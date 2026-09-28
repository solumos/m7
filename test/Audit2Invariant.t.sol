// SPDX-License-Identifier: Unlicense
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {M7Vault} from "../src/M7Vault.sol";
import {USDCGateway} from "../src/USDCGateway.sol";
import {IM7Vault} from "../src/interfaces/IM7Vault.sol";
import {GatewayToken, GatewayFactory, GatewayRouter} from "./mocks/GatewayMocks.sol";
import {PolicyRegistryMock} from "./mocks/PolicyMocks.sol";
import {VaultHarness} from "./mocks/VaultHarness.sol";

/// @dev Random in-kind, resilient and gateway flows, donations, share burns, asset freezes and claim withdrawals.
///      Violations are latched in ghost flags because the invariant profile does not fail on handler reverts.
contract Audit2Handler is Test {
    M7Vault public vault;
    USDCGateway public gateway;
    GatewayToken[8] public tokens;
    address[4] public actors = [address(0xA1), address(0xA2), address(0xA3), address(0xA4)];

    uint256[8] public lastBacking;
    uint256 public lastSupply;
    bool public backingDecreased;
    bool public roundTripProfit;
    bool public gatewayRetainedFunds;
    bool public gatewayOverspent;
    bool public resilientReverted;

    constructor(M7Vault vault_, USDCGateway gateway_, GatewayToken[8] memory tokens_) {
        vault = vault_;
        gateway = gateway_;
        tokens = tokens_;
        _record();
    }

    function _record() private {
        for (uint256 i; i < 8; ++i) {
            lastBacking[i] = vault.backing(i);
        }
        lastSupply = vault.totalSupply();
    }

    /// Per-share backing B[i]/S may never fall: there is no seizure or rebalance action in this campaign.
    function _check() private {
        uint256 supply = vault.totalSupply();
        for (uint256 i; i < 8; ++i) {
            if (vault.backing(i) * lastSupply < lastBacking[i] * supply) backingDecreased = true;
            if (tokens[i].balanceOf(address(gateway)) != 0) gatewayRetainedFunds = true;
        }
        _record();
    }

    function _actor(uint256 seed) private view returns (address) {
        return actors[seed % actors.length];
    }

    function _fundAndApprove(address who, uint256[8] memory amounts) private {
        for (uint256 i; i < 8; ++i) {
            if (amounts[i] != 0) tokens[i].mint(who, amounts[i]);
            vm.prank(who);
            tokens[i].approve(address(vault), amounts[i]);
        }
    }

    function _redeemable(address who) private view returns (uint256 cap) {
        cap = vault.balanceOf(who);
        uint256 maxRedeem = vault.totalSupply() - vault.LOCKED_SHARES();
        if (cap > maxRedeem) cap = maxRedeem;
    }

    function _anyFrozen() private view returns (bool) {
        for (uint256 i; i < 8; ++i) {
            if (tokens[i].blocked()) return true;
        }
        return false;
    }

    function mintInKind(uint256 actorSeed, uint256 shares) external {
        if (_anyFrozen()) return;
        shares = bound(shares, 1, vault.totalSupply() * 3);
        address a = _actor(actorSeed);
        uint256[8] memory quote = vault.quoteMint(shares);
        _fundAndApprove(a, quote);
        vm.prank(a);
        vault.mintBasket(shares, quote, a, block.timestamp);
        _check();
    }

    function redeemInKind(uint256 actorSeed, uint256 shares) external {
        if (_anyFrozen()) return;
        address a = _actor(actorSeed);
        uint256 cap = _redeemable(a);
        if (cap == 0) return;
        uint256[8] memory noMinimum;
        vm.prank(a);
        vault.redeemBasket(bound(shares, 1, cap), noMinimum, a, block.timestamp);
        _check();
    }

    /// The resilient exit must succeed whatever is frozen, deferring the legs that cannot move.
    function redeemWithClaims(uint256 actorSeed, uint256 shares) external {
        address a = _actor(actorSeed);
        uint256 cap = _redeemable(a);
        if (cap == 0) return;
        uint256[8] memory noMinimum;
        vm.prank(a);
        try vault.redeemBasketWithClaims(bound(shares, 1, cap), noMinimum, a, block.timestamp) {
            _check();
        } catch {
            resilientReverted = true;
        }
    }

    function withdrawClaim(uint256 actorSeed, uint256 assetSeed, uint256 amount) external {
        address a = _actor(actorSeed);
        uint256 index = assetSeed % 8;
        uint256 owed = vault.claimOf(a)[index];
        if (owed == 0 || tokens[index].blocked()) return;
        vm.prank(a);
        vault.withdrawClaim(index, bound(amount, 1, owed), a);
        _check();
    }

    function toggleFreeze(uint256 assetSeed) external {
        GatewayToken token = tokens[assetSeed % 8];
        token.setBlocked(!token.blocked());
    }

    function roundTrip(uint256 actorSeed, uint256 shares) external {
        if (_anyFrozen()) return;
        shares = bound(shares, 1, vault.totalSupply() * 2);
        address a = _actor(actorSeed);
        uint256[8] memory paid = vault.quoteMint(shares);
        _fundAndApprove(a, paid);
        vm.startPrank(a);
        vault.mintBasket(shares, paid, a, block.timestamp);
        uint256[8] memory received = vault.quoteRedeem(shares);
        vault.redeemBasket(shares, received, a, block.timestamp);
        vm.stopPrank();
        for (uint256 i; i < 8; ++i) {
            if (received[i] > paid[i]) roundTripProfit = true;
        }
        _check();
    }

    function donate(uint256 assetSeed, uint256 amount) external {
        GatewayToken token = tokens[assetSeed % 8];
        if (token.blocked()) return;
        token.mint(address(vault), bound(amount, 1, 1e12));
        _check();
    }

    function burnToSeedLock(uint256 actorSeed, uint256 amount) external {
        address a = _actor(actorSeed);
        uint256 balance = vault.balanceOf(a);
        if (balance == 0) return;
        vm.prank(a);
        vault.transfer(address(1), bound(amount, 1, balance));
        _check();
    }

    function gatewayMint(uint256 actorSeed, uint256 shares, uint256 slack) external {
        if (_anyFrozen()) return;
        shares = bound(shares, 1, vault.totalSupply());
        address a = _actor(actorSeed);
        uint256[8] memory quote = vault.quoteMint(shares);
        uint256 cost = quote[7];
        for (uint256 i; i < 7; ++i) {
            cost += (quote[i] + 99) / 100; // GatewayRouter: $1 stocks, 8 vs 6 decimals, rounded up
        }
        uint256 maxIn = cost + bound(slack, 0, 1e9);
        tokens[7].mint(a, maxIn);
        uint256 before = tokens[7].balanceOf(a);
        vm.startPrank(a);
        tokens[7].approve(address(gateway), maxIn);
        uint256 spent = gateway.mintWithUSDC(shares, maxIn, a, block.timestamp);
        vm.stopPrank();
        if (spent > maxIn || before - tokens[7].balanceOf(a) != spent) gatewayOverspent = true;
        _check();
    }

    function gatewayRedeem(uint256 actorSeed, uint256 shares) external {
        if (_anyFrozen()) return;
        address a = _actor(actorSeed);
        uint256 cap = _redeemable(a);
        if (cap == 0) return;
        shares = bound(shares, 1, cap);
        vm.startPrank(a);
        vault.approve(address(gateway), shares);
        gateway.redeemToUSDC(shares, 0, a, block.timestamp);
        vm.stopPrank();
        _check();
    }

    function knownShares() external view returns (uint256 total) {
        for (uint256 i; i < actors.length; ++i) {
            total += vault.balanceOf(actors[i]);
        }
        total += vault.balanceOf(address(1)) + vault.balanceOf(address(gateway));
    }

    function knownClaims(uint256 index) external view returns (uint256 total) {
        for (uint256 i; i < actors.length; ++i) {
            total += vault.claimOf(actors[i])[index];
        }
    }
}

contract Audit2InvariantTest is VaultHarness {
    M7Vault vault;
    Audit2Handler handler;
    GatewayToken[8] tokens;

    function setUp() public {
        IERC20[8] memory assets;
        uint256[8] memory seed;
        for (uint256 i; i < 8; ++i) {
            tokens[i] = new GatewayToken(i == 7 ? 6 : 8);
            assets[i] = IERC20(address(tokens[i]));
            if (i < 7) seed[i] = (i + 1) * 1e8 + 12345; // non-divisible seed quantities
        }
        GatewayFactory factory = new GatewayFactory();
        GatewayRouter router = new GatewayRouter(address(factory), address(tokens[7]));
        for (uint256 i; i < 7; ++i) {
            factory.setPool(address(tokens[i]), address(tokens[7]), 10, address(router));
        }
        (vault,) = _deployVault(assets, _spacings(10), router, factory, new PolicyRegistryMock());
        USDCGateway gateway = new USDCGateway(IM7Vault(address(vault)));
        for (uint256 i; i < 8; ++i) {
            tokens[i].mint(address(this), seed[i]);
            tokens[i].approve(address(vault), seed[i]);
            tokens[i].mint(address(router), 1e30);
        }
        vault.bootstrap(seed, address(0xA1));
        handler = new Audit2Handler(vault, gateway, tokens);
        targetContract(address(handler));
    }

    function invariant_audit2VaultAccounting() public view {
        assertFalse(handler.backingDecreased(), "per-share backing fell");
        assertFalse(handler.roundTripProfit(), "mint then redeem profited");
        uint256 supply = vault.totalSupply();
        assertEq(handler.knownShares(), supply, "untracked shares");
        assertGe(vault.balanceOf(address(1)), vault.LOCKED_SHARES());
        for (uint256 i; i < 7; ++i) {
            assertGe(vault.backing(i) * vault.LOCKED_SHARES() / supply, vault.MIN_LOCKED_STOCK_UNITS());
        }
    }

    function invariant_audit2ClaimsAreFullyReserved() public view {
        assertFalse(handler.resilientReverted(), "resilient redemption reverted");
        for (uint256 i; i < 8; ++i) {
            assertEq(handler.knownClaims(i), vault.reserved(i), "claims differ from reserved");
            assertGe(tokens[i].balanceOf(address(vault)), vault.reserved(i), "reserved exceeds balance");
        }
    }

    function invariant_audit2GatewayNeverRetainsOrOverspends() public view {
        assertFalse(handler.gatewayRetainedFunds(), "gateway kept user funds");
        assertFalse(handler.gatewayOverspent(), "gateway exceeded maxUSDCIn");
    }
}
