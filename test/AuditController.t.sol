// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {M7Vault} from "../src/M7Vault.sol";
import {IndexController} from "../src/IndexController.sol";
import {Valuation, IAggregatorV3} from "../src/Valuation.sol";
import {IM7Vault} from "../src/interfaces/IM7Vault.sol";
import {ISlipstreamRouter, ISlipstreamFactory} from "../src/interfaces/ISlipstreamRouter.sol";
import {PolicyRegistryMock} from "./mocks/PolicyMocks.sol";
import {ControllerToken, ControllerFeed, ControllerRegistry} from "./mocks/ControllerMocks.sol";
import {PoolOracleMock} from "./mocks/PoolOracleMock.sol";

/// @dev Models a funded, attacker-owned pool reached through the immutable router.
///      This is not a native Aerodrome fork: it isolates the controller's acceptance of
///      unnecessary round trips that transfer the full permitted NAV loss to a venue.
contract AuditControllerVenue is ISlipstreamRouter, ISlipstreamFactory, PoolOracleMock {
    address public immutable usdc;

    constructor(address usdc_) {
        usdc = usdc_;
    }

    function factory() external view returns (address) {
        return address(this);
    }

    function getPool(address, address, int24) external view returns (address) {
        return address(this);
    }

    function exactInputSingle(ExactInputSingleParams calldata p)
        external
        payable
        returns (uint256 amountOut)
    {
        // $100 stocks with 8 decimals have the same raw unit value as 6-decimal USDC.
        amountOut = p.tokenIn == usdc ? p.amountIn * 995 / 1000 : p.amountIn;
        require(amountOut >= p.amountOutMinimum, "slippage");
        require(IERC20(p.tokenIn).transferFrom(msg.sender, address(this), p.amountIn));
        require(IERC20(p.tokenOut).transfer(p.recipient, amountOut));
    }

    function exactOutputSingle(ExactOutputSingleParams calldata) external payable returns (uint256) {
        revert("unused");
    }
}

/// @dev First-review reproductions, converted to regressions after the fixes (docs/AUDIT.md).
contract AuditControllerTest is Test {
    M7Vault vault;
    IndexController controller;
    Valuation valuation;
    AuditControllerVenue venue;
    IERC20[8] assets;
    IAggregatorV3[8] feeds;
    uint32 constant QUARTER = 2026 * 4 + 3;

    function setUp() public {
        vm.warp(1790870400); // Thursday October 1, 2026 16:00 UTC.
        address[8] memory addresses;
        uint256[8] memory seed;
        int24[7] memory spacings;
        for (uint256 i; i < 8; ++i) {
            addresses[i] = address(new ControllerToken(i == 7 ? 6 : 8));
            assets[i] = IERC20(addresses[i]);
            feeds[i] = new ControllerFeed(8, i == 7 ? int256(1e8) : int256(100e8));
            if (i < 7) {
                seed[i] = 100e8;
                spacings[i] = 100;
            }
        }
        valuation =
            new Valuation(addresses, feeds, new ControllerFeed(0, 0), new ControllerRegistry(), 25 hours);
        venue = new AuditControllerVenue(address(assets[7]));
        PolicyRegistryMock registry = new PolicyRegistryMock();
        address predictedVault =
            vm.computeCreateAddress(address(this), uint256(vm.getNonce(address(this))) + 1);
        controller = new IndexController(IM7Vault(predictedVault), valuation);
        vault = new M7Vault(assets, spacings, address(controller), venue, venue, registry, address(this));
        assertEq(address(vault), predictedVault);
        for (uint256 i; i < 7; ++i) {
            ControllerToken(addresses[i]).mint(address(this), seed[i]);
            ControllerToken(addresses[i]).mint(address(venue), 1000e8);
            assets[i].approve(address(vault), seed[i]);
        }
        ControllerToken(addresses[7]).mint(address(venue), 10000e6);
        vault.bootstrap(seed, address(this));
    }

    function _refresh() private {
        for (uint256 i; i < 8; ++i) {
            ControllerFeed(address(feeds[i])).set(i == 7 ? int256(1e8) : int256(100e8), block.timestamp);
        }
    }

    function _nav() private view returns (uint256 nav) {
        uint256[8] memory held;
        for (uint256 i; i < 8; ++i) {
            held[i] = vault.backing(i);
        }
        (, nav) = valuation.values(held, valuation.snapshot());
    }

    // M-02 regression: callers choose no legs, so an equal-weight vault trades nothing and loses nothing.
    function testCallerCannotSpendLossAllowanceOnUnnecessaryTrades() public {
        uint256 navBefore = _nav();
        vm.prank(address(0xBAD)); // No shares, role, bond, or approval is needed to trigger the reset.
        controller.rebalance(block.timestamp, address(0xBAD));
        assertEq(_nav(), navBefore); // formerly $350 of $70,000 went to the venue
        for (uint256 i; i < 7; ++i) {
            assertEq(assets[i].balanceOf(address(vault)), 100e8);
            assertEq(assets[i].balanceOf(address(venue)), 1000e8);
        }
        assertEq(assets[7].balanceOf(address(0xBAD)), 0); // no trade, no reward
        assertTrue(controller.executedQuarter(QUARTER));
    }

    function testLossIsBoundedByNeededTurnoverThroughAnExtractiveVenue() public {
        // Five extra tokens of stock 0 make it overweight: $428.57 must move to the other six.
        ControllerToken(address(assets[0])).mint(address(vault), 5e8);
        uint256 navBefore = _nav();
        controller.rebalance(block.timestamp, address(this));
        uint256 reward = assets[7].balanceOf(address(this)) * 1e12;
        assertApproxEqAbs(reward, 0.214285e18, 1e12); // 5 bp of the $428.57 traded
        // Only the needed turnover trades: each stock ends at $10,071.40, a seventh of NAV after the reward, and the
        // venue keeps 0.5% of the $428.39 bought, not 50 bp of NAV.
        assertApproxEqAbs(navBefore - _nav(), 428.39e18 * 5 / 1000 + reward, 0.01e18);
        assertApproxEqAbs(assets[0].balanceOf(address(vault)), 100.71398e8, 0.0001e8);
    }

    // M-03 regression: a heartbeat-conforming quiet feed no longer blocks the window.
    function testQuietButHeartbeatConformingFeedNoLongerBlocksExecution() public {
        vm.warp(block.timestamp + 23 hours); // Friday 15:00 UTC, the start of the window
        _refresh();
        ControllerFeed(address(feeds[0])).set(100e8, block.timestamp - 3 hours); // last update at 12:00
        controller.rebalance(block.timestamp, address(0));
        assertTrue(controller.executedQuarter(QUARTER));
    }
}
