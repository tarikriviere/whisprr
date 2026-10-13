// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {WhisprrVault} from "../src/WhisprrVault.sol";
import {IReceiver} from "../src/IReceiver.sol";
import {MockRWA} from "../src/mocks/MockRWA.sol";
import {OracleVenue} from "../src/mocks/OracleVenue.sol";
import {IPriceVenue} from "../src/IPriceVenue.sol";

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
    uint64 constant PERIOD = 7 days;
    uint64 constant LEAD = 1 hours;
    uint64 scheduleStart;

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
            _timing(),
            50
        );

        // Seed vault at 25/25/25/25 of $1m.
        usdc.mint(address(vault), 250_000e6);
        tbill.mint(address(vault), 2_500e18);
        gold.mint(address(vault), 100e18);
        spy.mint(address(vault), 500e18);
    }

    // ---- helpers ----

    function _timing() internal returns (WhisprrVault.Timing memory) {
        if (scheduleStart == 0) scheduleStart = uint64(block.timestamp + 7 days);
        return WhisprrVault.Timing(JITTER_BEFORE, JITTER_AFTER, TOLERANCE, scheduleStart, PERIOD, LEAD);
    }

    // Target 10 / 40 / 20 / 30.
    function _plan() internal pure returns (uint16[] memory w) {
        w = new uint16[](4);
        w[0] = 1_000;
        w[1] = 4_000;
        w[2] = 2_000;
        w[3] = 3_000;
    }

    function _commit(uint16[] memory w, bytes32 salt) internal returns (uint64 nominal) {
        (, nominal,,,) = vault.nextSlot();
        bytes32 c = vault.hashRebalance(vault.currentEpoch() + 1, w, salt);
        vm.prank(operator);
        vault.commit(c);
    }

    function _commitPlan() internal returns (uint16[] memory w, uint64 nominal) {
        w = _plan();
        nominal = _commit(w, SALT);
    }

    function _seed() internal {
        vm.roll(block.number + vault.SEED_DELAY() + 1);
        vault.recordSeed();
    }

    function _report(uint256 epoch, uint16[] memory w, bytes32 salt) internal view returns (bytes memory) {
        return abi.encode(vault.REPORT_EXECUTE(), abi.encode(epoch, w, salt));
    }

    function _executeViaChainlink(uint16[] memory w, bytes32 salt) internal {
        bytes memory r = _report(vault.currentEpoch(), w, salt);
        vm.prank(forwarder);
        vault.onReport("", r);
    }

    function _status(uint256 epoch) internal view returns (WhisprrVault.Status s) {
        (,,,,,,,,, s) = vault.epochs(epoch);
    }

    // ---- full loop ----

    function test_fullLoop_chainlinkExecutesAtSealedTime() public {
        (uint16[] memory w, uint64 nominal) = _commitPlan();
        _seed();
        uint64 executeAt = vault.executionTime(1, SALT);
        assertGe(executeAt, nominal - JITTER_BEFORE);
        assertLe(executeAt, nominal + JITTER_AFTER);

        vm.warp(executeAt);
        _executeViaChainlink(w, SALT);

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
        (uint16[] memory w,) = _commitPlan();
        _seed();
        vm.warp(vault.executionTime(1, SALT) + TOLERANCE);
        _executeViaChainlink(w, SALT);
        assertEq(uint8(_status(1)), uint8(WhisprrVault.Status.Executed));
    }

    function test_nextEpochAfterExecution() public {
        (uint16[] memory w,) = _commitPlan();
        _seed();
        vm.warp(vault.executionTime(1, SALT));
        _executeViaChainlink(w, SALT);

        vm.prank(operator);
        assertEq(vault.commit(keccak256("next")), 2);
    }

    // ---- timing can't be chosen ----

    function test_revert_oneSecondEarly() public {
        (uint16[] memory w,) = _commitPlan();
        _seed();
        uint64 executeAt = vault.executionTime(1, SALT);
        vm.warp(executeAt - 1);
        bytes memory r = _report(1, w, SALT);
        vm.prank(forwarder);
        vm.expectRevert(abi.encodeWithSelector(WhisprrVault.TooEarly.selector, executeAt));
        vault.onReport("", r);
    }

    function test_revert_pastTolerance() public {
        (uint16[] memory w,) = _commitPlan();
        _seed();
        uint64 executeAt = vault.executionTime(1, SALT);
        vm.warp(executeAt + TOLERANCE + 1);
        bytes memory r = _report(1, w, SALT);
        vm.prank(forwarder);
        vm.expectRevert(abi.encodeWithSelector(WhisprrVault.TooLate.selector, executeAt + TOLERANCE));
        vault.onReport("", r);
    }

    function test_revert_executeBeforeSeed() public {
        (uint16[] memory w,) = _commitPlan();
        bytes memory r = _report(1, w, SALT);
        vm.prank(forwarder);
        vm.expectRevert(
            abi.encodeWithSelector(
                WhisprrVault.WrongStatus.selector, WhisprrVault.Status.Seeded, WhisprrVault.Status.Committed
            )
        );
        vault.onReport("", r);
    }

    function test_onlyForwarderCanExecute_operatorIncluded() public {
        (uint16[] memory w,) = _commitPlan();
        _seed();
        vm.warp(vault.executionTime(1, SALT));
        bytes memory r = _report(1, w, SALT);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(WhisprrVault.NotForwarder.selector, operator));
        vault.onReport("", r);
    }

    function test_differentSeedGivesDifferentTime() public {
        uint16[] memory w = _plan();
        _commit(w, SALT);
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
        (uint16[] memory w,) = _commitPlan();
        _seed();
        vm.warp(vault.executionTime(1, SALT));
        bytes memory r = _report(1, w, keccak256("wrong"));
        vm.prank(forwarder);
        vm.expectPartialRevert(WhisprrVault.CommitmentMismatch.selector);
        vault.onReport("", r);
    }

    function test_revert_tamperedWeights() public {
        (uint16[] memory w,) = _commitPlan();
        _seed();
        vm.warp(vault.executionTime(1, SALT));
        w[0] = 1_001;
        w[1] = 3_999;
        bytes memory r = _report(1, w, SALT);
        vm.prank(forwarder);
        vm.expectPartialRevert(WhisprrVault.CommitmentMismatch.selector);
        vault.onReport("", r);
    }

    function test_revert_weightsDontSumToOne() public {
        uint16[] memory w = _plan();
        w[0] = 900;
        _commit(w, SALT);
        _seed();
        vm.warp(vault.executionTime(1, SALT));
        bytes memory r = _report(1, w, SALT);
        vm.prank(forwarder);
        vm.expectRevert(WhisprrVault.BadWeights.selector);
        vault.onReport("", r);
    }

    // ---- trades are sized at execution, from the prices at that second ----

    function test_pricesMoveBeforeExecution_stillLandsOnTarget() public {
        (uint16[] memory w,) = _commitPlan();
        _seed();
        // Days pass inside the window: gold +12%, S&P -9%, T-bills accrue.
        venue.setPrice(address(gold), 2_800e18);
        venue.setPrice(address(spy), 455e18);
        venue.setPrice(address(tbill), 101e18);
        vm.warp(vault.executionTime(1, SALT));
        _executeViaChainlink(w, SALT);

        uint256[] memory cw = vault.currentWeights();
        for (uint256 i; i < 4; ++i) {
            assertApproxEqAbs(cw[i], w[i], 1);
        }
    }

    function test_zeroWeightSellsOut() public {
        uint16[] memory w = new uint16[](4);
        w[0] = 2_000;
        w[1] = 0;
        w[2] = 5_000;
        w[3] = 3_000;
        _commit(w, SALT);
        _seed();
        vm.warp(vault.executionTime(1, SALT));
        _executeViaChainlink(w, SALT);
        assertLt(tbill.balanceOf(address(vault)), 1e15);
        uint256[] memory cw = vault.currentWeights();
        assertApproxEqAbs(cw[2], 5_000, 1);
    }

    function test_revert_venueSlippageBeyondTolerance() public {
        SlippyVenue slippy = new SlippyVenue();
        address[] memory cs = vault.constituents();
        for (uint256 i; i < cs.length; ++i) {
            slippy.setPrice(cs[i], venue.priceOf(cs[i]));
            MockRWA(cs[i]).mint(address(slippy), MockRWA(cs[i]).balanceOf(address(venue)));
        }
        vault = new WhisprrVault(
            operator, IPriceVenue(address(slippy)), forwarder, cs, keccak256("m"), _timing(), 50
        );
        usdc.mint(address(vault), 250_000e6);
        tbill.mint(address(vault), 2_500e18);
        gold.mint(address(vault), 100e18);
        spy.mint(address(vault), 500e18);

        (uint16[] memory w,) = _commitPlan();
        _seed();
        vm.warp(vault.executionTime(1, SALT));
        bytes memory r = _report(1, w, SALT);
        vm.prank(forwarder);
        vm.expectPartialRevert(WhisprrVault.WeightOutOfTolerance.selector);
        vault.onReport("", r);
    }

    function test_revert_staleEpochReport() public {
        (uint16[] memory w,) = _commitPlan();
        _seed();
        vm.warp(vault.executionTime(1, SALT));
        bytes memory r = _report(7, w, SALT);
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
        vault.commit(keccak256("x"));
    }

    function test_revert_commitNotOperator() public {
        vm.prank(anyone);
        vm.expectRevert(WhisprrVault.NotOperator.selector);
        vault.commit(keccak256("x"));
    }

    // ---- schedule: the operator never picks the date ----

    function test_commitTakesNextScheduledSlot() public {
        (, uint64 nominal) = _commitPlan();
        assertEq(nominal, scheduleStart);
        (,,,, uint64 windowStart, uint64 windowEnd,,,,) = vault.epochs(1);
        assertEq(windowStart, scheduleStart - JITTER_BEFORE);
        assertEq(windowEnd, scheduleStart + JITTER_AFTER);
    }

    function test_commitPastDeadlineRollsToFollowingSlot() public {
        vm.warp(scheduleStart - JITTER_BEFORE - LEAD + 1);
        (uint64 slot, uint64 nominal,,,) = vault.nextSlot();
        assertEq(slot, 1);
        assertEq(nominal, scheduleStart + PERIOD);
        vm.warp(scheduleStart - JITTER_BEFORE - LEAD);
        (slot,,,,) = vault.nextSlot();
        assertEq(slot, 0);
    }

    function test_commitFlagsExpiredRebalanceAsDefaulted() public {
        (, uint64 nominal) = _commitPlan();
        vm.warp(nominal + JITTER_AFTER + TOLERANCE + 1);
        vm.prank(operator);
        assertEq(vault.commit(keccak256("next")), 2);
        assertEq(uint8(_status(1)), uint8(WhisprrVault.Status.Defaulted));
        (,,,, uint64 windowStart,,,,,) = vault.epochs(2);
        assertEq(windowStart, scheduleStart + PERIOD - JITTER_BEFORE);
    }

    function test_revert_scheduleTooTight() public {
        address[] memory cs = vault.constituents();
        vm.expectRevert(WhisprrVault.BadFramework.selector);
        new WhisprrVault(
            operator,
            venue,
            forwarder,
            cs,
            keccak256("m"),
            WhisprrVault.Timing(JITTER_BEFORE, JITTER_AFTER, TOLERANCE, scheduleStart, 3 days, LEAD),
            50
        );
    }

    // ---- default ----

    function test_defaultAfterWindowPlusTolerance() public {
        (, uint64 nominal) = _commitPlan();
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
        (, uint64 nominal) = _commitPlan();
        vm.warp(nominal + JITTER_AFTER + TOLERANCE + 1);
        vault.markDefaulted();
        assertEq(uint8(_status(1)), uint8(WhisprrVault.Status.Defaulted));
    }

    // ---- framework ----

    function test_revert_zeroForwarder() public {
        address[] memory cs = vault.constituents();
        vm.expectRevert(WhisprrVault.BadFramework.selector);
        new WhisprrVault(
            operator, venue, address(0), cs, keccak256("m"), _timing(), 50
        );
    }

    function test_supportsReceiverInterface() public view {
        assertTrue(vault.supportsInterface(type(IReceiver).interfaceId));
        assertTrue(vault.supportsInterface(0x01ffc9a7));
        assertFalse(vault.supportsInterface(0xdeadbeef));
    }

    function testFuzz_executionTimeAlwaysInsideWindow(bytes32 salt, bytes32 seed, uint32 offset) public {
        vm.warp(block.timestamp + offset);
        (, uint64 nominal,,,) = vault.nextSlot();
        assertEq((nominal - scheduleStart) % PERIOD, 0);
        assertGe(nominal - JITTER_BEFORE, block.timestamp + LEAD);
        vm.prank(operator);
        vault.commit(keccak256("c"));
        vm.roll(block.number + vault.SEED_DELAY() + 1);
        vm.setBlockhash(block.number - 1, seed == bytes32(0) ? bytes32(uint256(1)) : seed);
        vault.recordSeed();
        uint64 executeAt = vault.executionTime(1, salt);
        assertGe(executeAt, nominal - JITTER_BEFORE);
        assertLe(executeAt, nominal + JITTER_AFTER);
    }
}

/// @dev A venue that fills 20% short of its own quote, to exercise the weight check.
contract SlippyVenue {
    mapping(address => uint256) public priceOf;

    function setPrice(address token, uint256 price) external {
        priceOf[token] = price;
    }

    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256, address to)
        external
        returns (uint256 amountOut)
    {
        uint256 usd = amountIn * priceOf[tokenIn] / 10 ** MockRWA(tokenIn).decimals();
        amountOut = usd * 10 ** MockRWA(tokenOut).decimals() / priceOf[tokenOut] * 80 / 100;
        MockRWA(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        MockRWA(tokenOut).transfer(to, amountOut);
    }
}
