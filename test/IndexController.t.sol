// SPDX-License-Identifier: Unlicense
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IndexController} from "../src/IndexController.sol";
import {Valuation, IAggregatorV3} from "../src/Valuation.sol";
import {IM7Vault} from "../src/interfaces/IM7Vault.sol";
import {Swap} from "../src/Types.sol";
import {
    ControllerToken,
    ControllerFeed,
    ControllerRegistry,
    ControllerVault
} from "./mocks/ControllerMocks.sol";

/// @dev The quarterly equal-weight reset against a vault double whose legs convert at the mock feeds' fair value.
///      Seven $100 stocks, 100 tokens each: $70,000 at equal weights.
contract IndexControllerTest is Test {
    IndexController controller;
    Valuation valuation;
    ControllerVault vault;
    address[8] assets;
    ControllerFeed[8] feeds;
    ControllerFeed sequencer;
    ControllerRegistry registry;
    uint32 constant QUARTER = 2026 * 4 + 3;
    address constant KEEPER = address(0xBEEF);

    function setUp() public {
        vm.warp(1790870400); // Thursday Oct 1 2026 16:00 UTC.
        IAggregatorV3[8] memory aggregators;
        for (uint256 i; i < 8; ++i) {
            assets[i] = address(new ControllerToken(i == 7 ? 6 : 8));
            feeds[i] = new ControllerFeed(8, i == 7 ? int256(1e8) : int256(100e8));
            aggregators[i] = feeds[i];
        }
        sequencer = new ControllerFeed(0, 0);
        registry = new ControllerRegistry();
        valuation = new Valuation(assets, aggregators, sequencer, registry, 25 hours);
        vault = new ControllerVault(assets, feeds);
        for (uint256 i; i < 7; ++i) {
            ControllerToken(assets[i]).mint(address(vault), 100e8);
        }
        controller = new IndexController(IM7Vault(address(vault)), valuation);
    }

    function _price(uint256 index, uint256 dollars) private {
        feeds[index].set(int256(dollars * 1e8), block.timestamp);
    }

    /// AAPL rises 10% and AMZN falls 10%: NAV stays $70,000 and each should again hold $10,000.
    function _drift() private {
        _price(0, 110);
        _price(1, 90);
    }

    function _rebalance() private {
        controller.rebalance(block.timestamp, KEEPER);
    }

    /// @dev Half an hour on, or the next weekday's 15:00 UTC if that leaves the window, with every feed reported fresh.
    function _nextTranche() private {
        uint256 t = block.timestamp + controller.TRANCHE_COOLDOWN();
        if (t % 1 days >= 20 hours) t = (t / 1 days + 1) * 1 days + 15 hours;
        while ((t / 1 days + 4) % 7 == 0 || (t / 1 days + 4) % 7 == 6) {
            t += 1 days;
        }
        vm.warp(t);
        for (uint256 i; i < 8; ++i) {
            feeds[i].set(feeds[i].answer(), block.timestamp);
        }
    }

    /// @dev The largest oracle value any single leg has traded so far.
    function _largestLeg() private view returns (uint256 largest) {
        uint256[7] memory prices;
        for (uint256 i; i < 7; ++i) {
            prices[i] = uint256(feeds[i].answer());
        }
        for (uint256 k; k < vault.legCount(); ++k) {
            Swap memory leg = vault.legAt(k);
            uint256 value = leg.tokenIn == 7 ? leg.amountIn * 1e12 : leg.amountIn * prices[leg.tokenIn] * 1e2;
            if (value > largest) largest = value;
        }
    }

    function _held(uint256 index) private view returns (uint256) {
        return ControllerToken(assets[index]).balanceOf(address(vault));
    }

    function _usdc() private view returns (ControllerToken) {
        return ControllerToken(assets[7]);
    }

    // ------------------------------------------------------------------ schedule

    function testExactGregorianQuarterBoundariesIncludingLeapAndCentury() public view {
        assertEq(controller.quarterAt(1711929599), 2024 * 4);
        assertEq(controller.quarterAt(1711929600), 2024 * 4 + 1);
        assertEq(controller.quarterAt(4110220799), 2100 * 4);
        assertEq(controller.quarterAt(4110220800), 2100 * 4 + 1);
        assertEq(controller.quarterAt(1798761599), 2026 * 4 + 3);
        assertEq(controller.quarterAt(1798761600), 2027 * 4);
        assertEq(controller.quarterAt(0), 1970 * 4);
    }

    function testAnyoneResetsOncePerCalendarQuarter() public {
        _drift();
        assertTrue(controller.rebalanceDue());
        vm.prank(address(456));
        _rebalance();
        assertTrue(controller.executedQuarter(QUARTER));
        assertEq(controller.lastExecutedQuarter(), QUARTER);
        assertFalse(controller.rebalanceDue());
        vm.expectRevert(IndexController.AlreadyRebalanced.selector);
        _rebalance();
        // The next quarter opens on its first day; Monday Jan 4 2027 is its first execution window.
        vm.warp(1799078400);
        assertTrue(controller.rebalanceDue());
        for (uint256 i; i < 8; ++i) {
            feeds[i].set(feeds[i].answer(), block.timestamp);
        }
        _price(2, 120);
        _rebalance();
        assertEq(controller.lastExecutedQuarter(), 2027 * 4);
    }

    function testRunsOnlyInsideTheValuationWindow() public {
        _drift();
        vm.warp(1791043200); // Saturday Oct 3 2026 16:00 UTC
        vm.expectRevert(Valuation.OutsideExecutionWindow.selector);
        _rebalance();
        assertTrue(controller.rebalanceDue());
    }

    // ------------------------------------------------------------------ targets and trades

    function testEqualWeightsTradeNothingAndPayNoReward() public {
        _rebalance();
        assertEq(vault.calls(), 0);
        assertEq(vault.rewardPaid(), 0);
        assertTrue(controller.executedQuarter(QUARTER));
    }

    function testPriceMovesAreResetToEqualValue() public {
        _drift();
        _rebalance();
        assertEq(vault.calls(), 2);
        // Sales first: AAPL's $1,000 surplus, plus 1/7 of the $0.50 reward from every other stock above goal.
        Swap memory sell = vault.legAt(0);
        assertEq(sell.tokenIn, 0);
        assertEq(sell.tokenOut, 7);
        assertApproxEqAbs(sell.amountIn, 9.0916e8, 0.0001e8); // $1,000.07 of AAPL at $110
        Swap memory buy = vault.legAt(vault.legCount() - 1);
        assertEq(buy.tokenIn, 7);
        assertEq(buy.tokenOut, 1);
        assertApproxEqAbs(buy.amountIn, 999.93e6, 0.01e6); // AMZN's deficit to $9,999.93
        // Every stock holds $9,999.93: equal value after the reward. One tranche completes the quarter.
        uint256[7] memory prices = [uint256(110), 90, 100, 100, 100, 100, 100];
        for (uint256 i; i < 7; ++i) {
            assertApproxEqRel(_held(i) * prices[i], 9_999.93e8, 0.001e18);
        }
        assertEq(vault.rewardPaid(), 0.5e6); // 5 bp of the $1,000 traded
        assertEq(vault.rewardRecipient(), KEEPER);
        assertEq(_usdc().balanceOf(KEEPER), 0.5e6);
        assertTrue(controller.executedQuarter(QUARTER));
    }

    function testRewardIsCappedAndCanBeDeclined() public {
        for (uint256 i; i < 7; ++i) {
            ControllerToken(assets[i]).mint(address(vault), 99_900e8); // $70M at $100 per token
        }
        _usdc().mint(address(vault), 7_000_000e6); // a $7M donation to invest: seven $10k purchases per tranche
        uint256 snapshot = vm.snapshotState();
        _rebalance();
        assertEq(vault.rewardPaid(), 25e6); // 5 bp of $70,000 would be $35
        vm.revertToState(snapshot);
        controller.rebalance(block.timestamp, address(0));
        assertEq(vault.rewardPaid(), 0);
        assertEq(vault.calls(), 1); // purchases only
    }

    function testLargeMovesFinishInASecondTranche() public {
        _price(1, 40); // AMZN falls 60%: its quantity would need to rise 150%
        _rebalance();
        // A tranche may at most double a quantity share: AMZN reaches 2/7, not the 5/17 equal-value share.
        uint256 total;
        for (uint256 i; i < 7; ++i) {
            total += _held(i);
        }
        assertApproxEqRel(_held(1) * 1e18 / total, uint256(2e18) / 7, 0.001e18);
        assertFalse(controller.executedQuarter(QUARTER));
        assertFalse(controller.rebalanceDue()); // cooling down
        vm.expectRevert(IndexController.TooSoon.selector);
        _rebalance();
        _nextTranche();
        assertTrue(controller.rebalanceDue());
        _rebalance();
        assertTrue(controller.executedQuarter(QUARTER));
        uint256[7] memory prices = [uint256(100), 40, 100, 100, 100, 100, 100];
        uint256 value = _held(0) * prices[0];
        for (uint256 i = 1; i < 7; ++i) {
            assertApproxEqRel(_held(i) * prices[i], value, 0.003e18);
        }
    }

    /// AAPL x20 leaves it at 77% of NAV: the whole move would sell $163k of it. Tranches take it $10k at a time, in the
    /// same proportion for every stock, and complete the quarter within two trading days.
    function testHugeMovesProceedInCappedTranches() public {
        _price(0, 2_000);
        uint256 tranches;
        while (!controller.executedQuarter(QUARTER)) {
            if (tranches != 0) _nextTranche();
            _rebalance();
            ++tranches;
            assertLe(_largestLeg(), 10_000e18, "a leg above the $10k cap");
        }
        assertEq(tranches, 17);
        assertEq(controller.currentQuarter(), QUARTER);
        uint256[7] memory prices = [uint256(2_000), 100, 100, 100, 100, 100, 100];
        uint256 value = _held(0) * prices[0];
        for (uint256 i = 1; i < 7; ++i) {
            assertApproxEqRel(_held(i) * prices[i], value, 0.001e18);
        }
    }

    function testSeizedStockIsRebuiltByTheMinimumStep() public {
        ControllerToken(assets[3]).burn(address(vault), 100e8); // seized to zero: issuance halts
        _rebalance();
        // Stock 3 regains the 0.25-point minimum step; the six others each sell a quarter token to fund it, and all
        // seven fund the $0.075 reward pro rata. Later tranches continue the rebuild.
        assertApproxEqAbs(_held(3), 1.5e8, 0.001e8);
        for (uint256 i; i < 7; ++i) {
            if (i != 3) assertApproxEqAbs(_held(i), 99.75e8, 0.001e8);
        }
        assertEq(vault.rewardPaid(), 0.075e6);
        assertFalse(controller.executedQuarter(QUARTER));
    }

    // ------------------------------------------------------------------ postconditions

    function testFuzzLossBackstopIsOnePercentOfTradedValue(uint16 lossBps) public {
        lossBps = uint16(bound(lossBps, 0, 300));
        vm.assume(lossBps != 100); // exactly 1% sits on the rounding boundary either way
        _drift();
        vault.setOutputBps(10_000 - lossBps);
        if (lossBps > 100) vm.expectRevert(IndexController.RebalanceLoss.selector);
        _rebalance();
        assertEq(vault.calls() != 0, lossBps <= 100);
    }

    function testLossLimitAtomicRollbackAndRetry() public {
        _drift();
        vault.setOutputBps(9_800);
        vm.expectRevert(IndexController.RebalanceLoss.selector);
        _rebalance();
        assertEq(_held(0), 100e8);
        assertEq(vault.calls(), 0);
        assertEq(vault.rewardPaid(), 0);
        assertTrue(controller.rebalanceDue());
        vault.setOutputBps(9_950);
        _rebalance();
        assertEq(vault.calls(), 2);
    }

    function testComplianceAndCashPostconditionsRollBack() public {
        _drift();
        uint256[8] memory amounts;
        for (uint256 i; i < 7; ++i) {
            amounts[i] = 100e8;
        }
        amounts[0] = 90.9091e8;
        amounts[1] = 90e8; // AMZN was to be bought but ends lower: value kept, moved away from its goal
        amounts[7] = 1_900e6;
        vault.setAfter(amounts);
        vm.expectRevert(IndexController.NotCompliant.selector);
        _rebalance();
        amounts[1] = 111.1111e8;
        amounts[7] = 12e6; // on target, but $11.50 of cash after the $0.50 reward exceeds 1 bp of $70,000
        vault.setAfter(amounts);
        vm.expectRevert(IndexController.ResidualCash.selector);
        _rebalance();
        // A shortfall is not a failure: AMZN bought short of its goal leaves the rest for the next tranche.
        amounts[1] = 111.055e8; // 0.5% short of AMZN's goal: within the loss allowance
        amounts[7] = 0;
        vault.setAfter(amounts);
        _rebalance();
        assertTrue(controller.executedQuarter(QUARTER));
    }

    function testOneConsistentPriceSnapshotIsUsed() public {
        _drift();
        // After the sale, AAPL's feed collapses 99%. A second oracle read would fail the NAV check.
        vault.setChangeFeed(feeds[0]);
        _rebalance();
        assertTrue(controller.executedQuarter(QUARTER));
    }

    function testUnexpectedShareDilutionFailsAtomically() public {
        _drift();
        vault.setDilute(true);
        vm.expectRevert(IndexController.RebalanceLoss.selector);
        _rebalance();
        assertEq(vault.totalSupply(), 1_000e18);
    }

    function testFreshnessPauseAndDeadlineBlockTheReset() public {
        _drift();
        registry.setPaused(assets[0], true);
        vm.expectRevert(abi.encodeWithSelector(Valuation.CorporateAction.selector, 0));
        _rebalance();
        registry.setPaused(assets[0], false);
        feeds[2].set(100e8, block.timestamp - 25 hours - 1);
        vm.expectRevert(abi.encodeWithSelector(Valuation.UnavailablePrice.selector, 2));
        _rebalance();
        for (uint256 i; i < 7; ++i) {
            feeds[i].set(feeds[i].answer(), block.timestamp - 2 hours);
        }
        vm.expectRevert(Valuation.NoFreshMarketSignal.selector);
        _rebalance();
        vm.expectRevert(IndexController.Expired.selector);
        controller.rebalance(block.timestamp - 1, KEEPER);
        // One fresh feed is enough while quiet feeds stay inside their heartbeat.
        feeds[3].set(100e8, block.timestamp);
        _rebalance();
        assertTrue(controller.executedQuarter(QUARTER));
    }

    function testRejectsMissingConfiguration() public {
        vm.expectRevert(IndexController.InvalidConfiguration.selector);
        new IndexController(IM7Vault(address(0)), valuation);
        vm.expectRevert(IndexController.InvalidConfiguration.selector);
        new IndexController(IM7Vault(address(vault)), Valuation(address(0)));
    }
}
