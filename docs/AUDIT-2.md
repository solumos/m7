# M7CAP security review 2 — 2026-09-26

> **Status after the redesign (2026-09-27).** M7CAP has since been redesigned as **M7, "M7 Equal Weight"**, and its contracts renamed (`M7CapVault` → `M7Vault`, `M7CapLens` → `M7Lens`). UMA governance is gone: an autonomous quarterly reset that anyone may trigger returns the basket to equal value using only onchain prices, and pays the caller at most 0.5 bp of NAV, capped at $25. The gateway has no owner and no fee, and no contract has an owner. This review describes the earlier design and was not repeated on the new code. Findings about proposals, disputes and assertions (N-02, N-03, N-04, N-08 and the L-01 re-rating) no longer apply. The planner findings still apply to the reset, which reuses that planner, and so do the vault, gateway and policy findings. See [METHODOLOGY.md](METHODOLOGY.md) for the current rules.

## Scope and conclusion

Reviewed commit `2c1b64179af278d63c00687bda3f0ce6bda5e8a3`, which is the M-01 fix on top of `ac11b09`. Scope: every contract and interface in `src/`, the deployment and maintenance scripts, and the off-chain tools where they feed on-chain decisions. This is a second internal, AI-assisted review, not an external firm's attestation. It builds on the [first review](AUDIT.md) and does not repeat its findings, except to re-rate them.

**Conclusion: the stack is still not ready for public deposits.** No path was found to steal vault assets, mint unbacked shares, or reduce per-share backing, and the accounting held under a new stateful fuzz campaign. The review found two new, cheaply triggered availability failures and one integrity risk in the governance design, all reproduced. It also recommends raising M-02 to High.

| ID | Severity | Finding | Reproduction |
| --- | --- | --- | --- |
| N-01 | Medium | One wei of ETH left in the Slipstream router makes every gateway purchase, gateway sale and rebalance revert | Live-router fork test and local end-to-end tests |
| N-02 | Medium | A false proposal disputed to an unpayable address can never settle, which blocks its quarter | Live UMA fork test; only the DVM vote is mocked |
| N-03 | Medium | One unchallenged assertion can move the whole basket into one stock; nothing bounds the change | Local end-to-end test |
| N-04 | Low | DVM voters must recompute exact ratios from a hash-referenced methodology, and unresolvable claims resolve false | Primary-source analysis |
| N-05 | Low | Anyone can make USDC a leg of nearly every redemption for about $0.001 | Analysis |
| N-06 | Informational | Absolute swap amounts make execution plans fragile to balance changes | Local tests |
| N-07 | Informational | The vault–controller binding is only checked in the deployment simulation | Analysis |
| N-08 | Informational | Monitoring does not detect the two new failure signals | Analysis |
| N-09 | Informational | Gas, clarity and unrecoverable-transfer notes | — |
| M-02 | Medium → **High** | Re-rating: the loss allowance is systematically extractable every quarter | Live pool evidence |
| L-01 | Low → **Medium** | Re-rating: N-02 removes the premise that dispute resolution restores availability | Live UMA fork test |

## Remediation status

After this review the code was changed to fix every finding, including the first review's open ones. The finding sections below describe the code as reviewed (`2c1b641`). Their reproduction tests were converted into regression tests that assert the fixed behavior.

| ID | Status | Fix | Regression tests |
| --- | --- | --- | --- |
| N-01 | Fixed | `receive()` on the vault and gateway accepts ETH from the router only | `testAudit2RouterEthDustNoLongerBlocksGateway`, `testAudit2RouterEthDustNoLongerBlocksRebalance`, fork `testAudit2LiveRouterDustIsAbsorbedByRouterGatedReceiver` |
| N-02 | Fixed | A disputed proposal, or an undisputed one unsettled one day after its challenge window, no longer blocks a replacement; the first to settle true is executed | fork `testAudit2UnpayableDisputerNoLongerBlocksQuarter`, `testUndisputedPendingBlocksButADisputedOneDoesNot`, `testUnsettledUndisputedProposalIsReplaceableAfterGrace` |
| N-03 | Mitigated | Each quarter moves every quantity share at most max(5% relative, 0.25 points); the planner bounds loss by traded value | `testAudit2FalseAssertionMovesAtMostOneStep`, `testBogusRatiosMoveEachConstituentAtMostOneStep` |
| N-04 | Mitigated | The claim names the methodology and evidence by plain-text content-addressed URI plus hash, the observation cutoff and symbol labels; `--canonical-out` publishes the digested bytes | `testAssertionClaimBindsExactMethodologyEvidenceAndContext`, `testMalformedProposalsRejected` |
| N-05 | Fixed | `redeemBasketWithClaims` defers a USDC leg that cannot move | `testPausedUsdcDefersTheCashLeg` |
| N-06 | Fixed | The controller plans from current balances at execution time | `testAudit2PlannerSurvivesLargeRedemptionBeforeExecution`, `testAudit2PlannerDeploysDonatedCash` |
| N-07 | Fixed | The vault's constructor requires `controller.vault() == address(this)`; Bootstrap verifies linkage and pools before funding | `testConstructorPinsExistingPoolsAndRequiresControllerBinding` |
| N-08 | Fixed | The watcher flags unpayable payees, unexpected assertion parameters and digest mismatches, and reports whether a replacement is allowed | `test/test_watch_index.py` |
| N-09 | Fixed | Vault and gateway assets and pools are immutables; the redundant ratio bound is removed | — |
| M-02 | Fixed | See the first review's status section | `test/ControllerPlanner.t.sol` |
| L-01 | Fixed | As N-02 | As N-02 |

Residual risks after remediation:

- **Execution:** an executor can still extract up to 1% of traded value through the pinned pools, a few basis points of NAV per quarter.
- **Oracles:** a stale-but-accepted price widens that bound. A holiday heartbeat can open a window while the market is closed.
- **Governance:** a false unchallenged assertion can still move composition one step per quarter, and the bond is fixed. *(Superseded: the equal-weight reset has no assertions. Its targets are computed onchain from prices, and one reset moves each stock's quantity share by at most its current size, or 0.25 points if that is more.)*
- **Claims:** claims on frozen or seized assets may never pay out, and they are senior to holders under seizure.
- **Eligibility:** policy mirroring means a stock-wide freeze or an allowlist switch also freezes M7CAP transfers, including M7CAP held in DeFi.
- **Fee owner:** removed. The gateway briefly had an owner who could set a fee of at most 10 bp; the fee and the owner were taken out before deployment, so no contract has an owner.

Native B20 behavior of the new code has since been tested against live Base under both Beryl and Cobalt rules, including registry lookups and their gas and a rebalance through the live pools (see [INTEGRATION.md](INTEGRATION.md)).

## Method

- Manual line-by-line review of the four contracts, interfaces and scripts.
- Primary-source checks of dependencies as deployed. Sources: the verified `SwapRouter` source for `0x698Cb2b6dd822994581fEa6eA4Fc755d1363A92F` on [Blockscout](https://base.blockscout.com/address/0x698Cb2b6dd822994581fEa6eA4Fc755d1363A92F), Aerodrome's [`CLFactory`](https://github.com/aerodrome-finance/slipstream/blob/main/contracts/core/CLFactory.sol), UMA's [`OptimisticOracleV3`](https://github.com/UMAprotocol/protocol/blob/master/packages/core/contracts/optimistic-oracle-v3/implementation/OptimisticOracleV3.sol), [UMIP-191](https://github.com/UMAprotocol/UMIPs/blob/master/UMIPs/umip-191.md), the [Base tokenized-stock documentation](https://docs.base.org/build-on-base/integrate-defi/list-tokenized-stocks) and [`IB20`](https://github.com/base/base-std/blob/main/src/interfaces/IB20.sol). Live reads covered the factory, router, OOv3 and USDC.
- Fork tests on live Base state with ordinary Foundry. They do not need the B20 precompile.
- Local end-to-end tests with the real vault, gateway, controller and valuation, a stateful invariant campaign, and a differential calendar test.
- Slither 0.11.6 on the current commit: 80 detector results in the same categories as the first review's baseline. The two additional `calls-loop` results come from the M-01 floor checks. No new category appeared.

New tests: [`test/Audit2.t.sol`](../test/Audit2.t.sol), [`test/Audit2Invariant.t.sol`](../test/Audit2Invariant.t.sol) and [`test/Audit2Fork.t.sol`](../test/Audit2Fork.t.sol). Tests of open issues assert the current behavior so they stay executable. Convert them to regression assertions when the issues are fixed.

## N-01 — dust ETH in the router blocks the gateway and rebalancing

**Locations:** [M7CapVault.sol](../src/M7CapVault.sol) lines 16 and 180; [USDCGateway.sol](../src/USDCGateway.sol) lines 12, 68 and 124. OWASP area: external interactions and denial of service.

The deployed Slipstream router ends both `exactInputSingle` and `exactOutputSingle` with `refundETH()`. That call sends the router's entire ETH balance to `msg.sender` and reverts with `STE` if the transfer fails. The vault and the gateway are that `msg.sender`, and neither has `receive()` or a payable fallback.

Anyone can leave ETH in the router. Several router functions are payable and keep the ETH, for example `unwrapWETH9` when the router holds no WETH. `SELFDESTRUCT` can also force ETH in.

While the router holds any ETH, every gateway mint and redemption and every quarterly rebalance reverts. In-kind mint and redeem still work. Anyone who can receive ETH can clear the dust by calling `refundETH()`. A griefer can put it back for one wei plus the gas of one call, and Base has no public mempool that a victim could watch.

**Reproduction:**

- `testAudit2LiveRouterEthDustBricksNoReceiveCallers` leaves one wei in the live router. Both swap types then revert with `STE` for a contract that calls the router the way the vault does.
- `testAudit2RouterEthDustBlocksGatewayMintAndRedeem` and `testAudit2RouterEthDustBlocksQuarterlyRebalance` show the end-to-end effect on the real contracts.

The existing router mocks do not implement `refundETH`, so the suite could not catch this. The native fork test passed at a block where the router held no ETH.

No funds are at risk. Severity is Medium because the trigger is unprivileged and nearly free, and it blocks the product's primary entry and exit path.

**Recommendation:** add `receive() external payable { if (msg.sender != address(router)) revert Unauthorized(); }` to the vault and the gateway; the ETH then sits inert. Keep router mocks with `refundETH` semantics and keep the regression tests.

## N-02 — an unpayable disputer makes a dispute unsettleable and blocks the quarter

**Locations:** [IndexController.sol](../src/IndexController.sol) lines 130, 140–153 and 208–214. OWASP area: denial of service.

UMA pays a disputed assertion's bonds at settlement. The asserter is paid if the claim is true; otherwise the payout goes to a `disputer` address that the disputing caller chooses. The bond currency is USDC, and Base USDC refuses transfers to blacklisted addresses. That includes the USDC contract itself: `isBlacklisted(USDC)` returns true on Base. If a payout goes to such an address, `settleAssertion` reverts every time. The controller keeps a pending proposal as the quarter's only slot until it settles.

**Attack:** at the start of a quarter, an attacker contract calls `propose` with a false basket. In the same transaction it calls `disputeAssertion(id, USDC)`, so no honest party can dispute first.

- The DVM correctly rejects the claim, but settlement can never pay the disputer.
- `settle` then reverts permanently, and `propose` reverts with `ProposalUnavailable` for the rest of the quarter.
- The cost is two bonds: 2,000 USDC at the deployment default, locked permanently in UMA.
- The attacker must be the quarter's first proposer, which a priority fee can usually buy. The attack can repeat every quarter.

**Reproduction:** `testAudit2UnpayableDisputerBlocksQuarterPermanently` uses the live OOv3, Finder, Store, whitelists and USDC; only the bridged DVM vote result is mocked. `testAudit2ControlOrdinaryDisputerSettlesAndReopensQuarter` runs the same flow with an ordinary disputer. It settles false, pays the disputer 1,500 USDC and reopens the quarter.

The same lock-up follows if a griefer disputes an honest proposal, names an unpayable disputer and the DVM resolves false. N-04 makes that outcome more likely.

**Recommendation:** let a new proposal replace a pending one whose UMA assertion has been disputed. Only the quarter's latest proposal is executable, so a later true resolution of the old one is harmless; this also resolves L-01. A time limit on pending proposals is an alternative. A bond currency with no blacklist, such as WETH if UMA whitelists it on Base, removes this lever but not ordinary dispute delays.

## N-03 — one assertion can rewrite the whole basket

**Locations:** [IndexController.sol](../src/IndexController.sol) lines 54, 133–137 and 243–256. OWASP area: business logic and governance.

`propose` only requires seven positive ratios that sum to 1e18. `execute` then drives the vault to those ratios. The only limits are the 50 bp loss allowance, the locked-backing floor and a nonzero balance per stock. The bond floor is a fixed immutable amount, and UMA does not monitor Base.

Legitimate quarterly changes are small. Quantity ratios are proportional to shares outstanding divided by the B20 multiplier; Alphabet also includes the GOOG/GOOGL price ratio. They therefore move only with buybacks, issuance and dividends. A false assertion faces no such limit.

**Reproduction:** `testAudit2UnchallengedFalseAssertionConcentratesIndexAndLeaksValue` accepts six ratios of one wei each. A caller with no role sells six constituents down to the locked floor and buys the seventh through its own venue. The index ends with 99.99% of NAV in one stock. The venue keeps $299.97 of the $70,000 NAV, or 0.43%.

Holders can still exit in kind, but they receive the distorted basket until a correct proposal is accepted and executed in a later quarter, subject to M-03. At moderate TVL the value an attacker can move or extract exceeds the 1,000 USDC bond, and the bond does not grow with TVL.

**Recommendation:** bound each quarter's change on chain. For example, require every target ratio to fall within a small relative band of the vault's current quantity ratio; that check needs no oracle. Route larger changes through a slower path with longer liveness. Size the bond to exceed what one execution can move or extract, and revisit it as TVL grows.

## N-04 — the claim is hard for DVM voters to resolve

**Location:** [IndexController.claim](../src/IndexController.sol) lines 164–194.

UMIP-191 tells voters to return false when a claim "cannot be unambiguously resolved". To confirm a true proposal, voters must:

- find the methodology from its Keccak-256 hash alone,
- decode a hex-encoded evidence URI, and
- reproduce 18-decimal integer ratios under a specific rounding rule within the voting period.

The claim also resolves false if the evidence is unavailable at vote time.

A griefer who disputes an honest proposal receives the asserter's bond, minus the 50% burned fraction, if voters return false. That is a 500 USDC profit at the default bond. The quarter is delayed, or blocked permanently in combination with N-02.

**Recommendation:** put a content-addressed methodology URI and the observation file's SHA-256 digest in the claim as validated plain text, restricted to a safe character set. Publish a one-command verification, and keep the evidence pinned for the whole resolution window.

## N-05 — USDC can be made a dependency of nearly every exit

**Locations:** [M7CapVault.sol](../src/M7CapVault.sol) lines 126–133 and 149–154.

`quoteRedeem` includes a pro-rata USDC leg whenever the vault holds USDC. A donation of 1,000 raw units, or $0.001, gives every redemption of at least 0.1% of supply a nonzero USDC transfer. The 1 bp residual-cash allowance leaves such dust after rebalances anyway.

If Circle pauses USDC or blacklists the vault, those in-kind redemptions revert. This adds USDC's issuer to the D-01 dependency set.

**Recommendation:** resolve this together with the D-01 decision. One option that covers both is to let a redeemer explicitly forgo named legs, leaving the forgone amounts to the remaining holders. Because the redeemer consents, this avoids D-01's concern about silent forfeiture.

## N-06 — execution plans are fragile (Informational)

`Swap.amountIn` is absolute. Any mint, redemption or donation between quoting and inclusion changes the vault's balances but not the plan.

- `testAudit2InKindRedeemBetweenPlanningAndExecutionInvalidatesPlan` shows a 40% in-kind redemption turning a valid plan into `TargetDeviation`. Re-minting the shares restores it.
- `testAudit2SmallUsdcDonationTripsResidualCashCheck` shows that $15 donated to a $70,000 vault fails a zero-trade execution with `ResidualCash`.

Without a public mempool this is mainly a reliability problem, but it compounds M-03's narrow execution windows. Express legs relative to current balances, or compute the plan on chain in the executing transaction.

## N-07 — deployment binding is only checked in simulation (Informational)

`Deploy.s.sol` predicts the vault's address from the deployer nonce and checks the match only in the simulation. If a nonce is used between simulation and broadcast, the controller can end up bound to an empty valuation address or the wrong vault. Nothing on chain detects this.

Have the vault constructor require `IndexController(controller_).vault() == address(this)`, check that `valuation` has code, and add a post-broadcast verification step. The script also assumes an externally owned deployer account.

## N-08 — monitoring does not detect the new signals (Informational)

`watch_index.py` reports that an assertion is disputed but not whether USDC can pay its disputer. It does not check the router's ETH balance. It also trusts the controller's stored ratios without comparing the assertion's identifier, liveness, asserter or claim bytes. Alert on a disputer that USDC blacklists and on a nonzero router ETH balance.

## N-09 — gas, clarity and unrecoverable transfers (Informational)

- The vault's `assets` array and Valuation's `assets`, `feeds`, `tokenUnits` and `feedUnits` never change after construction. Immutables would save a storage read on every access.
- The gateway calls `vault.assets(i)` repeatedly in each operation. Caching the addresses as immutables at construction would avoid those external calls.
- The `ratios[i] > 1e18` check is implied by positivity and the exact sum.
- Tokens sent to the controller or the gateway, and shares sent to the vault or to `address(1)`, cannot be recovered. This is by design; document it for integrators.

## Re-assessment of the first review

- **M-01 (fixed): the fix is correct.** Rounding mint inputs up and redemption outputs down keeps every per-share backing ratio from falling, so ordinary flows cannot breach the floor. A terminal exit leaves `ceil(B·L/S)` of each stock, which is off by less than one raw unit against at least 10,000. USDC has no floor, but its residual after a terminal exit is at most one raw unit. The invariant campaign found no counterexample.
- **M-02: raise to High.** Required turnover is usually far below the 50 bp allowance (see N-03), so nearly all of the allowance is available to whoever executes first.
  - An executor can create a pool at any unused enabled tick spacing. Only pairs that already have a legacy-factory pool need the factory owner.
  - The executor provides the only liquidity and routes 14 round-trip legs through that pool in one transaction, with flash-borrowed capital.
  - Such pools already exist for constituents on the factory the contracts trust. AAPLc/USDC at tick spacing 200 has zero active liquidity at the minimum tick. AMZNc/USDC at tick spacing 1 and NVDAc/USDC at tick spacing 200 are thin.
  - At $1M NAV the extraction is up to $5,000 per quarter, about 2% a year.

  In addition to the first review's advice, pin the seven canonical pools in the vault and bound the loss by the required turnover.
- **M-03:** agreed.
- **L-01: raise to Medium.** N-02 turns "blocked until resolution" into "blocked for the whole quarter" at a fixed cost. The same fix addresses both. Even an ordinary dispute on Base takes days, because the vote happens on the mainnet DVM.
- **D-01:** agreed. Add USDC to its scope, per N-05.
- **D-02:** agreed.

## Verified properties

- **Stateful invariants** (`test/Audit2Invariant.t.sol`): the review ran 256 runs at depth 100, or 25,600 calls per invariant, with zero reverts. The committed profile runs 128 × 64. No violation was found:
  - per-share backing never fell across in-kind and gateway flows, donations and share burns;
  - minting and immediately redeeming never returned more than was paid;
  - every share was accounted for, and the locked floor held;
  - the gateway never kept funds or spent more than `maxUSDCIn`.
- **Calendar:** `quarterAt` matches an independent Gregorian algorithm at both ends of every day from 1970 to 2399, and on 20,000 fuzzed timestamps up to year 9999.
- **UMA integration:** the controller pays the bond and UMA refunds the proposer. Disputed assertions later resolved true are accepted. One pending proposal per quarter prevents assertion-ID collisions, and `ASSERT_TRUTH2` is used explicitly.
- **Partial fills cannot leak value.** Balance deltas check exact-input legs. On exact-output swaps without a price limit, the router itself requires the full output.
- **Corporate actions:** B20 balances do not rebase. Splits and dividends move the multiplier, and the total-return feed stays continuous. Accepted quantity ratios therefore stay valid across corporate actions, and the registry pause blocks execution while one is in progress.
- **Off-chain tools:** the compiler's quarter ID and ratio normalization match the contract's rules. The watcher decodes OOv3's assertion layout correctly.
- **Reentrancy:** no path was found. B20 tokens and USDC have no transfer hooks, router callbacks go to the router, and every state-changing entry point is `nonReentrant`.

Checked and dismissed: first-depositor inflation, gateway donation theft, read-only reentrancy, UMA assertion-ID collisions, settling proposals from earlier quarters, the `Execute` script's `int24` bound, and corporate actions invalidating accepted ratios.

## Limits

- Base's Foundry build was not available during the review, so no new test executed native B20 code; the review's fork tests use USDC/WETH pools and synthetic stock tokens. The native tests have run since and pass.
- N-02's fork tests mock the DVM vote.
- Extraction amounts use modeled venues, not live pool depth.
- The Python tools were reviewed only for consistency with on-chain rules.

## Reproduce

```sh
make check
forge test --match-contract 'Audit2' -vv
BASE_FORK_TEST=true BASE_RPC_URL=https://base-rpc.publicnode.com \
  forge test --match-contract Audit2ForkTest -vv
```

The fork tests passed at Base block 51,833,451 with ordinary Forge 1.5.1 when this review was written. `make check` then passed with 74 Solidity tests, 5 opt-in skips and 20 Python tests. After remediation the same commands run the converted regression tests; the fork regressions passed at Base block 51,835,900.
