// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IM7CapVault} from "./interfaces/IM7CapVault.sol";
import {ISlipstreamRouter, ISlipstreamFactory} from "./interfaces/ISlipstreamRouter.sol";

/// @notice Atomic USDC entry and exit for one fixed basket, using direct Slipstream pools.
/// @dev No arbitrary calls, persistent approvals, administrative keys, or fee collection.
contract USDCGateway is ReentrancyGuard {
    using SafeERC20 for IERC20;

    IM7CapVault public immutable vault;
    ISlipstreamRouter public immutable router;
    ISlipstreamFactory public immutable factory;
    IERC20 public immutable usdc;

    error InvalidConfiguration();
    error InvalidRequest();
    error DeadlineExpired();
    error InvalidPool(uint256 assetIndex);
    error InsufficientUSDC();
    error UnexpectedBalance(uint256 assetIndex);
    error InsufficientProceeds();

    event MintedWithUSDC(address indexed caller, address indexed receiver, uint256 shares, uint256 usdcSpent);
    event RedeemedToUSDC(
        address indexed caller, address indexed receiver, uint256 shares, uint256 usdcReceived
    );

    constructor(IM7CapVault vault_, ISlipstreamRouter router_, ISlipstreamFactory factory_) {
        if (
            address(vault_) == address(0) || address(router_) == address(0) || address(factory_) == address(0)
                || router_.factory() != address(factory_)
        ) revert InvalidConfiguration();
        vault = vault_;
        router = router_;
        factory = factory_;
        usdc = vault_.assets(7);
        if (address(usdc) == address(0)) revert InvalidConfiguration();
    }

    /// @param tickSpacings One direct USDC/stock pool tick spacing per constituent, in vault asset order.
    /// @return usdcSpent The actual USDC cost; unused input is refunded to the caller.
    function mintWithUSDC(
        uint256 sharesOut,
        uint256 maxUSDCIn,
        address receiver,
        uint256 deadline,
        int24[7] calldata tickSpacings
    ) external nonReentrant returns (uint256 usdcSpent) {
        _checkRequest(sharesOut, receiver, deadline);
        uint256[8] memory beforeBalances = _balances();
        uint256[8] memory amounts = vault.quoteMint(sharesOut);
        if (maxUSDCIn < amounts[7]) revert InsufficientUSDC();
        usdc.safeTransferFrom(msg.sender, address(this), maxUSDCIn);
        if (usdc.balanceOf(address(this)) != beforeBalances[7] + maxUSDCIn) revert UnexpectedBalance(7);

        for (uint256 i; i < 7; ++i) {
            IERC20 stock = vault.assets(i);
            if (amounts[i] != 0) {
                _checkPool(stock, tickSpacings[i], i);
                uint256 available = usdc.balanceOf(address(this)) - beforeBalances[7];
                if (available < amounts[7]) revert InsufficientUSDC();
                usdc.forceApprove(address(router), available - amounts[7]);
                router.exactOutputSingle(
                    ISlipstreamRouter.ExactOutputSingleParams({
                        tokenIn: address(usdc),
                        tokenOut: address(stock),
                        tickSpacing: tickSpacings[i],
                        recipient: address(this),
                        deadline: deadline,
                        amountOut: amounts[i],
                        amountInMaximum: available - amounts[7],
                        sqrtPriceLimitX96: 0
                    })
                );
                if (stock.balanceOf(address(this)) != beforeBalances[i] + amounts[i]) {
                    revert UnexpectedBalance(i);
                }
                stock.forceApprove(address(vault), amounts[i]);
            }
        }
        usdc.forceApprove(address(router), 0);
        usdc.forceApprove(address(vault), amounts[7]);
        vault.mintBasket(sharesOut, amounts, receiver, deadline);

        for (uint256 i; i < 8; ++i) {
            IERC20 asset = vault.assets(i);
            asset.forceApprove(address(vault), 0);
            // A changed quote must not consume donations or silently return an incomplete basket.
            if (i < 7 && asset.balanceOf(address(this)) != beforeBalances[i]) revert UnexpectedBalance(i);
        }
        uint256 refund = usdc.balanceOf(address(this)) - beforeBalances[7];
        usdcSpent = maxUSDCIn - refund;
        if (refund != 0) usdc.safeTransfer(msg.sender, refund);
        emit MintedWithUSDC(msg.sender, receiver, sharesOut, usdcSpent);
    }

    /// @notice Approve vault shares to this gateway before calling. The whole transaction reverts on a failed sale.
    function redeemToUSDC(
        uint256 sharesIn,
        uint256 minUSDCOut,
        address receiver,
        uint256 deadline,
        int24[7] calldata tickSpacings
    ) external nonReentrant returns (uint256 usdcOut) {
        _checkRequest(sharesIn, receiver, deadline);
        uint256[8] memory beforeBalances = _balances();
        uint256[8] memory amounts = vault.quoteRedeem(sharesIn);
        IERC20(address(vault)).safeTransferFrom(msg.sender, address(this), sharesIn);
        vault.redeemBasket(sharesIn, amounts, address(this), deadline);

        for (uint256 i; i < 7; ++i) {
            IERC20 stock = vault.assets(i);
            if (stock.balanceOf(address(this)) != beforeBalances[i] + amounts[i]) {
                revert UnexpectedBalance(i);
            }
            if (amounts[i] != 0) {
                _checkPool(stock, tickSpacings[i], i);
                stock.forceApprove(address(router), amounts[i]);
                router.exactInputSingle(
                    ISlipstreamRouter.ExactInputSingleParams({
                        tokenIn: address(stock),
                        tokenOut: address(usdc),
                        tickSpacing: tickSpacings[i],
                        recipient: address(this),
                        deadline: deadline,
                        amountIn: amounts[i],
                        amountOutMinimum: 0,
                        sqrtPriceLimitX96: 0
                    })
                );
                stock.forceApprove(address(router), 0);
                if (stock.balanceOf(address(this)) != beforeBalances[i]) revert UnexpectedBalance(i);
            }
        }
        usdcOut = usdc.balanceOf(address(this)) - beforeBalances[7];
        if (usdcOut < minUSDCOut) revert InsufficientProceeds();
        if (usdcOut != 0) usdc.safeTransfer(receiver, usdcOut);
        emit RedeemedToUSDC(msg.sender, receiver, sharesIn, usdcOut);
    }

    function _balances() private view returns (uint256[8] memory balances) {
        for (uint256 i; i < 8; ++i) {
            balances[i] = vault.assets(i).balanceOf(address(this));
        }
    }

    function _checkPool(IERC20 stock, int24 tickSpacing, uint256 i) private view {
        if (tickSpacing <= 0 || factory.getPool(address(usdc), address(stock), tickSpacing) == address(0)) {
            revert InvalidPool(i);
        }
    }

    function _checkRequest(uint256 shares, address receiver, uint256 deadline) private view {
        if (shares == 0 || receiver == address(0) || receiver == address(this)) revert InvalidRequest();
        if (block.timestamp > deadline) revert DeadlineExpired();
    }
}
