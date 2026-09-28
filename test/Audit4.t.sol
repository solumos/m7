// SPDX-License-Identifier: Unlicense
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {M7Vault} from "../src/M7Vault.sol";
import {IndexController} from "../src/IndexController.sol";
import {Valuation, IAggregatorV3} from "../src/Valuation.sol";
import {IM7Vault} from "../src/interfaces/IM7Vault.sol";
import {ControllerToken, ControllerFeed, ControllerRegistry} from "./mocks/ControllerMocks.sol";
import {PolicyRegistryMock} from "./mocks/PolicyMocks.sol";
import {PricedVenue} from "./mocks/RouterMocks.sol";

contract Audit4Test is Test {
    M7Vault vault;
    IndexController controller;
    PricedVenue venue;
    ControllerToken[8] tokens;
    ControllerFeed[8] feeds;

    function setUp() public {
        _deploy(125e6);
    }

    function _deploy(uint256 seedUSDC) private {
        vm.warp(1790870400); // Thursday, October 1, 2026, 16:00 UTC.
        address[8] memory addresses;
        IERC20[8] memory assets;
        IAggregatorV3[8] memory aggregators;
        int24[7] memory spacings;
        uint256[8] memory seed;
        for (uint256 i; i < 8; ++i) {
            tokens[i] = new ControllerToken(i == 7 ? 6 : 8);
            addresses[i] = address(tokens[i]);
            assets[i] = IERC20(addresses[i]);
            feeds[i] = new ControllerFeed(8, i == 7 ? int256(1e8) : int256(100e8));
            aggregators[i] = feeds[i];
        }
        Valuation valuation = new Valuation(
            addresses, aggregators, new ControllerFeed(0, 0), new ControllerRegistry(), 25 hours
        );
        venue = new PricedVenue(addresses[7]);
        for (uint256 i; i < 7; ++i) {
            spacings[i] = 10;
            venue.setPool(addresses[i], addresses[7], 10, true);
            venue.setRate(addresses[i], 1e18);
            seed[i] = seedUSDC / 7; // Equal value in seven $100 stocks (1:1 raw stock/USDC).
        }
        PolicyRegistryMock registry = new PolicyRegistryMock();
        address predicted = vm.computeCreateAddress(address(this), uint256(vm.getNonce(address(this))) + 1);
        controller = new IndexController(IM7Vault(predicted), valuation);
        vault = new M7Vault(assets, spacings, address(controller), venue, venue, registry, address(this));
        for (uint256 i; i < 8; ++i) {
            tokens[i].mint(address(this), seed[i]);
            tokens[i].mint(address(venue), 1e20);
            tokens[i].approve(address(vault), type(uint256).max);
        }
        vault.bootstrap(seed, address(this));
    }

    function testSeizedStockIsRebuiltBeforeSmallVaultCompletes() public {
        tokens[0].burn(address(vault), vault.backing(0));
        vm.expectRevert(abi.encodeWithSelector(M7Vault.MissingComponent.selector, 0));
        vault.quoteMint(1e18);

        controller.rebalance(block.timestamp, address(0));
        assertGt(vault.backing(0), 0, "the reset skipped the missing stock");
        assertFalse(controller.executedQuarter(controller.currentQuarter()), "premature completion");
        for (uint256 k; k < 30 && !controller.executedQuarter(controller.currentQuarter()); ++k) {
            _nextTranche();
            controller.rebalance(block.timestamp, address(0));
        }
        assertTrue(controller.executedQuarter(controller.currentQuarter()), "recovery did not finish");
        vault.quoteMint(1e18);
        for (uint256 i = 1; i < 7; ++i) {
            assertApproxEqRel(vault.backing(i), vault.backing(0), 0.001e18);
        }
    }

    function testFuzzPartialSeizureRecoveryWithReward(uint32 remainingRaw) public {
        _recoverPartialSeizure(bound(uint256(remainingRaw), 1, 999_999));
    }

    function testPartialSeizureRecoveryCompletesWithOnlyDustSales() public {
        // Shipping-preflight counterexample: the six funding sales each finish below $0.01.
        _recoverPartialSeizure(963_181);
        assertGt(vault.backing(1) - vault.backing(0), vault.backing(0) / 1000);
        assertEq(vault.backing(7), 0);
    }

    function _recoverPartialSeizure(uint256 remaining) private {
        tokens[0].burn(address(vault), vault.backing(0) - remaining);
        for (uint256 k; k < 30 && !controller.executedQuarter(controller.currentQuarter()); ++k) {
            if (k != 0) _nextTranche();
            controller.rebalance(block.timestamp, address(0xBEEF));
        }
        assertTrue(controller.executedQuarter(controller.currentQuarter()), "recovery did not finish");
        vault.quoteMint(1e18);
        uint256 high = vault.backing(0);
        uint256 low = high;
        uint256 total = high + vault.backing(7);
        for (uint256 i = 1; i < 7; ++i) {
            uint256 held = vault.backing(i);
            total += held;
            if (held > high) high = held;
            if (held < low) low = held;
        }
        if (high - low > low * controller.DEADBAND_BPS() / controller.BPS()) {
            // In this $100-stock fixture each raw stock unit equals one raw USDC unit.
            // Completion outside the deadband is valid only when cash cannot fund a purchase
            // and every remaining sale needed for equal value is below the minimum trade.
            assertLt(vault.backing(7), controller.MIN_LEG_USDC(), "unspent executable cash");
            uint256 target = total / 7;
            for (uint256 i; i < 7; ++i) {
                uint256 held = vault.backing(i);
                if (held > target) {
                    assertLt(held - target, controller.MIN_LEG_USDC(), "executable surplus remains");
                }
            }
        }
    }

    function testFloorConstrainedStockSellsItsAvailableSurplus() public {
        _deploy(14e6); // 0.02 of each stock; the precision floor is 0.01.
        feeds[0].set(1_000e8, block.timestamp);
        venue.setRate(address(tokens[0]), 10e18);
        controller.rebalance(block.timestamp, address(0));
        assertEq(vault.backing(0), 1e6, "sellable surplus was ignored");
        assertGt(vault.backing(1), 2e6, "the other stocks did not receive the proceeds");
        assertTrue(controller.executedQuarter(controller.currentQuarter()));
        vault.quoteMint(1e18);
    }

    function testUnfundedPrecisionDeficitDoesNotConsumeQuarter() public {
        for (uint256 i; i < 7; ++i) {
            tokens[i].burn(address(vault), vault.backing(i) - 0.005e8);
        }
        vm.expectRevert(IndexController.NoProgress.selector);
        controller.rebalance(block.timestamp, address(0));
        assertFalse(controller.executedQuarter(controller.currentQuarter()));
        assertEq(controller.lastTrancheAt(), 0);
        assertTrue(controller.rebalanceDue());
    }

    function _nextTranche() private {
        uint256 t = block.timestamp + controller.TRANCHE_COOLDOWN();
        if (t % 1 days >= 20 hours) t = (t / 1 days + 1) * 1 days + 15 hours;
        while ((t / 1 days + 4) % 7 == 0 || (t / 1 days + 4) % 7 == 6) t += 1 days;
        vm.warp(t);
        for (uint256 i; i < 8; ++i) {
            feeds[i].set(feeds[i].answer(), t);
        }
    }
}
