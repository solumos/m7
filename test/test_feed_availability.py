import unittest

from scripts.feed_availability import ORIGINAL, age_at, evaluate

CURRENT = {'execution_window_utc_seconds': [54000, 72000], 'max_stock_feed_age_seconds': 90000,
           'fresh_signal_seconds': 3600, 'max_usdc_feed_age_seconds': 90000}
MONDAY = 1791158400  # 2026-10-05 00:00 UTC


class FeedAvailabilityTest(unittest.TestCase):
    def test_age_uses_the_latest_update_at_or_before_the_moment(self):
        self.assertIsNone(age_at([100, 200], 99))
        self.assertEqual(age_at([100, 200], 150), 50)
        self.assertEqual(age_at([100, 200], 200), 0)

    def test_quiet_feed_passes_new_rule_but_fails_original(self):
        quiet = [MONDAY + 12 * 3600]  # last update at noon, then silent all afternoon
        active = [MONDAY + 15 * 3600 + 60 * m for m in range(0, 300, 5)]
        stocks = [quiet] + [active] * 6
        usdc = [MONDAY]
        end = MONDAY + DAY_SECONDS
        current = evaluate(stocks, usdc, MONDAY, end, 600, CURRENT)
        original = evaluate(stocks, usdc, MONDAY, end, 600, ORIGINAL)
        self.assertEqual(current['slots'], 30)  # 15:00-20:00 in ten-minute steps
        self.assertEqual(current['usable_slots'], 30)
        self.assertEqual(original['slots'], 12)  # 15:00-17:00
        self.assertEqual(original['usable_slots'], 0)
        self.assertEqual(original['weekdays_without_a_usable_slot'], ['2026-10-05'])

    def test_holiday_without_any_fresh_update_fails_closed(self):
        stale = [MONDAY - 4 * 3600]  # previous evening only
        report = evaluate([stale] * 7, [MONDAY], MONDAY, MONDAY + DAY_SECONDS, 600, CURRENT)
        self.assertEqual(report['usable_slots'], 0)

    def test_weekends_are_skipped(self):
        saturday = MONDAY - 2 * DAY_SECONDS
        report = evaluate([[saturday]] * 7, [saturday], saturday, saturday + 2 * DAY_SECONDS, 600, CURRENT)
        self.assertEqual(report['slots'], 0)


DAY_SECONDS = 86400

if __name__ == '__main__':
    unittest.main()
