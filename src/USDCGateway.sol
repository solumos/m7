// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IM7CapVault} from "./interfaces/IM7CapVault.sol";
import {ISlipstreamRouter} from "./interfaces/ISlipstreamRouter.sol";

/// @notice Atomic USDC entry and exit for one fixed basket, through the vault's pinned Slipstream pools.
/// @dev No arbitrary calls, persistent approvals, or user funds held between transactions. The owner may only set a
///      trade fee of at most `MAX_FEE_BPS` and claim fees already charged. It cannot touch vault assets, routes,
///      donations or user balances. A caller's `maxUSDCIn` and `minUSDCOut` limits include the fee.
contract USDCGateway is ReentrancyGuard, Ownable2Step {
    using SafeERC20 for IERC20;

    uint256 public constant BPS = 10_000;
    uint16 public constant MAX_FEE_BPS = 10;
    uint16 public constant INITIAL_FEE_BPS = 1;

    IM7CapVault public immutable vault;
    ISlipstreamRouter public immutable router;
    IERC20 public immutable usdc;
    IERC20 private immutable _stock0;
    IERC20 private immutable _stock1;
    IERC20 private immutable _stock2;
    IERC20 private immutable _stock3;
    IERC20 private immutable _stock4;
    IERC20 private immutable _stock5;
    IERC20 private immutable _stock6;
    int24 private immutable _spacing0;
    int24 private immutable _spacing1;
    int24 private immutable _spacing2;
    int24 private immutable _spacing3;
    int24 private immutable _spacing4;
    int24 private immutable _spacing5;
    int24 private immutable _spacing6;

    /// @notice Fee charged on each USDC mint (on USDC spent) and redemption (on gross USDC proceeds).
    uint16 public feeBps;
    /// @notice USDC fees charged and not yet claimed by the owner.
    uint256 public accruedFees;

    error InvalidConfiguration();
    error InvalidRequest();
    error DeadlineExpired();
    error InsufficientUSDC();
    error UnexpectedBalance(uint256 assetIndex);
    error InsufficientProceeds();
    error Unauthorized();
    error FeeTooHigh();
    error InsufficientFees();
    error FeesOutstanding();

    event MintedWithUSDC(
        address indexed caller, address indexed receiver, uint256 shares, uint256 usdcSpent, uint256 fee
    );
    event RedeemedToUSDC(
        address indexed caller, address indexed receiver, uint256 shares, uint256 usdcReceived, uint256 fee
    );
    event FeeUpdated(uint16 previousFeeBps, uint16 newFeeBps);
    event FeesClaimed(address indexed to, uint256 amount);

    constructor(IM7CapVault vault_, address owner_) Ownable(owner_) {
        if (address(vault_) == address(0)) revert InvalidConfiguration();
        vault = vault_;
        router = vault_.router();
        usdc = vault_.assets(7);
        if (address(router) == address(0) || address(usdc) == address(0)) revert InvalidConfiguration();
        _stock0 = vault_.assets(0);
        _stock1 = vault_.assets(1);
        _stock2 = vault_.assets(2);
        _stock3 = vault_.assets(3);
        _stock4 = vault_.assets(4);
        _stock5 = vault_.assets(5);
        _stock6 = vault_.assets(6);
        _spacing0 = vault_.tickSpacing(0);
        _spacing1 = vault_.tickSpacing(1);
        _spacing2 = vault_.tickSpacing(2);
        _spacing3 = vault_.tickSpacing(3);
        _spacing4 = vault_.tickSpacing(4);
        _spacing5 = vault_.tickSpacing(5);
        _spacing6 = vault_.tickSpacing(6);
        feeBps = INITIAL_FEE_BPS;
        emit FeeUpdated(0, INITIAL_FEE_BPS);
    }

    /// @dev Accepts the router's automatic ETH refund so dust left in the router cannot block swaps. Deliberately
    ///      not `nonReentrant`: the refund arrives while this gateway's lock is held.
    receive() external payable {
        if (msg.sender != address(router)) revert Unauthorized();
    }

    /// @notice Buy the vault's exact component quantities for `sharesOut` and mint them to `receiver`.
    /// @return usdcSpent The USDC taken from the caller, including the fee; the rest of `maxUSDCIn` is refunded.
    function mintWithUSDC(uint256 sharesOut, uint256 maxUSDCIn, address receiver, uint256 deadline)
        external
        nonReentrant
        returns (uint256 usdcSpent)
    {
        _checkRequest(sharesOut, receiver, deadline);
        uint256[8] memory beforeBalances = _balances();
        uint256[8] memory amounts = vault.quoteMint(sharesOut);
        if (maxUSDCIn < amounts[7]) revert InsufficientUSDC();
        usdc.safeTransferFrom(msg.sender, address(this), maxUSDCIn);
        if (usdc.balanceOf(address(this)) != beforeBalances[7] + maxUSDCIn) revert UnexpectedBalance(7);

        for (uint256 i; i < 7; ++i) {
            IERC20 stock = _stock(i);
            uint256 available = usdc.balanceOf(address(this)) - beforeBalances[7];
            if (available < amounts[7]) revert InsufficientUSDC();
            usdc.forceApprove(address(router), available - amounts[7]);
            router.exactOutputSingle(
                ISlipstreamRouter.ExactOutputSingleParams({
                    tokenIn: address(usdc),
                    tokenOut: address(stock),
                    tickSpacing: _spacing(i),
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
        usdc.forceApprove(address(router), 0);
        usdc.forceApprove(address(vault), amounts[7]);
        vault.mintBasket(sharesOut, amounts, receiver, deadline);

        for (uint256 i; i < 8; ++i) {
            IERC20 asset = i == 7 ? usdc : _stock(i);
            asset.forceApprove(address(vault), 0);
            // A changed quote must not consume donations or silently return an incomplete basket.
            if (i < 7 && asset.balanceOf(address(this)) != beforeBalances[i]) revert UnexpectedBalance(i);
        }
        uint256 unspent = usdc.balanceOf(address(this)) - beforeBalances[7];
        uint256 cost = maxUSDCIn - unspent;
        uint256 fee = _fee(cost);
        if (fee > unspent) revert InsufficientUSDC();
        accruedFees += fee;
        usdcSpent = cost + fee;
        uint256 refund = unspent - fee;
        if (refund != 0) usdc.safeTransfer(msg.sender, refund);
        emit MintedWithUSDC(msg.sender, receiver, sharesOut, usdcSpent, fee);
    }

    /// @notice Approve vault shares to this gateway before calling. The whole transaction reverts on a failed sale.
    /// @return usdcOut USDC paid to `receiver` after the fee.
    function redeemToUSDC(uint256 sharesIn, uint256 minUSDCOut, address receiver, uint256 deadline)
        external
        nonReentrant
        returns (uint256 usdcOut)
    {
        _checkRequest(sharesIn, receiver, deadline);
        uint256[8] memory beforeBalances = _balances();
        uint256[8] memory amounts = vault.quoteRedeem(sharesIn);
        IERC20(address(vault)).safeTransferFrom(msg.sender, address(this), sharesIn);
        vault.redeemBasket(sharesIn, amounts, address(this), deadline);

        for (uint256 i; i < 7; ++i) {
            IERC20 stock = _stock(i);
            if (stock.balanceOf(address(this)) != beforeBalances[i] + amounts[i]) {
                revert UnexpectedBalance(i);
            }
            if (amounts[i] != 0) {
                stock.forceApprove(address(router), amounts[i]);
                router.exactInputSingle(
                    ISlipstreamRouter.ExactInputSingleParams({
                        tokenIn: address(stock),
                        tokenOut: address(usdc),
                        tickSpacing: _spacing(i),
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
        uint256 gross = usdc.balanceOf(address(this)) - beforeBalances[7];
        uint256 fee = _fee(gross);
        usdcOut = gross - fee;
        if (usdcOut < minUSDCOut) revert InsufficientProceeds();
        accruedFees += fee;
        if (usdcOut != 0) usdc.safeTransfer(receiver, usdcOut);
        emit RedeemedToUSDC(msg.sender, receiver, sharesIn, usdcOut, fee);
    }

    /// @notice The fee the gateway would charge on `amount` USDC at the current rate.
    function previewFee(uint256 amount) external view returns (uint256) {
        return _fee(amount);
    }

    /// @notice Set the trade fee, at most `MAX_FEE_BPS`. Zero turns the fee off.
    function setFee(uint16 newFeeBps) external onlyOwner {
        if (newFeeBps > MAX_FEE_BPS) revert FeeTooHigh();
        emit FeeUpdated(feeBps, newFeeBps);
        feeBps = newFeeBps;
    }

    /// @notice Pay out fees already charged. Donations and in-flight user funds are never claimable.
    function claimFees(address to, uint256 amount) external onlyOwner nonReentrant {
        if (to == address(0) || to == address(this)) revert InvalidRequest();
        if (amount == 0 || amount > accruedFees) revert InsufficientFees();
        accruedFees -= amount;
        usdc.safeTransfer(to, amount);
        emit FeesClaimed(to, amount);
    }

    /// @notice Renouncing is allowed only once the fee is off and every fee has been claimed, which leaves the
    ///         gateway permanently fee-free.
    function renounceOwnership() public override onlyOwner {
        if (feeBps != 0 || accruedFees != 0) revert FeesOutstanding();
        super.renounceOwnership();
    }

    function _fee(uint256 amount) private view returns (uint256) {
        uint16 rate = feeBps;
        return rate == 0 ? 0 : Math.mulDiv(amount, rate, BPS, Math.Rounding.Ceil);
    }

    function _balances() private view returns (uint256[8] memory balances) {
        for (uint256 i; i < 7; ++i) {
            balances[i] = _stock(i).balanceOf(address(this));
        }
        balances[7] = usdc.balanceOf(address(this));
    }

    function _stock(uint256 index) private view returns (IERC20) {
        if (index == 0) return _stock0;
        if (index == 1) return _stock1;
        if (index == 2) return _stock2;
        if (index == 3) return _stock3;
        if (index == 4) return _stock4;
        if (index == 5) return _stock5;
        return _stock6;
    }

    function _spacing(uint256 index) private view returns (int24) {
        if (index == 0) return _spacing0;
        if (index == 1) return _spacing1;
        if (index == 2) return _spacing2;
        if (index == 3) return _spacing3;
        if (index == 4) return _spacing4;
        if (index == 5) return _spacing5;
        return _spacing6;
    }

    function _checkRequest(uint256 shares, address receiver, uint256 deadline) private view {
        if (shares == 0 || receiver == address(0) || receiver == address(this)) revert InvalidRequest();
        if (block.timestamp > deadline) revert DeadlineExpired();
    }
}
