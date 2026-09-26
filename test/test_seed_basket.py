import sys
import unittest
from fractions import Fraction
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
from index_snapshot import SYMBOLS
from seed_basket import MIN_RAW, build_seed, size

RATIOS = [190000000000000000, 120000000000000000, 120000000000000000, 90000000000000000,
          200000000000000000, 200000000000000000, 80000000000000000]
PRICES = [Fraction(341), Fraction(250), Fraction(343), Fraction(749), Fraction(518), Fraction(225), Fraction(372)]
SNAPSHOT = {'symbols': list(SYMBOLS), 'quantity_ratios': [str(r) for r in RATIOS], 'quarter_id': 8107,
            'observation_sha256': '0x' + 'ab' * 32}
VAULT = '0x' + '11' * 20
RECEIVER = '0x' + '22' * 20


class SeedBasketTest(unittest.TestCase):
    def test_amounts_keep_the_exact_quantity_ratios(self):
        raw, value = size(RATIOS, PRICES, [10**8] * 7, '1000')
        for i in range(7):
            for j in range(7):
                # Flooring one raw unit of at least MIN_RAW moves a ratio by under one part per million.
                self.assertAlmostEqual(raw[i] / raw[j], RATIOS[i] / RATIOS[j], delta=RATIOS[i] / RATIOS[j] * 2e-6)
        self.assertLessEqual(value, 1000)
        self.assertGreater(value, Fraction(99999, 100))

    def test_rejects_baskets_below_the_precision_floor(self):
        with self.assertRaisesRegex(ValueError, 'precision floor'):
            size(RATIOS, PRICES, [10**8] * 7, '10')
        raw, _ = size(RATIOS, PRICES, [10**8] * 7, '100')
        self.assertTrue(all(amount >= MIN_RAW for amount in raw))

    def test_seed_file_matches_bootstrap_format(self):
        block = {'number': 1, 'timestamp': '2026-10-02T16:00:00+00:00'}
        seed = build_seed(SNAPSHOT, PRICES, '1000', VAULT, RECEIVER, block)
        self.assertEqual(seed['chain_id'], 8453)
        self.assertEqual(seed['vault'], VAULT)
        self.assertEqual(seed['receiver'], RECEIVER)
        self.assertEqual(len(seed['raw_amounts']), 8)
        self.assertEqual(seed['raw_amounts'][7], 0)
        self.assertEqual(seed['provenance']['quarter_id'], 8107)
        self.assertEqual(seed['provenance']['quantity_ratios'], SNAPSHOT['quantity_ratios'])

    def test_rejects_malformed_snapshots_and_addresses(self):
        block = {'number': 1, 'timestamp': 'x'}
        bad_order = dict(SNAPSHOT, symbols=list(reversed(SYMBOLS)))
        with self.assertRaises(ValueError):
            build_seed(bad_order, PRICES, '1000', VAULT, RECEIVER, block)
        bad_sum = dict(SNAPSHOT, quantity_ratios=[str(r) for r in RATIOS[:6]] + ['1'])
        with self.assertRaises(ValueError):
            build_seed(bad_sum, PRICES, '1000', VAULT, RECEIVER, block)
        with self.assertRaises(ValueError):
            build_seed(SNAPSHOT, PRICES, '1000', '0x' + '00' * 20, RECEIVER, block)


if __name__ == '__main__':
    unittest.main()
