import unittest

from scripts.monitor import REPEAT_CRITICAL_SECONDS, WAD, decode_value, plan_notifications, reset_status, vault_state

DUE = {'level': 'info', 'message': "This quarter's equal-weight reset is due."}
LATE = {'level': 'action', 'message': "This quarter's equal-weight reset has not run; anyone can trigger it."}
BLOCKED = {'level': 'critical', 'message': 'New minting is blocked: InsufficientLockedBacking(3)'}


class MonitorTest(unittest.TestCase):
    def test_new_alerts_at_or_above_the_level_are_sent_once(self):
        messages, state = plan_notifications([DUE, LATE], {}, 1000)
        self.assertEqual(messages, ['[M7 ACTION] ' + LATE['message']])
        messages, state = plan_notifications([DUE, LATE], state, 1900)
        self.assertEqual(messages, [])
        messages, _ = plan_notifications([DUE], {}, 1000, notify_level='info')
        self.assertEqual(messages, ['[M7 INFO] ' + DUE['message']])

    def test_open_criticals_repeat_every_six_hours(self):
        messages, state = plan_notifications([BLOCKED], {}, 1000)
        self.assertEqual(len(messages), 1)
        messages, state = plan_notifications([BLOCKED], state, 1000 + REPEAT_CRITICAL_SECONDS - 1)
        self.assertEqual(messages, [])
        messages, state = plan_notifications([BLOCKED], state, 1000 + REPEAT_CRITICAL_SECONDS)
        self.assertEqual(messages, ['[M7 CRITICAL] ' + BLOCKED['message']])

    def test_cleared_alerts_are_announced_only_if_they_were_sent(self):
        _, state = plan_notifications([DUE, BLOCKED], {}, 1000)
        messages, state = plan_notifications([], state, 2000)
        self.assertEqual(messages, ['[M7 RESOLVED] ' + BLOCKED['message']])
        self.assertEqual(state['open'], {})

    def test_other_state_survives(self):
        _, state = plan_notifications([], {'last_preflight': 5, 'preflight_error': None}, 1000)
        self.assertEqual(state['last_preflight'], 5)


class FakeVaultRPC:
    def __init__(self, backing, supply=1_000 * WAD, reserved=None, last_tranche=1_790_000_000, mint_error=None):
        self.backing, self.supply = backing, supply
        self.reserved = reserved or [0] * 8
        self.last_tranche, self.mint_error = last_tranche, mint_error

    def call(self, target, signature, *args):
        if signature == 'quoteMint(uint256)':
            if self.mint_error:
                raise ValueError(self.mint_error)
            return [1] * 8
        return {'totalSupply()': [self.supply], 'lastTrancheAt()': [self.last_tranche],
                'backing(uint256)': [self.backing[args[0]] if args else 0],
                'reserved(uint256)': [self.reserved[args[0]] if args else 0],
                'value()': [WAD + WAD // 2, 1_500 * WAD, 1_000 * WAD] + [200 * WAD] * 6 + [300 * WAD, 0]
                + [1790870400, 0, 0]}[signature]


BACKING = [10**8 * (i + 1) for i in range(7)] + [0]


class VaultStateTest(unittest.TestCase):
    def test_reports_price_per_share_from_the_lens(self):
        _, report = vault_state(FakeVaultRPC(BACKING), 'c', 'v', 'lens', {})
        self.assertEqual(report['price_per_share_usd'], '1.500000')
        self.assertEqual(report['nav_usd'], '1500.00')
        self.assertEqual(report['oldest_price_at'], 1790870400)
        self.assertEqual(report['weights']['AAPLc'], '0.1333')
        self.assertEqual(report['weights']['TSLAc'], '0.2000')
        self.assertEqual(report['largest_weight_gap'], '0.0571')
        with self.assertRaises(ValueError):
            decode_value([0] * 13)

    def test_backing_per_share_falling_outside_a_rebalance_is_critical(self):
        state = {}
        alerts, _ = vault_state(FakeVaultRPC(BACKING), 'c', 'v', None, state)
        self.assertEqual(alerts, [])
        seized = BACKING[:2] + [BACKING[2] - 1] + BACKING[3:]
        alerts, _ = vault_state(FakeVaultRPC(seized), 'c', 'v', None, dict(state))
        self.assertIn('GOOGLc', alerts[0]['message'])
        self.assertEqual(alerts[0]['level'], 'critical')
        # A reset tranche between runs legitimately sells some stocks: the baseline resets instead of alerting.
        alerts, _ = vault_state(FakeVaultRPC(seized, last_tranche=1_790_900_000), 'c', 'v', None, dict(state))
        self.assertEqual(alerts, [])
        # Minting and redeeming change supply and backing together; per-share backing does not fall.
        alerts, _ = vault_state(FakeVaultRPC([b * 2 for b in BACKING], supply=2_000 * WAD), 'c', 'v', None,
                                dict(state))
        self.assertEqual(alerts, [])

    def test_blocked_minting_and_outstanding_claims(self):
        rpc = FakeVaultRPC(BACKING, reserved=[0, 5, 0, 0, 0, 0, 0, 7], mint_error='InsufficientLockedBacking(3)')
        alerts, _ = vault_state(rpc, 'c', 'v', None, {})
        levels = {a['level']: a['message'] for a in alerts}
        self.assertIn('New minting is blocked', levels['critical'])
        self.assertIn('AMZNc, USDC', levels['action'])



class FakeControllerRPC:
    def __init__(self, done, last_tranche=0, next_tranche=0, last_completed=0):
        self.done, self.last_tranche = done, last_tranche
        self.next_tranche, self.last_completed = next_tranche, last_completed

    def call(self, target, signature, *args):
        return {'currentQuarter()': [2026 * 4 + 3], 'executedQuarter(uint32)': [int(self.done)],
                'lastExecutedQuarter()': [2026 * 4 + 2], 'lastTrancheAt()': [self.last_tranche],
                'nextTrancheAt()': [self.next_tranche], 'lastCompletedAt()': [self.last_completed]}[signature]


OCT_1 = 1790812800  # quarter 8107 begins
JAN_1 = 1798761600  # and ends


class ResetStatusTest(unittest.TestCase):
    def test_due_then_late_then_critical(self):
        alerts, report = reset_status(FakeControllerRPC(False), 'c', OCT_1 + 3 * 86400)
        self.assertEqual([a['level'] for a in alerts], ['info'])
        self.assertIn('is due', alerts[0]['message'])
        self.assertEqual(report['quarter_ends_at'], '2027-01-01T00:00:00+00:00')
        alerts, _ = reset_status(FakeControllerRPC(False), 'c', OCT_1 + 8 * 86400)
        self.assertEqual([a['level'] for a in alerts], ['action'])
        alerts, _ = reset_status(FakeControllerRPC(False), 'c', JAN_1 - 20 * 86400)
        self.assertEqual([a['level'] for a in alerts], ['critical'])
        self.assertIn('2027-01-01 00:00 UTC', alerts[0]['message'])
        # The same alert on later days, so it repeats rather than resolving and reopening.
        later, _ = reset_status(FakeControllerRPC(False), 'c', JAN_1 - 3 * 86400)
        self.assertEqual(later, alerts)

    def test_tranches_in_progress(self):
        rpc = FakeControllerRPC(False, last_tranche=OCT_1 + 2 * 86400, next_tranche=OCT_1 + 2 * 86400 + 1800)
        alerts, report = reset_status(rpc, 'c', OCT_1 + 2 * 86400 + 600)
        self.assertEqual(alerts, [{'level': 'info', 'message': "This quarter's equal-weight reset is in progress."}])
        self.assertEqual(report['next_tranche_at'], '2026-10-03 00:30 UTC')

    def test_opens_thirty_days_after_the_last_completion(self):
        # The previous quarter's reset completed on September 29, so this one opens on October 29: not late before.
        rpc = FakeControllerRPC(False, last_completed=OCT_1 - 2 * 86400, next_tranche=OCT_1 + 28 * 86400)
        alerts, _ = reset_status(rpc, 'c', OCT_1 + 20 * 86400)
        self.assertEqual(alerts, [{'level': 'info', 'message': "This quarter's equal-weight reset opens at "
                                   '2026-10-29 00:00 UTC.'}])
        alerts, _ = reset_status(rpc, 'c', OCT_1 + 36 * 86400)
        self.assertEqual([a['level'] for a in alerts], ['action'])

    def test_done_quarter_is_quiet(self):
        alerts, report = reset_status(FakeControllerRPC(True), 'c', JAN_1 - 86400)
        self.assertEqual(alerts, [])
        self.assertTrue(report['reset_done'])


if __name__ == '__main__':
    unittest.main()
