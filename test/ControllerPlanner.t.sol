// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {M7CapVault} from "../src/M7CapVault.sol";
import {IndexController} from "../src/IndexController.sol";
import {Valuation, IAggregatorV3} from "../src/Valuation.sol";
import {IM7CapVault} from "../src/interfaces/IM7CapVault.sol";
import {
    ControllerToken,
    ControllerFeed,
    ControllerRegistry,
    ControllerOracle
} from "./mocks/ControllerMocks.sol";
import {PolicyRegistryMock} from "./mocks/PolicyMocks.sol";
import {PricedVenue} from "./mocks/RouterMocks.sol";

/// @dev The on-chain planner at realistic scale: about $1M NAV, seven differently priced stocks, the real vault and
///      controller, and a venue whose prices can deviate from the oracle and keep a haircut.
contract ControllerPlannerTest is Test {
    uint256 constant WAD = 1e18;
    uint32 constant QUARTER = 2026 * 4 + 3;
    uint256[7] PRICES = [uint256(340), 250, 343, 749, 518, 225, 372];
    uint256[7] WEIGHT_BPS = [uint256(1900), 1200, 1200, 900, 2000, 2000, 800];

    M7CapVault vault;
    IndexController controller;
    Valuation valuation;
    ControllerOracle oracle;
    PricedVenue venue;
    IERC20[8] assets;
    ControllerFeed[8] feeds;
    uint256[7] seed;

    function setUp() public {
        vm.warp(1790870400); // Thursday Oct 1 2026 16:00 UTC
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
        oracle = new ControllerOracle();
        venue = new PricedVenue(addresses[7]);
        uint256[8] memory amounts;
        for (uint256 i; i < 7; ++i) {
            spacings[i] = 10;
            venue.setPool(addresses[i], addresses[7], 10, true);
            venue.setRate(addresses[i], PRICES[i] * 1e16); // raw USDC per raw stock, 1e18-scaled
            seed[i] = 1_000_000e8 * WEIGHT_BPS[i] / 10_000 / PRICES[i];
            amounts[i] = seed[i];
        }
        PolicyRegistryMock registry = new PolicyRegistryMock();
        address predictedVault =
            vm.computeCreateAddress(address(this), uint256(vm.getNonce(address(this))) + 1);
        controller = new IndexController(
            IM7CapVault(predictedVault),
            oracle,
            assets[7],
            1000e6,
            keccak256("methodology"),
            "ipfs://m",
            valuation
        );
        vault = new M7CapVault(assets, spacings, address(controller), venue, venue, registry, address(this));
        for (uint256 i; i < 8; ++i) {
            ControllerToken(addresses[i]).mint(address(this), 1e20);
            ControllerToken(addresses[i]).mint(address(venue), 1e20);
            assets[i].approve(address(vault), type(uint256).max);
        }
        assets[7].approve(address(controller), type(uint256).max);
        vault.bootstrap(amounts, address(this));
    }

    function _accept(uint256[7] memory ratios) private {
        bytes32 id = controller.propose(QUARTER, ratios, "ipfs://evidence", keccak256("observations"));
        vm.warp(1791216000); // Monday Oct 5 16:00 UTC
        for (uint256 i; i < 8; ++i) {
            feeds[i].set(i == 7 ? int256(1e8) : int256(PRICES[i] * 1e8), block.timestamp);
        }
        assertTrue(controller.settle(id));
    }

    function _held() private view returns (uint256[8] memory held) {
        for (uint256 i; i < 8; ++i) {
            held[i] = vault.backing(i);
        }
    }

    function _shares(uint256[8] memory held) private pure returns (uint256[7] memory shares) {
        uint256 total;
        for (uint256 i; i < 7; ++i) {
            total += held[i];
        }
        for (uint256 i; i < 7; ++i) {
            shares[i] = held[i] * WAD / total;
        }
    }

    function _normalize(uint256[7] memory quantities) private pure returns (uint256[7] memory ratios) {
        uint256 total;
        for (uint256 i; i < 7; ++i) {
            total += quantities[i];
        }
        uint256 assigned;
        for (uint256 i; i < 6; ++i) {
            ratios[i] = quantities[i] * WAD / total;
            assigned += ratios[i];
        }
        ratios[6] = WAD - assigned;
    }

    function _nav(uint256[8] memory held) private view returns (uint256 nav) {
        (, nav) = valuation.values(held, valuation.snapshot());
    }

    /// Oracle value (1e18 USD) of every leg's input, from the venue's call log.
    function _traded() private view returns (uint256 traded) {
        for (uint256 k; k < venue.callCount(); ++k) {
            PricedVenue.Call memory call = venue.callAt(k);
            if (call.tokenIn == address(assets[7])) {
                traded += call.amountIn * 1e12;
            } else {
                for (uint256 i; i < 7; ++i) {
                    if (call.tokenIn == address(assets[i])) traded += call.amountIn * PRICES[i] * 1e10;
                }
            }
        }
    }

    function testSellsPrecedeBuysEachStockOnceThroughPinnedPools() public {
        uint256[7] memory drift = [uint256(10_300), 10_000, 9_900, 10_150, 9_800, 10_100, 10_000];
        uint256[7] memory quantities;
        for (uint256 i; i < 7; ++i) {
            quantities[i] = seed[i] * drift[i] / 10_000;
        }
        uint256[7] memory ratios = _normalize(quantities);
        _accept(ratios);
        controller.execute(block.timestamp);

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
        uint256[7] memory shares = _shares(_held());
        for (uint256 i; i < 7; ++i) {
            // All drifts are inside one step, so the accepted ratios are reached within 30 bp.
            assertApproxEqRel(shares[i], ratios[i], 0.003e18);
        }
    }

    function testFuzzPlannerStaysWithinStepLossAndCashBounds(uint256 entropy) public {
        uint256[7] memory quantities;
        for (uint256 i; i < 7; ++i) {
            uint256 drift = 9_200 + uint256(keccak256(abi.encode(entropy, "drift", i))) % 1_601; // +-8%
            quantities[i] = seed[i] * drift / 10_000;
            uint256 deviation = 9_960 + uint256(keccak256(abi.encode(entropy, "pool", i))) % 81; // +-0.4%
            venue.setRate(address(assets[i]), PRICES[i] * 1e16 * deviation / 10_000);
        }
        venue.setHaircuts(
            uint256(keccak256(abi.encode(entropy, "sell"))) % 31,
            uint256(keccak256(abi.encode(entropy, "buy"))) % 31
        );
        _accept(_normalize(quantities));
        uint256[8] memory before = _held();
        uint256 navBefore = _nav(before);
        uint256[7] memory sharesBefore = _shares(before);

        controller.execute(block.timestamp);

        uint256[8] memory held = _held();
        uint256[7] memory shares = _shares(held);
        for (uint256 i; i < 7; ++i) {
            uint256 moved =
                shares[i] > sharesBefore[i] ? shares[i] - sharesBefore[i] : sharesBefore[i] - shares[i];
            uint256 bound = Math.max(sharesBefore[i] * 5 / 100, 0.0025e18);
            assertLe(moved, bound + sharesBefore[i] / 1_000, "a constituent moved more than one step");
        }
        uint256 navAfter = _nav(held);
        assertLe(
            navBefore - Math.min(navBefore, navAfter), _traded() / 100 + 1e15, "loss beyond 1% of traded"
        );
        assertLe(held[7] * 1e12, Math.max(navAfter / 10_000, 0.1e18), "undeployed cash");
    }

    function testLossyVenueRevertsAtomically() public {
        uint256[7] memory quantities = seed;
        quantities[0] = quantities[0] * 103 / 100;
        _accept(_normalize(quantities));
        venue.setHaircuts(0, 150); // purchases return 1.5% less than the oracle implies
        uint256[8] memory before = _held();
        vm.expectRevert("Too little received");
        controller.execute(block.timestamp);
        uint256[8] memory held = _held();
        for (uint256 i; i < 8; ++i) {
            assertEq(held[i], before[i]);
        }
        assertFalse(controller.executedQuarter(QUARTER));
    }

    function testStockBelowPrecisionFloorIsRestoredAndIssuanceResumes() public {
        uint256[7] memory ratios = _normalize(seed);
        ControllerToken(address(assets[3])).burn(address(vault), seed[3] - 0.5e6); // seized below the floor
        vm.expectRevert(abi.encodeWithSelector(M7CapVault.InsufficientLockedBacking.selector, 3));
        vault.quoteMint(1e18);
        _accept(ratios);
        controller.execute(block.timestamp);
        uint256[7] memory shares = _shares(_held());
        assertApproxEqRel(shares[3], 0.0025e18, 0.01e18); // one minimum step back toward its ratio
        vault.quoteMint(1e18); // issuance is available again
    }

    function testCashBelowItsCapStaysAndLargerCashIsDeployed() public {
        _accept(_normalize(seed));
        require(assets[7].transfer(address(vault), 50e6)); // $50 is under 1 bp of about $1M
        controller.execute(block.timestamp);
        assertEq(venue.callCount(), 0);
        assertEq(assets[7].balanceOf(address(vault)), 50e6);
    }

    function testLargeCashDonationIsDeployedProportionally() public {
        _accept(_normalize(seed));
        require(assets[7].transfer(address(vault), 5_000e6));
        controller.execute(block.timestamp);
        assertLe(assets[7].balanceOf(address(vault)), controller.MIN_LEG_USDC());
        uint256[7] memory shares = _shares(_held());
        uint256[7] memory ratios = _normalize(seed);
        for (uint256 i; i < 7; ++i) {
            assertApproxEqRel(shares[i], ratios[i], 0.003e18);
        }
    }
}
