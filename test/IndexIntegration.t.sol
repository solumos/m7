// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {M7Vault} from "../src/M7Vault.sol";
import {IndexController} from "../src/IndexController.sol";
import {Valuation, IAggregatorV3} from "../src/Valuation.sol";
import {IM7Vault} from "../src/interfaces/IM7Vault.sol";
import {ISlipstreamRouter, ISlipstreamFactory} from "../src/interfaces/ISlipstreamRouter.sol";
import {PolicyRegistryMock} from "./mocks/PolicyMocks.sol";
import {ControllerToken, ControllerFeed, ControllerRegistry} from "./mocks/ControllerMocks.sol";
import {PoolOracleMock} from "./mocks/PoolOracleMock.sol";

/// @dev A funded external venue: $100 stocks with 8 decimals exchange 1:1 raw units against 6-decimal USDC.
contract IndexIntegrationRouter is ISlipstreamRouter, ISlipstreamFactory, PoolOracleMock {
    uint256 public calls;
    uint256 public secondTradeOutputBps = 10000;
    bool public failSecond;
    bool public reenter;

    function factory() external view returns (address) {
        return address(this);
    }

    function getPool(address, address, int24) external view returns (address) {
        return address(this);
    }

    function configure(uint256 outputBps, bool failSecond_, bool reenter_) external {
        secondTradeOutputBps = outputBps;
        failSecond = failSecond_;
        reenter = reenter_;
    }

    function exactInputSingle(ExactInputSingleParams calldata p)
        external
        payable
        returns (uint256 amountOut)
    {
        ++calls;
        require(p.recipient == msg.sender && p.deadline >= block.timestamp, "route");
        require(!(failSecond && calls == 2), "second swap failed");
        if (reenter) {
            uint256[8] memory amounts;
            IM7Vault(msg.sender).mintBasket(1, amounts, address(this), block.timestamp);
        }
        require(IERC20(p.tokenIn).transferFrom(msg.sender, address(this), p.amountIn));
        amountOut = calls == 2 ? p.amountIn * secondTradeOutputBps / 10000 : p.amountIn;
        require(amountOut >= p.amountOutMinimum, "slippage");
        require(IERC20(p.tokenOut).transfer(p.recipient, amountOut));
    }

    function exactOutputSingle(ExactOutputSingleParams calldata) external payable returns (uint256) {
        revert("unused");
    }
}

contract IndexIntegrationTest is Test {
    M7Vault vault;
    IndexController controller;
    Valuation valuation;
    IndexIntegrationRouter router;
    IERC20[8] assets;
    IAggregatorV3[8] feeds;
    ControllerFeed sequencer;
    uint32 constant QUARTER = 2026 * 4 + 3;

    function setUp() public {
        vm.warp(1790870400); // Thursday Oct 1 2026.
        address[8] memory addresses;
        uint256[8] memory seed;
        for (uint256 i; i < 8; ++i) {
            addresses[i] = address(new ControllerToken(i == 7 ? 6 : 8));
            assets[i] = IERC20(addresses[i]);
            ControllerToken(addresses[i]).mint(address(this), 1e15);
            feeds[i] = new ControllerFeed(8, i == 7 ? int256(1e8) : int256(100e8));
            if (i < 7) seed[i] = 100e8;
        }
        seed[0] = 110e8;
        seed[1] = 90e8;
        sequencer = new ControllerFeed(0, 0);
        valuation = new Valuation(addresses, feeds, sequencer, new ControllerRegistry(), 25 hours);
        router = new IndexIntegrationRouter();
        PolicyRegistryMock registry = new PolicyRegistryMock();
        address predictedVault =
            vm.computeCreateAddress(address(this), uint256(vm.getNonce(address(this))) + 1);
        controller = new IndexController(IM7Vault(predictedVault), valuation);
        int24[7] memory spacings;
        for (uint256 i; i < 7; ++i) {
            spacings[i] = 100;
        }
        vault = new M7Vault(assets, spacings, address(controller), router, router, registry, address(this));
        assertEq(address(vault), predictedVault);
        for (uint256 i; i < 8; ++i) {
            assets[i].approve(address(vault), type(uint256).max);
            require(assets[i].transfer(address(router), 1e12));
        }
        vault.bootstrap(seed, address(this));
    }

    /// The 110/90 seed resets to equal value: stock 0 sells 10 tokens and stock 1 buys with the proceeds. Every stock
    ///      also sells a seventh of the caller's $0.50 reward, 5 bp of the $1,000 traded, so each ends at $9,999.93.
    function testActualControllerAndVaultResetToEqualWeightsPermissionlessly() public {
        vm.prank(address(123));
        controller.rebalance(block.timestamp, address(123));
        assertEq(router.calls(), 7); // six sales, then one purchase
        for (uint256 i; i < 7; ++i) {
            assertApproxEqAbs(assets[i].balanceOf(address(vault)), 99.99928572e8, 10);
        }
        assertEq(assets[7].balanceOf(address(vault)), 0);
        assertEq(assets[7].balanceOf(address(123)), 0.5e6); // 5 bp of the $1,000 traded
        assertEq(vault.totalSupply(), 1000e18);
        assertEq(assets[0].allowance(address(vault), address(router)), 0);
        assertEq(assets[7].allowance(address(vault), address(router)), 0);
        assertTrue(controller.executedQuarter(QUARTER));
        // Subsequent issuance uses the updated actual basket.
        uint256[8] memory contribution = vault.quoteMint(100e18);
        assertApproxEqAbs(contribution[0], 9.99992858e8, 1);
        vault.mintBasket(100e18, contribution, address(456), block.timestamp);
        assertEq(vault.balanceOf(address(456)), 100e18);
    }

    function testLegMinimumRevertsRealTransfersAndApprovals() public {
        router.configure(5000, false, false); // the purchase returns half its oracle value
        uint256 routerStockBefore = assets[0].balanceOf(address(router));
        vm.expectRevert("slippage");
        controller.rebalance(block.timestamp, address(0));
        _assertOriginalBasket();
        assertEq(assets[0].balanceOf(address(router)), routerStockBefore);
        assertEq(assets[0].allowance(address(vault), address(router)), 0);
        assertEq(assets[7].allowance(address(vault), address(router)), 0);
        assertEq(router.calls(), 0);
        router.configure(10000, false, false);
        controller.rebalance(block.timestamp, address(0)); // Failed attempt did not consume the quarter.
        assertTrue(controller.executedQuarter(QUARTER));
    }

    function testSecondSwapFailureRollsBackFirstSaleAndControllerState() public {
        router.configure(10000, true, false);
        vm.expectRevert("second swap failed");
        controller.rebalance(block.timestamp, address(0));
        _assertOriginalBasket();
        assertEq(router.calls(), 0);
    }

    function testRouterCannotReenterBasketIssuanceDuringRebalance() public {
        router.configure(10000, false, true);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        controller.rebalance(block.timestamp, address(0));
        _assertOriginalBasket();
    }

    function _assertOriginalBasket() private view {
        assertEq(assets[0].balanceOf(address(vault)), 110e8);
        assertEq(assets[1].balanceOf(address(vault)), 90e8);
        assertEq(assets[7].balanceOf(address(vault)), 0);
        assertEq(vault.totalSupply(), 1000e18);
        assertFalse(controller.executedQuarter(QUARTER));
        assertTrue(controller.rebalanceDue());
    }
}
