# M7 methodology

M7 is a pooled, transferable helper for holding seven stocks in equal value. A share owns a proportion of a basket of Coinbase stock tokens on Base. In-kind redemption delivers the constituent tokens; it does not create individual brokerage accounts, company shareholder registrations, or separate tax lots for each underlying share.

These rules are enforced by immutable contracts with no owner. Nobody can change them, the constituents or the parameters after deployment; a change means a new deployment that holders move to voluntarily.

## Universe

Canonical order is **AAPLc, AMZNc, GOOGLc, METAc, MSFTc, NVDAc, TSLAc**, identified by the seven Base token addresses in `config/base.json`, not by mutable symbols. There is no leverage, shorting or discretionary substitution. Incidental USDC (from donations, or rounding) is part of the backing and is invested at the next reset.

## Weighting

Each quarterly reset returns the basket to **equal value**: one seventh of the vault's value in each stock at that moment's oracle prices. Between resets the token quantities stay fixed, so weights drift with prices: a stock that outperforms grows its weight until the next reset.

Prices are Coinbase's total-return reference prices published through Chainlink on Base, which already include each token's dividend multiplier. USDC is valued at its own Chainlink feed.

## The quarterly reset

- **Who and when.** Anyone may trigger the reset once per calendar quarter (January–March, April–June, July–September, October–December). It runs only on a weekday between 15:00 and 20:00 UTC, while the issuer's reference prices are not paused, Base's sequencer has been up for over an hour, every stock price is at most 25 hours old, at least one stock price is at most 1 hour old, and the USDC price is at most 25 hours old. A reset that cannot meet these conditions changes nothing and can be retried later in the quarter.
- **Targets.** Equal value at one price snapshot. A single reset may at most double any stock's quantity share (or raise it by 0.25 points, if that is more); after an extreme quarter the basket moves partway and finishes at the next reset.
- **Trades.** The contracts choose every trade. Each stock trades only through its one pinned Aerodrome Slipstream pool against USDC, is only sold or only bought, and sales come first. Each trade must return at least its oracle value less 1%, the reset's total loss may not exceed 1% of the value traded plus the reward, and a reset selling more than half of the vault's value is refused. Trades under $0.01 are skipped.
- **Result.** The basket must end within 0.3% of equal quantities per unit of target, and hold at most the larger of 1 bp of its value and $0.07 in cash. Within 0.1% of target, nothing trades.
- **Reward.** A reset that trades pays whoever triggered it (to an address they choose) 0.5 bp of the vault's value, at most $25, in USDC. Every stock funds its share: the targets invest the vault's value less the reward.

## Minting and redeeming

Shares are minted and redeemed in proportion to the current basket, so they never change its composition. In-kind minting and redemption charge nothing. The USDC gateway buys or sells the exact constituent quantities through the same pinned pools; the person minting or redeeming pays those pools' prices and fees, and nobody else does. There is no fee and no owner.

The initial seed permanently locks 10 of the first 1,000 shares. Each stock must keep at least 10,000 raw units attributable to those locked shares; an issuer seizure below that level pauses new minting until a reset rebuilds the stock. A redemption leg that cannot be delivered (for example a frozen token) can be deferred as a claim the redeemer withdraws later.

## What it depends on

The reset trusts the Coinbase reference prices and the Aerodrome pools only within the bounds above: a wrong price makes trades revert rather than execute at that price. The issuer can pause, freeze or seize its stock tokens, including those the vault holds, and applies its transfer policies to M7 holders too. Base, Chainlink and Aerodrome are external dependencies. A replaced stock token, retired feed or unsupported corporate event may require a new deployment and voluntary migration.
