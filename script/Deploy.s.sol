// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {WhisprrVault} from "../src/WhisprrVault.sol";
import {MockRWA} from "../src/mocks/MockRWA.sol";
import {OracleVenue} from "../src/mocks/OracleVenue.sol";

/// @notice Deploys the constituents, venue and vault, seeds a $1m 25/25/25/25 portfolio,
/// and writes addresses to deployments/<chainid>.json.
/// Timing defaults to a demo-friendly schedule: a rebalance every 5 minutes on the clock's 5-minute
/// marks, window [-30s, +45s], 60s execution tolerance, commits at least 60s before the window.
/// Override with REBALANCE_PERIOD, SCHEDULE_START, JITTER_BEFORE, JITTER_AFTER, TOLERANCE, COMMIT_LEAD.
///
///   forge script script/Deploy.s.sol --rpc-url $MONAD_TESTNET_RPC --broadcast                       # everything
///   forge script script/Deploy.s.sol --sig "vaultOnly()" --rpc-url $MONAD_TESTNET_RPC --broadcast   # new vault, same tokens and venue
contract Deploy is Script {
    function _forwarder() internal view returns (address) {
        // Chainlink forwarder trusted for CRE reports (seed + execution). Defaults to Monad testnet's simulation forwarder,
        // which `cre workflow simulate --broadcast` writes through; use the KeystoneForwarder
        // (0xF8344CFd5c43616a4366C34E3EEE75af79a74482) for a deployed workflow.
        return vm.envOr(
            "CHAINLINK_FORWARDER",
            block.chainid == 10143 ? 0xB9F79d863261869B234c481D1f9A7af84AeAd192 : address(0)
        );
    }

    function _newVault(address deployer, OracleVenue venue, address[] memory cs) internal returns (WhisprrVault) {
        uint64 period = uint64(vm.envOr("REBALANCE_PERIOD", uint256(300)));
        WhisprrVault.Timing memory t = WhisprrVault.Timing({
            jitterBefore: uint64(vm.envOr("JITTER_BEFORE", uint256(30))),
            jitterAfter: uint64(vm.envOr("JITTER_AFTER", uint256(45))),
            executionTolerance: uint64(vm.envOr("TOLERANCE", uint256(60))),
            // First nominal date: the next multiple of the period, so dates fall on round clock times.
            scheduleStart: uint64(vm.envOr("SCHEDULE_START", (block.timestamp / period + 1) * period)),
            rebalancePeriod: period,
            commitLead: uint64(vm.envOr("COMMIT_LEAD", uint256(60)))
        });
        return new WhisprrVault(
            deployer, venue, _forwarder(), cs, keccak256(bytes(vm.readFile("docs/FRAMEWORK.md"))), t, 50
        );
    }

    /// @notice Deploys a fresh vault against the existing tokens and venue (deployer must own the
    /// tokens) and seeds it with $1m at 25/25/25/25 of the venue's current prices.
    function vaultOnly() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        string memory json = vm.readFile(string.concat("deployments/", vm.toString(block.chainid), ".json"));
        OracleVenue venue = OracleVenue(vm.parseJsonAddress(json, ".venue"));
        address[] memory cs = new address[](4);
        cs[0] = vm.parseJsonAddress(json, ".mUSDC");
        cs[1] = vm.parseJsonAddress(json, ".mTBILL");
        cs[2] = vm.parseJsonAddress(json, ".mXAU");
        cs[3] = vm.parseJsonAddress(json, ".mSPY");

        vm.startBroadcast(pk);
        WhisprrVault vault = _newVault(deployer, venue, cs);
        for (uint256 i; i < cs.length; ++i) {
            MockRWA t = MockRWA(cs[i]);
            t.mint(address(vault), 250_000e18 * 10 ** t.decimals() / venue.priceOf(cs[i]));
        }
        vm.stopBroadcast();

        _write(deployer, address(venue), cs, address(vault));
    }

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

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
        WhisprrVault vault = _newVault(deployer, venue, cs);

        usdc.mint(address(vault), 250_000e6);
        tbill.mint(address(vault), 2_500e18);
        gold.mint(address(vault), 100e18);
        spy.mint(address(vault), 500e18);

        vm.stopBroadcast();

        _write(deployer, address(venue), cs, address(vault));
    }

    function _write(address deployer, address venue, address[] memory cs, address vault) internal {
        string memory k = "deployment";
        vm.serializeAddress(k, "operator", deployer);
        vm.serializeAddress(k, "venue", venue);
        vm.serializeAddress(k, "chainlinkForwarder", _forwarder());
        vm.serializeAddress(k, "mUSDC", cs[0]);
        vm.serializeAddress(k, "mTBILL", cs[1]);
        vm.serializeAddress(k, "mXAU", cs[2]);
        vm.serializeAddress(k, "mSPY", cs[3]);
        string memory json = vm.serializeAddress(k, "vault", vault);
        vm.writeJson(json, string.concat("deployments/", vm.toString(block.chainid), ".json"));

        // Point the CRE workflow at the new vault.
        if (block.chainid == 10143) {
            vm.writeJson(
                vm.toString(vault), "cre/whisprr-keeper/config.staging.json", ".vaultAddress"
            );
            vm.writeJson(
                vm.toString(vault), "cre/whisprr-keeper/config.production.json", ".vaultAddress"
            );
        }

        console.log("WhisprrVault:", vault);
        console.log("OracleVenue: ", venue);
    }
}
