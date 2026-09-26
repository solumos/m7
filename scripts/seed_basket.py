#!/usr/bin/env python3
"""Size the bootstrap basket from a reviewed index snapshot. Read-only; writes the seed file Bootstrap.s.sol reads.

The seven raw stock amounts are in the snapshot's exact quantity ratios, so the first rebalance toward those
ratios has nothing to do. Current oracle prices only choose the scale: the basket is worth about the USD target.
No keys, signatures, or transactions.
"""
import argparse
from datetime import datetime, timezone
from fractions import Fraction
import json
import os
from pathlib import Path
import sys

from index_snapshot import SYMBOLS
from verify_base import RPC, address

ROOT = Path(__file__).resolve().parents[1]
WAD = 10**18
INITIAL_SHARES = 1_000 * WAD
LOCKED_SHARES = 10 * WAD
MIN_LOCKED_STOCK_UNITS = 10_000
# Smallest raw amount whose locked-share attribution, floor(raw * LOCKED / INITIAL), meets the vault's floor.
MIN_RAW = MIN_LOCKED_STOCK_UNITS * INITIAL_SHARES // LOCKED_SHARES


def checked_address(value, name):
    if not isinstance(value, str) or len(value) != 42 or not value.startswith('0x'):
        raise ValueError(name + ' must be a 20-byte hex address')
    if int(value, 16) == 0:
        raise ValueError(name + ' cannot be zero')
    return value


def snapshot_ratios(snapshot):
    if snapshot.get('symbols') != list(SYMBOLS):
        raise ValueError('Snapshot symbols are not in canonical order')
    ratios = [int(r) for r in snapshot['quantity_ratios']]
    if len(ratios) != 7 or sum(ratios) != WAD or min(ratios) <= 0:
        raise ValueError('Snapshot ratios must be seven positive integers summing to 1e18')
    return ratios


def size(ratios, prices, stock_units, usd):
    """Raw amounts floor(ratio * Q * unit / 1e18), where Q whole tokens in total are worth `usd` at `prices`."""
    usd = Fraction(usd)
    if usd <= 0 or min(prices) <= 0:
        raise ValueError('The USD target and every price must be positive')
    per_token = sum(Fraction(r, WAD) * p for r, p in zip(ratios, prices))
    total_tokens = usd / per_token
    raw = [int(Fraction(r, WAD) * total_tokens * unit) for r, unit in zip(ratios, stock_units)]
    short = [SYMBOLS[i] for i, amount in enumerate(raw) if amount < MIN_RAW]
    if short:
        # Every stock needs MIN_RAW units; the smallest ratio sets the minimum basket value.
        needed = max(usd * MIN_RAW / amount for amount in raw if amount) if all(raw) else None
        raise ValueError('Below the vault precision floor for ' + ', '.join(short)
                         + ('; use at least $%.2f' % float(needed) if needed else ''))
    value = sum(Fraction(amount, unit) * p for amount, unit, p in zip(raw, stock_units, prices))
    return raw, value


def build_seed(snapshot, prices, usd, vault, receiver, block):
    ratios = snapshot_ratios(snapshot)
    raw, value = size(ratios, prices, [10**8] * 7, usd)
    return {
        'chain_id': 8453,
        'vault': checked_address(vault, 'vault'),
        'receiver': checked_address(receiver, 'receiver'),
        'raw_amounts': raw + [0],
        'note': 'Bootstrap basket in the snapshot quantity ratios; stocks have 8 decimals, USDC is last and zero.',
        'provenance': {
            'quarter_id': snapshot['quarter_id'],
            'observation_sha256': snapshot['observation_sha256'],
            'quantity_ratios': [str(r) for r in ratios],
            'symbols': list(SYMBOLS),
            'usd_target': str(usd),
            'usd_value_at_prices': '%.6f' % float(value),
            'prices_usd': ['%.8f' % float(p) for p in prices],
            'block': block['number'],
            'block_timestamp': block['timestamp'],
        },
    }


def read_prices(rpc, manifest, max_age):
    now = int(rpc.block['timestamp'], 16)
    prices = []
    for asset in manifest['stocks'] + [manifest['usdc']]:
        values = rpc.call(asset['feed'], 'latestRoundData()')
        if len(values) != 5 or not 0 < values[1] < 2**255 or not 0 < values[3] <= now:
            raise ValueError('Invalid feed round for ' + asset.get('symbol', 'USDC'))
        if now - values[3] > max_age:
            raise ValueError('Feed older than the valuation max age: ' + asset.get('symbol', 'USDC'))
        prices.append(Fraction(values[1], 10**asset['feed_decimals']))
    # Express stock prices in USDC so the target is a USDC budget.
    return [p / prices[7] for p in prices[:7]]


def check_vault(rpc, manifest, vault):
    if rpc.rpc('eth_getCode', [vault, rpc.block['number']]) in ('0x', '0x0'):
        raise ValueError('No contract at the vault address')
    if rpc.call(vault, 'totalSupply()')[0] != 0:
        raise ValueError('Vault is already bootstrapped')
    expected = [s['address'] for s in manifest['stocks']] + [manifest['usdc']['address']]
    for i, asset in enumerate(expected):
        if address(rpc.call(vault, 'assets(uint256)', i)[0]).lower() != asset.lower():
            raise ValueError('Vault asset %d differs from the manifest' % i)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('snapshot', type=Path, nargs='?', default=ROOT / 'config/snapshot.json')
    parser.add_argument('--usd', default='1000', help='Approximate basket value in USDC (default 1000)')
    parser.add_argument('--vault', default=os.environ.get('VAULT'))
    parser.add_argument('--receiver', required=True, help='Receives the 990 unlocked seed shares')
    parser.add_argument('--out', type=Path, default=ROOT / 'config/seed.json')
    parser.add_argument('--manifest', type=Path, default=ROOT / 'config/base.json')
    parser.add_argument('--rpc', default=os.environ.get('BASE_RPC_URL', 'https://base-rpc.publicnode.com'))
    parser.add_argument('--max-feed-age', type=int, help='Oldest usable feed answer in seconds; defaults to the '
                        'valuation max age. Only rehearsals on a quiet fork should raise it')
    args = parser.parse_args()
    try:
        manifest = json.loads(args.manifest.read_text())
        rpc = RPC(args.rpc)
        vault = checked_address(args.vault, 'vault')
        check_vault(rpc, manifest, vault)
        block = {'number': int(rpc.block['number'], 16),
                 'timestamp': datetime.fromtimestamp(int(rpc.block['timestamp'], 16), timezone.utc).isoformat()}
        max_age = args.max_feed_age or manifest['risk_checks']['max_stock_feed_age_seconds']
        seed = build_seed(json.loads(args.snapshot.read_text()), read_prices(rpc, manifest, max_age), args.usd,
                          vault, args.receiver, block)
    except Exception as exc:
        print(json.dumps({'error': str(exc)}, indent=2))
        return 1
    args.out.write_text(json.dumps(seed, indent=2) + '\n')
    budget = Fraction(seed['provenance']['usd_value_at_prices']) * Fraction(101, 100)
    print(json.dumps({'seed_file': str(args.out), 'raw_amounts': seed['raw_amounts'],
                      'usd_value_at_prices': seed['provenance']['usd_value_at_prices'],
                      'usdc_budget_for_acquire_seed': '%.2f' % float(budget)}, indent=2))
    return 0


if __name__ == '__main__':
    sys.exit(main())
