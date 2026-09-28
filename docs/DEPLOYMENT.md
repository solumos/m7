# M7 mainnet deployment runbook

This runbook deploys M7 to Base mainnet, seeds it, runs the first quarterly reset and keeps it monitored. Each step gives the command, what a good result looks like, and when to stop.

None of the five contracts has an owner or charges a protocol fee. M7 has no privileged pause or upgrade function; external asset restrictions, unavailable dependencies, and its own execution gates can still stop operations. A mistake after the bootstrap can require a new deployment and voluntary holder migration, subject to the assets being transferable. The contracts have not had an independent audit; launching without one is the launch organizer's decision. Say so wherever the deployment is announced.

## Roles and funding

Every mainnet transaction is signed by the role's owner with a hardware wallet or an encrypted Foundry keystore. No private key belongs in `.env` or on the monitoring server.

| Role | Holds | Authority |
|---|---|---|
| Deployer, a fresh EOA used for nothing else until the deploy | about 0.01 ETH and the seed's USDC budget: the seed's value plus about 3% | Deploys the five contracts and calls `bootstrap` once; none afterwards |
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

| When | Phase |
|---|---|
| Now to Tue Sep 29 | Phase 0: preparation |
| Wed Sep 30, 18:00 | Cobalt hard fork activates on Base mainnet |
| Thu Oct 1 | Phase 1: go/no-go on post-Cobalt state. Phase 2: deploy |
| Oct 1–2, US market hours | Phase 3: seed, bootstrap, smoke tests, first reset, announce |
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
     script/rehearse.sh
   ```

   It must end with `Rehearsal passed`. Its last step is the first reset with the `Rebalance` script: inside the execution window (a weekday, 15:00–20:00 UTC) the reset runs on the fork; outside it, the valuation must refuse it and change nothing. The fork source must serve recent history: `mainnet.base.org` does when throttled as above, and so may your private endpoint. The rehearsal applies Cobalt's rules by default; set `BASE_UPGRADE=beryl` for the rules mainnet runs before activation. With `DEPLOYER` set to the real deployer, it previews the exact mainnet addresses.

4. **Wallets and services.** Create and fund the roles above. Set `DEPLOYER`, `SEED_RECEIVER` and `SEED_USD` in `.env`. Set up the monitor server (see [Monitoring](#monitoring)) and test its webhook.

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

3. Re-run the native tests and the rehearsal (Phase 0, steps 2 and 3). They now fork a post-activation block. Run the rehearsal between 15:00 and 20:00 UTC so that it also runs the first reset.

**Go** only if all three pass.

## Phase 2: deploy

1. Build with the deploying toolchain. The verifier compares bytecode with this build:

   ```sh
   "$BASE_FORGE" build
   ```

2. Simulate:

   ```sh
   "$BASE_FORGE" script script/Deploy.s.sol:Deploy --rpc-url "$BASE_RPC_URL" --sender "$DEPLOYER"
   ```

   Check that the logged `Vault` equals `$VAULT_PREDICTED`. The run must end `SIMULATION COMPLETE`.

3. Broadcast five transactions: the Valuation, controller, vault and gateway, then the read-only lens. Send nothing else from the deployer until all five are mined:

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

## Phase 3: seed, bootstrap, smoke tests and the first reset

Run this during US market hours (13:30–20:00 UTC), when feeds are fresh and pools track prices.

1. Size an equal-value seed at current prices:

   ```sh
   python3 scripts/seed_basket.py --usd "$SEED_USD" --vault "$VAULT" --receiver "$SEED_RECEIVER"
   ```

   Review `config/seed.json` and fund the deployer with the printed `usdc_budget_for_acquire_seed`. Every stock needs at least 0.01 tokens, so the seed must be worth at least about $53 at current prices; the script refuses a smaller seed and prints the minimum. Only 1% of the seed stays locked for good.

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
   EXECUTOR=$ME "$BASE_FORGE" script script/Maintain.s.sol:Rebalance --rpc-url "$BASE_RPC_URL" --ledger \
     --sender "$ME" --broadcast --gas-estimate-multiplier 200
   ```

   The seed is already at equal value, so this first call trades nothing and completes the quarter: the script prints `Reset complete`, and `rebalanceDue()` becomes false. A revert changes nothing (`OutsideExecutionWindow`, `NoFreshMarketSignal`, `Too little received`, `PoolMoved`); retry later. The next quarter's reset opens 30 days after this one completed.

6. Commit `config/seed.json` and `deployments/base-mainnet.json`, then tag the deployed commit and push the tag: `git tag -a v1.0.0 <commit in deployments/base-mainnet.json> && git push origin v1.0.0`.

**Abort rule:** if a smoke test fails, don't announce. The seed receiver can take the seed out in kind with `redeemBasketWithClaims`.

## Announce

Once the smoke tests pass and the monitor is running, publish:
- the five addresses, with links to their verified source;
- the rules ([METHODOLOGY.md](METHODOLOGY.md)): equal weight, reset quarterly by anyone, no fee and no owner;
- the risks, including that there has been no independent audit.

## Phase 4: the quarterly reset

Each calendar quarter, anyone may run the reset, on weekdays between 15:00 and 20:00 UTC, in tranches at least 30 minutes apart. Each tranche trades at most about $10,000 per stock and the script says whether the quarter completed or when the next tranche may start: run it again until it prints `Reset complete`. A small vault completes in one tranche; in a volatile quarter a $1M vault takes a handful. Once the vault is large enough, the reward (5 bp of each tranche's traded value, up to $25) should attract others to do it; until then, run the `Rebalance` script above yourself early in the quarter. The monitor reports a reset in progress, alerts when a quarter's reset is still incomplete a week after it opens, and as critical with 21 days or fewer left. If a quarter ends first, nothing breaks: the next quarter's tranches continue it, and the basket keeps its quantities meanwhile.

## Monitoring

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
*/15 * * * * cd /opt/m7 && set -a && . /etc/m7/monitor.env && python3 scripts/monitor.py >> /var/log/m7-monitor.log 2>&1
```

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
