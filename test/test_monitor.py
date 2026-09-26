import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
from monitor import REPEAT_CRITICAL_SECONDS, plan_notifications

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


if __name__ == '__main__':
    unittest.main()
