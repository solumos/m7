#!/usr/bin/env python3
"""Read-only check of a deployed M7CAP system: once before any funds go in, and again after the bootstrap.

Compares every constructor-set value of the four contracts with config/base.json, the environment and the exact
bytes of docs/METHODOLOGY.md, checks the contracts are bound to each other, and compares their runtime bytecode
with the local build artifacts (immutables and compiler metadata masked). Optionally writes the deployment
record. No keys, signatures, or transactions.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys

from ipfs_cid import raw_cid
from verify_base import RPC, address, keccak_text

ROOT = Path(__file__).resolve().parents[1]
CONTRACTS = ('Valuation', 'IndexController', 'M7CapVault', 'USDCGateway')
SEED_LOCK = '0x' + '00' * 19 + '01'
WAD = 10**18


def decode_string(words):
    if len(words) < 2 or words[0] != 32 or words[1] > 32 * (len(words) - 2):
        raise ValueError('Malformed ABI string')
    return b''.join(w.to_bytes(32, 'big') for w in words[2:])[:words[1]].decode('utf-8')


def masked_runtime(code, references):
    """Runtime code with immutable slots zeroed, split from its trailing CBOR metadata."""
    body = bytearray(code)
    for slots in references.values():
        for slot in slots:
            body[slot['start']:slot['start'] + slot['length']] = bytes(slot['length'])
    trailer = int.from_bytes(body[-2:], 'big') + 2
    if trailer > len(body):
        raise ValueError('Malformed metadata trailer')
    return bytes(body[:-trailer]), bytes(body[-trailer:])


def compare_bytecode(onchain_hex, artifact):
    onchain = bytes.fromhex(onchain_hex[2:])
    built = bytes.fromhex(artifact['deployedBytecode']['object'][2:])
    if len(onchain) != len(built):
        return False, False
    references = artifact['deployedBytecode'].get('immutableReferences', {})
    code, metadata = masked_runtime(onchain, references)
    expected_code, expected_metadata = masked_runtime(built, references)
    return code == expected_code, metadata == expected_metadata


def verify(rpc, manifest, addresses, expected, artifacts=None, seed=None):
    """`addresses` maps each contract name to its lowercase address. `expected` holds deployer, bond_floor,
    methodology (bytes) and optionally methodology_uri. `seed` switches to the post-bootstrap checks."""
    report = {'block': int(rpc.block['number'], 16), 'contracts': addresses, 'checks': [], 'failures': []}

    def check(name, actual, wanted):
        ok = actual == wanted
        entry = {'check': name, 'ok': ok}
        if not ok:
            entry.update(actual=str(actual), expected=str(wanted))
            report['failures'].append(name)
        report['checks'].append(entry)

    def num(target, signature, *args):
        return rpc.call(target, signature, *args)[0]

    def addr(target, signature, *args):
        return address(num(target, signature, *args)).lower()

    vault, controller = addresses['M7CapVault'], addresses['IndexController']
    gateway, valuation = addresses['USDCGateway'], addresses['Valuation']
    for name in CONTRACTS:
        code = rpc.rpc('eth_getCode', [addresses[name], rpc.block['number']])
        deployed = code not in ('0x', '0x0')
        check(name + ' has code', deployed, True)
        if deployed and artifacts:
            code_matches, metadata_matches = compare_bytecode(code, artifacts[name])
            check(name + ' runtime code matches the local build', code_matches, True)
            report.setdefault('metadata_matches', {})[name] = metadata_matches

    stocks, venue = manifest['stocks'], manifest['venue']
    assets = [s['address'].lower() for s in stocks] + [manifest['usdc']['address'].lower()]
    feeds = [s['feed'].lower() for s in stocks] + [manifest['usdc']['feed'].lower()]

    check('vault name', decode_string(rpc.call(vault, 'name()')), 'MAG7 Cap Index')
    check('vault symbol', decode_string(rpc.call(vault, 'symbol()')), 'M7CAP')
    check('vault decimals', num(vault, 'decimals()'), 18)
    for i, asset in enumerate(assets):
        check('vault asset %d' % i, addr(vault, 'assets(uint256)', i), asset)
    for i, stock in enumerate(stocks):
        check('vault tick spacing %d' % i, num(vault, 'tickSpacing(uint256)', i), stock['tick_spacing'])
    check('vault router', addr(vault, 'router()'), venue['router'].lower())
    check('vault factory', addr(vault, 'factory()'), venue['factory'].lower())
    check('vault policy registry', addr(vault, 'policyRegistry()'), manifest['policy_registry'].lower())
    check('vault controller', addr(vault, 'controller()'), controller)
    check('vault bootstrapper', addr(vault, 'bootstrapper()'), expected['deployer'])
    for scope in ('sender', 'receiver', 'executor'):
        check('vault %s scope' % scope, num(vault, scope + 'Scope()'),
              keccak_text('TRANSFER_%s_POLICY' % scope.upper()))

    check('controller vault', addr(controller, 'vault()'), vault)
    check('controller oracle', addr(controller, 'oracle()'), manifest['uma_oo_v3'].lower())
    check('controller bond currency', addr(controller, 'bondCurrency()'), assets[7])
    check('controller bond floor', num(controller, 'bondFloor()'), expected['bond_floor'])
    check('controller valuation', addr(controller, 'valuation()'), valuation)
    methodology = expected['methodology']
    check('controller methodology keccak256', num(controller, 'methodologyHash()'),
          keccak_text(methodology.decode('utf-8')))
    uri = decode_string(rpc.call(controller, 'methodologyURI()'))
    check('controller methodology URI is the raw CID of the file', uri, 'ipfs://' + raw_cid(methodology))
    if expected.get('methodology_uri'):
        check('controller methodology URI equals METHODOLOGY_URI', uri, expected['methodology_uri'])

    for i in range(8):
        check('valuation asset %d' % i, addr(valuation, 'assets(uint256)', i), assets[i])
        check('valuation feed %d' % i, addr(valuation, 'feeds(uint256)', i), feeds[i])
    check('valuation sequencer feed', addr(valuation, 'sequencer()'), manifest['sequencer_feed'].lower())
    check('valuation issuer registry', addr(valuation, 'registry()'), manifest['registry'].lower())
    check('valuation max age', num(valuation, 'maxAge()'), manifest['risk_checks']['max_stock_feed_age_seconds'])

    check('gateway vault', addr(gateway, 'vault()'), vault)
    check('gateway router', addr(gateway, 'router()'), venue['router'].lower())
    check('gateway usdc', addr(gateway, 'usdc()'), assets[7])

    if seed is None:
        check('vault is unseeded', num(vault, 'totalSupply()'), 0)
    else:
        check('seed file vault', seed['vault'].lower(), vault)
        check('vault supply', num(vault, 'totalSupply()'), 1_000 * WAD)
        check('locked seed shares', num(vault, 'balanceOf(address)', SEED_LOCK), 10 * WAD)
        check('receiver seed shares', num(vault, 'balanceOf(address)', seed['receiver']), 990 * WAD)
        for i in range(8):
            check('backing %d equals the seed' % i, num(vault, 'backing(uint256)', i), seed['raw_amounts'][i])
            check('reserved %d is zero' % i, num(vault, 'reserved(uint256)', i), 0)
        check('quoteMint answers eight amounts', len(rpc.call(vault, 'quoteMint(uint256)', WAD)), 8)
    report['ok'] = not report['failures']
    return report


def from_broadcast(path):
    """Contract addresses and creation receipts from a forge broadcast file."""
    data = json.loads(Path(path).read_text())
    receipts = {r['transactionHash']: r for r in data.get('receipts', [])}
    contracts, deployer = {}, None
    for tx in data['transactions']:
        if tx.get('transactionType') != 'CREATE' or tx.get('contractName') not in CONTRACTS:
            continue
        receipt = receipts.get(tx['hash'], {})
        contracts[tx['contractName']] = {
            'address': tx['contractAddress'].lower(), 'transaction': tx['hash'],
            'block': int(receipt['blockNumber'], 16) if receipt.get('blockNumber') else None,
            'status': receipt.get('status'),
        }
        deployer = tx['transaction']['from'].lower()
    missing = set(CONTRACTS) - set(contracts)
    if missing:
        raise ValueError('Broadcast file lacks: ' + ', '.join(sorted(missing)))
    return contracts, deployer


def git_state():
    commit = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
    dirty = bool(subprocess.check_output(['git', 'status', '--porcelain'], cwd=ROOT, text=True).strip())
    return commit, dirty


def toolchain():
    forge = os.environ.get('BASE_FORGE')
    if not forge:
        return None
    return subprocess.check_output([forge, '--version'], text=True).strip().splitlines()


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--broadcast', type=Path, default=ROOT / 'broadcast/Deploy.s.sol/8453/run-latest.json')
    p.add_argument('--manifest', type=Path, default=ROOT / 'config/base.json')
    p.add_argument('--methodology', type=Path, default=ROOT / 'docs/METHODOLOGY.md')
    p.add_argument('--artifacts', type=Path, default=ROOT / 'out', help='Build output to compare bytecode against')
    p.add_argument('--no-bytecode', action='store_true', help='Skip the runtime bytecode comparison')
    p.add_argument('--bond-floor', type=int, default=int(os.environ.get('BOND_FLOOR_USDC') or 1_000 * 10**6))
    p.add_argument('--methodology-uri', default=os.environ.get('METHODOLOGY_URI'))
    p.add_argument('--bootstrapped', action='store_true', help='Also check the state right after Bootstrap.s.sol')
    p.add_argument('--seed', type=Path, default=ROOT / os.environ.get('SEED_FILE', 'config/seed.json'))
    p.add_argument('--write-record', type=Path, help='Write the deployment record, e.g. deployments/base-mainnet.json')
    p.add_argument('--rpc', default=os.environ.get('BASE_RPC_URL', 'https://base-rpc.publicnode.com'))
    args = p.parse_args()
    try:
        manifest = json.loads(args.manifest.read_text())
        contracts, deployer = from_broadcast(args.broadcast)
        expected = {'deployer': deployer, 'bond_floor': args.bond_floor,
                    'methodology': args.methodology.read_bytes(), 'methodology_uri': args.methodology_uri}
        artifacts = None if args.no_bytecode else {
            name: json.loads((args.artifacts / (name + '.sol') / (name + '.json')).read_text()) for name in CONTRACTS}
        seed = json.loads(args.seed.read_text()) if args.bootstrapped else None
        report = verify(RPC(args.rpc), manifest, {n: c['address'] for n, c in contracts.items()}, expected,
                        artifacts, seed)
        report['receipts_succeeded'] = all(c['status'] in (None, '0x1') for c in contracts.values())
        if not report['receipts_succeeded']:
            report['failures'].append('a creation transaction failed')
            report['ok'] = False
    except Exception as exc:
        print(json.dumps({'ok': False, 'error': str(exc)}, indent=2))
        return 2
    print(json.dumps(report, indent=2))
    if args.write_record and report['ok']:
        commit, dirty = git_state()
        methodology = expected['methodology']
        record = {
            'chain_id': 8453, 'verified_at_block': report['block'], 'commit': commit, 'working_tree_dirty': dirty,
            'toolchain': toolchain(), 'deployer': deployer,
            'bond_floor_usdc_raw': str(args.bond_floor), 'contracts': contracts,
            'methodology': {'uri': 'ipfs://' + raw_cid(methodology),
                            'keccak256': '0x' + format(keccak_text(methodology.decode('utf-8')), '064x')},
            'runtime_metadata_matches_build': report.get('metadata_matches'),
        }
        args.write_record.parent.mkdir(parents=True, exist_ok=True)
        args.write_record.write_text(json.dumps(record, indent=2) + '\n')
    return 0 if report['ok'] else 1


if __name__ == '__main__':
    sys.exit(main())
