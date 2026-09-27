#!/usr/bin/env python3
"""Scheduled M7CAP monitor for an always-on server. Read-only: no keys, signatures, or transactions.

Each run (every 15 minutes from ops/m7cap-monitor.timer) reads the controller's proposal state with
watch_index.py, records the price per share from M7CapLens, checks the vault's assets, and, at most hourly, runs
the verify_base.py read checks with the vault and gateway as policy accounts. New or changed alerts at or above NOTIFY_LEVEL go to ALERT_WEBHOOK_URL (Slack or Discord JSON). Open
critical alerts repeat every six hours and cleared ones are announced. HEARTBEAT_URL is pinged after every run
that read the chain and delivered its alerts, so a heartbeat service notices a dead monitor, server or RPC.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import sys
import time
import urllib.request

from index_snapshot import SYMBOLS
from verify_base import RPC, address, verify
from watch_index import LEVELS, monitor

ROOT = Path(__file__).resolve().parents[1]
REPEAT_CRITICAL_SECONDS = 6 * 3600
PREFLIGHT_INTERVAL_SECONDS = 3600
WAD = 10**18


def alert_key(alert):
    return hashlib.sha256((alert['level'] + '|' + alert['message']).encode()).hexdigest()[:16]


def plan_notifications(alerts, state, now, notify_level='action'):
    """Messages to send and the next state. An alert at or above `notify_level` is sent when it first appears;
    an open critical alert repeats every REPEAT_CRITICAL_SECONDS; a sent alert that clears is announced."""
    floor = LEVELS.index(notify_level)
    previous = state.get('open', {})
    current, messages = {}, []
    for alert in alerts:
        key = alert_key(alert)
        entry = previous.get(key, {'level': alert['level'], 'message': alert['message'],
                                   'first_seen': now, 'last_sent': None})
        due = entry['last_sent'] is None or (
            alert['level'] == 'critical' and now - entry['last_sent'] >= REPEAT_CRITICAL_SECONDS)
        if LEVELS.index(alert['level']) >= floor and due:
            messages.append('[M7CAP %s] %s' % (alert['level'].upper(), alert['message']))
            entry = dict(entry, last_sent=now)
        current[key] = entry
    for key, entry in previous.items():
        if key not in current and entry.get('last_sent') is not None:
            messages.append('[M7CAP RESOLVED] ' + entry['message'])
    return messages, dict(state, open=current)


def decode_value(words):
    """M7CapLens.value(): a static tuple of perShare, nav, supply, components[8], oldestPriceAt and two flags."""
    if len(words) != 14 or words[12] not in (0, 1) or words[13] not in (0, 1):
        raise ValueError('Malformed M7CapLens value')
    return {'price_per_share_usd': '%.6f' % (words[0] / WAD), 'nav_usd': '%.2f' % (words[1] / WAD),
            'supply': '%.6f' % (words[2] / WAD), 'oldest_price_at': words[11],
            'issuer_paused': bool(words[12]), 'sequencer_down': bool(words[13])}


def vault_state(rpc, controller, vault, lens, state):
    """Price per share and alerts on the vault's assets. Backing per share never falls through minting, redeeming
    or claims, so a fall outside a rebalance means an issuer seized or burned vault holdings."""
    alerts, report = [], {}
    supply = rpc.call(vault, 'totalSupply()')[0]
    backing = [rpc.call(vault, 'backing(uint256)', i)[0] for i in range(8)]
    reserved = [rpc.call(vault, 'reserved(uint256)', i)[0] for i in range(8)]
    last_executed = rpc.call(controller, 'lastExecutedQuarter()')[0]
    if lens:
        report.update(decode_value(rpc.call(lens, 'value()')))
    if supply:
        per_share = [b * WAD // supply for b in backing[:7]]
        previous = state.get('backing_per_share')
        if previous and state.get('last_executed_quarter') == last_executed:
            fell = [SYMBOLS[i] for i in range(7) if per_share[i] < int(previous[i])]
            if fell:
                alerts.append({'level': 'critical', 'message': 'Backing per share fell for %s outside a rebalance: '
                               'check for an issuer seizure or burn of vault holdings.' % ', '.join(fell)})
        state['backing_per_share'] = [str(x) for x in per_share]
        state['last_executed_quarter'] = last_executed
        try:
            rpc.call(vault, 'quoteMint(uint256)', WAD)
        except ValueError as exc:
            alerts.append({'level': 'critical', 'message': 'New minting is blocked: %s' % exc})
    owed = [(SYMBOLS + ('USDC',))[i] for i in range(8) if reserved[i]]
    if owed:
        alerts.append({'level': 'action', 'message': 'Deferred claims are outstanding for %s: the vault could not '
                       'deliver them to redeemers.' % ', '.join(owed)})
    return alerts, report


def request(url, payload=None):
    data = None if payload is None else json.dumps(payload).encode()
    req = urllib.request.Request(url, data=data, headers={'Content-Type': 'application/json',
                                                           'User-Agent': 'm7cap-monitor/0.1'})
    with urllib.request.urlopen(req, timeout=30) as response:
        response.read()


def collect(args, state, now):
    """Current alerts, the vault's price report, and whether the chain could be read."""
    alerts, readable, report = [], True, {}
    try:
        rpc = RPC(args.rpc)
        expected = json.loads(Path(args.expected_snapshot).read_text()) if args.expected_snapshot else None
        alerts += monitor(args.controller, rpc, expected)['alert_levels']
        vault = args.vault or address(rpc.call(args.controller, 'vault()')[0])
        state_alerts, report = vault_state(rpc, args.controller, vault, args.lens, state)
        alerts += state_alerts
        report.update(block=int(rpc.block['number'], 16))
    except Exception as exc:
        readable, vault = False, args.vault
        alerts.append({'level': 'critical', 'message': 'Watcher could not read the controller: %s' % exc})
    if now - state.get('last_preflight', 0) >= PREFLIGHT_INTERVAL_SECONDS:
        accounts = [a for a in (vault, args.gateway) if a]
        try:
            verify(json.loads(Path(args.manifest).read_text()), args.rpc, accounts=accounts)
            state['preflight_error'] = None
        except Exception as exc:
            state['preflight_error'] = str(exc)
        state['last_preflight'] = now
    if state.get('preflight_error'):
        alerts.append({'level': 'critical', 'message': 'Preflight read checks failed: ' + state['preflight_error']})
    return alerts, readable, report


def main():
    env = os.environ.get
    state_dir = env('STATE_DIRECTORY')  # set by systemd's StateDirectory=
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('--controller', default=env('CONTROLLER'))
    p.add_argument('--vault', default=env('VAULT'), help='Defaults to controller.vault()')
    p.add_argument('--gateway', default=env('GATEWAY'))
    p.add_argument('--lens', default=env('LENS'), help='M7CapLens, for the price per share')
    p.add_argument('--rpc', default=env('BASE_RPC_URL'))
    p.add_argument('--expected-snapshot', default=env('EXPECTED_SNAPSHOT'),
                   help='The reviewed index_snapshot.py output for the current quarter')
    p.add_argument('--manifest', default=str(ROOT / 'config/base.json'))
    p.add_argument('--webhook', default=env('ALERT_WEBHOOK_URL'))
    p.add_argument('--heartbeat', default=env('HEARTBEAT_URL'))
    p.add_argument('--notify-level', choices=LEVELS, default=env('NOTIFY_LEVEL', 'action'))
    p.add_argument('--state-file', default=env('STATE_FILE') or str(
        Path(state_dir) / 'state.json' if state_dir else Path.home() / '.m7cap-monitor/state.json'))
    p.add_argument('--history-file', default=env('HISTORY_FILE'),
                   help='Appends one JSON line of price per share per run; defaults beside the state file')
    args = p.parse_args()
    if not args.controller or not args.rpc:
        p.error('CONTROLLER and BASE_RPC_URL are required')

    now = int(time.time())
    state_file = Path(args.state_file)
    state = json.loads(state_file.read_text()) if state_file.exists() else {}
    alerts, readable, report = collect(args, state, now)
    if report.get('price_per_share_usd'):
        history = Path(args.history_file or state_file.parent / 'price-history.jsonl')
        history.parent.mkdir(parents=True, exist_ok=True)
        with history.open('a') as out:
            out.write(json.dumps(dict(report, time=now), sort_keys=True) + '\n')
    messages, state = plan_notifications(alerts, state, now, args.notify_level)
    delivered = True
    for message in messages:
        if not args.webhook:
            print(message)
            continue
        try:
            request(args.webhook, {'text': message, 'content': message})  # Slack reads text, Discord content
        except Exception as exc:
            delivered = False
            print('Alert delivery failed: %s' % exc, file=sys.stderr)
    if delivered:
        # Undelivered alerts stay unsent, so the next run retries them.
        state_file.parent.mkdir(parents=True, exist_ok=True)
        state_file.write_text(json.dumps(state, indent=2) + '\n')
    if readable and delivered and args.heartbeat:
        try:
            request(args.heartbeat)
        except Exception as exc:
            print('Heartbeat failed: %s' % exc, file=sys.stderr)
    print(json.dumps({'time': now, 'readable': readable, 'vault': report, 'alerts': alerts,
                      'sent': messages if delivered else []}, indent=2))
    if not readable or not delivered:
        return 2
    return 1 if any(a['level'] == 'critical' for a in alerts) else 0


if __name__ == '__main__':
    sys.exit(main())
