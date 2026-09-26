// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @dev Indices 0..6 are the seven stocks; 7 is USDC. Routes never contain arbitrary calldata.
struct Swap {
    uint8 tokenIn;
    uint8 tokenOut;
    int24 tickSpacing;
    uint256 amountIn;
    uint256 minAmountOut;
}
