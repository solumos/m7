# M7CAP v1 methodology

M7CAP is a pooled, transferable helper for implementing a seven-company indexing allocation. A share owns a proportion of a basket of Coinbase stock tokens. In-kind redemption delivers the constituent tokens; it does not create individual brokerage accounts, company shareholder registrations, or separate tax lots for each underlying share.

This file defines the immutable methodology committed by the controller's deployment `methodologyHash`. The deployment script computes Ethereum Keccak-256 over the exact UTF-8 file bytes, including the final newline. Changing this document requires a new deployment and voluntary migration. The input compiler checks structure and arithmetic; a reviewer and UMA disputers must verify the sources and methodology.

## Universe and reference dates

Canonical order is **AAPLc, AMZNc, GOOGLc, METAc, MSFTc, NVDAc, TSLAc**. Identify assets by the seven immutable Base addresses, not mutable token symbols. Companies are Apple, Amazon, Alphabet, Meta, Microsoft, NVIDIA, and Tesla. Alphabet appears once, with its full company capitalization represented through GOOGLc. There is no cash target, leverage, shorting, project fee, or discretionary substitution.

The observation cutoff is 23:59:59 UTC on the last calendar day of each quarter. The reference timestamp is the official regular-session closing time of the final US equity trading session on or before that cutoff (including early closes). Record an authoritative exchange-calendar source. Propose the observation during the following quarter; `quarter_id = year * 4 + zero_based_quarter` identifies that proposal quarter, not the observation quarter. For example, the June 30, 2026 review has proposal quarter ID 8106, corresponding to July–September 2026.

Use only evidence publicly available by the cutoff. Missing data, unresolved corporate actions, unknown share-class treatment, or an unavailable compatible token means no valid proposal; preserve the existing basket. Do not estimate missing observations or remove a constituent.

## Capitalization and quantity calculation

Use the latest **actual outstanding common share count** available for each required class in SEC filings published by cutoff, with the observation date no later than the reference close. Prefer the latest dated explicit class count in an applicable 10-Q, 10-K, or subsequent filing. Record the exact filing URL, publication timestamp, count observation date, and share-class label. A filing may report class counts outside aggregate company-facts fields: inspect the filing. Do not use float, fully diluted shares, weighted-average EPS shares, issuer token supply, or a market-cap estimate that cannot be reproduced from these observations. [SEC APIs](https://www.sec.gov/search-filings/edgar-application-programming-interfaces)

Apply documented splits, reverse splits, issuances, cancellations, repurchases, or conversions after each count's observation date and through the reference close. Apply adjustments chronologically as `shares = shares * factor + delta_shares`; factor is positive, delta may be signed, and resulting shares must remain positive. Counts are understood to include events through the close of their observation date; reject adjustments on that same calendar date so an action cannot be applied twice. If no sufficiently precise public adjustment is available, retain the latest reported count rather than inventing intervening buybacks. Record each action's effective timestamp, publication timestamp, and source. A source becoming available after cutoff is excluded even if it describes an earlier event.

Required classes and price proxies:

| Company token | Counted classes | Closing price used for each class |
| --- | --- | --- |
| AAPLc, AMZNc, MSFTc, NVDAc, TSLAc | `common` | AAPL, AMZN, MSFT, NVDA, TSLA respectively |
| GOOGLc | `A`, `B`, `C` | A: GOOGL; B: GOOGL; C: GOOG |
| METAc | `A`, `B` | META for both |

The unlisted B-class proxies rely on economic equivalence of the current share classes; a change to those rights invalidates v1 treatment until a new methodology/deployment. All listed-class prices are unadjusted official closes in USD at the reference timestamp. Record the exchange/issuer or licensed price-source URL and timestamp for each. Splits are applied to counts and closing prices consistently.

For each company `i`:

```text
company_cap[i] = sum(adjusted_actual_shares[class] * class_close_usd)
cap_weight[i] = company_cap[i] / sum(company_caps)
human_token_quantity[i] = company_cap[i] / reference_total_return_token_price[i]
quantity_ratio[i] = human_token_quantity[i] / sum(human_token_quantities)
```

The token price must refer to the same reference close and the B20 multiplier effective at that close. Require the token reference price to equal the held share class's reference close multiplied by the effective multiplier, allowing at most **0.00000001 USD absolute difference** for the eight-decimal feed's rounding or truncation. The held class is A for GOOGLc and METAc and `common` for the other five; other classes affect company capitalization but not this token-price identity. Perform this check with exact rational arithmetic. A published total-return value already contains the multiplier: **do not multiply it again**. Record multiplier evidence and reference timestamp even when using a total-return price. If the issuer oracle is paused, or its last value describes another session, do not call it a matched closing observation. Reconstruct from the class close and independently verified effective multiplier only when that reconstruction is fully sourced. [Coinbase total-return feeds](https://docs.chain.link/data-feeds/tokenized-equity-feeds/coinbase)

Ratios are **human token quantities**, before token-decimal conversion, not value weights or smallest-unit amounts. Normalize exactly to integers summing to `10^18`: floor each exact rational allocation, then give the remaining units to largest fractional remainders; canonical component order breaks ties. Reject any allocation rounded to zero. The controller converts quantity ratios into value weights using current valid token prices for execution checks. Between reviews, quantities stay fixed while prices naturally change the portfolio weights. B20 dividends can cause some deviation from pure price-only company capitalization between quarterly reviews.

## Observation compiler

Run `python3 scripts/index_snapshot.py observations.json --canonical-out observations.canonical.json > snapshot.json`. The canonical file holds the exact bytes whose SHA-256 is asserted, so `sha256sum observations.canonical.json` reproduces `observation_sha256`. Financial numbers must be quoted plain decimal strings, UTC timestamps must use `YYYY-MM-DDTHH:MM:SSZ`, and URLs must be HTTPS. Supply all seven companies and all required classes. This illustrative **single-company fragment is synthetic**, is not a valid seven-company input, and must not be used to seed a vault:

```json
{
  "cutoff": "2026-06-30T23:59:59Z",
  "reference_at": "2026-06-30T20:00:00Z",
  "market_calendar_source": "https://exchange.example/calendar",
  "companies": [{
    "symbol": "AAPLc",
    "share_basis": "actual_outstanding_common",
    "token_price_usd": "10",
    "token_price_at": "2026-06-30T20:00:00Z",
    "token_price_source": "https://price.example/reference",
    "multiplier": "1",
    "multiplier_at": "2026-06-30T20:00:00Z",
    "multiplier_source": "https://chain.example/archival-evidence",
    "classes": [{
      "id": "common",
      "shares_outstanding": "100",
      "shares_as_of": "2026-06-01",
      "filing_published_at": "2026-06-02T00:00:00Z",
      "filing_source": "https://www.sec.gov/synthetic-example-not-a-filing",
      "price_symbol": "AAPL",
      "price_usd": "10",
      "price_at": "2026-06-30T20:00:00Z",
      "price_source": "https://price.example/official-close",
      "adjustments": []
    }]
  }]
}
```

Each adjustment has `effective_at`, `published_at`, `source`, `factor`, and `delta_shares`. Publish the observation file with the compiler output at an immutable/content-addressed location. Output includes `quantity_ratios`, reference-only `reference_cap_weights`, `quarter_id`, and a SHA-256 digest of the canonical JSON observation bytes (sorted keys, compact separators, unescaped UTF-8). The SHA-256 evidence digest is distinct from the contract's methodology hash and assertion hash. Changing observation field order does not change its digest; array order remains significant.

The compiler does not fetch filings, determine the latest available filing, license market data, establish economic equivalence, or attest the truth of URLs. It refuses many structural mistakes; it cannot prove that a proposer supplied honest financial observations.

## Assertion and monitoring

The controller uses UMA OOv3 with the fixed `ASSERT_TRUTH2` identifier (UTF-8 bytes, right-padded with zeros to bytes32), a 72-hour challenge period and a USDC bond at least the current UMA minimum and immutable project bond floor. The claim commits to the proposal quarter, its observation cutoff, and all seven quantity ratios, with each ratio beside its token address and canonical symbol label. It also names two documents, each by plain-text location and hash: this methodology (a content-addressed `ipfs://` or `ar://` copy of these exact bytes, with its Keccak-256) and the evidence bundle (a content-addressed location, with the SHA-256 of the canonical observation bytes). It asserts that the ratios are exactly what this methodology produces from those observations. The claim is false if either document is unavailable at its location, does not match its hash, or does not support the exact values. Never fall back to OOv3's `defaultIdentifier()`: when this methodology was written, Base's deployment returned the deprecated `ASSERT_TRUTH`, which is no longer whitelisted. Verify the explicit identifier and USDC against the current allowlists resolved by UMA Finder, then synchronize the oracle parameters before calculating the bond. [Approved identifiers](https://docs.uma.xyz/resources/approved-price-identifiers), [ASSERT_TRUTH2 specification](https://github.com/UMAprotocol/UMIPs/blob/master/UMIPs/umip-191.md)

UMA resolves data correctness; a price-loss check cannot substitute for this process. Anyone may propose, challenge, settle, or execute subject to the controller's fixed checks. A pending proposal blocks new ones only while it is undisputed and within one day after its challenge window. A disputed proposal never blocks a replacement, and the first proposal of a quarter to settle true is the one executed. [UMA dispute model](https://docs.uma.xyz/developers/optimistic-oracle-v3)

Monitor proposals continuously during every challenge window. Independently recalculate the ratios and compare the commitment against the original filing, calendar, class, price, multiplier, and adjustment evidence; dispute a false or unreviewable claim before its expiration. Monitor assertion settlement, issuer corporate-action/pause announcements, feed staleness, and missed quarterly execution. When this methodology was written, Base was an **unmonitored UMA deployment**: Risk Labs does not promise to challenge this integration. Bonds, monitoring, and challenge capital are funded separately from vault backing. [UMA network support](https://docs.uma.xyz/resources/network-addresses)

One accepted rebalance may execute per quarter; missing, false, or stale proposals leave existing quantities in place. Execution moves the vault one bounded step toward the accepted ratios. Each constituent's quantity share changes by at most the larger of 5% of its current share and 0.25 percentage points; every other share moves proportionally along the same path. A change larger than one step therefore converges over several quarters.

The controller plans the trades itself from the vault's holdings and one oracle snapshot:
- each stock is only sold or only bought, sales first;
- each leg must return at least its oracle value less 1%;
- total loss may not exceed 1% of traded value;
- the result must match the stepped quantities within 30 bp and leave at most 1 bp of NAV in cash.

It also enforces its oracle rules: issuer feeds unpaused, the sequencer healthy, every stock price at most 25 hours old and at least one at most 1 hour old, weekdays 15:00–20:00 UTC. Neither the methodology nor the oracle creates an administrator withdrawal path.
