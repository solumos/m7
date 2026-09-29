#!/usr/bin/env python3
"""Size the bootstrap basket: equal USD value of each stock at current oracle prices. Read-only; writes the seed
file Bootstrap.s.sol reads.

An equal-value seed matches the controller's target, so the first quarterly reset has little or nothing to do. No
keys, signatures, or transactions.
"""
import argparse
from datetime import datetime, timezone
from fractions import Fraction
import json
import os
from pathlib import Path
import sys

from scripts.common import ROOT, RPC, SYMBOLS, address

WAD = 10**18
INITIAL_SHARES = 1_000 * WAD
LOCKED_SHARES = 10 * WAD
MIN_LOCKED_STOCK_UNITS = 10_000
# Smallest raw amount whose locked-share attribution, floor(raw * LOCKED / INITIAL), meets the vault's floor.
MIN_RAW = MIN_LOCKED_STOCK_UNITS * INITIAL_SHARES // LOCKED_SHARES
STOCK_UNIT = 10**8


def checked_address(value, name):
    if not isinstance(value, str) or len(value) != 42 or not value.startswith('0x'):
        raise ValueError(name + ' must be a 20-byte hex address')
    if int(value, 16) == 0:
        raise ValueError(name + ' cannot be zero')
    return value


def size(prices, usd):
    """Raw amounts worth usd / 7 each at `prices` (USDC per whole token), rounded down."""
    usd = Fraction(usd)
    if usd <= 0 or len(prices) != 7 or min(prices) <= 0:
        raise ValueError('The USD target and seven prices must be positive')
    raw = [int(usd / 7 / p * STOCK_UNIT) for p in prices]
    short = [SYMBOLS[i] for i, amount in enumerate(raw) if amount < MIN_RAW]
    if short:
        # Every stock needs MIN_RAW units; the priciest stock sets the minimum basket value.
        needed = max(Fraction(MIN_RAW, STOCK_UNIT) * p for p in prices) * 7
        raise ValueError('Below the vault precision floor for %s; use at least $%.2f' % (', '.join(short), needed))
    value = sum(Fraction(amount, STOCK_UNIT) * p for amount, p in zip(raw, prices))
    return raw, value


def build_seed(prices, usd, vault, receiver, block):
    raw, value = size(prices, usd)
    return {
        'chain_id': 8453,
        'vault': checked_address(vault, 'vault'),
        'receiver': checked_address(receiver, 'receiver'),
        'raw_amounts': raw + [0],
        'note': 'Bootstrap basket of equal value per stock; stocks have 8 decimals, USDC is last and zero.',
        'provenance': {
            'symbols': list(SYMBOLS),
            'usd_target': str(usd),
            'usd_value_at_prices': '%.6f' % float(value),
            'prices_usdc': ['%.8f' % float(p) for p in prices],
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
        seed = build_seed(read_prices(rpc, manifest, max_age), args.usd, vault, args.receiver, block)
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
