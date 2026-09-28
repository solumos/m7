// SPDX-License-Identifier: Unlicense
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {M7Vault} from "../src/M7Vault.sol";
import {IndexController} from "../src/IndexController.sol";
import {Valuation, IAggregatorV3} from "../src/Valuation.sol";
import {IM7Vault} from "../src/interfaces/IM7Vault.sol";
import {ControllerToken, ControllerFeed, ControllerRegistry} from "./mocks/ControllerMocks.sol";
import {PolicyRegistryMock} from "./mocks/PolicyMocks.sol";
import {PricedVenue} from "./mocks/RouterMocks.sol";

/// @dev The equal-weight reset at realistic prices with the real vault and controller, against a venue whose prices
///      can deviate from the oracle and keep a haircut. The default vault holds $1M in equal value.
contract ControllerPlannerTest is Test {
    uint256 constant WAD = 1e18;
    uint256 constant THURSDAY = 1790870400; // Oct 1 2026 16:00 UTC
    address constant KEEPER = address(0xBEEF);
    uint256[7] PRICES = [uint256(340), 250, 343, 749, 518, 225, 372];

    M7Vault vault;
    IndexController controller;
    Valuation valuation;
    PricedVenue venue;
    IERC20[8] assets;
    ControllerFeed[8] feeds;
    uint256[7] seed;
    uint256[7] prices; // dollars with four extra decimals

    function setUp() public {
        _deploy(1_000_000);
    }

    /// A fresh system holding `navUsd` in equal value at PRICES.
    function _deploy(uint256 navUsd) private {
        vm.warp(THURSDAY);
        address[8] memory addresses;
        IAggregatorV3[8] memory aggregators;
        int24[7] memory spacings;
        for (uint256 i; i < 8; ++i) {
            addresses[i] = address(new ControllerToken(i == 7 ? 6 : 8));
            assets[i] = IERC20(addresses[i]);
            feeds[i] = new ControllerFeed(8, i == 7 ? int256(1e8) : int256(PRICES[i] * 1e8));
            aggregators[i] = feeds[i];
        }
        valuation = new Valuation(
            addresses, aggregators, new ControllerFeed(0, 0), new ControllerRegistry(), 25 hours
        );
        venue = new PricedVenue(addresses[7]);
        uint256[8] memory amounts;
        for (uint256 i; i < 7; ++i) {
            prices[i] = PRICES[i] * 1e4;
            spacings[i] = 10;
            venue.setPool(addresses[i], addresses[7], 10, true);
            venue.setRate(addresses[i], PRICES[i] * 1e16); // raw USDC per raw stock, 1e18-scaled
            seed[i] = navUsd * 1e8 / 7 / PRICES[i];
            amounts[i] = seed[i];
        }
        // Every contract created before the vault shifts its CREATE address, so create the registry first.
        PolicyRegistryMock registry = new PolicyRegistryMock();
        address predictedVault =
            vm.computeCreateAddress(address(this), uint256(vm.getNonce(address(this))) + 1);
        controller = new IndexController(IM7Vault(predictedVault), valuation);
        vault = new M7Vault(assets, spacings, address(controller), venue, venue, registry, address(this));
        for (uint256 i; i < 8; ++i) {
            ControllerToken(addresses[i]).mint(address(this), 1e20);
            ControllerToken(addresses[i]).mint(address(venue), 1e20);
            assets[i].approve(address(vault), type(uint256).max);
        }
        vault.bootstrap(amounts, address(this));
    }

    /// Moves stock `i` by `bps` in both the oracle and the venue.
    function _move(uint256 i, int256 bps) private {
        prices[i] = uint256(int256(PRICES[i]) * (10_000 + bps)) * 1e4 / 10_000; // 4 extra decimals
        feeds[i].set(int256(prices[i] * 1e4), block.timestamp);
        venue.setRate(address(assets[i]), prices[i] * 1e12);
    }

    /// A typical quarter's price moves.
    function _quarterOfMoves() private {
        int256[7] memory bps = [int256(500), -300, 200, -400, 100, 600, -200];
        for (uint256 i; i < 7; ++i) {
            _move(i, bps[i]);
        }
    }

    function _rebalance() private {
        controller.rebalance(block.timestamp, KEEPER);
    }

    /// Tranches half an hour apart, feeds reported fresh each time, until the quarter's reset completes.
    function _completeReset() private returns (uint256 tranches) {
        uint32 quarter = controller.currentQuarter();
        while (!controller.executedQuarter(quarter)) {
            if (tranches != 0) {
                vm.warp(block.timestamp + controller.TRANCHE_COOLDOWN());
                for (uint256 i; i < 8; ++i) {
                    feeds[i].set(feeds[i].answer(), block.timestamp);
                }
            }
            _rebalance();
            ++tranches;
        }
    }

    function _held() private view returns (uint256[8] memory held) {
        for (uint256 i; i < 8; ++i) {
            held[i] = vault.backing(i);
        }
    }

    function _values() private view returns (uint256[8] memory components, uint256 nav) {
        return valuation.values(_held(), valuation.snapshot());
    }

    function _assertEqualWeights(uint256 toleranceWad) private view {
        (uint256[8] memory components,) = _values();
        for (uint256 i = 1; i < 7; ++i) {
            assertApproxEqRel(components[i], components[0], toleranceWad, "not equal weight");
        }
    }

    /// Oracle value (1e18 USD) of every leg's input, from the venue's call log.
    function _traded() private view returns (uint256 traded) {
        for (uint256 k; k < venue.callCount(); ++k) {
            PricedVenue.Call memory call = venue.callAt(k);
            if (call.tokenIn == address(assets[7])) {
                traded += call.amountIn * 1e12;
            } else {
                for (uint256 i; i < 7; ++i) {
                    if (call.tokenIn == address(assets[i])) traded += call.amountIn * prices[i] * 1e6;
                }
            }
        }
    }

    function testSellsPrecedeBuysEachStockOnceThroughPinnedPools() public {
        _quarterOfMoves();
        _rebalance();
        bool buying;
        uint256 seen;
        for (uint256 k; k < venue.callCount(); ++k) {
            PricedVenue.Call memory call = venue.callAt(k);
            assertEq(call.tickSpacing, 10);
            bool isBuy = call.tokenIn == address(assets[7]);
            if (isBuy) buying = true;
            else assertFalse(buying, "a sale after a purchase");
            address stock = isBuy ? call.tokenOut : call.tokenIn;
            for (uint256 i; i < 7; ++i) {
                if (stock == address(assets[i])) {
                    assertEq(seen & (1 << i), 0, "stock traded twice");
                    seen |= 1 << i;
                }
            }
        }
        assertTrue(buying);
        _assertEqualWeights(0.003e18);
        assertTrue(controller.executedQuarter(controller.currentQuarter()), "every trade fit in one tranche");
        // 5 bp of the one-way traded value, about half of what the legs traded.
        assertApproxEqRel(assets[7].balanceOf(KEEPER) * 1e12, _traded() * 5 / 20_000, 0.01e18);
    }

    function testFuzzResetStaysWithinLossComplianceAndCashBounds(uint256 entropy) public {
        for (uint256 i; i < 7; ++i) {
            // Quarterly moves of +-20%, and pools within +-0.4% of the oracle.
            _move(i, int256(uint256(keccak256(abi.encode(entropy, "move", i))) % 4_001) - 2_000);
            uint256 deviation = 9_960 + uint256(keccak256(abi.encode(entropy, "pool", i))) % 81;
            venue.setRate(address(assets[i]), prices[i] * 1e12 * deviation / 10_000);
        }
        venue.setHaircuts(
            uint256(keccak256(abi.encode(entropy, "sell"))) % 31,
            uint256(keccak256(abi.encode(entropy, "buy"))) % 31
        );
        (, uint256 navBefore) = _values();
        uint256[8] memory before = _held();
        uint256 tranches = _completeReset();
        (, uint256 navAfter) = _values();
        uint256 reward = assets[7].balanceOf(KEEPER) * 1e12;
        // No trade above the $10k cap: moves above it took several tranches.
        _assertLegsCapped();
        if (tranches > 1) assertGt(_largestMove(before), 9_990e18, "an extra tranche without a capped leg");
        assertLe(
            navBefore - Math.min(navBefore, navAfter),
            _traded() / 100 + reward + 1e15,
            "loss beyond 1% plus reward"
        );
        _assertEqualWeights(0.004e18); // compliance is 30 bp of quantity; pool deviation adds a little value noise
        (uint256[8] memory components,) = _values();
        assertLe(components[7], navAfter / 10_000 + 0.07e18, "undeployed cash");
    }

    /// Sales stay within the $10k cap. Purchases spend the tranche's cash, so sales filled above the oracle can lift
    /// them slightly over it; the pools here sit at most 0.4% above.
    function _assertLegsCapped() private view {
        for (uint256 k; k < venue.callCount(); ++k) {
            PricedVenue.Call memory call = venue.callAt(k);
            if (call.tokenIn == address(assets[7])) {
                assertLe(call.amountIn * 1e12, 10_050e18, "a purchase above the $10k cap");
            }
            for (uint256 i; i < 7; ++i) {
                if (call.tokenIn == address(assets[i])) {
                    assertLe(call.amountIn * prices[i] * 1e6, 10_000e18, "a sale above the $10k cap");
                }
            }
        }
    }

    /// The oracle value of the largest single-stock move between `before` and now.
    function _largestMove(uint256[8] memory before) private view returns (uint256 largest) {
        uint256[8] memory held = _held();
        for (uint256 i; i < 7; ++i) {
            uint256 moved = held[i] > before[i] ? held[i] - before[i] : before[i] - held[i];
            largest = Math.max(largest, moved * prices[i] * 1e6);
        }
    }

    function testLossyVenueRevertsAtomically() public {
        _quarterOfMoves();
        venue.setHaircuts(0, 150); // purchases return 1.5% less than the oracle implies
        uint256[8] memory before = _held();
        vm.expectRevert("Too little received");
        _rebalance();
        uint256[8] memory held = _held();
        for (uint256 i; i < 8; ++i) {
            assertEq(held[i], before[i]);
        }
        assertTrue(controller.rebalanceDue());
        assertEq(assets[7].balanceOf(KEEPER), 0);
    }

    function testStockBelowPrecisionFloorIsRestoredAndIssuanceResumes() public {
        ControllerToken(address(assets[3])).burn(address(vault), seed[3] - 0.5e6); // seized below the floor
        vm.expectRevert(abi.encodeWithSelector(M7Vault.InsufficientLockedBacking.selector, 3));
        vault.quoteMint(1e18);
        _rebalance();
        uint256 total;
        uint256[8] memory held = _held();
        for (uint256 i; i < 7; ++i) {
            total += held[i];
        }
        assertApproxEqRel(held[3] * WAD / total, 0.0025e18, 0.01e18); // one minimum step back
        vault.quoteMint(1e18); // issuance is available again
    }

    function testCashBelowItsCapStaysAndLargerCashIsDeployed() public {
        require(assets[7].transfer(address(vault), 50e6)); // $50 is under 1 bp of $1M
        _rebalance();
        assertEq(venue.callCount(), 0);
        assertEq(assets[7].balanceOf(address(vault)), 50e6);
        assertEq(assets[7].balanceOf(KEEPER), 0); // nothing traded, nothing paid
    }

    function testLargeCashDonationIsDeployedEqually() public {
        require(assets[7].transfer(address(vault), 5_000e6));
        _rebalance();
        assertLe(assets[7].balanceOf(address(vault)), 100e6);
        _assertEqualWeights(0.003e18);
    }

    function testSmallVaultsResetToo() public {
        uint256[3] memory sizes = [uint256(100), 125, 250];
        for (uint256 s; s < 3; ++s) {
            _deploy(sizes[s]);
            _quarterOfMoves();
            _rebalance();
            _assertEqualWeights(0.004e18);
            assertFalse(controller.rebalanceDue());
        }
    }
}
