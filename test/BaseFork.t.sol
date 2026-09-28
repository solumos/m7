// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {M7Vault} from "../src/M7Vault.sol";
import {USDCGateway} from "../src/USDCGateway.sol";
import {M7Lens} from "../src/M7Lens.sol";
import {IndexController} from "../src/IndexController.sol";
import {Valuation, IAggregatorV3, ICoinbaseOracleRegistry} from "../src/Valuation.sol";
import {IM7Vault} from "../src/interfaces/IM7Vault.sol";
import {ISlipstreamRouter, ISlipstreamFactory} from "../src/interfaces/ISlipstreamRouter.sol";
import {IPolicyRegistry} from "../src/interfaces/IB20Policy.sol";
import {VaultHarness} from "./mocks/VaultHarness.sol";

/// @dev Opt in with BASE_FORK_TEST=true and use Base's patched forge with FOUNDRY_BASE=true.
/// This is a local fork: only USDC is dealt; every B20 is acquired from its actual live-state pool.
contract BaseForkTest is VaultHarness {
    using SafeERC20 for IERC20;

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
        (M7Vault vault,) = _deployVault(assets, routes, router, factory, registry);
        USDCGateway gateway = new USDCGateway(IM7Vault(address(vault)));
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

    /// @dev The quarterly equal-weight reset through the live pinned pools with native B20 transfers. The seed holds
    ///      twice as much AAPLc by value as each other stock, so the reset sells AAPLc, pays the keeper and buys the
    ///      rest. Feeds are mocked only to report their fork-time answers as fresh in the next execution window.
    function testBaseNativeResetToEqualWeightsThroughLivePools() public {
        _startFork();
        IndexController controller = _deployFixtureController();
        M7Vault vault = M7Vault(payable(address(controller.vault())));
        uint256[7] memory spend = [uint256(300e6), 150e6, 150e6, 150e6, 150e6, 150e6, 150e6];
        vault.bootstrap(_buyWeighted(vault, spend), address(this));
        vm.warp(_nextWindow());
        Valuation valuation = controller.valuation();
        _reportFeedsFresh(valuation);
        address keeper = makeAddr("Base fork keeper");

        vm.recordLogs();
        uint256 gasBefore = gasleft();
        controller.rebalance(block.timestamp + 1 hours, keeper);
        emit log_named_uint("Reset gas", gasBefore - gasleft());
        (uint256 navBefore, uint256 navAfter, uint256 sold, uint256 bought, uint256 reward, uint256 legs) =
            _rebalanced(vm.getRecordedLogs());
        assertFalse(controller.rebalanceDue());
        assertEq(legs, 7);
        assertGt(sold, 0);
        assertGt(bought, 0);
        assertGt(vault.assets(7).balanceOf(keeper), 0);
        assertLe(
            navBefore - Math.min(navBefore, navAfter),
            (sold + bought) / 100 + reward,
            "loss beyond 1% of traded value plus the reward"
        );
        uint256[8] memory prices = valuation.snapshot();
        uint256[8] memory held = _backing(vault);
        (uint256[8] memory values,) = valuation.values(held, prices);
        for (uint256 i = 1; i < 7; ++i) {
            assertApproxEqRel(values[i], values[0], 0.003e18, "outside the 30 bp compliance band");
        }
        emit log_named_decimal_uint("NAV before (USD)", navBefore, 18);
        emit log_named_decimal_uint("NAV after (USD)", navAfter, 18);
        emit log_named_decimal_uint("Sold (USD)", sold, 18);
        emit log_named_decimal_uint("Bought (USD)", bought, 18);
        emit log_named_decimal_uint("Keeper reward (USD)", reward, 18);
    }

    /// @dev Receipt transfers and the resilient exit against the real policy registry and native stock transfers.
    function testBaseNativeTransferGasAndResilientRedemption() public {
        _startFork();
        IndexController controller = _deployFixtureController();
        M7Vault vault = M7Vault(payable(address(controller.vault())));
        vault.bootstrap(_buySeed(vault, 50e6), address(this));
        address holder = makeAddr("Base fork holder");
        address receiver = makeAddr("Base fork receiver");

        uint256 gasBefore = gasleft();
        require(vault.transfer(holder, 100e18));
        emit log_named_uint("M7 transfer gas, new recipient", gasBefore - gasleft());
        gasBefore = gasleft();
        require(vault.transfer(holder, 1e18));
        emit log_named_uint("M7 transfer gas, existing recipient", gasBefore - gasleft());

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
        M7Vault vault = M7Vault(payable(address(controller.vault())));
        M7Lens lens = new M7Lens(controller);
        vault.bootstrap(_buySeed(vault, 100e6), address(this));
        M7Lens.Value memory v = lens.value();
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
        (uint256 vaultValue,) = lens.totalValue();
        assertEq(vaultValue, v.nav);
        emit log_named_decimal_uint("Total value (USD)", vaultValue, 18);
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
        address predictedVault =
            vm.computeCreateAddress(address(this), uint256(vm.getNonce(address(this))) + 1);
        controller = new IndexController(IM7Vault(predictedVault), valuation);
        M7Vault vault = new M7Vault(
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
    function _buySeed(M7Vault vault, uint256 usdcPerStock) private returns (uint256[8] memory seed) {
        uint256[7] memory spend;
        for (uint256 i; i < 7; ++i) {
            spend[i] = usdcPerStock;
        }
        return _buyWeighted(vault, spend);
    }

    function _buyWeighted(M7Vault vault, uint256[7] memory spend) private returns (uint256[8] memory seed) {
        IERC20 usdc = vault.assets(7);
        ISlipstreamRouter router = vault.router();
        uint256 total;
        for (uint256 i; i < 7; ++i) {
            total += spend[i];
        }
        deal(address(usdc), address(this), total);
        usdc.forceApprove(address(router), total);
        for (uint256 i; i < 7; ++i) {
            seed[i] = router.exactInputSingle(
                ISlipstreamRouter.ExactInputSingleParams({
                    tokenIn: address(usdc),
                    tokenOut: address(vault.assets(i)),
                    tickSpacing: vault.tickSpacing(i),
                    recipient: address(this),
                    deadline: block.timestamp,
                    amountIn: spend[i],
                    amountOutMinimum: 1,
                    sqrtPriceLimitX96: 0
                })
            );
            vault.assets(i).forceApprove(address(vault), seed[i]);
        }
        usdc.forceApprove(address(router), 0);
    }

    function _backing(M7Vault vault) private view returns (uint256[8] memory held) {
        for (uint256 i; i < 8; ++i) {
            held[i] = vault.backing(i);
        }
    }

    /// @dev The first weekday 16:00 UTC after today: inside the valuation's execution window.
    function _nextWindow() private view returns (uint256 t) {
        t = (block.timestamp / 1 days + 1) * 1 days + 16 hours;
        while ((t / 1 days + 4) % 7 == 0 || (t / 1 days + 4) % 7 == 6) {
            t += 1 days;
        }
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
        returns (
            uint256 navBefore,
            uint256 navAfter,
            uint256 sold,
            uint256 bought,
            uint256 reward,
            uint256 legs
        )
    {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == M7Vault.RebalanceLeg.selector) ++legs;
            if (logs[i].topics[0] == IndexController.Rebalanced.selector) {
                (navBefore, navAfter,, sold, bought, reward) =
                    abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, uint256, uint256));
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
