// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {M7CapVault} from "../src/M7CapVault.sol";
import {USDCGateway} from "../src/USDCGateway.sol";
import {IM7CapVault} from "../src/interfaces/IM7CapVault.sol";
import {GatewayToken, GatewayFactory, GatewayRouter} from "./mocks/GatewayMocks.sol";
import {PolicyRegistryMock} from "./mocks/PolicyMocks.sol";
import {VaultHarness} from "./mocks/VaultHarness.sol";

/// @dev The owner-controlled USDC trade fee: 1 bp by default, at most 10 bp, claimable only once charged.
contract GatewayFeeTest is VaultHarness {
    GatewayToken usdc;
    GatewayRouter router;
    M7CapVault vault;
    USDCGateway gateway;
    address owner = address(0x0A11);
    address alice = address(0xa11ce);
    address bob = address(0xb0b);
    uint256 constant COST = 28.25e6; // exact basket cost of 10 shares at the mock venue's prices

    function setUp() public {
        IERC20[8] memory assets;
        for (uint256 i; i < 8; ++i) {
            assets[i] = new GatewayToken(i == 7 ? 6 : 8);
        }
        usdc = GatewayToken(address(assets[7]));
        GatewayFactory factory = new GatewayFactory();
        router = new GatewayRouter(address(factory), address(usdc));
        for (uint256 i; i < 7; ++i) {
            factory.setPool(address(usdc), address(assets[i]), 100, address(uint160(i + 100)));
        }
        (vault,) = _deployVault(assets, _spacings(100), router, factory, new PolicyRegistryMock());
        gateway = new USDCGateway(IM7CapVault(address(vault)), owner);
        uint256[8] memory seed;
        for (uint256 i; i < 8; ++i) {
            seed[i] = i == 7 ? 0 : (i + 1) * 100e8;
            GatewayToken(address(assets[i])).mint(address(this), seed[i]);
            GatewayToken(address(assets[i])).mint(address(router), 1_000_000e8);
            assets[i].approve(address(vault), seed[i]);
        }
        vault.bootstrap(seed, address(this));
        usdc.mint(address(vault), 25e6);
        usdc.mint(alice, 10_000e6);
        vm.prank(alice);
        usdc.approve(address(gateway), type(uint256).max);
    }

    function _mintAndRedeem() private returns (uint256 spent, uint256 received) {
        vm.startPrank(alice);
        spent = gateway.mintWithUSDC(10e18, 100e6, alice, block.timestamp);
        vault.approve(address(gateway), 10e18);
        received = gateway.redeemToUSDC(10e18, 0, bob, block.timestamp);
        vm.stopPrank();
    }

    function testDefaultOneBasisPointOnMintAndRedeem() public {
        assertEq(gateway.feeBps(), 1);
        assertEq(gateway.owner(), owner);
        assertEq(gateway.previewFee(COST), 2825);
        (uint256 spent, uint256 received) = _mintAndRedeem();
        assertEq(spent, COST + 2825);
        assertEq(received, COST - 2825);
        assertEq(usdc.balanceOf(alice), 10_000e6 - spent);
        assertEq(usdc.balanceOf(bob), received);
        assertEq(gateway.accruedFees(), 5650);
        assertEq(usdc.balanceOf(address(gateway)), 5650);
    }

    function testUserLimitsIncludeTheFee() public {
        vm.prank(alice);
        vm.expectRevert(USDCGateway.InsufficientUSDC.selector);
        gateway.mintWithUSDC(10e18, COST, alice, block.timestamp); // the fee no longer fits
        vm.prank(alice);
        assertEq(gateway.mintWithUSDC(10e18, COST + 2825, alice, block.timestamp), COST + 2825);
        vm.startPrank(alice);
        vault.approve(address(gateway), 10e18);
        vm.expectRevert(USDCGateway.InsufficientProceeds.selector);
        gateway.redeemToUSDC(10e18, COST, bob, block.timestamp);
        vm.stopPrank();
    }

    function testOnlyTheOwnerSetsTheFeeWithinTheCapOrTurnsItOff() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        gateway.setFee(0);
        vm.startPrank(owner);
        vm.expectRevert(USDCGateway.FeeTooHigh.selector);
        gateway.setFee(11);
        gateway.setFee(10);
        assertEq(gateway.previewFee(COST), 28250);
        gateway.setFee(0);
        vm.stopPrank();
        (uint256 spent, uint256 received) = _mintAndRedeem();
        assertEq(spent, COST);
        assertEq(received, COST);
        assertEq(gateway.accruedFees(), 0);
    }

    function testOwnerClaimsOnlyChargedFeesNeverDonations() public {
        usdc.mint(address(gateway), 1_000e6); // a donation
        _mintAndRedeem();
        assertEq(gateway.accruedFees(), 5650);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        gateway.claimFees(alice, 1);
        vm.startPrank(owner);
        vm.expectRevert(USDCGateway.InsufficientFees.selector);
        gateway.claimFees(owner, 5651);
        vm.expectRevert(USDCGateway.InsufficientFees.selector);
        gateway.claimFees(owner, 0);
        vm.expectRevert(USDCGateway.InvalidRequest.selector);
        gateway.claimFees(address(0), 1);
        gateway.claimFees(owner, 5650);
        vm.stopPrank();
        assertEq(usdc.balanceOf(owner), 5650);
        assertEq(gateway.accruedFees(), 0);
        assertEq(usdc.balanceOf(address(gateway)), 1_000e6);
    }

    function testTwoStepOwnershipAndRenounceOnlyWhenFeeFree() public {
        address next = address(0x0B22);
        vm.prank(owner);
        gateway.transferOwnership(next);
        assertEq(gateway.owner(), owner);
        assertEq(gateway.pendingOwner(), next);
        vm.prank(next);
        gateway.acceptOwnership();
        assertEq(gateway.owner(), next);

        _mintAndRedeem();
        vm.startPrank(next);
        vm.expectRevert(USDCGateway.FeesOutstanding.selector);
        gateway.renounceOwnership();
        gateway.setFee(0);
        vm.expectRevert(USDCGateway.FeesOutstanding.selector);
        gateway.renounceOwnership();
        gateway.claimFees(next, gateway.accruedFees());
        gateway.renounceOwnership();
        vm.stopPrank();
        assertEq(gateway.owner(), address(0));
        assertEq(gateway.feeBps(), 0); // permanently fee-free
    }

    function testFuzzFeeMatchesRateAndNeverExceedsUserLimits(uint16 rate, uint256 shares, uint256 slack)
        public
    {
        rate = uint16(bound(rate, 0, gateway.MAX_FEE_BPS()));
        shares = bound(shares, 1e15, 500e18);
        slack = bound(slack, 0, 1e6);
        vm.prank(owner);
        gateway.setFee(rate);
        uint256[8] memory amounts = vault.quoteMint(shares);
        uint256 cost = amounts[7];
        for (uint256 i; i < 7; ++i) {
            cost += (amounts[i] + 99) / 100;
        }
        uint256 fee = Math.mulDiv(cost, rate, 10_000, Math.Rounding.Ceil);
        vm.startPrank(alice);
        uint256 spent = gateway.mintWithUSDC(shares, cost + fee + slack, alice, block.timestamp);
        vault.approve(address(gateway), shares);
        uint256[8] memory out = vault.quoteRedeem(shares);
        uint256 gross = out[7];
        for (uint256 i; i < 7; ++i) {
            gross += out[i] / 100;
        }
        uint256 exitFee = Math.mulDiv(gross, rate, 10_000, Math.Rounding.Ceil);
        uint256 received = gateway.redeemToUSDC(shares, gross - exitFee, alice, block.timestamp);
        vm.stopPrank();
        assertEq(spent, cost + fee);
        assertEq(received, gross - exitFee);
        assertEq(gateway.accruedFees(), fee + exitFee);
        assertEq(usdc.balanceOf(address(gateway)), fee + exitFee);
    }
}
