// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {Valuation, IAggregatorV3} from "../src/Valuation.sol";
import {ControllerToken, ControllerFeed, ControllerRegistry} from "./mocks/ControllerMocks.sol";

contract ValuationTest is Test {
    Valuation valuation;
    address[8] assets;
    IAggregatorV3[8] feeds;
    ControllerFeed sequencer;
    ControllerRegistry registry;

    function setUp() public {
        vm.warp(1791216000); // Monday 2026-10-05 16:00 UTC.
        for (uint256 i; i < 8; ++i) {
            assets[i] = address(new ControllerToken(i == 7 ? 6 : 8));
            feeds[i] = new ControllerFeed(8, i == 7 ? int256(1e8) : int256(200e8));
        }
        sequencer = new ControllerFeed(0, 0);
        registry = new ControllerRegistry();
        valuation = new Valuation(assets, feeds, sequencer, registry, 1 hours);
    }

    function testSnapshotNormalizesAndDoesNotMultiplyTwice() public {
        registry.setMultiplier(10e18);
        uint256[8] memory prices = valuation.snapshot();
        assertEq(prices[0], 200e18);
        assertEq(prices[7], 1e18);
        ControllerToken(assets[0]).mint(address(this), 2e8);
        ControllerToken(assets[7]).mint(address(this), 3e6);
        (uint256[8] memory values, uint256 total) = valuation.values(address(this), prices);
        assertEq(values[0], 400e18);
        assertEq(values[7], 3e18);
        assertEq(total, 403e18);
    }

    function testUsdcIsNotAssumedToBeOneDollar() public {
        ControllerFeed(address(feeds[7])).set(95e6, block.timestamp);
        assertEq(valuation.snapshot()[7], 0.95e18);
    }

    function testUsdcUsesIts24HourHeartbeatPlusOneHourGrace() public {
        ControllerFeed feed = ControllerFeed(address(feeds[7]));
        feed.set(99e6, block.timestamp - 24 hours);
        assertEq(valuation.snapshot()[7], 0.99e18);
        feed.set(1e8, block.timestamp - 25 hours - 1);
        vm.expectRevert(abi.encodeWithSelector(Valuation.UnavailablePrice.selector, 7));
        valuation.snapshot();
    }

    function testMixedTokenAndFeedDecimals() public {
        assets[0] = address(new ControllerToken(18));
        feeds[0] = new ControllerFeed(6, 200e6);
        Valuation mixed = new Valuation(assets, feeds, sequencer, registry, 1 hours);
        ControllerToken(assets[0]).mint(address(this), 2e18);
        (, uint256 total) = mixed.values(address(this), mixed.snapshot());
        assertEq(total, 400e18);
    }

    function testPausedOrZeroMultiplierBlocksValuation() public {
        registry.setPaused(assets[3], true);
        vm.expectRevert(abi.encodeWithSelector(Valuation.CorporateAction.selector, 3));
        valuation.snapshot();
        registry.setPaused(assets[3], false);
        registry.setMultiplier(0);
        vm.expectRevert(abi.encodeWithSelector(Valuation.CorporateAction.selector, 0));
        valuation.snapshot();
    }

    function testStaleFutureNegativeAndIncompletePricesRejected() public {
        ControllerFeed feed = ControllerFeed(address(feeds[2]));
        uint256[3] memory badTimestamps = [block.timestamp - 1 hours - 1, block.timestamp + 1, uint256(0)];
        for (uint256 i; i < 3; ++i) {
            feed.set(200e8, badTimestamps[i]);
            vm.expectRevert(abi.encodeWithSelector(Valuation.UnavailablePrice.selector, 2));
            valuation.snapshot();
        }
        feed.set(-1, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(Valuation.UnavailablePrice.selector, 2));
        valuation.snapshot();
        feed.set(200e8, block.timestamp);
        feed.setRounds(2, 1);
        vm.expectRevert(abi.encodeWithSelector(Valuation.UnavailablePrice.selector, 2));
        valuation.snapshot();
    }

    function testSequencerDownUninitializedFutureAndRecoveryGrace() public {
        sequencer.set(1, block.timestamp);
        vm.expectRevert(Valuation.SequencerUnavailable.selector);
        valuation.snapshot();
        sequencer.set(0, block.timestamp);
        uint256[4] memory badStarts =
            [uint256(0), block.timestamp + 1, block.timestamp, block.timestamp - 1 hours];
        for (uint256 i; i < 4; ++i) {
            sequencer.setStartedAt(badStarts[i]);
            vm.expectRevert(Valuation.SequencerUnavailable.selector);
            valuation.snapshot();
        }
    }

    function testWeekendAndOutsideConservativeWindowFailClosed() public {
        vm.warp(1791043200); // Saturday.
        vm.expectRevert(Valuation.OutsideExecutionWindow.selector);
        valuation.snapshot();
        vm.warp(1791216000 + 1 hours);
        vm.expectRevert(Valuation.OutsideExecutionWindow.selector);
        valuation.snapshot();
        vm.warp(1791216000 - 2 hours);
        vm.expectRevert(Valuation.OutsideExecutionWindow.selector);
        valuation.snapshot();
    }

    function testConfigurationRejectsUnsafeFreshnessAndDuplicates() public {
        vm.expectRevert(Valuation.InvalidConfiguration.selector);
        new Valuation(assets, feeds, sequencer, registry, 1 hours + 1);
        assets[2] = assets[0];
        vm.expectRevert(Valuation.InvalidConfiguration.selector);
        new Valuation(assets, feeds, sequencer, registry, 1 hours);
    }
}
