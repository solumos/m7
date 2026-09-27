// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {M7CapVault} from "../src/M7CapVault.sol";
import {USDCGateway} from "../src/USDCGateway.sol";
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

/// @dev Second-review reproductions, converted to regressions after the fixes (docs/AUDIT-2.md).
contract Audit2Test is Test {
    M7CapVault vault;
    USDCGateway gateway;
    IndexController controller;
    Valuation valuation;
    ControllerOracle oracle;
    PricedVenue router;
    IERC20[8] assets;
    ControllerFeed[8] feeds;
    uint256[7] equal;
    uint32 constant QUARTER = 2026 * 4 + 3;
    bytes32 constant DIGEST = keccak256("observations");

    function setUp() public {
        vm.warp(1790870400); // Thursday Oct 1 2026 16:00 UTC
        address[8] memory addresses;
        IAggregatorV3[8] memory aggregators;
        uint256[8] memory seed;
        int24[7] memory spacings;
        for (uint256 i; i < 8; ++i) {
            addresses[i] = address(new ControllerToken(i == 7 ? 6 : 8));
            assets[i] = IERC20(addresses[i]);
            feeds[i] = new ControllerFeed(8, i == 7 ? int256(1e8) : int256(100e8));
            aggregators[i] = feeds[i];
            if (i < 7) {
                seed[i] = 100e8; // 100 tokens x $100 = $10,000 per stock, $70,000 NAV
                equal[i] = uint256(1e18) / 7;
                spacings[i] = 10;
            }
        }
        equal[6] += uint256(1e18) % 7;
        valuation = new Valuation(
            addresses, aggregators, new ControllerFeed(0, 0), new ControllerRegistry(), 25 hours
        );
        oracle = new ControllerOracle();
        router = new PricedVenue(addresses[7]);
        for (uint256 i; i < 7; ++i) {
            router.setRate(addresses[i], 1e18); // $100, 8 decimals: one raw unit per raw USDC unit
            router.setPool(addresses[i], addresses[7], 10, true);
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
        vault = new M7CapVault(assets, spacings, address(controller), router, router, registry, address(this));
        assertEq(address(vault), predictedVault);
        gateway = new USDCGateway(IM7CapVault(address(vault)));
        for (uint256 i; i < 8; ++i) {
            ControllerToken(addresses[i]).mint(address(this), 1e15);
            ControllerToken(addresses[i]).mint(address(router), 1e15);
            assets[i].approve(address(vault), type(uint256).max);
        }
        assets[7].approve(address(controller), type(uint256).max);
        assets[7].approve(address(gateway), type(uint256).max);
        vault.approve(address(gateway), type(uint256).max);
        vault.bootstrap(seed, address(this));
    }

    function _accept(uint256[7] memory ratios) private returns (bytes32 id) {
        id = controller.propose(QUARTER, ratios, "ipfs://evidence", DIGEST);
        vm.warp(1791216000); // Monday Oct 5 16:00 UTC, after the 72h liveness
        for (uint256 i; i < 8; ++i) {
            feeds[i].set(i == 7 ? int256(1e8) : int256(100e8), block.timestamp);
        }
        assertTrue(controller.settle(id));
    }

    function _nav() private view returns (uint256 nav) {
        uint256[8] memory held;
        for (uint256 i; i < 8; ++i) {
            held[i] = vault.backing(i);
        }
        (, nav) = valuation.values(held, valuation.snapshot());
    }

    function _leaveOneWeiInRouter() private {
        address griefer = address(0xBAD);
        vm.deal(griefer, 1);
        vm.prank(griefer);
        router.unwrapWETH9{value: 1}(0, griefer);
        assertEq(address(router).balance, 1);
    }

    // N-01 regression: router dust is absorbed by the vault or gateway instead of reverting the swap.
    function testAudit2RouterEthDustNoLongerBlocksGateway() public {
        _leaveOneWeiInRouter();
        assertEq(gateway.mintWithUSDC(10e18, 1_000e6, address(this), block.timestamp), 700e6);
        assertEq(address(router).balance, 0);
        assertEq(address(gateway).balance, 1);
        _leaveOneWeiInRouter();
        assertEq(gateway.redeemToUSDC(10e18, 0, address(this), block.timestamp), 700e6);
        assertEq(address(gateway).balance, 2);
    }

    function testAudit2RouterEthDustNoLongerBlocksRebalance() public {
        uint256[7] memory target = equal;
        target[0] += 0.01e18;
        target[1] -= 0.01e18;
        _accept(target);
        _leaveOneWeiInRouter();
        controller.execute(block.timestamp);
        assertTrue(controller.executedQuarter(QUARTER));
        assertEq(address(vault).balance, 1);
    }

    // N-03 regression: an unchallenged false assertion moves the basket by at most one bounded step.
    function testAudit2FalseAssertionMovesAtMostOneStep() public {
        uint256[7] memory bogus;
        for (uint256 i = 1; i < 7; ++i) {
            bogus[i] = 1; // 1e-18 "quantity" per stock is still accepted by propose()
        }
        bogus[0] = 1e18 - 6;
        _accept(bogus);
        uint256 navBefore = _nav();
        router.setHaircuts(0, 50); // the venue keeps 0.5% of every purchase
        vm.prank(address(0xE0A)); // permissionless executor, no role or stake
        controller.execute(block.timestamp);

        // Formerly 99.99% of NAV moved into one stock. Now stock 0 gains one 5% step, less the haircut.
        assertApproxEqAbs(assets[0].balanceOf(address(vault)), 104.975e8, 10);
        for (uint256 i = 1; i < 7; ++i) {
            assertApproxEqAbs(assets[i].balanceOf(address(vault)), 99.1666667e8, 10);
        }
        // $2.50 kept by the venue: 0.5% of the $500 bought, versus 0.43% of NAV before the fix.
        assertApproxEqAbs(navBefore - _nav(), 2.5e18, 1e14);
    }

    // N-06 regressions: the controller plans from current balances, so interim flows cannot invalidate a plan.
    function testAudit2PlannerSurvivesLargeRedemptionBeforeExecution() public {
        uint256[7] memory target = equal;
        target[0] += 0.05e18;
        target[1] -= 0.05e18;
        _accept(target);
        uint256[8] memory noMinimum;
        vault.redeemBasket(vault.totalSupply() * 40 / 100, noMinimum, address(this), block.timestamp);
        controller.execute(block.timestamp);
        assertApproxEqAbs(assets[0].balanceOf(address(vault)), 63e8, 10); // 60 tokens + one 5% step
        assertApproxEqAbs(assets[1].balanceOf(address(vault)), 57e8, 10);
    }

    function testAudit2PlannerDeploysDonatedCash() public {
        _accept(equal);
        require(assets[7].transfer(address(vault), 15e6)); // formerly tripped the 1 bp residual-cash check
        controller.execute(block.timestamp);
        assertTrue(controller.executedQuarter(QUARTER));
        assertLe(assets[7].balanceOf(address(vault)), controller.MIN_LEG_USDC());
    }

    // Verified property: quarterAt agrees with an independent Gregorian algorithm.
    function testAudit2FuzzQuarterAtMatchesIndependentCalendar(uint256 timestamp) public view {
        timestamp = bound(timestamp, 0, 253402300799);
        (uint256 year, uint256 month) = _civil(timestamp / 1 days);
        assertEq(uint256(controller.quarterAt(timestamp)), year * 4 + (month - 1) / 3);
    }

    function testAudit2QuarterAtEveryDay2000To2100() public view {
        for (uint256 day = 10957; day < 47482; ++day) {
            (uint256 year, uint256 month) = _civil(day);
            uint256 expected = year * 4 + (month - 1) / 3;
            assertEq(uint256(controller.quarterAt(day * 1 days)), expected);
            assertEq(uint256(controller.quarterAt(day * 1 days + 1 days - 1)), expected);
        }
    }

    /// Howard Hinnant's civil_from_days, restricted to non-negative day counts.
    function _civil(uint256 z) private pure returns (uint256 year, uint256 month) {
        z += 719468;
        uint256 era = z / 146097;
        uint256 doe = z - era * 146097;
        uint256 yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
        uint256 doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
        uint256 mp = (5 * doy + 2) / 153;
        month = mp < 10 ? mp + 3 : mp - 9;
        year = yoe + era * 400 + (month <= 2 ? 1 : 0);
    }
}
