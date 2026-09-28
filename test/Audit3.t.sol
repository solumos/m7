// SPDX-License-Identifier: Unlicense
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IndexController} from "../src/IndexController.sol";
import {Valuation, IAggregatorV3} from "../src/Valuation.sol";
import {IM7Vault} from "../src/interfaces/IM7Vault.sol";
import {
    ControllerToken,
    ControllerFeed,
    ControllerRegistry,
    ControllerVault
} from "./mocks/ControllerMocks.sol";

/// @dev Third review (docs/AUDIT-3.md): its reproductions, converted to regression tests of the fixed controller, against
///      the fair-value vault double.
contract Audit3Test is Test {
    IndexController controller;
    Valuation valuation;
    ControllerVault vault;
    address[8] assets;
    ControllerFeed[8] feeds;
    address constant KEEPER = address(0xBEEF);
    uint256 constant THU_OCT_1_2026_1600 = 1790870400;
    uint256 constant WED_DEC_30_2026_1600 = 1798646400;
    uint256 constant MON_JAN_4_2027_1600 = 1799078400;
    uint256 constant FRI_JAN_29_2027_1600 = 1801238400;

    /// @dev Seven stocks at `dollars` each, `raw` units of each held by the vault double (1,000 shares).
    function _deploy(uint256 dollars, uint256 raw) private {
        vm.warp(THU_OCT_1_2026_1600);
        IAggregatorV3[8] memory aggregators;
        for (uint256 i; i < 8; ++i) {
            assets[i] = address(new ControllerToken(i == 7 ? 6 : 8));
            feeds[i] = new ControllerFeed(8, i == 7 ? int256(1e8) : int256(dollars * 1e8));
            aggregators[i] = feeds[i];
        }
        valuation =
            new Valuation(assets, aggregators, new ControllerFeed(0, 0), new ControllerRegistry(), 25 hours);
        vault = new ControllerVault(assets, feeds);
        for (uint256 i; i < 7; ++i) {
            ControllerToken(assets[i]).mint(address(vault), raw);
        }
        controller = new IndexController(IM7Vault(address(vault)), valuation);
    }

    function _setPrice(uint256 index, int256 answer) private {
        feeds[index].set(answer, block.timestamp);
    }

    function _refreshFeeds() private {
        for (uint256 i; i < 8; ++i) {
            feeds[i].set(feeds[i].answer(), block.timestamp);
        }
    }

    /// @dev Half an hour on, or the next weekday's 15:00 UTC if that leaves the window, with every feed fresh.
    function _nextTranche() private {
        uint256 t = block.timestamp + controller.TRANCHE_COOLDOWN();
        if (t % 1 days >= 20 hours) t = (t / 1 days + 1) * 1 days + 15 hours;
        while ((t / 1 days + 4) % 7 == 0 || (t / 1 days + 4) % 7 == 6) {
            t += 1 days;
        }
        vm.warp(t);
        _refreshFeeds();
    }

    function _held(uint256 index) private view returns (uint256) {
        return ControllerToken(assets[index]).balanceOf(address(vault));
    }

    /// E-01: the pool check. With cash to invest, every stock is bought. A caller that pushes stock 0's price more than
    /// 25 ticks above its 10-minute average makes the tranche revert, near tick zero or far from it; a push of 25
    /// ticks does not.
    function testAudit3PushedPoolRefusesTheTranche() public {
        _deploy(100, 100e8);
        ControllerToken(assets[7]).mint(address(vault), 700e6);
        // A falling tick makes a stock dearer when USDC is token0, the lower address.
        int24 dearer = assets[7] < assets[0] ? int24(-1) : int24(1);
        uint256 snap = vm.snapshotState();
        vault.setTicks(26 * dearer, 0);
        vm.expectRevert(abi.encodeWithSelector(IndexController.PoolMoved.selector, 0));
        controller.rebalance(block.timestamp, KEEPER);
        vault.setTicks(26_000 + 26 * dearer, 26_000);
        vm.expectRevert(abi.encodeWithSelector(IndexController.PoolMoved.selector, 0));
        controller.rebalance(block.timestamp, KEEPER);
        vm.revertToState(snap);
        vault.setTicks(25 * dearer, 0);
        controller.rebalance(block.timestamp, KEEPER);
        assertEq(vault.calls(), 1);
    }

    /// E-02: a shortfall no longer fails the tranche. Every leg loses 0.5% and AMZN, after a 40% fall, buys 36% of its
    /// final holding; the tranche that reverted `NotCompliant` now trades, and a second tranche completes the quarter.
    function testAudit3LargePurchaseShortfallCompletesInALaterTranche() public {
        _deploy(100, 100e8);
        _setPrice(1, 60e8);
        vault.setOutputBps(9_950);
        controller.rebalance(block.timestamp, KEEPER);
        assertFalse(controller.executedQuarter(controller.currentQuarter()));
        _nextTranche();
        controller.rebalance(block.timestamp, KEEPER);
        assertTrue(controller.executedQuarter(controller.currentQuarter()));
    }

    /// E-03: no turnover fence. AAPL rises 11x, so the whole move sells over half of NAV; it now proceeds $10k a
    /// tranche and completes within the quarter.
    function testAudit3ElevenfoldMoveCompletesInTranches() public {
        _deploy(100, 100e8);
        _setPrice(0, 1_100e8);
        uint256 tranches;
        uint32 quarter = controller.currentQuarter();
        while (!controller.executedQuarter(quarter)) {
            if (tranches != 0) _nextTranche();
            controller.rebalance(block.timestamp, KEEPER);
            ++tranches;
        }
        assertEq(tranches, 9);
        uint256 value = _held(0) * 1_100;
        for (uint256 i = 1; i < 7; ++i) {
            assertApproxEqRel(_held(i) * 100, value, 0.001e18);
        }
    }

    /// E-04: a tranche that trades nothing pays nothing. $10 stocks, 0.12 of each ($8.40) and $0.05 of cash: AAPL moves
    /// 0.2%, so the basket leaves the deadband, but every trade would be under $0.01. Nothing trades, nothing is paid,
    /// and the quarter completes because nothing more can be done.
    function testAudit3TrancheThatTradesNothingPaysNothing() public {
        _deploy(10, 0.12e8);
        ControllerToken(assets[7]).mint(address(vault), 0.05e6);
        _setPrice(0, 10.02e8);
        controller.rebalance(block.timestamp, KEEPER);
        assertEq(vault.calls(), 0);
        assertEq(vault.rewardPaid(), 0);
        assertTrue(controller.executedQuarter(controller.currentQuarter()));
    }

    /// E-05/A4-01: an unfunded precision deficit fails explicitly, without consuming the quarter.
    function testAudit3EveryStockBelowTheFloorHasNothingToTrade() public {
        _deploy(100, 0.005e8); // floor is 0.01 token per 1,000 shares
        vm.expectRevert(IndexController.NoProgress.selector);
        controller.rebalance(block.timestamp, KEEPER);
        assertEq(vault.calls(), 0);
        assertFalse(controller.executedQuarter(controller.currentQuarter()));
    }

    /// E-06: a completed reset is followed by at least 30 days without one. After a reset on Wednesday December 30,
    /// Monday January 4 is refused and Friday January 29 is allowed.
    function testAudit3ResetsAreAtLeastThirtyDaysApart() public {
        _deploy(100, 100e8);
        vm.warp(WED_DEC_30_2026_1600);
        _refreshFeeds();
        _setPrice(0, 110e8);
        controller.rebalance(block.timestamp, KEEPER);
        assertEq(controller.lastExecutedQuarter(), 2026 * 4 + 3);

        vm.warp(MON_JAN_4_2027_1600);
        _refreshFeeds();
        _setPrice(1, 95e8);
        assertFalse(controller.rebalanceDue());
        vm.expectRevert(IndexController.TooSoon.selector);
        controller.rebalance(block.timestamp, KEEPER);

        vm.warp(FRI_JAN_29_2027_1600);
        _refreshFeeds();
        assertTrue(controller.rebalanceDue());
        controller.rebalance(block.timestamp, KEEPER);
        assertEq(controller.lastExecutedQuarter(), 2027 * 4);
    }

    /// E-07: a reward sent to the controller or the valuation could never move again, so the tranche refuses them.
    function testAudit3RewardSinksAreRefused() public {
        _deploy(100, 100e8);
        _setPrice(0, 110e8);
        vm.expectRevert(IndexController.InvalidConfiguration.selector);
        controller.rebalance(block.timestamp, address(controller));
        vm.expectRevert(IndexController.InvalidConfiguration.selector);
        controller.rebalance(block.timestamp, address(valuation));
        controller.rebalance(block.timestamp, KEEPER);
    }
}
