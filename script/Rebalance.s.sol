// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {WhisprrVault} from "../src/WhisprrVault.sol";

/// @notice Operator tooling: commit one rebalance. The operator's role ends there; Chainlink
/// executes it at the time its salt and the seed block imply, and the vault sizes the trades
/// from the prices at that second.
///
///   forge script script/Rebalance.s.sol --sig "commit()" --rpc-url $MONAD_TESTNET_RPC --broadcast
///
/// The date isn't the operator's to pick: the commit seals the next scheduled rebalance.
/// commit() seals the target WEIGHTS (comma-separated bps, default 1000,4000,2000,3000) with a
/// fresh salt and stores the sealed plan (hex of abi.encode(epoch, weights, salt)) in sealed/
/// (gitignored). Only the hash is broadcast. Hand the sealed file to the CRE workflow with
/// cre/whisprr-keeper/scripts/hand-over.mjs.
contract Rebalance is Script {
    function _vault() internal view returns (WhisprrVault) {
        string memory json = vm.readFile(string.concat("deployments/", vm.toString(block.chainid), ".json"));
        return WhisprrVault(vm.parseJsonAddress(json, ".vault"));
    }

    function _sealedPath(WhisprrVault vault, uint256 epoch) internal view returns (string memory) {
        return string.concat("sealed/", vm.toString(address(vault)), "-", vm.toString(epoch), ".hex");
    }

    function commit() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        WhisprrVault vault = _vault();

        uint256[] memory def = new uint256[](4);
        (def[0], def[1], def[2], def[3]) = (1_000, 4_000, 2_000, 3_000);
        uint256[] memory raw = vm.envOr("WEIGHTS", ",", def);
        uint16[] memory weights = new uint16[](raw.length);
        for (uint256 i; i < raw.length; ++i) {
            weights[i] = uint16(raw[i]);
        }

        bytes32 salt = keccak256(abi.encode(vm.randomUint(), pk, block.timestamp, block.prevrandao));
        uint256 epoch = vault.currentEpoch() + 1;
        // Same encoding as WhisprrVault.hashRebalance, computed locally so the preimage never
        // leaves this machine before execution.
        bytes32 commitment = keccak256(abi.encode(block.chainid, address(vault), epoch, weights, salt));
        (, uint64 nominal,,, uint64 deadline) = vault.nextSlot();

        vm.writeFile(_sealedPath(vault, epoch), vm.toString(abi.encode(epoch, weights, salt)));

        vm.broadcast(pk);
        vault.commit(commitment);

        console.log("epoch     ", epoch);
        console.log("commitment");
        console.logBytes32(commitment);
        console.log("nominal   ", nominal, "(next scheduled date)");
        console.log("deadline  ", deadline);
        console.log("sealed    ", _sealedPath(vault, epoch));
        console.log("next: node cre/whisprr-keeper/scripts/hand-over.mjs <sealed file>");
    }
}
