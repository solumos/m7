// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Vm} from "forge-std/Vm.sol";
import {M7Vault} from "../src/M7Vault.sol";
import {IndexController} from "../src/IndexController.sol";
import {Valuation, IAggregatorV3, ICoinbaseOracleRegistry} from "../src/Valuation.sol";
import {IM7Vault} from "../src/interfaces/IM7Vault.sol";
import {ISlipstreamRouter, ISlipstreamFactory} from "../src/interfaces/ISlipstreamRouter.sol";
import {IPolicyRegistry} from "../src/interfaces/IB20Policy.sol";
import {VaultHarness} from "./mocks/VaultHarness.sol";

interface ISlipstreamPool {
    function token0() external view returns (address);
}

/// @dev Any contract may call `rebalance`. This one moves the pinned pools of the stocks the reset will buy, triggers
///      the reset, and sells back, all in one transaction. It also collects the caller's reward.
contract ResetSandwich {
    using SafeERC20 for IERC20;

    ISlipstreamRouter public immutable router;
    IERC20 public immutable usdc;

    constructor(ISlipstreamRouter router_, IERC20 usdc_) {
        router = router_;
        usdc = usdc_;
    }

    receive() external payable {}

    function run(
        IndexController controller,
        IERC20[] calldata stocks,
        int24[] calldata spacings,
        uint256[] calldata frontRunUsdc
    ) external {
        for (uint256 i; i < stocks.length; ++i) {
            _swap(usdc, stocks[i], spacings[i], frontRunUsdc[i]);
        }
        controller.rebalance(block.timestamp + 1 hours, address(this));
        for (uint256 i; i < stocks.length; ++i) {
            _swap(stocks[i], usdc, spacings[i], stocks[i].balanceOf(address(this)));
        }
    }

    function _swap(IERC20 tokenIn, IERC20 tokenOut, int24 spacing, uint256 amountIn) private {
        if (amountIn == 0) return;
        tokenIn.forceApprove(address(router), amountIn);
        router.exactInputSingle(
            ISlipstreamRouter.ExactInputSingleParams({
                tokenIn: address(tokenIn),
                tokenOut: address(tokenOut),
                tickSpacing: spacing,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: amountIn,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );
    }
}

/// @dev Third review (docs/AUDIT-3.md): its live-pool reproductions, converted to regression tests of the fixed reset,
///      against live Base pools with native B20 execution. Opt in like BaseForkTest:
///      BASE_FORK_TEST=true, Base's forge and FOUNDRY_BASE=beryl|cobalt. Only USDC is dealt; every stock is bought from
///      its pinned pool. After the seed purchases, each stock feed is mocked to report its pool's own mid price (and
///      USDC exactly $1), so every reset starts from pools that agree with the oracle.
contract Audit3ForkTest is VaultHarness {
    using SafeERC20 for IERC20;

    address constant KEEPER = address(0xBEEF);
    uint256 constant META = 3;
    uint256 constant TSLA = 6;
    // Blocks at which docs/AUDIT-3.md records each result. Pool liquidity moves, so other blocks give other numbers:
    // AUDIT3_FORK_BLOCK overrides them (0 = latest). Pinned blocks need an RPC that still serves their state.
    uint256 constant SANDWICH_BLOCK = 51_891_228;
    uint256 constant CAPACITY_BLOCK = 51_891_137;
    uint256 constant COMPLIANCE_BLOCK = 51_888_052;

    /// E-01 regression: the same $300k vault and front-runs as the review, at the same block. Before the fix, pushing
    /// TSLAc with $40k took $67.62 from holders and METAc $50k plus TSLAc $40k took $128.16. Now a push beyond 25 ticks
    /// of a pool's 10-minute average makes the tranche revert `PoolMoved`, and a smaller one can only worsen a trade of
    /// at most $10k by 25 ticks: every sandwich that still executes costs the attacker more than holders lose.
    function testAudit3SandwichIsRefusedOrUnprofitable() public {
        _startFork(SANDWICH_BLOCK);
        (IndexController controller, M7Vault vault) = _sandwichFixture();
        uint256 snap = vm.snapshotState();
        uint256 keeperBefore = vault.assets(7).balanceOf(KEEPER); // the address holds USDC on mainnet
        controller.rebalance(block.timestamp + 1 hours, KEEPER);
        uint256 honest = _nav(controller.valuation(), vault, controller.valuation().snapshot());
        uint256 reward = vault.assets(7).balanceOf(KEEPER) - keeperBefore;
        emit log_named_decimal_uint("Honest first tranche: NAV after (USD)", honest, 18);
        emit log_named_decimal_uint("  reward (USDC)", reward, 6);

        uint256[2][8] memory frontRuns = [
            [uint256(0), 2_000e6],
            [uint256(0), 5_000e6],
            [uint256(0), 10_000e6],
            [uint256(0), 20_000e6],
            [uint256(0), 40_000e6],
            [uint256(10_000e6), 10_000e6],
            [uint256(50_000e6), 40_000e6],
            [uint256(90_000e6), 50_000e6]
        ];
        for (uint256 k; k < frontRuns.length; ++k) {
            vm.revertToState(snap);
            _logSandwich(controller, vault, frontRuns[k], honest, reward);
        }
        // Pushing METAc as well moves its pool beyond 25 ticks: those tranches are refused.
        for (uint256 k = 6; k < 8; ++k) {
            vm.revertToState(snap);
            (bool ran,, bytes memory reason) = _attack(controller, vault, frontRuns[k]);
            assertFalse(ran);
            assertEq(bytes4(reason), IndexController.PoolMoved.selector);
        }
    }

    /// $300k with AAPLc overweight and METAc and TSLAc 42% under target, feeds at the pools' mid prices.
    function _sandwichFixture() private returns (IndexController controller, M7Vault vault) {
        controller = _deployFixtureController();
        vault = M7Vault(payable(address(controller.vault())));
        // AAPLc, AMZNc, GOOGLc, METAc, MSFTc, NVDAc, TSLAc
        uint256[7] memory spend =
            [uint256(90_000e6), 40_000e6, 40_000e6, 25_000e6, 40_000e6, 40_000e6, 25_000e6];
        vault.bootstrap(_buyWeighted(vault, spend), address(this));
        vm.warp(_nextWindow());
        _reportPoolMidAsFeeds(controller.valuation(), vault);
        emit log_named_decimal_uint(
            "NAV before (USD)", _nav(controller.valuation(), vault, controller.valuation().snapshot()), 18
        );
    }

    function _logSandwich(
        IndexController controller,
        M7Vault vault,
        uint256[2] memory frontRun,
        uint256 honest,
        uint256 reward
    ) private {
        (bool ran, int256 profit, bytes memory reason) = _attack(controller, vault, frontRun);
        emit log_named_uint("Front-run METAc (USDC)", frontRun[0] / 1e6);
        emit log_named_uint("Front-run TSLAc (USDC)", frontRun[1] / 1e6);
        if (!ran) {
            emit log_named_bytes("  reverted", reason);
            return;
        }
        uint256 navAfter = _nav(controller.valuation(), vault, controller.valuation().snapshot());
        int256 trading = profit - int256(reward);
        uint256 extraLoss = honest - Math.min(honest, navAfter);
        emit log_named_decimal_int("  attacker result excluding the reward (USDC)", trading, 6);
        emit log_named_decimal_uint("  holders' extra loss vs honest (USD)", extraLoss, 18);
        assertLt(trading, 0, "a sandwich still pays");
        assertLe(extraLoss, 25e18, "more than 25 bp of two $10k trades");
    }

    /// E-02 regression: the $182k TSLAc sale that could not execute now completes in tranches of at most $10k per
    /// trade. On a fork nothing arbitrages the pools between tranches, so before each one the oracle is set to the
    /// pools' mid prices, as arbitrage keeps them aligned on mainnet.
    function testAudit3LargeSaleCompletesInTranches() public {
        _startFork(CAPACITY_BLOCK);
        IndexController controller = _deployFixtureController();
        M7Vault vault = M7Vault(payable(address(controller.vault())));
        uint256[7] memory spend =
            [uint256(40_000e6), 40_000e6, 40_000e6, 40_000e6, 40_000e6, 40_000e6, 250_000e6];
        vault.bootstrap(_buyWeighted(vault, spend), address(this));
        vm.warp(_nextWindow());
        Valuation valuation = controller.valuation();
        _reportPoolMidAsFeeds(valuation, vault);
        emit log_named_decimal_uint(
            "TSLAc to sell (USD)", _surplus(valuation, vault, valuation.snapshot(), TSLA), 18
        );
        uint256 tranches = _completeInTranches(controller, vault, valuation);
        emit log_named_uint("Tranches", tranches);
        assertGe(tranches, 18);
        _assertEqualValue(vault, valuation);
    }

    /// E-02 regression: the $900k vault with METAc and TSLAc 42% under target, which failed `NotCompliant`, now
    /// completes in tranches.
    function testAudit3LargePurchasesCompleteInTranches() public {
        _startFork(COMPLIANCE_BLOCK);
        IndexController controller = _deployFixtureController();
        M7Vault vault = M7Vault(payable(address(controller.vault())));
        uint256[7] memory spend =
            [uint256(270_000e6), 120_000e6, 120_000e6, 75_000e6, 120_000e6, 120_000e6, 75_000e6];
        vault.bootstrap(_buyWeighted(vault, spend), address(this));
        vm.warp(_nextWindow());
        Valuation valuation = controller.valuation();
        _reportPoolMidAsFeeds(valuation, vault);
        uint256 tranches = _completeInTranches(controller, vault, valuation);
        emit log_named_uint("Tranches", tranches);
        assertGe(tranches, 5);
        _assertEqualValue(vault, valuation);
    }

    // ------------------------------------------------------------------ helpers

    function _attack(IndexController controller, M7Vault vault, uint256[2] memory frontRun)
        private
        returns (bool ran, int256 profit, bytes memory reason)
    {
        IERC20 usdc = vault.assets(7);
        ResetSandwich attacker = new ResetSandwich(vault.router(), usdc);
        uint256 capital = frontRun[0] + frontRun[1] + 1e6;
        deal(address(usdc), address(attacker), capital);
        (IERC20[] memory stocks, int24[] memory spacings, uint256[] memory amounts) = _legs(vault, frontRun);
        try attacker.run(controller, stocks, spacings, amounts) {
            ran = true;
            profit = int256(usdc.balanceOf(address(attacker))) - int256(capital);
        } catch (bytes memory why) {
            reason = why;
        }
    }

    function _legs(M7Vault vault, uint256[2] memory frontRun)
        private
        view
        returns (IERC20[] memory stocks, int24[] memory spacings, uint256[] memory amounts)
    {
        stocks = new IERC20[](2);
        spacings = new int24[](2);
        amounts = new uint256[](2);
        (stocks[0], stocks[1]) = (vault.assets(META), vault.assets(TSLA));
        (spacings[0], spacings[1]) = (vault.tickSpacing(META), vault.tickSpacing(TSLA));
        (amounts[0], amounts[1]) = (frontRun[0], frontRun[1]);
    }

    /// Tranches until the quarter's reset completes, each half an hour after the last within the execution window,
    /// with the oracle set to the pools' mid prices before each. Every sale stays within the $10k cap.
    function _completeInTranches(IndexController controller, M7Vault vault, Valuation valuation)
        private
        returns (uint256 tranches)
    {
        // An unfinished reset carries on into the next quarter, whose first tranche continues the same work.
        while (!controller.executedQuarter(controller.currentQuarter())) {
            if (tranches != 0) {
                uint256 t = block.timestamp + controller.TRANCHE_COOLDOWN();
                if (t % 1 days >= 20 hours) t = (t / 1 days + 1) * 1 days + 15 hours;
                while ((t / 1 days + 4) % 7 == 0 || (t / 1 days + 4) % 7 == 6) {
                    t += 1 days;
                }
                vm.warp(t);
                _reportPoolMidAsFeeds(valuation, vault);
            }
            vm.recordLogs();
            controller.rebalance(block.timestamp + 1 hours, KEEPER);
            ++tranches;
            _assertSalesCapped(vm.getRecordedLogs(), valuation.snapshot());
            assertLt(tranches, 40, "the reset does not converge");
        }
    }

    function _assertSalesCapped(Vm.Log[] memory logs, uint256[8] memory prices) private pure {
        for (uint256 k; k < logs.length; ++k) {
            if (logs[k].topics[0] != M7Vault.RebalanceLeg.selector) continue;
            uint256 tokenIn = uint256(logs[k].topics[1]);
            if (tokenIn == 7) continue;
            (uint256 amountIn,) = abi.decode(logs[k].data, (uint256, uint256));
            assertLe(amountIn * prices[tokenIn] / 1e8, 10_000e18, "a sale above the $10k cap");
        }
    }

    function _assertEqualValue(M7Vault vault, Valuation valuation) private view {
        uint256[8] memory prices = valuation.snapshot();
        uint256 first = vault.backing(0) * prices[0] / 1e8;
        for (uint256 i = 1; i < 7; ++i) {
            assertApproxEqRel(vault.backing(i) * prices[i] / 1e8, first, 0.004e18, "not equal value");
        }
    }

    function _nav(Valuation valuation, M7Vault vault, uint256[8] memory prices)
        private
        view
        returns (uint256 nav)
    {
        uint256[8] memory held;
        for (uint256 i; i < 8; ++i) {
            held[i] = vault.backing(i);
        }
        (, nav) = valuation.values(held, prices);
    }

    function _deficit(Valuation valuation, M7Vault vault, uint256[8] memory prices, uint256 index)
        private
        view
        returns (uint256)
    {
        uint256 nav = _nav(valuation, vault, prices);
        uint256 value = vault.backing(index) * prices[index] / 1e8;
        return nav / 7 > value ? nav / 7 - value : 0;
    }

    function _surplus(Valuation valuation, M7Vault vault, uint256[8] memory prices, uint256 index)
        private
        view
        returns (uint256)
    {
        uint256 nav = _nav(valuation, vault, prices);
        uint256 value = vault.backing(index) * prices[index] / 1e8;
        return value > nav / 7 ? value - nav / 7 : 0;
    }

    /// @dev Each stock feed reports its pinned pool's mid price in USDC; the USDC feed reports exactly $1.
    function _reportPoolMidAsFeeds(Valuation valuation, M7Vault vault) private {
        IERC20 usdc = vault.assets(7);
        for (uint256 i; i < 8; ++i) {
            int256 answer = 1e8;
            if (i < 7) {
                address pool =
                    vault.factory().getPool(address(vault.assets(i)), address(usdc), vault.tickSpacing(i));
                (, bytes memory data) = pool.staticcall(abi.encodeWithSignature("slot0()"));
                uint256 sqrtPrice = abi.decode(data, (uint256));
                // USDC per whole stock, 8 decimals: 1e10 / (stock raw per USDC raw), or its inverse by token order.
                answer = ISlipstreamPool(pool).token0() == address(usdc)
                    ? int256(Math.mulDiv(Math.mulDiv(1e10, 1 << 96, sqrtPrice), 1 << 96, sqrtPrice))
                    : int256(Math.mulDiv(Math.mulDiv(1e10, sqrtPrice, 1 << 96), sqrtPrice, 1 << 96));
            }
            vm.mockCall(
                address(valuation.feeds(i)),
                abi.encodeWithSelector(IAggregatorV3.latestRoundData.selector),
                abi.encode(uint80(1), answer, block.timestamp, block.timestamp, uint80(1))
            );
        }
    }

    function _reason(bytes memory reason) private pure returns (string memory) {
        if (reason.length >= 68 && bytes4(reason) == bytes4(keccak256("Error(string)"))) {
            bytes memory data = new bytes(reason.length - 4);
            for (uint256 i; i < data.length; ++i) {
                data[i] = reason[i + 4];
            }
            return abi.decode(data, (string));
        }
        return vm.toString(reason);
    }

    function _deployFixtureController() private returns (IndexController controller) {
        string memory manifest = vm.readFile("config/base.json");
        IERC20[8] memory assets;
        address[8] memory assetAddresses;
        IAggregatorV3[8] memory feeds;
        int24[7] memory spacings;
        for (uint256 i; i < 7; ++i) {
            string memory prefix = string.concat(".stocks[", vm.toString(i), "]");
            assetAddresses[i] = vm.parseJsonAddress(manifest, string.concat(prefix, ".address"));
            assets[i] = IERC20(assetAddresses[i]);
            feeds[i] = IAggregatorV3(vm.parseJsonAddress(manifest, string.concat(prefix, ".feed")));
            spacings[i] = int24(uint24(vm.parseJsonUint(manifest, string.concat(prefix, ".tick_spacing"))));
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
            spacings,
            address(controller),
            ISlipstreamRouter(vm.parseJsonAddress(manifest, ".venue.router")),
            ISlipstreamFactory(vm.parseJsonAddress(manifest, ".venue.factory")),
            IPolicyRegistry(vm.parseJsonAddress(manifest, ".policy_registry")),
            address(this)
        );
        assertEq(address(vault), predictedVault);
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

    /// @dev The first weekday 16:00 UTC after today: inside the valuation's execution window.
    function _nextWindow() private view returns (uint256 t) {
        t = (block.timestamp / 1 days + 1) * 1 days + 16 hours;
        while ((t / 1 days + 4) % 7 == 0 || (t / 1 days + 4) % 7 == 6) {
            t += 1 days;
        }
    }

    /// @return pinned Whether the fork is at the block the report records for this test.
    function _startFork(uint256 recorded) private returns (bool pinned) {
        vm.skip(!vm.envOr("BASE_FORK_TEST", false));
        string memory rpc = vm.envOr("BASE_RPC_URL", string("https://mainnet.base.org"));
        uint256 forkBlock = vm.envOr("AUDIT3_FORK_BLOCK", recorded);
        if (forkBlock == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, forkBlock);
        assertEq(block.chainid, 8453);
        emit log_named_uint("Base fork block", block.number);
        return forkBlock == recorded;
    }
}
