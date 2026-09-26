import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('index_snapshot', Path(__file__).parents[1] / 'scripts/index_snapshot.py')
index = importlib.util.module_from_spec(spec)
spec.loader.exec_module(index)


def observations():
    ref = '2026-06-30T20:00:00Z'
    companies = []
    for symbol in index.SYMBOLS:
        classes = index.CLASSES.get(symbol, {'common': symbol[:-1]})
        companies.append({
            'symbol': symbol, 'share_basis': 'actual_outstanding_common',
            'token_price_usd': '10', 'token_price_at': ref,
            'token_price_source': 'https://example.com/synthetic-price',
            'multiplier': '1', 'multiplier_at': ref,
            'multiplier_source': 'https://example.com/synthetic-multiplier',
            'classes': [{'id': cid, 'shares_outstanding': '100', 'shares_as_of': '2026-06-01',
                         'filing_published_at': '2026-06-02T00:00:00Z',
                         'filing_source': 'https://www.sec.gov/synthetic-fixture-not-a-filing',
                         'price_symbol': proxy, 'price_usd': '10', 'price_at': ref,
                         'price_source': 'https://example.com/synthetic-price', 'adjustments': []}
                        for cid, proxy in classes.items()],
        })
    return {'cutoff': '2026-06-30T23:59:59Z', 'reference_at': ref,
            'market_calendar_source': 'https://example.com/synthetic-calendar', 'companies': companies}


class SnapshotTests(unittest.TestCase):
    def test_classes_count_once_and_human_quantity_normalization(self):
        snapshot = index.compile_snapshot(observations())
        self.assertEqual(snapshot['quarter_id'], 2026 * 4 + 2)
        self.assertEqual(list(map(int, snapshot['quantity_ratios'])),
                         [10**17, 10**17, 3*10**17, 2*10**17, 10**17, 10**17, 10**17])
        self.assertEqual(sum(map(int, snapshot['quantity_ratios'])), 10**18)

    def test_split_matches_both_shares_and_token_multiplier_without_double_count(self):
        data = observations()
        before = index.compile_snapshot(data)
        c = data['companies'][0]
        c['multiplier'] = '2'
        c['classes'][0]['price_usd'] = '5'
        c['classes'][0]['adjustments'].append({
            'effective_at': '2026-06-15T00:00:00Z', 'published_at': '2026-06-10T00:00:00Z',
            'factor': '2', 'delta_shares': '0', 'source': 'https://example.com/split'})
        self.assertEqual(before['quantity_ratios'], index.compile_snapshot(data)['quantity_ratios'])

    def test_dividend_multiplier_reduces_quantity_not_company_cap(self):
        data = observations()
        data['companies'][0]['token_price_usd'] = '20'
        data['companies'][0]['multiplier'] = '2'
        result = index.compile_snapshot(data)
        self.assertEqual(result['reference_cap_weights'][0], str(10**17))
        self.assertLess(int(result['quantity_ratios'][0]), int(result['quantity_ratios'][1]))

    def test_adjustments_cannot_double_count_observation_date_events(self):
        for effective in ('2026-06-01T00:00:00Z', '2026-06-01T23:59:59Z'):
            data = observations()
            data['companies'][0]['classes'][0]['adjustments'] = [{
                'effective_at': effective, 'published_at': '2026-06-01T00:00:00Z',
                'factor': '2', 'delta_shares': '0', 'source': 'https://example.com/split'}]
            with self.assertRaisesRegex(ValueError, 'follow the share observation'):
                index.compile_snapshot(data)
        # The next calendar day is outside the reported-count window and can be adjusted.
        data['companies'][0]['classes'][0]['adjustments'][0]['effective_at'] = '2026-06-02T00:00:00Z'
        self.assertGreater(int(index.compile_snapshot(data)['reference_cap_weights'][0]), 10**17)

    def test_malformed_or_oversized_delta_is_rejected_before_fraction_parsing(self):
        invalid = [None, 1, ['1'], '1' * 101, '--1', '1-1', '1.2.3', '1/2', '1e100000', '', '.', 'nan']
        with patch.object(index, 'Fraction') as fraction:
            for value in invalid:
                with self.subTest(value=value), self.assertRaises(ValueError):
                    index.decimal(value, signed=True)
            fraction.assert_not_called()
        self.assertEqual(index.decimal('-12.5', signed=True), index.Fraction(-25, 2))

    def test_total_return_identity_uses_held_class_and_allows_feed_rounding(self):
        data = observations()
        # Alphabet holds A, so a different C close changes market cap but not the token price identity.
        data['companies'][2]['classes'][2]['price_usd'] = '12'
        index.compile_snapshot(data)
        data['companies'][0]['token_price_usd'] = '10.00000001'
        index.compile_snapshot(data)
        data['companies'][0]['token_price_usd'] = '10.00000002'
        with self.assertRaisesRegex(ValueError, 'held-class close times multiplier'):
            index.compile_snapshot(data)
        data['companies'][0]['token_price_usd'] = '10'
        data['companies'][0]['multiplier'] = '2'
        with self.assertRaisesRegex(ValueError, 'held-class close times multiplier'):
            index.compile_snapshot(data)

    def test_exact_rounding_deterministic_even_if_input_order_changes(self):
        self.assertEqual(index.allocate([index.Fraction(1)] * 7),
                         [142857142857142858] + [142857142857142857] * 6)
        data = observations()
        before = index.compile_snapshot(data)
        data['companies'].reverse()
        self.assertEqual(before['quantity_ratios'], index.compile_snapshot(data)['quantity_ratios'])

    def test_rejects_lookahead_missing_classes_and_wrong_basis(self):
        changes = [lambda d: d['companies'][0].update(share_basis='diluted_eps'),
                   lambda d: d['companies'][0].update(token_price_at='2026-07-01T20:00:00Z'),
                   lambda d: d['companies'][0]['classes'][0].update(filing_published_at='2026-07-01T00:00:00Z'),
                   lambda d: d['companies'][2]['classes'].pop(),
                   lambda d: d['companies'][0].update(token_price_usd='0'),
                   lambda d: d.update(cutoff='2026-06-29T23:59:59Z')]
        for change in changes:
            data = observations()
            change(data)
            with self.assertRaises(ValueError):
                index.compile_snapshot(data)


if __name__ == '__main__':
    unittest.main()
