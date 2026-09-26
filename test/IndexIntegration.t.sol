// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {M7CapVault} from "../src/M7CapVault.sol";
import {IndexController} from "../src/IndexController.sol";
import {Valuation, IAggregatorV3} from "../src/Valuation.sol";
import {IM7CapVault} from "../src/interfaces/IM7CapVault.sol";
import {ISlipstreamRouter, ISlipstreamFactory} from "../src/interfaces/ISlipstreamRouter.sol";
import {Swap} from "../src/Types.sol";
import {
    ControllerToken,
    ControllerFeed,
    ControllerRegistry,
    ControllerOracle
} from "./mocks/ControllerMocks.sol";

/// @dev A funded external venue: $100 stocks with 8 decimals exchange 1:1 raw units against 6-decimal USDC.
contract IndexIntegrationRouter is ISlipstreamRouter, ISlipstreamFactory {
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
            IM7CapVault(msg.sender).mintBasket(1, amounts, address(this), block.timestamp);
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
    M7CapVault vault;
    IndexController controller;
    Valuation valuation;
    ControllerOracle oracle;
    IndexIntegrationRouter router;
    IERC20[8] assets;
    IAggregatorV3[8] feeds;
    ControllerFeed sequencer;
    bytes32 assertionId;
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
        valuation = new Valuation(addresses, feeds, sequencer, new ControllerRegistry(), 1 hours);
        oracle = new ControllerOracle();
        router = new IndexIntegrationRouter();
        address predictedVault =
            vm.computeCreateAddress(address(this), uint256(vm.getNonce(address(this))) + 1);
        controller = new IndexController(
            IM7CapVault(predictedVault), oracle, assets[7], 1000e6, keccak256("methodology"), valuation
        );
        vault = new M7CapVault(assets, address(controller), router, router, address(this));
        assertEq(address(vault), predictedVault);
        for (uint256 i; i < 8; ++i) {
            assets[i].approve(address(vault), type(uint256).max);
            require(assets[i].transfer(address(router), 1e12));
        }
        vault.bootstrap(seed, address(this));
        uint256[7] memory ratios;
        for (uint256 i; i < 7; ++i) {
            ratios[i] = uint256(1e18) / 7;
        }
        ratios[6] += uint256(1e18) % 7;
        assets[7].approve(address(controller), 1000e6);
        assertionId = controller.propose(QUARTER, ratios, "ipfs://test-evidence");
        vm.warp(1791216000); // Monday Oct 5, after 72h liveness.
        sequencer.set(0, block.timestamp);
        for (uint256 i; i < 8; ++i) {
            ControllerFeed(address(feeds[i])).set(i == 7 ? int256(1e8) : int256(100e8), block.timestamp);
        }
        controller.settle(assertionId);
    }

    function _trades(uint256 minimumBuy) private pure returns (Swap[] memory swaps) {
        swaps = new Swap[](2);
        swaps[0] = Swap(0, 7, 100, 10e8, 1000e6);
        swaps[1] = Swap(7, 1, 100, 1000e6, minimumBuy);
    }

    function testActualControllerAndVaultExecuteTwoLegRebalancePermissionlessly() public {
        vm.prank(address(123));
        controller.execute(_trades(10e8), block.timestamp);
        assertEq(router.calls(), 2);
        for (uint256 i; i < 7; ++i) {
            assertEq(assets[i].balanceOf(address(vault)), 100e8);
        }
        assertEq(assets[7].balanceOf(address(vault)), 0);
        assertEq(vault.totalSupply(), 1000e18);
        assertEq(assets[0].allowance(address(vault), address(router)), 0);
        assertEq(assets[7].allowance(address(vault), address(router)), 0);
        assertTrue(controller.executedQuarter(QUARTER));
        // Subsequent issuance uses the successfully updated actual basket.
        uint256[8] memory contribution = vault.quoteMint(100e18);
        for (uint256 i; i < 7; ++i) {
            assertEq(contribution[i], 10e8);
        }
        vault.mintBasket(100e18, contribution, address(456), block.timestamp);
        assertEq(vault.balanceOf(address(456)), 100e18);
    }

    function testControllerPostconditionRevertsRealTransfersAndApprovals() public {
        router.configure(5000, false, false); // Lose $500 on a $70,000 portfolio, over 50bps.
        uint256 routerStockBefore = assets[0].balanceOf(address(router));
        vm.expectRevert(IndexController.RebalanceLoss.selector);
        controller.execute(_trades(5e8), block.timestamp);
        _assertOriginalBasket();
        assertEq(assets[0].balanceOf(address(router)), routerStockBefore);
        assertEq(assets[0].allowance(address(vault), address(router)), 0);
        assertEq(assets[7].allowance(address(vault), address(router)), 0);
        assertEq(router.calls(), 0);
        router.configure(10000, false, false);
        controller.execute(_trades(10e8), block.timestamp); // Failed attempt did not consume the quarter.
        assertTrue(controller.executedQuarter(QUARTER));
    }

    function testSecondSwapFailureRollsBackFirstSaleAndControllerState() public {
        router.configure(10000, true, false);
        vm.expectRevert("second swap failed");
        controller.execute(_trades(10e8), block.timestamp);
        _assertOriginalBasket();
        assertEq(router.calls(), 0);
    }

    function testRouterCannotReenterBasketIssuanceDuringRebalance() public {
        router.configure(10000, false, true);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        controller.execute(_trades(10e8), block.timestamp);
        _assertOriginalBasket();
    }

    function _assertOriginalBasket() private view {
        assertEq(assets[0].balanceOf(address(vault)), 110e8);
        assertEq(assets[1].balanceOf(address(vault)), 90e8);
        assertEq(assets[7].balanceOf(address(vault)), 0);
        assertEq(vault.totalSupply(), 1000e18);
        assertFalse(controller.executedQuarter(QUARTER));
        assertEq(uint256(controller.proposal(assertionId).status), uint256(IndexController.Status.Accepted));
    }
}
