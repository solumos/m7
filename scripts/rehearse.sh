#!/usr/bin/env bash
# Dress rehearsal of the mainnet runbook (docs/DEPLOYMENT.md) on a local base-anvil fork of Base mainnet.
#
# Every transaction goes to the local fork: no keys, no mainnet broadcast. The repository is copied to a temporary
# directory so rehearsal broadcast files never mix with real ones. Accounts are impersonated and funded on the fork.
#
#   BASE_RPC_URL=<Base mainnet RPC> scripts/rehearse.sh
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
account() { cast to-check-sum-address "0x$(cast keccak "M7 rehearsal $1" | cut -c 27-66)"; }
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
  # A fixed gas limit: the fork's gas estimates for B20 precompile calls can come out too low.
  cast send --rpc-url "$LOCAL" --unlocked --json --gas-limit 8000000 "$@" >"$WORK/logs/send.log" 2>&1 ||
    { cat "$WORK/logs/send.log"; fail "cast send $* (a fork source without recent history fails here)"; }
  if [ "$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["status"])' "$WORK/logs/send.log")" != 0x1 ]; then
    cast call --rpc-url "$LOCAL" "$@" 2>&1 | tail -3  # replays the call to show the revert reason
    fail "transaction reverted: $*"
  fi
}

monitor_ok() { # readable, and no critical alert except the quarter deadline (real near a quarter end)
  sed -n '/^{/,$p' "$1" | python3 -c 'import json, sys; d = json.load(sys.stdin); sys.exit(not d["readable"] or any(
    a["level"] == "critical" and not a["message"].startswith("The quarter ends at") for a in d["alerts"]))'
}
WORK=$(mktemp -d "${TMPDIR:-/tmp}/m7-rehearsal.XXXXXX")
mkdir -p "$WORK/logs"
# Keep source and Git provenance, but leave credentials, website builds and local caches behind.
rsync -a --exclude broadcast --exclude cache --exclude out --include .env.example --exclude '.env*' \
  --exclude '*.env' --exclude '*.key' --exclude '*.pem' --exclude keystore --exclude keystores \
  --exclude node_modules --exclude dist --exclude test-results --exclude playwright-report \
  --exclude .vercel --include '/.impeccable/config.json' --exclude '/.impeccable/*' \
  --exclude __pycache__ "$ROOT/" "$WORK/repo/"
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
REHEARSAL_USER=$(account user)
export DEPLOYER
NONCE=$(cast nonce "$DEPLOYER" --rpc-url "$LOCAL")
step "Preflight: deployer $DEPLOYER (nonce $NONCE), seed receiver $RECEIVER"
PREDICTED_VAULT=$(cast compute-address "$DEPLOYER" --nonce $((NONCE + 2)) | awk '{print $NF}')
PREDICTED_GATEWAY=$(cast compute-address "$DEPLOYER" --nonce $((NONCE + 3)) | awk '{print $NF}')
python3 -m scripts.verify_base --rpc "$LOCAL" --reads-only --account "$DEPLOYER" --account "$RECEIVER" \
  --account "$PREDICTED_VAULT" --account "$PREDICTED_GATEWAY" >"$WORK/logs/preflight.json" ||
  fail "verify_base.py (see $WORK/logs/preflight.json)"

step "Deploy (predicted vault $PREDICTED_VAULT)"
fund "$DEPLOYER" $((SEED_USD * 2 * 1000000))
forge_script scripts/Deploy.s.sol:Deploy "$DEPLOYER"
read -r VALUATION CONTROLLER VAULT GATEWAY LENS < <(python3 - <<'EOF'
import json
d = json.load(open('broadcast/Deploy.s.sol/8453/run-latest.json'))
a = {t['contractName']: t['contractAddress'] for t in d['transactions'] if t.get('transactionType') == 'CREATE'}
print(a['Valuation'], a['IndexController'], a['M7Vault'], a['USDCGateway'], a['M7Lens'])
EOF
)
export VAULT CONTROLLER GATEWAY
[ "$(cast to-check-sum-address "$VAULT")" = "$(cast to-check-sum-address "$PREDICTED_VAULT")" ] ||
  fail "vault address differs from the prediction"
python3 -m scripts.verify_deployment --rpc "$LOCAL" \
  --write-record "$WORK/deployment-record.json" >"$WORK/logs/verify-deployment.json" ||
  fail "verify_deployment.py (see $WORK/logs/verify-deployment.json)"

step "Size the seed, acquire it from the pinned pools and bootstrap"
python3 -m scripts.seed_basket --usd "$SEED_USD" --vault "$VAULT" \
  --receiver "$RECEIVER" --out config/rehearsal/seed.json --rpc "$LOCAL" --max-feed-age 604800 \
  >"$WORK/logs/seed.json" || fail "seed_basket.py (see $WORK/logs/seed.json)"
export SEED_FILE=config/rehearsal/seed.json MAX_FEED_AGE=604800 GATEWAY
forge_script scripts/AcquireSeed.s.sol:AcquireSeed "$DEPLOYER"
forge_script scripts/Bootstrap.s.sol:Bootstrap "$DEPLOYER"
python3 -m scripts.verify_deployment --rpc "$LOCAL" --bootstrapped \
  --seed config/rehearsal/seed.json >"$WORK/logs/verify-bootstrap.json" ||
  fail "verify_deployment.py --bootstrapped (see $WORK/logs/verify-bootstrap.json)"
PRICE=$(cast call "$LENS" 'pricePerShare()(uint256,uint256)' --rpc-url "$LOCAL" | head -1 | awk '{print $1}')
TOTAL=$(cast call "$LENS" 'totalValue()(uint256,uint256)' --rpc-url "$LOCAL" | head -1 | awk '{print $1}')
python3 -c 'import sys; p, t = int(sys.argv[1]), int(sys.argv[2]); sys.exit(abs(p * 1000 - t) > 1000)' \
  "$PRICE" "$TOTAL" || fail "total value $TOTAL is not 1,000 shares at $PRICE"  # the seed's 1,000 shares
python3 -c 'import sys; p, usd = int(sys.argv[1]), int(sys.argv[2]); sys.exit(abs(p * 1000 / 10**18 - usd) > usd * 0.03)' \
  "$PRICE" "$SEED_USD" || fail "the lens prices a share at $PRICE, not about SEED_USD / 1000"

step "Smoke tests: gateway mint and redeem, in-kind resilient redemption, receipt transfer"
fund "$REHEARSAL_USER" 20000000
DEADLINE=$(($(cast block latest -f timestamp --rpc-url "$LOCAL") + 3600))
send --from "$REHEARSAL_USER" "$USDC" 'approve(address,uint256)' "$GATEWAY" 20000000
send --from "$REHEARSAL_USER" "$GATEWAY" 'mintWithUSDC(uint256,uint256,address,uint256)' 3000000000000000000 20000000 \
  "$REHEARSAL_USER" "$DEADLINE"
[ "$(cast call "$VAULT" 'balanceOf(address)(uint256)' "$REHEARSAL_USER" --rpc-url "$LOCAL" | awk '{print $1}')" = \
  3000000000000000000 ] || fail "gateway mint"
send --from "$REHEARSAL_USER" "$VAULT" 'approve(address,uint256)' "$GATEWAY" 1000000000000000000
send --from "$REHEARSAL_USER" "$GATEWAY" 'redeemToUSDC(uint256,uint256,address,uint256)' 1000000000000000000 0 "$REHEARSAL_USER" \
  "$DEADLINE"
send --from "$REHEARSAL_USER" "$VAULT" 'redeemBasketWithClaims(uint256,uint256[8],address,uint256)' 1000000000000000000 \
  '[0,0,0,0,0,0,0,0]' "$REHEARSAL_USER" "$DEADLINE"
send --from "$REHEARSAL_USER" "$VAULT" 'transfer(address,uint256)' "$RECEIVER" 500000000000000000
for i in 0 1 2 3 4 5 6 7; do
  [ "$(cast call "$VAULT" 'reserved(uint256)(uint256)' $i --rpc-url "$LOCAL" | awk '{print $1}')" = 0 ] ||
    fail "a redemption leg was deferred"
done
[ "$(cast call "$USDC" 'balanceOf(address)(uint256)' "$GATEWAY" --rpc-url "$LOCAL" | awk '{print $1}')" = 0 ] ||
  fail "the gateway kept USDC"

step "Reset status and monitoring"
[ "$(cast call "$CONTROLLER" 'rebalanceDue()(bool)' --rpc-url "$LOCAL")" = true ] ||
  fail "a fresh deployment should have this quarter's reset due"
python3 -m scripts.monitor --controller "$CONTROLLER" --gateway "$GATEWAY" --lens "$LENS" --rpc "$LOCAL" \
  --state-file "$WORK/monitor-state.json" >"$WORK/logs/monitor.json" || true
monitor_ok "$WORK/logs/monitor.json" || fail "monitor.py alert or read failure (see $WORK/logs/monitor.json)"
grep -q "equal-weight reset" "$WORK/logs/monitor.json" || fail "monitor did not report the due reset"
grep -q '"price_per_share_usd"' "$WORK/logs/monitor.json" || fail "monitor did not report the price per share"

step "First reset, with the runbook's Maintain.s.sol:Rebalance"
# Inside the execution window (a weekday, 15:00-20:00 UTC, with fresh prices) a tranche runs on the fork; the
# equal-value seed needs no trade, so it completes the quarter. Outside the window, the valuation's gates must refuse
# it and leave this quarter's reset due.
LOG="$WORK/logs/rebalance.log"
QUARTER=$(cast call "$CONTROLLER" 'currentQuarter()(uint32)' --rpc-url "$LOCAL")
if EXECUTOR=$REHEARSAL_USER "$BIN/forge" script scripts/Maintain.s.sol:Rebalance --rpc-url "$LOCAL" --unlocked --sender "$REHEARSAL_USER" \
  --broadcast --gas-estimate-multiplier 200 >"$LOG" 2>&1; then
  [ "$(cast call "$CONTROLLER" 'rebalanceDue()(bool)' --rpc-url "$LOCAL")" = false ] || fail "a tranche ran but no cooldown began"
  python3 -m scripts.monitor --controller "$CONTROLLER" --gateway "$GATEWAY" --lens "$LENS" --rpc "$LOCAL" \
    --state-file "$WORK/monitor-state.json" >"$WORK/logs/monitor-after-reset.json" || true
  monitor_ok "$WORK/logs/monitor-after-reset.json" ||
    fail "monitor.py alert or read failure after the reset (see $WORK/logs/monitor-after-reset.json)"
  if [ "$(cast call "$CONTROLLER" 'executedQuarter(uint32)(bool)' "$QUARTER" --rpc-url "$LOCAL")" = true ]; then
    ! grep -q "equal-weight reset" "$WORK/logs/monitor-after-reset.json" || fail "the monitor still reports the reset"
    RESET="completed on the fork"
  else
    grep -q "in progress" "$WORK/logs/monitor-after-reset.json" || fail "the monitor does not report the tranches"
    RESET="one tranche ran on the fork; the quarter needs more, at least 30 minutes apart"
  fi
else
  GATE=$(grep -o -E 'OutsideExecutionWindow|NoFreshMarketSignal|UnavailablePrice\([0-9]+\)|SequencerUnavailable' "$LOG" |
    head -1 || true)
  [ -n "$GATE" ] || { tail -40 "$LOG"; fail "Maintain.s.sol:Rebalance (see $LOG)"; }
  [ "$(cast call "$CONTROLLER" 'rebalanceDue()(bool)' --rpc-url "$LOCAL")" = true ] || fail "a refused reset changed state"
  RESET="refused by the valuation's gates ($GATE); rehearse in the execution window to run it"
fi

step "Rehearsal passed"
cat <<EOF
Upgrade rules:   $UPGRADE
Valuation:       $VALUATION
IndexController: $CONTROLLER
M7Vault:         $VAULT
USDCGateway:     $GATEWAY
M7Lens:          $LENS
Price per share: $(python3 -c "print('%.6f' % ($PRICE / 1e18))") USD
Total value:     $(python3 -c "print('%.2f' % ($TOTAL / 1e18))") USD
Record:          $WORK/deployment-record.json
First reset:     $RESET
Logs:            $WORK/logs
BaseForkTest runs a trading reset through the live pools, with feeds reported fresh.
EOF
