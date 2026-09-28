#!/usr/bin/env python3
"""Read-only Base integration preflight. No keys, signatures, or transactions."""
import argparse
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from fractions import Fraction
from functools import lru_cache
import json
import os
from pathlib import Path
import subprocess
import sys
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
SYMBOLS = ('AAPLc', 'AMZNc', 'GOOGLc', 'METAc', 'MSFTc', 'NVDAc', 'TSLAc')


def request(url, payload=None):
    data = None if payload is None else json.dumps(payload).encode()
    req = urllib.request.Request(url, data=data, headers={
        'Content-Type': 'application/json', 'User-Agent': 'm7-integration/0.1'})
    with urllib.request.urlopen(req, timeout=30) as response:
        return json.load(response)


@lru_cache(maxsize=None)
def selector(signature):
    # Ethereum uses Keccak, not hashlib.sha3_256; reuse installed Foundry.
    return subprocess.check_output(['cast', 'sig', signature], text=True).strip()


@lru_cache(maxsize=None)
def keccak_text(text):
    return int(subprocess.check_output(['cast', 'keccak', text], text=True).strip(), 16)


def rebalance_oracles_usable(now, stock_ages, usdc_age, risk):
    """Mirror Valuation.snapshot(): weekday window, every stock within its heartbeat age, one stock fresh."""
    day_of_week = (now // 86400 + 4) % 7
    time_of_day = now % 86400
    start, end = risk['execution_window_utc_seconds']
    checks = {
        'in_execution_window': day_of_week not in (0, 6) and start <= time_of_day < end,
        'stocks_within_max_age': all(age <= risk['max_stock_feed_age_seconds'] for age in stock_ages),
        'market_open_signal': any(age <= risk['fresh_signal_seconds'] for age in stock_ages),
        'usdc_within_max_age': usdc_age <= risk['max_usdc_feed_age_seconds'],
    }
    return all(checks.values()), checks


def word(value):
    number = int(value, 16) if isinstance(value, str) else value
    if not 0 <= number < 2**256:
        raise ValueError('ABI word out of range')
    return format(number, '064x')


def words(encoded):
    body = encoded[2:]
    if len(body) % 64:
        raise ValueError('Malformed ABI response')
    return [int(body[i:i+64], 16) for i in range(0, len(body), 64)]


def address(value):
    return '0x' + format(value, '040x')


class RPC:
    def __init__(self, url):
        self.url = url
        chain = self.rpc('eth_chainId', [])
        if int(chain, 16) != 8453:
            raise ValueError('RPC is not Base mainnet')
        self.block = self.rpc('eth_getBlockByNumber', ['latest', False])

    def rpc(self, method, params):
        response = request(self.url, {'jsonrpc': '2.0', 'id': 1, 'method': method, 'params': params})
        if 'error' in response:
            raise ValueError(str(response['error']))
        return response['result']

    def call(self, target, signature, *args):
        payload = selector(signature) + ''.join(word(arg) for arg in args)
        return words(self.rpc('eth_call', [{'to': target, 'data': payload}, self.block['number']]))

    def balance(self, target):
        return int(self.rpc('eth_getBalance', [target, self.block['number']]), 16)


def registry_answers_policy_zero(rpc, registry, accounts):
    """The vault constructor requires isAuthorized(0, vault) to answer true; so must every planned account."""
    rejected = [a for a in accounts if rpc.call(registry, 'isAuthorized(uint64,address)', 0, a)[0] != 1]
    if rejected:
        raise ValueError('Policy registry rejects policy 0 for ' + ', '.join(rejected))


def verify(manifest, rpc_url, accounts=()):
    rpc = RPC(rpc_url)
    now = int(rpc.block['timestamp'], 16)
    venue = manifest['venue']
    report = {'chain_id': 8453, 'block': int(rpc.block['number'], 16),
              'block_hash': rpc.block['hash'],
              'block_timestamp': datetime.fromtimestamp(now, timezone.utc).isoformat(),
              'rpc': rpc_url, 'errors': [], 'stocks': [], 'quotes': [],
              'quote_basis': 'equal dollar allocations: the index weights',
              'funded_transaction_test': 'not performed by this read-only tool; see manifest native_fork_verification',
              'launch_ready': False}
    report['applied_risk_checks'] = manifest['risk_checks']

    def require(condition, message):
        if not condition:
            raise ValueError(message)

    def feed_data(asset, max_age):
        require(rpc.call(asset['feed'], 'decimals()')[0] == asset['feed_decimals'], 'Feed decimals mismatch')
        values = rpc.call(asset['feed'], 'latestRoundData()')
        require(len(values) == 5 and 0 < values[1] < 2**255, 'Invalid feed answer')
        require(0 < values[3] <= now and values[4] >= values[0], 'Invalid oracle round')
        return {'answer': str(values[1]), 'updated_at': values[3],
                'age_seconds': now - values[3], 'fresh': now - values[3] <= max_age}

    issuer = {t['contract_address'].lower(): t for t in request(manifest['sources']['stock_api'])['tokens']}
    require(rpc.call(manifest['usdc']['address'], 'decimals()')[0] == 6, 'USDC decimals mismatch')
    report['usdc_feed'] = feed_data(manifest['usdc'], manifest['risk_checks']['max_usdc_feed_age_seconds'])
    sequencer = rpc.call(manifest['sequencer_feed'], 'latestRoundData()')
    require(len(sequencer) == 5 and sequencer[1] == 0, 'Sequencer down')
    require(0 < sequencer[2] <= now and now-sequencer[2] > manifest['risk_checks']['sequencer_grace_seconds'],
            'Sequencer grace period')
    report['sequencer_up_since'] = sequencer[2]
    for name in ('router', 'quoter'):
        actual = address(rpc.call(venue[name], 'factory()')[0])
        require(actual.lower() == venue['factory'].lower(), name + ' factory mismatch')
    report['router_factory_match'] = True
    registry_answers_policy_zero(rpc, manifest['policy_registry'], [venue['router'], *accounts])
    report['policy_zero_authorized'] = True

    def stock_check(stock):
        token = stock['address']
        official = issuer.get(token.lower())
        require(official and official['symbol'] == stock['symbol'] and official['decimals'] == stock['decimals'],
                'Issuer identity mismatch: ' + stock['symbol'])
        # B20 tokens are native precompiles. A bytecode check would incorrectly reject them.
        require(rpc.call(token, 'decimals()')[0] == stock['decimals'], 'Token decimals mismatch')
        require(rpc.call(token, 'totalSupply()')[0] > 0, 'Empty token supply')
        require(rpc.call(token, 'isPaused(uint8)', 0)[0] == 0, 'B20 transfers paused')
        multiplier, paused = rpc.call(manifest['registry'], 'getOracleParams(address)', token)
        require(multiplier > 0 and paused == 0, 'Issuer reference feed paused')
        pool = address(rpc.call(venue['factory'], 'getPool(address,address,int24)',
                                token, manifest['usdc']['address'], stock['tick_spacing'])[0])
        require(pool.lower() == stock['pool'].lower(), 'Pool mismatch')
        require(address(rpc.call(pool, 'factory()')[0]).lower() == venue['factory'].lower(), 'Pool factory mismatch')
        pair = {address(rpc.call(pool, 'token0()')[0]).lower(), address(rpc.call(pool, 'token1()')[0]).lower()}
        require(pair == {token.lower(), manifest['usdc']['address'].lower()}, 'Pool assets mismatch')
        liquidity = rpc.call(pool, 'liquidity()')[0]
        require(liquidity > 0, 'No active pool liquidity')
        policies = {}
        for scope in ('TRANSFER_SENDER_POLICY', 'TRANSFER_RECEIVER_POLICY', 'TRANSFER_EXECUTOR_POLICY'):
            scope_hash = rpc.call(token, scope + '()')[0]
            # M7Vault requires identical scope constants across all seven stocks.
            require(scope_hash == keccak_text(scope), stock['symbol'] + ': unexpected ' + scope + ' constant')
            policy = rpc.call(token, 'policyId(bytes32)', scope_hash)[0]
            policies[scope] = policy
            for account in [pool, venue['router'], venue['quoter'], *accounts]:
                require(rpc.call(manifest['policy_registry'], 'isAuthorized(uint64,address)', policy, account)[0] == 1,
                        stock['symbol'] + ': policy rejects ' + account)
        feed = feed_data(stock, manifest['risk_checks']['max_stock_feed_age_seconds'])
        return {**stock, 'feed_data': feed, 'multiplier_wad': str(multiplier),
                'active_liquidity': str(liquidity), 'policy_ids': policies}

    with ThreadPoolExecutor(max_workers=7) as executor:
        report['stocks'] = list(executor.map(stock_check, manifest['stocks']))
    stocks = report['stocks']
    def quote(stock, budget):
        # Quote equal USD notionals: the index's own weights.
        price = Fraction(int(stock['feed_data']['answer']), 10**stock['feed_decimals'])
        desired = int(budget * 10**stock['decimals'] / price)
        require(desired > 0, 'Probe too small')
        buy = rpc.call(venue['quoter'], 'quoteExactOutputSingle((address,address,uint256,int24,uint160))',
                       manifest['usdc']['address'], stock['address'], desired, stock['tick_spacing'], 0)[0]
        sell = rpc.call(venue['quoter'], 'quoteExactInputSingle((address,address,uint256,int24,uint160))',
                        stock['address'], manifest['usdc']['address'], desired, stock['tick_spacing'], 0)[0]
        require(buy > 0 and sell > 0, 'Zero executable quote')
        return {'symbol': stock['symbol'], 'stock_amount_raw': str(desired),
                'buy_usdc_raw': str(buy), 'sell_usdc_raw': str(sell)}

    for budget in (10, 100, 1000):
        with ThreadPoolExecutor(max_workers=7) as executor:
            legs = list(executor.map(lambda stock: quote(stock, Fraction(budget, 7)), stocks))
        buy = sum(int(leg['buy_usdc_raw']) for leg in legs)
        sell = sum(int(leg['sell_usdc_raw']) for leg in legs)
        report['quotes'].append({'reference_usd_notional': budget, 'legs': legs,
                                 'buy_usdc_raw': str(buy), 'sell_usdc_raw': str(sell),
                                 'buy_premium_bps_vs_reference': round((buy/(budget*10**6)-1)*10000, 4),
                                 'sell_discount_bps_vs_reference': round((1-sell/(budget*10**6))*10000, 4)})
    report['read_checks_passed'] = True
    usable, checks = rebalance_oracles_usable(
        now, [s['feed_data']['age_seconds'] for s in stocks], report['usdc_feed']['age_seconds'],
        manifest['risk_checks'])
    report['rebalance_oracle_checks'] = checks
    report['rebalance_oracles_currently_usable'] = usable
    report['remaining_launch_blockers'] = list(manifest['launch_blockers'])
    report['remaining_launch_blockers'] += ['Quotes are eth_call simulations at one block, not funded atomic gateway execution.']
    return report


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--manifest', type=Path, default=ROOT / 'config/base.json')
    p.add_argument('--rpc', default=os.environ.get('BASE_RPC_URL', 'https://base-rpc.publicnode.com'))
    p.add_argument('--account', action='append', default=[], help='Also check planned vault/gateway/holder addresses against B20 policies')
    p.add_argument('--reads-only', action='store_true',
                   help='Exit 0 when every read check passes, even outside the rebalance window (for monitoring)')
    args = p.parse_args()
    try:
        result = verify(json.loads(args.manifest.read_text()), args.rpc, args.account)
        print(json.dumps(result, indent=2))
        # Passing a read check never grants production approval. Stale feed => fail closed for rebalance preflight.
        return 0 if args.reads_only or result['rebalance_oracles_currently_usable'] else 1
    except Exception as exc:
        print(json.dumps({'read_checks_passed': False, 'launch_ready': False, 'error': str(exc)}, indent=2))
        return 1


if __name__ == '__main__':
    sys.exit(main())
