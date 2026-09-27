// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IndexController} from "./IndexController.sol";
import {Valuation} from "./Valuation.sol";
import {IM7CapVault} from "./interfaces/IM7CapVault.sol";

/// @notice Read-only value of M7CAP from the latest oracle prices, for dashboards and monitoring. It has no owner and
///         no effect on the other contracts, so it can be deployed or replaced at any time.
/// @dev Unlike Valuation.snapshot, which gates rebalances, it applies no trading-window or staleness rule; it reports
///      the update time of its stalest price instead. Stock feeds stand still outside market hours, so do not use it
///      as a lending or liquidation price without your own staleness check.
contract M7CapLens {
    struct Value {
        /// USD value of one whole M7CAP, 18 decimals.
        uint256 perShare;
        /// USD value of the vault's backing, 18 decimals. Amounts owed to earlier redeemers are excluded.
        uint256 nav;
        /// M7CAP supply, 18 decimals, including the permanently locked seed shares.
        uint256 supply;
        /// USD value of each asset's backing in canonical order, USDC last.
        uint256[8] components;
        /// Update time of the stalest price used.
        uint256 oldestPriceAt;
        /// An issuer has paused a stock's reference price, for example during a corporate action.
        bool issuerPaused;
        /// Base's sequencer uptime feed reports an outage.
        bool sequencerDown;
    }

    IM7CapVault public immutable vault;
    Valuation public immutable valuation;

    error InvalidConfiguration();
    error InvalidPrice(uint256 assetIndex);

    constructor(IndexController controller) {
        vault = controller.vault();
        valuation = controller.valuation();
        for (uint256 i; i < 8; ++i) {
            if (address(vault.assets(i)) != valuation.assets(i)) revert InvalidConfiguration();
        }
    }

    /// @notice USD value of one whole M7CAP (18 decimals) and the update time of the stalest price behind it.
    function pricePerShare() external view returns (uint256 perShare, uint256 oldestPriceAt) {
        Value memory v = value();
        return (v.perShare, v.oldestPriceAt);
    }

    /// @notice USD value of everything backing M7CAP (18 decimals) and the update time of the stalest price behind it.
    /// @dev Excludes assets owed to earlier redeemers as deferred claims, which belong to them, not to holders.
    function totalValue() external view returns (uint256 nav, uint256 oldestPriceAt) {
        Value memory v = value();
        return (v.nav, v.oldestPriceAt);
    }

    function value() public view returns (Value memory v) {
        uint256[8] memory held;
        uint256[8] memory prices;
        v.oldestPriceAt = type(uint256).max;
        for (uint256 i; i < 8; ++i) {
            held[i] = vault.backing(i);
            (, int256 answer,, uint256 updatedAt,) = valuation.feeds(i).latestRoundData();
            if (answer <= 0 || updatedAt == 0) revert InvalidPrice(i);
            prices[i] = Math.mulDiv(uint256(answer), 1e18, valuation.feedUnits(i));
            if (updatedAt < v.oldestPriceAt) v.oldestPriceAt = updatedAt;
            if (i < 7) {
                (uint256 multiplier, bool paused) = valuation.registry().getOracleParams(valuation.assets(i));
                if (paused || multiplier == 0) v.issuerPaused = true;
            }
        }
        (v.components, v.nav) = valuation.values(held, prices);
        v.supply = vault.totalSupply();
        if (v.supply != 0) v.perShare = Math.mulDiv(v.nav, 1e18, v.supply);
        (, int256 status,,,) = valuation.sequencer().latestRoundData();
        v.sequencerDown = status != 0;
    }
}
