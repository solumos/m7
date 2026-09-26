// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {M7CapVault} from "../src/M7CapVault.sol";
import {USDCGateway} from "../src/USDCGateway.sol";
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
        USDCGateway gateway = new USDCGateway(IM7CapVault(address(vault)), address(this)); // default 1 bp fee
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
            assertEq(assets[i].balanceOf(address(gateway)), i == 7 ? gateway.accruedFees() : 0);
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
