// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {M7Vault} from "../src/M7Vault.sol";
import {USDCGateway} from "../src/USDCGateway.sol";
import {IM7Vault} from "../src/interfaces/IM7Vault.sol";
import {GatewayToken, GatewayFactory, GatewayRouter} from "./mocks/GatewayMocks.sol";
import {PolicyRegistryMock} from "./mocks/PolicyMocks.sol";
import {VaultHarness} from "./mocks/VaultHarness.sol";

contract USDCGatewayTest is VaultHarness {
    IERC20[8] internal assets;
    GatewayToken internal usdc;
    GatewayFactory internal factory;
    GatewayRouter internal router;
    M7Vault internal vault;
    USDCGateway internal gateway;
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        for (uint256 i; i < 8; ++i) {
            assets[i] = new GatewayToken(i == 7 ? 6 : 8);
        }
        usdc = GatewayToken(address(assets[7]));
        factory = new GatewayFactory();
        router = new GatewayRouter(address(factory), address(usdc));
        for (uint256 i; i < 7; ++i) {
            factory.setPool(address(usdc), address(assets[i]), 100, address(uint160(i + 100)));
        }
        (vault,) = _deployVault(assets, _spacings(100), router, factory, new PolicyRegistryMock());
        gateway = new USDCGateway(IM7Vault(address(vault)));

        uint256[8] memory seed;
        for (uint256 i; i < 8; ++i) {
            seed[i] = i == 7 ? 0 : (i + 1) * 100e8;
            GatewayToken(address(assets[i])).mint(address(this), seed[i]);
            GatewayToken(address(assets[i])).mint(address(router), 1_000_000e8);
            assets[i].approve(address(vault), seed[i]);
        }
        vault.bootstrap(seed, address(this));
        usdc.mint(address(vault), 25e6); // Incidental cash must participate in mint and redemption.
        usdc.mint(alice, 10_000e6);
        vm.prank(alice);
        usdc.approve(address(gateway), type(uint256).max);
    }

    function testMintBuysAllStocksReservesCashAndRefundsCaller() public {
        uint256[8] memory before = _vaultBalances();
        uint256[8] memory required = vault.quoteMint(10e18);
        vm.prank(alice);
        uint256 spent = gateway.mintWithUSDC(10e18, 100e6, bob, block.timestamp);
        assertEq(spent, 28.25e6);
        assertEq(vault.balanceOf(bob), 10e18);
        assertEq(usdc.balanceOf(alice), 10_000e6 - spent);
        assertEq(usdc.balanceOf(bob), 0);
        for (uint256 i; i < 8; ++i) {
            assertEq(assets[i].balanceOf(address(vault)), before[i] + required[i]);
            assertEq(assets[i].balanceOf(address(gateway)), 0);
            assertEq(assets[i].allowance(address(gateway), address(vault)), 0);
            assertEq(assets[i].allowance(address(gateway), address(router)), 0);
        }
    }

    function testMintAndRedeemDoNotConsumeDonatedGatewayBalances() public {
        for (uint256 i; i < 8; ++i) {
            GatewayToken(address(assets[i])).mint(address(gateway), 123);
        }
        vault.transfer(address(gateway), 1e18);
        vm.startPrank(alice);
        gateway.mintWithUSDC(10e18, 100e6, alice, block.timestamp);
        vault.approve(address(gateway), 10e18);
        uint256 received = gateway.redeemToUSDC(10e18, 28.25e6, bob, block.timestamp);
        vm.stopPrank();
        assertEq(received, 28.25e6);
        assertEq(usdc.balanceOf(bob), received);
        assertEq(vault.balanceOf(alice), 0);
        assertEq(vault.balanceOf(address(gateway)), 1e18);
        for (uint256 i; i < 8; ++i) {
            assertEq(assets[i].balanceOf(address(gateway)), 123);
            assertEq(assets[i].allowance(address(gateway), address(router)), 0);
        }
    }

    function testBuyFailureRollsBackAllTradesTransfersAndApprovals() public {
        router.configure(4, false, false);
        uint256[8] memory before = _vaultBalances();
        uint256 supply = vault.totalSupply();
        vm.prank(alice);
        vm.expectRevert("swap failed");
        gateway.mintWithUSDC(10e18, 100e6, alice, block.timestamp);
        assertEq(usdc.balanceOf(alice), 10_000e6);
        assertEq(vault.totalSupply(), supply);
        assertEq(router.swapCalls(), 0);
        for (uint256 i; i < 8; ++i) {
            assertEq(assets[i].balanceOf(address(vault)), before[i]);
            assertEq(assets[i].balanceOf(address(gateway)), 0);
            assertEq(assets[i].allowance(address(gateway), address(router)), 0);
        }
    }

    function testSellFailureRollsBackBurnAndEarlierSales() public {
        _giveShares(10e18);
        router.configure(4, false, false);
        uint256[8] memory before = _vaultBalances();
        uint256 supply = vault.totalSupply();
        vm.prank(alice);
        vm.expectRevert("swap failed");
        gateway.redeemToUSDC(10e18, 0, bob, block.timestamp);
        assertEq(vault.balanceOf(alice), 10e18);
        assertEq(vault.totalSupply(), supply);
        assertEq(usdc.balanceOf(bob), 0);
        assertEq(router.swapCalls(), 0);
        for (uint256 i; i < 8; ++i) {
            assertEq(assets[i].balanceOf(address(vault)), before[i]);
        }
    }

    function testAggregateMinimumProtectsRedemption() public {
        _giveShares(10e18);
        vm.prank(alice);
        vm.expectRevert(USDCGateway.InsufficientProceeds.selector);
        gateway.redeemToUSDC(10e18, 28.25e6 + 1, alice, block.timestamp);
        assertEq(vault.balanceOf(alice), 10e18);
    }

    function testInputMaximumProtectsPurchaseEvenWithDonatedUSDC() public {
        usdc.mint(address(gateway), 1_000e6);
        vm.prank(alice);
        vm.expectRevert("maximum input exceeded");
        gateway.mintWithUSDC(10e18, 28e6, alice, block.timestamp);
        assertEq(usdc.balanceOf(address(gateway)), 1_000e6);
        assertEq(usdc.balanceOf(alice), 10_000e6);
    }

    function testInputBelowRequiredCashReverts() public {
        vm.prank(alice);
        vm.expectRevert(USDCGateway.InsufficientUSDC.selector);
        gateway.mintWithUSDC(10e18, 0.25e6 - 1, alice, block.timestamp);
    }

    function testCallersCannotChooseRoutesOnlyTheVaultsPinnedPools() public {
        vm.prank(alice);
        gateway.mintWithUSDC(10e18, 100e6, alice, block.timestamp);
        assertEq(router.lastTickSpacing(), 100);
        assertEq(vault.tickSpacing(4), 100);
        assertEq(address(gateway.router()), address(router));
        assertEq(address(gateway.usdc()), address(usdc));
    }

    function testGatewayAcceptsEthOnlyFromRouter() public {
        vm.deal(alice, 1);
        vm.prank(alice);
        (bool fromOther,) = address(gateway).call{value: 1}("");
        assertFalse(fromOther);
        vm.deal(address(router), 1);
        vm.prank(address(router));
        (bool fromRouter,) = address(gateway).call{value: 1}("");
        assertTrue(fromRouter);
    }

    function testExpiredAndInvalidRequestsRevertBeforeTransfers() public {
        vm.warp(100);
        vm.startPrank(alice);
        vm.expectRevert(USDCGateway.DeadlineExpired.selector);
        gateway.mintWithUSDC(10e18, 100e6, alice, 99);
        vm.expectRevert(USDCGateway.DeadlineExpired.selector);
        gateway.redeemToUSDC(10e18, 0, alice, 99);
        vm.expectRevert(USDCGateway.InvalidRequest.selector);
        gateway.mintWithUSDC(0, 100e6, alice, 100);
        vm.expectRevert(USDCGateway.InvalidRequest.selector);
        gateway.mintWithUSDC(10e18, 100e6, address(gateway), 100);
        vm.stopPrank();
        assertEq(usdc.balanceOf(alice), 10_000e6);
    }

    function testShortOutputCannotUseDonatedStockToMint() public {
        GatewayToken(address(assets[0])).mint(address(gateway), 10e8);
        router.configure(0, true, false);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(USDCGateway.UnexpectedBalance.selector, 0));
        gateway.mintWithUSDC(10e18, 100e6, alice, block.timestamp);
        assertEq(assets[0].balanceOf(address(gateway)), 10e8);
    }

    function testPartialSaleRevertsInsteadOfStrandingUserStock() public {
        _giveShares(10e18);
        router.configure(0, false, true);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(USDCGateway.UnexpectedBalance.selector, 0));
        gateway.redeemToUSDC(10e18, 0, alice, block.timestamp);
        assertEq(vault.balanceOf(alice), 10e18);
    }

    function testBlockedConstituentMakesExitAtomic() public {
        _giveShares(10e18);
        GatewayToken(address(assets[4])).setBlocked(true);
        vm.prank(alice);
        vm.expectRevert("issuer blocked transfer");
        gateway.redeemToUSDC(10e18, 0, alice, block.timestamp);
        assertEq(vault.balanceOf(alice), 10e18);
    }

    function testRouterCannotReenterGateway() public {
        router.setReentry(
            address(gateway), abi.encodeCall(gateway.mintWithUSDC, (10e18, 100e6, alice, block.timestamp))
        );
        vm.prank(alice);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        gateway.mintWithUSDC(10e18, 100e6, alice, block.timestamp);
        assertEq(usdc.balanceOf(alice), 10_000e6);
    }

    function testConstructorRejectsMissingVault() public {
        vm.expectRevert(USDCGateway.InvalidConfiguration.selector);
        new USDCGateway(IM7Vault(address(0)));
    }

    function testFuzzRoundTripNeverSpendsMoreThanMaxOrPaysOutGatewayDonations(uint256 shares) public {
        shares = bound(shares, 1e15, 1_000e18);
        uint256[8] memory amounts = vault.quoteMint(shares);
        uint256 expectedCost = amounts[7];
        for (uint256 i; i < 7; ++i) {
            expectedCost += (amounts[i] + 99) / 100;
        }
        usdc.mint(address(gateway), 17e6);
        vm.startPrank(alice);
        uint256 spent = gateway.mintWithUSDC(shares, expectedCost + 100, alice, block.timestamp);
        vault.approve(address(gateway), shares);
        uint256 received = gateway.redeemToUSDC(shares, 0, alice, block.timestamp);
        vm.stopPrank();
        assertEq(spent, expectedCost);
        assertLe(received, spent);
        assertEq(usdc.balanceOf(address(gateway)), 17e6);
        assertEq(vault.balanceOf(alice), 0);
        for (uint256 i; i < 7; ++i) {
            assertEq(assets[i].balanceOf(address(gateway)), 0);
        }
    }

    function _giveShares(uint256 shares) private {
        vault.transfer(alice, shares);
        vm.prank(alice);
        vault.approve(address(gateway), shares);
    }

    function _vaultBalances() private view returns (uint256[8] memory result) {
        for (uint256 i; i < 8; ++i) {
            result[i] = assets[i].balanceOf(address(vault));
        }
    }
}
