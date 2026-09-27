// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {M7CapVault} from "../src/M7CapVault.sol";
import {USDCGateway} from "../src/USDCGateway.sol";
import {IM7CapVault} from "../src/interfaces/IM7CapVault.sol";
import {IPolicyRegistry} from "../src/interfaces/IB20Policy.sol";
import {GatewayFactory, GatewayRouter} from "./mocks/GatewayMocks.sol";
import {B20LikeToken, PolicyRegistryMock} from "./mocks/PolicyMocks.sol";
import {VaultHarness} from "./mocks/VaultHarness.sol";

/// @dev D-02: M7CAP transfers, mints, redemptions and claim withdrawals mirror the stocks' B20 transfer policies.
contract VaultPolicyTest is VaultHarness {
    uint64 constant SENDER = 11;
    uint64 constant RECEIVER = 12;
    uint64 constant EXECUTOR = 13;
    PolicyRegistryMock registry;
    GatewayFactory factory;
    GatewayRouter router;
    M7CapVault vault;
    IERC20[8] tokens;
    uint256[8] seed;
    uint256[8] noMinimum;
    address alice = address(0xa11ce);
    address bob = address(0xb0b);
    address carol = address(0xca701);

    function setUp() public {
        registry = new PolicyRegistryMock();
        for (uint256 i; i < 8; ++i) {
            tokens[i] = new B20LikeToken(i == 7 ? 6 : 8, registry);
            B20LikeToken(address(tokens[i])).mint(address(this), 1e30);
            if (i < 7) seed[i] = (i + 1) * 1e8;
        }
        factory = new GatewayFactory();
        router = new GatewayRouter(address(factory), address(tokens[7]));
        for (uint256 i; i < 7; ++i) {
            factory.setPool(address(tokens[i]), address(tokens[7]), 10, address(router));
        }
        vault = _deploy();
        vault.bootstrap(seed, address(this));
        // Stock 2 uses a distinct policy per scope, so each scope can be exercised on its own.
        B20LikeToken stock = _stock(2);
        stock.setPolicyId(stock.TRANSFER_SENDER_POLICY(), SENDER);
        stock.setPolicyId(stock.TRANSFER_RECEIVER_POLICY(), RECEIVER);
        stock.setPolicyId(stock.TRANSFER_EXECUTOR_POLICY(), EXECUTOR);
        require(vault.transfer(alice, 100e18));
    }

    function _deploy() private returns (M7CapVault fresh) {
        (fresh,) = _deployVault(tokens, _spacings(10), router, factory, registry);
        for (uint256 i; i < 8; ++i) {
            tokens[i].approve(address(fresh), type(uint256).max);
        }
    }

    function _stock(uint256 index) private view returns (B20LikeToken) {
        return B20LikeToken(address(tokens[index]));
    }

    function _forbidden(bytes32 scope, address account) private view returns (bytes memory) {
        return abi.encodeWithSelector(M7CapVault.PolicyForbidden.selector, 2, scope, account);
    }

    function testTransfersCheckSenderReceiverAndExecutor() public {
        registry.setBlocked(SENDER, alice, true);
        bytes memory expected1 = _forbidden(vault.senderScope(), alice);
        vm.prank(alice);
        vm.expectRevert(expected1);
        vault.transfer(bob, 1e18);
        registry.setBlocked(SENDER, alice, false);

        registry.setBlocked(RECEIVER, bob, true);
        bytes memory expected2 = _forbidden(vault.receiverScope(), bob);
        vm.prank(alice);
        vm.expectRevert(expected2);
        vault.transfer(bob, 1e18);
        registry.setBlocked(RECEIVER, bob, false);

        vm.prank(alice);
        vault.approve(carol, 1e18);
        registry.setBlocked(EXECUTOR, carol, true);
        bytes memory expected3 = _forbidden(vault.executorScope(), carol);
        vm.prank(carol);
        vm.expectRevert(expected3);
        vault.transferFrom(alice, bob, 1e18);
        registry.setBlocked(EXECUTOR, carol, false);
        vm.prank(carol);
        require(vault.transferFrom(alice, bob, 1e18));
        assertEq(vault.balanceOf(bob), 1e18);
    }

    function testMintChecksReceiverAndCaller() public {
        uint256[8] memory quote = vault.quoteMint(1e18);
        registry.setBlocked(RECEIVER, bob, true);
        vm.expectRevert(_forbidden(vault.receiverScope(), bob));
        vault.mintBasket(1e18, quote, bob, block.timestamp);
        registry.setBlocked(RECEIVER, bob, false);
        registry.setBlocked(EXECUTOR, address(this), true);
        vm.expectRevert(_forbidden(vault.executorScope(), address(this)));
        vault.mintBasket(1e18, quote, bob, block.timestamp);
    }

    function testSeedLockIsExemptFromTheReceiverPolicy() public {
        M7CapVault fresh = _deploy();
        registry.setBlocked(RECEIVER, address(1), true);
        fresh.bootstrap(seed, address(this));
        assertEq(fresh.balanceOf(address(1)), fresh.LOCKED_SHARES());
        require(fresh.transfer(address(1), 1e18)); // sending shares into the lock stays possible
    }

    function testRedemptionsCheckTheOwnerForEveryDeliveredStock() public {
        registry.setBlocked(SENDER, alice, true);
        bytes memory expected4 = _forbidden(vault.senderScope(), alice);
        vm.prank(alice);
        vm.expectRevert(expected4);
        vault.redeemBasket(10e18, noMinimum, bob, block.timestamp);

        vm.prank(alice);
        (uint256[8] memory delivered, uint256[8] memory deferred) =
            vault.redeemBasketWithClaims(10e18, noMinimum, bob, block.timestamp);
        assertEq(delivered[2], 0);
        assertGt(deferred[2], 0);
        assertEq(tokens[1].balanceOf(bob), delivered[1]);
        assertEq(vault.claimOf(alice)[2], deferred[2]);

        bytes memory expected5 = _forbidden(vault.senderScope(), alice);

        vm.prank(alice);
        vm.expectRevert(expected5);
        vault.withdrawClaim(2, deferred[2], bob);
        registry.setBlocked(SENDER, alice, false);
        vm.prank(alice);
        vault.withdrawClaim(2, deferred[2], bob);
        assertEq(tokens[2].balanceOf(bob), deferred[2]);
    }

    function testBlockedReceiverDefersOnlyThatLegOfAResilientExit() public {
        registry.setBlocked(RECEIVER, bob, true); // the stock itself refuses delivery to bob
        vm.prank(alice);
        (, uint256[8] memory deferred) = vault.redeemBasketWithClaims(10e18, noMinimum, bob, block.timestamp);
        assertGt(deferred[2], 0);
        vm.prank(alice);
        vault.withdrawClaim(2, deferred[2], carol); // the owner redirects it to an eligible address
        assertEq(tokens[2].balanceOf(carol), deferred[2]);
    }

    function testPolicyZeroSkipsTheRegistryAndRepeatedIdsAreCheckedOnce() public {
        B20LikeToken stock = _stock(2);
        stock.setPolicyId(stock.TRANSFER_SENDER_POLICY(), 0);
        stock.setPolicyId(stock.TRANSFER_RECEIVER_POLICY(), 0);
        stock.setPolicyId(stock.TRANSFER_EXECUTOR_POLICY(), 0);
        registry.setBroken(true);
        vm.prank(alice);
        require(vault.transfer(bob, 1e18)); // every scope is policy 0: no lookup is needed
        registry.setBroken(false);

        for (uint256 i; i < 7; ++i) {
            _stock(i).setPolicyId(_stock(i).TRANSFER_SENDER_POLICY(), 5);
        }
        vm.expectCall(address(registry), abi.encodeCall(IPolicyRegistry.isAuthorized, (5, alice)), 1);
        vm.prank(alice);
        require(vault.transfer(bob, 1e18));
    }

    function testLookupFailuresFailClosedForTransfersAndDeferInResilientExits() public {
        registry.setBroken(true);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(M7CapVault.PolicyUnavailable.selector, 2));
        vault.transfer(bob, 1e18);
        registry.setBroken(false);

        _stock(4).setPolicyLookupReverts(true);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(M7CapVault.PolicyUnavailable.selector, 4));
        vault.transfer(bob, 1e18);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(M7CapVault.PolicyUnavailable.selector, 4));
        vault.redeemBasket(10e18, noMinimum, bob, block.timestamp);
        vm.prank(alice);
        (uint256[8] memory delivered, uint256[8] memory deferred) =
            vault.redeemBasketWithClaims(10e18, noMinimum, bob, block.timestamp);
        assertGt(deferred[4], 0);
        assertEq(delivered[4], 0);
        assertGt(delivered[0], 0);
    }

    function testEligibleUserUsesTheGatewayWithPoliciesActive() public {
        USDCGateway gateway = new USDCGateway(IM7CapVault(address(vault)));
        for (uint256 i; i < 8; ++i) {
            _stock(i).mint(address(router), 1e20);
        }
        _stock(7).mint(bob, 1_000e6);
        vm.startPrank(bob);
        tokens[7].approve(address(gateway), type(uint256).max);
        gateway.mintWithUSDC(10e18, 1_000e6, bob, block.timestamp);
        vault.approve(address(gateway), 10e18);
        gateway.redeemToUSDC(10e18, 0, bob, block.timestamp);
        vm.stopPrank();
        assertEq(vault.balanceOf(bob), 0);
    }
}
