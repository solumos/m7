# M7CAP security review — 2026-09-26

## Scope and conclusion

Reviewed commit [`ac11b0930af0a778a0d37a90b49ede5add359df4`](https://github.com/solumos/mag7/tree/ac11b0930af0a778a0d37a90b49ede5add359df4): all custom contracts and interfaces, deployment/maintenance scripts, observation compiler, preflight, monitor, methodology, and tests. This revision includes a fix for **M-01 only**. This is an internal, AI-assisted review with independent parallel review passes, not an external audit firm's attestation or formal verification.

**Do not treat the stack as ready for public deposits.** No unbounded theft or unrestricted administrator withdrawal was demonstrated. We did reproduce material tracking drift, avoidable bounded rebalance losses, and unavailable rebalancing under normal oracle behavior. Issuer transfer controls can also prevent every ordinary withdrawal. Passing tests do not resolve those design risks.

| ID | Severity / category | Finding | Status |
| --- | --- | --- | --- |
| M-01 | Medium — index correctness | Near-empty redemption changes the basket that later deposits amplify | Fixed; regression tests added |
| M-02 | Medium (re-rated High in review 2) — economic execution | Unnecessary trades can consume the entire 50 bp portfolio loss allowance | Fixed after review 2; regression tests |
| M-03 | Medium — availability | Healthy stock feeds can be too old throughout the permitted execution window | Fixed after review 2; replay evidence |
| L-01 | Low (re-rated Medium in review 2) — funded griefing | A disputed first proposal prevents parallel valid proposals | Fixed after review 2; regression tests |
| D-01 | High impact — conditional design risk | One transfer-frozen stock blocks withdrawal of otherwise healthy assets | Fixed for in-kind exits after review 2 |
| D-02 | Conditional Medium — policy integration | Underlying address exclusions do not carry through to M7CAP holders | Fixed after review 2 (enforcement chosen) |

**Remediation status.** After the [second review](AUDIT-2.md), the code was changed to fix every open finding. The sections below describe the original code at `ac11b09` and remain the record of what was found. The current behavior and its tests are:

- **M-02.** `execute(deadline)` takes no trades from the executor; the controller plans every leg. Pools are pinned per stock, each stock is only sold or only bought, and each leg's minimum output is its oracle value less 1%. Loss is bounded by 1% of traded value, not 50 bp of NAV. Regressions: `testExecutorCannotSpendLossAllowanceOnUnnecessaryTrades`, `testLossIsBoundedByNeededTurnoverThroughAnExtractiveVenue`, and `test/ControllerPlanner.t.sol`.
- **M-03.** Every stock price must be at most 25 h old and at least one at most 1 h old, weekdays 15:00–20:00 UTC. A replay of ten recent weekdays found 96% of slots usable, against under 1% before (see [INTEGRATION.md](INTEGRATION.md)). Regression: `testQuietButHeartbeatConformingFeedNoLongerBlocksExecution`.
- **L-01.** A disputed proposal, or one still unsettled a day after its challenge window, no longer blocks a replacement; the first to settle true is executed. Regression: `testDisputedProposalNoLongerBlocksAReplacement`.
- **D-01.** `redeemBasketWithClaims` delivers every movable leg and turns the rest into claims withdrawable later; the gateway path stays atomic. Tests: `test/VaultClaims.t.sol`.
- **D-02.** M7CAP transfers, mints, redemptions and claim withdrawals check the stocks' B20 transfer policies. Regression: `testStockAddressExclusionPropagatesToReceiptHolders`; matrix in `test/VaultPolicy.t.sol`.

The stack is still not ready for public deposits. It has had no external audit, and the native Base fork tests have not been re-run against the current code. Residual risks are listed in the second review.

Severity considers impact and prerequisites. Medium covers bounded value loss, material index-tracking failure, or maintenance unavailability. Low covers a costly, limited disruption. D-01's high impact requires an issuer transfer pause or policy rejection; it is not evidence that an arbitrary user can freeze the vault. D-02 is a defect only if receipt-level eligibility enforcement is a product requirement. No critical issue was confirmed within this scope.

## Method and trust model

The review followed the relevant [OWASP SCSVS](https://scs.owasp.org/SCSVS/) control areas: architecture and trust boundaries, business logic/economics, authorization, external interactions, arithmetic, and denial of service. It combined manual call-path review, independent subsystem reviews, static analysis, existing fuzz/unit tests, targeted adversarial reproductions, and primary-source integration checks. This is a selected control review, not a claim of exhaustive SCSVS certification.

The central invariants were:

1. Minting receives the required backing before issuing shares and cannot dilute existing per-share component backing.
2. Redemption burns only the caller's shares, rounds assets down, and either completes all transfers or rolls everything back.
3. A gateway caller cannot spend or withdraw previously donated gateway balances; the aggregate input/output limit applies atomically.
4. Only the controller can rebalance; share supply is unchanged and all postconditions use one price snapshot.
5. A quarter executes at most once and cannot execute before accepted assertion settlement.
6. Normal exit/refill sequences must not amplify raw-unit dust into a materially different index.

| Boundary | Assumption or authority |
| --- | --- |
| Seed funder | Chooses the initial funded basket; initial market-cap correctness needs separate review |
| Users and executors | Untrusted; executors can currently choose swap quantities, minima, and factory-valid routes |
| Proposers and UMA | Ratios are optimistic assertions; independent challengers must act before the 72-hour expiry |
| Valuation | Chainlink and issuer registry observations must remain correct and available; the loss bound is in reference-price units |
| B20 and USDC issuers | External transfer controls and asset changes are outside the vault's authority |
| Base and venue | Native B20 behavior, sequencer, router, factory and pools are external dependencies |
| Operations | Snapshot truth, source publication, live monitoring, dispute funds and transaction submission are not supplied by a running service in this repository |

## M-01 — depletion rounding changes future allocations

**Original locations:** [vault constants](https://github.com/solumos/mag7/blob/ac11b0930af0a778a0d37a90b49ede5add359df4/src/M7CapVault.sol#L19), [mint quote](https://github.com/solumos/mag7/blob/ac11b0930af0a778a0d37a90b49ede5add359df4/src/M7CapVault.sol#L91), [redemption quote](https://github.com/solumos/mag7/blob/ac11b0930af0a778a0d37a90b49ede5add359df4/src/M7CapVault.sol#L119).

The original permanent stake was only `10^12 / 10^21 = 10^-9` of the seed. If all circulating shares were redeemed, each remaining stock balance became `ceil(B[i] * locked / supply)`. Ordinary small seed positions could consequently all become one raw unit, regardless of their original proportions.

The reproduction seeded 1, 2, …, 7 stock tokens, redeemed every circulating share, and observed one raw unit of each stock. A subsequent 1,000-share mint required ten whole tokens of each stock. The first-to-last quantity ratio changed from 1:7 to 1:1 without a rebalance. The new holder paid for actual backing, so this was not a demonstrated theft; it was a failure of the tracking product.

**Fix:** lock 10 of the initial 1,000 shares and require, for every stock:

```text
floor(balance[i] * LOCKED_SHARES / totalSupply) >= 10,000 raw units
```

Enforce this at bootstrap, after rebalancing and before issuance. Redemptions do not get an additional precision restriction. A partial seizure below the floor stops issuance while holders can still redeem whatever transfers remain possible. At bootstrap the condition requires at least 0.01 of each eight-decimal stock token. The seed receiver gets 990 M7CAP; approximately $10 of a $1,000 seed remains permanently locked.

Why this addresses the cause: with rounded-up mint inputs and rounded-down redemption outputs, each component's `B/S` cannot decrease through ordinary mint/redeem operations. Therefore those operations preserve the reserve floor. At terminal redemption, rounding the projected reserve upward adds less than one raw unit against at least 10,000 units, or less than one basis point of relative component error. A refill scales that bounded remainder, rather than an arbitrary one-unit basket. This is a bound for the terminal operation; it is not a promise of zero rounding, cumulative lifetime tracking accuracy, or protection against intentional donations.

The original audit reproduction is converted into a regression in [AuditVaultGateway.t.sol](../test/AuditVaultGateway.t.sol). Additional vault tests cover non-divisible balances, repeated exit/refill, inadequate bootstrap, rebalance rollback and partial seizure. Other audit findings remain unfixed.

## M-02 — an executor can deliberately spend the loss allowance

**Locations:** [IndexController.execute](../src/IndexController.sol), [M7CapVault.rebalance](../src/M7CapVault.sol). OWASP area: business logic/economics.

The contract checks final portfolio value and weights but does not restrict trades to required surpluses/deficits, forbid buying and selling the same stock, or require a no-op when the basket already meets the accepted target. A factory-valid pool is not necessarily good execution liquidity. Aerodrome permits pool creation at enabled, unused tick spacings, subject to restrictions where legacy pools already exist. [Factory source](https://github.com/aerodrome-finance/slipstream/blob/main/contracts/core/CLFactory.sol#L63)

**Reproduction:** `testUnnecessaryRoundTripsPayFull50BpsToVenueAndConsumeQuarter` in [AuditController.t.sol](../test/AuditController.t.sol) uses the real vault/controller with an honestly accepted unchanged target, current mock prices, and a funded modeled venue. A caller with no role executes fourteen unnecessary sell/buy legs. NAV falls from **$70,000 to $69,650**; the venue retains $350 of stock; the final ratios remain exact; the quarter is marked executed. The companion no-op test completes with zero trades and zero loss.

This stays inside the intended 50 bp ceiling; it does not bypass it. Extracting the value requires adversarial liquidity ownership or MEV positioning. The test demonstrates the accepted contract behavior, not a native Aerodrome exploit. At $1,000 NAV the ceiling represents about $5 per quarter under accurate reference prices, and grows with TVL.

**Remediation:** constrain each trade to the target's required surplus/deficit, prevent round trips within a batch, and require zero trades for an already compliant basket. Cap costs relative to necessary turnover as well as portfolio value. Reviewed pool selection reduces routing risk but does not eliminate LP-fee or MEV extraction by itself.

## M-03 — oracle freshness and execution hours conflict

**Locations:** [Valuation.sol](../src/Valuation.sol), constructor and `snapshot`. OWASP area: external dependencies/availability.

Every stock must have an update no older than one hour, simultaneously, between 15:00 and 17:00 UTC. The maximum age cannot be configured above one hour. Base documents stock updates at a 0.5% deviation or 24-hour heartbeat during market hours. A quiet stock can legitimately fail the vault's freshness condition all afternoon. [Feed behavior](https://docs.base.org/build-on-base/integrate-defi/list-tokenized-stocks)

**Reproduction:** `testHeartbeatConformingQuietFeedCanBlockEntireExecutionWindow` leaves one stock's last update at noon, refreshes all other feeds, and attempts execution every ten minutes from 15:00 through 16:50. Every attempt reverts despite the stock reading remaining younger than its advertised heartbeat.

This is a previously documented availability limitation, not evidence of malicious feed manipulation. It can delay or prevent the quarterly rebalance; ordinary quantity-based entry/exit is unaffected.

**Remediation:** choose a supported source and execution schedule with demonstrated joint availability, using historical observations of all seven feeds. Simply allowing 24-hour-old prices would weaken economic safety and is not a sufficient fix. The price-loss bound also remains a bound on reference NAV, not guaranteed executable market value.

## L-01 — a disputed assertion occupies the quarter's proposal slot

**Locations:** [IndexController.sol](../src/IndexController.sol), `propose` and `settle`. OWASP area: denial of service.

A pending first assertion excludes all other proposals until it is settled false. An honest dispute prevents a false rebalance but cannot allow a valid parallel proposal while dispute resolution is pending.

**Reproduction:** `testDisputedProposalMonopolizesQuarterUntilOracleResolution` keeps a modeled dispute unresolved for 30 days and confirms a replacement proposal still reverts. Resolving and recording rejection restores availability.

The 30-day duration is a test scenario, not a claim about UMA's normal resolution time. A rejected malicious proposer loses bond capital and must fund another attempt. The next calendar quarter has an independent slot. This is funded griefing and dispute coupling, not free indefinite denial of service.

**Remediation:** consider bounded concurrent bonded candidates with deterministic selection of a valid accepted result. Compare the extra state-machine complexity with the limited disruption before changing this design.

## D-01 — a transfer-frozen constituent locks healthy backing too

**Locations:** [M7CapVault.redeemBasket](../src/M7CapVault.sol), [USDCGateway.redeemToUSDC](../src/USDCGateway.sol). OWASP area: external interactions/availability.

If an issuer rejects transfer of one nonzero constituent from the vault, the complete redemption reverts, including transfers of the other six stocks. In-kind redemption does not escape this condition. The code has no partial redemption and deferred frozen-asset claim accounting. This compounds the affected stock's freeze into an inability to exit otherwise healthy backing.

Existing tests `testFrozenComponentRollsBackBurnAndEarlierTransfers` and `testBlockedConstituentMakesExitAtomic` reproduce this. This is an acknowledged design risk, not a new unprivileged freeze attack. A seized-to-zero component differs: zero transfers are skipped, allowing remaining assets to be redeemed.

Normal corporate-action **oracle** pauses should not be confused with a token-transfer freeze: Base documents that ordinary corporate-action processing leaves onchain transfers enabled. [B20 behavior](https://docs.base.org/build-on-base/integrate-defi/list-tokenized-stocks)

**Remediation:** decide whether resilient exits require proportional partial withdrawal with preserved claims on frozen components. Do not merely skip a failed transfer and burn the whole claim; that would forfeit user property. Otherwise disclose and explicitly accept the all-component exit dependency. This is a launch-level product decision.

## D-02 — stock restrictions do not apply automatically to receipt owners

**Locations:** [M7CapVault ERC20 inheritance](../src/M7CapVault.sol), [USDCGateway](../src/USDCGateway.sol), purchase recipients and cash-redemption path. OWASP area: authorization/trust boundaries.

B20 policies evaluate the transfer's sender, receiver and executor. In the gateway route those addresses are intermediaries, not the M7CAP beneficial owner. M7CAP itself inherits unrestricted ERC-20 transfers. [Policy semantics](https://docs.base.org/build-on-base/issue-rwa/restrict-transfer-initiators)

**Reproduction:** `testAuditStockAddressExclusionDoesNotPropagateToGatewayUser` configures a mock stock to reject one user's direct receipt. That user can still buy ten M7CAP with USDC and redeem back to USDC through permitted intermediaries; direct stock redemption fails. This assumes the stock-specific exclusion does not also prevent that user's USDC transfers. No production policy was modified.

The technical noninheritance is confirmed; it is not a legal determination. Secondary stock-token ownership is documented as permissionless subject to onchain address policies, while issuer redemption is a separate AP process. [Issuer/secondary-market distinction](https://docs.base.org/build-on-base/integrate-defi/list-tokenized-stocks)

**Remediation:** establish whether this wrapper must enforce recipient/holder eligibility. If required, apply it consistently to issuance, transfers and redemption; relying only on underlying transfers is insufficient. If unrestricted receipts are acceptable, record the decision and its issuer assumptions explicitly.

## Tool results, checks and limits

Baseline `make check` passed: **55 Solidity tests, 20 Python tests**, with two native-only tests skipped by ordinary Forge. Existing property tests use 512 fuzz runs. The final suite after adding the audit reproductions and rounding fix passes **65 Solidity tests and 20 Python tests**; the updated native Base gateway test also passes separately.

[Slither](https://github.com/crytic/slither) **0.11.6** completed successfully against the baseline with Foundry integration, filtering dependency/test/script paths. It emitted 78 detector results: 15 High, 16 Medium, 45 Low and 2 Informational. These are tool labels, not 78 confirmed vulnerabilities. Manual triage found:

| Detector | Count | Disposition |
| --- | ---: | --- |
| weak-prng | 3 | Calendar arithmetic; no random selection exists |
| reentrancy-balance | 12 | Guarded operations deliberately compare before/after balances; no demonstrated bypass under canonical dependencies |
| incorrect-equality | 5 | Calendar, zero-balance and zero-transfer checks are intentional |
| reentrancy-no-eth | 2 | Guarded controller entry points; no demonstrated exploit through status getters |
| uninitialized-local | 3 | Solidity zero initialization is intended |
| unused-return | 6 | Swap outcomes checked with actual balances; selected feed/value tuple fields intentionally omitted |
| calls-loop | 40 | Bounded seven/eight-asset or fourteen-trade loops; constituent availability risk recorded as D-01 |
| timestamp | 5 | Intended deadlines, oracle age and calendar gates; scheduling limitation recorded as M-03 |
| complexity / literal style | 2 | Informational, no exploit demonstrated |

Manual review did not identify a standard first-depositor zero-share attack, unbacked mint, gateway donation theft, persistent swap allowance, repeated same-quarter rebalance, or arbitrary asset-withdrawal path. Individual gateway sales use zero per-leg minima, but the caller's final aggregate minimum protects the entire atomic transaction; this is not independently an unbounded-slippage bug. CREATE nonce prediction correctly matches the deployment sequence and is checked by the script. The explicit `ASSERT_TRUTH2` avoids the deprecated UMA default.

The read-only integration check at Base block **51,831,293**, hash `0xc5c3d5cc303f78375dafc3e8c7e547af28bbf5343e7cfe0a1718cc8a5d0d99cf`, passed identity/integration reads and confirmed supported assertion identifier/collateral. Weekend stock freshness failed as expected. Read results do not prove execution availability or production eligibility.

The existing native Base fork tests previously exercised seven-stock gateway execution and real UMA submission/undisputed settlement at block 51,830,602. The audit's economic/policy/dispute reproductions use mocks for external conditions, explicitly identified above. Native disputed UMA resolution, selective native-policy rejection, later-leg rollback under native policy failure, and native-stock rebalancing are not established by those reproductions. Neither actual company-cap observations nor a running dispute service are supplied. UMA identifies Base as unmonitored by Risk Labs; the one-shot watcher is not a substitute for independent challenge operations. [UMA network support](https://docs.uma.xyz/resources/network-addresses)

Reproduce locally:

```sh
make deps
make check
forge test --match-contract 'Audit.*' -vv
uvx --from slither-analyzer==0.11.6 slither . \
  --filter-paths 'lib/|test/|script/' --exclude-dependencies \
  --json /tmp/mag7-audit-slither.json
python3 scripts/verify_base.py
```

Slither normally exits nonzero when detectors report results even if analysis succeeds; inspect the JSON `success` field and triage findings. The read-only preflight exits nonzero for stale prices. Audit tests for open issues intentionally assert the vulnerable behavior so they remain executable reproductions; they must be converted to regression assertions when those issues are fixed.

## Remediation validation

The M-01 patch changes only `M7CapVault.sol` in production code: the permanent reserve, the indexed `InsufficientLockedBacking` error, and precision checks at bootstrap, mint quotation and completed rebalance. Withdrawal calculations, gateway routes, controller logic and oracle policy are unchanged. The methodology document and its deployment hash are unchanged. No live deployment or user funds are involved.

- `make check`: **65 Solidity tests passed, 0 failed, 2 native-only tests skipped; 20 Python tests passed**. Formatting and contract-size checks passed.
- The full-exit/refill regression preserves the original 1:7 fixture instead of producing 1:1. A 512-run fuzz test exercises non-divisible positions and one to five complete exit/refill cycles, asserting the reserve floor and strict per-exit rounding bound.
- Bootstrap tests reject an insufficient final constituent and verify rollback of earlier transfers/allowances; the exact boundary succeeds. A two-leg rebalance that breaches the reserve floor fully rolls back. Partial seizure blocks issuance but allows every circulating share to redeem remaining backing.
- A separate reviewer inspected the patch and ran 40 relevant accounting, gateway, integration and audit tests successfully.
- The updated native seven-stock gateway test passed at Base block **51,830,602** with Base Foundry v1.1.0. Minting 100 M7CAP cost 70.000034 USDC; redemption returned 69.929989 USDC. This remains an equal-dollar routing fixture, not reviewed production index weights.

Reproduce that final native check with the official Base-aware `forge` binary:

```sh
BASE_FORK_TEST=true BASE_FORK_BLOCK=51830602 FOUNDRY_BASE=true \
  "$BASE_FORGE" test --match-contract BaseForkTest \
  --match-test testBaseNativeB20BootstrapAndUSDCRoundTrip -vv
```

M-02, M-03, L-01 and the two conditional design risks are still open. Address the rebalance-execution policy and resolve exit/eligibility requirements before a production launch; operate independent UMA challenge monitoring and obtain external review of the final release.
