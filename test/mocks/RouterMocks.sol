// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ISlipstreamRouter, ISlipstreamFactory} from "../../src/interfaces/ISlipstreamRouter.sol";
import {PoolOracleMock} from "./PoolOracleMock.sol";

/// @dev A funded venue quoting each stock at a fixed USDC rate, with optional per-direction haircuts kept by the
///      venue. Like the deployed Slipstream SwapRouter (0x698C...A92F), both single-hop swaps end with refundETH():
///      the router's entire ETH balance goes to msg.sender and the swap reverts with "STE" if that transfer fails.
///      unwrapWETH9 is payable and does nothing without WETH, as on the live router.
contract PricedVenue is ISlipstreamRouter, ISlipstreamFactory, PoolOracleMock {
    struct Call {
        address tokenIn;
        address tokenOut;
        int24 tickSpacing;
        uint256 amountIn;
        uint256 amountOut;
    }

    uint256 private constant BPS = 10_000;
    address public immutable usdc;
    /// Raw USDC units per raw stock unit, 1e18-scaled. A $100 8-decimal stock is 1e18.
    mapping(address => uint256) public rate;
    mapping(bytes32 => bool) private _pools;
    uint256 public sellHaircutBps;
    uint256 public buyHaircutBps;
    Call[] private _calls;

    constructor(address usdc_) {
        usdc = usdc_;
    }

    function factory() external view returns (address) {
        return address(this);
    }

    function setPool(address a, address b, int24 spacing, bool exists) external {
        _pools[_key(a, b, spacing)] = exists;
    }

    function getPool(address a, address b, int24 spacing) external view returns (address) {
        return _pools[_key(a, b, spacing)] ? address(this) : address(0);
    }

    function setRate(address stock, uint256 usdcPerStockWad) external {
        rate[stock] = usdcPerStockWad;
    }

    function setHaircuts(uint256 sellBps, uint256 buyBps) external {
        sellHaircutBps = sellBps;
        buyHaircutBps = buyBps;
    }

    function callCount() external view returns (uint256) {
        return _calls.length;
    }

    function callAt(uint256 index) external view returns (Call memory) {
        return _calls[index];
    }

    function exactInputSingle(ExactInputSingleParams calldata p)
        external
        payable
        returns (uint256 amountOut)
    {
        require(block.timestamp <= p.deadline, "Transaction too old");
        require(_pools[_key(p.tokenIn, p.tokenOut, p.tickSpacing)], "no pool");
        if (p.tokenIn == usdc) {
            amountOut = p.amountIn * 1e18 / rate[p.tokenOut] * (BPS - buyHaircutBps) / BPS;
        } else {
            require(p.tokenOut == usdc, "stock pairs only");
            amountOut = p.amountIn * rate[p.tokenIn] / 1e18 * (BPS - sellHaircutBps) / BPS;
        }
        require(amountOut >= p.amountOutMinimum, "Too little received");
        require(IERC20(p.tokenIn).transferFrom(msg.sender, address(this), p.amountIn));
        require(IERC20(p.tokenOut).transfer(p.recipient, amountOut));
        _calls.push(Call(p.tokenIn, p.tokenOut, p.tickSpacing, p.amountIn, amountOut));
        refundETH();
    }

    function exactOutputSingle(ExactOutputSingleParams calldata p)
        external
        payable
        returns (uint256 amountIn)
    {
        require(block.timestamp <= p.deadline, "Transaction too old");
        require(p.tokenIn == usdc, "buys only");
        require(_pools[_key(p.tokenIn, p.tokenOut, p.tickSpacing)], "no pool");
        uint256 fair = (p.amountOut * rate[p.tokenOut] + 1e18 - 1) / 1e18;
        amountIn = (fair * BPS + (BPS - buyHaircutBps) - 1) / (BPS - buyHaircutBps);
        require(amountIn <= p.amountInMaximum, "Too much requested");
        require(IERC20(p.tokenIn).transferFrom(msg.sender, address(this), amountIn));
        require(IERC20(p.tokenOut).transfer(p.recipient, p.amountOut));
        _calls.push(Call(p.tokenIn, p.tokenOut, p.tickSpacing, amountIn, p.amountOut));
        refundETH();
    }

    function unwrapWETH9(uint256, address) external payable {}

    function refundETH() public payable {
        if (address(this).balance > 0) {
            (bool success,) = msg.sender.call{value: address(this).balance}(new bytes(0));
            require(success, "STE");
        }
    }

    function _key(address a, address b, int24 spacing) private pure returns (bytes32) {
        return a < b ? keccak256(abi.encode(a, b, spacing)) : keccak256(abi.encode(b, a, spacing));
    }
}
