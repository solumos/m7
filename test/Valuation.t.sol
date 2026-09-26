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
        valuation = new Valuation(assets, feeds, sequencer, registry, 25 hours);
    }

    function testSnapshotNormalizesAndDoesNotMultiplyTwice() public {
        registry.setMultiplier(10e18);
        uint256[8] memory prices = valuation.snapshot();
        assertEq(prices[0], 200e18);
        assertEq(prices[7], 1e18);
        uint256[8] memory amounts;
        amounts[0] = 2e8;
        amounts[7] = 3e6;
        (uint256[8] memory values, uint256 total) = valuation.values(amounts, prices);
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
        Valuation mixed = new Valuation(assets, feeds, sequencer, registry, 25 hours);
        uint256[8] memory amounts;
        amounts[0] = 2e18;
        (, uint256 total) = mixed.values(amounts, mixed.snapshot());
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
        uint256[3] memory badTimestamps = [block.timestamp - 25 hours - 1, block.timestamp + 1, uint256(0)];
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

    function testWeekendAndOutsideWindowFailClosed() public {
        vm.warp(1791043200); // Saturday.
        vm.expectRevert(Valuation.OutsideExecutionWindow.selector);
        valuation.snapshot();
        vm.warp(1791216000 - 1 hours - 1); // Monday 14:59:59 UTC
        vm.expectRevert(Valuation.OutsideExecutionWindow.selector);
        valuation.snapshot();
        vm.warp(1791216000 + 4 hours); // Monday 20:00:00 UTC
        vm.expectRevert(Valuation.OutsideExecutionWindow.selector);
        valuation.snapshot();
        vm.warp(1791216000 + 4 hours - 1); // Monday 19:59:59 UTC is inside the widened window
        ControllerFeed(address(feeds[0])).set(200e8, block.timestamp);
        valuation.snapshot();
    }

    /// M-03: a quiet feed within its heartbeat no longer blocks, but at least one stock must be fresh.
    function testQuietFeedsPassWhileOneStockFeedIsFresh() public {
        for (uint256 i = 1; i < 7; ++i) {
            ControllerFeed(address(feeds[i])).set(200e8, block.timestamp - 24 hours - 59 minutes);
        }
        valuation.snapshot(); // stock 0 was published this second
        ControllerFeed(address(feeds[0])).set(200e8, block.timestamp - 1 hours - 1);
        vm.expectRevert(Valuation.NoFreshMarketSignal.selector);
        valuation.snapshot();
        ControllerFeed(address(feeds[0])).set(200e8, block.timestamp - 1 hours);
        valuation.snapshot();
        ControllerFeed(address(feeds[3])).set(200e8, block.timestamp - 25 hours - 1);
        vm.expectRevert(abi.encodeWithSelector(Valuation.UnavailablePrice.selector, 3));
        valuation.snapshot();
    }

    function testConfigurationBoundsFreshnessAndRejectsDuplicates() public {
        vm.expectRevert(Valuation.InvalidConfiguration.selector);
        new Valuation(assets, feeds, sequencer, registry, 25 hours + 1);
        vm.expectRevert(Valuation.InvalidConfiguration.selector);
        new Valuation(assets, feeds, sequencer, registry, 1 hours - 1);
        new Valuation(assets, feeds, sequencer, registry, 1 hours);
        assets[2] = assets[0];
        vm.expectRevert(Valuation.InvalidConfiguration.selector);
        new Valuation(assets, feeds, sequencer, registry, 25 hours);
    }
}
