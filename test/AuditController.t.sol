// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
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

/// @dev Models a funded, attacker-owned pool reached through the immutable router.
///      This is not a native Aerodrome fork: it isolates the controller's acceptance of
///      unnecessary round trips that transfer the full permitted NAV loss to a venue.
contract AuditControllerVenue is ISlipstreamRouter, ISlipstreamFactory {
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

contract AuditControllerTest is Test {
    M7CapVault vault;
    IndexController controller;
    Valuation valuation;
    ControllerOracle oracle;
    AuditControllerVenue venue;
    IERC20[8] assets;
    IAggregatorV3[8] feeds;
    uint256[7] ratios;
    uint32 constant QUARTER = 2026 * 4 + 3;

    function setUp() public {
        vm.warp(1790870400); // Thursday October 1, 2026 16:00 UTC.
        address[8] memory addresses;
        uint256[8] memory seed;
        for (uint256 i; i < 8; ++i) {
            addresses[i] = address(new ControllerToken(i == 7 ? 6 : 8));
            assets[i] = IERC20(addresses[i]);
            feeds[i] = new ControllerFeed(8, i == 7 ? int256(1e8) : int256(100e8));
            if (i < 7) {
                seed[i] = 100e8;
                ratios[i] = uint256(1e18) / 7;
            }
        }
        ratios[6] += uint256(1e18) % 7;
        valuation =
            new Valuation(addresses, feeds, new ControllerFeed(0, 0), new ControllerRegistry(), 1 hours);
        oracle = new ControllerOracle();
        venue = new AuditControllerVenue(address(assets[7]));
        address predictedVault =
            vm.computeCreateAddress(address(this), uint256(vm.getNonce(address(this))) + 1);
        controller = new IndexController(
            IM7CapVault(predictedVault), oracle, assets[7], 1000e6, keccak256("methodology"), valuation
        );
        vault = new M7CapVault(assets, address(controller), venue, venue, address(this));
        assertEq(address(vault), predictedVault);
        for (uint256 i; i < 7; ++i) {
            ControllerToken(addresses[i]).mint(address(this), seed[i]);
            assets[i].approve(address(vault), seed[i]);
        }
        ControllerToken(addresses[7]).mint(address(venue), 10000e6);
        ControllerToken(addresses[7]).mint(address(this), 1000e6);
        assets[7].approve(address(controller), 1000e6);
        vault.bootstrap(seed, address(this));
    }

    function _acceptedProposal() private returns (bytes32 id) {
        id = controller.propose(QUARTER, ratios, "ipfs://honest-unchanged-target");
        vm.warp(1791216000); // Monday October 5, after the challenge period.
        for (uint256 i; i < 8; ++i) {
            ControllerFeed(address(feeds[i])).set(i == 7 ? int256(1e8) : int256(100e8), block.timestamp);
        }
        assertTrue(controller.settle(id));
    }

    function testUnnecessaryRoundTripsPayFull50BpsToVenueAndConsumeQuarter() public {
        _acceptedProposal();
        (, uint256 beforeNav) = valuation.values(address(vault), valuation.snapshot());
        Swap[] memory swaps = new Swap[](14);
        for (uint256 i; i < 7; ++i) {
            swaps[i * 2] = Swap(uint8(i), 7, 100, 100e8, 10000e6);
            swaps[i * 2 + 1] = Swap(7, uint8(i), 100, 10000e6, 995e7);
        }
        vm.prank(address(0xBAD)); // No shares, role, bond, or approval is needed to execute.
        controller.execute(swaps, block.timestamp);
        (, uint256 afterNav) = valuation.values(address(vault), valuation.snapshot());
        assertEq(beforeNav, 70000e18);
        assertEq(afterNav, 69650e18);
        assertEq(beforeNav - afterNav, 350e18);
        for (uint256 i; i < 7; ++i) {
            assertEq(assets[i].balanceOf(address(vault)), 995e7);
            assertEq(assets[i].balanceOf(address(venue)), 5e7);
        }
        assertEq(assets[7].balanceOf(address(venue)), 10000e6);
        assertEq(assets[7].balanceOf(address(vault)), 0);
        assertTrue(controller.executedQuarter(QUARTER));
        vm.expectRevert(IndexController.ProposalUnavailable.selector);
        controller.execute(new Swap[](0), block.timestamp);
    }

    function testUnchangedTargetCanExecuteWithZeroTradesAndZeroLoss() public {
        _acceptedProposal();
        controller.execute(new Swap[](0), block.timestamp);
        for (uint256 i; i < 7; ++i) {
            assertEq(assets[i].balanceOf(address(vault)), 100e8);
        }
    }

    function testDisputedProposalMonopolizesQuarterUntilOracleResolution() public {
        bytes32 id = controller.propose(QUARTER, ratios, "ipfs://unreviewable-evidence");
        vm.prank(address(0xD15));
        oracle.dispute(id);
        vm.warp(block.timestamp + 30 days);
        vm.expectRevert("unresolved dispute");
        controller.settle(id);
        vm.expectRevert(IndexController.ProposalUnavailable.selector);
        controller.propose(QUARTER, ratios, "ipfs://honest-evidence");
        oracle.resolveDispute(id, false);
        assertFalse(controller.settle(id));
        // The first proposer's bond is gone. A replacement requires new operating capital.
        assertEq(assets[7].balanceOf(address(this)), 0);
        ControllerToken(address(assets[7])).mint(address(this), 1000e6);
        assets[7].approve(address(controller), 1000e6);
        assertTrue(controller.propose(QUARTER, ratios, "ipfs://honest-evidence") != bytes32(0));
    }

    function testHeartbeatConformingQuietFeedCanBlockEntireExecutionWindow() public {
        _acceptedProposal();
        uint256 windowStart = block.timestamp - 1 hours; // Monday 15:00 UTC.
        // A feed that last published at 12:00 need not republish by 17:00 on a
        // quiet day with no 0.5% deviation and a 24-hour heartbeat.
        uint256 lastStockUpdate = windowStart - 3 hours;
        ControllerFeed(address(feeds[0])).set(100e8, lastStockUpdate);
        for (uint256 minute; minute < 120; minute += 10) {
            vm.warp(windowStart + minute * 1 minutes);
            for (uint256 i = 1; i < 8; ++i) {
                ControllerFeed(address(feeds[i])).set(i == 7 ? int256(1e8) : int256(100e8), block.timestamp);
            }
            assertLt(block.timestamp - lastStockUpdate, 24 hours);
            vm.expectRevert(abi.encodeWithSelector(Valuation.UnavailablePrice.selector, 0));
            controller.execute(new Swap[](0), block.timestamp);
        }
        assertFalse(controller.executedQuarter(QUARTER));
    }
}
