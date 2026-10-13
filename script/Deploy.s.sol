// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {WhisprrVault} from "../src/WhisprrVault.sol";
import {MockRWA} from "../src/mocks/MockRWA.sol";
import {OracleVenue} from "../src/mocks/OracleVenue.sol";

/// @notice Deploys the constituents, venue and vault, seeds a $1m 25/25/25/25 portfolio,
/// and writes addresses to deployments/<chainid>.json.
/// Jitter/grace default to demo-friendly minutes; override with JITTER_BEFORE, JITTER_AFTER, GRACE.
contract Deploy is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        uint64 jitterBefore = uint64(vm.envOr("JITTER_BEFORE", uint256(60)));
        uint64 jitterAfter = uint64(vm.envOr("JITTER_AFTER", uint256(120)));
        uint64 grace = uint64(vm.envOr("GRACE", uint256(600)));
        // Chainlink forwarder trusted for CRE draws. Defaults to Monad testnet's simulation forwarder,
        // which `cre workflow simulate --broadcast` writes through; use the KeystoneForwarder
        // (0xF8344CFd5c43616a4366C34E3EEE75af79a74482) for a deployed workflow.
        address drawForwarder = vm.envOr(
            "DRAW_FORWARDER", block.chainid == 10143 ? 0xB9F79d863261869B234c481D1f9A7af84AeAd192 : address(0)
        );

        vm.startBroadcast(pk);

        MockRWA usdc = new MockRWA("Mock USD Coin", "mUSDC", 6, deployer);
        MockRWA tbill = new MockRWA("Mock Tokenized T-Bill", "mTBILL", 18, deployer);
        MockRWA gold = new MockRWA("Mock Tokenized Gold", "mXAU", 18, deployer);
        MockRWA spy = new MockRWA("Mock Tokenized S&P 500", "mSPY", 18, deployer);

        OracleVenue venue = new OracleVenue(deployer);
        venue.setPrice(address(usdc), 1e18);
        venue.setPrice(address(tbill), 100e18);
        venue.setPrice(address(gold), 2_500e18);
        venue.setPrice(address(spy), 500e18);
        usdc.mint(address(venue), 10_000_000e6);
        tbill.mint(address(venue), 100_000e18);
        gold.mint(address(venue), 4_000e18);
        spy.mint(address(venue), 20_000e18);

        address[] memory cs = new address[](4);
        cs[0] = address(usdc);
        cs[1] = address(tbill);
        cs[2] = address(gold);
        cs[3] = address(spy);
        WhisprrVault vault = new WhisprrVault(
            deployer,
            venue,
            drawForwarder,
            cs,
            keccak256(bytes(vm.readFile("docs/FRAMEWORK.md"))),
            jitterBefore,
            jitterAfter,
            grace,
            50
        );

        usdc.mint(address(vault), 250_000e6);
        tbill.mint(address(vault), 2_500e18);
        gold.mint(address(vault), 100e18);
        spy.mint(address(vault), 500e18);

        vm.stopBroadcast();

        string memory k = "deployment";
        vm.serializeAddress(k, "operator", deployer);
        vm.serializeAddress(k, "venue", address(venue));
        vm.serializeAddress(k, "drawForwarder", drawForwarder);
        vm.serializeAddress(k, "mUSDC", address(usdc));
        vm.serializeAddress(k, "mTBILL", address(tbill));
        vm.serializeAddress(k, "mXAU", address(gold));
        vm.serializeAddress(k, "mSPY", address(spy));
        string memory json = vm.serializeAddress(k, "vault", address(vault));
        vm.writeJson(json, string.concat("deployments/", vm.toString(block.chainid), ".json"));

        // Point the CRE workflow at the new vault.
        if (block.chainid == 10143) {
            vm.writeJson(vm.toString(address(vault)), "cre/whisprr-draw/config.staging.json", ".vaultAddress");
            vm.writeJson(vm.toString(address(vault)), "cre/whisprr-draw/config.production.json", ".vaultAddress");
        }

        console.log("WhisprrVault:", address(vault));
        console.log("OracleVenue: ", address(venue));
    }
}
