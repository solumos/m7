// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IM7Vault} from "./interfaces/IM7Vault.sol";
import {ISlipstreamPoolOracle} from "./interfaces/ISlipstreamRouter.sol";
import {Valuation} from "./Valuation.sol";
import {Swap} from "./Types.sol";

/// @notice Ownerless quarterly reset of the vault to equal weights, from on-chain prices alone.
/// @dev Anyone may call `rebalance` while the valuation's safety gates pass. Each call trades one tranche planned from
///      the vault's backing and one oracle snapshot: every stock moves the same fraction of the way to its equal-weight
///      goal, and no trade is worth more than MAX_LEG_USD. No trade starts in a pool whose price has moved against the
///      vault by more than MAX_POOL_MOVE_TICKS from its own POOL_TWAP_WINDOW average, so a caller cannot push prices
///      before its own call. Each leg returns at least its oracle value less MAX_SLIPPAGE_BPS, and total loss, including
///      the caller's reward, is bounded by the traded value. Tranches repeat at least TRANCHE_COOLDOWN apart until the
///      basket is within DEADBAND_BPS of equal weight, which completes the quarter.
contract IndexController is ReentrancyGuard {
    /// @dev Working memory for one tranche. Prices are 1e18 USD per whole token; stocks use 1e8 raw units and USDC 1e6.
    ///      `shares` are the equal-value quantity shares and `target` the stepped ones (1e18-scaled). `goal` holds the
    ///      raw quantities of the whole move and `next` this tranche's, `fraction` of the way from `held` to `goal`.
    struct Plan {
        uint256[8] prices;
        uint256[8] held;
        uint256[7] shares;
        uint256[7] target;
        uint256[7] goal;
        uint256[7] next;
        uint256 nav;
        uint256 supply;
        uint256 step;
        uint256 fraction;
        uint256 sold;
        uint256 bought;
        uint256 slack;
        uint256 floored;
        uint256 legs;
        uint256 heldBack;
        uint256 rewardRaw;
        uint256 reward;
    }

    error InvalidConfiguration();
    error InvalidQuarter();
    error AlreadyRebalanced();
    error TooSoon();
    error RebalanceLoss();
    error ResidualCash();
    error EmptyVault();
    error MissingComponent(uint256 index);
    error NotCompliant();
    error PoolMoved(uint256 index);
    error PoolUnavailable(uint256 index);
    error Expired();

    uint256 public constant WAD = 1e18;
    uint256 public constant BPS = 10_000;
    uint256 public constant STOCK_UNIT = 1e8;
    uint256 public constant USDC_UNIT = 1e6;
    /// @notice Each constituent's quantity share may move per tranche by the larger of MAX_STEP_WAD (relative to its
    ///         current share) and MIN_STEP_WAD (absolute): a share can at most double, and a tiny or seized holding can
    ///         still be rebuilt. Larger moves finish over later tranches.
    uint256 public constant MAX_STEP_WAD = 1e18;
    uint256 public constant MIN_STEP_WAD = 0.0025e18;
    uint256 public constant MAX_SLIPPAGE_BPS = 100;
    /// @notice Within this spread of equal weights (and with little cash), the quarter's reset is complete.
    uint256 public constant DEADBAND_BPS = 10;
    /// @notice After a tranche, no stock may end further from its goal than it started, beyond this share of the goal.
    uint256 public constant COMPLIANCE_BPS = 30;
    uint256 public constant MAX_CASH_BPS = 1;
    /// @notice Trades below this many raw USDC ($0.01) are skipped; pool rounding stays below 0.1% of any leg.
    uint256 public constant MIN_LEG_USDC = 1e4;
    /// @notice No sale in a tranche is worth more than this, and purchases only exceed it by what the sales raised
    ///         above oracle value: larger moves are spread over tranches, which keeps each trade within the pinned
    ///         pools' depth and too small to be worth sandwiching.
    uint256 public constant MAX_LEG_USD = 10_000e18;
    /// @notice Minimum time between tranches, so pools can return to their oracle prices.
    uint256 public constant TRANCHE_COOLDOWN = 30 minutes;
    /// @notice Minimum time between the completions of two quarters' resets.
    uint256 public constant MIN_RESET_SPACING = 30 days;
    /// @notice A pool's price may sit at most this many ticks (about 0.01% each) against the vault's trade, measured
    ///         from its own time-weighted average over POOL_TWAP_WINDOW.
    int24 public constant MAX_POOL_MOVE_TICKS = 25;
    uint32 public constant POOL_TWAP_WINDOW = 10 minutes;
    /// @notice A tranche that trades pays its caller 5 bp of its one-way traded value, at most $25.
    uint256 public constant REWARD_BPS = 5;
    uint256 public constant REWARD_CAP_USD = 25e18;
    // Covers floor rounding in the eight component values; per-leg output rounding is tracked in `Plan.slack`.
    uint256 private constant LOSS_ROUNDING = 8;

    IM7Vault public immutable vault;
    Valuation public immutable valuation;
    mapping(uint32 => bool) public executedQuarter;
    uint32 public lastExecutedQuarter;
    uint64 public lastTrancheAt;
    uint64 public lastCompletedAt;

    event Rebalanced(
        uint32 indexed quarter,
        address indexed caller,
        address indexed rewardTo,
        uint256 navBefore,
        uint256 navAfter,
        uint256 fractionWad,
        uint256 soldValue,
        uint256 boughtValue,
        uint256 rewardValue,
        bool completed
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

    /// @notice The earliest time the next tranche may start, apart from the valuation's own gates.
    function nextTrancheAt() public view returns (uint256) {
        return
            Math.max(uint256(lastTrancheAt) + TRANCHE_COOLDOWN, uint256(lastCompletedAt) + MIN_RESET_SPACING);
    }

    /// @notice Whether a tranche of this quarter's reset may start now, if the valuation's gates pass.
    function rebalanceDue() external view returns (bool) {
        return !executedQuarter[currentQuarter()] && block.timestamp >= nextTrancheAt();
    }

    /// @notice Trade one tranche towards equal weights: anyone, while this quarter's reset is incomplete. The controller
    ///         plans every trade, and all safety checks are atomic with the swaps.
    /// @param rewardTo Receives the reward if the tranche trades; the zero address declines it.
    function rebalance(uint256 deadline, address rewardTo) external nonReentrant {
        if (block.timestamp > deadline) revert Expired();
        uint32 quarter = currentQuarter();
        if (executedQuarter[quarter]) revert AlreadyRebalanced();
        if (block.timestamp < nextTrancheAt()) revert TooSoon();
        // A reward sent here could never move again; the vault refuses itself and the seed lock.
        if (rewardTo == address(this) || rewardTo == address(valuation)) revert InvalidConfiguration();
        for (uint256 i; i < 8; ++i) {
            if (address(vault.assets(i)) != valuation.assets(i)) revert InvalidConfiguration();
        }
        Plan memory plan;
        plan.prices = valuation.snapshot();
        plan.supply = vault.totalSupply();
        _readBacking(plan.held);
        (, plan.nav) = valuation.values(plan.held, plan.prices);
        if (plan.nav == 0 || plan.supply == 0) revert EmptyVault();
        _equalShares(plan);
        _stepTowards(plan);
        _setGoals(plan, plan.nav);
        lastTrancheAt = uint64(block.timestamp);
        uint256 navAfter = plan.nav;
        bool completed = _complete(plan, plan.held, plan.nav);
        if (!completed) {
            _size(plan, rewardTo);
            _checkPools(plan);
            _sell(plan, deadline);
            _buy(plan, deadline);
            _payReward(plan, rewardTo);
            uint256[8] memory held;
            _readBacking(held);
            navAfter = _verify(plan, held);
            // A tranche whose every leg was dust has nothing left to do.
            completed = plan.legs == 0 || _complete(plan, held, navAfter);
        }
        if (completed) {
            executedQuarter[quarter] = true;
            lastExecutedQuarter = quarter;
            lastCompletedAt = uint64(block.timestamp);
        }
        emit Rebalanced(
            quarter,
            msg.sender,
            rewardTo,
            plan.nav,
            navAfter,
            Math.mulDiv(plan.step, plan.fraction, WAD),
            plan.sold,
            plan.bought,
            plan.reward,
            completed
        );
    }

    function _readBacking(uint256[8] memory held) private view {
        for (uint256 i; i < 8; ++i) {
            held[i] = vault.backing(i);
        }
    }

    /// @dev Quantity shares of equal value at the snapshot: each proportional to 1 / price, summing to one. Valuation
    ///      caps prices at 1e36, so every share is positive.
    function _equalShares(Plan memory plan) private pure {
        uint256[7] memory inverse;
        uint256 total;
        for (uint256 i; i < 7; ++i) {
            inverse[i] = Math.mulDiv(WAD, WAD, plan.prices[i]);
            total += inverse[i];
        }
        uint256 assigned;
        for (uint256 i = 1; i < 7; ++i) {
            plan.shares[i] = Math.mulDiv(inverse[i], WAD, total);
            assigned += plan.shares[i];
        }
        plan.shares[0] = WAD - assigned;
    }

    /// @dev Moves the current quantity shares s toward the equal-value shares c: t = s + a(c - s), with the largest
    ///      a <= 1 such that no share moves by more than max(MAX_STEP_WAD * s, MIN_STEP_WAD). t sums to one (up to
    ///      rounding) without renormalization, and every t is positive because c is.
    function _stepTowards(Plan memory plan) private pure {
        uint256 total;
        for (uint256 i; i < 7; ++i) {
            total += plan.held[i];
        }
        if (total == 0) revert EmptyVault();
        uint256[7] memory current;
        uint256 step = WAD;
        for (uint256 i; i < 7; ++i) {
            current[i] = Math.mulDiv(plan.held[i], WAD, total);
            uint256 share = plan.shares[i];
            uint256 gap = share > current[i] ? share - current[i] : current[i] - share;
            if (gap == 0) continue;
            uint256 limit = Math.max(Math.mulDiv(MAX_STEP_WAD, current[i], WAD), MIN_STEP_WAD);
            step = Math.min(step, Math.mulDiv(limit, WAD, gap));
        }
        plan.step = step;
        for (uint256 i; i < 7; ++i) {
            plan.target[i] = Math.mulDiv(current[i], WAD - step, WAD) + Math.mulDiv(plan.shares[i], step, WAD);
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

    /// @dev Sizes the tranche: the largest trade of the whole move sets the fraction taken now. The reward is 5 bp of
    ///      the tranche's one-way traded value. It leaves NAV, so the goals invest what remains and every stock funds
    ///      its share of it. Cash the whole move would invest is drawn down in step with it.
    function _size(Plan memory plan, address rewardTo) private view {
        (uint256 turnover, uint256 largest) = _measure(plan);
        // Funding the reward can add up to REWARD_BPS to a sale, so size against the cap less that.
        uint256 cap = MAX_LEG_USD - Math.mulDiv(MAX_LEG_USD, REWARD_BPS, BPS);
        plan.fraction = largest > cap ? Math.mulDiv(cap, WAD, largest) : WAD;
        uint256 rewardUsd = rewardTo == address(0)
            ? 0
            : Math.min(Math.mulDiv(turnover, plan.fraction * REWARD_BPS, WAD * BPS), REWARD_CAP_USD);
        if (rewardUsd != 0) {
            _setGoals(plan, plan.nav - Math.mulDiv(rewardUsd, WAD, plan.fraction));
            plan.rewardRaw = Math.mulDiv(rewardUsd, USDC_UNIT, plan.prices[7]);
        }
        plan.heldBack = Math.mulDiv(plan.held[7], WAD - plan.fraction, WAD);
        for (uint256 i; i < 7; ++i) {
            uint256 held = plan.held[i];
            uint256 goal = plan.goal[i];
            // Rounded towards the current holding: a tranche never sells past its share of the surplus.
            plan.next[i] = goal >= held
                ? held + Math.mulDiv(goal - held, plan.fraction, WAD)
                : held - Math.mulDiv(held - goal, plan.fraction, WAD);
        }
    }

    /// @return turnover The larger of the whole move's sales and purchases, at oracle value.
    /// @return largest The oracle value of its largest single trade.
    function _measure(Plan memory plan) private pure returns (uint256 turnover, uint256 largest) {
        uint256 sales;
        uint256 purchases;
        for (uint256 i; i < 7; ++i) {
            uint256 held = plan.held[i];
            uint256 goal = plan.goal[i];
            uint256 value = Math.mulDiv(goal > held ? goal - held : held - goal, plan.prices[i], STOCK_UNIT);
            if (goal > held) purchases += value;
            else sales += value;
            largest = Math.max(largest, value);
        }
        turnover = Math.max(sales, purchases);
    }

    /// @dev Refuses to trade through a pool whose price a caller could have pushed against the vault before calling.
    function _checkPools(Plan memory plan) private view {
        uint256 minimum = Math.mulDiv(MIN_LEG_USDC, plan.prices[7], USDC_UNIT);
        for (uint256 i; i < 7; ++i) {
            uint256 held = plan.held[i];
            uint256 next = plan.next[i];
            if (Math.mulDiv(next > held ? next - held : held - next, plan.prices[i], STOCK_UNIT) < minimum) {
                continue;
            }
            _checkPool(i, next > held);
        }
    }

    /// @dev The pool's current tick against its time-weighted average. Observations are written before a block's
    ///      first swap, so moves made earlier in the caller's own transaction show in the tick, not in the average.
    function _checkPool(uint256 index, bool buying) private view {
        address stock = address(vault.assets(index));
        address usdc = address(vault.assets(7));
        address pool = vault.factory().getPool(stock, usdc, vault.tickSpacing(index));
        (bool ok, bytes memory data) = pool.staticcall(abi.encodeWithSignature("slot0()"));
        if (!ok || data.length < 64) revert PoolUnavailable(index);
        (, int256 tick) = abi.decode(data, (uint256, int256));
        uint32[] memory ago = new uint32[](2);
        ago[0] = POOL_TWAP_WINDOW;
        int56 elapsed;
        try ISlipstreamPoolOracle(pool).observe(ago) returns (int56[] memory cumulative, uint160[] memory) {
            elapsed = cumulative[1] - cumulative[0];
        } catch {
            revert PoolUnavailable(index);
        }
        int56 window = int56(uint56(POOL_TWAP_WINDOW));
        int256 average = elapsed / window;
        if (elapsed < 0 && elapsed % window != 0) --average;
        // With USDC as token0 the tick falls as the stock's USDC price rises.
        int256 dearer = usdc < stock ? average - tick : tick - average;
        if (buying ? dearer > MAX_POOL_MOVE_TICKS : -dearer > MAX_POOL_MOVE_TICKS) revert PoolMoved(index);
    }

    function _sell(Plan memory plan, uint256 deadline) private {
        Swap[] memory legs = new Swap[](7);
        uint256 count;
        for (uint256 i; i < 7; ++i) {
            if (plan.held[i] <= plan.next[i]) continue;
            uint256 amountIn = plan.held[i] - plan.next[i];
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
        if (count == 0) return;
        plan.legs += count;
        vault.rebalance(_trim(legs, count), deadline);
    }

    /// @dev Spends the tranche's cash on the stocks below their tranche goal, pro rata to their oracle-valued deficits.
    ///      The reward and the cash held back for later tranches stay. Allocations below MIN_LEG_USDC, and the rounding
    ///      remainder, stay as cash within the cash cap.
    function _buy(Plan memory plan, uint256 deadline) private {
        uint256 cash = vault.backing(7);
        uint256 keep = plan.heldBack + plan.rewardRaw;
        if (cash <= keep) return;
        cash -= keep;
        if (cash < MIN_LEG_USDC) return;
        uint256[7] memory need;
        uint256 totalNeed;
        for (uint256 i; i < 7; ++i) {
            uint256 held = vault.backing(i);
            if (held >= plan.next[i]) continue;
            need[i] = Math.mulDiv(plan.next[i] - held, plan.prices[i], STOCK_UNIT);
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
        plan.legs += count;
        plan.bought = Math.mulDiv(spent, plan.prices[7], USDC_UNIT);
        vault.rebalance(_trim(legs, count), deadline);
    }

    /// @dev Paid after the trades, only by a tranche that traded, from cash set aside for it; never from amounts owed to
    ///      earlier redeemers.
    function _payReward(Plan memory plan, address rewardTo) private {
        if (plan.rewardRaw == 0 || plan.legs == 0) return;
        uint256 amount = Math.min(plan.rewardRaw, vault.backing(7));
        if (amount == 0) return;
        plan.reward = Math.mulDiv(amount, plan.prices[7], USDC_UNIT, Math.Rounding.Ceil);
        vault.payReward(rewardTo, amount);
    }

    function _verify(Plan memory plan, uint256[8] memory held) private view returns (uint256 navAfter) {
        if (vault.totalSupply() != plan.supply) revert RebalanceLoss();
        (, navAfter) = valuation.values(held, plan.prices);
        uint256 allowance = Math.mulDiv(plan.sold + plan.bought, MAX_SLIPPAGE_BPS, BPS) + plan.slack
            + plan.reward + LOSS_ROUNDING;
        if (navAfter + allowance < plan.nav) revert RebalanceLoss();
        for (uint256 i; i < 7; ++i) {
            if (held[i] == 0) revert MissingComponent(i);
            // A shortfall only leaves more for the next tranche; moving away from the goal would be a planning error.
            uint256 goal = plan.goal[i];
            uint256 before = plan.held[i] > goal ? plan.held[i] - goal : goal - plan.held[i];
            uint256 afterwards = held[i] > goal ? held[i] - goal : goal - held[i];
            if (afterwards > before + Math.mulDiv(goal, COMPLIANCE_BPS, BPS)) revert NotCompliant();
        }
        // Cash held back for later tranches, and a reward left unpaid, may stay above the cap.
        uint256 kept = plan.heldBack + (plan.reward == 0 ? plan.rewardRaw : 0);
        if (!_cashWithinCap(held[7] > kept ? held[7] - kept : 0, navAfter, plan.prices[7])) {
            revert ResidualCash();
        }
    }

    /// @dev The quarter's reset is complete when every stock holds the same quantity per unit of equal-value share,
    ///      within the deadband, and cash is within its cap.
    function _complete(Plan memory plan, uint256[8] memory held, uint256 nav) private pure returns (bool) {
        return _compliant(held, plan.shares, plan.floored, DEADBAND_BPS)
            && _cashWithinCap(held[7], nav, plan.prices[7]);
    }

    /// @dev Price-free check: every stock holds the same quantity per unit of share, within `toleranceBps`. Stocks
    ///      flagged in `skip` were lifted to the precision floor and are excluded.
    function _compliant(uint256[8] memory held, uint256[7] memory shares, uint256 skip, uint256 toleranceBps)
        private
        pure
        returns (bool)
    {
        uint256 low = type(uint256).max;
        uint256 high;
        bool compared;
        for (uint256 i; i < 7; ++i) {
            if ((skip & (1 << i)) != 0) continue;
            compared = true;
            uint256 perShare = Math.mulDiv(held[i], WAD, shares[i]);
            if (perShare < low) low = perShare;
            if (perShare > high) high = perShare;
        }
        // Every stock at its floor leaves nothing to compare.
        return !compared || high * BPS <= low * (BPS + toleranceBps);
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
