// SPDX-License-Identifier: Unlicense
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {M7Vault} from "../src/M7Vault.sol";
import {USDCGateway} from "../src/USDCGateway.sol";
import {IM7Vault} from "../src/interfaces/IM7Vault.sol";
import {VaultTestToken, VaultTestRouter} from "./M7Vault.t.sol";
import {GatewayFactory, GatewayRouter} from "./mocks/GatewayMocks.sol";
import {B20LikeToken, PolicyRegistryMock} from "./mocks/PolicyMocks.sol";
import {VaultHarness} from "./mocks/VaultHarness.sol";

/// @dev First-review reproductions, converted to regressions after the fixes (docs/AUDIT.md).
contract AuditVaultGatewayTest is VaultHarness {
    uint64 constant POLICY = 5;

    // D-02 regression: a stock's address policy now applies to M7 holders on every path.
    function testStockAddressExclusionPropagatesToReceiptHolders() public {
        PolicyRegistryMock registry = new PolicyRegistryMock();
        IERC20[8] memory tokens;
        uint256[8] memory seed;
        for (uint256 i; i < 8; ++i) {
            tokens[i] = new B20LikeToken(i == 7 ? 6 : 8, registry);
            B20LikeToken(address(tokens[i])).mint(address(this), 1_000e8);
            if (i < 7) seed[i] = 10e8;
        }
        B20LikeToken stock = B20LikeToken(address(tokens[0]));
        stock.setPolicyId(stock.TRANSFER_SENDER_POLICY(), POLICY);
        stock.setPolicyId(stock.TRANSFER_RECEIVER_POLICY(), POLICY);
        stock.setPolicyId(stock.TRANSFER_EXECUTOR_POLICY(), POLICY);
        GatewayFactory factory = new GatewayFactory();
        GatewayRouter router = new GatewayRouter(address(factory), address(tokens[7]));
        for (uint256 i; i < 7; ++i) {
            factory.setPool(address(tokens[i]), address(tokens[7]), 10, address(router));
        }
        (M7Vault vault,) = _deployVault(tokens, _spacings(10), router, factory, registry);
        USDCGateway gateway = new USDCGateway(IM7Vault(address(vault)));
        for (uint256 i; i < 8; ++i) {
            B20LikeToken(address(tokens[i])).mint(address(router), 1_000e8);
            tokens[i].approve(address(vault), type(uint256).max);
        }
        vault.bootstrap(seed, address(this));

        address excluded = address(0xa11ce);
        registry.setBlocked(POLICY, excluded, true);
        vm.expectRevert("policy forbids");
        tokens[0].transfer(excluded, 1);

        // Formerly the excluded user bought ten M7 with USDC; now the receipt cannot be issued to them.
        B20LikeToken(address(tokens[7])).mint(excluded, 100e6);
        vm.startPrank(excluded);
        tokens[7].approve(address(gateway), 1e6);
        vm.expectRevert(
            abi.encodeWithSelector(M7Vault.PolicyForbidden.selector, 0, vault.receiverScope(), excluded)
        );
        gateway.mintWithUSDC(10e18, 1e6, excluded, block.timestamp);
        vm.stopPrank();
        vm.expectRevert(
            abi.encodeWithSelector(M7Vault.PolicyForbidden.selector, 0, vault.receiverScope(), excluded)
        );
        vault.transfer(excluded, 1e18);

        // A holder who becomes excluded can neither sell through the gateway nor redirect the stock elsewhere.
        address holder = address(0xb0b);
        require(vault.transfer(holder, 20e18));
        registry.setBlocked(POLICY, holder, true);
        vm.startPrank(holder);
        vault.approve(address(gateway), 10e18);
        vm.expectRevert(
            abi.encodeWithSelector(M7Vault.PolicyForbidden.selector, 0, vault.senderScope(), holder)
        );
        gateway.redeemToUSDC(10e18, 0, holder, block.timestamp);
        uint256[8] memory noMinimum;
        vm.expectRevert(
            abi.encodeWithSelector(M7Vault.PolicyForbidden.selector, 0, vault.senderScope(), holder)
        );
        vault.redeemBasket(10e18, noMinimum, address(0xca11), block.timestamp);

        // The resilient exit still releases the six healthy stocks and keeps the blocked one as the holder's claim.
        (uint256[8] memory delivered, uint256[8] memory deferred) =
            vault.redeemBasketWithClaims(10e18, noMinimum, address(0xca11), block.timestamp);
        assertEq(delivered[0], 0);
        assertEq(deferred[0], 0.1e8);
        assertEq(tokens[1].balanceOf(address(0xca11)), delivered[1]);
        assertGt(delivered[1], 0);
        vm.expectRevert(
            abi.encodeWithSelector(M7Vault.PolicyForbidden.selector, 0, vault.senderScope(), holder)
        );
        vault.withdrawClaim(0, deferred[0], address(0xca11));
        vm.stopPrank();
        registry.setBlocked(POLICY, holder, false);
        vm.prank(holder);
        vault.withdrawClaim(0, deferred[0], address(0xca11));
        assertEq(tokens[0].balanceOf(address(0xca11)), deferred[0]);
    }

    function testRegressionAllCirculatingSharesRedeemedAndRefilledPreservesBasket() public {
        IERC20[8] memory tokens;
        uint256[8] memory seed;
        for (uint256 i; i < 8; ++i) {
            tokens[i] = new VaultTestToken(i == 7 ? 6 : 8);
            VaultTestToken(address(tokens[i])).mint(address(this), 1_000e8);
            if (i < 7) seed[i] = (i + 1) * 1e8;
        }
        VaultTestRouter router = new VaultTestRouter();
        (M7Vault vault,) = _deployVault(tokens, _spacings(10), router, router, new PolicyRegistryMock());
        for (uint256 i; i < 8; ++i) {
            tokens[i].approve(address(vault), type(uint256).max);
        }
        vault.bootstrap(seed, address(this));

        // The seed holds 1, 2, ... 7 human stock tokens, hence a 1:7 quantity ratio.
        assertEq(tokens[6].balanceOf(address(vault)), 7 * tokens[0].balanceOf(address(vault)));
        uint256 circulating = vault.balanceOf(address(this));
        uint256[8] memory amounts = vault.quoteRedeem(circulating);
        vault.redeemBasket(circulating, amounts, address(0xb0b), block.timestamp);

        assertEq(vault.totalSupply(), vault.LOCKED_SHARES());
        for (uint256 i; i < 7; ++i) {
            // The meaningful reserve retains every stock's original quantity proportion.
            assertEq(tokens[i].balanceOf(address(vault)), (i + 1) * 1e6);
        }

        // Refilling the original circulating supply preserves the original 1:7 ratio.
        uint256[8] memory quote = vault.quoteMint(990e18);
        for (uint256 i; i < 7; ++i) {
            assertEq(quote[i], (i + 1) * 99e6);
        }
        vault.mintBasket(990e18, quote, address(0xa11ce), block.timestamp);
        assertEq(tokens[0].balanceOf(address(vault)), 1e8);
        assertEq(tokens[6].balanceOf(address(vault)), 7 * tokens[0].balanceOf(address(vault)));
    }
}
