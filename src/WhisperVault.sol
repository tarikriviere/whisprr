// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IPriceVenue} from "./IPriceVenue.sol";

/// @title WhisperVault
/// @notice An onchain index whose rebalances can't be front-run.
///
/// The *framework* is public from deployment: the constituent universe, a hash of the
/// methodology document, the jitter window and the weight tolerance. The *specifics* of each
/// rebalance (target weights, trades) are sealed behind a hash commitment until the moment
/// they execute.
///
/// Lifecycle of an epoch:
///   1. commit(commitment, nominalTime): operator seals keccak256(preimage); the execution
///      window [nominalTime - jitterBefore, nominalTime + jitterAfter] is fixed.
///   2. drawExecutionTime(): anyone, once the draw block is mined, derives the exact execution
///      time inside the window from that block's hash, which wasn't known at commit.
///   3. execute(weights, trades, salt): operator reveals the preimage within the grace period
///      after the drawn time. The vault checks the hash, runs every trade, and checks that the
///      resulting portfolio matches the committed weights. Reveal and execution are one atomic
///      transaction, so the instructions are never public before they've executed.
///   4. If the operator misses the grace period, anyone can call markDefaulted().
contract WhisperVault is ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint16 public constant BPS = 10_000;
    /// @dev Blocks between commit and the block whose hash seeds the execution-time draw.
    uint64 public constant DRAW_DELAY = 5;

    struct Trade {
        uint8 tokenIn; // index into constituents
        uint8 tokenOut; // index into constituents
        uint256 amountIn;
        uint256 minAmountOut;
    }

    enum Status {
        None,
        Committed,
        Drawn,
        Executed,
        Defaulted
    }

    struct Epoch {
        bytes32 commitment;
        uint64 committedBlock;
        uint64 drawBlock;
        uint64 windowStart;
        uint64 windowEnd;
        uint64 executeAt;
        uint64 executedAt;
        Status status;
    }

    // ---- public framework (disclosed in the clear at deployment) ----
    address public immutable operator;
    IPriceVenue public immutable venue;
    bytes32 public immutable frameworkHash;
    uint64 public immutable jitterBefore;
    uint64 public immutable jitterAfter;
    uint64 public immutable executionGrace;
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
        uint64 executionGrace,
        uint16 weightToleranceBps
    );
    event Committed(
        uint256 indexed epoch,
        bytes32 indexed commitment,
        uint64 windowStart,
        uint64 windowEnd,
        uint64 drawBlock
    );
    event ExecutionTimeDrawn(uint256 indexed epoch, uint64 executeAt, bytes32 seed);
    event DrawRearmed(uint256 indexed epoch, uint64 newDrawBlock);
    event TradeExecuted(
        uint256 indexed epoch,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut
    );
    event Executed(
        uint256 indexed epoch, bytes32 indexed commitment, uint16[] weights, Trade[] trades, bytes32 salt
    );
    event Defaulted(uint256 indexed epoch);

    error NotOperator();
    error BadFramework();
    error EpochOpen(uint256 epoch, Status status);
    error WrongStatus(Status expected, Status actual);
    error WindowInPast();
    error DrawNotReady(uint64 drawBlock);
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
        address[] memory constituents_,
        bytes32 frameworkHash_,
        uint64 jitterBefore_,
        uint64 jitterAfter_,
        uint64 executionGrace_,
        uint16 weightToleranceBps_
    ) {
        if (constituents_.length < 2 || constituents_.length > type(uint8).max) {
            revert BadFramework();
        }
        if (executionGrace_ == 0 || weightToleranceBps_ > BPS) revert BadFramework();
        operator = operator_;
        venue = venue_;
        _constituents = constituents_;
        frameworkHash = frameworkHash_;
        jitterBefore = jitterBefore_;
        jitterAfter = jitterAfter_;
        executionGrace = executionGrace_;
        weightToleranceBps = weightToleranceBps_;
        emit FrameworkPublished(
            frameworkHash_, constituents_, jitterBefore_, jitterAfter_, executionGrace_, weightToleranceBps_
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
        uint64 drawBlock = uint64(block.number) + DRAW_DELAY;
        epochs[epoch] = Epoch({
            commitment: commitment,
            committedBlock: uint64(block.number),
            drawBlock: drawBlock,
            windowStart: windowStart,
            windowEnd: nominalTime + jitterAfter,
            executeAt: 0,
            executedAt: 0,
            status: Status.Committed
        });
        emit Committed(epoch, commitment, windowStart, nominalTime + jitterAfter, drawBlock);
    }

    /// @notice Draw the exact execution time from a block hash that didn't exist at commit time.
    /// Callable by anyone. If the draw block falls out of the 256-block hash horizon, the draw is
    /// re-armed to a fresh future block rather than accepting a predictable seed.
    function drawExecutionTime() external returns (uint64 executeAt) {
        uint256 epoch = currentEpoch;
        Epoch storage e = epochs[epoch];
        if (e.status != Status.Committed) revert WrongStatus(Status.Committed, e.status);
        if (block.number <= e.drawBlock) revert DrawNotReady(e.drawBlock);

        bytes32 bh = blockhash(e.drawBlock);
        if (bh == bytes32(0)) {
            e.drawBlock = uint64(block.number) + DRAW_DELAY;
            emit DrawRearmed(epoch, e.drawBlock);
            return 0;
        }

        bytes32 seed = keccak256(abi.encode(bh, e.commitment, epoch));
        uint64 span = e.windowEnd - e.windowStart + 1;
        executeAt = e.windowStart + uint64(uint256(seed) % span);
        e.executeAt = executeAt;
        e.status = Status.Drawn;
        emit ExecutionTimeDrawn(epoch, executeAt, seed);
    }

    /// @notice Reveal the sealed rebalance and execute it atomically.
    function execute(uint16[] calldata weights, Trade[] calldata trades, bytes32 salt)
        external
        onlyOperator
        nonReentrant
    {
        uint256 epoch = currentEpoch;
        Epoch storage e = epochs[epoch];
        if (e.status != Status.Drawn) revert WrongStatus(Status.Drawn, e.status);
        if (block.timestamp < e.executeAt) revert TooEarly(e.executeAt);
        uint64 deadline = e.executeAt + executionGrace;
        if (block.timestamp > deadline) revert TooLate(deadline);

        bytes32 actual = hashRebalance(epoch, weights, trades, salt);
        if (actual != e.commitment) revert CommitmentMismatch(e.commitment, actual);

        uint256 n = _constituents.length;
        if (weights.length != n) revert BadWeights();
        uint256 sum;
        for (uint256 i; i < n; ++i) {
            sum += weights[i];
        }
        if (sum != BPS) revert BadWeights();

        for (uint256 i; i < trades.length; ++i) {
            Trade calldata t = trades[i];
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
        e.executedAt = uint64(block.timestamp);
        emit Executed(epoch, e.commitment, weights, trades, salt);
    }

    /// @notice Publicly flag an epoch whose operator failed to execute in time.
    function markDefaulted() external {
        uint256 epoch = currentEpoch;
        Epoch storage e = epochs[epoch];
        if (e.status != Status.Drawn) revert WrongStatus(Status.Drawn, e.status);
        uint64 deadline = e.executeAt + executionGrace;
        if (block.timestamp <= deadline) revert StillExecutable(deadline);
        e.status = Status.Defaulted;
        emit Defaulted(epoch);
    }
}
