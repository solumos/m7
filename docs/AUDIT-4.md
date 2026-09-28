# M7 security review 4 — 2026-09-28

Reviewed baseline `665c663`, including the tranche-based remediation from review 3. This review covers all contracts and interfaces in `src/`, the Solidity deployment/seed/maintenance scripts, and relevant tests. The Python operating tools were tested, but were not independently re-audited line by line. Findings below were reproduced and fixed in the accompanying working-tree changes.

Two contract issues were confirmed: one medium availability/correctness issue and one low display-integrity issue. No new path to steal backing, mint unbacked shares, or spend deferred claims was identified. This is an internal AI-assisted review with executable regressions, not an independent audit or formal proof.

| ID | Severity | Finding | Status |
| --- | --- | --- | --- |
| A4-01 | Medium | Reset completion skips stocks that still need precision-floor recovery or have sellable surplus | Fixed |
| A4-02 | Low | The lens accepts future-dated and incomplete oracle rounds | Fixed |

## A4-01 — premature completion prevents recovery

Affected code: `IndexController._setGoals`, `_complete`, `_compliant`, and the no-trades completion branch in `rebalance`.

`_setGoals` lifts a stock's planned quantity to the vault's precision floor and marks it in `plan.floored`. `_compliant` then excludes every marked stock from the equal-weight check without checking its actual holding. Before trading, `rebalance` uses that check to decide whether the quarter is already complete.

**Reproduction against the real vault and controller.** Bootstrap approximately $125 in seven equally valued $100 stock tokens. Seize all of stock 0. The first recovery step's quantity for stock 0 is below its 0.01-token precision floor, so it is excluded from comparison. The other six stocks are equal and there is no cash: the original controller marks the quarter complete with zero trades and stock 0 still missing. `quoteMint` continues reverting `MissingComponent(0)`. Further resets in the quarter are refused; unchanged prices reproduce the same false completion in later quarters. Funds are not stolen, and remaining backing can still be redeemed.

The same cause skips available sales. With 0.02 of each $100 stock, raising stock 0's oracle and venue price to $1,000 makes its equal-weight goal fall below the 0.01 floor. The original completion check ignores it entirely, even though half its quantity can be sold without breaching the floor.

**Fix.** Cache the supply-adjusted precision floor in the plan. Completion now requires every stock to meet that floor. A stock excluded from equal-weight comparison must also be at the floor within the deadband, so available surplus is processed. A tranche with no trades and an unresolved precision deficit reverts `NoProgress`, leaving the quarter and cooldown unchanged.

**Regressions:** `test/Audit4.t.sol` covers complete seizure, partial seizure with keeper rewards (512 fuzz runs), available sales from a floor-constrained stock, and an unfunded deficit. The existing completion invariant now also rejects completed baskets below the precision floor. Review 3's all-below-floor test now expects an explicit failure instead of false completion.

Recovery still requires sufficient remaining assets, executable pools, usable feeds, and issuer permission to move the tokens. The fix does not promise recovery after arbitrary seizure or insolvency.

## A4-02 — malformed price rounds can appear valid in the lens

Affected code: `M7Lens.value`.

The lens checked only positive answers and nonzero update times. A future-dated answer or a round whose `answeredInRound` predates `roundId` therefore contributed to NAV. Its `oldestPriceAt` could still look normal because another component supplies the minimum timestamp. This affects dashboard values; minting, redemption, and controller valuation use other paths.

**Fix.** Reject zero round IDs, incomplete rounds, and timestamps after the current block, matching the structural checks in `Valuation.snapshot`. Old but structurally valid prices remain readable with their age, as the lens API promises. `testMalformedRoundsAreRejectedWithoutRejectingOldPrices` failed on the original code and passes after the fix.

## Shipping-preflight follow-up

A later release-preflight fuzz run found that the new partial-seizure test asserted the 0.1% equal-weight deadband even when the documented minimum-trade exception applies. The counterexample leaves 963,181 raw units after seizure. Recovery ends with stock 0 at 15,409,845 units and each other stock at 15,448,161 units, with zero cash: each remaining funding sale is worth about $0.00547, below the $0.01 minimum. The final tranche makes no trades and pays no reward. This is permitted dust completion, not a new precision-floor recovery defect.

The test now requires either the normal deadband or insufficient purchase cash with every remaining equal-weight funding sale below the minimum. Successful issuance after recovery remains required. A deterministic regression preserves the exact dust-completion case. The focused run passed 4,096 fresh fuzz cases plus the replayed counterexample; the subsequent `make check` passed 124 Solidity tests and 31 Python tests, with the nine native fork cases skipped in that command. No contract behavior changed in this follow-up.

## Initial review validation

Final results: `make check` passed formatting, contract-size checks, **123 Solidity tests** and **31 Python tests**. Its nine opt-in fork cases were skipped there, then **all nine passed separately under both Beryl and Cobalt**. The completed-basket invariant and the new 512-case partial-seizure fuzz test also passed. No test failures remain.

Commands used:

```sh
make check
forge test --match-contract 'Audit4Test|Audit3InvariantTest'
BASE_FORK_TEST=true BASE_FORK_BLOCK=51894703 FOUNDRY_BASE=beryl "$BASE_FORGE" test \
  --match-contract 'BaseForkTest|Audit3ForkTest|Audit2ForkTest'
BASE_FORK_TEST=true BASE_FORK_BLOCK=51894703 FOUNDRY_BASE=cobalt "$BASE_FORGE" test \
  --match-contract 'BaseForkTest|Audit3ForkTest|Audit2ForkTest'
```

The ordinary suite uses Forge 1.5.1 and Solidity 0.8.30, with 512 fuzz runs and 128 invariant runs at depth 64. Native forks use the installed Base Foundry build `nightly-98e7839c65f6`. `Audit3ForkTest` uses its own recorded blocks 51,888,052, 51,891,137, and 51,891,228; the other fork suites use block 51,894,703. The native tests exercise B20 transfers, gateway entry/exit, the lens, real pool resets, large tranches, and the previously demonstrated sandwich scenarios. Cobalt here is simulated against pre-upgrade state, not a post-upgrade mainnet validation.

One pre-existing test-harness defect was also repaired: `Audit2ForkTest` called `refundETH()` during cleanup but could not receive ETH itself, reverting `STE` after correctly observing the victim's expected failures. A receive function was added to the test contract; the deliberately vulnerable victim remains unchanged.

No transactions were broadcast. The deployment rehearsal and production address/bytecode verification were not rerun in this review.

## Remaining assumptions and limits

- The fixed per-leg cap still relies on adequate liquidity in the pinned pools. Reduced liquidity or adverse prices can stop resets; there is no caller-selected smaller tranche size or alternative route.
- The TWAP guard limits adverse spot movement relative to the pool's history. It does not eliminate MEV, manipulation held over time, or the advantages of an attacker who owns liquidity. The existing tested sandwiches remain bounded and unprofitable in the tested states, not in every possible future pool state.
- Issuer freezes, policy changes, seizures, and reserve insolvency remain external risks. Seizure below outstanding claims can block all rebalances until reserves are covered. The contracts cannot create missing assets.
- Equal weighting remains subject to the precision floor and dust thresholds. A stock retained at its floor may stay overweight. Healthy baskets with only sub-minimum trades can still complete outside the nominal deadband.
- The oracle freshness policy is a heuristic for usable market data, not a market calendar. No live historical-feed replay was repeated here.

Primary integration references checked during review: [Base's B20 policy interface](https://github.com/base/base-std/blob/main/src/interfaces/IB20.sol), [Slipstream's observation implementation](https://github.com/aerodrome-finance/slipstream/blob/main/contracts/core/libraries/Oracle.sol), and [Chainlink's Coinbase equity-feed model](https://docs.chain.link/data-feeds/tokenized-equity-feeds/coinbase). B20 policies apply to transfer parties and the immediate executor; observations accumulate ticks over elapsed time; tokenized-equity prices already include the issuer multiplier. These support the integration assumptions, not a guarantee of issuer behavior or future pool liquidity.
