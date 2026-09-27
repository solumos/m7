// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {M7CapVault} from "../src/M7CapVault.sol";
import {M7CapLens} from "../src/M7CapLens.sol";
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

/// @dev Price per share from the latest oracle prices, readable at any time, including outside the rebalance window.
contract M7CapLensTest is Test {
    uint256[7] PRICES = [uint256(340), 250, 343, 749, 518, 225, 372];

    M7CapVault vault;
    IndexController controller;
    Valuation valuation;
    M7CapLens lens;
    IERC20[8] assets;
    ControllerFeed[8] feeds;
    ControllerFeed sequencer;
    ControllerRegistry registry;
    uint256[8] seed;

    function setUp() public {
        vm.warp(1790870400); // Thursday Oct 1 2026 16:00 UTC
        address[8] memory addresses;
        IAggregatorV3[8] memory aggregators;
        int24[7] memory spacings;
        for (uint256 i; i < 8; ++i) {
            addresses[i] = address(new ControllerToken(i == 7 ? 6 : 8));
            assets[i] = IERC20(addresses[i]);
            feeds[i] = new ControllerFeed(8, i == 7 ? int256(0.9999e8) : int256(PRICES[i] * 1e8));
            aggregators[i] = feeds[i];
        }
        sequencer = new ControllerFeed(0, 0);
        registry = new ControllerRegistry();
        valuation = new Valuation(addresses, aggregators, sequencer, registry, 25 hours);
        PricedVenue venue = new PricedVenue(addresses[7]);
        for (uint256 i; i < 7; ++i) {
            spacings[i] = 10;
            venue.setPool(addresses[i], addresses[7], 10, true);
            seed[i] = (i + 1) * 1e8; // 1, 2, ... 7 whole tokens
        }
        // Every contract created before the vault shifts its CREATE address, so create the mocks first.
        ControllerOracle oracle = new ControllerOracle();
        PolicyRegistryMock policies = new PolicyRegistryMock();
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
        vault = new M7CapVault(assets, spacings, address(controller), venue, venue, policies, address(this));
        lens = new M7CapLens(controller);
        for (uint256 i; i < 8; ++i) {
            ControllerToken(addresses[i]).mint(address(this), 1e20);
            assets[i].approve(address(vault), type(uint256).max);
        }
    }

    /// Sum over stocks of whole tokens times the whole-dollar price, in 18-decimal USD.
    function _seedValue() private view returns (uint256 total) {
        for (uint256 i; i < 7; ++i) {
            total += seed[i] * PRICES[i] * 1e10;
        }
    }

    function testUnseededVaultHasNoPricePerShare() public view {
        (uint256 perShare,) = lens.pricePerShare();
        assertEq(perShare, 0);
        (uint256 total,) = lens.totalValue();
        assertEq(total, 0);
    }

    function testPricePerShareIsBackingValueOverSupply() public {
        vault.bootstrap(seed, address(this));
        M7CapLens.Value memory v = lens.value();
        assertEq(v.supply, 1_000e18);
        assertEq(v.nav, _seedValue());
        assertEq(v.perShare, _seedValue() / 1_000);
        (uint256 total, uint256 oldest) = lens.totalValue();
        assertEq(total, _seedValue());
        assertEq(oldest, block.timestamp);
        for (uint256 i; i < 7; ++i) {
            assertEq(v.components[i], seed[i] * PRICES[i] * 1e10);
        }
        assertEq(v.components[7], 0);
        assertEq(v.oldestPriceAt, block.timestamp);
        assertFalse(v.issuerPaused);
        assertFalse(v.sequencerDown);

        // Donated USDC is backing, valued at the USDC feed, and raises every share's value.
        require(assets[7].transfer(address(vault), 100e6));
        v = lens.value();
        assertEq(v.components[7], 99.99e18);
        assertEq(v.perShare, (_seedValue() + 99.99e18) / 1_000);
    }

    function testReadableOutsideTheRebalanceWindowWithItsStalestPriceTime() public {
        vault.bootstrap(seed, address(this));
        feeds[3].set(int256(PRICES[3] * 1e8), block.timestamp - 3 days);
        vm.warp(1791043200); // Saturday Oct 3 2026 16:00 UTC: snapshot() refuses, the lens still reads
        vm.expectRevert(Valuation.OutsideExecutionWindow.selector);
        valuation.snapshot();
        (uint256 perShare, uint256 oldestPriceAt) = lens.pricePerShare();
        assertEq(perShare, _seedValue() / 1_000);
        assertEq(oldestPriceAt, 1790870400 - 3 days);
    }

    function testReportsIssuerPauseAndSequencerOutage() public {
        vault.bootstrap(seed, address(this));
        registry.setPaused(address(assets[2]), true);
        sequencer.set(1, block.timestamp);
        M7CapLens.Value memory v = lens.value();
        assertTrue(v.issuerPaused);
        assertTrue(v.sequencerDown);
        assertEq(v.perShare, _seedValue() / 1_000); // flags inform; they do not change the arithmetic
    }

    function testInvalidPriceReverts() public {
        vault.bootstrap(seed, address(this));
        feeds[5].set(0, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(M7CapLens.InvalidPrice.selector, 5));
        lens.value();
    }

    function testRejectsMismatchedValuation() public {
        address[8] memory other;
        IAggregatorV3[8] memory aggregators;
        for (uint256 i; i < 8; ++i) {
            other[i] = address(new ControllerToken(i == 7 ? 6 : 8));
            aggregators[i] = feeds[i];
        }
        Valuation wrong = new Valuation(other, aggregators, sequencer, registry, 25 hours);
        IndexController mismatched = new IndexController(
            IM7CapVault(address(vault)),
            new ControllerOracle(),
            assets[7],
            1000e6,
            keccak256("methodology"),
            "ipfs://m",
            wrong
        );
        vm.expectRevert(M7CapLens.InvalidConfiguration.selector);
        new M7CapLens(mismatched);
    }
}
