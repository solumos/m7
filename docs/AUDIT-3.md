# M7 security review 3 — 2026-09-28

Follow-up: [review 4](AUDIT-4.md) found and fixed a completion-check gap in this remediation. Precision-floor exclusions could leave a seized stock unrecovered, and the all-below-floor case now fails explicitly instead of consuming the quarter. The results below describe review 3's historical state.

## Scope and conclusion

Reviewed commit [`54b02e8`](https://github.com/solumos/mag7/tree/54b02e8), the equal-weight redesign now on `main`. Scope: every contract and interface in `src/`, the deployment and maintenance scripts, the rehearsal, and the off-chain tools where they feed on-chain actions. No earlier review covered this code. Review 2 covered `2c1b641`; since then `src/` has changed by 1,099 added and 561 removed lines. Those changes are the remediation of both reviews, the removal of the gateway's fee and owner, the lens, and the redesign itself. This is a third internal, AI-assisted review, not an external firm's attestation or formal verification. It covers the code, not legal or issuer eligibility.

**Conclusion.** No path was found to steal vault assets, mint unbacked shares, lower backing per share, reach deferred claims, or make a reset trade outside its bounds. A wrong oracle price makes a reset revert instead of trading at that price. The two medium findings concern the reset's economics at larger sizes, not the safety of deposits:

- **E-01: anyone who triggers the reset can sandwich it inside their own transaction.** On live Base pools, with a $300k vault, an attacker made up to $53 while holders lost $128 more than in an honest reset (4.3 bp of NAV). At a block 105 minutes earlier, with different pool liquidity, the same attack lost money.
- **E-02: the reset cannot rebalance a large vault through today's pools.** Every trade goes through one pool per stock, all in one transaction. Large purchases also fail the 30 bp equal-weight check before they reach the 1% trade minimum. On live pools, a $900k vault with two stocks 42% underweight could not be reset at all, and neither could a vault that needed to sell $182k of TSLAc.

**What this meant for the launch.** At the planned $125 seed both are negligible. The sandwich is worth cents, below the pools' fees, and no trade comes near pool capacity. Both grow with the vault: E-01 is already profitable at $300k in some pool states, and E-02 binds from roughly $1–3M in a volatile quarter. The contracts are immutable and ownerless, so fixing either after deployment would have meant new contracts and asking holders to move. All eight findings were therefore fixed before deployment; see [Remediation status](#remediation-status).

| ID | Severity | Finding | Reproduction |
| --- | --- | --- | --- |
| E-01 | Medium — value extraction | Any caller can sandwich the reset in one transaction, within its 1% trade minimums | Live-pool fork test |
| E-02 | Medium — availability at scale | Pool depth caps the reset, and large purchases fail the 30 bp compliance check before the 1% minimum | Live-pool fork tests, unit test, seeded soak |
| E-03 | Low — availability | The turnover fence blocks every reset after a stock outperforms about 11x, instead of limiting the step | Unit test |
| E-04 | Informational | A reset that trades nothing can still pay the reward (vaults under about $70) | Unit test |
| E-05 | Informational | With every stock below the precision floor, the reset panics instead of reverting with a named error | Unit test |
| E-06 | Informational | Two resets can run days apart around a quarter boundary | Unit test |
| E-07 | Informational | The reward and USDC legs skip the stocks' transfer policies; a reward sent to a contract that cannot move USDC is lost | Analysis |
| E-08 | Informational | `verify_deployment.py` still describes the earlier design | Analysis |

## Remediation status

After this review the reset was changed to fix every finding. The sections below describe the code as reviewed (`54b02e8`). Their reproduction tests were converted into regression tests that assert the fixed behavior.

The reset now runs in **tranches**. Each call moves every stock the same fraction of the way to equal weight, with no sale worth more than about $10,000. Calls come at least 30 minutes apart, and the quarter completes once every stock is within 10 bp of equal value. Before trading, each pool the tranche uses must sit within 25 ticks (about 0.25%) of its own 10-minute time-weighted average in the vault's direction. Observations are written before a block's first swap, so a caller cannot move that average within its own transaction.

| ID | Status | Fix | Regression tests |
| --- | --- | --- | --- |
| E-01 | Fixed | Pool check against each pool's 10-minute average; trades capped at about $10k per stock per tranche | `testAudit3PushedPoolRefusesTheTranche`; fork `testAudit3SandwichIsRefusedOrUnprofitable` |
| E-02 | Fixed | Tranches sized to the $10k cap; a shortfall is allowed, as long as no stock moves away from its target | fork `testAudit3LargeSaleCompletesInTranches` and `testAudit3LargePurchasesCompleteInTranches`; `testAudit3LargePurchaseShortfallCompletesInALaterTranche`; `testHugeMovesProceedInCappedTranches` |
| E-03 | Fixed | Turnover fence removed; the cap sizes every tranche | `testAudit3ElevenfoldMoveCompletesInTranches` |
| E-04 | Fixed | The reward is 5 bp of the tranche's one-way traded value, at most $25. It is set aside from cash and paid only if a trade executed | `testAudit3TrancheThatTradesNothingPaysNothing`, `testRewardIsCappedAndCanBeDeclined` |
| E-05 | Fixed | Nothing to compare counts as compliant | `testAudit3EveryStockBelowTheFloorHasNothingToTrade` |
| E-06 | Fixed | A quarter's reset opens 30 days after the previous one completed | `testAudit3ResetsAreAtLeastThirtyDaysApart` |
| E-07 | Fixed | The controller and valuation are refused as reward receivers | `testAudit3RewardSinksAreRefused` |
| E-08 | Fixed | Description updated | — |

**Re-verification on live Base.** The fixed code was re-run at the blocks each finding was recorded at.
- **E-01:** the same $300k vault and front-runs. Every sandwich that still executed lost the attacker money: $1.92–29.57 beyond the reward it would have earned anyway. Holders' extra loss fell to $0.08–10.41 per tranche, from $15–128. Pushes that also moved METAc were refused with `PoolMoved`.
- **E-02:** the $182k TSLAc sale completed in 19 tranches, and the $900k vault with two stocks 42% under target in 15.
- **Everything else:**
  - the native Base tests and the rehearsal pass under Beryl and Cobalt rules;
  - `make check` passes: 118 Solidity and 31 Python tests;
  - fuzzing passes at 10,000 runs;
  - all five invariants pass at 2,048 runs of 64 calls;
  - three 6,000-step seeded soaks pass.

  The stateful campaign now also pushes pool prices and checks two more properties: every sale stays within the cap, and no trade goes through a pool pushed against the vault.

**Residual risks after remediation:**
- **Execution:** a caller can still move a pool up to 25 ticks against the vault before its call, and worsen each trade of at most $10k by that much, about $25. On the tested pools that cost the attacker more in fees than it gained. A provider holding most of a pool's in-range liquidity earns those fees back, so for them it can pay, within that bound.
- **Speed:** the $10k cap keeps each tranche within today's pool depth. Resets of large vaults therefore take time: a volatile quarter needs about 50 tranches at $10M, a week at ten a day. Well beyond that, a quarter's reset may not complete within the quarter, and the next quarter continues it.
- **New dependency:** the pool check needs each pinned pool to keep 300 price observations. All seven keep 360 or 2,048. The preflight checks this, and anyone can raise it.
- **Keepers:** at 5 bp of the traded value, the reward does not attract keepers to a small vault, so the owner runs its tranches.
- **Review:** the remediation has had no review other than this internal one, and there is no external audit.

## Method

- Manual line-by-line review of `IndexController`, `M7Vault`, `USDCGateway`, `Valuation`, `M7Lens`, the interfaces, `Deploy`, `Bootstrap`, `AcquireSeed` and `Rebalance`, `rehearse.sh`, `seed_basket.py`, `verify_base.py`, `verify_deployment.py` and `monitor.py`.
- Live data from Base:
  - each pinned pool's fee, depth and offset from the oracle, through the Slipstream quoter;
  - every stock feed's round history around US Labor Day (Monday 2026-09-07).
- Reproductions:
  - [`test/Audit3.t.sol`](../test/Audit3.t.sol): unit tests against a vault double that fills trades at oracle value.
  - [`test/Audit3Fork.t.sol`](../test/Audit3Fork.t.sol): the real contracts on a local fork of live Base, with native B20 execution. Only USDC is dealt; every stock is bought from its pinned pool. Stock feeds are then set to each pool's mid price, so each test starts from pools that agree with the oracle.
  - [`test/Audit3Invariant.t.sol`](../test/Audit3Invariant.t.sol): the first campaign to interleave quarterly resets with every holder flow. It covers in-kind mints and exits, resilient exits and claim withdrawals, donations, issuer seizures and freezes, price moves, pool offsets and fees. It also includes a wrong-price test and a long seeded soak.
- Existing checks re-run on this commit:
  - `make check`;
  - fuzzing at 10,000 runs;
  - review 2's invariant campaign at 2,048 runs;
  - the native Base tests and the rehearsal under both Beryl and Cobalt rules;
  - Slither 0.11.6.

## E-01 — any caller can sandwich the reset in one transaction

`rebalance` takes no trades from its caller, but it can be called by any contract, in the middle of that contract's own swaps. Each of the reset's trades must return at least its oracle value less 1%, and it goes through a public pool. A caller can therefore do all of this atomically, with no mempool access:
1. push up the price in the pools of the stocks the vault is about to buy (or down, for those it will sell);
2. call `rebalance`, collecting the reward;
3. trade back.

The vault pays the higher prices, up to its minimums. The attacker pays the pools' 0.05% fee on its own volume.

**Reproduction** (`testAudit3CallerSandwichesTheResetInOneTransaction`, block 51,891,228, Cobalt and Beryl rules). The vault holds $300k, with AAPLc overweight and METAc and TSLAc 42% under their equal-weight value. The reset therefore buys about $17.8k of each. The honest reset cost holders $80.60, including the $15 reward.

| Front-run (USDC) | Outcome | Attacker, incl. the $15 reward | Holders' extra loss |
| --- | --- | ---: | ---: |
| TSLAc 20,000 | executed | +$10.24 | $15.24 |
| TSLAc 40,000 | executed | +$42.65 | $67.62 |
| TSLAc 80,000 | reverted by the 1% minimum | — | — |
| METAc 50,000 + TSLAc 40,000 | executed | +$53.31 | $128.16 |
| METAc 100,000 + TSLAc 80,000 | reverted | — | — |
| METAc 200,000 + TSLAc 160,000 | reverted | — | — |

At block 51,888,073, 105 minutes earlier, the same attack on the same vault lost the attacker $0.26, $7.00 and $18.66 in the three executed rows, and cost holders $4.74, $17.99 and $56.27. Pool liquidity decides whether a given size pays. Where it doesn't, the loss is mostly the attacker's fees, about $90 in the $90k row. A liquidity provider holding most of a pool's in-range liquidity earns that fee back, so for them the sandwich pays in more states.

**Impact.** The loss is bounded: at most 1% of each trade's value, and in practice by the pools' depth (E-02). This naive attacker tried six sizes on two of seven pools and took 4.3 bp of NAV from one reset. An optimized one would take more. The reset's reward also pays whoever triggers it first, so bots that do this will compete for every quarter's reset once the vault is worth it. The first review's residual risk of "up to 1% of traded value" still applies. Equal weight trades far more each quarter than the cap-weighted design did, so that 1% applies to much larger trades.

**Recommendations.**
1. Check each pinned pool's current price against the oracle at the start of the reset. Revert if a pool the reset will trade in is more than about 30 bp against the vault. A caller then cannot pre-position more than that. The reset's own price impact stays governed by the leg minimum.
2. Keep reset trades small, as in E-02's tranches. The gain from a sandwich grows with the size of the vault's trade, while its fee cost does not.
3. Once trades are small, consider tightening `MAX_SLIPPAGE_BPS`.

## E-02 — pool depth caps the reset, and the compliance check binds before the trade minimums

The reset plans every trade from one price snapshot and executes them in one transaction, each through its stock's single pinned pool. Each trade must return at least its oracle value less 1%. Afterwards every stock not lifted to the precision floor must hold the same quantity per unit of target within 30 bp (`COMPLIANCE_BPS`).
- Stocks that were sold end exactly at their goal.
- Stocks that were bought end short by two amounts, in proportion to how much of their final holding was bought: their own purchase's slippage, and the cash the sales raised below oracle value.

So a stock that buys a fraction *f* of its final holding fails compliance once its combined shortfall × *f* exceeds 0.3%. At *f* = 42%, about 0.7% is enough, well inside the 1% trade minimum. Every retry fails the same way until prices move back, because each attempt plans the same trades.

**Pool depth** (Slipstream quoter at block 51,887,748, about 03:07 UTC; every pinned pool charges 0.05%):

| Stock | Selling $100k: pool price moves | Filled vs oracle | Selling $250k: pool price moves | Filled vs oracle |
| --- | ---: | ---: | ---: | ---: |
| AAPLc | 3.7 bp | −6.6 bp | 29.0 bp | −11.5 bp |
| AMZNc | 34.8 bp | −37.8 bp | 170.0 bp | −92.1 bp |
| GOOGLc | 41.0 bp | −41.2 bp | 217.2 bp | −111.6 bp |
| METAc | 59.2 bp | −49.9 bp | 162.6 bp | −104.9 bp |
| MSFTc | 23.7 bp | −14.7 bp | 146.1 bp | −64.6 bp |
| NVDAc | 40.7 bp | −59.2 bp | 118.3 bp | −94.3 bp |
| TSLAc | 135.6 bp | −89.0 bp | 300.7 bp | −178.6 bp |

"Filled vs oracle" includes each pool's offset from the oracle at that hour, which was up to 41 bp (NVDAc) overnight. Offsets during the reset window were not measured.

**Reproductions.**
- `testAudit3ResetLegBeyondPoolDepthBlocksTheQuarter` (block 51,891,137). A reset that must sell $51.8k of TSLAc executes. One that must sell $182.0k reverts `NotCompliant`: the sale met its minimum, but the purchases it funded fell short. At block 51,888,034 the $182.7k sale itself failed its minimum (`Too little received`).
- `testAudit3LargePurchasesFailComplianceOnLivePools` (block 51,888,052). A $901k vault with METAc and TSLAc 42% under target must buy about $53.7k of each. The honest reset reverts `NotCompliant`. The same reset executed at block 51,891,178, and the same skew at $300k executes: whether it fails depends on pool state.
- `testAudit3LargePurchaseFailsComplianceInsideTheLegMinimums` (unit). Every trade loses 0.5%, half its minimum, and the total loss is about half the allowance. AMZN, after a 40% fall, must buy 36% of its final holding, and the reset reverts `NotCompliant`. At 0.25% per trade it passes.
- `testAudit3ResetSoak` with seed 7 (6,000 steps). With pool fees and impact capped at 40 bp and offsets at 30 bp, one reset in 1,197 attempts failed `NotCompliant`.

**Impact.** Once a quarter's reset needs trades beyond these limits, no reset runs and the basket drifts until prices come back. No funds are at risk, and minting and redemption continue, but the vault stops being equal-weight, which is its purpose.

With today's pools, a volatile quarter for TSLAc or METAc (a 30–40% move against the others) reaches the limits at roughly $1.5–3M of NAV. Calmer quarters reach them later, and an extreme skew sooner: the $900k example above. The step bound allows doubling a quantity share in one reset, so a single reset's trades are as large as the whole quarter's drift.

**Recommendations.**
1. Let the reset proceed in tranches. Each call trades a bounded amount, for example sales of at most 2–5% of NAV. Calls are spaced by a cooldown so pools re-align with the oracle, and the quarter counts as done once the basket is inside the deadband or the quarter ends. Smaller trades also reduce E-01.
2. Make compliance consistent with the trade minimums. For example, widen each bought stock's band by the permitted slippage times its bought fraction. The loss bound already protects value; a basket that ends 50 bp from target is far better than no reset.
3. Monitor capacity. Extend the preflight or monitor to quote each stock's likely reset trade (a few % of NAV) through its pool, and alert above about 60 bp of impact.

## E-03 — the turnover fence blocks the reset instead of limiting it

A reset that would sell more than half of NAV reverts `ExcessTurnover`. The step bound limits changes in quantity shares, but price moves change value shares without changing quantities, so the step bound never shrinks such a reset. Once one stock has risen about 11x against the others since the last reset, it is worth more than 64% of NAV and the full reset sells over half. Every later quarter then reverts the same way until prices come back.

`testAudit3TurnoverFenceBlocksEveryResetAfterAnElevenfoldMove` shows two successive quarters refused, and the same reset allowed at 10x. Such a move within one quarter is very unlikely. It becomes more reachable after a long gap without resets, for example while E-02 blocks them.

**Recommendation.** When the full reset would exceed the fence, scale the step down so sales stay under it instead of reverting. Alternatively remove the fence, since the step bound, trade minimums and loss bound already constrain the reset.

## E-04 — a reset that trades nothing can pay the reward

The reward is decided by the deadband check, before trades are planned. Trades under $0.01 are then skipped. When every position is under about $10 (NAV under about $70), a reset can leave the deadband, skip every trade and still pay the reward from cash.

`testAudit3RewardIsPaidByAResetThatTradesNothing` has an $8.45 vault pay $0.0004 with no trade. The amounts are trivial, but the documented rule is that only a reset that trades pays. **Recommendation:** set the reward aside from cash, pay it after the purchases, and only if at least one trade executed.

## E-05 — every stock below the floor makes the reset panic

`_compliant` skips stocks lifted to the precision floor. If all seven are lifted, `low` stays at `type(uint256).max` and the multiplication overflows. The reset then reverts with `Panic(0x11)` (`testAudit3EveryStockBelowTheFloorPanics`). This is only reachable after issuer seizures of every stock, and the outcome is unchanged because the reset cannot run either way. Only the error is opaque. **Recommendation:** return `true` when no stock was compared.

## E-06 — two resets days apart around a quarter boundary

"Once per calendar quarter" allows a reset on Wednesday, December 30 and another on Monday, January 4. Each pays its reward and trading costs (`testAudit3TwoResetsFiveDaysApartAcrossAQuarterBoundary`). This only happens when a quarter's reset was left to its last days. **Recommendation:** also require, say, 30 days since the last reset.

## E-07 — the reward and USDC legs skip the stock policies; reward sinks

`payReward` refuses only the zero address, the vault and the seed lock. USDC is not a B20 stock, so this matches how USDC redemption legs and USDC claims already work, and the reward is at most $25. A reward sent to the controller, gateway, lens or valuation cannot be moved again. That is the caller's own loss. **Optional:** refuse those four addresses.

## E-08 — the verifier's description is stale

`scripts/verify_deployment.py` says it checks "the four contracts" against "the exact bytes of docs/METHODOLOGY.md". It checks five contracts, and there is no methodology hash any more. Only the description is wrong.

## Verified properties

These were verified on the reviewed commit, `54b02e8`. The fixed code's campaign checks the tranche equivalents, as listed under [Remediation status](#remediation-status).

- **Stateful campaign** (`Audit3InvariantTest`): 2,048 runs of 64 calls per invariant (131,072 calls each), plus seeded soaks. Seed 42 (3,000 steps) made 595 reset attempts, 322 successful. Seed 7 (6,000 steps) made 1,197 attempts, 616 successful, 434 of them trading. No violation of:
  - backing per share never falling except through a reset or a seizure;
  - every share and every claim accounted for, with claims equal to `reserved`;
  - resets never changing or underfunding claims, and never changing the share supply;
  - the reward never exceeding `min(0.5 bp of NAV, $25)`;
  - reset losses within 1% of the traded value (measured from the venue's own records) plus the reward;
  - cash within its cap after every reset;
  - after every full-step reset, stocks above the floor holding equal value within 30 bp plus $0.02;
  - at most one reset per quarter, with every repeat attempt refused.
- **Wrong prices fail closed** (`testAudit3WrongPricesFailClosedAgainstTheRealVault`): with the real vault and a pool at the true price, a 5% oracle error in either direction makes the affected trade miss its minimum, and the reset rolls back.
- **Holidays:** no stock feed updated on Labor Day (2026-09-07), so `NoFreshMarketSignal` would have refused a reset all day. Around it, the feeds update during US trading and when the Sunday-evening session opens (00:00 UTC Monday), with occasional overnight updates. The weekday 15:00–20:00 UTC window keeps resets inside regular hours.
- **The reward cannot be farmed.** Pushing a no-op reset into trading costs more than it pays:
  - cash donated above its cap costs at least 1 bp of NAV;
  - moving a weight past the deadband costs about 1.4 bp;
  - the reward is 0.5 bp.
- **Reentrancy:** B20 stocks and USDC have no transfer hooks, and router callbacks go to the router. `payReward` is `nonReentrant` and callable only by the controller, inside the controller's own lock.
- **Unchanged since review 2 and re-checked:**
  - the gateway still cannot spend donations or keep funds;
  - exact balance deltas still guard every transfer;
  - pinned pools and scope checks at construction still hold;
  - the lens, which cannot change state, still matches the vault and valuation it was built from.
- **Deployment tooling:**
  - CREATE prediction and the vault's binding check refuse any drift;
  - `Bootstrap` verifies linkage before funding;
  - `AcquireSeed` caps each purchase at oracle value plus 1%;
  - the verifier compares runtime bytecode with the build and checks every other immutable.

  The gateway's private stock and tick-spacing immutables are copied from the vault at construction, so its checked `vault()` and matching code cover them.
- **Slither 0.11.6:** 121 results.
  - Categories already triaged in reviews 1 and 2: `calls-loop`, `reentrancy-balance`, `uninitialized-local`, `unused-return`, `incorrect-equality`, `weak-prng` (calendar arithmetic) and `timestamp`.
  - New categories: `locked-ether` for the router-only `receive()` from N-01's fix; `assembly` in `_trim`; and `naming-convention` for interface constants.
  - None in the reset or reward path needs a change.

## Limits

- Pool depth and offsets were measured at one hour, overnight. Depth during the reset window was not measured.
- The fork tests set each stock feed to its pool's mid price. On mainnet the feed can sit tens of basis points away, in either direction.
- The sandwich search tried six sizes on two pools. It did not simulate flash liquidity, all seven pools, or an attacker who is also the pools' liquidity provider.
- The recorded fork results depend on pool state at the pinned blocks. `AUDIT3_FORK_BLOCK` reruns them elsewhere, with different numbers, and pinned blocks need an RPC that still serves their state.
- No formal verification and no external audit.

## Reproduce

```sh
make check
forge test --match-contract 'Audit3' -vv
FOUNDRY_INVARIANT_RUNS=2048 forge test --match-contract Audit3InvariantTest --match-test invariant
AUDIT3_SOAK_SEED=7 AUDIT3_SOAK_STEPS=6000 forge test --match-test testAudit3ResetSoak --gas-limit 9000000000000 -vv
FOUNDRY_COMPUTE_UNITS_PER_SECOND=8 FOUNDRY_FORK_RETRIES=80 FOUNDRY_FORK_RETRY_BACKOFF=5000 \
  BASE_FORK_TEST=true FOUNDRY_BASE=cobalt "$BASE_FORGE" test --match-contract Audit3ForkTest -vv -j 1
```
