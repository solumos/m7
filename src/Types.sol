// SPDX-License-Identifier: Unlicense
pragma solidity 0.8.30;

/// @dev Indices 0..6 are the seven stocks; 7 is USDC. Routes never contain arbitrary calldata or pools:
///      every leg trades a stock against USDC through that stock's pinned pool.
struct Swap {
    uint8 tokenIn;
    uint8 tokenOut;
    uint256 amountIn;
    uint256 minAmountOut;
}
