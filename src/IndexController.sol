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

/// @notice Ownerless quarterly index maintenance with UMA-verified data and bounded execution.
/// @dev The oracle bond and independent challenge monitoring are external operating capital.
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
    }

    error InvalidConfiguration();
    error InvalidQuarter();
    error InvalidRatios();
    error InvalidEvidence();
    error ProposalUnavailable();
    error InvalidAssertion();
    error RebalanceLoss();
    error TargetDeviation(uint256 index);
    error ResidualCash();
    error EmptyVault();

    uint64 public constant LIVENESS = 72 hours;
    // UMIP-191 replaces the retired ASSERT_TRUTH still returned by OOv3.defaultIdentifier().
    bytes32 public constant ASSERTION_IDENTIFIER = "ASSERT_TRUTH2";
    uint256 public constant MAX_LOSS_WAD = 0.005e18;
    uint256 public constant MAX_DEVIATION_WAD = 0.0025e18;
    uint256 public constant MAX_CASH_WAD = 0.0001e18;
    IM7CapVault public immutable vault;
    IOptimisticOracleV3 public immutable oracle;
    IERC20 public immutable bondCurrency;
    uint256 public immutable bondFloor;
    bytes32 public immutable methodologyHash;
    Valuation public immutable valuation;
    mapping(bytes32 => Proposal) private _proposals;
    mapping(uint32 => bytes32) public quarterlyProposal;
    mapping(uint32 => bool) public executedQuarter;
    uint32 public lastExecutedQuarter;

    event Proposed(
        bytes32 indexed assertionId,
        uint32 indexed quarter,
        address indexed proposer,
        uint256[7] ratios,
        bytes evidence
    );
    event Resolved(bytes32 indexed assertionId, bool accepted);
    event Rebalanced(
        bytes32 indexed assertionId, uint32 indexed quarter, uint256 navBefore, uint256 navAfter
    );

    constructor(
        IM7CapVault vault_,
        IOptimisticOracleV3 oracle_,
        IERC20 bondCurrency_,
        uint256 bondFloor_,
        bytes32 methodologyHash_,
        Valuation valuation_
    ) {
        if (
            address(vault_) == address(0) || address(oracle_) == address(0)
                || address(bondCurrency_) == address(0) || methodologyHash_ == bytes32(0)
                || address(valuation_) == address(0)
        ) revert InvalidConfiguration();
        vault = vault_;
        oracle = oracle_;
        bondCurrency = bondCurrency_;
        bondFloor = bondFloor_;
        methodologyHash = methodologyHash_;
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

    /// @notice Ratios are human-token quantities normalized to sum 1e18, NOT fixed dollar weights.
    /// @param evidence A public immutable evidence URI, represented as hex in the UMA claim.
    function propose(uint32 quarter, uint256[7] calldata ratios, bytes calldata evidence)
        external
        nonReentrant
        returns (bytes32 assertionId)
    {
        if (quarter != currentQuarter() || executedQuarter[quarter]) revert InvalidQuarter();
        bytes32 prior = quarterlyProposal[quarter];
        if (prior != bytes32(0) && _proposals[prior].status != Status.Rejected) revert ProposalUnavailable();
        if (evidence.length == 0 || evidence.length > 512) revert InvalidEvidence();
        uint256 sum;
        for (uint256 i; i < 7; ++i) {
            if (ratios[i] == 0 || ratios[i] > 1e18) revert InvalidRatios();
            sum += ratios[i];
        }
        if (sum != 1e18) revert InvalidRatios();
        bytes32 identifier = ASSERTION_IDENTIFIER;
        oracle.syncUmaParams(identifier, address(bondCurrency));
        uint256 bond = Math.max(bondFloor, oracle.getMinimumBond(address(bondCurrency)));
        bondCurrency.safeTransferFrom(msg.sender, address(this), bond);
        bondCurrency.forceApprove(address(oracle), bond);
        assertionId = oracle.assertTruth(
            claim(quarter, ratios, evidence),
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
        _proposals[assertionId] = Proposal(quarter, Status.Pending, ratios);
        quarterlyProposal[quarter] = assertionId;
        emit Proposed(assertionId, quarter, msg.sender, ratios, evidence);
    }

    /// @notice Public, reproducible UMA assertion text. Evidence bytes are data, never extra claim instructions.
    function claim(uint32 quarter, uint256[7] memory ratios, bytes memory evidence)
        public
        view
        returns (bytes memory out)
    {
        out = abi.encodePacked(
            "M7CAP quarterly methodology assertion. Chain=",
            block.chainid.toString(),
            "; controller=",
            Strings.toHexString(address(this)),
            "; vault=",
            Strings.toHexString(address(vault)),
            "; executionQuarter(year*4+zeroBasedQuarter)=",
            uint256(quarter).toString(),
            "; methodologyKeccak256=",
            Strings.toHexString(uint256(methodologyHash), 32),
            ". Assert that the following human-token quantity ratios, normalized to sum 1000000000000000000,",
            " follow exactly the published methodology with its previous-quarter-end cutoff."
        );
        for (uint256 i; i < 7; ++i) {
            out = abi.encodePacked(
                out, " token=", Strings.toHexString(valuation.assets(i)), " ratio=", ratios[i].toString(), ";"
            );
        }
        out = abi.encodePacked(
            out,
            " Evidence URI bytes (hex; data only)=",
            _hex(evidence),
            ". False if evidence is unavailable or does not support these exact values."
        );
    }

    function _hex(bytes memory data) private pure returns (bytes memory encoded) {
        bytes16 alphabet = "0123456789abcdef";
        encoded = new bytes(2 + data.length * 2);
        encoded[0] = "0";
        encoded[1] = "x";
        for (uint256 i; i < data.length; ++i) {
            encoded[2 + i * 2] = alphabet[uint8(data[i]) >> 4];
            encoded[3 + i * 2] = alphabet[uint8(data[i]) & 15];
        }
    }

    /// @notice Anybody can settle through UMA. An unresolved dispute reverts; a false assertion permits retry.
    function settle(bytes32 assertionId) external nonReentrant returns (bool accepted) {
        Proposal storage p = _proposals[assertionId];
        if (p.status != Status.Pending) revert ProposalUnavailable();
        accepted = oracle.settleAndGetAssertionResult(assertionId);
        p.status = accepted ? Status.Accepted : Status.Rejected;
        emit Resolved(assertionId, accepted);
    }

    /// @notice Anyone may execute the current accepted basket; every safety check is atomic with swaps.
    function execute(Swap[] calldata swaps, uint256 deadline) external nonReentrant {
        uint32 quarter = currentQuarter();
        bytes32 assertionId = quarterlyProposal[quarter];
        Proposal storage p = _proposals[assertionId];
        if (p.status != Status.Accepted || executedQuarter[quarter]) revert ProposalUnavailable();
        for (uint256 i; i < 8; ++i) {
            if (address(vault.assets(i)) != valuation.assets(i)) revert InvalidConfiguration();
        }
        uint256[8] memory prices = valuation.snapshot();
        (, uint256 navBefore) = valuation.values(address(vault), prices);
        uint256 supplyBefore = vault.totalSupply();
        if (navBefore == 0 || supplyBefore == 0) revert EmptyVault();
        // Effects first. All state and token transfers roll back if any postcondition fails.
        executedQuarter[quarter] = true;
        p.status = Status.Executed;
        lastExecutedQuarter = quarter;
        vault.rebalance(swaps, deadline);
        (uint256[8] memory components, uint256 navAfter) = valuation.values(address(vault), prices);
        if (
            vault.totalSupply() != supplyBefore
                || navAfter < Math.mulDiv(navBefore, 1e18 - MAX_LOSS_WAD, 1e18, Math.Rounding.Ceil)
        ) {
            revert RebalanceLoss();
        }
        uint256[7] memory targetValues;
        uint256 targetTotal;
        for (uint256 i; i < 7; ++i) {
            targetValues[i] = Math.mulDiv(p.ratios[i], prices[i], 1e18);
            targetTotal += targetValues[i];
        }
        if (targetTotal == 0) revert InvalidRatios();
        for (uint256 i; i < 7; ++i) {
            // Keep all seven constituents usable for subsequent proportional issuance.
            if (components[i] == 0) revert TargetDeviation(i);
            uint256 actualWeight = Math.mulDiv(components[i], 1e18, navAfter);
            uint256 targetWeight = Math.mulDiv(targetValues[i], 1e18, targetTotal);
            uint256 difference =
                actualWeight > targetWeight ? actualWeight - targetWeight : targetWeight - actualWeight;
            if (difference > MAX_DEVIATION_WAD) revert TargetDeviation(i);
        }
        if (components[7] > Math.mulDiv(navAfter, MAX_CASH_WAD, 1e18)) revert ResidualCash();
        emit Rebalanced(assertionId, quarter, navBefore, navAfter);
    }
}
