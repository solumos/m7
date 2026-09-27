#!/usr/bin/env bash
# Dress rehearsal of the mainnet runbook (docs/DEPLOYMENT.md) on a local base-anvil fork of Base mainnet.
#
# Every transaction goes to the local fork: no keys, no mainnet broadcast. The repository is copied to a temporary
# directory so rehearsal broadcast files never mix with real ones. Accounts are impersonated and funded on the fork.
#
#   BASE_RPC_URL=<Base mainnet RPC> script/rehearse.sh
#
# The fork source must serve recent historical state: https://mainnet.base.org does; publicnode refuses once the
# fork is a few minutes old.
#
# Optional: BASE_UPGRADE (beryl or cobalt, default cobalt), DEPLOYER (default a fresh address; the real deployer
# previews the exact mainnet addresses), SEED_USD (default 1000), BASE_FOUNDRY_BIN, REHEARSAL_PORT (default 8547),
# ANVIL_FORK_FLAGS.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
BIN=${BASE_FOUNDRY_BIN:-$HOME/.base-foundry/nightly-98e7839c65f6/bin}
UPGRADE=${BASE_UPGRADE:-cobalt}
PORT=${REHEARSAL_PORT:-8547}
LOCAL="http://127.0.0.1:$PORT"
SEED_USD=${SEED_USD:-1000}
USDC=0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913
: "${BASE_RPC_URL:?set BASE_RPC_URL to a Base mainnet endpoint to fork}"
FORK_SOURCE=$BASE_RPC_URL

step() { printf '\n==> %s\n' "$*"; }
fail() { printf 'REHEARSAL FAILED: %s\n' "$*" >&2; exit 1; }
# A named rehearsal account: the last 20 bytes of keccak256(name). Nobody holds its key; the fork impersonates it.
account() { cast to-check-sum-address "0x$(cast keccak "M7CAP rehearsal $1" | cut -c 27-66)"; }
fund() { # fund <address> <usdc raw>: 10 ETH and a USDC balance written into USDC's balance mapping (slot 9)
  cast rpc --rpc-url "$LOCAL" anvil_setBalance "$1" 0x8AC7230489E80000 >/dev/null
  cast rpc --rpc-url "$LOCAL" anvil_setStorageAt "$USDC" "$(cast index address "$1" 9)" \
    "$(cast to-uint256 "$2")" >/dev/null
}
forge_script() { # forge_script <script:contract> <sender>
  "$BIN/forge" script "$1" --rpc-url "$LOCAL" --unlocked --sender "$2" --broadcast --slow \
    --gas-estimate-multiplier 200 >"$WORK/logs/$(echo "$1" | tr '/:' '__').log" 2>&1 ||
    { tail -40 "$WORK/logs/$(echo "$1" | tr '/:' '__').log"; fail "$1"; }
}
send() { # cast send exits 0 even when the transaction reverts, so check the receipt's status
  cast send --rpc-url "$LOCAL" --unlocked --json "$@" >"$WORK/logs/send.log" 2>&1 ||
    { cat "$WORK/logs/send.log"; fail "cast send $* (a fork source without recent history fails here)"; }
  if [ "$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["status"])' "$WORK/logs/send.log")" != 0x1 ]; then
    cast call --rpc-url "$LOCAL" "$@" 2>&1 | tail -3  # replays the call to show the revert reason
    fail "transaction reverted: $*"
  fi
}

monitor_ok() { # readable, and no critical alert except the quarter deadline (real near a quarter end)
  sed -n '/^{/,$p' "$1" | python3 -c 'import json, sys; d = json.load(sys.stdin); sys.exit(not d["readable"] or any(
    a["level"] == "critical" and not a["message"].startswith("Quarter ends in") for a in d["alerts"]))'
}
WORK=$(mktemp -d "${TMPDIR:-/tmp}/m7cap-rehearsal.XXXXXX")
mkdir -p "$WORK/logs"
rsync -a --exclude broadcast --exclude cache --exclude out "$ROOT/" "$WORK/repo/"
cd "$WORK/repo"
mkdir -p config/rehearsal
"$BIN/forge" build >/dev/null  # compile before forking, to keep the fork young

step "Starting base-anvil ($UPGRADE rules) forked from Base mainnet on $LOCAL"
# ANVIL_FORK_FLAGS passes extra fork options, e.g. "--compute-units-per-second 50" for a rate-limited source.
# shellcheck disable=SC2086
"$BIN/anvil" --base "$UPGRADE" --fork-url "$FORK_SOURCE" --port "$PORT" --auto-impersonate --silent \
  ${ANVIL_FORK_FLAGS:-} &
ANVIL=$!
trap 'kill $ANVIL 2>/dev/null || true' EXIT
for _ in $(seq 1 60); do cast chain-id --rpc-url "$LOCAL" >/dev/null 2>&1 && break; sleep 1; done
[ "$(cast chain-id --rpc-url "$LOCAL")" = 8453 ] || fail "the fork must keep chain id 8453"
export BASE_RPC_URL=$LOCAL FOUNDRY_BASE=$UPGRADE FOUNDRY_DISABLE_NIGHTLY_WARNING=1
case "$BASE_RPC_URL" in http://127.0.0.1:*) ;; *) fail "refusing a non-local RPC" ;; esac

DEPLOYER=${DEPLOYER:-$(account deployer)}
RECEIVER=$(account receiver)
PROPOSER=$(account proposer)
USER=$(account user)
export DEPLOYER
NONCE=$(cast nonce "$DEPLOYER" --rpc-url "$LOCAL")
step "Preflight: deployer $DEPLOYER (nonce $NONCE), seed receiver $RECEIVER"
PREDICTED_VAULT=$(cast compute-address "$DEPLOYER" --nonce $((NONCE + 2)) | awk '{print $NF}')
PREDICTED_GATEWAY=$(cast compute-address "$DEPLOYER" --nonce $((NONCE + 3)) | awk '{print $NF}')
python3 scripts/verify_base.py --rpc "$LOCAL" --reads-only --account "$DEPLOYER" --account "$RECEIVER" \
  --account "$PREDICTED_VAULT" --account "$PREDICTED_GATEWAY" >"$WORK/logs/preflight.json" ||
  fail "verify_base.py (see $WORK/logs/preflight.json)"

step "Deploy (predicted vault $PREDICTED_VAULT)"
fund "$DEPLOYER" $((SEED_USD * 2 * 1000000))
METHODOLOGY_URI=$(python3 scripts/ipfs_cid.py docs/METHODOLOGY.md)
export METHODOLOGY_URI
forge_script script/Deploy.s.sol:Deploy "$DEPLOYER"
read -r VALUATION CONTROLLER VAULT GATEWAY < <(python3 - <<'EOF'
import json
d = json.load(open('broadcast/Deploy.s.sol/8453/run-latest.json'))
a = {t['contractName']: t['contractAddress'] for t in d['transactions'] if t.get('transactionType') == 'CREATE'}
print(a['Valuation'], a['IndexController'], a['M7CapVault'], a['USDCGateway'])
EOF
)
export VAULT CONTROLLER GATEWAY
[ "$(cast to-check-sum-address "$VAULT")" = "$(cast to-check-sum-address "$PREDICTED_VAULT")" ] ||
  fail "vault address differs from the prediction"
python3 scripts/verify_deployment.py --rpc "$LOCAL" \
  --write-record "$WORK/deployment-record.json" >"$WORK/logs/verify-deployment.json" ||
  fail "verify_deployment.py (see $WORK/logs/verify-deployment.json)"

step "Fixture snapshot for the current quarter (REHEARSAL ONLY, not index data)"
QUARTER=$(cast call "$CONTROLLER" 'currentQuarter()(uint32)' --rpc-url "$LOCAL")
python3 - "$QUARTER" <<'EOF'
import hashlib, json, sys
quantities = [19, 12, 12, 9, 20, 20, 8]  # illustrative only
ratios = [q * 10**18 // sum(quantities) for q in quantities]
ratios[0] += 10**18 - sum(ratios)
digest = '0x' + hashlib.sha256(b'M7CAP rehearsal fixture: not index data').hexdigest()
json.dump({'methodology': 'M7CAP-v1', 'quarter_id': int(sys.argv[1]), 'observation_sha256': digest,
           'symbols': ['AAPLc', 'AMZNc', 'GOOGLc', 'METAc', 'MSFTc', 'NVDAc', 'TSLAc'],
           'quantity_ratios': [str(r) for r in ratios], 'scale': str(10**18),
           'note': 'REHEARSAL FIXTURE, NOT INDEX DATA'},
          open('config/rehearsal/snapshot.json', 'w'), indent=2)
EOF

step "Size the seed, acquire it from the pinned pools and bootstrap"
python3 scripts/seed_basket.py config/rehearsal/snapshot.json --usd "$SEED_USD" --vault "$VAULT" \
  --receiver "$RECEIVER" --out config/rehearsal/seed.json --rpc "$LOCAL" --max-feed-age 604800 \
  >"$WORK/logs/seed.json" || fail "seed_basket.py (see $WORK/logs/seed.json)"
export SEED_FILE=config/rehearsal/seed.json MAX_FEED_AGE=604800 GATEWAY
forge_script script/AcquireSeed.s.sol:AcquireSeed "$DEPLOYER"
forge_script script/Bootstrap.s.sol:Bootstrap "$DEPLOYER"
python3 scripts/verify_deployment.py --rpc "$LOCAL" --bootstrapped \
  --seed config/rehearsal/seed.json >"$WORK/logs/verify-bootstrap.json" ||
  fail "verify_deployment.py --bootstrapped (see $WORK/logs/verify-bootstrap.json)"

step "Smoke tests: gateway mint and redeem, in-kind resilient redemption, receipt transfer"
fund "$USER" 20000000
DEADLINE=$(($(cast block latest -f timestamp --rpc-url "$LOCAL") + 3600))
send --from "$USER" "$USDC" 'approve(address,uint256)' "$GATEWAY" 20000000
send --from "$USER" "$GATEWAY" 'mintWithUSDC(uint256,uint256,address,uint256)' 3000000000000000000 20000000 \
  "$USER" "$DEADLINE"
[ "$(cast call "$VAULT" 'balanceOf(address)(uint256)' "$USER" --rpc-url "$LOCAL" | awk '{print $1}')" = \
  3000000000000000000 ] || fail "gateway mint"
send --from "$USER" "$VAULT" 'approve(address,uint256)' "$GATEWAY" 1000000000000000000
send --from "$USER" "$GATEWAY" 'redeemToUSDC(uint256,uint256,address,uint256)' 1000000000000000000 0 "$USER" \
  "$DEADLINE"
send --from "$USER" "$VAULT" 'redeemBasketWithClaims(uint256,uint256[8],address,uint256)' 1000000000000000000 \
  '[0,0,0,0,0,0,0,0]' "$USER" "$DEADLINE"
send --from "$USER" "$VAULT" 'transfer(address,uint256)' "$RECEIVER" 500000000000000000
for i in 0 1 2 3 4 5 6 7; do
  [ "$(cast call "$VAULT" 'reserved(uint256)(uint256)' $i --rpc-url "$LOCAL" | awk '{print $1}')" = 0 ] ||
    fail "a redemption leg was deferred"
done
[ "$(cast call "$USDC" 'balanceOf(address)(uint256)' "$GATEWAY" --rpc-url "$LOCAL" | awk '{print $1}')" = 0 ] ||
  fail "the gateway kept USDC"

step "Propose the fixture, watch, travel 72 hours, settle"
fund "$PROPOSER" 2000000000
export PROPOSER SNAPSHOT_FILE=config/rehearsal/snapshot.json EVIDENCE_URI=ipfs://m7cap-rehearsal-fixture
forge_script script/Maintain.s.sol:Propose "$PROPOSER"
ASSERTION_ID=$(cast call "$CONTROLLER" 'latestProposal(uint32)(bytes32)' "$QUARTER" --rpc-url "$LOCAL")
export ASSERTION_ID EXECUTOR=$USER
python3 scripts/watch_index.py --controller "$CONTROLLER" --rpc "$LOCAL" \
  --expected-snapshot config/rehearsal/snapshot.json >"$WORK/logs/watch-pending.json" || true
grep -q 'Challenge window is open' "$WORK/logs/watch-pending.json" || fail "watcher did not see the open challenge"
python3 scripts/monitor.py --controller "$CONTROLLER" --gateway "$GATEWAY" --rpc "$LOCAL" \
  --expected-snapshot config/rehearsal/snapshot.json --state-file "$WORK/monitor-state.json" \
  >"$WORK/logs/monitor-pending.json" || true
monitor_ok "$WORK/logs/monitor-pending.json" || fail "monitor.py alert or read failure (see $WORK/logs/monitor-pending.json)"
cast rpc --rpc-url "$LOCAL" evm_increaseTime 259201 >/dev/null
cast rpc --rpc-url "$LOCAL" evm_mine >/dev/null
forge_script script/Maintain.s.sol:Settle "$USER"
[ "$(cast call "$CONTROLLER" 'acceptedProposal(uint32)(bytes32)' "$QUARTER" --rpc-url "$LOCAL")" = "$ASSERTION_ID" ] ||
  fail "the fixture proposal was not accepted"
python3 scripts/watch_index.py --controller "$CONTROLLER" --rpc "$LOCAL" \
  --expected-snapshot config/rehearsal/snapshot.json >"$WORK/logs/watch-accepted.json" || true
grep -q 'awaits permissionless execution' "$WORK/logs/watch-accepted.json" || fail "watcher missed the acceptance"
python3 scripts/monitor.py --controller "$CONTROLLER" --gateway "$GATEWAY" --rpc "$LOCAL" \
  --expected-snapshot config/rehearsal/snapshot.json --state-file "$WORK/monitor-state.json" \
  >"$WORK/logs/monitor-accepted.json" || true
monitor_ok "$WORK/logs/monitor-accepted.json" || fail "monitor.py alert or read failure (see $WORK/logs/monitor-accepted.json)"
grep -q 'awaits permissionless execution' "$WORK/logs/monitor-accepted.json" || fail "monitor did not report the due execution"

step "Rehearsal passed"
cat <<EOF
Upgrade rules:   $UPGRADE
Valuation:       $VALUATION
IndexController: $CONTROLLER
M7CapVault:      $VAULT
USDCGateway:     $GATEWAY
Record:          $WORK/deployment-record.json
Logs:            $WORK/logs
Execution is not rehearsed here: after 72 hours of time travel the fork's feeds are stale. BaseForkTest
covers a live-pool execution with feeds reported fresh.
EOF
