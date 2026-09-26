// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {M7CapVault} from "../src/M7CapVault.sol";
import {Swap} from "../src/Types.sol";
import {VaultTestToken, VaultTestRouter} from "./M7CapVault.t.sol";
import {PolicyRegistryMock} from "./mocks/PolicyMocks.sol";
import {ControllerStub, VaultHarness} from "./mocks/VaultHarness.sol";

/// @dev D-01 and N-05: a leg that cannot move becomes the redeemer's claim instead of blocking the whole exit.
contract VaultClaimsTest is VaultHarness {
    M7CapVault vault;
    ControllerStub stub;
    IERC20[8] tokens;
    VaultTestRouter router;
    uint256[8] seed;
    uint256[8] noMinimum;
    address bob = address(0xb0b);
    address carol = address(0xca701);

    function setUp() public {
        for (uint256 i; i < 8; ++i) {
            tokens[i] = IERC20(address(new VaultTestToken(i == 7 ? 6 : 8)));
            VaultTestToken(address(tokens[i])).mint(address(this), 1e30);
            if (i < 7) seed[i] = (i + 1) * 1e8;
        }
        router = new VaultTestRouter();
        (vault, stub) = _deployVault(tokens, _spacings(10), router, router, new PolicyRegistryMock());
        for (uint256 i; i < 8; ++i) {
            tokens[i].approve(address(vault), type(uint256).max);
        }
        vault.bootstrap(seed, address(this));
        require(tokens[7].transfer(address(vault), 50e6)); // incidental cash makes USDC a leg too
    }

    function _token(uint256 index) private view returns (VaultTestToken) {
        return VaultTestToken(address(tokens[index]));
    }

    function testFrozenStockDefersOnlyThatLegAndNothingIsForfeited() public {
        uint256[8] memory entitled = vault.quoteRedeem(100e18);
        uint256 supplyBefore = vault.totalSupply();
        uint256 backingBefore = vault.backing(6);
        _token(6).setFrozen(true);
        vm.expectRevert("frozen"); // the all-or-nothing path still reverts
        vault.redeemBasket(100e18, entitled, bob, block.timestamp);

        (uint256[8] memory delivered, uint256[8] memory deferred) =
            vault.redeemBasketWithClaims(100e18, entitled, bob, block.timestamp);
        for (uint256 i; i < 8; ++i) {
            assertEq(delivered[i] + deferred[i], entitled[i]);
            if (i == 6) continue;
            assertEq(deferred[i], 0);
            assertEq(tokens[i].balanceOf(bob), entitled[i]);
        }
        assertEq(deferred[6], entitled[6]);
        assertEq(vault.claimOf(address(this))[6], entitled[6]);
        assertEq(vault.reserved(6), entitled[6]);
        // The reserved stock stays in the vault but no longer backs shares; per-share backing is unchanged.
        assertEq(tokens[6].balanceOf(address(vault)), seed[6]);
        assertEq(vault.backing(6), backingBefore - entitled[6]);
        assertEq(vault.backing(6) * supplyBefore, backingBefore * vault.totalSupply());

        _token(6).setFrozen(false);
        vault.withdrawClaim(6, entitled[6], carol);
        assertEq(tokens[6].balanceOf(carol), entitled[6]);
        assertEq(vault.reserved(6), 0);
        assertEq(vault.claimOf(address(this))[6], 0);
    }

    function testPausedUsdcDefersTheCashLeg() public {
        uint256[8] memory entitled = vault.quoteRedeem(100e18);
        assertGt(entitled[7], 0);
        _token(7).setFrozen(true);
        (uint256[8] memory delivered, uint256[8] memory deferred) =
            vault.redeemBasketWithClaims(100e18, noMinimum, bob, block.timestamp);
        assertEq(deferred[7], entitled[7]);
        for (uint256 i; i < 7; ++i) {
            assertEq(delivered[i], entitled[i]);
        }
        // Issuance keeps quoting from backing, which excludes the reserved USDC.
        uint256[8] memory quote = vault.quoteMint(1e18);
        assertEq(quote[7], Math.mulDiv(50e6 - entitled[7], 1e18, vault.totalSupply(), Math.Rounding.Ceil));
    }

    function testReservedBalancesAreExcludedFromRebalancing() public {
        _token(6).setFrozen(true);
        (, uint256[8] memory deferred) = vault.redeemBasketWithClaims(500e18, noMinimum, bob, block.timestamp);
        _token(6).setFrozen(false);
        Swap[] memory sell = new Swap[](1);
        sell[0] = Swap({tokenIn: 6, tokenOut: 7, amountIn: vault.backing(6) + 1, minAmountOut: 1});
        vm.expectRevert(abi.encodeWithSelector(M7CapVault.ExceedsBacking.selector, 6));
        stub.rebalance(sell, block.timestamp);
        assertEq(tokens[6].balanceOf(address(vault)) - vault.backing(6), deferred[6]);
    }

    function testPartialWithdrawalAndInvalidRequests() public {
        _token(3).setFrozen(true);
        (, uint256[8] memory deferred) = vault.redeemBasketWithClaims(100e18, noMinimum, bob, block.timestamp);
        uint256 owed = deferred[3];
        vm.expectRevert("frozen"); // still frozen: the claim stays intact
        vault.withdrawClaim(3, owed, carol);
        _token(3).setFrozen(false);
        vm.expectRevert(abi.encodeWithSelector(M7CapVault.InsufficientClaim.selector, 3));
        vault.withdrawClaim(3, owed + 1, carol);
        vm.expectRevert(abi.encodeWithSelector(M7CapVault.InsufficientClaim.selector, 3));
        vault.withdrawClaim(3, 0, carol);
        vm.expectRevert(M7CapVault.InvalidReceiver.selector);
        vault.withdrawClaim(3, owed, address(vault));
        vm.expectRevert(M7CapVault.InvalidReceiver.selector);
        vault.withdrawClaim(3, owed, address(1));
        vm.expectRevert(M7CapVault.InvalidIndex.selector);
        vault.withdrawClaim(8, owed, carol);
        vm.prank(bob); // claims belong to the redeemer, not the receiver
        vm.expectRevert(abi.encodeWithSelector(M7CapVault.InsufficientClaim.selector, 3));
        vault.withdrawClaim(3, 1, bob);
        uint256 bobBefore = tokens[3].balanceOf(bob);
        vault.withdrawClaim(3, owed / 2, carol);
        vault.withdrawClaim(3, owed - owed / 2, bob);
        assertEq(tokens[3].balanceOf(carol), owed / 2);
        assertEq(tokens[3].balanceOf(bob) - bobBefore, owed - owed / 2);
        assertEq(vault.reserved(3), 0);
    }

    function testSeizureBelowReservedIsFirstComeAndHaltsIssuance() public {
        _token(5).setFrozen(true);
        (, uint256[8] memory deferred) = vault.redeemBasketWithClaims(500e18, noMinimum, bob, block.timestamp);
        _token(5).setFrozen(false);
        uint256 held = tokens[5].balanceOf(address(vault));
        _token(5).seize(address(vault), held - deferred[5] / 2); // the issuer seizes past the reserve
        assertEq(vault.backing(5), 0);
        vm.expectRevert(abi.encodeWithSelector(M7CapVault.MissingComponent.selector, 5));
        vault.quoteMint(1e18);
        assertEq(vault.quoteRedeem(10e18)[5], 0);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, address(vault), deferred[5] / 2, deferred[5]
            )
        );
        vault.withdrawClaim(5, deferred[5], carol);
        vault.withdrawClaim(5, deferred[5] / 2, carol); // what remains is paid first come
        assertEq(tokens[5].balanceOf(carol), deferred[5] / 2);
    }

    function testShortTransferStillRevertsInsteadOfDeferring() public {
        _token(2).setTaxed(true);
        vm.expectRevert(abi.encodeWithSelector(M7CapVault.TransferMismatch.selector, 2));
        vault.redeemBasketWithClaims(100e18, noMinimum, bob, block.timestamp);
        assertEq(vault.reserved(2), 0);
    }

    function testResilientRedemptionRespectsMinimumsDeadlineAndReceiver() public {
        uint256[8] memory entitled = vault.quoteRedeem(10e18);
        entitled[4] += 1;
        vm.expectRevert(abi.encodeWithSelector(M7CapVault.OutputLimit.selector, 4));
        vault.redeemBasketWithClaims(10e18, entitled, bob, block.timestamp);
        vm.expectRevert(M7CapVault.Expired.selector);
        vault.redeemBasketWithClaims(10e18, noMinimum, bob, block.timestamp - 1);
        vm.expectRevert(M7CapVault.InvalidReceiver.selector);
        vault.redeemBasketWithClaims(10e18, noMinimum, address(vault), block.timestamp);
        uint256 supply = vault.totalSupply();
        vm.expectRevert(M7CapVault.InvalidAmount.selector);
        vault.redeemBasketWithClaims(supply, noMinimum, bob, block.timestamp);
    }
}
