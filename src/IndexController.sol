// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {IM7CapVault} from "./interfaces/IM7CapVault.sol";
import {IOptimisticOracleV3} from "./interfaces/IOptimisticOracleV3.sol";
import {Valuation} from "./Valuation.sol";
import {Swap} from "./Types.sol";

/// @notice Ownerless quarterly index maintenance with UMA-verified data and on-chain trade planning.
/// @dev Anyone may propose, settle or execute. Executors choose no trades: `execute` derives every leg from the
///      vault's backing, the accepted quantity ratios and one oracle snapshot. Each constituent's quantity share moves
///      at most `MAX_STEP_WAD` (relative) per quarter, each leg's minimum output is its oracle value less
///      `MAX_SLIPPAGE_BPS`, and total loss is bounded by the traded value. The oracle bond and independent challenge
///      monitoring are external operating capital.
contract IndexController is ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Strings for uint256;

    enum Status {
        None,
        Pending,
        Accepted,
        Rejected,
        Executed
    }

    struct Proposal {
        uint32 quarter;
        Status status;
        uint256[7] ratios;
        bytes32 observationDigest;
    }

    /// @dev Working memory for one execution. Prices are 1e18 USD per whole token; stocks use 1e8 raw units and USDC
    ///      1e6. `target` holds 1e18-scaled quantity shares after the bounded step; `goal` holds raw stock quantities.
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
    }

    error InvalidConfiguration();
    error InvalidQuarter();
    error InvalidRatios();
    error InvalidURI();
    error InvalidDigest();
    error ProposalUnavailable();
    error InvalidAssertion();
    error RebalanceLoss();
    error ResidualCash();
    error EmptyVault();
    error MissingComponent(uint256 index);
    error NotCompliant();
    error ExcessTurnover();
    error Expired();

    uint64 public constant LIVENESS = 72 hours;
    // UMIP-191 replaces the retired ASSERT_TRUTH still returned by OOv3.defaultIdentifier().
    bytes32 public constant ASSERTION_IDENTIFIER = "ASSERT_TRUTH2";
    /// @notice An undisputed proposal this long past its challenge expiry that still has not settled (for example a
    ///         bond payout USDC refuses) no longer blocks a replacement.
    uint256 public constant SETTLEMENT_GRACE = 1 days;
    uint256 public constant WAD = 1e18;
    uint256 public constant BPS = 10_000;
    uint256 public constant STOCK_UNIT = 1e8;
    uint256 public constant USDC_UNIT = 1e6;
    /// @notice Each constituent's quantity share may move per quarter by the larger of MAX_STEP_WAD (relative to
    ///         its current share) and MIN_STEP_WAD (absolute), so a tiny or seized holding can still be rebuilt.
    uint256 public constant MAX_STEP_WAD = 0.05e18;
    uint256 public constant MIN_STEP_WAD = 0.0025e18;
    uint256 public constant MAX_SLIPPAGE_BPS = 100;
    /// @notice Below this spread against the stepped target (and with little cash), execution trades nothing.
    uint256 public constant DEADBAND_BPS = 10;
    uint256 public constant COMPLIANCE_BPS = 30;
    uint256 public constant MAX_TURNOVER_BPS = 1_000;
    uint256 public constant MAX_CASH_BPS = 1;
    uint256 public constant MIN_LEG_USDC = 1e5;
    uint256 public constant MAX_URI_LENGTH = 256;
    // Covers floor rounding in the eight component values; per-leg output rounding is tracked in `Plan.slack`.
    uint256 private constant LOSS_ROUNDING = 8;

    IM7CapVault public immutable vault;
    IOptimisticOracleV3 public immutable oracle;
    IERC20 public immutable bondCurrency;
    uint256 public immutable bondFloor;
    bytes32 public immutable methodologyHash;
    Valuation public immutable valuation;
    string public methodologyURI;
    mapping(bytes32 => Proposal) private _proposals;
    mapping(bytes32 => string) public evidenceURIOf;
    mapping(uint32 => bytes32) public latestProposal;
    mapping(uint32 => bytes32) public acceptedProposal;
    mapping(uint32 => bool) public executedQuarter;
    uint32 public lastExecutedQuarter;

    event Proposed(
        bytes32 indexed assertionId,
        uint32 indexed quarter,
        address indexed proposer,
        uint256[7] ratios,
        string evidenceURI,
        bytes32 observationDigest
    );
    event Resolved(bytes32 indexed assertionId, bool accepted);
    event Selected(bytes32 indexed assertionId, uint32 indexed quarter);
    event Rebalanced(
        bytes32 indexed assertionId,
        uint32 indexed quarter,
        uint256 navBefore,
        uint256 navAfter,
        uint256 stepWad,
        uint256 soldValue,
        uint256 boughtValue
    );

    constructor(
        IM7CapVault vault_,
        IOptimisticOracleV3 oracle_,
        IERC20 bondCurrency_,
        uint256 bondFloor_,
        bytes32 methodologyHash_,
        string memory methodologyURI_,
        Valuation valuation_
    ) {
        if (
            address(vault_) == address(0) || address(oracle_) == address(0)
                || address(bondCurrency_) == address(0) || methodologyHash_ == bytes32(0)
                || address(valuation_) == address(0)
        ) revert InvalidConfiguration();
        _validateURI(bytes(methodologyURI_));
        vault = vault_;
        oracle = oracle_;
        bondCurrency = bondCurrency_;
        bondFloor = bondFloor_;
        methodologyHash = methodologyHash_;
        methodologyURI = methodologyURI_;
        valuation = valuation_;
    }

    /// @notice Quarter of execution: year * 4 + zero-based quarter. Data cutoff is prior quarter-end.
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

    function proposal(bytes32 assertionId) external view returns (Proposal memory) {
        return _proposals[assertionId];
    }

    /// @notice Whether a new proposal may be made for `quarter` now. A pending proposal blocks others only while
    ///         its UMA assertion is undisputed and within its settlement grace; a disputed proposal never does.
    function canPropose(uint32 quarter) public view returns (bool) {
        if (acceptedProposal[quarter] != bytes32(0) || executedQuarter[quarter]) return false;
        bytes32 latest = latestProposal[quarter];
        if (latest == bytes32(0)) return true;
        Status status = _proposals[latest].status;
        if (status == Status.Rejected) return true;
        if (status != Status.Pending) return false;
        IOptimisticOracleV3.Assertion memory assertion = oracle.getAssertion(latest);
        return assertion.disputer != address(0)
            || block.timestamp > uint256(assertion.expirationTime) + SETTLEMENT_GRACE;
    }

    /// @notice Ratios are human-token quantities normalized to sum 1e18, NOT fixed dollar weights.
    /// @param evidenceURI Content-addressed (ipfs:// or ar://) location of the observation file and compiler output.
    /// @param observationDigest SHA-256 of the canonical observation file bytes (`index_snapshot.py`).
    function propose(
        uint32 quarter,
        uint256[7] calldata ratios,
        string calldata evidenceURI,
        bytes32 observationDigest
    ) external nonReentrant returns (bytes32 assertionId) {
        if (quarter != currentQuarter() || executedQuarter[quarter]) {
            revert InvalidQuarter();
        }
        if (!canPropose(quarter)) revert ProposalUnavailable();
        _validateURI(bytes(evidenceURI));
        if (observationDigest == bytes32(0)) revert InvalidDigest();
        uint256 sum;
        for (uint256 i; i < 7; ++i) {
            if (ratios[i] == 0) revert InvalidRatios();
            sum += ratios[i];
        }
        if (sum != WAD) revert InvalidRatios();
        bytes32 identifier = ASSERTION_IDENTIFIER;
        oracle.syncUmaParams(identifier, address(bondCurrency));
        uint256 bond = Math.max(bondFloor, oracle.getMinimumBond(address(bondCurrency)));
        bondCurrency.safeTransferFrom(msg.sender, address(this), bond);
        bondCurrency.forceApprove(address(oracle), bond);
        assertionId = oracle.assertTruth(
            claim(quarter, ratios, evidenceURI, observationDigest),
            msg.sender,
            address(0),
            address(0),
            LIVENESS,
            bondCurrency,
            bond,
            identifier,
            bytes32(0)
        );
        bondCurrency.forceApprove(address(oracle), 0);
        if (assertionId == bytes32(0) || _proposals[assertionId].status != Status.None) {
            revert InvalidAssertion();
        }
        _proposals[assertionId] = Proposal(quarter, Status.Pending, ratios, observationDigest);
        evidenceURIOf[assertionId] = evidenceURI;
        latestProposal[quarter] = assertionId;
        emit Proposed(assertionId, quarter, msg.sender, ratios, evidenceURI, observationDigest);
    }

    /// @notice Public, reproducible UMA assertion text. URIs are restricted to a safe character set, so they are
    ///         data, never extra claim instructions.
    function claim(
        uint32 quarter,
        uint256[7] memory ratios,
        string memory evidenceURI,
        bytes32 observationDigest
    ) public view returns (bytes memory out) {
        out = abi.encodePacked(
            "M7CAP quarterly methodology assertion. Chain=",
            block.chainid.toString(),
            "; controller=",
            Strings.toHexString(address(this)),
            "; vault=",
            Strings.toHexString(address(vault)),
            "; executionQuarter(year*4+zeroBasedQuarter)=",
            uint256(quarter).toString(),
            "; observationCutoff=",
            _cutoff(quarter)
        );
        out = abi.encodePacked(
            out,
            "; methodologyURI=",
            methodologyURI,
            "; methodologyKeccak256=",
            Strings.toHexString(uint256(methodologyHash), 32),
            "; evidenceURI=",
            evidenceURI,
            "; observationSha256=",
            Strings.toHexString(uint256(observationDigest), 32)
        );
        out = abi.encodePacked(
            out,
            ". Assert that the following human-token quantity ratios, normalized to sum 1000000000000000000, are",
            " exactly the values the methodology at methodologyURI (whose bytes hash to methodologyKeccak256) produces",
            " from the observation file at evidenceURI (whose canonical bytes hash to observationSha256), and that those",
            " observations follow the methodology with its previous-quarter-end cutoff."
        );
        for (uint256 i; i < 7; ++i) {
            out = abi.encodePacked(
                out,
                " ",
                _symbol(i),
                " token=",
                Strings.toHexString(valuation.assets(i)),
                " ratio=",
                ratios[i].toString(),
                ";"
            );
        }
        out = abi.encodePacked(
            out,
            " Symbols are labels; token addresses are authoritative. False if either document is unavailable at its",
            " URI, does not match its hash, or does not support these exact values."
        );
    }

    /// @notice Anybody can settle through UMA. An unresolved dispute reverts; a false assertion permits a retry.
    ///         The first proposal of a quarter that settles true becomes that quarter's executable proposal.
    function settle(bytes32 assertionId) external nonReentrant returns (bool accepted) {
        Proposal storage p = _proposals[assertionId];
        if (p.status != Status.Pending) revert ProposalUnavailable();
        accepted = oracle.settleAndGetAssertionResult(assertionId);
        p.status = accepted ? Status.Accepted : Status.Rejected;
        emit Resolved(assertionId, accepted);
        uint32 quarter = p.quarter;
        if (accepted && acceptedProposal[quarter] == bytes32(0) && !executedQuarter[quarter]) {
            acceptedProposal[quarter] = assertionId;
            emit Selected(assertionId, quarter);
        }
    }

    /// @notice Anyone may execute the current quarter's selected basket. The controller plans every trade; all
    ///         safety checks are atomic with the swaps.
    function execute(uint256 deadline) external nonReentrant {
        if (block.timestamp > deadline) revert Expired();
        uint32 quarter = currentQuarter();
        bytes32 assertionId = acceptedProposal[quarter];
        Proposal storage p = _proposals[assertionId];
        if (assertionId == bytes32(0) || p.status != Status.Accepted || executedQuarter[quarter]) {
            revert ProposalUnavailable();
        }
        for (uint256 i; i < 8; ++i) {
            if (address(vault.assets(i)) != valuation.assets(i)) revert InvalidConfiguration();
        }
        Plan memory plan;
        plan.prices = valuation.snapshot();
        plan.supply = vault.totalSupply();
        _readBacking(plan.held);
        (, plan.nav) = valuation.values(plan.held, plan.prices);
        if (plan.nav == 0 || plan.supply == 0) revert EmptyVault();
        _stepTowards(plan, p.ratios);
        _setGoals(plan);
        // Effects first. All state and token transfers roll back if any postcondition fails.
        executedQuarter[quarter] = true;
        p.status = Status.Executed;
        lastExecutedQuarter = quarter;
        uint256 navAfter = plan.nav;
        if (
            !_compliant(plan.held, plan.target, plan.floored, DEADBAND_BPS)
                || !_cashWithinCap(plan.held[7], plan.nav, plan.prices[7])
        ) {
            _sell(plan, deadline);
            _buy(plan, deadline);
            navAfter = _verify(plan);
        }
        emit Rebalanced(assertionId, quarter, plan.nav, navAfter, plan.step, plan.sold, plan.bought);
    }

    function _readBacking(uint256[8] memory held) private view {
        for (uint256 i; i < 8; ++i) {
            held[i] = vault.backing(i);
        }
    }

    /// @dev Moves the current quantity shares s toward the accepted shares c: t = s + a(c - s), with the largest
    ///      a <= 1 such that no share moves by more than max(MAX_STEP_WAD * s, MIN_STEP_WAD). t sums to one (up to
    ///      rounding) without renormalization, and every t is positive because c is.
    function _stepTowards(Plan memory plan, uint256[7] memory ratios) private pure {
        uint256 total;
        for (uint256 i; i < 7; ++i) {
            total += plan.held[i];
        }
        if (total == 0) revert EmptyVault();
        uint256[7] memory share;
        uint256 step = WAD;
        for (uint256 i; i < 7; ++i) {
            share[i] = Math.mulDiv(plan.held[i], WAD, total);
            uint256 gap = ratios[i] > share[i] ? ratios[i] - share[i] : share[i] - ratios[i];
            if (gap == 0) continue;
            uint256 limit = Math.max(Math.mulDiv(MAX_STEP_WAD, share[i], WAD), MIN_STEP_WAD);
            step = Math.min(step, Math.mulDiv(limit, WAD, gap));
        }
        plan.step = step;
        for (uint256 i; i < 7; ++i) {
            plan.target[i] = Math.mulDiv(share[i], WAD - step, WAD) + Math.mulDiv(ratios[i], step, WAD);
            if (plan.target[i] == 0) revert MissingComponent(i);
        }
    }

    /// @dev Raw quantities that invest the whole NAV at the stepped shares, never below the vault's precision floor.
    ///      Rounded up so no stock is sold past its exact surplus. A stock lifted to the floor (for example after a
    ///      partial seizure) is restored to it and excluded from the proportional compliance check.
    function _setGoals(Plan memory plan) private view {
        uint256 denominator;
        for (uint256 i; i < 7; ++i) {
            denominator += plan.target[i] * plan.prices[i];
        }
        uint256 floorUnits = Math.mulDiv(
            vault.MIN_LOCKED_STOCK_UNITS(), plan.supply, vault.LOCKED_SHARES(), Math.Rounding.Ceil
        );
        for (uint256 i; i < 7; ++i) {
            uint256 goal = Math.mulDiv(plan.nav, STOCK_UNIT * plan.target[i], denominator, Math.Rounding.Ceil);
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

    /// @dev Spends all USDC backing on the stocks below goal, pro rata to their oracle-valued deficits. Allocations
    ///      below MIN_LEG_USDC, and the rounding remainder, go to the largest deficit.
    function _buy(Plan memory plan, uint256 deadline) private {
        uint256 cash = vault.backing(7);
        if (cash < MIN_LEG_USDC) return;
        uint256[7] memory need;
        uint256 totalNeed;
        uint256 largest = 7;
        for (uint256 i; i < 7; ++i) {
            uint256 held = vault.backing(i);
            if (held >= plan.goal[i]) continue;
            need[i] = Math.mulDiv(plan.goal[i] - held, plan.prices[i], STOCK_UNIT);
            if (need[i] == 0) continue;
            totalNeed += need[i];
            if (largest == 7 || need[i] > need[largest]) largest = i;
        }
        if (totalNeed == 0) return;
        uint256[7] memory spend;
        uint256 allocated;
        for (uint256 i; i < 7; ++i) {
            if (need[i] == 0 || i == largest) continue;
            uint256 amount = Math.mulDiv(cash, need[i], totalNeed);
            if (amount < MIN_LEG_USDC) continue;
            spend[i] = amount;
            allocated += amount;
        }
        spend[largest] = cash - allocated;
        Swap[] memory legs = new Swap[](7);
        uint256 count;
        for (uint256 i; i < 7; ++i) {
            if (spend[i] == 0) continue;
            uint256 fair = Math.mulDiv(spend[i], plan.prices[7] * STOCK_UNIT, plan.prices[i] * USDC_UNIT);
            plan.slack += Math.mulDiv(1, plan.prices[i], STOCK_UNIT, Math.Rounding.Ceil);
            legs[count++] = Swap({
                tokenIn: 7,
                tokenOut: uint8(i),
                amountIn: spend[i],
                minAmountOut: Math.mulDiv(fair, BPS - MAX_SLIPPAGE_BPS, BPS, Math.Rounding.Ceil)
            });
        }
        plan.bought = Math.mulDiv(cash, plan.prices[7], USDC_UNIT);
        vault.rebalance(_trim(legs, count), deadline);
    }

    function _verify(Plan memory plan) private view returns (uint256 navAfter) {
        if (vault.totalSupply() != plan.supply) revert RebalanceLoss();
        uint256[8] memory held;
        _readBacking(held);
        (, navAfter) = valuation.values(held, plan.prices);
        uint256 allowance =
            Math.mulDiv(plan.sold + plan.bought, MAX_SLIPPAGE_BPS, BPS) + plan.slack + LOSS_ROUNDING;
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

    function _cashWithinCap(uint256 cash, uint256 nav, uint256 usdcPrice) private pure returns (bool) {
        uint256 cap =
            Math.max(Math.mulDiv(nav, MAX_CASH_BPS, BPS), Math.mulDiv(MIN_LEG_USDC, usdcPrice, USDC_UNIT));
        return Math.mulDiv(cash, usdcPrice, USDC_UNIT) <= cap;
    }

    function _trim(Swap[] memory legs, uint256 count) private pure returns (Swap[] memory) {
        assembly ("memory-safe") {
            mstore(legs, count)
        }
        return legs;
    }

    function _cutoff(uint32 quarter) private pure returns (string memory) {
        uint256 year = quarter / 4;
        uint256 index = quarter % 4;
        if (index == 0) return string.concat((year - 1).toString(), "-12-31T23:59:59Z");
        if (index == 1) return string.concat(year.toString(), "-03-31T23:59:59Z");
        if (index == 2) return string.concat(year.toString(), "-06-30T23:59:59Z");
        return string.concat(year.toString(), "-09-30T23:59:59Z");
    }

    function _symbol(uint256 index) private pure returns (string memory) {
        if (index == 0) return "AAPLc";
        if (index == 1) return "AMZNc";
        if (index == 2) return "GOOGLc";
        if (index == 3) return "METAc";
        if (index == 4) return "MSFTc";
        if (index == 5) return "NVDAc";
        return "TSLAc";
    }

    /// @dev Content-addressed URIs only: ipfs:// or ar://, then at least one of [A-Za-z0-9-._~:/].
    function _validateURI(bytes memory uri) private pure {
        uint256 length = uri.length;
        uint256 start;
        if (_hasPrefix(uri, "ipfs://")) start = 7;
        else if (_hasPrefix(uri, "ar://")) start = 5;
        else revert InvalidURI();
        if (length == start || length > MAX_URI_LENGTH) revert InvalidURI();
        for (uint256 i = start; i < length; ++i) {
            bytes1 c = uri[i];
            if (!((c >= "a" && c <= "z") || (c >= "A" && c <= "Z") || (c >= "0" && c <= "9") || c == "-"
                        || c == "." || c == "_" || c == "~" || c == ":" || c == "/")) revert InvalidURI();
        }
    }

    function _hasPrefix(bytes memory data, bytes memory prefix) private pure returns (bool) {
        if (data.length < prefix.length) return false;
        for (uint256 i; i < prefix.length; ++i) {
            if (data[i] != prefix[i]) return false;
        }
        return true;
    }
}
