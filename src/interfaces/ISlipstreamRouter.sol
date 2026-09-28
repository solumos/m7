// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @dev Aerodrome Slipstream periphery ABI. The factory uses tick spacing, not a V3 fee tier.
interface ISlipstreamRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        int24 tickSpacing;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    struct ExactOutputSingleParams {
        address tokenIn;
        address tokenOut;
        int24 tickSpacing;
        address recipient;
        uint256 deadline;
        uint256 amountOut;
        uint256 amountInMaximum;
        uint160 sqrtPriceLimitX96;
    }

    function factory() external view returns (address);
    function exactInputSingle(ExactInputSingleParams calldata params)
        external
        payable
        returns (uint256 amountOut);
    function exactOutputSingle(ExactOutputSingleParams calldata params)
        external
        payable
        returns (uint256 amountIn);
}

interface ISlipstreamFactory {
    function getPool(address tokenA, address tokenB, int24 tickSpacing) external view returns (address);
}

/// @dev Slipstream CLPool's Uniswap V3-style oracle. An observation is written at most once per block, before that
///      block's first swap, so trades inside the current block do not move the averages it returns.
interface ISlipstreamPoolOracle {
    function observe(uint32[] calldata secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s);
}
