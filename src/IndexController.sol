// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IM7Vault} from "./interfaces/IM7Vault.sol";
import {Valuation} from "./Valuation.sol";
import {Swap} from "./Types.sol";

/// @notice Ownerless quarterly reset of the vault to equal weights, from on-chain prices alone.
/// @dev Anyone may call `rebalance` once per calendar quarter when the valuation's safety gates pass. Callers choose no
///      trades: every leg is derived from the vault's backing and one oracle snapshot. A reset may at most double any
///      constituent's quantity share, each leg's minimum output is its oracle value less `MAX_SLIPPAGE_BPS`, and total
///      loss, including the caller's reward, is bounded by the traded value. A reset that trades pays its caller's
///      chosen address `min(REWARD_WAD * NAV, REWARD_CAP_USD)` in USDC from the vault.
contract IndexController is ReentrancyGuard {
    /// @dev Working memory for one reset. Prices are 1e18 USD per whole token; stocks use 1e8 raw units and USDC 1e6.
    ///      `target` holds 1e18-scaled quantity shares after the step; `goal` holds raw stock quantities.
    struct Plan {
        uint256[8] prices;
        uint256[8] held;
        uint256[7] target;
        uint256[7] goal;
        uint256 nav;
        uint256 supply;
        uint256 step;
        uint256 sold;
        uint256 bought;
        uint256 slack;
        uint256 floored;
        uint256 reward;
    }

    error InvalidConfiguration();
    error InvalidQuarter();
    error AlreadyRebalanced();
    error RebalanceLoss();
    error ResidualCash();
    error EmptyVault();
    error MissingComponent(uint256 index);
    error NotCompliant();
    error ExcessTurnover();
    error Expired();

    uint256 public constant WAD = 1e18;
    uint256 public constant BPS = 10_000;
    uint256 public constant STOCK_UNIT = 1e8;
    uint256 public constant USDC_UNIT = 1e6;
    /// @notice Each constituent's quantity share may move per reset by the larger of MAX_STEP_WAD (relative to its
    ///         current share) and MIN_STEP_WAD (absolute): a share can at most double, and a tiny or seized holding can
    ///         still be rebuilt. Larger moves finish over later quarters.
    uint256 public constant MAX_STEP_WAD = 1e18;
    uint256 public constant MIN_STEP_WAD = 0.0025e18;
    uint256 public constant MAX_SLIPPAGE_BPS = 100;
    /// @notice Within this spread of equal weights (and with little cash), a reset trades nothing.
    uint256 public constant DEADBAND_BPS = 10;
    uint256 public constant COMPLIANCE_BPS = 30;
    /// @notice A sanity fence: a reset selling more than this share of NAV reverts.
    uint256 public constant MAX_TURNOVER_BPS = 5_000;
    uint256 public constant MAX_CASH_BPS = 1;
    /// @notice Trades below this many raw USDC ($0.01) are skipped; pool rounding stays below 0.1% of any leg.
    uint256 public constant MIN_LEG_USDC = 1e4;
    /// @notice The reward for a reset that trades: 0.5 bp of NAV, at most $25.
    uint256 public constant REWARD_WAD = 0.00005e18;
    uint256 public constant REWARD_CAP_USD = 25e18;
    // Covers floor rounding in the eight component values; per-leg output rounding is tracked in `Plan.slack`.
    uint256 private constant LOSS_ROUNDING = 8;

    IM7Vault public immutable vault;
    Valuation public immutable valuation;
    mapping(uint32 => bool) public executedQuarter;
    uint32 public lastExecutedQuarter;

    event Rebalanced(
        uint32 indexed quarter,
        address indexed caller,
        address indexed rewardTo,
        uint256 navBefore,
        uint256 navAfter,
        uint256 stepWad,
        uint256 soldValue,
        uint256 boughtValue,
        uint256 rewardValue
    );

    constructor(IM7Vault vault_, Valuation valuation_) {
        if (address(vault_) == address(0) || address(valuation_) == address(0)) {
            revert InvalidConfiguration();
        }
        vault = vault_;
        valuation = valuation_;
    }

    /// @notice Calendar quarter: year * 4 + zero-based quarter.
    function currentQuarter() public view returns (uint32) {
        return quarterAt(block.timestamp);
    }

    /// @dev Exact Gregorian calculation, including century exceptions; no approximate 90-day epochs.
    function quarterAt(uint256 timestamp) public pure returns (uint32) {
        if (timestamp > 253402300799) revert InvalidQuarter(); // 9999-12-31 UTC.
        uint256 daysSinceEpoch = timestamp / 1 days;
        uint256 year = 1970 + daysSinceEpoch / 365;
        while (_yearStartDays(year) > daysSinceEpoch) --year;
        uint256 day = daysSinceEpoch - _yearStartDays(year);
        uint256 leap = (year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)) ? 1 : 0;
        uint256 quarter = day < 90 + leap ? 0 : day < 181 + leap ? 1 : day < 273 + leap ? 2 : 3;
        return uint32(year * 4 + quarter);
    }

    function _yearStartDays(uint256 year) private pure returns (uint256) {
        uint256 prior = year - 1;
        return 365 * (year - 1970) + prior / 4 - prior / 100 + prior / 400 - 477;
    }

    /// @notice Whether this quarter's reset has yet to run. It can run whenever the valuation's gates pass.
    function rebalanceDue() external view returns (bool) {
        return !executedQuarter[currentQuarter()];
    }

    /// @notice Reset the vault to equal weights: anyone, once per calendar quarter. The controller plans every trade,
    ///         and all safety checks are atomic with the swaps.
    /// @param rewardTo Receives the reward if the reset trades; the zero address declines it.
    function rebalance(uint256 deadline, address rewardTo) external nonReentrant {
        if (block.timestamp > deadline) revert Expired();
        uint32 quarter = currentQuarter();
        if (executedQuarter[quarter]) revert AlreadyRebalanced();
        for (uint256 i; i < 8; ++i) {
            if (address(vault.assets(i)) != valuation.assets(i)) revert InvalidConfiguration();
        }
        Plan memory plan;
        plan.prices = valuation.snapshot();
        plan.supply = vault.totalSupply();
        _readBacking(plan.held);
        (, plan.nav) = valuation.values(plan.held, plan.prices);
        if (plan.nav == 0 || plan.supply == 0) revert EmptyVault();
        _stepTowards(plan, _equalShares(plan.prices));
        _setGoals(plan, plan.nav);
        // Effects first. All state and token transfers roll back if any postcondition fails.
        executedQuarter[quarter] = true;
        lastExecutedQuarter = quarter;
        uint256 navAfter = plan.nav;
        if (
            !_compliant(plan.held, plan.target, plan.floored, DEADBAND_BPS)
                || !_cashWithinCap(plan.held[7], plan.nav, plan.prices[7])
        ) {
            // The reward leaves NAV, so the goals invest what remains: every stock funds its share of it.
            uint256 rewardUsd =
                rewardTo == address(0) ? 0 : Math.min(Math.mulDiv(plan.nav, REWARD_WAD, WAD), REWARD_CAP_USD);
            if (rewardUsd != 0) _setGoals(plan, plan.nav - rewardUsd);
            _sell(plan, deadline);
            _payReward(plan, rewardTo, rewardUsd);
            _buy(plan, deadline);
            navAfter = _verify(plan);
        }
        emit Rebalanced(
            quarter, msg.sender, rewardTo, plan.nav, navAfter, plan.step, plan.sold, plan.bought, plan.reward
        );
    }

    function _readBacking(uint256[8] memory held) private view {
        for (uint256 i; i < 8; ++i) {
            held[i] = vault.backing(i);
        }
    }

    /// @dev Quantity shares of equal value at `prices`: each proportional to 1 / price, summing to one. Valuation
    ///      caps prices at 1e36, so every share is positive.
    function _equalShares(uint256[8] memory prices) private pure returns (uint256[7] memory shares) {
        uint256[7] memory inverse;
        uint256 total;
        for (uint256 i; i < 7; ++i) {
            inverse[i] = Math.mulDiv(WAD, WAD, prices[i]);
            total += inverse[i];
        }
        uint256 assigned;
        for (uint256 i = 1; i < 7; ++i) {
            shares[i] = Math.mulDiv(inverse[i], WAD, total);
            assigned += shares[i];
        }
        shares[0] = WAD - assigned;
    }

    /// @dev Moves the current quantity shares s toward the equal-value shares c: t = s + a(c - s), with the largest
    ///      a <= 1 such that no share moves by more than max(MAX_STEP_WAD * s, MIN_STEP_WAD). t sums to one (up to
    ///      rounding) without renormalization, and every t is positive because c is.
    function _stepTowards(Plan memory plan, uint256[7] memory shares) private pure {
        uint256 total;
        for (uint256 i; i < 7; ++i) {
            total += plan.held[i];
        }
        if (total == 0) revert EmptyVault();
        uint256[7] memory current;
        uint256 step = WAD;
        for (uint256 i; i < 7; ++i) {
            current[i] = Math.mulDiv(plan.held[i], WAD, total);
            uint256 gap = shares[i] > current[i] ? shares[i] - current[i] : current[i] - shares[i];
            if (gap == 0) continue;
            uint256 limit = Math.max(Math.mulDiv(MAX_STEP_WAD, current[i], WAD), MIN_STEP_WAD);
            step = Math.min(step, Math.mulDiv(limit, WAD, gap));
        }
        plan.step = step;
        for (uint256 i; i < 7; ++i) {
            plan.target[i] = Math.mulDiv(current[i], WAD - step, WAD) + Math.mulDiv(shares[i], step, WAD);
            if (plan.target[i] == 0) revert MissingComponent(i);
        }
    }

    /// @dev Raw quantities that invest `investable` at the stepped shares, never below the vault's precision floor.
    ///      Rounded up so no stock is sold past its exact surplus. A stock lifted to the floor (for example after a
    ///      partial seizure) is restored to it and excluded from the proportional compliance check.
    function _setGoals(Plan memory plan, uint256 investable) private view {
        plan.floored = 0;
        uint256 denominator;
        for (uint256 i; i < 7; ++i) {
            denominator += plan.target[i] * plan.prices[i];
        }
        uint256 floorUnits = Math.mulDiv(
            vault.MIN_LOCKED_STOCK_UNITS(), plan.supply, vault.LOCKED_SHARES(), Math.Rounding.Ceil
        );
        for (uint256 i; i < 7; ++i) {
            uint256 goal =
                Math.mulDiv(investable, STOCK_UNIT * plan.target[i], denominator, Math.Rounding.Ceil);
            if (goal < floorUnits) {
                goal = floorUnits;
                plan.floored |= 1 << i;
            }
            plan.goal[i] = goal;
        }
    }

    function _sell(Plan memory plan, uint256 deadline) private {
        Swap[] memory legs = new Swap[](7);
        uint256 count;
        for (uint256 i; i < 7; ++i) {
            if (plan.held[i] <= plan.goal[i]) continue;
            uint256 amountIn = plan.held[i] - plan.goal[i];
            uint256 fair = Math.mulDiv(amountIn, plan.prices[i] * USDC_UNIT, plan.prices[7] * STOCK_UNIT);
            if (fair < MIN_LEG_USDC) continue;
            plan.sold += Math.mulDiv(amountIn, plan.prices[i], STOCK_UNIT);
            // A leg meeting its minimum can still round one raw output unit below the exact bound.
            plan.slack += Math.mulDiv(1, plan.prices[7], USDC_UNIT, Math.Rounding.Ceil);
            legs[count++] = Swap({
                tokenIn: uint8(i),
                tokenOut: 7,
                amountIn: amountIn,
                minAmountOut: Math.mulDiv(fair, BPS - MAX_SLIPPAGE_BPS, BPS, Math.Rounding.Ceil)
            });
        }
        if (plan.sold > Math.mulDiv(plan.nav, MAX_TURNOVER_BPS, BPS)) revert ExcessTurnover();
        if (count != 0) vault.rebalance(_trim(legs, count), deadline);
    }

    /// @dev The reward comes from the vault's USDC after the sales, never from amounts owed to earlier redeemers.
    function _payReward(Plan memory plan, address rewardTo, uint256 rewardUsd) private {
        if (rewardUsd == 0) return;
        uint256 amount = Math.min(Math.mulDiv(rewardUsd, USDC_UNIT, plan.prices[7]), vault.backing(7));
        if (amount == 0) return;
        plan.reward = Math.mulDiv(amount, plan.prices[7], USDC_UNIT, Math.Rounding.Ceil);
        vault.payReward(rewardTo, amount);
    }

    /// @dev Spends the USDC backing on the stocks below goal, pro rata to their oracle-valued deficits. Allocations
    ///      below MIN_LEG_USDC, and the rounding remainder, stay as cash within the cash cap.
    function _buy(Plan memory plan, uint256 deadline) private {
        uint256 cash = vault.backing(7);
        if (cash < MIN_LEG_USDC) return;
        uint256[7] memory need;
        uint256 totalNeed;
        for (uint256 i; i < 7; ++i) {
            uint256 held = vault.backing(i);
            if (held >= plan.goal[i]) continue;
            need[i] = Math.mulDiv(plan.goal[i] - held, plan.prices[i], STOCK_UNIT);
            totalNeed += need[i];
        }
        if (totalNeed == 0) return;
        Swap[] memory legs = new Swap[](7);
        uint256 count;
        uint256 spent;
        for (uint256 i; i < 7; ++i) {
            if (need[i] == 0) continue;
            uint256 amount = Math.mulDiv(cash, need[i], totalNeed);
            if (amount < MIN_LEG_USDC) continue;
            uint256 fair = Math.mulDiv(amount, plan.prices[7] * STOCK_UNIT, plan.prices[i] * USDC_UNIT);
            plan.slack += Math.mulDiv(1, plan.prices[i], STOCK_UNIT, Math.Rounding.Ceil);
            spent += amount;
            legs[count++] = Swap({
                tokenIn: 7,
                tokenOut: uint8(i),
                amountIn: amount,
                minAmountOut: Math.mulDiv(fair, BPS - MAX_SLIPPAGE_BPS, BPS, Math.Rounding.Ceil)
            });
        }
        if (count == 0) return;
        plan.bought = Math.mulDiv(spent, plan.prices[7], USDC_UNIT);
        vault.rebalance(_trim(legs, count), deadline);
    }

    function _verify(Plan memory plan) private view returns (uint256 navAfter) {
        if (vault.totalSupply() != plan.supply) revert RebalanceLoss();
        uint256[8] memory held;
        _readBacking(held);
        (, navAfter) = valuation.values(held, plan.prices);
        uint256 allowance = Math.mulDiv(plan.sold + plan.bought, MAX_SLIPPAGE_BPS, BPS) + plan.slack
            + plan.reward + LOSS_ROUNDING;
        if (navAfter + allowance < plan.nav) revert RebalanceLoss();
        for (uint256 i; i < 7; ++i) {
            if (held[i] == 0) revert MissingComponent(i);
        }
        if (!_compliant(held, plan.target, plan.floored, COMPLIANCE_BPS)) revert NotCompliant();
        if (!_cashWithinCap(held[7], navAfter, plan.prices[7])) revert ResidualCash();
    }

    /// @dev Price-free check: every stock holds the same quantity per unit of stepped share, within `toleranceBps`.
    ///      Stocks flagged in `skip` were lifted to the precision floor and are excluded.
    function _compliant(uint256[8] memory held, uint256[7] memory target, uint256 skip, uint256 toleranceBps)
        private
        pure
        returns (bool)
    {
        uint256 low = type(uint256).max;
        uint256 high;
        for (uint256 i; i < 7; ++i) {
            if ((skip & (1 << i)) != 0) continue;
            uint256 perShare = Math.mulDiv(held[i], WAD, target[i]);
            if (perShare < low) low = perShare;
            if (perShare > high) high = perShare;
        }
        return high * BPS <= low * (BPS + toleranceBps);
    }

    /// @dev Cash may stay up to 1 bp of NAV, or seven skipped minimum legs for a small vault.
    function _cashWithinCap(uint256 cash, uint256 nav, uint256 usdcPrice) private pure returns (bool) {
        uint256 cap = Math.max(
            Math.mulDiv(nav, MAX_CASH_BPS, BPS), Math.mulDiv(7 * MIN_LEG_USDC, usdcPrice, USDC_UNIT)
        );
        return Math.mulDiv(cash, usdcPrice, USDC_UNIT) <= cap;
    }

    function _trim(Swap[] memory legs, uint256 count) private pure returns (Swap[] memory) {
        assembly ("memory-safe") {
            mstore(legs, count)
        }
        return legs;
    }
}
