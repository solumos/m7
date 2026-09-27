import json
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
from ipfs_cid import raw_cid
from verify_base import keccak_text
from verify_deployment import CONTRACTS, SEED_LOCK, WAD, compare_bytecode, decode_string, from_broadcast, verify

MANIFEST = json.loads((ROOT / 'config/base.json').read_text())
METHODOLOGY = b'# Methodology fixture\n'
ADDRESSES = {'Valuation': '0x' + 'a1' * 20, 'IndexController': '0x' + 'a2' * 20,
             'M7CapVault': '0x' + 'a3' * 20, 'USDCGateway': '0x' + 'a4' * 20}
DEPLOYER = '0x' + 'de' * 20
SAFE = '0x' + '5a' * 20
EXPECTED = {'deployer': DEPLOYER, 'bond_floor': 1_000 * 10**6, 'methodology': METHODOLOGY,
            'methodology_uri': 'ipfs://' + raw_cid(METHODOLOGY)}
SEED = {'vault': ADDRESSES['M7CapVault'], 'receiver': SAFE, 'raw_amounts': [10**8 + i for i in range(7)] + [0]}


def text_words(value):
    data = value.encode()
    padded = data + bytes(-len(data) % 32)
    return [32, len(data)] + [int.from_bytes(padded[i:i + 32], 'big') for i in range(0, len(padded), 32)]


def artifact(code_hex):
    return {'deployedBytecode': {'object': '0x' + code_hex,
                                 'immutableReferences': {'7': [{'start': 1, 'length': 32}]}}}


# One opcode, a 32-byte immutable, one more opcode, then a 3-byte CBOR trailer and its 2-byte length.
BUILT = '60' + '00' * 32 + '56' + 'a1b2c3' + '0003'


class FakeRPC:
    block = {'number': '0x10', 'timestamp': '0x0'}

    def __init__(self, overrides=None, seeded=False):
        stocks, venue = MANIFEST['stocks'], MANIFEST['venue']
        assets = [s['address'] for s in stocks] + [MANIFEST['usdc']['address']]
        feeds = [s['feed'] for s in stocks] + [MANIFEST['usdc']['feed']]
        vault, controller = ADDRESSES['M7CapVault'], ADDRESSES['IndexController']
        gateway, valuation = ADDRESSES['USDCGateway'], ADDRESSES['Valuation']
        a = lambda value: int(value, 16)
        self.answers = {
            (vault, 'name()', ()): text_words('MAG7 Cap Index'), (vault, 'symbol()', ()): text_words('M7CAP'),
            (vault, 'decimals()', ()): [18], (vault, 'router()', ()): [a(venue['router'])],
            (vault, 'factory()', ()): [a(venue['factory'])],
            (vault, 'policyRegistry()', ()): [a(MANIFEST['policy_registry'])],
            (vault, 'controller()', ()): [a(controller)], (vault, 'bootstrapper()', ()): [a(DEPLOYER)],
            (vault, 'totalSupply()', ()): [1_000 * WAD if seeded else 0],
            (vault, 'balanceOf(address)', (SEED_LOCK,)): [10 * WAD],
            (vault, 'balanceOf(address)', (SAFE,)): [990 * WAD],
            (vault, 'quoteMint(uint256)', (WAD,)): [1] * 8,
            (controller, 'vault()', ()): [a(vault)], (controller, 'oracle()', ()): [a(MANIFEST['uma_oo_v3'])],
            (controller, 'bondCurrency()', ()): [a(assets[7])], (controller, 'bondFloor()', ()): [1_000 * 10**6],
            (controller, 'valuation()', ()): [a(valuation)],
            (controller, 'methodologyHash()', ()): [keccak_text(METHODOLOGY.decode())],
            (controller, 'methodologyURI()', ()): text_words('ipfs://' + raw_cid(METHODOLOGY)),
            (valuation, 'sequencer()', ()): [a(MANIFEST['sequencer_feed'])],
            (valuation, 'registry()', ()): [a(MANIFEST['registry'])],
            (valuation, 'maxAge()', ()): [MANIFEST['risk_checks']['max_stock_feed_age_seconds']],
            (gateway, 'vault()', ()): [a(vault)], (gateway, 'router()', ()): [a(venue['router'])],
            (gateway, 'usdc()', ()): [a(assets[7])],
        }
        for scope in ('sender', 'receiver', 'executor'):
            self.answers[(vault, scope + 'Scope()', ())] = [keccak_text('TRANSFER_%s_POLICY' % scope.upper())]
        for i in range(8):
            self.answers[(vault, 'assets(uint256)', (i,))] = [a(assets[i])]
            self.answers[(valuation, 'assets(uint256)', (i,))] = [a(assets[i])]
            self.answers[(valuation, 'feeds(uint256)', (i,))] = [a(feeds[i])]
            self.answers[(vault, 'backing(uint256)', (i,))] = [SEED['raw_amounts'][i]]
            self.answers[(vault, 'reserved(uint256)', (i,))] = [0]
        for i, stock in enumerate(stocks):
            self.answers[(vault, 'tickSpacing(uint256)', (i,))] = [stock['tick_spacing']]
        self.answers.update(overrides or {})
        self.code = '0x60' + '11' * 32 + '56' + 'ffffff' + '0003'

    def call(self, target, signature, *args):
        return self.answers[(target, signature, args)]

    def rpc(self, method, params):
        assert method == 'eth_getCode'
        return self.code


class VerifyDeploymentTest(unittest.TestCase):
    def test_consistent_deployment_passes(self):
        artifacts = {name: artifact(BUILT) for name in CONTRACTS}
        report = verify(FakeRPC(), MANIFEST, ADDRESSES, EXPECTED, artifacts)
        self.assertEqual(report['failures'], [])
        self.assertTrue(report['ok'])
        self.assertFalse(report['metadata_matches']['M7CapVault'])  # only the metadata trailer differs

    def test_detects_wrong_gateway_uri_and_binding(self):
        vault, controller = ADDRESSES['M7CapVault'], ADDRESSES['IndexController']
        rpc = FakeRPC({(ADDRESSES['USDCGateway'], 'vault()', ()): [1],
                       (controller, 'methodologyURI()', ()): text_words('ipfs://publish-the-reviewed-methodology-here'),
                       (vault, 'controller()', ()): [1]})
        report = verify(rpc, MANIFEST, ADDRESSES, EXPECTED)
        self.assertFalse(report['ok'])
        self.assertIn('gateway vault', report['failures'])
        self.assertIn('controller methodology URI is the raw CID of the file', report['failures'])
        self.assertIn('vault controller', report['failures'])

    def test_bootstrapped_state_is_checked_against_the_seed(self):
        report = verify(FakeRPC(seeded=True), MANIFEST, ADDRESSES, EXPECTED, seed=SEED)
        self.assertTrue(report['ok'], report['failures'])
        short = dict(SEED, raw_amounts=[1] + SEED['raw_amounts'][1:])
        self.assertIn('backing 0 equals the seed',
                      verify(FakeRPC(seeded=True), MANIFEST, ADDRESSES, EXPECTED, seed=short)['failures'])

    def test_bytecode_comparison_masks_only_immutables_and_metadata(self):
        onchain = '0x60' + 'ab' * 32 + '56' + '000000' + '0003'
        self.assertEqual(compare_bytecode(onchain, artifact(BUILT)), (True, False))
        self.assertEqual(compare_bytecode('0x' + BUILT, artifact(BUILT)), (True, True))
        changed_opcode = '0x61' + 'ab' * 32 + '56' + 'a1b2c3' + '0003'
        self.assertEqual(compare_bytecode(changed_opcode, artifact(BUILT))[0], False)
        self.assertEqual(compare_bytecode('0x60', artifact(BUILT)), (False, False))

    def test_decode_string_rejects_malformed_words(self):
        self.assertEqual(decode_string(text_words('M7CAP')), 'M7CAP')
        with self.assertRaises(ValueError):
            decode_string([64, 5, 0])
        with self.assertRaises(ValueError):
            decode_string([32, 40, 0])

    def test_broadcast_file_parsing(self):
        import tempfile
        transactions = [{'transactionType': 'CREATE', 'contractName': name, 'contractAddress': ADDRESSES[name],
                         'hash': '0x%064x' % i, 'transaction': {'from': DEPLOYER}}
                        for i, name in enumerate(CONTRACTS)]
        receipts = [{'transactionHash': '0x%064x' % i, 'blockNumber': hex(100 + i), 'status': '0x1'}
                    for i in range(4)]
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'run-latest.json'
            path.write_text(json.dumps({'transactions': transactions, 'receipts': receipts}))
            contracts, deployer = from_broadcast(path)
            self.assertEqual(deployer, DEPLOYER)
            self.assertEqual(contracts['M7CapVault']['block'], 102)
            path.write_text(json.dumps({'transactions': transactions[:3], 'receipts': receipts}))
            with self.assertRaises(ValueError):
                from_broadcast(path)


if __name__ == '__main__':
    unittest.main()
