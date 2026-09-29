# M7 mainnet deployment runbook

This runbook deploys M7 to Base mainnet, seeds it, runs the first quarterly reset and keeps it monitored. Each step gives the command, what a good result looks like, and when to stop.

None of the five contracts has an owner or charges a protocol fee. M7 has no privileged pause or upgrade function; external asset restrictions, unavailable dependencies, and its own execution gates can still stop operations. A mistake after the bootstrap can require a new deployment and voluntary holder migration, subject to the assets being transferable. The contracts have not had an independent audit; launching without one is the launch organizer's decision. Say so wherever the deployment is announced.

## Roles and funding

Every mainnet transaction is signed by the role's owner with a hardware wallet or an encrypted Foundry keystore. No private key belongs in `.env` or on the monitoring server.

| Role | Holds | Authority |
|---|---|---|
| Deployer, with its nonce reserved until all five creates finish | ETH covering refreshed gas estimates for deployment and launch, and the seed's USDC acquisition budget | Deploys the five contracts and calls `bootstrap` once; none afterwards |
| Seed receiver, e.g. a 2-of-3 Safe on Base | the 990 unlocked seed shares | None: an ordinary holder |
| Reset caller | gas, and receives the reset reward | None: anyone may trigger the quarterly reset |
| Monitor server | an RPC URL and a webhook, no keys | Read-only |

## Toolchain

The Valuation and vault constructors, AcquireSeed, Bootstrap and the reset call Base's B20 precompiles. Stock Forge cannot simulate those calls, so every script on the deploy path runs with Base's Foundry build, base-anvil. Stock Foundry stays in use for `make check` and `cast`.

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

Updated September 28: the launch organizer chose to deploy now under Beryl, before Cobalt. The previous October 1 target was a sequencing precaution, not a contract restriction. Both Beryl and simulated Cobalt native integration tests have passed. Actual post-Cobalt validation remains a follow-up after activation. Preserve the contracts' existing feed-age and execution-window checks.

| When | Phase |
|---|---|
| Mon Sep 28 | Phase 1: fresh Beryl preflight. Phase 2: deploy and verify source |
| After deployment verification and usable seed feeds | Phase 3: seed, bootstrap and smoke tests |
| Next weekday 15:00–20:00 execution window, with fresh market signal | First reset |
| Wed Sep 30, 18:00 | Cobalt hard fork activates on Base mainnet |
| After Cobalt activation | Repeat integration checks on actual post-upgrade state |
| Every quarter | Phase 4: the quarterly reset |

## Phase 0: preparation

1. **Release commit.** Deploy only from a clean checkout of the reviewed release commit:

   ```sh
   git switch main && git pull && git status --porcelain   # prints nothing
   make check                                          # all Solidity and Python tests pass
   ```

2. **Native tests** against live Base, under both rule sets:

   ```sh
   for up in beryl cobalt; do
     BASE_FORK_TEST=true FOUNDRY_BASE=$up "$BASE_FORGE" test --match-contract BaseForkTest -vv
   done
   ```

   All four tests must pass: the native bootstrap and gateway round trip, the lens's price per share, a reset to equal weights through the live pools, and transfers with the resilient exit. A failure mentioning `over rate limit` is the endpoint, not the code: run the tests one at a time and throttled, by adding `-j 1` and prefixing `FOUNDRY_COMPUTE_UNITS_PER_SECOND=20 FOUNDRY_FORK_RETRIES=30 FOUNDRY_FORK_RETRY_BACKOFF=3000`.

3. **Rehearsal.** Run the runbook against a local fork. It impersonates and funds throwaway accounts, and never broadcasts to mainnet:

   ```sh
   BASE_RPC_URL=https://mainnet.base.org \
   ANVIL_FORK_FLAGS="--compute-units-per-second 20 --retries 30 --fork-retry-backoff 3000 --timeout 60000" \
     scripts/rehearse.sh
   ```

   It must end with `Rehearsal passed`. Its last step is the first reset with the `Rebalance` script: inside the execution window (a weekday, 15:00–20:00 UTC) the reset runs on the fork; outside it, the valuation must refuse it and change nothing. The fork source must serve recent history: `mainnet.base.org` does when throttled as above, and so may your private endpoint. The rehearsal applies Cobalt's rules by default; set `BASE_UPGRADE=beryl` for the rules mainnet runs before activation. With `DEPLOYER` set to the real deployer, it previews the exact mainnet addresses.

4. **Wallets and services.** Create and fund the roles above. Set `DEPLOYER`, `SEED_RECEIVER` and `SEED_USD` in `.env`. Set up the monitor server (see [Monitoring](#monitoring)) and test its webhook.

## Phase 1: go/no-go

1. Predict the deployer's addresses. The deployer's nonce `N` must not change before the deploy:

   ```sh
   N=$(cast nonce "$DEPLOYER" --rpc-url "$BASE_RPC_URL")
   VAULT_PREDICTED=$(cast compute-address "$DEPLOYER" --nonce $((N + 2)) | awk '{print $NF}')
   GATEWAY_PREDICTED=$(cast compute-address "$DEPLOYER" --nonce $((N + 3)) | awk '{print $NF}')
   ```

2. Preflight against live mainnet, with every planned account checked against the stocks' transfer policies:

   ```sh
   python3 -m scripts.verify_base --reads-only --account "$DEPLOYER" --account "$SEED_RECEIVER" \
     --account "$VAULT_PREDICTED" --account "$GATEWAY_PREDICTED"
   ```

   Expect exit 0 with `read_checks_passed: true` and `policy_zero_authorized: true`.

3. Use the native tests and rehearsal from Phase 0, with Beryl for a deployment before Cobalt activation. Refresh the deploy simulation against live state immediately before signing. A rehearsal outside 15:00–20:00 UTC must refuse the reset; record it as pending until the execution window opens. Repeat the integration checks on actual post-Cobalt state after activation.

**Go** only if all three pass.

## Phase 2: deploy

1. Build with the deploying toolchain. The verifier compares bytecode with this build:

   ```sh
   "$BASE_FORGE" build
   ```

2. Simulate:

   ```sh
   "$BASE_FORGE" script scripts/Deploy.s.sol:Deploy --rpc-url "$BASE_RPC_URL" --sender "$DEPLOYER"
   ```

   Check that the logged `Vault` equals `$VAULT_PREDICTED`. The run must end `SIMULATION COMPLETE`.

3. Broadcast five transactions: the Valuation, controller, vault and gateway, then the read-only lens. Send nothing else from the deployer until all five are mined:

   ```sh
   "$BASE_FORGE" script scripts/Deploy.s.sol:Deploy --rpc-url "$BASE_RPC_URL" --ledger --sender "$DEPLOYER" \
     --broadcast --slow --gas-estimate-multiplier 200
   ```

   For a local signer, replace `--ledger` with `--account <keystore-name>`; enter its password only in your own terminal. Verify its address first with `cast wallet address --account <keystore-name>`.

4. Verify on chain and write the deployment record:

   ```sh
   python3 -m scripts.verify_deployment --write-record deployments/base-mainnet.json
   ```

   Expect `"ok": true`, with every contract's `runtime code matches the local build`.

5. Publish and verify all five contracts' source through [Sourcify](https://docs.sourcify.dev/docs/verify-via-foundry/). This needs no explorer API key and sends no blockchain transaction. Use the actual deployment record from step 4:

   ```sh
   python3 - <<'PY'
   import json, os, subprocess
   from pathlib import Path
   record = json.loads(Path('deployments/base-mainnet.json').read_text())
   assert record['chain_id'] == 8453
   for name, contract in record['contracts'].items():
       assert contract['status'] == '0x1' and contract['transaction']
       subprocess.run([
           os.environ['BASE_FORGE'], 'verify-contract', contract['address'],
           f'src/{name}.sol:{name}', '--chain', '8453', '--verifier', 'sourcify',
           '--creation-transaction-hash', contract['transaction'], '--watch',
       ], check=True)
   PY
   ```

   Require successful creation and runtime matches for every address before seeding. Review the result at `https://repo.sourcify.dev/8453/<address>`. If verification fails, diagnose and retry this step; do not redeploy merely to retry source publication. The pinned Base Forge was checked locally to send Sourcify v2 requests for all five contracts. This preflight is not a public verification result. Basescan verification with an Etherscan API key remains an optional additional publication.

6. Put `VAULT`, `CONTROLLER`, `GATEWAY` and `LENS` in `.env`. Point the monitor at `CONTROLLER`, `GATEWAY` and `LENS`, and confirm one successful read in its logs (and a heartbeat if configured).

**Abort rules:**
- **A deploy transaction fails.** Stop. The contracts already created are inert: the controller is bound to a vault address nobody can deploy any more. After diagnosing, redeploy from the next nonce and redo Phase 1 for the new predicted addresses.
- **`verify_deployment.py` fails.** Never fund that deployment. Redeploy.

## Phase 3: seed, bootstrap, smoke tests and the first reset

Run this during US market hours (13:30–20:00 UTC), when feeds are fresh and pools track prices.

1. Size an equal-value seed at current prices:

   ```sh
   python3 -m scripts.seed_basket --usd "$SEED_USD" --vault "$VAULT" --receiver "$SEED_RECEIVER"
   ```

   Review `config/seed.json` and fund the deployer with the printed `usdc_budget_for_acquire_seed`. Every stock needs at least 0.01 tokens, so the seed must be worth at least about $53 at current prices; the script refuses a smaller seed and prints the minimum. Only 1% of the seed stays locked for good.

2. Buy the seed through the vault's pinned pools. Simulate first, then broadcast. Each of the seven purchases is an approval, a swap and an approval reset:

   ```sh
   "$BASE_FORGE" script scripts/AcquireSeed.s.sol:AcquireSeed --rpc-url "$BASE_RPC_URL" --sender "$DEPLOYER"
   "$BASE_FORGE" script scripts/AcquireSeed.s.sol:AcquireSeed --rpc-url "$BASE_RPC_URL" --ledger \
     --sender "$DEPLOYER" --broadcast --slow
   ```

   A swap that would pay more than oracle value plus 1% reverts (`Too much requested`). Wait and rerun: the script buys only what is still missing.

3. Bootstrap with seven approvals and one `bootstrap` call. It re-verifies the linkage first:

   ```sh
   "$BASE_FORGE" script scripts/Bootstrap.s.sol:Bootstrap --rpc-url "$BASE_RPC_URL" --ledger --sender "$DEPLOYER" \
     --broadcast --slow
   BOOTSTRAP_BLOCK=$(python3 -c 'import json; d=json.load(open("broadcast/Bootstrap.s.sol/8453/run-latest.json")); print(max(int(r["blockNumber"],16) for r in d["receipts"]))')
   python3 -m scripts.verify_deployment --bootstrapped --min-block "$BOOTSTRAP_BLOCK"
   ```

   The verifier waits up to 30 seconds for the read endpoint to reach the bootstrap receipt block. During the initial launch a lagging read endpoint returned `NotInitialized()` just after the successful bootstrap; the retry passed all 84 checks. If verification fails, inspect the transaction receipts before retrying a broadcast. A read failure does not mean the transaction failed.

   The verifier must report `"ok": true`: 1,000 shares with 10 locked, 990 held by the seed receiver, backing equal to the seed, and no reserves. Its `price_per_share_usd` should be about the seed's value divided by 1,000.

4. Smoke tests from a small operator wallet (`ME`) holding about 20 USDC, not the deployer. The gateway calls run seven swaps, so give them an explicit gas limit:

   ```sh
   D=$(( $(date +%s) + 1800 ))
   cast send "$USDC" 'approve(address,uint256)' "$GATEWAY" 20000000 --ledger --rpc-url "$BASE_RPC_URL"
   cast send "$GATEWAY" 'mintWithUSDC(uint256,uint256,address,uint256)' 3000000000000000000 20000000 "$ME" "$D" \
     --gas-limit 4000000 --ledger --rpc-url "$BASE_RPC_URL"
   cast send "$VAULT" 'approve(address,uint256)' "$GATEWAY" 1000000000000000000 --ledger --rpc-url "$BASE_RPC_URL"
   cast send "$GATEWAY" 'redeemToUSDC(uint256,uint256,address,uint256)' 1000000000000000000 0 "$ME" "$D" \
     --gas-limit 4000000 --ledger --rpc-url "$BASE_RPC_URL"
   cast send "$VAULT" 'redeemBasketWithClaims(uint256,uint256[8],address,uint256)' 1000000000000000000 \
     '[0,0,0,0,0,0,0,0]' "$ME" "$D" --ledger --rpc-url "$BASE_RPC_URL"
   cast send "$VAULT" 'transfer(address,uint256)' "$SEED_RECEIVER" 500000000000000000 --ledger --rpc-url "$BASE_RPC_URL"
   ```

   Here `USDC` is `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913`. A share is worth about `SEED_USD / 1000` dollars, so expect the mint to cost about three times that, then USDC back from the redemption, and every stock leg delivered in kind. `claimOf(ME)` must be all zero, and the gateway must hold no USDC.

5. **First reset.** This quarter's reset is due as soon as the vault exists. On a weekday between 15:00 and 20:00 UTC:

   ```sh
   EXECUTOR=$ME "$BASE_FORGE" script scripts/Maintain.s.sol:Rebalance --rpc-url "$BASE_RPC_URL" --ledger \
     --sender "$ME" --broadcast --gas-estimate-multiplier 200
   ```

   The seed is already at equal value, so this first call trades nothing and completes the quarter: the script prints `Reset complete`, and `rebalanceDue()` becomes false. A revert changes nothing (`OutsideExecutionWindow`, `NoFreshMarketSignal`, `Too little received`, `PoolMoved`); retry later. The next quarter's reset opens 30 days after this one completed.

6. Commit the seed and launch records, then tag the release snapshot and push it. Preserve the actual deployment source commit in `deployments/base-mainnet.json`; release documentation and tooling may be updated afterward, but verify that `src/` and the compiler configuration have no differences from the deployed commit. Record both commits in the release manifest.

**Abort rule:** if a smoke test fails, don't announce. The seed receiver can take the seed out in kind with `redeemBasketWithClaims`.

## Announce

Once the smoke tests pass and the monitor is running, publish:
- the five addresses, with links to their verified source;
- the rules ([METHODOLOGY.md](METHODOLOGY.md)): equal weight, reset quarterly by anyone, no fee and no owner;
- the risks, including that there has been no independent audit.

## Phase 4: the quarterly reset

Each calendar quarter, anyone may run the reset, on weekdays between 15:00 and 20:00 UTC, in tranches at least 30 minutes apart. Each tranche trades at most about $10,000 per stock and the script says whether the quarter completed or when the next tranche may start: run it again until it prints `Reset complete`. A small vault completes in one tranche; in a volatile quarter a $1M vault takes a handful. Once the vault is large enough, the reward (5 bp of each tranche's traded value, up to $25) should attract others to do it; until then, run the `Rebalance` script above yourself early in the quarter. The monitor reports a reset in progress, alerts when a quarter's reset is still incomplete a week after it opens, and as critical with 21 days or fewer left. If a quarter ends first, nothing breaks: the next quarter's tranches continue it, and the basket keeps its quantities meanwhile.

## Monitoring

Run Python commands from the repository root with `python3 -m scripts.monitor`.
When upgrading an existing monitor checkout, also reinstall its service template
and run `systemctl daemon-reload` (or `systemctl --user daemon-reload` for the user
service): older units invoke the Python file directly.

`scripts/monitor.py` runs every 15 minutes from a systemd timer on an always-on Linux server. It:
- checks whether this quarter's reset has completed, is in progress, or has yet to open;
- records the price per share and weights from the lens in `price-history.jsonl` beside its state file;
- alerts if backing per share falls outside a reset (an issuer seizure or burn), if new minting is blocked, or if deferred claims are outstanding;
- runs the `verify_base.py` read checks hourly, with the vault and gateway as policy accounts, including that every pinned pool keeps the 300 price observations the reset's 10-minute average needs;
- posts new alerts to a Slack or Discord webhook;
- repeats open critical alerts every six hours and announces cleared ones;
- pings a heartbeat URL after every successful run.

It holds no keys.

**Setup.** Copy the release commit to the server from your machine (the server needs no repository access):

```sh
git archive --format=tar main | ssh <server> 'sudo mkdir -p /opt/m7 && sudo tar -x -C /opt/m7'
```

Then, on the server:

```sh
sudo useradd --system --create-home m7
sudo -u m7 sh -c 'curl -L https://foundry.paradigm.xyz | bash && ~/.foundry/bin/foundryup'   # for cast
cd /opt/m7
sudo install -D -m 600 -o m7 ops/monitor.env.example /etc/m7/monitor.env   # then fill it in
sudo cp ops/m7-monitor.service ops/m7-monitor.timer /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now m7-monitor.timer
sudo systemctl start m7-monitor.service && journalctl -u m7-monitor -n 50
```

For the heartbeat, create a check (for example on healthchecks.io) that expects a ping every 15 minutes with 30 minutes' grace, and put its URL in `HEARTBEAT_URL`. Without systemd, use cron:

```sh
*/15 * * * * cd /opt/m7 && set -a && . /etc/m7/monitor.env && python3 -m scripts.monitor >> /var/log/m7-monitor.log 2>&1
```

**User-service alternative.** When the SSH user already has `Linger=yes` (`loginctl show-user "$USER" -p Linger`), the monitor can run across logouts without a system service. Put the release source in `~/.local/share/m7`, a verified `cast` executable or symlink in its `bin/` directory, and install `ops/m7-monitor-user.service` as `~/.config/systemd/user/m7-monitor.service`. Copy the existing timer alongside it. Stage the monitor environment at `~/.config/m7/monitor.env` with mode 600. After deployment verification, fill in the actual addresses, configure alert delivery, rename it to `deployed.env`, then run:

```sh
systemctl --user daemon-reload
systemctl --user start m7-monitor.service
journalctl --user -u m7-monitor.service -n 50
systemctl --user enable --now m7-monitor.timer
```

Require a successful chain read and check the selected alert destination before enabling the timer. The launch organizer selected journal logs for initial alerts; leave the webhook and heartbeat blank and inspect `journalctl --user -u m7-monitor.service` regularly. This setup does not send notifications or detect the server going offline through an external heartbeat. Until `deployed.env` exists, the service skips its run. State and price history live in `~/.local/state/m7-monitor/`. Do not copy the deployer's `.env` or keystore to the server.

**Alert levels:**

| Level | Examples | Response |
|---|---|---|
| critical | 21 days or fewer left without a completed reset; backing per share fell; minting blocked; failed preflight reads | Act now: see the playbook |
| action | the reset still incomplete a week after it opened; deferred claims outstanding | Run its next tranche, or look into the frozen asset |
| info | the reset is due, in progress, or opens on a given date | None |

## Incident playbook

**Reset keeps reverting.** The revert names the gate:
- `OutsideExecutionWindow`: wait for a weekday 15:00–20:00 UTC.
- `TooSoon`: the last tranche was under 30 minutes ago, or the last completed reset under 30 days ago; see `nextTrancheAt()`.
- `NoFreshMarketSignal` or `UnavailablePrice`: the market is closed or a feed is stale; retry on the next trading day.
- `CorporateAction`: an issuer paused a reference price; wait for it to resume.
- `PoolMoved(i)`: stock `i`'s pool sits more than 25 ticks against the vault from its 10-minute average, perhaps pushed by someone else's transaction; retry in a few minutes.
- `PoolUnavailable(i)`: stock `i`'s pool cannot report its 10-minute average; check its observations with `verify_base.py`. Anyone can call the pool's `increaseObservationCardinalityNext` to keep more.
- `Too little received`: a pool sits more than 1% from its oracle price; retry later, and check that pool's depth with `verify_base.py`.
- `NotCompliant`: a stock would end further from its target than it started, which only an unusual fill causes; retry later.

None of these changes anything, and an unfinished quarter only means the basket keeps its quantities until later tranches.

**Backing per share fell.** Minting, redeeming and claims never lower it, so a fall outside a reset means an issuer seized or burned vault holdings. Check the stock's `Transfer` events from the vault and the issuer's announcements. Claims are paid before holders, so holders absorb the loss.

**Minting blocked.** An issuer seizure may have pushed a stock below the vault's precision floor. Remaining backing can still be redeemed subject to token availability and transfer rules. Reset tranches can rebuild the stock only if sufficient backing remains, reserves are covered, prices are usable and trades can execute.

**Preflight failure.** The message names the check:
- a paused stock or issuer feed;
- a policy that now rejects the vault or gateway;
- changed feed decimals.

The contracts fail closed. Holders' in-kind exit through `redeemBasketWithClaims` still delivers every asset that can move, and defers the rest as claims. A replaced stock contract or retired feed needs a new deployment and a voluntary migration.
