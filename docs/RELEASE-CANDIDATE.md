# M7 v1.0.0-rc.1 — deployment preparation

Prepared 2026-09-28. This document records the release candidate's preparation. **Subsequent launch update:** all five contracts were deployed on Base that day and exactly verified on Sourcify; see the [actual deployment record](../deployments/base-mainnet.json) and [source verification record](../deployments/base-mainnet-source.json). The source repository remains private; the contract source is public on Sourcify.

## Included changes

- Precision-floor recovery and completion checks, with executable regressions.
- Structural oracle-round validation in the display lens.
- The Unlicense for original M7 work, preserved dependency notices, and consistent SPDX headers.
- Architecture and methodology documentation describing issuer authority, fixed execution dependencies, keeper incentives, conditional exits, and the firm requirement for no M7 administrator.
- A corrected recovery-test assertion for documented dust completion; the exact release-preflight counterexample is retained. See [review 4](AUDIT-4.md#shipping-preflight-follow-up).

## Validation

| Check | Result |
| --- | --- |
| `make check` | Formatting and size checks passed; 124 Solidity tests and 31 Python tests passed; 9 opt-in native fork cases skipped in this command |
| Focused recovery campaign | 4,096 new fuzz cases plus the saved counterexample passed; deterministic dust regression passed |
| Native Base integration, Beryl | All 9 cases passed |
| Native Base integration, simulated Cobalt | All 9 cases passed |
| Live read-only integration and planned-account eligibility | Passed at block 51,896,512 |
| Local Cobalt rehearsal using the supplied deployer at nonce 7 and a $125 seed | Deployment, linkage/bytecode checks, acquisition, bootstrap, gateway/in-kind smoke tests, and monitoring passed |
| First reset in that rehearsal | Correctly refused outside the execution window; this is not evidence of an in-window launch reset |

Native tests used Base Foundry `nightly-98e7839c65f6`. `BaseForkTest` and `Audit2ForkTest` used block 51,896,371; `Audit3ForkTest` retains its recorded historical blocks. Cobalt was simulated over pre-upgrade mainnet state. It must not be described as a post-Cobalt mainnet test.

The rehearsal impersonated the supplied deployer and funded it on a local fork. Its seed recipient was a throwaway rehearsal address. It demonstrates transaction behavior, not possession of the production signing key or sufficient production funding. The real proposed recipient and addresses are recorded in [the deployment plan](../deployments/base-mainnet-plan.json).

## Preparation inputs and subsequent launch checks

1. **Signing verified:** the local encrypted keystore `m7-deployer` derived the supplied address at block 51,897,516, and the operator unlocked it locally for deployment. File permissions are 600. No private key or password belongs in this repository or in chat.
2. **Funding received:** the proposed seed remains $125, with the supplied address provisionally receiving the seed shares. At block 51,897,031 the wallet held **181.920276 USDC** and **0.000266845134275612 ETH**; latest and pending nonces were both 7. A seed preview at block 51,897,087 gave a 126.249994 USDC acquisition budget, which the wallet covers. Recompute quotes and gas costs before broadcast; these balances and estimates are snapshots.
3. **Timing updated September 28:** the launch organizer requested immediate deployment under Beryl instead of the previous October 1 target. A fresh deployment simulation and planned-account checks passed under current rules at block 51,897,427; the conservative deployment gas estimate was 0.000208415537094312 ETH. Actual post-Cobalt validation remains a follow-up after the September 30, 18:00 UTC activation. The first reset still requires the 15:00–20:00 UTC execution window and a fresh market signal. [Base's upgrade schedule](https://status.base.org/)
4. **Source verification and monitoring active:** Sourcify reports exact creation and runtime matches for all five addresses. The monitor is running from a systemd user timer on the selected always-on Linux server, every 15 minutes. All 31 Python tests passed there; its first deployed-contract read succeeded at block 51,897,598. Initial alerts go to the server journal, as requested; no webhook or external heartbeat is configured. Its pending-first-reset alert is expected until a successful reset in the execution window.
5. **Deployment verified:** all five creation receipts succeeded at blocks 51,897,533–51,897,537. The 63 on-chain checks passed at block 51,897,549, including exact runtime metadata matches. The deployment used source commit `296b57e6d13af81da9f574baf121db1e78f0a758`; the plan file remains preparation evidence, while `base-mainnet.json` records the actual deployment.

The decision to ship without an independent audit remains documented in the runbook. These checks do not remove the external and architectural dependencies in [the architecture review](ARCHITECTURE-REVIEW.md).

## Bootstrap and final launch checks

Bootstrap succeeded at block 51,897,833, transaction `0x21d101f6f92e96c82a8b6c5d9615bafe374784eeb503c7281fc55403aa778be8`. The seed used 121.530009 USDC plus the deployer's existing 0.01 AAPLc. Supply is 1,000 M7, with 990 held by the seed receiver and 10 permanently locked. Public minting is open. All 21 acquisition transactions and all eight bootstrap transactions succeeded.

A follow-up RPC initially read pre-bootstrap state and returned `NotInitialized()`; this was a read error, not a reverted mint. The retry passed all 84 checks. The verifier now accepts a minimum receipt block and waits for a lagging endpoint; all 33 Python tests pass, including two regressions for this guard. The deployed contract code is unchanged.

The [live-state smoke script](../deployments/base-mainnet-smoke.sol) passed against the deployed addresses using local pranks only: gateway minting, USDC redemption, in-kind redemption, receipt transfers, no deferred claims, supply conservation and no retained gateway assets. It sent no additional transactions. Run it with Base Forge and the current precompile rules, e.g. `FOUNDRY_BASE=beryl "$BASE_FORGE" script deployments/base-mainnet-smoke.sol:Smoke --rpc-url "$BASE_RPC_URL"` before Cobalt.

The monitor reads the live vault every 15 minutes and records alerts in its journal. Its first-reset alert remains open: the first reset must be signed during the weekday 15:00–20:00 UTC window with valid feeds. No automatic reset signer is installed. Actual post-Cobalt checks also remain pending. See the [launch record](../deployments/base-mainnet-launch.json).
