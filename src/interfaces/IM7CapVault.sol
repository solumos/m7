// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Swap} from "../Types.sol";

interface IM7CapVault is IERC20 {
    function assets(uint256 index) external view returns (IERC20);
    function quoteMint(uint256 sharesOut) external view returns (uint256[8] memory);
    function mintBasket(uint256 sharesOut, uint256[8] calldata maxAmounts, address receiver, uint256 deadline)
        external;
    function quoteRedeem(uint256 sharesIn) external view returns (uint256[8] memory);
    function redeemBasket(
        uint256 sharesIn,
        uint256[8] calldata minAmounts,
        address receiver,
        uint256 deadline
    ) external;
    function rebalance(Swap[] calldata swaps, uint256 deadline) external;
}
