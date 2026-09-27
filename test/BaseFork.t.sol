// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {M7CapVault} from "../src/M7CapVault.sol";
import {USDCGateway} from "../src/USDCGateway.sol";
import {M7CapLens} from "../src/M7CapLens.sol";
import {IndexController} from "../src/IndexController.sol";
import {Valuation, IAggregatorV3, ICoinbaseOracleRegistry} from "../src/Valuation.sol";
import {IM7CapVault} from "../src/interfaces/IM7CapVault.sol";
import {IOptimisticOracleV3} from "../src/interfaces/IOptimisticOracleV3.sol";
import {ISlipstreamRouter, ISlipstreamFactory} from "../src/interfaces/ISlipstreamRouter.sol";
import {IPolicyRegistry} from "../src/interfaces/IB20Policy.sol";
import {VaultHarness} from "./mocks/VaultHarness.sol";

/// @dev Opt in with BASE_FORK_TEST=true and use Base's patched forge with FOUNDRY_BASE=true.
/// This is a local fork: only USDC is dealt; every B20 is acquired from its actual live-state pool.
contract BaseForkTest is VaultHarness {
    using SafeERC20 for IERC20;

    string private constant FIXTURE =
        "Local fork ABI fixture only, not investment data: the seven quantity ratios are 0.1e18 each for the first six stocks and 0.4e18 for the seventh.";

    function testBaseNativeB20BootstrapAndUSDCRoundTrip() public {
        _startFork();
        string memory manifest = vm.readFile("config/base.json");
        IERC20[8] memory assets;
        int24[7] memory routes;
        assets[7] = IERC20(vm.parseJsonAddress(manifest, ".usdc.address"));
        ISlipstreamRouter router = ISlipstreamRouter(vm.parseJsonAddress(manifest, ".venue.router"));
        ISlipstreamFactory factory = ISlipstreamFactory(vm.parseJsonAddress(manifest, ".venue.factory"));
        for (uint256 i; i < 7; ++i) {
            string memory prefix = string.concat(".stocks[", vm.toString(i), "]");
            assets[i] = IERC20(vm.parseJsonAddress(manifest, string.concat(prefix, ".address")));
            routes[i] = int24(uint24(vm.parseJsonUint(manifest, string.concat(prefix, ".tick_spacing"))));
            assertEq(
                factory.getPool(address(assets[7]), address(assets[i]), routes[i]),
                vm.parseJsonAddress(manifest, string.concat(prefix, ".pool"))
            );
        }

        IPolicyRegistry registry = IPolicyRegistry(vm.parseJsonAddress(manifest, ".policy_registry"));
        (M7CapVault vault,) = _deployVault(assets, routes, router, factory, registry);
        USDCGateway gateway = new USDCGateway(IM7CapVault(address(vault)));
        // Forge mutates only this local fork's standard USDC storage, never native B20 state.
        deal(address(assets[7]), address(this), 2_000e6);
        uint256[8] memory seed;
        for (uint256 i; i < 7; ++i) {
            assets[7].forceApprove(address(router), 100e6);
            uint256 beforeBalance = assets[i].balanceOf(address(this));
            seed[i] = router.exactInputSingle(
                ISlipstreamRouter.ExactInputSingleParams({
                    tokenIn: address(assets[7]),
                    tokenOut: address(assets[i]),
                    tickSpacing: routes[i],
                    recipient: address(this),
                    deadline: block.timestamp,
                    amountIn: 100e6,
                    amountOutMinimum: 1,
                    sqrtPriceLimitX96: 0
                })
            );
            assertGt(seed[i], 0);
            assertEq(assets[i].balanceOf(address(this)) - beforeBalance, seed[i]);
            assets[i].forceApprove(address(vault), seed[i]);
        }
        assets[7].forceApprove(address(router), 0);
        vault.bootstrap(seed, address(this));
        for (uint256 i; i < 7; ++i) {
            assertEq(assets[i].balanceOf(address(vault)), seed[i]);
        }

        address user = makeAddr("Base fork user");
        assets[7].safeTransfer(user, 100e6);
        vm.startPrank(user);
        assets[7].forceApprove(address(gateway), 100e6);
        uint256 spent = gateway.mintWithUSDC(100e18, 100e6, user, block.timestamp);
        assertEq(vault.balanceOf(user), 100e18);
        assertGt(spent, 50e6);
        assertLe(spent, 100e6);
        vault.approve(address(gateway), 100e18);
        uint256 received = gateway.redeemToUSDC(100e18, spent * 95 / 100, user, block.timestamp);
        vm.stopPrank();
        emit log_named_uint("Mint USDC cost (6 decimals)", spent);
        emit log_named_uint("Redemption USDC proceeds (6 decimals)", received);
        assertEq(vault.balanceOf(user), 0);
        assertEq(assets[7].balanceOf(user), 100e6 - spent + received);
        for (uint256 i; i < 8; ++i) {
            assertGe(assets[i].balanceOf(address(vault)), seed[i]);
            assertEq(assets[i].balanceOf(address(gateway)), 0);
            assertEq(assets[i].allowance(address(gateway), address(router)), 0);
            assertEq(assets[i].allowance(address(gateway), address(vault)), 0);
        }
    }

    /// @dev Exercises the actual UMA ABI and bond lifecycle, not the correctness of index weights.
    /// The undisputed assertion uses a synthetic fixture methodology and exists only on the local fork.
    function testBaseLiveUMAAssertionAndBondRefund() public {
        _startFork();
        IndexController controller = _deployFixtureController();
        IERC20 usdc = controller.bondCurrency();
        IOptimisticOracleV3 oracle = controller.oracle();

        // The deployed OOv3's defaultIdentifier remains the retired ASSERT_TRUTH value.
        oracle.syncUmaParams(bytes32("ASSERT_TRUTH2"), address(usdc));
        uint256 minimumBond = oracle.getMinimumBond(address(usdc));
        uint256 bond = minimumBond > 1_000e6 ? minimumBond : 1_000e6;
        address proposer = makeAddr("Local fork UMA proposer");
        deal(address(usdc), proposer, bond);
        uint256 oracleBalanceBefore = usdc.balanceOf(address(oracle));
        uint256[7] memory ratios = [uint256(0.1e18), 0.1e18, 0.1e18, 0.1e18, 0.1e18, 0.1e18, 0.4e18];
        uint32 quarter = controller.currentQuarter();
        vm.startPrank(proposer);
        usdc.forceApprove(address(controller), bond);
        bytes32 assertionId =
            controller.propose(quarter, ratios, "ipfs://local-fork-fixture", sha256(bytes(FIXTURE)));
        vm.stopPrank();

        IOptimisticOracleV3.Assertion memory assertion = oracle.getAssertion(assertionId);
        assertEq(assertion.asserter, proposer);
        assertEq(assertion.escalationManagerSettings.assertingCaller, address(controller));
        assertEq(assertion.escalationManagerSettings.escalationManager, address(0));
        assertEq(address(assertion.currency), address(usdc));
        assertEq(assertion.bond, bond);
        assertEq(assertion.identifier, bytes32("ASSERT_TRUTH2"));
        assertEq(assertion.expirationTime - assertion.assertionTime, 72 hours);
        assertEq(assertion.callbackRecipient, address(0));
        assertEq(assertion.disputer, address(0));
        assertFalse(assertion.settled);
        assertEq(usdc.balanceOf(proposer), 0);
        assertEq(usdc.balanceOf(address(oracle)), oracleBalanceBefore + bond);
        assertEq(usdc.balanceOf(address(controller)), 0);
        assertEq(usdc.allowance(address(controller), address(oracle)), 0);
        assertEq(uint256(controller.proposal(assertionId).status), uint256(IndexController.Status.Pending));
        vm.expectRevert();
        controller.settle(assertionId);

        vm.warp(assertion.expirationTime);
        vm.prank(makeAddr("Permissionless local fork settler"));
        assertTrue(controller.settle(assertionId));
        assertion = oracle.getAssertion(assertionId);
        assertTrue(assertion.settled);
        assertTrue(assertion.settlementResolution);
        assertEq(uint256(controller.proposal(assertionId).status), uint256(IndexController.Status.Accepted));
        assertEq(usdc.balanceOf(proposer), bond);
        assertEq(usdc.balanceOf(address(oracle)), oracleBalanceBefore);
        emit log_named_uint("Live UMA minimum USDC bond (6 decimals)", minimumBond);
        emit log_named_uint("Local assertion USDC bond refunded (6 decimals)", bond);
    }

    /// @dev The on-chain planner against the live pinned pools with native B20 transfers: a real UMA acceptance, then
    ///      one bounded step. Feeds are mocked only to report their fork-time answers as fresh after the time travel.
    function testBaseNativeRebalanceAgainstLivePools() public {
        _startFork();
        IndexController controller = _deployFixtureController();
        M7CapVault vault = M7CapVault(payable(address(controller.vault())));
        vault.bootstrap(_buySeed(vault, 150e6), address(this));
        uint256[7] memory ratios = _oneStepAway(_backing(vault));

        uint256 execution = _executionTime(controller);
        vm.warp(execution - 73 hours);
        bytes32 assertionId = _proposeLive(controller, ratios);
        vm.warp(execution - 1 hours);
        assertTrue(controller.settle(assertionId));
        vm.warp(execution);
        _reportFeedsFresh(controller.valuation());

        vm.recordLogs();
        uint256 gasBefore = gasleft();
        controller.execute(block.timestamp + 1 hours);
        emit log_named_uint("Rebalance execute gas", gasBefore - gasleft());
        (uint256 navBefore, uint256 navAfter, uint256 sold, uint256 bought, uint256 legs) =
            _rebalanced(vm.getRecordedLogs());
        assertTrue(controller.executedQuarter(controller.currentQuarter()));
        assertGt(sold, 0);
        assertGt(bought, 0);
        assertLe(navBefore - Math.min(navBefore, navAfter), (sold + bought) / 100, "loss beyond 1% of traded");
        uint256[7] memory shares = _shares(_backing(vault));
        for (uint256 i; i < 7; ++i) {
            assertApproxEqRel(shares[i], ratios[i], 0.003e18, "outside the 30 bp compliance band");
        }
        assertLe(vault.backing(7), Math.max(navAfter / 10_000 / 1e12, controller.MIN_LEG_USDC()));
        emit log_named_uint("Rebalance legs", legs);
        emit log_named_uint("NAV before (1e18 USD)", navBefore);
        emit log_named_uint("NAV after (1e18 USD)", navAfter);
        emit log_named_uint("Sold value (1e18 USD)", sold);
        emit log_named_uint("Bought value (1e18 USD)", bought);
    }

    /// @dev Receipt transfers and the resilient exit against the real policy registry and native stock transfers.
    function testBaseNativeTransferGasAndResilientRedemption() public {
        _startFork();
        IndexController controller = _deployFixtureController();
        M7CapVault vault = M7CapVault(payable(address(controller.vault())));
        vault.bootstrap(_buySeed(vault, 50e6), address(this));
        address holder = makeAddr("Base fork holder");
        address receiver = makeAddr("Base fork receiver");

        uint256 gasBefore = gasleft();
        require(vault.transfer(holder, 100e18));
        emit log_named_uint("M7CAP transfer gas, new recipient", gasBefore - gasleft());
        gasBefore = gasleft();
        require(vault.transfer(holder, 1e18));
        emit log_named_uint("M7CAP transfer gas, existing recipient", gasBefore - gasleft());

        uint256[8] memory quote = vault.quoteRedeem(50e18);
        uint256[8] memory noMinimum;
        vm.prank(holder);
        (uint256[8] memory delivered, uint256[8] memory deferred) =
            vault.redeemBasketWithClaims(50e18, noMinimum, receiver, block.timestamp);
        for (uint256 i; i < 8; ++i) {
            assertEq(delivered[i], quote[i]);
            assertEq(deferred[i], 0);
            assertEq(vault.assets(i).balanceOf(receiver), quote[i]);
            assertEq(vault.reserved(i), 0);
        }
        assertEq(vault.balanceOf(holder), 51e18);
    }

    /// @dev Price per share from the live feeds: a seed bought for 700 USDC backs 1,000 shares worth about $0.70 each.
    function testBaseNativeLensPricesShares() public {
        _startFork();
        IndexController controller = _deployFixtureController();
        M7CapVault vault = M7CapVault(payable(address(controller.vault())));
        M7CapLens lens = new M7CapLens(controller);
        vault.bootstrap(_buySeed(vault, 100e6), address(this));
        M7CapLens.Value memory v = lens.value();
        uint256 total;
        for (uint256 i; i < 8; ++i) {
            total += v.components[i];
        }
        assertEq(v.nav, total);
        assertEq(v.supply, 1_000e18);
        // Pool prices sit within a fraction of a percent of the feeds, so the seed is worth about what it cost.
        assertApproxEqRel(v.perShare, 0.7e18, 0.01e18);
        assertLe(v.oldestPriceAt, block.timestamp);
        assertFalse(v.issuerPaused);
        assertFalse(v.sequencerDown);
        emit log_named_decimal_uint("Price per share (USD)", v.perShare, 18);
        emit log_named_uint("Stalest price age (seconds)", block.timestamp - v.oldestPriceAt);
    }

    function _deployFixtureController() private returns (IndexController controller) {
        string memory manifest = vm.readFile("config/base.json");
        IERC20[8] memory assets;
        address[8] memory assetAddresses;
        IAggregatorV3[8] memory feeds;
        for (uint256 i; i < 7; ++i) {
            string memory prefix = string.concat(".stocks[", vm.toString(i), "]");
            assetAddresses[i] = vm.parseJsonAddress(manifest, string.concat(prefix, ".address"));
            assets[i] = IERC20(assetAddresses[i]);
            feeds[i] = IAggregatorV3(vm.parseJsonAddress(manifest, string.concat(prefix, ".feed")));
        }
        assetAddresses[7] = vm.parseJsonAddress(manifest, ".usdc.address");
        assets[7] = IERC20(assetAddresses[7]);
        feeds[7] = IAggregatorV3(vm.parseJsonAddress(manifest, ".usdc.feed"));
        Valuation valuation = new Valuation(
            assetAddresses,
            feeds,
            IAggregatorV3(vm.parseJsonAddress(manifest, ".sequencer_feed")),
            ICoinbaseOracleRegistry(vm.parseJsonAddress(manifest, ".registry")),
            vm.parseJsonUint(manifest, ".risk_checks.max_stock_feed_age_seconds")
        );
        IOptimisticOracleV3 oracle = IOptimisticOracleV3(vm.parseJsonAddress(manifest, ".uma_oo_v3"));
        address predictedVault =
            vm.computeCreateAddress(address(this), uint256(vm.getNonce(address(this))) + 1);
        controller = new IndexController(
            IM7CapVault(predictedVault),
            oracle,
            assets[7],
            1_000e6,
            keccak256(bytes(FIXTURE)),
            "ipfs://local-fork-fixture-methodology",
            valuation
        );
        M7CapVault vault = new M7CapVault(
            assets,
            _manifestSpacings(manifest),
            address(controller),
            ISlipstreamRouter(vm.parseJsonAddress(manifest, ".venue.router")),
            ISlipstreamFactory(vm.parseJsonAddress(manifest, ".venue.factory")),
            IPolicyRegistry(vm.parseJsonAddress(manifest, ".policy_registry")),
            address(this)
        );
        assertEq(address(vault), predictedVault);
    }

    /// @dev Buys `usdcPerStock` of each stock from its pinned pool and approves the vault to take it.
    function _buySeed(M7CapVault vault, uint256 usdcPerStock) private returns (uint256[8] memory seed) {
        IERC20 usdc = vault.assets(7);
        ISlipstreamRouter router = vault.router();
        deal(address(usdc), address(this), usdcPerStock * 7);
        usdc.forceApprove(address(router), usdcPerStock * 7);
        for (uint256 i; i < 7; ++i) {
            seed[i] = router.exactInputSingle(
                ISlipstreamRouter.ExactInputSingleParams({
                    tokenIn: address(usdc),
                    tokenOut: address(vault.assets(i)),
                    tickSpacing: vault.tickSpacing(i),
                    recipient: address(this),
                    deadline: block.timestamp,
                    amountIn: usdcPerStock,
                    amountOutMinimum: 1,
                    sqrtPriceLimitX96: 0
                })
            );
            vault.assets(i).forceApprove(address(vault), seed[i]);
        }
        usdc.forceApprove(address(router), 0);
    }

    function _backing(M7CapVault vault) private view returns (uint256[8] memory held) {
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
            shares[i] = held[i] * 1e18 / total;
        }
    }

    /// @dev Current quantity shares with the first stock 3% heavier and the second 3% lighter: within one step.
    function _oneStepAway(uint256[8] memory held) private pure returns (uint256[7] memory ratios) {
        uint256[7] memory quantities;
        uint256 total;
        for (uint256 i; i < 7; ++i) {
            quantities[i] = held[i];
        }
        quantities[0] = quantities[0] * 103 / 100;
        quantities[1] = quantities[1] * 97 / 100;
        for (uint256 i; i < 7; ++i) {
            total += quantities[i];
        }
        uint256 assigned;
        for (uint256 i; i < 6; ++i) {
            ratios[i] = quantities[i] * 1e18 / total;
            assigned += ratios[i];
        }
        ratios[6] = 1e18 - assigned;
    }

    /// @dev First weekday 16:00 UTC at least 88 hours ahead whose proposal time, 73 hours earlier, is in the same
    ///      quarter: proposal, settlement and execution must share one quarter.
    function _executionTime(IndexController controller) private view returns (uint256 t) {
        t = (block.timestamp / 1 days + 4) * 1 days + 16 hours;
        while (true) {
            uint256 dayOfWeek = (t / 1 days + 4) % 7;
            if (
                dayOfWeek != 0 && dayOfWeek != 6
                    && controller.quarterAt(t - 73 hours) == controller.quarterAt(t)
            ) {
                return t;
            }
            t += 1 days;
        }
    }

    function _proposeLive(IndexController controller, uint256[7] memory ratios) private returns (bytes32) {
        IERC20 usdc = controller.bondCurrency();
        controller.oracle().syncUmaParams(controller.ASSERTION_IDENTIFIER(), address(usdc));
        uint256 bond = Math.max(controller.bondFloor(), controller.oracle().getMinimumBond(address(usdc)));
        address proposer = makeAddr("Local fork rebalance proposer");
        deal(address(usdc), proposer, bond);
        vm.startPrank(proposer);
        usdc.forceApprove(address(controller), bond);
        bytes32 assertionId = controller.propose(
            controller.currentQuarter(), ratios, "ipfs://local-fork-fixture", sha256(bytes(FIXTURE))
        );
        vm.stopPrank();
        return assertionId;
    }

    /// @dev After time travel, report each feed's fork-time answer as updated now. Prices are not changed.
    function _reportFeedsFresh(Valuation valuation) private {
        for (uint256 i; i < 8; ++i) {
            IAggregatorV3 feed = valuation.feeds(i);
            (, int256 answer,,,) = feed.latestRoundData();
            vm.mockCall(
                address(feed),
                abi.encodeWithSelector(IAggregatorV3.latestRoundData.selector),
                abi.encode(uint80(1), answer, block.timestamp, block.timestamp, uint80(1))
            );
        }
    }

    function _rebalanced(Vm.Log[] memory logs)
        private
        pure
        returns (uint256 navBefore, uint256 navAfter, uint256 sold, uint256 bought, uint256 legs)
    {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == M7CapVault.RebalanceLeg.selector) ++legs;
            if (logs[i].topics[0] == IndexController.Rebalanced.selector) {
                (navBefore, navAfter,, sold, bought) =
                    abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, uint256));
            }
        }
    }

    function _manifestSpacings(string memory manifest) private pure returns (int24[7] memory spacings) {
        for (uint256 i; i < 7; ++i) {
            string memory prefix = string.concat(".stocks[", vm.toString(i), "]");
            spacings[i] = int24(uint24(vm.parseJsonUint(manifest, string.concat(prefix, ".tick_spacing"))));
        }
    }

    function _startFork() private {
        vm.skip(!vm.envOr("BASE_FORK_TEST", false));
        string memory rpc = vm.envOr("BASE_RPC_URL", string("https://mainnet.base.org"));
        uint256 forkBlock = vm.envOr("BASE_FORK_BLOCK", uint256(0));
        if (forkBlock == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, forkBlock);
        assertEq(block.chainid, 8453);
        emit log_named_uint("Base fork block", block.number);
    }
}
