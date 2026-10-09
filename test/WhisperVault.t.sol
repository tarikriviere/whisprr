// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {WhisperVault} from "../src/WhisperVault.sol";
import {MockRWA} from "../src/mocks/MockRWA.sol";
import {OracleVenue} from "../src/mocks/OracleVenue.sol";

contract WhisperVaultTest is Test {
    address operator = makeAddr("operator");
    address anyone = makeAddr("anyone");

    MockRWA usdc; // cash leg, 6 decimals
    MockRWA tbill;
    MockRWA gold;
    MockRWA spy;
    OracleVenue venue;
    WhisperVault vault;

    uint64 constant JITTER_BEFORE = 1 days;
    uint64 constant JITTER_AFTER = 2 days;
    uint64 constant GRACE = 1 hours;
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

        // Venue inventory.
        usdc.mint(address(venue), 10_000_000e6);
        tbill.mint(address(venue), 100_000e18);
        gold.mint(address(venue), 4_000e18);
        spy.mint(address(venue), 20_000e18);

        address[] memory cs = new address[](4);
        cs[0] = address(usdc);
        cs[1] = address(tbill);
        cs[2] = address(gold);
        cs[3] = address(spy);
        vault = new WhisperVault(
            operator, venue, cs, keccak256("methodology-v1"), JITTER_BEFORE, JITTER_AFTER, GRACE, 50
        );

        // Seed vault at 25/25/25/25 of $1m.
        usdc.mint(address(vault), 250_000e6);
        tbill.mint(address(vault), 2_500e18);
        gold.mint(address(vault), 100e18);
        spy.mint(address(vault), 500e18);
    }

    // Target 10 / 40 / 20 / 30.
    function _plan() internal pure returns (uint16[] memory w, WhisperVault.Trade[] memory t) {
        w = new uint16[](4);
        w[0] = 1_000;
        w[1] = 4_000;
        w[2] = 2_000;
        w[3] = 3_000;
        t = new WhisperVault.Trade[](2);
        // Sell $50k gold -> $50k spy; sell $150k usdc -> $150k tbill.
        t[0] = WhisperVault.Trade(2, 3, 20e18, 0);
        t[1] = WhisperVault.Trade(0, 1, 150_000e6, 0);
    }

    function _commit() internal returns (uint16[] memory w, WhisperVault.Trade[] memory t, uint64 nominal) {
        (w, t) = _plan();
        nominal = uint64(block.timestamp + 7 days);
        bytes32 c = vault.hashRebalance(1, w, t, SALT);
        vm.prank(operator);
        vault.commit(c, nominal);
    }

    function _draw() internal returns (uint64 executeAt) {
        vm.roll(block.number + vault.DRAW_DELAY() + 1);
        executeAt = vault.drawExecutionTime();
    }

    function test_fullLoop() public {
        (uint16[] memory w, WhisperVault.Trade[] memory t, uint64 nominal) = _commit();
        uint64 executeAt = _draw();
        assertGe(executeAt, nominal - JITTER_BEFORE);
        assertLe(executeAt, nominal + JITTER_AFTER);

        vm.warp(executeAt);
        vm.prank(operator);
        vault.execute(w, t, SALT);

        uint256[] memory cw = vault.currentWeights();
        assertApproxEqAbs(cw[0], 1_000, 1);
        assertApproxEqAbs(cw[1], 4_000, 1);
        assertApproxEqAbs(cw[2], 2_000, 1);
        assertApproxEqAbs(cw[3], 3_000, 1);
        (,,,,,, uint64 executedAt, WhisperVault.Status s) = vault.epochs(1);
        assertEq(uint8(s), uint8(WhisperVault.Status.Executed));
        assertEq(executedAt, executeAt);
    }

    function test_nextEpochAfterExecution() public {
        (uint16[] memory w, WhisperVault.Trade[] memory t,) = _commit();
        vm.warp(_draw());
        vm.prank(operator);
        vault.execute(w, t, SALT);

        vm.prank(operator);
        assertEq(vault.commit(keccak256("next"), uint64(block.timestamp + 7 days)), 2);
    }

    function test_revert_commitWhileOpen() public {
        _commit();
        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(WhisperVault.EpochOpen.selector, 1, WhisperVault.Status.Committed)
        );
        vault.commit(keccak256("x"), uint64(block.timestamp + 7 days));
    }

    function test_revert_commitNotOperator() public {
        vm.prank(anyone);
        vm.expectRevert(WhisperVault.NotOperator.selector);
        vault.commit(keccak256("x"), uint64(block.timestamp + 7 days));
    }

    function test_revert_windowInPast() public {
        vm.prank(operator);
        vm.expectRevert(WhisperVault.WindowInPast.selector);
        vault.commit(keccak256("x"), uint64(block.timestamp + JITTER_BEFORE));
    }

    function test_revert_drawTooSoon() public {
        _commit();
        vm.expectRevert();
        vault.drawExecutionTime();
    }

    function test_drawRearmsWhenHashExpired() public {
        _commit();
        vm.roll(block.number + 1_000);
        assertEq(vault.drawExecutionTime(), 0);
        (,, uint64 drawBlock,,,,, WhisperVault.Status s) = vault.epochs(1);
        assertEq(drawBlock, block.number + vault.DRAW_DELAY());
        assertEq(uint8(s), uint8(WhisperVault.Status.Committed));
    }

    function test_revert_executeBeforeDraw() public {
        (uint16[] memory w, WhisperVault.Trade[] memory t,) = _commit();
        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(
                WhisperVault.WrongStatus.selector, WhisperVault.Status.Drawn, WhisperVault.Status.Committed
            )
        );
        vault.execute(w, t, SALT);
    }

    function test_revert_executeTooEarly() public {
        (uint16[] memory w, WhisperVault.Trade[] memory t,) = _commit();
        uint64 executeAt = _draw();
        vm.warp(executeAt - 1);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(WhisperVault.TooEarly.selector, executeAt));
        vault.execute(w, t, SALT);
    }

    function test_revert_executeTooLate_thenDefault() public {
        (uint16[] memory w, WhisperVault.Trade[] memory t,) = _commit();
        uint64 executeAt = _draw();
        vm.warp(executeAt + GRACE + 1);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(WhisperVault.TooLate.selector, executeAt + GRACE));
        vault.execute(w, t, SALT);

        vm.prank(anyone);
        vault.markDefaulted();
        (,,,,,,, WhisperVault.Status s) = vault.epochs(1);
        assertEq(uint8(s), uint8(WhisperVault.Status.Defaulted));
    }

    function test_revert_markDefaultedEarly() public {
        _commit();
        uint64 executeAt = _draw();
        vm.warp(executeAt);
        vm.expectRevert(abi.encodeWithSelector(WhisperVault.StillExecutable.selector, executeAt + GRACE));
        vault.markDefaulted();
    }

    function test_revert_wrongSalt() public {
        (uint16[] memory w, WhisperVault.Trade[] memory t,) = _commit();
        vm.warp(_draw());
        vm.prank(operator);
        vm.expectPartialRevert(WhisperVault.CommitmentMismatch.selector);
        vault.execute(w, t, keccak256("wrong"));
    }

    function test_revert_tamperedTrade() public {
        (uint16[] memory w, WhisperVault.Trade[] memory t,) = _commit();
        vm.warp(_draw());
        t[0].amountIn = 21e18;
        vm.prank(operator);
        vm.expectPartialRevert(WhisperVault.CommitmentMismatch.selector);
        vault.execute(w, t, SALT);
    }

    function test_revert_tradesDontReachCommittedWeights() public {
        // Commit to weights the trades don't produce: the vault refuses to call it honest.
        (uint16[] memory w, WhisperVault.Trade[] memory t) = _plan();
        w[0] = 2_000;
        w[1] = 3_000;
        bytes32 c = vault.hashRebalance(1, w, t, SALT);
        vm.prank(operator);
        vault.commit(c, uint64(block.timestamp + 7 days));
        vm.warp(_draw());
        vm.prank(operator);
        vm.expectPartialRevert(WhisperVault.WeightOutOfTolerance.selector);
        vault.execute(w, t, SALT);
    }

    function test_revert_executeNotOperator() public {
        (uint16[] memory w, WhisperVault.Trade[] memory t,) = _commit();
        vm.warp(_draw());
        vm.prank(anyone);
        vm.expectRevert(WhisperVault.NotOperator.selector);
        vault.execute(w, t, SALT);
    }

    function testFuzz_drawAlwaysInsideWindow(bytes32 commitment, uint32 offset) public {
        uint64 nominal = uint64(block.timestamp) + JITTER_BEFORE + 1 + offset;
        vm.prank(operator);
        vault.commit(commitment, nominal);
        vm.roll(block.number + vault.DRAW_DELAY() + 1);
        uint64 executeAt = vault.drawExecutionTime();
        assertGe(executeAt, nominal - JITTER_BEFORE);
        assertLe(executeAt, nominal + JITTER_AFTER);
    }
}
