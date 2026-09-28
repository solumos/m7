// SPDX-License-Identifier: Unlicense
pragma solidity 0.8.30;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

interface IAggregatorV3 {
    function decimals() external view returns (uint8);
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80);
}

/// @dev ABI verified against Coinbase's deployed OracleRegistry published source.
interface ICoinbaseOracleRegistry {
    function getOracleParams(address token) external view returns (uint256 multiplier, bool paused);
}

/// @notice Immutable, fail-closed USD valuations for rebalance safety checks only.
/// @dev Stock feeds already incorporate the B20 multiplier. Never apply it again.
contract Valuation {
    error InvalidConfiguration();
    error SequencerUnavailable();
    error OutsideExecutionWindow();
    error UnavailablePrice(uint256 index);
    error CorporateAction(uint256 index);
    error NoFreshMarketSignal();

    uint256 public constant SEQUENCER_GRACE_PERIOD = 1 hours;
    // Base USDC/USD publishes on 0.3% deviation or a 24h heartbeat.
    uint256 public constant USDC_MAX_AGE = 25 hours;
    // Stock feeds publish on a 0.5% deviation or a 24h heartbeat during market hours only.
    uint256 public constant MAX_STOCK_AGE_LIMIT = 25 hours;
    // At least one stock feed this fresh is evidence the US market is open (holidays fail closed).
    uint256 public constant FRESH_SIGNAL_AGE = 1 hours;
    // Weekdays 15:00-20:00 UTC fall inside regular US trading in both daylight-saving regimes.
    uint256 public constant WINDOW_START = 15 hours;
    uint256 public constant WINDOW_END = 20 hours;
    address[8] public assets;
    IAggregatorV3[8] public feeds;
    uint256[8] public tokenUnits;
    uint256[8] public feedUnits;
    IAggregatorV3 public immutable sequencer;
    ICoinbaseOracleRegistry public immutable registry;
    uint256 public immutable maxAge;

    constructor(
        address[8] memory assets_,
        IAggregatorV3[8] memory feeds_,
        IAggregatorV3 sequencer_,
        ICoinbaseOracleRegistry registry_,
        uint256 maxAge_
    ) {
        if (
            address(sequencer_) == address(0) || address(registry_) == address(0)
                || maxAge_ < FRESH_SIGNAL_AGE || maxAge_ > MAX_STOCK_AGE_LIMIT
        ) {
            revert InvalidConfiguration();
        }
        assets = assets_;
        feeds = feeds_;
        sequencer = sequencer_;
        registry = registry_;
        maxAge = maxAge_;
        for (uint256 i; i < 8; ++i) {
            if (assets_[i] == address(0) || address(feeds_[i]) == address(0)) revert InvalidConfiguration();
            for (uint256 j; j < i; ++j) {
                if (assets_[j] == assets_[i]) revert InvalidConfiguration();
            }
            uint8 tokenDecimals = IERC20Metadata(assets_[i]).decimals();
            uint8 feedDecimals = feeds_[i].decimals();
            if (tokenDecimals > 18 || feedDecimals > 18) revert InvalidConfiguration();
            tokenUnits[i] = 10 ** tokenDecimals;
            feedUnits[i] = 10 ** feedDecimals;
        }
    }

    /// @notice Valid USD prices, 18 decimals per whole token, from one transaction snapshot.
    /// @dev Every stock price must be at most `maxAge` old (heartbeat liveness) and at least one must be at most
    ///      `FRESH_SIGNAL_AGE` old (the market is trading). A quiet feed inside its 0.5% deviation band is still
    ///      accurate, so it no longer blocks execution. Holidays fail closed unless a heartbeat lands on them.
    function snapshot() external view returns (uint256[8] memory prices) {
        uint256 dayOfWeek = (block.timestamp / 1 days + 4) % 7;
        uint256 timeOfDay = block.timestamp % 1 days;
        if (dayOfWeek == 0 || dayOfWeek == 6 || timeOfDay < WINDOW_START || timeOfDay >= WINDOW_END) {
            revert OutsideExecutionWindow();
        }
        (, int256 status, uint256 startedAt,,) = sequencer.latestRoundData();
        if (
            status != 0 || startedAt == 0 || startedAt > block.timestamp
                || block.timestamp - startedAt <= SEQUENCER_GRACE_PERIOD
        ) revert SequencerUnavailable();

        bool marketSignal;
        for (uint256 i; i < 8; ++i) {
            if (i < 7) {
                (uint256 multiplier, bool paused) = registry.getOracleParams(assets[i]);
                if (paused || multiplier == 0) revert CorporateAction(i);
            }
            (uint80 round, int256 answer,, uint256 updatedAt, uint80 answeredInRound) =
                feeds[i].latestRoundData();
            if (
                answer <= 0 || round == 0 || answeredInRound < round || updatedAt == 0
                    || updatedAt > block.timestamp
                    || block.timestamp - updatedAt > (i == 7 ? USDC_MAX_AGE : maxAge)
            ) revert UnavailablePrice(i);
            if (i < 7 && block.timestamp - updatedAt <= FRESH_SIGNAL_AGE) marketSignal = true;
            prices[i] = Math.mulDiv(uint256(answer), 1e18, feedUnits[i]);
            // An out-of-range configured feed fails closed rather than overflowing later arithmetic.
            if (prices[i] == 0 || prices[i] > 1e36) revert UnavailablePrice(i);
        }
        if (!marketSignal) revert NoFreshMarketSignal();
    }

    /// @notice Convert raw token amounts into 18-decimal USD values using supplied snapshot prices.
    /// @dev Takes explicit amounts so callers can exclude balances the vault owes to earlier redeemers.
    function values(uint256[8] memory amounts, uint256[8] memory prices)
        external
        view
        returns (uint256[8] memory components, uint256 total)
    {
        for (uint256 i; i < 8; ++i) {
            components[i] = Math.mulDiv(amounts[i], prices[i], tokenUnits[i]);
            total += components[i];
        }
    }
}
