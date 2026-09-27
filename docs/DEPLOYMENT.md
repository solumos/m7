# M7CAP mainnet deployment runbook

This runbook deploys M7CAP to Base mainnet, seeds it, runs the first quarterly cycle and keeps it monitored. Each step gives the command, what a good result looks like, and when to stop.

None of the four contracts has an owner, and none charges a fee. Nothing can pause, cap or upgrade them. A mistake after the bootstrap means a new deployment and asking holders to migrate. The contracts have not had an independent audit; launching without one is the owner's decision. Say so wherever the deployment is announced.

## Roles and funding

Every mainnet transaction is signed by the role's owner with a hardware wallet or an encrypted Foundry keystore. No private key belongs in `.env` or on the monitoring server.

| Role | Holds | Authority |
|---|---|---|
| Deployer, a fresh EOA used for nothing else until the deploy | about 0.01 ETH and the seed's USDC budget (about 1,030 USDC for a $1,000 seed) | Deploys the four contracts and calls `bootstrap` once; none afterwards |
| Seed receiver, e.g. a 2-of-3 Safe on Base | the 990 unlocked seed shares | None: an ordinary holder |
| Proposer | the UMA bond (at least 1,000 USDC, refunded 72 hours after an undisputed proposal) and gas | None: anyone may propose |
| Dispute wallet | at least one bond in USDC and gas, reachable during every challenge window from Oct 1 | None: anyone may dispute |
| Settler and executor | gas | None: anyone may settle or execute |
| Monitor server | an RPC URL and a webhook, no keys | Read-only |

The controller address alone decides nothing: a stranger can propose on the first day of a quarter. Keep the dispute wallet funded and the monitor running from the moment the controller exists.

## Toolchain

The Valuation and vault constructors, AcquireSeed, Bootstrap and Execute call Base's B20 precompiles. Stock Forge cannot simulate those calls, so every script on the deploy path runs with Base's Foundry build, base-anvil. Stock Foundry stays in use for `make check` and `cast`.

Install the pinned base-anvil build and verify its provenance:

```sh
TAG=nightly-98e7839c65f64aee9627b69a9b98b79afaeb1fae   # reproduces base/base 3eb4817 (2026-09-01)
gh release download "$TAG" -R base/base-anvil -p 'foundry_nightly_darwin_arm64.tar.gz'   # pick your platform
mkdir -p x && tar -xzf foundry_nightly_darwin_arm64.tar.gz -C x
for b in forge anvil cast chisel; do gh attestation verify "x/$b" --repo base/base-anvil; done
mkdir -p ~/.base-foundry/nightly-98e7839c65f6/bin && cp x/* ~/.base-foundry/nightly-98e7839c65f6/bin/
```

Before the Oct 1 go/no-go, check `gh release list -R base/base-anvil` for a build reproducing mainnet's release, and switch to it if one exists. Every later command assumes this shell setup:

```sh
export BASE_FORGE=~/.base-foundry/nightly-98e7839c65f6/bin/forge
export FOUNDRY_BASE=cobalt   # Base's precompile rules; use beryl before 2026-09-30 18:00 UTC
export FOUNDRY_DISABLE_NIGHTLY_WARNING=1
set -a; . ./.env; set +a     # a copy of .env.example with real values
```

`BASE_RPC_URL` should be a private endpoint. Public endpoints rate-limit, and some refuse the historical reads a fork needs. Sign forge scripts with `--ledger --sender <address>` (add `--mnemonic-derivation-paths` for another account) or `--account <keystore> --sender <address>`. Sign cast commands with `--ledger` or `--account`.

## Timeline (UTC)

| When | Phase |
|---|---|
| Now to Tue Sep 29 | Phase 0: preparation |
| Wed Sep 30, 18:00 | Cobalt hard fork activates on Base mainnet |
| Wed Sep 30, 20:00 | Reference close for the Sep 30 review (proposal quarter 8107, Oct–Dec) |
| Thu Oct 1 | Phase 1: go/no-go on post-Cobalt state; draft the observations |
| Oct 1–2 | Phase 2: observations reviewed and published. Phase 3: deploy |
| Fri Oct 2, US market hours | Phase 4: seed, bootstrap, smoke tests, propose, announce |
| Mon Oct 5 onward | Phase 5: settle and execute the first cycle |

## Phase 0: preparation

1. **Release commit.** Deploy only from a clean checkout of the reviewed release commit:

   ```sh
   git switch release/v1 && git status --porcelain   # prints nothing
   make check                                          # all Solidity and Python tests pass
   ```

2. **Native tests** against live Base, under both rule sets:

   ```sh
   for up in beryl cobalt; do
     BASE_FORK_TEST=true FOUNDRY_BASE=$up "$BASE_FORGE" test --match-contract BaseForkTest -vv
   done
   ```

   All four tests must pass: the native bootstrap and gateway round trip, the live UMA bond lifecycle, the rebalance through the live pools, and transfers with the resilient exit.

3. **Rehearsal.** Run the whole runbook against a local fork. It impersonates and funds throwaway accounts, and never broadcasts to mainnet:

   ```sh
   BASE_RPC_URL=https://mainnet.base.org \
   ANVIL_FORK_FLAGS="--compute-units-per-second 20 --retries 30 --fork-retry-backoff 3000 --timeout 60000" \
     script/rehearse.sh
   ```

   It must end with `Rehearsal passed`. The fork source must serve recent history: `mainnet.base.org` does when throttled as above, and so may your private endpoint. The rehearsal applies Cobalt's rules by default; set `BASE_UPGRADE=beryl` for the rules mainnet runs before activation. With `DEPLOYER` set to the real deployer, it previews the exact mainnet addresses.

4. **Bond floor.** `BOND_FLOOR_USDC` is immutable. A false, undisputed proposal can cost holders at most about 0.1–0.2% of NAV per quarter, so a 1,000 USDC bond deters it only up to roughly $0.5–1M of NAV. Raise it before deploying if you expect more. Dispute capital must match the bond.

5. **Methodology.** Freeze `docs/METHODOLOGY.md`: its exact bytes are hashed into the controller, `Propose` checks the hash, and any later edit needs a new deployment. Publish it at its raw CIDv1, the only URI the deploy script accepts:

   ```sh
   python3 scripts/ipfs_cid.py docs/METHODOLOGY.md --car methodology.car   # prints ipfs://bafkrei...
   ipfs add --cid-version=1 docs/METHODOLOGY.md                           # kubo prints the same CID
   ```

   Pin that CID on at least two independent services: `ipfs pin remote add`, or upload `methodology.car` to a service that imports CARs. Then confirm public gateways serve the exact bytes:

   ```sh
   python3 scripts/ipfs_cid.py docs/METHODOLOGY.md --gateway https://ipfs.io --gateway https://dweb.link
   ```

   Every gateway must report `identical bytes`. Set `METHODOLOGY_URI` to the printed URI. A claim is false if the document is unavailable, so keep the pins for the life of the deployment.

6. **Wallets and services.** Create and fund the roles above. Set `DEPLOYER` and `SEED_RECEIVER` in `.env`. Set up the monitor server (see [Monitoring](#monitoring)) and test its webhook.

## Phase 1: go/no-go after Cobalt (Oct 1)

1. Predict the deployer's addresses. The deployer's nonce `N` must not change before the deploy:

   ```sh
   N=$(cast nonce "$DEPLOYER" --rpc-url "$BASE_RPC_URL")
   VAULT_PREDICTED=$(cast compute-address "$DEPLOYER" --nonce $((N + 2)) | awk '{print $NF}')
   GATEWAY_PREDICTED=$(cast compute-address "$DEPLOYER" --nonce $((N + 3)) | awk '{print $NF}')
   ```

2. Preflight against live mainnet, with every planned account checked against the stocks' transfer policies:

   ```sh
   python3 scripts/verify_base.py --reads-only --account "$DEPLOYER" --account "$SEED_RECEIVER" \
     --account "$VAULT_PREDICTED" --account "$GATEWAY_PREDICTED"
   ```

   Expect exit 0 with `read_checks_passed: true` and `policy_zero_authorized: true`.

3. Re-run the native tests and the rehearsal (Phase 0, steps 2 and 3). They now fork a post-activation block.

**Go** only if all three pass.

## Phase 2: observations and snapshot

1. Draft `observations.json` for the Sep 30, 2026 review, following [the methodology](METHODOLOGY.md):
   - share counts from SEC filings published by the cutoff;
   - official closes at the 20:00 UTC reference close;
   - the token feed rounds and each B20 multiplier effective at that close, read at that block because Cobalt schedules multiplier changes.

   An independent reviewer checks every number against its source URL.

2. Compile it and check the digest:

   ```sh
   python3 scripts/index_snapshot.py observations.json --canonical-out observations.canonical.json \
     > config/snapshot.json
   sha256sum observations.canonical.json   # equals observation_sha256 in config/snapshot.json
   ```

   `quarter_id` must be 8107.

3. Publish `observations.json`, `observations.canonical.json` and `config/snapshot.json` together as one IPFS directory (`ipfs add -r --cid-version=1 evidence/`), and pin it twice. Set `EVIDENCE_URI=ipfs://<directory CID>`.

4. Copy `config/snapshot.json` to the monitor server as its `EXPECTED_SNAPSHOT`.

## Phase 3: deploy

1. Build with the deploying toolchain. The verifier compares bytecode with this build:

   ```sh
   "$BASE_FORGE" build
   ```

2. Simulate:

   ```sh
   "$BASE_FORGE" script script/Deploy.s.sol:Deploy --rpc-url "$BASE_RPC_URL" --sender "$DEPLOYER"
   ```

   Check that the logged `Vault` equals `$VAULT_PREDICTED`. The run must end `SIMULATION COMPLETE`. A wrong `METHODOLOGY_URI` stops here.

3. Broadcast five transactions: the Valuation, controller, vault and gateway, then the read-only price lens. Send nothing else from the deployer until all five are mined:

   ```sh
   "$BASE_FORGE" script script/Deploy.s.sol:Deploy --rpc-url "$BASE_RPC_URL" --ledger --sender "$DEPLOYER" \
     --broadcast --slow --gas-estimate-multiplier 200 --verify --etherscan-api-key "$ETHERSCAN_API_KEY"
   ```

   If only the explorer verification fails, repeat it later with `--resume --verify` in place of `--broadcast`.

4. Verify on chain and write the deployment record:

   ```sh
   python3 scripts/verify_deployment.py --write-record deployments/base-mainnet.json
   ```

   Expect `"ok": true`, with every contract's `runtime code matches the local build`.

5. Put `VAULT`, `CONTROLLER`, `GATEWAY` and `LENS` in `.env`. Point the monitor at `CONTROLLER`, `GATEWAY` and `LENS`, and confirm one heartbeat.

**Abort rules:**
- **A deploy transaction fails.** Stop. The contracts already created are inert: the controller is bound to a vault address nobody can deploy any more. After diagnosing, redeploy from the next nonce and redo Phase 1 for the new predicted addresses.
- **`verify_deployment.py` fails.** Never fund that deployment. Redeploy.

## Phase 4: seed, bootstrap and smoke tests

Run this during US market hours (13:30–20:00 UTC), when feeds are fresh and pools track prices.

1. Size the seed in the snapshot's exact ratios, so the first execution has nothing to do:

   ```sh
   python3 scripts/seed_basket.py config/snapshot.json --usd 1000 --vault "$VAULT" --receiver "$SEED_RECEIVER"
   ```

   Review `config/seed.json` and fund the deployer with the printed `usdc_budget_for_acquire_seed`.

2. Buy the seed through the vault's pinned pools. Simulate first, then broadcast. Each of the seven purchases is an approval, a swap and an approval reset:

   ```sh
   "$BASE_FORGE" script script/AcquireSeed.s.sol:AcquireSeed --rpc-url "$BASE_RPC_URL" --sender "$DEPLOYER"
   "$BASE_FORGE" script script/AcquireSeed.s.sol:AcquireSeed --rpc-url "$BASE_RPC_URL" --ledger \
     --sender "$DEPLOYER" --broadcast --slow
   ```

   A swap that would pay more than oracle value plus 1% reverts (`Too much requested`). Wait and rerun: the script buys only what is still missing.

3. Bootstrap with seven approvals and one `bootstrap` call. It re-verifies the linkage first:

   ```sh
   "$BASE_FORGE" script script/Bootstrap.s.sol:Bootstrap --rpc-url "$BASE_RPC_URL" --ledger --sender "$DEPLOYER" \
     --broadcast --slow
   python3 scripts/verify_deployment.py --bootstrapped
   ```

   The verifier must report `"ok": true`: 1,000 shares with 10 locked, 990 held by the seed receiver, backing equal to the seed, and no reserves. Its `price_per_share_usd` should be about the seed's value divided by 1,000.

4. Smoke tests from a small operator wallet (`ME`) holding about 20 USDC, not the deployer:

   ```sh
   D=$(( $(date +%s) + 1800 ))
   cast send "$USDC" 'approve(address,uint256)' "$GATEWAY" 20000000 --ledger --rpc-url "$BASE_RPC_URL"
   cast send "$GATEWAY" 'mintWithUSDC(uint256,uint256,address,uint256)' 3000000000000000000 20000000 "$ME" "$D" \
     --ledger --rpc-url "$BASE_RPC_URL"
   cast send "$VAULT" 'approve(address,uint256)' "$GATEWAY" 1000000000000000000 --ledger --rpc-url "$BASE_RPC_URL"
   cast send "$GATEWAY" 'redeemToUSDC(uint256,uint256,address,uint256)' 1000000000000000000 0 "$ME" "$D" \
     --ledger --rpc-url "$BASE_RPC_URL"
   cast send "$VAULT" 'redeemBasketWithClaims(uint256,uint256[8],address,uint256)' 1000000000000000000 \
     '[0,0,0,0,0,0,0,0]' "$ME" "$D" --ledger --rpc-url "$BASE_RPC_URL"
   cast send "$VAULT" 'transfer(address,uint256)' "$SEED_RECEIVER" 500000000000000000 --ledger --rpc-url "$BASE_RPC_URL"
   ```

   Here `USDC` is `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913`. Expect about $3 spent on the mint (on a $1,000 seed a share is worth about $1), USDC back from the redemption, and every stock leg delivered in kind. `claimOf(ME)` must be all zero, and the gateway must hold no USDC.

5. Commit `config/snapshot.json`, `config/seed.json` and `deployments/base-mainnet.json`.

**Abort rule:** if a smoke test fails, don't announce. The seed receiver can take the seed out in kind with `redeemBasketWithClaims`.

## Announce

Once the smoke tests pass and the monitor is running, publish:
- the five addresses, with links to their verified source;
- `METHODOLOGY_URI` and the evidence URI;
- that there is no fee and no owner;
- the risks, including that there has been no independent audit.

## Phase 5: first quarterly cycle (quarter 8107)

1. **Propose.** The proposer holds at least `max(bond floor, UMA minimum)` USDC. The script syncs UMA's parameters, approves the bond and proposes: three transactions.

   ```sh
   "$BASE_FORGE" script script/Maintain.s.sol:Propose --rpc-url "$BASE_RPC_URL" --ledger --sender "$PROPOSER" \
     --broadcast --slow
   ```

   It refuses a changed methodology file, a snapshot for another quarter, or a quarter that already has a live proposal. It prints the assertion ID. The monitor should show only info alerts: challenge window open, ratios and digest matching.

2. **Settle** after the 72-hour challenge window. Anyone may:

   ```sh
   ASSERTION_ID=$(cast call "$CONTROLLER" 'latestProposal(uint32)(bytes32)' 8107 --rpc-url "$BASE_RPC_URL")
   ASSERTION_ID=$ASSERTION_ID "$BASE_FORGE" script script/Maintain.s.sol:Settle --rpc-url "$BASE_RPC_URL" --ledger \
     --sender "$EXECUTOR" --broadcast
   ```

3. **Execute** on a weekday, 15:00–20:00 UTC, while at least one stock feed has updated within the hour:

   ```sh
   "$BASE_FORGE" script script/Maintain.s.sol:Execute --rpc-url "$BASE_RPC_URL" --ledger --sender "$EXECUTOR" \
     --broadcast
   ```

   The seed already matches the ratios, so no trades are expected and `executedQuarter(8107)` becomes true. A revert changes nothing (`OutsideExecutionWindow`, `NoFreshMarketSignal`, `Too little received`, `NotCompliant`); retry later in the quarter.

4. Tag the deployed commit and push the tag: `git tag -a v1.0.0 <commit in deployments/base-mainnet.json> && git push origin v1.0.0`.

**Every quarter after this:**
- compile and review the new observations after the quarter-end close;
- replace `EXPECTED_SNAPSHOT` on the monitor server;
- propose, settle and execute, allowing the 72-hour challenge window and a weekday execution window.

## Monitoring

`scripts/monitor.py` runs every 15 minutes from a systemd timer on an always-on Linux server. It:
- reads the controller with `watch_index.py`;
- records the price per share from the lens in `price-history.jsonl` beside its state file;
- alerts if backing per share falls outside a rebalance (an issuer seizure or burn), if new minting is blocked, or if deferred claims are outstanding;
- runs the `verify_base.py` read checks hourly, with the vault and gateway as policy accounts;
- posts new alerts to a Slack or Discord webhook;
- repeats open critical alerts every six hours and announces cleared ones;
- pings a heartbeat URL after every successful run.

It holds no keys.

**Setup.** Copy the release commit to the server from your machine (the server needs no repository access):

```sh
git archive --format=tar release/v1 | ssh <server> 'sudo mkdir -p /opt/m7cap && sudo tar -x -C /opt/m7cap'
```

Then, on the server:

```sh
sudo useradd --system --create-home m7cap
sudo -u m7cap sh -c 'curl -L https://foundry.paradigm.xyz | bash && ~/.foundry/bin/foundryup'   # for cast
cd /opt/m7cap
sudo install -D -m 600 -o m7cap ops/monitor.env.example /etc/m7cap/monitor.env   # then fill it in
sudo cp ops/m7cap-monitor.service ops/m7cap-monitor.timer /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now m7cap-monitor.timer
sudo systemctl start m7cap-monitor.service && journalctl -u m7cap-monitor -n 50
```

For the heartbeat, create a check (for example on healthchecks.io) that expects a ping every 15 minutes with 30 minutes' grace, and put its URL in `HEARTBEAT_URL`. Without systemd, use cron:

```sh
*/15 * * * * cd /opt/m7cap && set -a && . /etc/m7cap/monitor.env && python3 scripts/monitor.py >> /var/log/m7cap-monitor.log 2>&1
```

**Alert levels:**

| Level | Examples | Response |
|---|---|---|
| critical | ratios or digest differ from the reviewed snapshot; a proposal while no reviewed snapshot is loaded; unexpected UMA parameters; a disputed or unsettleable assertion; 21 days or fewer left without an execution; failed preflight reads; backing per share fell; minting blocked | Act now: see the playbook |
| action | no proposal yet; settlement available; an accepted proposal awaiting execution; a rejected proposal; deferred claims outstanding | Run the next maintenance step |
| info | challenge window open on a matching proposal; replacement allowed | None |

## Incident playbook

**False or unreviewable proposal.** Compare the assertion with the reviewed snapshot and its sources. If it is false, dispute before `challenge_expires_utc` in the watcher output. The dispute wallet posts a bond equal to the assertion's (`bond_raw`), and must not be blocked by USDC:

```sh
OOV3=0x2aBf1Bd76655de80eDB3086114315Eec75AF500c
cast send "$USDC" 'approve(address,uint256)' "$OOV3" <bond_raw> --ledger --rpc-url "$BASE_RPC_URL"
cast send "$OOV3" 'disputeAssertion(bytes32,address)' <assertion id> <dispute wallet> --ledger --rpc-url "$BASE_RPC_URL"
```

A disputed proposal never blocks a replacement, so propose the correct snapshot straight away. UMA's DVM resolves the dispute over the following days; the first proposal of the quarter to settle true is the one executed.

**Our proposal disputed or unsettleable.** Propose again at once; the replacement is allowed. Settle whichever resolves true first.

**Quarter deadline.** Leave at least four days: 72 hours of challenge and a weekday window. An accepted but unexecuted proposal expires at the quarter boundary, and the basket is simply kept.

**Backing per share fell.** Minting, redeeming and claims never lower it, so a fall outside a rebalance means an issuer seized or burned vault holdings. Check the stock's `Transfer` events from the vault and the issuer's announcements. Claims are paid before holders, so holders absorb the loss.

**Minting blocked.** An issuer seizure pushed a stock below the vault's precision floor. Redemptions still work, and the next quarterly rebalance rebuilds the stock by one step.

**Preflight failure.** The message names the check:
- a paused stock or issuer feed;
- a policy that now rejects the vault or gateway;
- changed feed decimals;
- a de-listed UMA identifier or collateral.

The contracts fail closed. Holders' in-kind exit through `redeemBasketWithClaims` still delivers every asset that can move, and defers the rest as claims. A replaced stock contract, retired feed or de-listed identifier needs a new deployment and a voluntary migration.

