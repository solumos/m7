import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
from index_snapshot import SYMBOLS
from watch_index import compare_snapshot, decode_assertion, decode_proposal, monitor, ratios


RATIOS = [10**18 // 7] * 7
RATIOS[0] += 10**18 % 7
QUARTER = 2026 * 4 + 3
NOW = 1791216000
CONTROLLER = '0x' + '11' * 20


def assertion_words(settled=False, result=False, disputed=False):
    return [0, 0, 0, 1, 0, 2, NOW - 3600, int(settled), 3, NOW + 71 * 3600,
            int(result), 0, 0, 500_000000, 0, 4 if disputed else 0]


def snapshot():
    return {'symbols': list(SYMBOLS), 'scale': '1000000000000000000', 'quarter_id': QUARTER,
            'quantity_ratios': [str(v) for v in RATIOS], 'observation_sha256': '0xabcd'}


class FakeRPC:
    block = {'number': '0x123', 'hash': '0xabc', 'timestamp': hex(NOW)}

    def __init__(self, status=1, assertion=None, last=QUARTER - 1, identifier=123):
        self.status = status
        self.assertion = assertion or assertion_words()
        self.last = last
        self.identifier = identifier
        self.calls = []

    def call(self, target, signature, *args):
        self.calls.append((target, signature, args))
        return {'currentQuarter()': [QUARTER], 'lastExecutedQuarter()': [self.last],
                'quarterlyProposal(uint32)': [self.identifier], 'oracle()': [99],
                'proposal(bytes32)': [QUARTER, self.status, *RATIOS],
                'getAssertion(bytes32)': self.assertion}[signature]


class WatchIndexTest(unittest.TestCase):
    def test_ratio_normalization_preserves_exact_integers(self):
        self.assertEqual(ratios([str(v) for v in RATIOS]), RATIOS)
        for bad in ([1] * 7, [0, *RATIOS[1:]], RATIOS[:-1], [True, *RATIOS[1:]], ['1e18', *RATIOS[1:]]):
            with self.assertRaises(ValueError):
                ratios(bad)

    def test_static_proposal_and_nested_uma_decoding(self):
        proposal = decode_proposal([QUARTER, 1, *RATIOS])
        self.assertEqual(proposal['status'], 'pending')
        self.assertEqual(proposal['quantity_ratios'], [str(v) for v in RATIOS])
        assertion = decode_assertion(assertion_words(disputed=True))
        self.assertEqual(assertion['challenge_expires_at'], NOW + 71 * 3600)
        self.assertEqual(assertion['bond_raw'], '500000000')
        self.assertTrue(assertion['disputed'])
        self.assertFalse(assertion['settled'])
        with self.assertRaises(ValueError):
            decode_proposal([QUARTER, 7, *RATIOS])
        with self.assertRaises(ValueError):
            decode_assertion([0] * 15)

    def test_mismatch_is_exact_and_names_affected_symbols(self):
        expected = snapshot()
        expected['quantity_ratios'][0] = str(RATIOS[0] + 1)
        expected['quantity_ratios'][1] = str(RATIOS[1] - 1)
        comparison = compare_snapshot(expected, decode_proposal([QUARTER, 1, *RATIOS]), QUARTER)
        self.assertFalse(comparison['ratios_match'])
        self.assertEqual([d['symbol'] for d in comparison['differences']], ['AAPLc', 'AMZNc'])

    def test_pending_reports_staleness_and_open_challenge(self):
        report = monitor(CONTROLLER, FakeRPC(), snapshot())
        self.assertTrue(report['current_review_stale'])
        self.assertEqual(report['assertion']['challenge_seconds_remaining'], 71 * 3600)
        self.assertTrue(any('window is open' in text for text in report['alerts']))
        self.assertFalse(report['transactions_sent'])

    def test_missing_expected_data_is_never_reported_as_verified(self):
        report = monitor(CONTROLLER, FakeRPC(status=4, assertion=assertion_words(True, True), last=QUARTER))
        self.assertTrue(any('snapshot supplied' in text for text in report['alerts']))
        self.assertIn('Not verified', report['source_truth'])

    def test_executed_matching_snapshot_has_no_operational_alerts(self):
        report = monitor(CONTROLLER, FakeRPC(status=4, assertion=assertion_words(True, True), last=QUARTER), snapshot())
        self.assertEqual(report['alerts'], [])
        self.assertTrue(report['snapshot_comparison']['ratios_match'])

    def test_disputed_and_externally_settled_lifecycle(self):
        report = monitor(CONTROLLER, FakeRPC(assertion=assertion_words(disputed=True)), snapshot())
        self.assertTrue(any('is disputed' in text for text in report['alerts']))
        report = monitor(CONTROLLER, FakeRPC(assertion=assertion_words(True, True)), snapshot())
        self.assertTrue(any('settled externally' in text for text in report['alerts']))

    def test_no_proposal_and_wrong_snapshot_quarter(self):
        rpc = FakeRPC(identifier=0)
        report = monitor(CONTROLLER, rpc)
        self.assertTrue(any('No current-quarter assertion' in text for text in report['alerts']))
        self.assertEqual(len(rpc.calls), 4)
        expected = snapshot()
        expected['quarter_id'] -= 1
        report = monitor(CONTROLLER, FakeRPC(), expected)
        self.assertFalse(report['snapshot_comparison']['quarter_matches'])


if __name__ == '__main__':
    unittest.main()
