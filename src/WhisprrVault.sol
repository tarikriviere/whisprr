// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IPriceVenue} from "./IPriceVenue.sol";
import {IReceiver} from "./IReceiver.sol";

/// @title WhisprrVault
/// @notice An onchain index whose rebalances can't be front-run, and whose timing no one chooses.
///
/// The *framework* is public from deployment: the constituent universe, a hash of the
/// methodology document, the execution window around each nominal date, the execution
/// tolerance and the weight tolerance. The *specifics* of each rebalance (target weights,
/// trades, salt) are sealed behind a hash commitment, and so is its exact execution time.
///
/// Lifecycle of an epoch:
///   1. commit(commitment, nominalTime): the operator seals keccak256(preimage). The preimage
///      includes a random salt. The window [nominal - jitterBefore, nominal + jitterAfter] is
///      public; the exact time inside it is not.
///   2. recordSeed(): SEED_DELAY blocks later, the hash of that block (unknown to everyone at
///      commit) is stored onchain. Anyone can record it; the Chainlink workflow does so too.
///      From here the execution time is fixed:
///          executeAt = windowStart + keccak256(salt, seedHash) mod (window length + 1)
///      but only someone who knows the salt can compute it.
///   3. Chainlink executes. At commit the operator hands the sealed preimage to the CRE
///      workflow as a secret; it never touches the chain. When executeAt arrives, the workflow
///      delivers it in a report. In one transaction the vault checks the preimage against the
///      commitment, recomputes executeAt from the revealed salt and requires
///      executeAt <= now <= executeAt + executionTolerance, runs every trade, and checks the
///      resulting weights. The market learns the time and the trades in the same transaction.
///      The operator has no function to execute with: it can't choose when, or whether.
///   4. If nothing has executed by windowEnd + executionTolerance, anyone can markDefaulted().
contract WhisprrVault is ReentrancyGuard, IReceiver {
    using SafeERC20 for IERC20;

    uint16 public constant BPS = 10_000;
    /// @dev Blocks between commit and the block whose hash seeds the execution time.
    uint64 public constant SEED_DELAY = 5;

    /// @dev Report kinds delivered by the CRE workflow: report = abi.encode(uint8 kind, bytes body).
    uint8 public constant REPORT_RECORD_SEED = 1; // body = abi.encode(uint256 epoch)
    uint8 public constant REPORT_EXECUTE = 2; // body = abi.encode(uint256 epoch, uint16[] weights, Trade[] trades, bytes32 salt)

    struct Trade {
        uint8 tokenIn; // index into constituents
        uint8 tokenOut; // index into constituents
        uint256 amountIn;
        uint256 minAmountOut;
    }

    enum Status {
        None,
        Committed,
        Seeded,
        Executed,
        Defaulted
    }

    struct Epoch {
        bytes32 commitment;
        bytes32 seedHash;
        uint64 committedBlock;
        uint64 seedBlock;
        uint64 windowStart;
        uint64 windowEnd;
        uint64 executeAt; // stored once revealed at execution
        uint64 executedAt;
        uint64 executedBlock; // lets indexers fetch the Executed event (the reveal) without a log scan
        Status status;
    }

    // ---- public framework (disclosed in the clear at deployment) ----
    address public immutable operator;
    IPriceVenue public immutable venue;
    /// @notice The only address that can deliver CRE reports, and so the only path to execution.
    address public immutable chainlinkForwarder;
    bytes32 public immutable frameworkHash;
    uint64 public immutable jitterBefore;
    uint64 public immutable jitterAfter;
    /// @notice How late after executeAt Chainlink's execution may land (covers its polling interval).
    uint64 public immutable executionTolerance;
    uint16 public immutable weightToleranceBps;
    address[] internal _constituents;

    // ---- epoch state ----
    uint256 public currentEpoch;
    mapping(uint256 => Epoch) public epochs;

    event FrameworkPublished(
        bytes32 indexed frameworkHash,
        address[] constituents,
        uint64 jitterBefore,
        uint64 jitterAfter,
        uint64 executionTolerance,
        uint16 weightToleranceBps
    );
    event Committed(
        uint256 indexed epoch,
        bytes32 indexed commitment,
        uint64 windowStart,
        uint64 windowEnd,
        uint64 seedBlock
    );
    event SeedRecorded(uint256 indexed epoch, uint64 seedBlock, bytes32 seedHash);
    event SeedRearmed(uint256 indexed epoch, uint64 newSeedBlock);
    event TradeExecuted(
        uint256 indexed epoch,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut
    );
    event Executed(
        uint256 indexed epoch,
        bytes32 indexed commitment,
        uint16[] weights,
        Trade[] trades,
        bytes32 salt,
        uint64 executeAt
    );
    event Defaulted(uint256 indexed epoch);

    error NotOperator();
    error NotForwarder(address sender);
    error UnknownReport(uint8 kind);
    error StaleReport(uint256 reportEpoch, uint256 currentEpoch);
    error BadFramework();
    error EpochOpen(uint256 epoch, Status status);
    error WrongStatus(Status expected, Status actual);
    error WindowInPast();
    error SeedNotReady(uint64 seedBlock);
    error TooEarly(uint64 executeAt);
    error TooLate(uint64 deadline);
    error StillExecutable(uint64 deadline);
    error CommitmentMismatch(bytes32 expected, bytes32 actual);
    error BadWeights();
    error BadTrade(uint256 index);
    error WeightOutOfTolerance(uint256 index, uint256 actualBps, uint256 targetBps);

    modifier onlyOperator() {
        if (msg.sender != operator) revert NotOperator();
        _;
    }

    constructor(
        address operator_,
        IPriceVenue venue_,
        address chainlinkForwarder_,
        address[] memory constituents_,
        bytes32 frameworkHash_,
        uint64 jitterBefore_,
        uint64 jitterAfter_,
        uint64 executionTolerance_,
        uint16 weightToleranceBps_
    ) {
        if (constituents_.length < 2 || constituents_.length > type(uint8).max) {
            revert BadFramework();
        }
        if (executionTolerance_ == 0 || weightToleranceBps_ > BPS) revert BadFramework();
        if (chainlinkForwarder_ == address(0)) revert BadFramework();
        operator = operator_;
        venue = venue_;
        chainlinkForwarder = chainlinkForwarder_;
        _constituents = constituents_;
        frameworkHash = frameworkHash_;
        jitterBefore = jitterBefore_;
        jitterAfter = jitterAfter_;
        executionTolerance = executionTolerance_;
        weightToleranceBps = weightToleranceBps_;
        emit FrameworkPublished(
            frameworkHash_,
            constituents_,
            jitterBefore_,
            jitterAfter_,
            executionTolerance_,
            weightToleranceBps_
        );
    }

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------

    function constituents() external view returns (address[] memory) {
        return _constituents;
    }

    function constituentCount() external view returns (uint256) {
        return _constituents.length;
    }

    /// @notice The commitment for a rebalance preimage. Compute it locally before committing:
    /// calling this through a public RPC shows the preimage to that RPC's operator.
    function hashRebalance(uint256 epoch, uint16[] memory weights, Trade[] memory trades, bytes32 salt)
        public
        view
        returns (bytes32)
    {
        return keccak256(abi.encode(block.chainid, address(this), epoch, weights, trades, salt));
    }

    /// @notice The execution time the salt and the recorded seed imply. Anyone can recompute it
    /// once the salt is revealed; before that, only holders of the salt can.
    function executionTime(uint256 epoch, bytes32 salt) public view returns (uint64) {
        Epoch storage e = epochs[epoch];
        if (e.seedHash == bytes32(0)) revert WrongStatus(Status.Seeded, e.status);
        uint64 span = e.windowEnd - e.windowStart + 1;
        return e.windowStart + uint64(uint256(keccak256(abi.encode(salt, e.seedHash))) % span);
    }

    /// @notice Latest moment the current epoch can still execute; after it, anyone can flag a default.
    function lastExecutionTime(uint256 epoch) public view returns (uint64) {
        return epochs[epoch].windowEnd + executionTolerance;
    }

    /// @notice What the CRE workflow polls: whether the seed block of the current epoch is mined
    /// and waiting to be recorded.
    function pendingSeed() external view returns (bool ready, uint256 epoch) {
        epoch = currentEpoch;
        Epoch storage e = epochs[epoch];
        ready = e.status == Status.Committed && block.number > e.seedBlock;
    }

    /// @notice The chain's clock, so offchain executors judge "now" exactly as the vault will.
    function chainTime() external view returns (uint64) {
        return uint64(block.timestamp);
    }

    /// @notice USD value (1e18) of each constituent held and their sum.
    function holdingsValue() public view returns (uint256[] memory values, uint256 total) {
        uint256 n = _constituents.length;
        values = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            address t = _constituents[i];
            values[i] =
                IERC20(t).balanceOf(address(this)) * venue.priceOf(t) / 10 ** IERC20Metadata(t).decimals();
            total += values[i];
        }
    }

    /// @notice Current portfolio weights in basis points.
    function currentWeights() public view returns (uint256[] memory weights) {
        (uint256[] memory values, uint256 total) = holdingsValue();
        weights = new uint256[](values.length);
        if (total == 0) return weights;
        for (uint256 i; i < values.length; ++i) {
            weights[i] = values[i] * BPS / total;
        }
    }

    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IReceiver).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    // ------------------------------------------------------------------
    // Lifecycle
    // ------------------------------------------------------------------

    /// @notice Seal the next rebalance. Only the hash goes onchain.
    function commit(bytes32 commitment, uint64 nominalTime) external onlyOperator returns (uint256 epoch) {
        if (currentEpoch != 0) {
            Status s = epochs[currentEpoch].status;
            if (s != Status.Executed && s != Status.Defaulted) revert EpochOpen(currentEpoch, s);
        }
        uint64 windowStart = nominalTime > jitterBefore ? nominalTime - jitterBefore : 0;
        if (windowStart <= block.timestamp) revert WindowInPast();

        epoch = ++currentEpoch;
        uint64 seedBlock = uint64(block.number) + SEED_DELAY;
        epochs[epoch] = Epoch({
            commitment: commitment,
            seedHash: bytes32(0),
            committedBlock: uint64(block.number),
            seedBlock: seedBlock,
            windowStart: windowStart,
            windowEnd: nominalTime + jitterAfter,
            executeAt: 0,
            executedAt: 0,
            executedBlock: 0,
            status: Status.Committed
        });
        emit Committed(epoch, commitment, windowStart, nominalTime + jitterAfter, seedBlock);
    }

    /// @notice Store the seed block's hash. Callable by anyone (and by the Chainlink workflow) once
    /// the seed block is mined. Recording it doesn't reveal the time: that needs the salt too.
    /// If the seed block has fallen out of the 256-block hash horizon, the seed is re-armed to a
    /// fresh future block rather than accepting a predictable value.
    function recordSeed() public {
        uint256 epoch = currentEpoch;
        Epoch storage e = epochs[epoch];
        if (e.status != Status.Committed) revert WrongStatus(Status.Committed, e.status);
        if (block.number <= e.seedBlock) revert SeedNotReady(e.seedBlock);

        bytes32 bh = blockhash(e.seedBlock);
        if (bh == bytes32(0)) {
            e.seedBlock = uint64(block.number) + SEED_DELAY;
            emit SeedRearmed(epoch, e.seedBlock);
            return;
        }
        e.seedHash = bh;
        e.status = Status.Seeded;
        emit SeedRecorded(epoch, e.seedBlock, bh);
    }

    /// @notice CRE report entry point. Only the Chainlink forwarder can call it.
    function onReport(bytes calldata, bytes calldata report) external nonReentrant {
        if (msg.sender != chainlinkForwarder) revert NotForwarder(msg.sender);
        (uint8 kind, bytes memory body) = abi.decode(report, (uint8, bytes));
        if (kind == REPORT_RECORD_SEED) {
            uint256 epoch = abi.decode(body, (uint256));
            if (epoch != currentEpoch) revert StaleReport(epoch, currentEpoch);
            recordSeed();
        } else if (kind == REPORT_EXECUTE) {
            (uint256 epoch, uint16[] memory weights, Trade[] memory trades, bytes32 salt) =
                abi.decode(body, (uint256, uint16[], Trade[], bytes32));
            _execute(epoch, weights, trades, salt);
        } else {
            revert UnknownReport(kind);
        }
    }

    /// @dev Reveal the sealed rebalance and execute it atomically, at the time its salt implies.
    function _execute(uint256 epoch, uint16[] memory weights, Trade[] memory trades, bytes32 salt) internal {
        if (epoch != currentEpoch) revert StaleReport(epoch, currentEpoch);
        Epoch storage e = epochs[epoch];
        if (e.status != Status.Seeded) revert WrongStatus(Status.Seeded, e.status);

        bytes32 actual = hashRebalance(epoch, weights, trades, salt);
        if (actual != e.commitment) revert CommitmentMismatch(e.commitment, actual);

        uint64 executeAt = executionTime(epoch, salt);
        if (block.timestamp < executeAt) revert TooEarly(executeAt);
        if (block.timestamp > executeAt + executionTolerance) revert TooLate(executeAt + executionTolerance);

        uint256 n = _constituents.length;
        if (weights.length != n) revert BadWeights();
        uint256 sum;
        for (uint256 i; i < n; ++i) {
            sum += weights[i];
        }
        if (sum != BPS) revert BadWeights();

        for (uint256 i; i < trades.length; ++i) {
            Trade memory t = trades[i];
            if (t.tokenIn >= n || t.tokenOut >= n || t.tokenIn == t.tokenOut) revert BadTrade(i);
            address tIn = _constituents[t.tokenIn];
            address tOut = _constituents[t.tokenOut];
            IERC20(tIn).forceApprove(address(venue), t.amountIn);
            uint256 out = venue.swap(tIn, tOut, t.amountIn, t.minAmountOut, address(this));
            emit TradeExecuted(epoch, tIn, tOut, t.amountIn, out);
        }

        uint256[] memory w = currentWeights();
        for (uint256 i; i < n; ++i) {
            uint256 diff = w[i] > weights[i] ? w[i] - weights[i] : weights[i] - w[i];
            if (diff > weightToleranceBps) revert WeightOutOfTolerance(i, w[i], weights[i]);
        }

        e.status = Status.Executed;
        e.executeAt = executeAt;
        e.executedAt = uint64(block.timestamp);
        e.executedBlock = uint64(block.number);
        emit Executed(epoch, e.commitment, weights, trades, salt, executeAt);
    }

    /// @notice Publicly flag an epoch that wasn't executed by the end of its window plus tolerance.
    function markDefaulted() external {
        uint256 epoch = currentEpoch;
        Epoch storage e = epochs[epoch];
        if (e.status != Status.Committed && e.status != Status.Seeded) {
            revert WrongStatus(Status.Seeded, e.status);
        }
        uint64 deadline = lastExecutionTime(epoch);
        if (block.timestamp <= deadline) revert StillExecutable(deadline);
        e.status = Status.Defaulted;
        emit Defaulted(epoch);
    }
}
