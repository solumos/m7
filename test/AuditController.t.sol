// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {M7CapVault} from "../src/M7CapVault.sol";
import {IndexController} from "../src/IndexController.sol";
import {Valuation, IAggregatorV3} from "../src/Valuation.sol";
import {IM7CapVault} from "../src/interfaces/IM7CapVault.sol";
import {ISlipstreamRouter, ISlipstreamFactory} from "../src/interfaces/ISlipstreamRouter.sol";
import {PolicyRegistryMock} from "./mocks/PolicyMocks.sol";
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

/// @dev First-review reproductions, converted to regressions after the fixes (docs/AUDIT.md).
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
    bytes32 constant DIGEST = keccak256("observations");

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
                ratios[i] = uint256(1e18) / 7;
                spacings[i] = 100;
            }
        }
        ratios[6] += uint256(1e18) % 7;
        valuation =
            new Valuation(addresses, feeds, new ControllerFeed(0, 0), new ControllerRegistry(), 25 hours);
        oracle = new ControllerOracle();
        venue = new AuditControllerVenue(address(assets[7]));
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
        assertEq(address(vault), predictedVault);
        for (uint256 i; i < 7; ++i) {
            ControllerToken(addresses[i]).mint(address(this), seed[i]);
            ControllerToken(addresses[i]).mint(address(venue), 1000e8);
            assets[i].approve(address(vault), seed[i]);
        }
        ControllerToken(addresses[7]).mint(address(venue), 10000e6);
        ControllerToken(addresses[7]).mint(address(this), 2000e6);
        assets[7].approve(address(controller), 2000e6);
        vault.bootstrap(seed, address(this));
    }

    function _settleAfterLiveness(bytes32 id) private {
        vm.warp(1791216000); // Monday October 5, after the challenge period.
        _refresh();
        assertTrue(controller.settle(id));
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

    // M-02 regression: executors no longer choose legs, so an unchanged target trades nothing and loses nothing.
    function testExecutorCannotSpendLossAllowanceOnUnnecessaryTrades() public {
        _settleAfterLiveness(controller.propose(QUARTER, ratios, "ipfs://unchanged", DIGEST));
        uint256 navBefore = _nav();
        vm.prank(address(0xBAD)); // No shares, role, bond, or approval is needed to execute.
        controller.execute(block.timestamp);
        assertEq(_nav(), navBefore); // formerly $350 of $70,000 went to the venue
        for (uint256 i; i < 7; ++i) {
            assertEq(assets[i].balanceOf(address(vault)), 100e8);
            assertEq(assets[i].balanceOf(address(venue)), 1000e8);
        }
        assertTrue(controller.executedQuarter(QUARTER));
    }

    function testLossIsBoundedByNeededTurnoverThroughAnExtractiveVenue() public {
        ratios[0] += 0.005e18;
        ratios[1] -= 0.005e18;
        _settleAfterLiveness(controller.propose(QUARTER, ratios, "ipfs://changed", DIGEST));
        uint256 navBefore = _nav();
        controller.execute(block.timestamp);
        // Only the $350 needed is traded; the venue keeps 0.5% of the purchase ($1.75), not 50 bp of NAV.
        assertApproxEqAbs(navBefore - _nav(), 1.75e18, 1e13);
        assertEq(assets[1].balanceOf(address(vault)), 96.5e8);
    }

    // L-01 regression: a disputed proposal no longer monopolizes the quarter.
    function testDisputedProposalNoLongerBlocksAReplacement() public {
        bytes32 disputed = controller.propose(QUARTER, ratios, "ipfs://unreviewable-evidence", DIGEST);
        vm.prank(address(0xD15));
        oracle.dispute(disputed);
        bytes32 honest = controller.propose(QUARTER, ratios, "ipfs://honest-evidence", DIGEST);
        _settleAfterLiveness(honest);
        vm.expectRevert("unresolved dispute"); // the dispute can take as long as the DVM needs
        controller.settle(disputed);
        controller.execute(block.timestamp);
        assertEq(controller.acceptedProposal(QUARTER), honest);
        assertTrue(controller.executedQuarter(QUARTER));
    }

    // M-03 regression: a heartbeat-conforming quiet feed no longer blocks the window.
    function testQuietButHeartbeatConformingFeedNoLongerBlocksExecution() public {
        _settleAfterLiveness(controller.propose(QUARTER, ratios, "ipfs://evidence", DIGEST));
        vm.warp(block.timestamp - 1 hours); // Monday 15:00 UTC, the start of the window
        _refresh();
        ControllerFeed(address(feeds[0])).set(100e8, block.timestamp - 3 hours); // last update at 12:00
        controller.execute(block.timestamp);
        assertTrue(controller.executedQuarter(QUARTER));
    }
}
