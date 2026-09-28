// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IM7Vault} from "./interfaces/IM7Vault.sol";
import {ISlipstreamRouter, ISlipstreamFactory} from "./interfaces/ISlipstreamRouter.sol";
import {IB20Policy, IPolicyRegistry, IControllerBinding} from "./interfaces/IB20Policy.sol";
import {Swap} from "./Types.sol";

/// @notice A transferable receipt for a proportional, directly indexed stock basket.
/// @dev No owner, upgrade, fees, rescue, or unbacked mint. The immutable controller may only rebalance, and only
///      through each stock's pinned USDC pool. Receipt transfers mirror the constituents' B20 transfer policies.
///      Balances owed to earlier redeemers (`reserved`) are excluded from all backing.
contract M7Vault is ERC20, ReentrancyGuard, IM7Vault {
    using SafeERC20 for IERC20;

    uint256 public constant INITIAL_SHARES = 1_000e18;
    // A 1% seed reserve prevents near-empty redemptions from resetting basket proportions to dust.
    uint256 public constant LOCKED_SHARES = 10e18;
    uint256 public constant MIN_LOCKED_STOCK_UNITS = 10_000;
    uint256 public constant MAX_LEGS = 7;
    address public constant SEED_LOCK = address(1);

    IERC20 private immutable _asset0;
    IERC20 private immutable _asset1;
    IERC20 private immutable _asset2;
    IERC20 private immutable _asset3;
    IERC20 private immutable _asset4;
    IERC20 private immutable _asset5;
    IERC20 private immutable _asset6;
    IERC20 private immutable _asset7;
    int24 private immutable _spacing0;
    int24 private immutable _spacing1;
    int24 private immutable _spacing2;
    int24 private immutable _spacing3;
    int24 private immutable _spacing4;
    int24 private immutable _spacing5;
    int24 private immutable _spacing6;
    address public immutable controller;
    address public immutable bootstrapper;
    ISlipstreamRouter public immutable router;
    ISlipstreamFactory public immutable factory;
    IPolicyRegistry public immutable policyRegistry;
    bytes32 public immutable senderScope;
    bytes32 public immutable receiverScope;
    bytes32 public immutable executorScope;

    uint256[8] private _reserved;
    mapping(address owner => uint256[8]) private _claims;

    error InvalidConfiguration();
    error InvalidIndex();
    error InvalidPool(uint256 index);
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
    error InsufficientLockedBacking(uint256 index);
    error InvalidSwap();
    error ExceedsBacking(uint256 index);
    error InsufficientClaim(uint256 index);
    error PolicyForbidden(uint256 index, bytes32 scope, address account);
    error PolicyUnavailable(uint256 index);

    event Bootstrapped(address indexed receiver, uint256[8] amounts);
    event BasketMinted(address indexed sender, address indexed receiver, uint256 shares, uint256[8] amounts);
    event BasketRedeemed(
        address indexed sender, address indexed receiver, uint256 shares, uint256[8] amounts
    );
    event BasketRedeemedWithClaims(
        address indexed sender,
        address indexed receiver,
        uint256 shares,
        uint256[8] delivered,
        uint256[8] deferred
    );
    event ClaimWithdrawn(address indexed owner, uint256 indexed index, address indexed to, uint256 amount);
    event BasketRebalanced(uint256 swaps);
    event RebalanceLeg(uint8 indexed tokenIn, uint8 indexed tokenOut, uint256 amountIn, uint256 amountOut);
    event RewardPaid(address indexed to, uint256 amount);

    constructor(
        IERC20[8] memory assets_,
        int24[7] memory tickSpacings_,
        address controller_,
        ISlipstreamRouter router_,
        ISlipstreamFactory factory_,
        IPolicyRegistry policyRegistry_,
        address bootstrapper_
    ) ERC20("M7 Equal Weight", "M7") {
        if (
            controller_ == address(0) || bootstrapper_ == address(0) || address(router_) == address(0)
                || address(factory_) == address(0) || address(policyRegistry_) == address(0)
                || router_.factory() != address(factory_)
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
        for (uint256 i; i < 7; ++i) {
            // Pin one reviewed pool per stock; executors can no longer choose a route.
            if (
                tickSpacings_[i] <= 0
                    || factory_.getPool(address(assets_[i]), address(assets_[7]), tickSpacings_[i])
                        == address(0)
            ) revert InvalidPool(i);
        }
        IB20Policy first = IB20Policy(address(assets_[0]));
        bytes32 sender = first.TRANSFER_SENDER_POLICY();
        bytes32 receiver = first.TRANSFER_RECEIVER_POLICY();
        bytes32 executor = first.TRANSFER_EXECUTOR_POLICY();
        if (sender == bytes32(0) || receiver == bytes32(0) || executor == bytes32(0)) {
            revert InvalidConfiguration();
        }
        for (uint256 i = 1; i < 7; ++i) {
            IB20Policy stock = IB20Policy(address(assets_[i]));
            if (
                stock.TRANSFER_SENDER_POLICY() != sender || stock.TRANSFER_RECEIVER_POLICY() != receiver
                    || stock.TRANSFER_EXECUTOR_POLICY() != executor
            ) revert InvalidConfiguration();
        }
        // Policy 0 always allows; a wrong registry address fails here instead of freezing transfers later.
        if (!policyRegistry_.isAuthorized(0, address(this))) revert InvalidConfiguration();
        // The controller is deployed first against this vault's predicted address. Refuse any other binding.
        if (IControllerBinding(controller_).vault() != address(this)) revert InvalidConfiguration();

        _asset0 = assets_[0];
        _asset1 = assets_[1];
        _asset2 = assets_[2];
        _asset3 = assets_[3];
        _asset4 = assets_[4];
        _asset5 = assets_[5];
        _asset6 = assets_[6];
        _asset7 = assets_[7];
        _spacing0 = tickSpacings_[0];
        _spacing1 = tickSpacings_[1];
        _spacing2 = tickSpacings_[2];
        _spacing3 = tickSpacings_[3];
        _spacing4 = tickSpacings_[4];
        _spacing5 = tickSpacings_[5];
        _spacing6 = tickSpacings_[6];
        controller = controller_;
        bootstrapper = bootstrapper_;
        router = router_;
        factory = factory_;
        policyRegistry = policyRegistry_;
        senderScope = sender;
        receiverScope = receiver;
        executorScope = executor;
    }

    /// @dev The Slipstream router refunds its whole ETH balance to the caller after every swap. Accepting that
    ///      refund stops dust left in the router from blocking swaps; the ETH is inert here. Deliberately not
    ///      `nonReentrant`: the refund arrives while this vault's lock is held.
    receive() external payable {
        if (msg.sender != address(router)) revert Unauthorized();
    }

    function assets(uint256 index) public view returns (IERC20) {
        if (index < 4) {
            if (index == 0) return _asset0;
            if (index == 1) return _asset1;
            if (index == 2) return _asset2;
            return _asset3;
        }
        if (index == 4) return _asset4;
        if (index == 5) return _asset5;
        if (index == 6) return _asset6;
        if (index == 7) return _asset7;
        revert InvalidIndex();
    }

    /// @notice The pinned USDC pool tick spacing for stock `index` (0..6).
    function tickSpacing(uint256 index) public view returns (int24) {
        if (index < 4) {
            if (index == 0) return _spacing0;
            if (index == 1) return _spacing1;
            if (index == 2) return _spacing2;
            return _spacing3;
        }
        if (index == 4) return _spacing4;
        if (index == 5) return _spacing5;
        if (index == 6) return _spacing6;
        revert InvalidIndex();
    }

    /// @notice Holdings that back shares: the balance minus amounts owed to earlier redeemers.
    function backing(uint256 index) public view returns (uint256) {
        uint256 balance = assets(index).balanceOf(address(this));
        uint256 owed = _reserved[index];
        return balance > owed ? balance - owed : 0;
    }

    function reserved(uint256 index) external view returns (uint256) {
        return _reserved[index];
    }

    function claimOf(address owner) external view returns (uint256[8] memory) {
        return _claims[owner];
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
        for (uint256 i; i < 7; ++i) {
            _checkLockedBacking(i, backing(i), INITIAL_SHARES);
        }
        _mint(SEED_LOCK, LOCKED_SHARES);
        _mint(receiver, INITIAL_SHARES - LOCKED_SHARES);
        emit Bootstrapped(receiver, amounts);
    }

    function quoteMint(uint256 sharesOut) public view returns (uint256[8] memory amounts) {
        uint256 supply = totalSupply();
        if (supply == 0) revert NotInitialized();
        if (sharesOut == 0) revert InvalidAmount();
        for (uint256 i; i < 8; ++i) {
            uint256 held = backing(i);
            if (i < 7) {
                // A seized-to-zero stock is not silently dropped from future issuance.
                if (held == 0) revert MissingComponent(i);
                _checkLockedBacking(i, held, supply);
            }
            amounts[i] = Math.mulDiv(held, sharesOut, supply, Math.Rounding.Ceil);
        }
    }

    function mintBasket(uint256 sharesOut, uint256[8] calldata maxAmounts, address receiver, uint256 deadline)
        external
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

    function quoteRedeem(uint256 sharesIn) public view returns (uint256[8] memory amounts) {
        uint256 supply = totalSupply();
        if (supply == 0) revert NotInitialized();
        if (sharesIn == 0 || sharesIn > supply - LOCKED_SHARES) revert InvalidAmount();
        for (uint256 i; i < 8; ++i) {
            amounts[i] = Math.mulDiv(backing(i), sharesIn, supply);
        }
    }

    /// @notice Burn the caller's shares and deliver the actual basket, without relying on a NAV oracle.
    ///         All-or-nothing: any failed leg reverts the whole redemption.
    function redeemBasket(
        uint256 sharesIn,
        uint256[8] calldata minAmounts,
        address receiver,
        uint256 deadline
    ) external nonReentrant {
        _checkDeadline(deadline);
        _checkReceiver(receiver);
        uint256[8] memory amounts = quoteRedeem(sharesIn);
        for (uint256 i; i < 8; ++i) {
            if (amounts[i] < minAmounts[i]) revert OutputLimit(i);
        }
        // Moving a stock's value out on the owner's behalf mirrors that stock's own transfer policy.
        _requireAuthorizedLegs(amounts, senderScope, msg.sender);
        _requireAuthorizedLegs(amounts, executorScope, msg.sender);
        _burn(msg.sender, sharesIn);
        for (uint256 i; i < 8; ++i) {
            if (amounts[i] == 0) continue;
            IERC20 asset = assets(i);
            uint256 beforeBalance = asset.balanceOf(receiver);
            asset.safeTransfer(receiver, amounts[i]);
            if (asset.balanceOf(receiver) - beforeBalance != amounts[i]) revert TransferMismatch(i);
        }
        emit BasketRedeemed(msg.sender, receiver, sharesIn, amounts);
    }

    /// @notice Burn the caller's shares and deliver every leg that can move now. A leg whose transfer fails
    ///         (frozen or paused asset, blocked receiver, or a policy that blocks the caller) becomes a claim owned
    ///         by the caller, withdrawable later with `withdrawClaim`. Nothing is forfeited.
    /// @dev `minAmounts` bounds each leg's entitlement, delivered or deferred. A transfer that succeeds but delivers
    ///      a different amount still reverts.
    function redeemBasketWithClaims(
        uint256 sharesIn,
        uint256[8] calldata minAmounts,
        address receiver,
        uint256 deadline
    ) external nonReentrant returns (uint256[8] memory delivered, uint256[8] memory deferred) {
        _checkDeadline(deadline);
        _checkReceiver(receiver);
        uint256[8] memory amounts = quoteRedeem(sharesIn);
        for (uint256 i; i < 8; ++i) {
            if (amounts[i] < minAmounts[i]) revert OutputLimit(i);
        }
        _burn(msg.sender, sharesIn);
        for (uint256 i; i < 8; ++i) {
            uint256 amount = amounts[i];
            if (amount == 0) continue;
            if (_tryDeliver(i, amount, receiver)) {
                delivered[i] = amount;
            } else {
                deferred[i] = amount;
                _reserved[i] += amount;
                _claims[msg.sender][i] += amount;
            }
        }
        emit BasketRedeemedWithClaims(msg.sender, receiver, sharesIn, delivered, deferred);
    }

    /// @notice Withdraw a deferred redemption leg once it can move. Claims are paid before holders' backing but are
    ///         not protected from issuer seizure of the vault's own holdings.
    function withdrawClaim(uint256 index, uint256 amount, address to) external nonReentrant {
        if (index > 7) revert InvalidIndex();
        _checkReceiver(to);
        if (amount == 0 || amount > _claims[msg.sender][index]) revert InsufficientClaim(index);
        if (index < 7) {
            _requireAuthorized(index, senderScope, msg.sender);
            _requireAuthorized(index, executorScope, msg.sender);
        }
        _claims[msg.sender][index] -= amount;
        _reserved[index] -= amount;
        IERC20 asset = assets(index);
        uint256 beforeBalance = asset.balanceOf(to);
        asset.safeTransfer(to, amount);
        if (asset.balanceOf(to) - beforeBalance != amount) revert TransferMismatch(index);
        emit ClaimWithdrawn(msg.sender, index, to, amount);
    }

    /// @dev The immutable controller plans every leg and enforces its target and loss bounds. Each call is
    ///      one direction (all stock->USDC or all USDC->stock), each stock at most once, through pinned pools only.
    ///      There are no external callbacks while the vault is unlocked during this batch.
    function rebalance(Swap[] calldata swaps, uint256 deadline) external nonReentrant {
        if (msg.sender != controller) revert Unauthorized();
        _checkDeadline(deadline);
        uint256 supply = totalSupply();
        if (supply == 0) revert NotInitialized();
        uint256 legs = swaps.length;
        if (legs == 0 || legs > MAX_LEGS) revert InvalidSwap();
        bool selling = swaps[0].tokenOut == 7;
        uint256[7] memory before;
        for (uint256 i; i < 7; ++i) {
            before[i] = assets(i).balanceOf(address(this));
        }
        uint256 seen;
        for (uint256 k; k < legs; ++k) {
            Swap calldata trade = swaps[k];
            uint256 stock = selling ? trade.tokenIn : trade.tokenOut;
            if (
                stock > 6 || (selling ? trade.tokenOut : trade.tokenIn) != 7 || (seen & (1 << stock)) != 0
                    || trade.amountIn == 0 || trade.minAmountOut == 0
            ) revert InvalidSwap();
            seen |= 1 << stock;
            if (trade.amountIn > backing(trade.tokenIn)) revert ExceedsBacking(trade.tokenIn);
            _swap(trade, stock, deadline);
        }
        for (uint256 i; i < 8; ++i) {
            if (assets(i).balanceOf(address(this)) < _reserved[i]) revert ExceedsBacking(i);
        }
        for (uint256 i; i < 7; ++i) {
            // Only a reduced stock can newly breach its floor; one already below it may still be restored.
            if (assets(i).balanceOf(address(this)) < before[i]) _checkLockedBacking(i, backing(i), supply);
        }
        emit BasketRebalanced(legs);
    }

    /// @notice Pays the controller's bounded quarterly-reset reward in USDC. Only the immutable controller can call it,
    ///         and it never touches amounts owed to earlier redeemers.
    function payReward(address to, uint256 amount) external nonReentrant {
        if (msg.sender != controller) revert Unauthorized();
        _checkReceiver(to);
        if (amount == 0 || amount > backing(7)) revert ExceedsBacking(7);
        IERC20 usdc = assets(7);
        uint256 beforeBalance = usdc.balanceOf(address(this));
        usdc.safeTransfer(to, amount);
        if (beforeBalance - usdc.balanceOf(address(this)) != amount) revert TransferMismatch(7);
        emit RewardPaid(to, amount);
    }

    function _swap(Swap calldata trade, uint256 stock, uint256 deadline) private {
        IERC20 input = assets(trade.tokenIn);
        IERC20 output = assets(trade.tokenOut);
        uint256 beforeInput = input.balanceOf(address(this));
        uint256 beforeOutput = output.balanceOf(address(this));
        input.forceApprove(address(router), trade.amountIn);
        router.exactInputSingle(
            ISlipstreamRouter.ExactInputSingleParams({
                tokenIn: address(input),
                tokenOut: address(output),
                tickSpacing: tickSpacing(stock),
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
        uint256 received = output.balanceOf(address(this)) - beforeOutput;
        if (received < trade.minAmountOut) revert OutputLimit(trade.tokenOut);
        emit RebalanceLeg(trade.tokenIn, trade.tokenOut, trade.amountIn, received);
    }

    /// @dev Receipt transfers and mints mirror every constituent's B20 transfer policy for the same parties.
    ///      Burns are checked per delivered stock by the redemption functions, so a resilient redemption can defer a
    ///      blocked leg instead of reverting. The seed lock is only ever a receiver and is exempt.
    function _update(address from, address to, uint256 value) internal override {
        if (to != address(0)) {
            if (from != address(0)) _requireAuthorizedAll(senderScope, from);
            if (to != SEED_LOCK) _requireAuthorizedAll(receiverScope, to);
            _requireAuthorizedAll(executorScope, msg.sender);
        }
        super._update(from, to, value);
    }

    function _tryDeliver(uint256 index, uint256 amount, address to) private returns (bool) {
        if (index < 7) {
            (bool senderOk, bool senderAllowed) = _check(index, senderScope, msg.sender);
            (bool executorOk, bool executorAllowed) = _check(index, executorScope, msg.sender);
            if (!(senderOk && senderAllowed && executorOk && executorAllowed)) return false;
        }
        IERC20 asset = assets(index);
        uint256 beforeBalance = asset.balanceOf(to);
        if (!asset.trySafeTransfer(to, amount)) return false;
        if (asset.balanceOf(to) - beforeBalance != amount) revert TransferMismatch(index);
        return true;
    }

    /// @dev A full circulating exit rounds each residual position by less than one raw unit.
    /// At least 10,000 units of locked backing bounds that exit's relative rounding below one bp.
    /// Ordinary mint/redeem cannot reduce backing per share; seizure may stop issuance, never exits.
    function _checkLockedBacking(uint256 index, uint256 balance, uint256 supply) private pure {
        if (Math.mulDiv(balance, LOCKED_SHARES, supply) < MIN_LOCKED_STOCK_UNITS) {
            revert InsufficientLockedBacking(index);
        }
    }

    function _pull(uint256[8] memory amounts) private {
        for (uint256 i; i < 8; ++i) {
            if (amounts[i] == 0) continue;
            IERC20 asset = assets(i);
            uint256 beforeBalance = asset.balanceOf(address(this));
            asset.safeTransferFrom(msg.sender, address(this), amounts[i]);
            if (asset.balanceOf(address(this)) - beforeBalance != amounts[i]) revert TransferMismatch(i);
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

    // ------------------------------------------------------------------ B20 policy lookups

    function _requireAuthorized(uint256 index, bytes32 scope, address account) private view {
        (bool ok, bool allowed) = _check(index, scope, account);
        if (!ok) revert PolicyUnavailable(index);
        if (!allowed) revert PolicyForbidden(index, scope, account);
    }

    /// @dev Checks all seven stocks, skipping policy 0 (always allow) and repeats of the id just authorized.
    function _requireAuthorizedAll(bytes32 scope, address account) private view {
        uint64 authorizedId;
        for (uint256 i; i < 7; ++i) {
            authorizedId = _requireStock(i, scope, account, authorizedId);
        }
    }

    /// @dev As `_requireAuthorizedAll`, restricted to stocks with a nonzero leg.
    function _requireAuthorizedLegs(uint256[8] memory amounts, bytes32 scope, address account) private view {
        uint64 authorizedId;
        for (uint256 i; i < 7; ++i) {
            if (amounts[i] != 0) authorizedId = _requireStock(i, scope, account, authorizedId);
        }
    }

    function _requireStock(uint256 index, bytes32 scope, address account, uint64 authorizedId)
        private
        view
        returns (uint64)
    {
        (bool ok, uint64 id) = _policyOf(index, scope);
        if (!ok) revert PolicyUnavailable(index);
        if (id == 0 || id == authorizedId) return authorizedId;
        (bool looked, bool allowed) = _authorized(id, account);
        if (!looked) revert PolicyUnavailable(index);
        if (!allowed) revert PolicyForbidden(index, scope, account);
        return id;
    }

    /// @return ok False when a lookup failed. `allowed` is meaningful only when `ok`.
    function _check(uint256 index, bytes32 scope, address account)
        private
        view
        returns (bool ok, bool allowed)
    {
        uint64 id;
        (ok, id) = _policyOf(index, scope);
        if (!ok) return (false, false);
        return _authorized(id, account);
    }

    function _policyOf(uint256 index, bytes32 scope) private view returns (bool ok, uint64 id) {
        (bool success, uint256 word) =
            _staticWord(address(assets(index)), abi.encodeCall(IB20Policy.policyId, (scope)));
        if (!success || word > type(uint64).max) return (false, 0);
        return (true, uint64(word));
    }

    function _authorized(uint64 id, address account) private view returns (bool ok, bool allowed) {
        if (id == 0) return (true, true);
        (bool success, uint256 word) =
            _staticWord(address(policyRegistry), abi.encodeCall(IPolicyRegistry.isAuthorized, (id, account)));
        if (!success || word > 1) return (false, false);
        return (true, word == 1);
    }

    /// @dev A static call that copies at most one return word, so return-data size cannot inflate gas.
    ///      Fewer than 32 returned bytes (including a call to an address without code) counts as failure.
    function _staticWord(address target, bytes memory data)
        private
        view
        returns (bool success, uint256 word)
    {
        assembly ("memory-safe") {
            success := staticcall(gas(), target, add(data, 0x20), mload(data), 0x00, 0x20)
            if lt(returndatasize(), 0x20) { success := 0 }
            word := mload(0x00)
        }
    }
}
