// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {M7CapVault} from "../src/M7CapVault.sol";
import {ISlipstreamRouter, ISlipstreamFactory} from "../src/interfaces/ISlipstreamRouter.sol";
import {IPolicyRegistry} from "../src/interfaces/IB20Policy.sol";
import {Swap} from "../src/Types.sol";
import {B20PolicyMixin, PolicyRegistryMock} from "./mocks/PolicyMocks.sol";
import {ControllerStub, VaultHarness} from "./mocks/VaultHarness.sol";

contract VaultTestToken is ERC20, B20PolicyMixin {
    uint8 private immutable _decimals;
    bool public frozen;
    bool public taxed;

    constructor(uint8 decimals_) ERC20("Test", "T") {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function seize(address from, uint256 amount) external {
        _burn(from, amount);
    }

    function setFrozen(bool value) external {
        frozen = value;
    }

    function setTaxed(bool value) external {
        taxed = value;
    }

    function _update(address from, address to, uint256 amount) internal override {
        if (from != address(0) && to != address(0)) {
            require(!frozen, "frozen");
            if (taxed && amount > 0) {
                super._update(from, address(0), 1);
                amount -= 1;
            }
        }
        super._update(from, to, amount);
    }
}

contract VaultTestRouter is ISlipstreamRouter, ISlipstreamFactory {
    bool public poolExists = true;

    function factory() external view returns (address) {
        return address(this);
    }

    function setPoolExists(bool value) external {
        poolExists = value;
    }

    function getPool(address, address, int24) external view returns (address) {
        return poolExists ? address(this) : address(0);
    }

    function exactInputSingle(ExactInputSingleParams calldata p) external payable returns (uint256) {
        IERC20(p.tokenIn).transferFrom(msg.sender, address(this), p.amountIn);
        VaultTestToken(p.tokenOut).mint(p.recipient, p.amountOutMinimum);
        return p.amountOutMinimum;
    }

    function exactOutputSingle(ExactOutputSingleParams calldata) external payable returns (uint256) {
        revert("unused");
    }
}

contract M7CapVaultTest is VaultHarness {
    M7CapVault internal vault;
    ControllerStub internal stub;
    PolicyRegistryMock internal registry;
    IERC20[8] internal tokens;
    VaultTestRouter internal router;
    address internal alice = address(0xa11ce);
    address internal bob = address(0xb0b);
    uint256[8] internal seed;

    function setUp() public {
        for (uint256 i; i < 8; ++i) {
            tokens[i] = IERC20(address(new VaultTestToken(i == 7 ? 6 : 8)));
            VaultTestToken(address(tokens[i])).mint(address(this), 1e30);
            if (i < 7) seed[i] = (i + 1) * 1e8;
        }
        router = new VaultTestRouter();
        registry = new PolicyRegistryMock();
        (vault, stub) = _deployVault(tokens, _spacings(10), router, router, registry);
        for (uint256 i; i < 8; ++i) {
            tokens[i].approve(address(vault), type(uint256).max);
        }
        vault.bootstrap(seed, address(this));
    }

    function testBootstrapIsFundedAndOneTime() public {
        assertEq(vault.totalSupply(), 1_000e18);
        assertEq(vault.balanceOf(address(1)), 10e18);
        assertEq(vault.balanceOf(address(this)), 990e18);
        for (uint256 i; i < 8; ++i) {
            assertEq(tokens[i].balanceOf(address(vault)), seed[i]);
        }
        vm.expectRevert(M7CapVault.AlreadyInitialized.selector);
        vault.bootstrap(seed, bob);
        vm.prank(alice);
        vm.expectRevert(M7CapVault.Unauthorized.selector);
        vault.bootstrap(seed, alice);
    }

    function testFuzzMintCannotDiluteAndRoundTripCannotProfit(uint96 rawShares, uint64 donation) public {
        uint256 shares = bound(uint256(rawShares), 1, 1e24);
        tokens[0].transfer(address(vault), donation);
        uint256[8] memory beforeBalances;
        uint256 supplyBefore = vault.totalSupply();
        uint256[8] memory amounts = vault.quoteMint(shares);
        for (uint256 i; i < 8; ++i) {
            beforeBalances[i] = tokens[i].balanceOf(address(vault));
        }
        vault.mintBasket(shares, amounts, alice, block.timestamp);
        for (uint256 i; i < 8; ++i) {
            // Cross multiplication checks backing per share never decreases on mint.
            assertGe(
                tokens[i].balanceOf(address(vault)) * supplyBefore, beforeBalances[i] * vault.totalSupply()
            );
        }
        uint256[8] memory returned = vault.quoteRedeem(shares);
        vm.prank(alice);
        vault.redeemBasket(shares, returned, alice, block.timestamp);
        for (uint256 i; i < 8; ++i) {
            assertLe(returned[i], amounts[i]);
            assertGe(tokens[i].balanceOf(address(vault)), beforeBalances[i]);
        }
        assertEq(vault.totalSupply(), supplyBefore);
    }

    function testCashDonationIsProRataAndNotLost() public {
        tokens[7].transfer(address(vault), 1_000e6);
        uint256[8] memory amounts = vault.quoteMint(100e18);
        assertEq(amounts[7], 100e6);
        vault.mintBasket(100e18, amounts, alice, block.timestamp);
        uint256[8] memory redeem = vault.quoteRedeem(100e18);
        assertEq(redeem[7], 100e6);
        vm.prank(alice);
        vault.redeemBasket(100e18, redeem, alice, block.timestamp);
        assertEq(tokens[7].balanceOf(alice), 100e6);
    }

    function testMintInputLimitAndDonationFrontRun() public {
        uint256[8] memory quote = vault.quoteMint(1e18);
        tokens[0].transfer(address(vault), 1e8);
        vm.expectRevert(abi.encodeWithSelector(M7CapVault.InputLimit.selector, 0));
        vault.mintBasket(1e18, quote, alice, block.timestamp);
        assertEq(vault.balanceOf(alice), 0);
    }

    function testFrozenComponentRollsBackBurnAndEarlierTransfers() public {
        uint256 shares = 100e18;
        uint256[8] memory amounts = vault.quoteRedeem(shares);
        uint256 supplyBefore = vault.totalSupply();
        VaultTestToken(address(tokens[6])).setFrozen(true);
        vm.expectRevert("frozen");
        vault.redeemBasket(shares, amounts, bob, block.timestamp);
        assertEq(vault.totalSupply(), supplyBefore);
        assertEq(tokens[0].balanceOf(bob), 0);
        assertEq(tokens[0].balanceOf(address(vault)), seed[0]);
    }

    function testSeizureIsReflectedInRedemptionAndStopsIssuanceWhenEmpty() public {
        VaultTestToken(address(tokens[0])).seize(address(vault), seed[0]);
        uint256[8] memory amounts = vault.quoteRedeem(100e18);
        assertEq(amounts[0], 0);
        assertGt(amounts[1], 0);
        vm.expectRevert(abi.encodeWithSelector(M7CapVault.MissingComponent.selector, 0));
        vault.quoteMint(1e18);
        vault.redeemBasket(100e18, amounts, bob, block.timestamp);
        assertEq(tokens[1].balanceOf(bob), amounts[1]);
    }

    function testFeeOnTransferFailsWithoutMinting() public {
        uint256[8] memory amounts = vault.quoteMint(100e18);
        VaultTestToken(address(tokens[1])).setTaxed(true);
        vm.expectRevert(abi.encodeWithSelector(M7CapVault.TransferMismatch.selector, 1));
        vault.mintBasket(100e18, amounts, alice, block.timestamp);
        assertEq(vault.totalSupply(), 1_000e18);
        assertEq(tokens[0].balanceOf(address(vault)), seed[0]);
    }

    function testRedeemMinimumAndExpiredCalls() public {
        uint256[8] memory amounts = vault.quoteRedeem(1e18);
        amounts[3] += 1;
        vm.expectRevert(abi.encodeWithSelector(M7CapVault.OutputLimit.selector, 3));
        vault.redeemBasket(1e18, amounts, bob, block.timestamp);
        vm.warp(100);
        vm.expectRevert(M7CapVault.Expired.selector);
        vault.redeemBasket(1e18, amounts, bob, 99);
        vm.expectRevert(M7CapVault.Expired.selector);
        vault.mintBasket(1e18, amounts, bob, 99);
    }

    function testNobodyCanRedeemLockedSharesOrSendBasketToVault() public {
        uint256 supply = vault.totalSupply();
        vm.expectRevert(M7CapVault.InvalidAmount.selector);
        vault.quoteRedeem(supply);
        uint256[8] memory amounts;
        vm.expectRevert(M7CapVault.InvalidReceiver.selector);
        vault.redeemBasket(1e18, amounts, address(vault), block.timestamp);
    }

    function testRebalanceOnlyControllerAndNoArbitraryAssetPairs() public {
        Swap[] memory swaps = new Swap[](1);
        swaps[0] = Swap({tokenIn: 0, tokenOut: 7, amountIn: 1e6, minAmountOut: 1e6});
        vm.prank(alice);
        vm.expectRevert(M7CapVault.Unauthorized.selector);
        vault.rebalance(swaps, block.timestamp);
        swaps[0].tokenOut = 1; // stock-to-stock
        vm.expectRevert(M7CapVault.InvalidSwap.selector);
        stub.rebalance(swaps, block.timestamp);
        vm.expectRevert(M7CapVault.InvalidSwap.selector);
        stub.rebalance(new Swap[](0), block.timestamp);
    }

    function testRebalanceLegsAreOneDirectionOncePerStockAndWithinBacking() public {
        Swap[] memory mixed = new Swap[](2);
        mixed[0] = Swap({tokenIn: 0, tokenOut: 7, amountIn: 1e6, minAmountOut: 1});
        mixed[1] = Swap({tokenIn: 7, tokenOut: 1, amountIn: 1, minAmountOut: 1});
        vm.expectRevert(M7CapVault.InvalidSwap.selector);
        stub.rebalance(mixed, block.timestamp);

        Swap[] memory repeated = new Swap[](2);
        repeated[0] = Swap({tokenIn: 0, tokenOut: 7, amountIn: 1e6, minAmountOut: 1});
        repeated[1] = repeated[0];
        vm.expectRevert(M7CapVault.InvalidSwap.selector);
        stub.rebalance(repeated, block.timestamp);

        Swap[] memory tooMany = new Swap[](8);
        for (uint256 i; i < 8; ++i) {
            tooMany[i] = Swap({tokenIn: uint8(i % 7), tokenOut: 7, amountIn: 1, minAmountOut: 1});
        }
        vm.expectRevert(M7CapVault.InvalidSwap.selector);
        stub.rebalance(tooMany, block.timestamp);

        Swap[] memory excessive = new Swap[](1);
        excessive[0] = Swap({tokenIn: 0, tokenOut: 7, amountIn: seed[0] + 1, minAmountOut: 1});
        vm.expectRevert(abi.encodeWithSelector(M7CapVault.ExceedsBacking.selector, 0));
        stub.rebalance(excessive, block.timestamp);
    }

    function testRebalanceRoutesToVaultAndClearsAllowance() public {
        Swap[] memory swaps = new Swap[](1);
        swaps[0] = Swap({tokenIn: 0, tokenOut: 7, amountIn: 1e6, minAmountOut: 5e6});
        stub.rebalance(swaps, block.timestamp);
        assertEq(tokens[0].balanceOf(address(vault)), seed[0] - 1e6);
        assertEq(tokens[7].balanceOf(address(vault)), 5e6);
        assertEq(tokens[0].allowance(address(vault), address(router)), 0);
    }

    function testConstructorPinsExistingPoolsAndRequiresControllerBinding() public {
        router.setPoolExists(false);
        vm.expectRevert(abi.encodeWithSelector(M7CapVault.InvalidPool.selector, 0));
        new M7CapVault(tokens, _spacings(10), address(stub), router, router, registry, address(this));
        router.setPoolExists(true);
        vm.expectRevert(abi.encodeWithSelector(M7CapVault.InvalidPool.selector, 0));
        new M7CapVault(tokens, _spacings(0), address(stub), router, router, registry, address(this));
        // The stub is bound to the existing vault, so any new vault is refused.
        vm.expectRevert(M7CapVault.InvalidConfiguration.selector);
        new M7CapVault(tokens, _spacings(10), address(stub), router, router, registry, address(this));
        vm.expectRevert(M7CapVault.InvalidConfiguration.selector);
        new M7CapVault(
            tokens, _spacings(10), address(stub), router, router, IPolicyRegistry(address(0)), address(this)
        );
        assertEq(vault.tickSpacing(6), 10);
        vm.expectRevert(M7CapVault.InvalidIndex.selector);
        vault.tickSpacing(7);
        vm.expectRevert(M7CapVault.InvalidIndex.selector);
        vault.assets(8);
    }

    function testVaultAcceptsEthOnlyFromRouter() public {
        vm.deal(alice, 1);
        vm.prank(alice);
        (bool fromOther,) = address(vault).call{value: 1}("");
        assertFalse(fromOther);
        vm.deal(address(router), 1);
        vm.prank(address(router));
        (bool fromRouter,) = address(vault).call{value: 1}("");
        assertTrue(fromRouter);
    }

    function testBootstrapRejectsInsufficientReserveAtomically() public {
        (M7CapVault fresh,) = _deployVault(tokens, _spacings(10), router, router, registry);
        uint256[8] memory amounts;
        for (uint256 i; i < 7; ++i) {
            amounts[i] = 1e6; // Exactly 10,000 locked raw units at the 1% lock fraction.
            tokens[i].approve(address(fresh), amounts[i]);
        }
        amounts[6] -= 1;
        uint256 senderBalance = tokens[0].balanceOf(address(this));
        vm.expectRevert(abi.encodeWithSelector(M7CapVault.InsufficientLockedBacking.selector, 6));
        fresh.bootstrap(amounts, address(this));
        assertEq(fresh.totalSupply(), 0);
        assertEq(tokens[0].balanceOf(address(this)), senderBalance);
        for (uint256 i; i < 7; ++i) {
            assertEq(tokens[i].balanceOf(address(fresh)), 0);
            assertEq(tokens[i].allowance(address(this), address(fresh)), 1e6);
        }

        amounts[6] += 1;
        fresh.bootstrap(amounts, address(this));
        assertEq(fresh.totalSupply(), fresh.INITIAL_SHARES());
    }

    function testRebalanceCannotReduceLockedPrecisionAndRollsBackSwaps() public {
        Swap[] memory swaps = new Swap[](2);
        swaps[0] = Swap({tokenIn: 1, tokenOut: 7, amountIn: 1e6, minAmountOut: 2e6});
        swaps[1] = Swap({tokenIn: 0, tokenOut: 7, amountIn: seed[0] - 1e6 + 1, minAmountOut: 3e6});
        vm.expectRevert(abi.encodeWithSelector(M7CapVault.InsufficientLockedBacking.selector, 0));
        stub.rebalance(swaps, block.timestamp);
        for (uint256 i; i < 8; ++i) {
            assertEq(tokens[i].balanceOf(address(vault)), seed[i]);
            assertEq(tokens[i].balanceOf(address(router)), 0);
            assertEq(tokens[i].allowance(address(vault), address(router)), 0);
        }
    }

    function testPartialSeizureBelowPrecisionFloorBlocksMintButAllowsExit() public {
        VaultTestToken(address(tokens[0])).seize(address(vault), seed[0] - 999_999);
        vm.expectRevert(abi.encodeWithSelector(M7CapVault.InsufficientLockedBacking.selector, 0));
        vault.quoteMint(1e18);
        uint256[8] memory maximums;
        vm.expectRevert(abi.encodeWithSelector(M7CapVault.InsufficientLockedBacking.selector, 0));
        vault.mintBasket(1e18, maximums, alice, block.timestamp);

        uint256 circulating = vault.balanceOf(address(this));
        uint256[8] memory amounts = vault.quoteRedeem(circulating);
        vault.redeemBasket(circulating, amounts, bob, block.timestamp);
        assertEq(vault.totalSupply(), vault.LOCKED_SHARES());
        assertEq(tokens[0].balanceOf(bob), amounts[0]);
        assertGt(amounts[0], 0);
        assertEq(tokens[6].balanceOf(bob), amounts[6]);
    }

    function testFuzzFullExitAndRefillPreservesPrecision(uint64 rawBalance, uint8 rawCycles) public {
        // Unequal, non-divisible seed positions exercise rounding rather than exact multiples.
        uint256 firstBalance = bound(uint256(rawBalance), 1e6, 1e12);
        uint256 cycles = bound(uint256(rawCycles), 1, 5);
        (M7CapVault fresh,) = _deployVault(tokens, _spacings(10), router, router, registry);
        uint256[8] memory initial;
        for (uint256 i; i < 7; ++i) {
            initial[i] = firstBalance * (i + 1) + i + 1;
            tokens[i].approve(address(fresh), type(uint256).max);
        }
        fresh.bootstrap(initial, address(this));
        for (uint256 cycle; cycle < cycles; ++cycle) {
            uint256 supplyBefore = fresh.totalSupply();
            uint256[8] memory beforeBalances;
            for (uint256 i; i < 7; ++i) {
                beforeBalances[i] = tokens[i].balanceOf(address(fresh));
            }
            uint256 circulating = fresh.balanceOf(address(this));
            uint256[8] memory amounts = fresh.quoteRedeem(circulating);
            fresh.redeemBasket(circulating, amounts, address(this), block.timestamp);
            for (uint256 i; i < 7; ++i) {
                uint256 residual = tokens[i].balanceOf(address(fresh));
                assertGe(residual, fresh.MIN_LOCKED_STOCK_UNITS());
                assertEq(
                    residual,
                    Math.mulDiv(beforeBalances[i], fresh.LOCKED_SHARES(), supplyBefore, Math.Rounding.Ceil)
                );
                // No underbacking, <1 raw unit rounding, and <1 bp relative rounding per full exit.
                uint256 excess = residual * supplyBefore - beforeBalances[i] * fresh.LOCKED_SHARES();
                assertLt(excess, supplyBefore);
                assertLt(excess * 10_000, beforeBalances[i] * fresh.LOCKED_SHARES());
            }
            uint256 refillShares = fresh.INITIAL_SHARES() - fresh.LOCKED_SHARES();
            uint256[8] memory refill = fresh.quoteMint(refillShares);
            fresh.mintBasket(refillShares, refill, address(this), block.timestamp);
            for (uint256 i; i < 7; ++i) {
                assertGe(tokens[i].balanceOf(address(fresh)), beforeBalances[i]);
                // Returning to 1,000 shares multiplies each residual by exactly 100.
                // Even repeated exit/refill cycles preserve the original within the one-exit bound.
                uint256 increase = tokens[i].balanceOf(address(fresh)) - initial[i];
                assertLt(increase, 100);
                assertLt(increase * 10_000, initial[i]);
            }
        }
    }
}
