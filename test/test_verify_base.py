import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('verify_base', Path(__file__).parents[1] / 'scripts/verify_base.py')
preflight = importlib.util.module_from_spec(spec)
spec.loader.exec_module(preflight)


class FakeUmaRPC:
    def __init__(self):
        self.supported = True
        self.currency_supported = True
        self.cached_supported = True
        self.synced = False

    def call(self, target, signature, *args):
        if signature == 'finder()':
            return [2]
        if signature == 'getImplementationAddress(bytes32)':
            return [1]  # All fake interfaces share an address.
        if signature == 'isIdentifierSupported(bytes32)':
            return [int(self.supported and args[0] == preflight.bytes32_text('ASSERT_TRUTH2'))]
        if signature == 'isOnWhitelist(address)':
            return [int(self.currency_supported)]
        if signature == 'defaultIdentifier()':
            return [preflight.bytes32_text('ASSERT_TRUTH')]
        if signature == 'cachedCurrencies(address)':
            return [1, 250_000_000]
        if signature == 'computeFinalFee(address)':
            return [300_000_000]
        if signature == 'burnedBondPercentage()':
            return [5 * 10**17]
        if signature == 'syncUmaParams(bytes32,address)':
            self.synced = True
            return []
        if signature == 'cachedIdentifiers(bytes32)':
            return [int(self.cached_supported)]
        if signature == 'getMinimumBond(address)':
            return [500_000_000]
        raise AssertionError(signature)


class UmaPreflightTests(unittest.TestCase):
    def setUp(self):
        self.manifest = {'uma_assertion_identifier': 'ASSERT_TRUTH2',
                         'uma_oo_v3': preflight.address(1), 'usdc': {'address': preflight.address(3)}}

    def test_identifier_encoding_is_bytes32_right_padding_not_numeric_left_padding(self):
        self.assertEqual(preflight.word(preflight.bytes32_text('ASSERT_TRUTH2')),
                         '4153534552545f545255544832' + '00' * 19)

    def test_current_identifier_passes_despite_deprecated_default_and_stale_fee_cache(self):
        rpc = FakeUmaRPC()
        rpc.cached_supported = False  # A sync can populate an initially empty cache.
        result = preflight.uma_preflight(rpc, self.manifest)
        self.assertFalse(result['oracle_default_identifier_supported'])
        self.assertTrue(result['configured_identifier_supported'])
        self.assertFalse(result['configured_identifier_cached'])
        self.assertEqual(result['minimum_bond_after_sync_usdc_raw'], '600000000')
        self.assertEqual(result['minimum_bond_cached_usdc_raw'], '500000000')
        self.assertTrue(rpc.synced)
        self.assertFalse(result['cache_persisted'])

    def test_revoked_identifier_or_currency_fails_even_with_positive_cached_bond(self):
        for field in ('supported', 'currency_supported'):
            rpc = FakeUmaRPC()
            setattr(rpc, field, False)
            with self.assertRaises(ValueError):
                preflight.uma_preflight(rpc, self.manifest)
            self.assertFalse(rpc.synced)

    def test_no_silent_deprecated_default_fallback(self):
        self.manifest['uma_assertion_identifier'] = 'ASSERT_TRUTH'
        with self.assertRaises(ValueError):
            preflight.uma_preflight(FakeUmaRPC(), self.manifest)


class RebalanceOracleRuleTests(unittest.TestCase):
    RISK = {'execution_window_utc_seconds': [54000, 72000], 'max_stock_feed_age_seconds': 90000,
            'fresh_signal_seconds': 3600, 'max_usdc_feed_age_seconds': 90000}
    MONDAY_1600 = 1791216000

    def usable(self, now, stock_ages, usdc_age=3600):
        return preflight.rebalance_oracles_usable(now, stock_ages, usdc_age, self.RISK)

    def test_quiet_feeds_pass_while_one_stock_is_fresh(self):
        ok, checks = self.usable(self.MONDAY_1600, [60] + [89_000] * 6)
        self.assertTrue(ok)
        self.assertTrue(checks['market_open_signal'])

    def test_no_fresh_stock_means_market_closed(self):
        ok, checks = self.usable(self.MONDAY_1600, [3601] * 7)
        self.assertFalse(ok)
        self.assertFalse(checks['market_open_signal'])

    def test_a_stock_beyond_its_heartbeat_fails(self):
        self.assertFalse(self.usable(self.MONDAY_1600, [60] * 6 + [90_001])[0])

    def test_window_edges_and_weekend(self):
        ages = [60] * 7
        self.assertFalse(self.usable(self.MONDAY_1600 - 3601, ages)[0])  # 14:59:59
        self.assertTrue(self.usable(self.MONDAY_1600 + 4 * 3600 - 1, ages)[0])  # 19:59:59
        self.assertFalse(self.usable(self.MONDAY_1600 + 4 * 3600, ages)[0])  # 20:00:00
        self.assertFalse(self.usable(self.MONDAY_1600 - 2 * 86400, ages)[0])  # Saturday

    def test_stale_usdc_fails(self):
        self.assertFalse(self.usable(self.MONDAY_1600, [60] * 7, usdc_age=90_001)[0])


if __name__ == '__main__':
    unittest.main()
