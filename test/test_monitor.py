import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
from monitor import REPEAT_CRITICAL_SECONDS, WAD, decode_value, plan_notifications, vault_state

OPEN = {'level': 'info', 'message': 'Challenge window is open; independently verify the assertion before expiry.'}
SETTLE = {'level': 'action', 'message': 'Undisputed challenge window closed; settlement is available.'}
FALSE = {'level': 'critical', 'message': 'ASSERTED RATIOS DIFFER FROM EXPECTED SNAPSHOT; independently review '
                                         'before challenge expiry.'}


class MonitorTest(unittest.TestCase):
    def test_new_alerts_at_or_above_the_level_are_sent_once(self):
        messages, state = plan_notifications([OPEN, SETTLE], {}, 1000)
        self.assertEqual(messages, ['[M7CAP ACTION] ' + SETTLE['message']])
        messages, state = plan_notifications([OPEN, SETTLE], state, 1900)
        self.assertEqual(messages, [])
        messages, _ = plan_notifications([OPEN], {}, 1000, notify_level='info')
        self.assertEqual(messages, ['[M7CAP INFO] ' + OPEN['message']])

    def test_open_criticals_repeat_every_six_hours(self):
        messages, state = plan_notifications([FALSE], {}, 1000)
        self.assertEqual(len(messages), 1)
        messages, state = plan_notifications([FALSE], state, 1000 + REPEAT_CRITICAL_SECONDS - 1)
        self.assertEqual(messages, [])
        messages, state = plan_notifications([FALSE], state, 1000 + REPEAT_CRITICAL_SECONDS)
        self.assertEqual(messages, ['[M7CAP CRITICAL] ' + FALSE['message']])

    def test_cleared_alerts_are_announced_only_if_they_were_sent(self):
        _, state = plan_notifications([OPEN, FALSE], {}, 1000)
        messages, state = plan_notifications([], state, 2000)
        self.assertEqual(messages, ['[M7CAP RESOLVED] ' + FALSE['message']])
        self.assertEqual(state['open'], {})

    def test_other_state_survives(self):
        _, state = plan_notifications([], {'last_preflight': 5, 'preflight_error': None}, 1000)
        self.assertEqual(state['last_preflight'], 5)


class FakeVaultRPC:
    def __init__(self, backing, supply=1_000 * WAD, reserved=None, last_executed=8106, mint_error=None):
        self.backing, self.supply = backing, supply
        self.reserved = reserved or [0] * 8
        self.last_executed, self.mint_error = last_executed, mint_error

    def call(self, target, signature, *args):
        if signature == 'quoteMint(uint256)':
            if self.mint_error:
                raise ValueError(self.mint_error)
            return [1] * 8
        return {'totalSupply()': [self.supply], 'lastExecutedQuarter()': [self.last_executed],
                'backing(uint256)': [self.backing[args[0]] if args else 0],
                'reserved(uint256)': [self.reserved[args[0]] if args else 0],
                'value()': [WAD + WAD // 2, 1_500 * WAD, 1_000 * WAD] + [0] * 8 + [1790870400, 0, 0]}[signature]


BACKING = [10**8 * (i + 1) for i in range(7)] + [0]


class VaultStateTest(unittest.TestCase):
    def test_reports_price_per_share_from_the_lens(self):
        _, report = vault_state(FakeVaultRPC(BACKING), 'c', 'v', 'lens', {})
        self.assertEqual(report['price_per_share_usd'], '1.500000')
        self.assertEqual(report['nav_usd'], '1500.00')
        self.assertEqual(report['oldest_price_at'], 1790870400)
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
        # A rebalance between runs legitimately sells some stocks: the baseline resets instead of alerting.
        alerts, _ = vault_state(FakeVaultRPC(seized, last_executed=8107), 'c', 'v', None, dict(state))
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


if __name__ == '__main__':
    unittest.main()
