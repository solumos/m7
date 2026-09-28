// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test, stdError} from "forge-std/Test.sol";
import {IndexController} from "../src/IndexController.sol";
import {Valuation, IAggregatorV3} from "../src/Valuation.sol";
import {IM7Vault} from "../src/interfaces/IM7Vault.sol";
import {
    ControllerToken,
    ControllerFeed,
    ControllerRegistry,
    ControllerVault
} from "./mocks/ControllerMocks.sol";

/// @dev Third review (docs/AUDIT-3.md): reproductions of the controller findings against the fair-value vault double.
///      Each test asserts the behavior as reviewed at 54b02e8.
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

    /// I-01: the reward is paid whenever the basket is outside the 10 bp deadband, even when every leg is then skipped
    /// as dust. $10 stocks, 0.12 of each ($8.40) and $0.05 of cash: AAPL moves 0.2%, so the reset leaves the deadband,
    /// but every buy is under $0.01. It trades nothing and still pays the caller.
    function testAudit3RewardIsPaidByAResetThatTradesNothing() public {
        _deploy(10, 0.12e8);
        ControllerToken(assets[7]).mint(address(vault), 0.05e6);
        _setPrice(0, 10.02e8);
        controller.rebalance(block.timestamp, KEEPER);
        assertEq(vault.calls(), 0, "no swap was executed");
        assertEq(vault.legCount(), 0);
        assertGt(vault.rewardPaid(), 0, "the caller was still paid");
        assertEq(ControllerToken(assets[7]).balanceOf(KEEPER), vault.rewardPaid());
        assertTrue(controller.executedQuarter(controller.currentQuarter()));
    }

    /// I-02: when every stock is below the precision floor (only possible after issuer seizures of all seven), each is
    /// excluded from the compliance check and `_compliant` multiplies type(uint256).max: the reset panics instead of
    /// reverting with a named error.
    function testAudit3EveryStockBelowTheFloorPanics() public {
        _deploy(100, 0.005e8); // floor is 0.01 token per 1,000 shares
        vm.expectRevert(stdError.arithmeticError);
        controller.rebalance(block.timestamp, KEEPER);
    }

    /// I-03: "once per calendar quarter" allows two resets five days apart around a quarter boundary, each paying the
    /// reward and trading costs.
    function testAudit3TwoResetsFiveDaysApartAcrossAQuarterBoundary() public {
        _deploy(100, 100e8);
        vm.warp(WED_DEC_30_2026_1600);
        _refreshFeeds();
        _setPrice(0, 110e8);
        controller.rebalance(block.timestamp, KEEPER);
        uint256 firstReward = vault.rewardPaid();
        assertGt(firstReward, 0);

        vm.warp(MON_JAN_4_2027_1600);
        _refreshFeeds();
        _setPrice(1, 95e8);
        controller.rebalance(block.timestamp, KEEPER);
        assertGt(vault.rewardPaid(), firstReward, "a second reward five days later");
        assertEq(controller.lastExecutedQuarter(), 2027 * 4);
    }

    /// M-01 (compliance part): every leg loses 0.5%, half the 1% minimum, and the total loss is about half the
    /// allowance, yet the reset fails. AMZN falls 40%, so it must buy 36% of its final holding; its shortfall
    /// (0.5% on the purchase plus the sales' 0.5% cash shortfall, times 36%) exceeds the 30 bp compliance band. At 0.25%
    /// per leg the same reset passes.
    function testAudit3LargePurchaseFailsComplianceInsideTheLegMinimums() public {
        _deploy(100, 100e8);
        _setPrice(1, 60e8);
        vault.setOutputBps(9_950);
        vm.expectRevert(IndexController.NotCompliant.selector);
        controller.rebalance(block.timestamp, KEEPER);

        vault.setOutputBps(9_975);
        controller.rebalance(block.timestamp, KEEPER);
        assertTrue(controller.executedQuarter(controller.currentQuarter()));
    }

    /// L-02: the turnover fence blocks the whole reset instead of limiting it. Once one stock is worth more than about
    /// 64% of NAV (here AAPL rises 11x against the others), the full reset would sell over half of NAV. The step bound
    /// limits quantity shares, which a price move leaves unchanged, so it does not help, and every later quarter fails
    /// the same way until prices revert.
    function testAudit3TurnoverFenceBlocksEveryResetAfterAnElevenfoldMove() public {
        _deploy(100, 100e8);
        _setPrice(0, 1_100e8);
        vm.expectRevert(IndexController.ExcessTurnover.selector);
        controller.rebalance(block.timestamp, KEEPER);

        vm.warp(MON_JAN_4_2027_1600);
        _refreshFeeds();
        vm.expectRevert(IndexController.ExcessTurnover.selector);
        controller.rebalance(block.timestamp, KEEPER);
        assertTrue(controller.rebalanceDue(), "no reset has run since the move");

        // Just under the threshold (10x), the same reset is allowed and sells just under half of NAV.
        _setPrice(0, 1_000e8);
        controller.rebalance(block.timestamp, KEEPER);
        assertEq(vault.calls(), 2);
    }
}
