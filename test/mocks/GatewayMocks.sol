// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ISlipstreamRouter, ISlipstreamFactory} from "../../src/interfaces/ISlipstreamRouter.sol";

contract GatewayToken is ERC20 {
    uint8 private immutable _tokenDecimals;
    bool public blocked;

    constructor(uint8 decimals_) ERC20("Gateway test asset", "TEST") {
        _tokenDecimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _tokenDecimals;
    }

    function mint(address receiver, uint256 amount) external {
        _mint(receiver, amount);
    }

    function setBlocked(bool value) external {
        blocked = value;
    }

    function _update(address from, address to, uint256 amount) internal override {
        require(!blocked, "issuer blocked transfer");
        super._update(from, to, amount);
    }
}

contract GatewayFactory is ISlipstreamFactory {
    mapping(bytes32 => address) private _pools;

    function setPool(address a, address b, int24 spacing, address pool) external {
        _pools[_key(a, b, spacing)] = pool;
    }

    function getPool(address a, address b, int24 spacing) external view returns (address) {
        return _pools[_key(a, b, spacing)];
    }

    function _key(address a, address b, int24 spacing) private pure returns (bytes32) {
        return a < b ? keccak256(abi.encode(a, b, spacing)) : keccak256(abi.encode(b, a, spacing));
    }
}

/// @dev Deterministic one-dollar stocks with 8 decimals and USDC with 6 decimals.
contract GatewayRouter is ISlipstreamRouter {
    address public immutable factory;
    address public immutable usdc;
    uint256 public swapCalls;
    uint256 public failOnCall;
    bool public partialOutput;
    bool public partialInput;
    address public reentryTarget;
    bytes public reentryData;

    constructor(address factory_, address usdc_) {
        factory = factory_;
        usdc = usdc_;
    }

    function configure(uint256 failOnCall_, bool partialOutput_, bool partialInput_) external {
        swapCalls = 0;
        failOnCall = failOnCall_;
        partialOutput = partialOutput_;
        partialInput = partialInput_;
    }

    function setReentry(address target, bytes calldata data) external {
        reentryTarget = target;
        reentryData = data;
    }

    function exactOutputSingle(ExactOutputSingleParams calldata p)
        external
        payable
        returns (uint256 amountIn)
    {
        _beforeSwap(p.recipient, p.deadline);
        require(p.tokenIn == usdc && p.tokenOut != usdc, "invalid buy");
        require(p.sqrtPriceLimitX96 == 0, "price limit");
        amountIn = (p.amountOut + 99) / 100;
        require(amountIn <= p.amountInMaximum, "maximum input exceeded");
        IERC20(p.tokenIn).transferFrom(msg.sender, address(this), amountIn);
        IERC20(p.tokenOut).transfer(p.recipient, partialOutput ? p.amountOut - 1 : p.amountOut);
    }

    function exactInputSingle(ExactInputSingleParams calldata p)
        external
        payable
        returns (uint256 amountOut)
    {
        _beforeSwap(p.recipient, p.deadline);
        require(p.tokenOut == usdc && p.tokenIn != usdc, "invalid sell");
        require(p.sqrtPriceLimitX96 == 0, "price limit");
        uint256 spent = partialInput ? p.amountIn / 2 : p.amountIn;
        amountOut = spent / 100;
        require(amountOut >= p.amountOutMinimum, "minimum output not met");
        IERC20(p.tokenIn).transferFrom(msg.sender, address(this), spent);
        IERC20(p.tokenOut).transfer(p.recipient, amountOut);
    }

    function _beforeSwap(address recipient, uint256 deadline) private {
        require(recipient == msg.sender, "invalid recipient");
        require(block.timestamp <= deadline, "expired");
        swapCalls++;
        require(failOnCall == 0 || swapCalls != failOnCall, "swap failed");
        if (reentryTarget != address(0)) {
            (bool success, bytes memory reason) = reentryTarget.call(reentryData);
            if (!success) {
                assembly ("memory-safe") {
                    revert(add(reason, 32), mload(reason))
                }
            }
        }
    }
}
