// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ISlipstreamRouter, ISlipstreamFactory} from "./ISlipstreamRouter.sol";
import {Swap} from "../Types.sol";

interface IM7Vault is IERC20 {
    function assets(uint256 index) external view returns (IERC20);
    function tickSpacing(uint256 index) external view returns (int24);
    function router() external view returns (ISlipstreamRouter);
    function factory() external view returns (ISlipstreamFactory);
    function controller() external view returns (address);
    function LOCKED_SHARES() external view returns (uint256);
    function MIN_LOCKED_STOCK_UNITS() external view returns (uint256);
    function backing(uint256 index) external view returns (uint256);
    function reserved(uint256 index) external view returns (uint256);
    function claimOf(address owner) external view returns (uint256[8] memory);
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
    function redeemBasketWithClaims(
        uint256 sharesIn,
        uint256[8] calldata minAmounts,
        address receiver,
        uint256 deadline
    ) external returns (uint256[8] memory delivered, uint256[8] memory deferred);
    function withdrawClaim(uint256 index, uint256 amount, address to) external;
    function rebalance(Swap[] calldata swaps, uint256 deadline) external;
    function payReward(address to, uint256 amount) external;
}
