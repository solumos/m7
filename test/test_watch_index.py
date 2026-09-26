import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
from index_snapshot import SYMBOLS
from watch_index import IDENTIFIER, compare_snapshot, decode_assertion, decode_proposal, monitor, ratios


RATIOS = [10**18 // 7] * 7
RATIOS[0] += 10**18 % 7
QUARTER = 2026 * 4 + 3
NOW = 1791216000
CONTROLLER = '0x' + '11' * 20
CONTROLLER_INT = int(CONTROLLER, 16)
CURRENCY = 3
DIGEST = 0xabcd
ASSERTER = 2
DISPUTER = 4


def assertion_words(settled=False, result=False, disputed=False, caller=CONTROLLER_INT, identifier=IDENTIFIER):
    return [0, 0, 0, caller, 0, ASSERTER, NOW - 3600, int(settled), CURRENCY, NOW + 71 * 3600,
            int(result), 0, identifier, 500_000000, 0, DISPUTER if disputed else 0]


def proposal_words(status=1, digest=DIGEST):
    return [QUARTER, status, *RATIOS, digest]


def snapshot():
    return {'symbols': list(SYMBOLS), 'scale': '1000000000000000000', 'quarter_id': QUARTER,
            'quantity_ratios': [str(v) for v in RATIOS], 'observation_sha256': '0x' + format(DIGEST, '064x')}


class FakeRPC:
    block = {'number': '0x123', 'hash': '0xabc', 'timestamp': hex(NOW)}

    def __init__(self, status=1, assertion=None, last=QUARTER - 1, identifier=123, blacklisted=(),
                 replaceable=False, accepted=0, digest=DIGEST):
        self.status = status
        self.assertion = assertion or assertion_words()
        self.last = last
        self.identifier = identifier
        self.blacklisted = set(blacklisted)
        self.replaceable = replaceable
        self.accepted = accepted
        self.digest = digest
        self.calls = []

    def call(self, target, signature, *args):
        self.calls.append((target, signature, args))
        if signature == 'isBlacklisted(address)':
            return [int(args[0] in self.blacklisted)]
        return {'currentQuarter()': [QUARTER], 'lastExecutedQuarter()': [self.last],
                'latestProposal(uint32)': [self.identifier], 'acceptedProposal(uint32)': [self.accepted],
                'oracle()': [99], 'bondCurrency()': [CURRENCY], 'bondFloor()': [500_000000],
                'vault()': [7], 'router()': [8], 'canPropose(uint32)': [int(self.replaceable)],
                'proposal(bytes32)': proposal_words(self.status, self.digest),
                'getAssertion(bytes32)': self.assertion}[signature]

    def balance(self, target):
        return 1


class WatchIndexTest(unittest.TestCase):
    def test_ratio_normalization_preserves_exact_integers(self):
        self.assertEqual(ratios([str(v) for v in RATIOS]), RATIOS)
        for bad in ([1] * 7, [0, *RATIOS[1:]], RATIOS[:-1], [True, *RATIOS[1:]], ['1e18', *RATIOS[1:]]):
            with self.assertRaises(ValueError):
                ratios(bad)

    def test_static_proposal_and_nested_uma_decoding(self):
        proposal = decode_proposal(proposal_words())
        self.assertEqual(proposal['status'], 'pending')
        self.assertEqual(proposal['quantity_ratios'], [str(v) for v in RATIOS])
        self.assertEqual(proposal['observation_sha256'], '0x' + format(DIGEST, '064x'))
        assertion = decode_assertion(assertion_words(disputed=True))
        self.assertEqual(assertion['challenge_expires_at'], NOW + 71 * 3600)
        self.assertEqual(assertion['bond_raw'], '500000000')
        self.assertTrue(assertion['disputed'])
        self.assertFalse(assertion['settled'])
        with self.assertRaises(ValueError):
            decode_proposal([QUARTER, 7, *RATIOS, DIGEST])
        with self.assertRaises(ValueError):
            decode_proposal([QUARTER, 1, *RATIOS])  # the pre-digest layout
        with self.assertRaises(ValueError):
            decode_assertion([0] * 15)

    def test_mismatch_is_exact_and_names_affected_symbols(self):
        expected = snapshot()
        expected['quantity_ratios'][0] = str(RATIOS[0] + 1)
        expected['quantity_ratios'][1] = str(RATIOS[1] - 1)
        comparison = compare_snapshot(expected, decode_proposal(proposal_words()), QUARTER)
        self.assertFalse(comparison['ratios_match'])
        self.assertTrue(comparison['digest_matches'])
        self.assertEqual([d['symbol'] for d in comparison['differences']], ['AAPLc', 'AMZNc'])

    def test_pending_reports_staleness_and_open_challenge(self):
        report = monitor(CONTROLLER, FakeRPC(), snapshot())
        self.assertTrue(report['current_review_stale'])
        self.assertEqual(report['assertion']['challenge_seconds_remaining'], 71 * 3600)
        self.assertTrue(any('window is open' in text for text in report['alerts']))
        self.assertFalse(any('UNEXPECTED' in text for text in report['alerts']))
        self.assertEqual(report['router_eth_wei'], 1)
        self.assertFalse(report['transactions_sent'])

    def test_missing_expected_data_is_never_reported_as_verified(self):
        report = monitor(CONTROLLER, FakeRPC(status=4, assertion=assertion_words(True, True), last=QUARTER))
        self.assertTrue(any('snapshot supplied' in text for text in report['alerts']))
        self.assertIn('Not verified', report['source_truth'])

    def test_executed_matching_snapshot_has_no_operational_alerts(self):
        report = monitor(CONTROLLER, FakeRPC(status=4, assertion=assertion_words(True, True), last=QUARTER), snapshot())
        self.assertEqual(report['alerts'], [])
        self.assertTrue(report['snapshot_comparison']['ratios_match'])
        self.assertTrue(report['snapshot_comparison']['digest_matches'])

    def test_disputed_and_externally_settled_lifecycle(self):
        report = monitor(CONTROLLER, FakeRPC(assertion=assertion_words(disputed=True), replaceable=True), snapshot())
        self.assertTrue(any('does not block a replacement' in text for text in report['alerts']))
        self.assertTrue(any('replacement proposal is currently allowed' in text for text in report['alerts']))
        report = monitor(CONTROLLER, FakeRPC(assertion=assertion_words(True, True)), snapshot())
        self.assertTrue(any('settled externally' in text for text in report['alerts']))

    def test_unpayable_disputer_or_asserter_is_flagged(self):
        report = monitor(CONTROLLER, FakeRPC(assertion=assertion_words(disputed=True), blacklisted={DISPUTER}))
        self.assertTrue(any('UNSETTLEABLE ASSERTION' in text for text in report['alerts']))
        report = monitor(CONTROLLER, FakeRPC(blacklisted={ASSERTER}))
        self.assertTrue(any('UNSETTLEABLE ASSERTION' in text for text in report['alerts']))
        report = monitor(CONTROLLER, FakeRPC(assertion=assertion_words(disputed=True), blacklisted={ASSERTER}))
        self.assertFalse(any('UNSETTLEABLE' in text for text in report['alerts']))

    def test_unexpected_assertion_parameters_and_digest_are_flagged(self):
        report = monitor(CONTROLLER, FakeRPC(assertion=assertion_words(caller=5, identifier=1)), snapshot())
        alert = next(text for text in report['alerts'] if 'UNEXPECTED UMA' in text)
        self.assertIn('asserting_caller', alert)
        self.assertIn('identifier', alert)
        report = monitor(CONTROLLER, FakeRPC(digest=0xbeef), snapshot())
        self.assertTrue(any('OBSERVATION DIGEST DIFFERS' in text for text in report['alerts']))

    def test_no_proposal_and_wrong_snapshot_quarter(self):
        rpc = FakeRPC(identifier=0)
        report = monitor(CONTROLLER, rpc)
        self.assertTrue(any('No current-quarter assertion' in text for text in report['alerts']))
        self.assertEqual(len(rpc.calls), 10)
        expected = snapshot()
        expected['quarter_id'] -= 1
        report = monitor(CONTROLLER, FakeRPC(), expected)
        self.assertFalse(report['snapshot_comparison']['quarter_matches'])


if __name__ == '__main__':
    unittest.main()
