# M7 v1.0.0-rc.1 — deployment preparation

Prepared 2026-09-28. **This is a tested release candidate, not a mainnet deployment.** No production transactions were broadcast during this preparation. The source repository remains private; a public source release has not been made by changing repository visibility.

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

## Remaining launch inputs and checks

1. **Signing:** the supplied account is held in MetaMask. A local encrypted keystore can be imported and used from the operator's own terminal. Verify the derived address before signing. No private key or password belongs in this repository or in chat.
2. **Funding:** the proposed seed remains $125, with the supplied address provisionally receiving the seed shares. At block 51,896,410 the wallet held 31.920276 USDC and 0.000266845134275612 ETH. The rehearsal's acquisition budget was 126.25 USDC. Recompute quotes and gas costs before funding and broadcast; those balances and estimates are snapshots.
3. **Post-Cobalt validation:** the existing [runbook](DEPLOYMENT.md#phase-1-go-no-go-after-cobalt-oct-1) targets the October 1 go/no-go after Cobalt activates September 30 at 18:00 UTC. Rerun native tests and the full rehearsal on actual post-upgrade state, during the 15:00–20:00 UTC execution window. [Base's upgrade schedule](https://status.base.org/)
4. **Source verification and monitoring:** configure explorer verification and an always-on monitor before seeding. Source verification should include the final licenses. Monitoring was tested locally; a production monitor and alert destination have not been configured in this preparation.
5. **Nonce and deployment record:** refresh the account nonce and all five predicted addresses before signing. After deployment, run `verify_deployment.py` and save the actual transaction-backed record before acquiring or depositing the seed. The plan file is not that record.

The decision to ship without an independent audit remains documented in the runbook. These checks do not remove the external and architectural dependencies in [the architecture review](ARCHITECTURE-REVIEW.md).
