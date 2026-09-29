import unittest
from fractions import Fraction

from scripts.seed_basket import MIN_RAW, build_seed, size

PRICES = [Fraction(341), Fraction(250), Fraction(343), Fraction(749), Fraction(518), Fraction(225), Fraction(372)]
VAULT = '0x' + '11' * 20
RECEIVER = '0x' + '22' * 20
BLOCK = {'number': 1, 'timestamp': '2026-10-02T16:00:00+00:00'}


class SeedBasketTest(unittest.TestCase):
    def test_every_stock_holds_an_equal_value(self):
        raw, value = size(PRICES, '1000')
        for amount, price in zip(raw, PRICES):
            # Rounding down loses under one raw unit, worth under $0.00001 at these prices.
            self.assertAlmostEqual(float(Fraction(amount, 10**8) * price), 1000 / 7, delta=1e-5)
        self.assertLessEqual(value, 1000)
        self.assertGreater(value, Fraction(99999, 100))

    def test_rejects_baskets_below_the_precision_floor(self):
        # META at $749 needs 0.01 tokens, $7.49, so seven equal slices need at least $52.43.
        with self.assertRaisesRegex(ValueError, r'METAc.*\$52\.43'):
            size(PRICES, '50')
        raw, _ = size(PRICES, '100')
        self.assertTrue(all(amount >= MIN_RAW for amount in raw))

    def test_seed_file_matches_bootstrap_format(self):
        seed = build_seed(PRICES, '125', VAULT, RECEIVER, BLOCK)
        self.assertEqual(seed['chain_id'], 8453)
        self.assertEqual(seed['vault'], VAULT)
        self.assertEqual(seed['receiver'], RECEIVER)
        self.assertEqual(len(seed['raw_amounts']), 8)
        self.assertEqual(seed['raw_amounts'][7], 0)
        self.assertEqual(seed['provenance']['usd_target'], '125')
        self.assertEqual(len(seed['provenance']['prices_usdc']), 7)

    def test_rejects_malformed_inputs(self):
        with self.assertRaises(ValueError):
            build_seed(PRICES, '1000', '0x' + '00' * 20, RECEIVER, BLOCK)
        with self.assertRaises(ValueError):
            build_seed(PRICES, '1000', VAULT, 'not-an-address', BLOCK)
        with self.assertRaises(ValueError):
            size(PRICES[:6], '1000')
        with self.assertRaises(ValueError):
            size(PRICES, '0')


if __name__ == '__main__':
    unittest.main()
