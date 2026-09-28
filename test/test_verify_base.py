import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('verify_base', Path(__file__).parents[1] / 'scripts/verify_base.py')
preflight = importlib.util.module_from_spec(spec)
spec.loader.exec_module(preflight)


class RebalanceOracleRuleTests(unittest.TestCase):
    RISK = {'execution_window_utc_seconds': [54000, 72000], 'max_stock_feed_age_seconds': 90000,
            'fresh_signal_seconds': 3600, 'max_usdc_feed_age_seconds': 90000}
    MONDAY_1600 = 1791216000

    def usable(self, now, stock_ages, usdc_age=3600):
        return preflight.rebalance_oracles_usable(now, stock_ages, usdc_age, self.RISK)

    def test_policy_zero_must_authorize_every_planned_account(self):
        class Registry:
            def __init__(self, rejected):
                self.rejected = rejected

            def call(self, target, signature, *args):
                assert signature == 'isAuthorized(uint64,address)' and args[0] == 0
                return [int(args[1] not in self.rejected)]

        preflight.registry_answers_policy_zero(Registry(()), '0xregistry', ['0xvault', '0xgateway'])
        with self.assertRaisesRegex(ValueError, '0xvault'):
            preflight.registry_answers_policy_zero(Registry(('0xvault',)), '0xregistry', ['0xvault'])

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
