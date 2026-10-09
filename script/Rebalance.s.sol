// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {WhisperVault} from "../src/WhisperVault.sol";

/// @notice Operator tooling for one rebalance epoch.
///
///   forge script script/Rebalance.s.sol --sig "commit()"  --rpc-url $MONAD_TESTNET_RPC --broadcast
///   forge script script/Rebalance.s.sol --sig "draw()"    --rpc-url $MONAD_TESTNET_RPC --broadcast
///   forge script script/Rebalance.s.sol --sig "execute()" --rpc-url $MONAD_TESTNET_RPC --broadcast
///
/// commit() plans trades from the vault's live holdings to the target WEIGHTS (comma-separated
/// bps, default 1000,4000,2000,3000), seals them with a fresh salt, and stores the preimage in
/// sealed/ (gitignored). Only the hash is broadcast.
contract Rebalance is Script {
    uint16 constant BPS = 10_000;
    uint8 constant CASH = 0;

    function _vault() internal view returns (WhisperVault) {
        string memory json = vm.readFile(string.concat("deployments/", vm.toString(block.chainid), ".json"));
        return WhisperVault(vm.parseJsonAddress(json, ".vault"));
    }

    function _sealedPath(WhisperVault vault, uint256 epoch) internal view returns (string memory) {
        return string.concat("sealed/", vm.toString(address(vault)), "-", vm.toString(epoch), ".hex");
    }

    function commit() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        WhisperVault vault = _vault();

        uint256[] memory def = new uint256[](4);
        (def[0], def[1], def[2], def[3]) = (1_000, 4_000, 2_000, 3_000);
        uint256[] memory raw = vm.envOr("WEIGHTS", ",", def);
        uint16[] memory weights = new uint16[](raw.length);
        for (uint256 i; i < raw.length; ++i) {
            weights[i] = uint16(raw[i]);
        }

        WhisperVault.Trade[] memory trades = plan(vault, weights);
        bytes32 salt = keccak256(abi.encode(vm.randomUint(), pk, block.timestamp, block.prevrandao));
        uint256 epoch = vault.currentEpoch() + 1;
        bytes32 commitment = _hash(vault, epoch, weights, trades, salt);
        uint64 nominal = uint64(block.timestamp + vm.envOr("NOMINAL_DELAY", vault.jitterBefore() + 60));

        vm.writeFile(_sealedPath(vault, epoch), vm.toString(abi.encode(weights, trades, salt)));

        vm.broadcast(pk);
        vault.commit(commitment, nominal);

        console.log("epoch     ", epoch);
        console.log("commitment");
        console.logBytes32(commitment);
        console.log("nominal   ", nominal);
        console.log("trades    ", trades.length);
    }

    function draw() external {
        vm.broadcast(vm.envUint("PRIVATE_KEY"));
        uint64 executeAt = _vault().drawExecutionTime();
        console.log("executeAt ", executeAt, "(0 = draw re-armed, run again in a few blocks)");
    }

    function execute() external {
        WhisperVault vault = _vault();
        uint256 epoch = vault.currentEpoch();
        bytes memory sealedData = vm.parseBytes(vm.readFile(_sealedPath(vault, epoch)));
        (uint16[] memory weights, WhisperVault.Trade[] memory trades, bytes32 salt) =
            abi.decode(sealedData, (uint16[], WhisperVault.Trade[], bytes32));

        vm.broadcast(vm.envUint("PRIVATE_KEY"));
        vault.execute(weights, trades, salt);
        console.log("executed epoch", epoch);
    }

    /// @notice Trades that move the vault to `weights`: sell every overweight leg into cash, then buy
    /// every underweight leg from cash. Sells come first so the cash leg can fund the buys.
    function plan(WhisperVault vault, uint16[] memory weights)
        public
        view
        returns (WhisperVault.Trade[] memory trades)
    {
        address[] memory cs = vault.constituents();
        require(weights.length == cs.length, "weights length");
        (uint256[] memory values, uint256 total) = vault.holdingsValue();

        WhisperVault.Trade[] memory buf = new WhisperVault.Trade[](2 * cs.length);
        uint256 n;
        for (uint256 pass; pass < 2; ++pass) {
            for (uint256 i = 1; i < cs.length; ++i) {
                uint256 target = total * weights[i] / BPS;
                uint256 price = vault.venue().priceOf(cs[i]);
                if (pass == 0 && values[i] > target) {
                    uint256 amt = (values[i] - target) * 10 ** IERC20Metadata(cs[i]).decimals() / price;
                    buf[n++] = WhisperVault.Trade(uint8(i), CASH, amt, 0);
                } else if (pass == 1 && values[i] < target) {
                    uint256 amt = (target - values[i]) * 10 ** IERC20Metadata(cs[CASH]).decimals()
                        / vault.venue().priceOf(cs[CASH]);
                    buf[n++] = WhisperVault.Trade(CASH, uint8(i), amt, 0);
                }
            }
        }
        trades = new WhisperVault.Trade[](n);
        for (uint256 i; i < n; ++i) {
            trades[i] = buf[i];
        }
    }

    /// @dev Same encoding as WhisperVault.hashRebalance, computed locally so the preimage never
    /// leaves this machine before execution.
    function _hash(
        WhisperVault vault,
        uint256 epoch,
        uint16[] memory weights,
        WhisperVault.Trade[] memory trades,
        bytes32 salt
    ) internal view returns (bytes32) {
        return keccak256(abi.encode(block.chainid, address(vault), epoch, weights, trades, salt));
    }
}
