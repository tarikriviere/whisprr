// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {WhisprrVault} from "../src/WhisprrVault.sol";
import {IReceiver} from "../src/IReceiver.sol";
import {MockRWA} from "../src/mocks/MockRWA.sol";
import {OracleVenue} from "../src/mocks/OracleVenue.sol";

contract WhisprrVaultTest is Test {
    address operator = makeAddr("operator");
    address anyone = makeAddr("anyone");
    address forwarder = makeAddr("chainlinkForwarder");

    MockRWA usdc; // cash leg, 6 decimals
    MockRWA tbill;
    MockRWA gold;
    MockRWA spy;
    OracleVenue venue;
    WhisprrVault vault;

    uint64 constant JITTER_BEFORE = 1 days;
    uint64 constant JITTER_AFTER = 2 days;
    uint64 constant TOLERANCE = 60;
    bytes32 constant SALT = keccak256("salt");

    function setUp() public {
        vm.warp(1_760_000_000);
        vm.roll(1_000);

        usdc = new MockRWA("Mock USD Coin", "mUSDC", 6, address(this));
        tbill = new MockRWA("Mock Tokenized T-Bill", "mTBILL", 18, address(this));
        gold = new MockRWA("Mock Tokenized Gold", "mXAU", 18, address(this));
        spy = new MockRWA("Mock Tokenized S&P 500", "mSPY", 18, address(this));

        venue = new OracleVenue(address(this));
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
        vault = new WhisprrVault(
            operator,
            venue,
            forwarder,
            cs,
            keccak256("methodology-v1"),
            JITTER_BEFORE,
            JITTER_AFTER,
            TOLERANCE,
            50
        );

        // Seed vault at 25/25/25/25 of $1m.
        usdc.mint(address(vault), 250_000e6);
        tbill.mint(address(vault), 2_500e18);
        gold.mint(address(vault), 100e18);
        spy.mint(address(vault), 500e18);
    }

    // ---- helpers ----

    // Target 10 / 40 / 20 / 30.
    function _plan() internal pure returns (uint16[] memory w, WhisprrVault.Trade[] memory t) {
        w = new uint16[](4);
        w[0] = 1_000;
        w[1] = 4_000;
        w[2] = 2_000;
        w[3] = 3_000;
        t = new WhisprrVault.Trade[](2);
        t[0] = WhisprrVault.Trade(2, 3, 20e18, 0); // $50k gold -> S&P
        t[1] = WhisprrVault.Trade(0, 1, 150_000e6, 0); // $150k cash -> tbill
    }

    function _commit(uint16[] memory w, WhisprrVault.Trade[] memory t, bytes32 salt)
        internal
        returns (uint64 nominal)
    {
        nominal = uint64(block.timestamp + 7 days);
        bytes32 c = vault.hashRebalance(vault.currentEpoch() + 1, w, t, salt);
        vm.prank(operator);
        vault.commit(c, nominal);
    }

    function _commitPlan()
        internal
        returns (uint16[] memory w, WhisprrVault.Trade[] memory t, uint64 nominal)
    {
        (w, t) = _plan();
        nominal = _commit(w, t, SALT);
    }

    function _seed() internal {
        vm.roll(block.number + vault.SEED_DELAY() + 1);
        vault.recordSeed();
    }

    function _report(uint256 epoch, uint16[] memory w, WhisprrVault.Trade[] memory t, bytes32 salt)
        internal
        view
        returns (bytes memory)
    {
        return abi.encode(vault.REPORT_EXECUTE(), abi.encode(epoch, w, t, salt));
    }

    function _executeViaChainlink(uint16[] memory w, WhisprrVault.Trade[] memory t, bytes32 salt) internal {
        bytes memory r = _report(vault.currentEpoch(), w, t, salt);
        vm.prank(forwarder);
        vault.onReport("", r);
    }

    function _status(uint256 epoch) internal view returns (WhisprrVault.Status s) {
        (,,,,,,,,, s) = vault.epochs(epoch);
    }

    // ---- full loop ----

    function test_fullLoop_chainlinkExecutesAtSealedTime() public {
        (uint16[] memory w, WhisprrVault.Trade[] memory t, uint64 nominal) = _commitPlan();
        _seed();
        uint64 executeAt = vault.executionTime(1, SALT);
        assertGe(executeAt, nominal - JITTER_BEFORE);
        assertLe(executeAt, nominal + JITTER_AFTER);

        vm.warp(executeAt);
        _executeViaChainlink(w, t, SALT);

        uint256[] memory cw = vault.currentWeights();
        assertApproxEqAbs(cw[0], 1_000, 1);
        assertApproxEqAbs(cw[1], 4_000, 1);
        assertApproxEqAbs(cw[2], 2_000, 1);
        assertApproxEqAbs(cw[3], 3_000, 1);
        (,,,,,, uint64 storedAt, uint64 executedAt, uint64 executedBlock, WhisprrVault.Status s) =
            vault.epochs(1);
        assertEq(uint8(s), uint8(WhisprrVault.Status.Executed));
        assertEq(storedAt, executeAt);
        assertEq(executedAt, executeAt);
        assertEq(executedBlock, block.number);
    }

    function test_executesAnywhereWithinTolerance() public {
        (uint16[] memory w, WhisprrVault.Trade[] memory t,) = _commitPlan();
        _seed();
        vm.warp(vault.executionTime(1, SALT) + TOLERANCE);
        _executeViaChainlink(w, t, SALT);
        assertEq(uint8(_status(1)), uint8(WhisprrVault.Status.Executed));
    }

    function test_nextEpochAfterExecution() public {
        (uint16[] memory w, WhisprrVault.Trade[] memory t,) = _commitPlan();
        _seed();
        vm.warp(vault.executionTime(1, SALT));
        _executeViaChainlink(w, t, SALT);

        vm.prank(operator);
        assertEq(vault.commit(keccak256("next"), uint64(block.timestamp + 7 days)), 2);
    }

    // ---- timing can't be chosen ----

    function test_revert_oneSecondEarly() public {
        (uint16[] memory w, WhisprrVault.Trade[] memory t,) = _commitPlan();
        _seed();
        uint64 executeAt = vault.executionTime(1, SALT);
        vm.warp(executeAt - 1);
        bytes memory r = _report(1, w, t, SALT);
        vm.prank(forwarder);
        vm.expectRevert(abi.encodeWithSelector(WhisprrVault.TooEarly.selector, executeAt));
        vault.onReport("", r);
    }

    function test_revert_pastTolerance() public {
        (uint16[] memory w, WhisprrVault.Trade[] memory t,) = _commitPlan();
        _seed();
        uint64 executeAt = vault.executionTime(1, SALT);
        vm.warp(executeAt + TOLERANCE + 1);
        bytes memory r = _report(1, w, t, SALT);
        vm.prank(forwarder);
        vm.expectRevert(abi.encodeWithSelector(WhisprrVault.TooLate.selector, executeAt + TOLERANCE));
        vault.onReport("", r);
    }

    function test_revert_executeBeforeSeed() public {
        (uint16[] memory w, WhisprrVault.Trade[] memory t,) = _commitPlan();
        bytes memory r = _report(1, w, t, SALT);
        vm.prank(forwarder);
        vm.expectRevert(
            abi.encodeWithSelector(
                WhisprrVault.WrongStatus.selector, WhisprrVault.Status.Seeded, WhisprrVault.Status.Committed
            )
        );
        vault.onReport("", r);
    }

    function test_onlyForwarderCanExecute_operatorIncluded() public {
        (uint16[] memory w, WhisprrVault.Trade[] memory t,) = _commitPlan();
        _seed();
        vm.warp(vault.executionTime(1, SALT));
        bytes memory r = _report(1, w, t, SALT);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(WhisprrVault.NotForwarder.selector, operator));
        vault.onReport("", r);
    }

    function test_differentSeedGivesDifferentTime() public {
        (uint16[] memory w, WhisprrVault.Trade[] memory t) = _plan();
        _commit(w, t, SALT);
        vm.roll(block.number + vault.SEED_DELAY() + 1);
        uint256 snap = vm.snapshotState();
        vm.setBlockhash(block.number - 1, keccak256("seed-a"));
        vault.recordSeed();
        uint64 a = vault.executionTime(1, SALT);
        vm.revertToState(snap);
        vm.setBlockhash(block.number - 1, keccak256("seed-b"));
        vault.recordSeed();
        uint64 b = vault.executionTime(1, SALT);
        assertTrue(a != b);
    }

    // ---- the reveal must match ----

    function test_revert_wrongSalt() public {
        (uint16[] memory w, WhisprrVault.Trade[] memory t,) = _commitPlan();
        _seed();
        vm.warp(vault.executionTime(1, SALT));
        bytes memory r = _report(1, w, t, keccak256("wrong"));
        vm.prank(forwarder);
        vm.expectPartialRevert(WhisprrVault.CommitmentMismatch.selector);
        vault.onReport("", r);
    }

    function test_revert_tamperedTrade() public {
        (uint16[] memory w, WhisprrVault.Trade[] memory t,) = _commitPlan();
        _seed();
        vm.warp(vault.executionTime(1, SALT));
        t[0].amountIn = 21e18;
        bytes memory r = _report(1, w, t, SALT);
        vm.prank(forwarder);
        vm.expectPartialRevert(WhisprrVault.CommitmentMismatch.selector);
        vault.onReport("", r);
    }

    function test_revert_tradesDontReachCommittedWeights() public {
        (uint16[] memory w, WhisprrVault.Trade[] memory t) = _plan();
        w[0] = 2_000;
        w[1] = 3_000;
        _commit(w, t, SALT);
        _seed();
        vm.warp(vault.executionTime(1, SALT));
        bytes memory r = _report(1, w, t, SALT);
        vm.prank(forwarder);
        vm.expectPartialRevert(WhisprrVault.WeightOutOfTolerance.selector);
        vault.onReport("", r);
    }

    function test_revert_staleEpochReport() public {
        (uint16[] memory w, WhisprrVault.Trade[] memory t,) = _commitPlan();
        _seed();
        vm.warp(vault.executionTime(1, SALT));
        bytes memory r = _report(7, w, t, SALT);
        vm.prank(forwarder);
        vm.expectRevert(abi.encodeWithSelector(WhisprrVault.StaleReport.selector, 7, 1));
        vault.onReport("", r);
    }

    function test_revert_unknownReportKind() public {
        vm.prank(forwarder);
        vm.expectRevert(abi.encodeWithSelector(WhisprrVault.UnknownReport.selector, 9));
        vault.onReport("", abi.encode(uint8(9), bytes("")));
    }

    // ---- seed ----

    function test_seedViaChainlinkReport() public {
        _commitPlan();
        vm.roll(block.number + vault.SEED_DELAY() + 1);
        (bool ready,) = vault.pendingSeed();
        assertTrue(ready);
        bytes memory r = abi.encode(vault.REPORT_RECORD_SEED(), abi.encode(uint256(1)));
        vm.prank(forwarder);
        vault.onReport("", r);
        assertEq(uint8(_status(1)), uint8(WhisprrVault.Status.Seeded));
        (ready,) = vault.pendingSeed();
        assertFalse(ready);
    }

    function test_revert_seedTooSoon() public {
        _commitPlan();
        vm.expectPartialRevert(WhisprrVault.SeedNotReady.selector);
        vault.recordSeed();
    }

    function test_seedRearmsWhenHashExpired() public {
        _commitPlan();
        vm.roll(block.number + 1_000);
        vault.recordSeed();
        (,,, uint64 seedBlock,,,,,, WhisprrVault.Status s) = vault.epochs(1);
        assertEq(seedBlock, block.number + vault.SEED_DELAY());
        assertEq(uint8(s), uint8(WhisprrVault.Status.Committed));
    }

    function test_revert_executionTimeBeforeSeed() public {
        _commitPlan();
        vm.expectPartialRevert(WhisprrVault.WrongStatus.selector);
        vault.executionTime(1, SALT);
    }

    // ---- commit ----

    function test_revert_commitWhileOpen() public {
        _commitPlan();
        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(WhisprrVault.EpochOpen.selector, 1, WhisprrVault.Status.Committed)
        );
        vault.commit(keccak256("x"), uint64(block.timestamp + 7 days));
    }

    function test_revert_commitNotOperator() public {
        vm.prank(anyone);
        vm.expectRevert(WhisprrVault.NotOperator.selector);
        vault.commit(keccak256("x"), uint64(block.timestamp + 7 days));
    }

    function test_revert_windowInPast() public {
        vm.prank(operator);
        vm.expectRevert(WhisprrVault.WindowInPast.selector);
        vault.commit(keccak256("x"), uint64(block.timestamp + JITTER_BEFORE));
    }

    // ---- default ----

    function test_defaultAfterWindowPlusTolerance() public {
        (,, uint64 nominal) = _commitPlan();
        _seed();
        uint64 deadline = nominal + JITTER_AFTER + TOLERANCE;
        assertEq(vault.lastExecutionTime(1), deadline);

        vm.warp(deadline);
        vm.expectRevert(abi.encodeWithSelector(WhisprrVault.StillExecutable.selector, deadline));
        vault.markDefaulted();

        vm.warp(deadline + 1);
        vm.prank(anyone);
        vault.markDefaulted();
        assertEq(uint8(_status(1)), uint8(WhisprrVault.Status.Defaulted));
    }

    function test_defaultEvenIfNeverSeeded() public {
        (,, uint64 nominal) = _commitPlan();
        vm.warp(nominal + JITTER_AFTER + TOLERANCE + 1);
        vault.markDefaulted();
        assertEq(uint8(_status(1)), uint8(WhisprrVault.Status.Defaulted));
    }

    // ---- framework ----

    function test_revert_zeroForwarder() public {
        address[] memory cs = vault.constituents();
        vm.expectRevert(WhisprrVault.BadFramework.selector);
        new WhisprrVault(
            operator, venue, address(0), cs, keccak256("m"), JITTER_BEFORE, JITTER_AFTER, TOLERANCE, 50
        );
    }

    function test_supportsReceiverInterface() public view {
        assertTrue(vault.supportsInterface(type(IReceiver).interfaceId));
        assertTrue(vault.supportsInterface(0x01ffc9a7));
        assertFalse(vault.supportsInterface(0xdeadbeef));
    }

    function testFuzz_executionTimeAlwaysInsideWindow(bytes32 salt, bytes32 seed, uint32 offset) public {
        uint64 nominal = uint64(block.timestamp) + JITTER_BEFORE + 1 + offset;
        vm.prank(operator);
        vault.commit(keccak256("c"), nominal);
        vm.roll(block.number + vault.SEED_DELAY() + 1);
        vm.setBlockhash(block.number - 1, seed == bytes32(0) ? bytes32(uint256(1)) : seed);
        vault.recordSeed();
        uint64 executeAt = vault.executionTime(1, salt);
        assertGe(executeAt, nominal - JITTER_BEFORE);
        assertLe(executeAt, nominal + JITTER_AFTER);
    }
}
