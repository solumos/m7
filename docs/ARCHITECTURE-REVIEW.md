# M7 architecture review: decentralization

Date: 2026-09-28. Scope: the working tree based on `665c663`, including the fixes documented in [review 4](AUDIT-4.md), the five contracts, deployment configuration, and operating tools. This is an internal design review, not an independent audit, a proof of economic security, or a deployment approval. Priorities below describe architectural importance rather than newly demonstrated exploit severity.

## Verdict

M7 removes ongoing discretionary control by its own developers. That is a strong foundation. It does not provide end-to-end decentralization: the chosen assets, pricing, execution venue, and chain retain external dependencies and control. Removing an M7 administrator cannot remove those powers.

The achievable goal for this product is **an ownerless index over issuer-controlled assets, with open participation, independently runnable maintenance, and direct exits subject to the assets' rules**. If the requirement instead means that nobody can freeze, seize, or restrict the underlying assets, the present asset universe cannot satisfy it. Synthetic equity exposure would be a different product with its own collateral, liquidation, and oracle assumptions, not a simple fix.

The largest avoidable architectural weakness is permanent coupling between custody and one execution venue. The largest operational weakness is assuming that permissionless calls will attract someone to run them. Neither is fixed by adding a DAO, multisig, or emergency administrator.

**Firm project constraint:** no ongoing discretionary M7 administrator. Recommendations must not introduce an upgrade authority, guardian, discretionary asset or oracle selector, or exclusive executor. Keepers and liquidity providers may execute only within the same immutable, publicly available rules; they cannot change the constituents, target methodology, or safety bounds. Where safe recovery cannot be expressed in those rules, accept halted maintenance, available in-kind exits, and holder-initiated migration. This records the project's architectural requirement, not a conclusion about the product's legal classification.

## What to preserve

- **Immutable custody and accounting.** No M7 owner can change constituents, upgrade the vault, withdraw backing, or redirect rewards. The bootstrapper's authority ends after funded initialization. The seed receiver's large initial holding is economic concentration, not special governance authority.
- **Proportional in-kind entry and exit.** These paths use actual balances rather than an oracle NAV. An oracle outage or unavailable DEX therefore need not prevent holders from exiting in kind.
- **Open, constrained maintenance.** Anyone can call the controller; it derives the trades and enforces bounds. Callers do not submit arbitrary vault calls or discretionary target weights.
- **Replaceable peripheral tools.** The gateway and lens have no special vault privileges. Anyone can deploy another gateway, including one that acquires the basket through different venues, or replace the display and transaction interface. That does not change the core controller's pinned routes.
- **Separation of deferred claims from circulating backing.** New holders cannot silently acquire assets already owed to earlier redeemers, and rebalancing cannot intentionally spend those reserves.

Evidence: [M7Vault](../src/M7Vault.sol), [IndexController](../src/IndexController.sol), [USDCGateway](../src/USDCGateway.sol), and [M7Lens](../src/M7Lens.sol).

## Authority and failure boundaries

| Dependency | Who or what determines behavior | Consequence for M7 |
| --- | --- | --- |
| M7 vault and controller | Immutable deployed code; anyone may invoke public functions | No privileged repair or parameter change; a defect can require voluntary migration |
| Stock tokens and policies | Issuer roles and applicable policy rules | Transfers can be restricted and holdings seized; one constituent's policy can restrict the receipt |
| USDC | External token administration | Cash transfers and USDC execution routes can become unavailable |
| Valuation | Configured feeds, issuer reference-price state, sequencer feed, immutable freshness rules | Unavailable inputs stop resets; accepted incorrect inputs can produce incorrect targets |
| Execution | Pinned router, factory, stock/USDC pool configuration, liquidity providers, fee settings | Rebalancing can stop when the required route is no longer executable |
| Transaction inclusion | Base and its sequencing/settlement mechanisms | Contract permissions do not guarantee timely inclusion or neutral ordering |
| Maintenance | Voluntary callers paying gas | Without an economically motivated or subsidized caller, weights continue drifting |
| User access | Public RPCs, software distribution, interfaces | A hosted service can disappear; direct use must remain practical |

The B20 interface exposes issuer pause, seizure, and policy administration. M7's policy checks compose those restrictions rather than eliminating them. Seven stocks from the same provider do not diversify that operational dependency. [B20 interface](https://github.com/base/base-std/blob/main/src/interfaces/IB20.sol)

Circle's EVM implementation includes upgrade, pause, and blacklist authorities. Replacing only the USDC route would leave the stock-token dependencies intact. [Circle contracts](https://github.com/circlefin/stablecoin-evm)

Base documents a single active sequencer and an L1 transaction-submission path. That distinction matters: ordering and timely execution remain dependencies even though the rollup has other validation and inclusion mechanisms. This review does not establish every current chain upgrade authority or signer set. [Base protocol overview](https://docs.base.org/specifications/base-protocol/overview)

## D-01 — Asset-level decentralization is a product constraint

**Priority: fundamental goal decision.** The wrapper cannot guarantee unrestricted ownership or redemption of assets whose issuer can intervene. `M7Vault._update` also checks sender, receiver, and executor policies across all seven stocks for receipt transfers and minting. Eligibility is effectively the intersection of their permissions, not an unconditional ERC-20 transfer right.

Removing receipt policy checks would not make the underlying basket permissionless. It could instead circulate receipts to people or contracts that cannot obtain the underlying assets. Keep the policy boundary explicit rather than describing M7 as universally composable.

**Recommendation:** define decentralization as absence of additional discretionary M7 control, and publish the inherited authorities. If issuer independence is mandatory, reconsider the product's assets before investing in a different wrapper architecture.

## D-02 — Immutable execution dependencies can permanently disable resets

**Priority: high; address before claiming durable autonomous operation.** [M7Vault's constructor and `_swap`](../src/M7Vault.sol) bind execution to a router/factory and one pool configuration per stock. [IndexController](../src/IndexController.sol) fixes sizing, the approximately $10,000 maximum leg, 30-minute cooldown, execution window, TWAP check, slippage, and reward rules. There is no route replacement or smaller caller-selected tranche.

If a pinned pool loses sufficient liquidity, moves outside acceptable pricing, or becomes uneconomic, repeated calls can revert even when another venue could fill the basket. Smaller public entry/exit adapters cannot repair the core rebalance path. The five-hour daily window and cooldown allow at most ten successful tranches per eligible day: roughly $100,000 of sales per stock per day at the configured cap, before failed calls and price gates. This places a finite capacity on a system that has no corresponding cap on deposits.

An immutable address also does not guarantee immutable external economics. Slipstream's upstream factory implementation exposes fee-manager and fee-module changes while making its pool implementation immutable. This supports a fee-control concern, not a claim that the factory can arbitrarily replace pool code. [Slipstream factory source](https://github.com/aerodrome-finance/slipstream/blob/main/contracts/core/CLFactory.sol)

Read-only calls at Base block **51,895,191** found that the configured factory `0xf8f2eB4940CFE7d13603DDDD87f123820Fc061Ef` returned the same nonzero address, `0xe6a41fe61e7a1996b59d508661e3f524d6a32075`, for `owner()`, `swapFeeManager()`, and `unstakedFeeManager()`. It also returned nonzero swap and unstaked fee modules. These are public role observations, not identification of their beneficial controllers or verification of their signer thresholds. Upstream source was not matched byte-for-byte to the deployment in this review.

**Recommendation:** for a long-lived autonomous design, separate the immutable rebalance rules from where execution occurs. A bounded settlement interface can let any eligible filler deliver the required outputs and receive only the permitted inputs. The filler can source liquidity elsewhere while the protocol verifies assets, amounts, reserves, supply, price bounds, and progress. Keep arbitrary calls and persistent approvals out of the custody layer; a team-maintained router allowlist would reintroduce control.

That is a separately specified and audited protocol revision, not a safe one-line patch. It does not remove oracle or issuer trust. If retaining the current simpler version, explicitly accept that venue failure can leave a static, redeemable basket requiring voluntary migration.

Do not merely add `maxTradeSize` under caller control. A caller could repeatedly select negligible progress and consume the shared cooldown. Adaptive sizing needs meaningful progress requirements, reward rules that resist splitting, and tests for cooldown monopolization and temporary changes in supply.

## D-03 — Permissionless maintenance is not economically assured maintenance

**Priority: high.** [Maintain.s.sol](../scripts/Maintain.s.sol) lets anyone submit one tranche. [The runbook](DEPLOYMENT.md#phase-4-the-quarterly-reset) explicitly relies on the operator while rewards are too small. [The monitor](../scripts/monitor.py) observes and alerts; it does not execute resets.

At a $125 NAV and 10% one-way turnover, the nominal 5 bp reward is approximately **$0.00625**, before rounding or other execution details. That is not a credible unconditional promise that an unrelated operator will pay transaction and monitoring costs. At larger sizes, costs, reverts, competing callers, and the $25 reward cap still matter. This is an incentive gap, not a privileged caller restriction.

**Recommendation:** ship an independently runnable keeper with simulation, retry/backoff, cost limits, and no project credential dependency. Demonstrate that a fresh operator can finish a reset after the team's infrastructure is turned off. Anyone's keeper key should control only that operator's gas funds.

Then measure profitability over relevant sizes, liquidity, volatility, and fee conditions. If small-vault maintenance requires support, a separately funded, permissionless sponsor mechanism is preferable to a privileged executor. Any additional reward mechanism needs bounded payout and splitting/grinding protection; never reimburse an uncapped caller-selected gas price. A sponsor fund can run out, so disclose the remaining funding assumption.

Preserve the existing safe failure: when nobody calls, the basket retains its quantities and users can attempt direct redemption. Do not promise a quarterly reset independent of participation and executable markets.

## D-04 — Oracle gates provide bounded trust, not independent truth

**Priority: high trust assumption; medium redesign priority.** [Valuation.snapshot](../src/Valuation.sol) accepts stock prices up to 25 hours old, provided at least one is within an hour, during the weekday UTC window. This can deliberately admit six older prices alongside one fresh price. It is an availability heuristic, not proof that all seven prices describe the same live market.

Chainlink's Coinbase feed model incorporates issuer-supplied tokenization adjustments and corporate-action pauses. Multiple stock feeds do not remove that shared data dependency. [Coinbase equity-feed model](https://docs.chain.link/data-feeds/tokenized-equity-feeds/coinbase)

The same accepted snapshot sets targets and measures before/after NAV. Therefore, a bad but accepted price can pass the valuation-based loss bound. The pool's own historical price adds a useful constraint but is not an independent guarantee of fair equity value. A wrong feed does not necessarily make every harmful trade revert.

Pinned feeds, registries, and freshness rules can also outlive their external support. Feed retirement can stop maintenance while direct in-kind redemption continues. Current code has no permissionless feed replacement mechanism.

**Recommendation:** retain oracle-free in-kind exits and explicitly document this trust boundary. Do not add spot-price fallback or a team-signed emergency price. Introduce multiple sources only if they provide meaningful independent information and have a precise disagreement rule. Otherwise, immutable fail-closed pricing plus voluntary migration is simpler and more defensible than a cosmetic oracle quorum.

## D-05 — Exit and loss allocation need precise promises

**Priority: high product specification; medium implementation follow-up.** The partial redemption path is a valuable architectural feature, but it preserves an entitlement rather than guaranteeing eventual payment.

Three boundaries deserve explicit treatment in [M7Vault](../src/M7Vault.sol):

1. `quoteRedeem` reads every constituent's `balanceOf` before delivery begins. A normal transfer pause can be deferred; an asset whose balance interface becomes unusable can block the whole quote and both redemption paths. The same applies to an unusable recipient balance read during delivery. The code does not isolate every possible dependency failure.
2. Claims are senior to circulating-share backing. If assets are seized below total reserved claims, later claim withdrawals depend on what remains; successful withdrawals can exhaust it before other claimants withdraw. No pro-rata shortfall allocation or insurance mechanism exists.
3. Every rebalance batch requires all reserves to be covered. Reserve insolvency can therefore stop resets across the basket. An ordinary freeze with fully backed reserves is a different state and should not be conflated with insolvency.

**Recommendation:** specify these loss and availability rules before launch and add focused failure-state tests where coverage is missing. Decide explicitly whether first-come withdrawal under claim insolvency is acceptable. Changing it to proportional loss sharing requires a different claim-accounting design, not an administrator deciding who gets paid. Do not silently treat an unreadable token balance as zero; that can destroy rightful entitlements.

Migration must be holder-initiated. A holder can redeem transferable assets and opt into a new deployment; existing deferred claims remain obligations of the original vault. Neither a migrator nor a new receipt can make seized assets reappear. Preserve that limitation in any migration UI.

## MEV and execution fairness

The system is **not MEV-immune**. The controller's TWAP, trade-size, and oracle-relative loss checks reduce opportunities; they do not prove that all allowed executions are economically fair. A caller can prepare the market and invoke a public reset itself, without observing someone else's pending transaction. Sustained price influence and liquidity ownership remain relevant.

Bounds apply per tranche and relative to the accepted prices. They are not a fixed dollar loss budget per quarter or a proof of eventual convergence while targets move. The USDC gateway has a separate protection model: caller-selected aggregate spending/proceeds limits, without the controller's TWAP gate or trade cap.

A competitive settlement or auction design may improve execution quality, but it must keep participation open and be evaluated for censorship, failed fills, ordering, and oracle timing. Requiring a team's private relay or exclusive solver would add an operator dependency. The existing sandwich regressions establish behavior in their tested states only; see [review 3](AUDIT-3.md) and [review 4](AUDIT-4.md).

## Non-standard aspects integrators must understand

| Feature | Consequence |
| --- | --- |
| Multi-asset ERC-20 receipt; deliberately not ERC-4626 | Integrators need basket-specific quotes and transaction logic |
| Policies checked across seven stocks, including the immediate executor | Wallet support for ERC-20 does not establish DEX, bridge, or lending compatibility |
| Locked seed shares and supply-adjusted stock precision floors | Some capital stays permanently locked; a floor-constrained stock can remain overweight |
| Partial redemption with separate, non-transferable claim records | Receipt balances alone do not represent all of a user's outstanding entitlements |
| Quarterly progress through multiple price snapshots | Completion is conditional, and the final basket need not match the first tranche's target quantities |
| Dust exceptions to equal-weight completion | “Equal weight within 0.1%” has explicit precision and minimum-trade exceptions |
| Lens returns old but structurally valid prices with timestamps | Display NAV is not automatically a safe lending or liquidation oracle |

These choices can be justified. Their unusual behavior must be part of integration documentation and tests rather than hidden behind “standard ERC-20.”

## Recommended sequence

1. **State the attainable decentralization promise.** Keep the ownerless vault, open controller, direct basket API, and voluntary migration. Publish inherited authorities and conditional exit rules. No governance token or guardian is needed for these improvements.
2. **Prove independence from the team.** Provide the runnable keeper, reproducible deployment record, ABIs, and direct mint/redeem/claim instructions. Run the disappearance exercise below and measure keeper economics. Static frontends can be mirrored independently.
3. **Resolve permanent venue coupling before making a durability claim.** Specify bounded permissionless settlement and safe adaptive progress, or explicitly launch a fixed-venue version whose failure mode is in-kind exit and voluntary migration. The stronger autonomy goal favors the former, with a fresh audit of that change.
4. **Specify failure economics.** Document claim seniority and insolvency, precision-floor departures from equal weights, and oracle-failure behavior. Avoid adding privileged recovery controls to paper over unresolved rules.

## Acceptance exercises still needed

These are proposed acceptance criteria, not claims that this review executed them.

| Exercise | Required evidence |
| --- | --- |
| Turn off team server, frontend, and preferred RPC | Independent operator completes maintenance; holder can mint, redeem, and claim using published artifacts and another RPC |
| Remove liquidity from a pinned venue | Current version fails safely and supports in-kind exit; a revised settlement version makes bounded progress through another eligible source |
| Raise external fees or suspend reference pricing | No unsafe fallback or unauthorized asset release; reason for stalled maintenance is observable |
| Make one feed accepted but economically wrong | Quantify the loss possible despite current checks; do not assume the oracle-relative bound proves fairness |
| Freeze, seize, or break one constituent's reads | Distinguish deliverable legs, deferred claims, total quote failure, and reserve insolvency |
| Run independent keepers across small and large NAV | Include gas, failed calls, competition, time to completion, and funding exhaustion |
| Attempt negligible fills, reward splitting, and temporary supply changes | A revised flexible execution design cannot monopolize cooldown or earn disproportionate rewards |
| Migrate while claims remain outstanding | Holder opts in, transferable assets move correctly, and old claims remain identifiable and withdrawable when eligible |

## Evidence and limitations

This review inspected the current contracts, methodology, deployment instructions, monitor, and maintenance script; consulted the linked primary integration sources; and made read-only Base calls. It did not broadcast transactions or modify contract behavior.

The prior hardening run passed 123 Solidity tests, 31 Python tests, and nine native fork cases under each of Beryl and simulated Cobalt rules, as recorded in [review 4](AUDIT-4.md). Those results are reused context, not newly executed architecture acceptance tests. They do not establish future liquidity, oracle correctness, keeper profitability, issuer behavior, or uninterrupted operation.

The role reads establish active factory role addresses at the stated block only. Full external governance tracing, signer independence, custody arrangements, and matching all upstream deployed code remain outside this review. An `owner()` call on the configured issuer oracle registry reverted; that does not establish absence of administration.
