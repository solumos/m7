// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IM7CapVault} from "./interfaces/IM7CapVault.sol";
import {ISlipstreamRouter, ISlipstreamFactory} from "./interfaces/ISlipstreamRouter.sol";
import {Swap} from "./Types.sol";

/// @notice A transferable receipt for a proportional, directly indexed stock basket.
/// @dev No owner, upgrade, fees, rescue, or unbacked mint. The immutable controller may only rebalance.
contract M7CapVault is ERC20, ReentrancyGuard, IM7CapVault {
    using SafeERC20 for IERC20;

    uint256 public constant INITIAL_SHARES = 1_000e18;
    uint256 public constant LOCKED_SHARES = 1e12;
    address public constant SEED_LOCK = address(1);
    IERC20[8] public override assets;
    address public immutable controller;
    address public immutable bootstrapper;
    ISlipstreamRouter public immutable router;
    ISlipstreamFactory public immutable factory;

    error InvalidConfiguration();
    error Unauthorized();
    error NotInitialized();
    error AlreadyInitialized();
    error InvalidAmount();
    error InvalidReceiver();
    error Expired();
    error InputLimit(uint256 index);
    error OutputLimit(uint256 index);
    error TransferMismatch(uint256 index);
    error MissingComponent(uint256 index);
    error InvalidSwap();

    event Bootstrapped(address indexed receiver, uint256[8] amounts);
    event BasketMinted(address indexed sender, address indexed receiver, uint256 shares, uint256[8] amounts);
    event BasketRedeemed(
        address indexed sender, address indexed receiver, uint256 shares, uint256[8] amounts
    );
    event BasketRebalanced(uint256 swaps);

    constructor(
        IERC20[8] memory assets_,
        address controller_,
        ISlipstreamRouter router_,
        ISlipstreamFactory factory_,
        address bootstrapper_
    ) ERC20("MAG7 Cap Index", "M7CAP") {
        if (
            controller_ == address(0) || bootstrapper_ == address(0) || address(router_) == address(0)
                || address(factory_) == address(0) || router_.factory() != address(factory_)
        ) revert InvalidConfiguration();
        for (uint256 i; i < 8; ++i) {
            if (address(assets_[i]) == address(0)) revert InvalidConfiguration();
            // B20s are native precompiles: deliberately do not require address.code.length > 0.
            if (IERC20Metadata(address(assets_[i])).decimals() != (i == 7 ? 6 : 8)) {
                revert InvalidConfiguration();
            }
            for (uint256 j; j < i; ++j) {
                if (assets_[i] == assets_[j]) revert InvalidConfiguration();
            }
        }
        assets = assets_;
        controller = controller_;
        bootstrapper = bootstrapper_;
        router = router_;
        factory = factory_;
    }

    /// @notice One-time funded initialization. The bootstrapper has no authority after this call.
    function bootstrap(uint256[8] calldata amounts, address receiver) external nonReentrant {
        if (msg.sender != bootstrapper) revert Unauthorized();
        if (totalSupply() != 0) revert AlreadyInitialized();
        _checkReceiver(receiver);
        for (uint256 i; i < 7; ++i) {
            if (amounts[i] == 0) revert MissingComponent(i);
        }
        if (amounts[7] != 0) revert InvalidAmount();
        _pull(amounts);
        _mint(SEED_LOCK, LOCKED_SHARES);
        _mint(receiver, INITIAL_SHARES - LOCKED_SHARES);
        emit Bootstrapped(receiver, amounts);
    }

    function quoteMint(uint256 sharesOut) public view override returns (uint256[8] memory amounts) {
        uint256 supply = totalSupply();
        if (supply == 0) revert NotInitialized();
        if (sharesOut == 0) revert InvalidAmount();
        for (uint256 i; i < 8; ++i) {
            uint256 balance = assets[i].balanceOf(address(this));
            // A seized-to-zero stock is not silently dropped from future issuance.
            if (i < 7 && balance == 0) revert MissingComponent(i);
            amounts[i] = Math.mulDiv(balance, sharesOut, supply, Math.Rounding.Ceil);
        }
    }

    function mintBasket(uint256 sharesOut, uint256[8] calldata maxAmounts, address receiver, uint256 deadline)
        external
        override
        nonReentrant
    {
        _checkDeadline(deadline);
        _checkReceiver(receiver);
        uint256[8] memory amounts = quoteMint(sharesOut);
        for (uint256 i; i < 8; ++i) {
            if (amounts[i] > maxAmounts[i]) revert InputLimit(i);
        }
        _pull(amounts);
        _mint(receiver, sharesOut);
        emit BasketMinted(msg.sender, receiver, sharesOut, amounts);
    }

    function quoteRedeem(uint256 sharesIn) public view override returns (uint256[8] memory amounts) {
        uint256 supply = totalSupply();
        if (supply == 0) revert NotInitialized();
        if (sharesIn == 0 || sharesIn > supply - LOCKED_SHARES) revert InvalidAmount();
        for (uint256 i; i < 8; ++i) {
            amounts[i] = Math.mulDiv(assets[i].balanceOf(address(this)), sharesIn, supply);
        }
    }

    /// @notice Burn the caller's shares and deliver the actual basket, without relying on a NAV oracle.
    function redeemBasket(
        uint256 sharesIn,
        uint256[8] calldata minAmounts,
        address receiver,
        uint256 deadline
    ) external override nonReentrant {
        _checkDeadline(deadline);
        _checkReceiver(receiver);
        uint256[8] memory amounts = quoteRedeem(sharesIn);
        for (uint256 i; i < 8; ++i) {
            if (amounts[i] < minAmounts[i]) revert OutputLimit(i);
        }
        _burn(msg.sender, sharesIn);
        for (uint256 i; i < 8; ++i) {
            if (amounts[i] == 0) continue;
            uint256 beforeBalance = assets[i].balanceOf(receiver);
            assets[i].safeTransfer(receiver, amounts[i]);
            if (assets[i].balanceOf(receiver) - beforeBalance != amounts[i]) revert TransferMismatch(i);
        }
        emit BasketRedeemed(msg.sender, receiver, sharesIn, amounts);
    }

    /// @dev The immutable controller enforces accepted targets and atomic pre/post NAV constraints.
    /// There are no external callbacks while the vault is unlocked during this batch.
    function rebalance(Swap[] calldata swaps, uint256 deadline) external override nonReentrant {
        if (msg.sender != controller) revert Unauthorized();
        _checkDeadline(deadline);
        if (totalSupply() == 0) revert NotInitialized();
        if (swaps.length > 14) revert InvalidSwap();
        for (uint256 i; i < swaps.length; ++i) {
            Swap calldata trade = swaps[i];
            if (
                trade.tokenIn > 7 || trade.tokenOut > 7 || trade.tokenIn == trade.tokenOut
                    || (trade.tokenIn != 7 && trade.tokenOut != 7) || trade.amountIn == 0
                    || trade.minAmountOut == 0 || trade.tickSpacing <= 0
            ) revert InvalidSwap();
            IERC20 input = assets[trade.tokenIn];
            IERC20 output = assets[trade.tokenOut];
            if (factory.getPool(address(input), address(output), trade.tickSpacing) == address(0)) {
                revert InvalidSwap();
            }
            uint256 beforeInput = input.balanceOf(address(this));
            uint256 beforeOutput = output.balanceOf(address(this));
            input.forceApprove(address(router), trade.amountIn);
            router.exactInputSingle(
                ISlipstreamRouter.ExactInputSingleParams({
                    tokenIn: address(input),
                    tokenOut: address(output),
                    tickSpacing: trade.tickSpacing,
                    recipient: address(this),
                    deadline: deadline,
                    amountIn: trade.amountIn,
                    amountOutMinimum: trade.minAmountOut,
                    sqrtPriceLimitX96: 0
                })
            );
            input.forceApprove(address(router), 0);
            if (beforeInput - input.balanceOf(address(this)) != trade.amountIn) {
                revert TransferMismatch(trade.tokenIn);
            }
            if (output.balanceOf(address(this)) - beforeOutput < trade.minAmountOut) {
                revert OutputLimit(trade.tokenOut);
            }
        }
        emit BasketRebalanced(swaps.length);
    }

    function _pull(uint256[8] memory amounts) private {
        for (uint256 i; i < 8; ++i) {
            if (amounts[i] == 0) continue;
            uint256 beforeBalance = assets[i].balanceOf(address(this));
            assets[i].safeTransferFrom(msg.sender, address(this), amounts[i]);
            if (assets[i].balanceOf(address(this)) - beforeBalance != amounts[i]) revert TransferMismatch(i);
        }
    }

    function _checkReceiver(address receiver) private view {
        if (receiver == address(0) || receiver == address(this) || receiver == SEED_LOCK) {
            revert InvalidReceiver();
        }
    }

    function _checkDeadline(uint256 deadline) private view {
        if (block.timestamp > deadline) revert Expired();
    }
}
