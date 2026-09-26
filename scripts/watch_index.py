#!/usr/bin/env python3
"""One-shot, read-only M7CAP assertion monitor. Exit 0=matched/executed, 1=alerts, 2=read failure."""
import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import sys

from index_snapshot import SYMBOLS
from verify_base import RPC, address


STATUS = ('none', 'pending', 'accepted', 'rejected', 'executed')
ZERO_ID = '0x' + '00' * 32


def uint(value, bits=256):
    if isinstance(value, str):
        if not value or not value.isascii() or not value.isdecimal() or len(value) > 78:
            raise ValueError('Expected an unsigned decimal integer')
        value = int(value)
    if type(value) is not int or not 0 <= value < 2**bits:
        raise ValueError('Integer out of ABI range')
    return value


def ratios(values):
    if not isinstance(values, (list, tuple)) or len(values) != 7:
        raise ValueError('Expected seven quantity ratios')
    result = [uint(value) for value in values]
    if sum(result) != 10**18 or any(value == 0 for value in result):
        raise ValueError('Positive human-token quantity ratios must sum to 1e18')
    return result


def decode_proposal(values):
    # proposal(bytes32) returns a fully static tuple: uint32, uint8, uint256[7].
    if len(values) != 9:
        raise ValueError('Malformed proposal ABI response')
    quarter, status = uint(values[0], 32), uint(values[1], 8)
    if not 0 < status < len(STATUS):
        raise ValueError('Unknown or missing proposal status')
    return {'quarter_id': quarter, 'status': STATUS[status],
            'quantity_ratios': [str(value) for value in ratios(values[2:])]}


def decode_assertion(values):
    # UMA's static nested EscalationManagerSettings occupies words 0..4.
    if len(values) != 16:
        raise ValueError('Malformed UMA getAssertion ABI response')
    for index in (0, 1, 2, 7, 10):
        if values[index] not in (0, 1):
            raise ValueError('Malformed UMA bool')
    for index in (3, 4, 5, 8, 14, 15):
        uint(values[index], 160)
    for index in (6, 9):
        uint(values[index], 64)
    return {'asserter': address(values[5]), 'asserted_at': values[6],
            'settled': bool(values[7]), 'currency': address(values[8]),
            'challenge_expires_at': values[9], 'settlement_result': bool(values[10]),
            'bond_raw': str(values[13]), 'disputer': address(values[15]),
            'disputed': values[15] != 0}


def compare_snapshot(expected, proposal, quarter):
    if expected.get('symbols') != list(SYMBOLS):
        raise ValueError('Expected snapshot has incorrect canonical symbol order')
    if uint(expected.get('scale')) != 10**18:
        raise ValueError('Expected snapshot uses an unsupported ratio scale')
    expected_ratios = ratios(expected.get('quantity_ratios'))
    expected_quarter = uint(expected.get('quarter_id'), 32)
    observed = ratios(proposal['quantity_ratios'])
    differences = [{'symbol': symbol, 'expected': str(want), 'asserted': str(got)}
                   for symbol, want, got in zip(SYMBOLS, expected_ratios, observed) if want != got]
    return {'quarter_matches': expected_quarter == quarter == proposal['quarter_id'],
            'ratios_match': not differences, 'differences': differences,
            'expected_observation_sha256': expected.get('observation_sha256')}


def monitor(controller, rpc, expected=None):
    if not isinstance(controller, str) or len(controller) != 42 or not controller.startswith('0x'):
        raise ValueError('Controller must be a 20-byte hex address')
    uint(int(controller, 16), 160)
    if int(controller, 16) == 0:
        raise ValueError('Controller cannot be zero')
    quarter = uint(rpc.call(controller, 'currentQuarter()')[0], 32)
    last = uint(rpc.call(controller, 'lastExecutedQuarter()')[0], 32)
    identifier = '0x' + format(uint(rpc.call(controller, 'quarterlyProposal(uint32)', quarter)[0]), '064x')
    oracle = address(uint(rpc.call(controller, 'oracle()')[0], 160))
    now = int(rpc.block['timestamp'], 16)
    report = {
        'controller': controller, 'chain_id': 8453,
        'block': int(rpc.block['number'], 16), 'block_hash': rpc.block['hash'],
        'block_timestamp': datetime.fromtimestamp(now, timezone.utc).isoformat(),
        'current_quarter': quarter, 'last_executed_quarter': last,
        'current_review_stale': last != quarter,
        'assertion_id': identifier, 'uma_oracle': oracle, 'alerts': [],
        'source_truth': 'Not verified. Independently review filings, corporate actions, prices, and methodology.',
        'evidence': 'Inspect controller Proposed and UMA AssertionMade events. No evidence URL is fetched.',
        'transactions_sent': False,
    }
    alerts = report['alerts']
    if last != quarter:
        alerts.append('Current calendar quarter has no completed rebalance.')
    if identifier == ZERO_ID:
        alerts.append('No current-quarter assertion exists; a sourced proposal is required.')
        return report
    proposal = decode_proposal(rpc.call(controller, 'proposal(bytes32)', identifier))
    assertion = decode_assertion(rpc.call(oracle, 'getAssertion(bytes32)', identifier))
    report['proposal'] = proposal
    report['assertion'] = assertion
    assertion['challenge_seconds_remaining'] = max(0, assertion['challenge_expires_at'] - now)
    assertion['challenge_expires_utc'] = datetime.fromtimestamp(
        assertion['challenge_expires_at'], timezone.utc).isoformat()
    if proposal['quarter_id'] != quarter:
        alerts.append('Controller current-quarter mapping points to a different proposal quarter.')
    if expected is None:
        alerts.append('No independently compiled expected snapshot supplied; asserted ratios require review.')
    else:
        comparison = compare_snapshot(expected, proposal, quarter)
        report['snapshot_comparison'] = comparison
        if not comparison['quarter_matches']:
            alerts.append('Expected snapshot is not for this proposal and current quarter.')
        if not comparison['ratios_match']:
            alerts.append('ASSERTED RATIOS DIFFER FROM EXPECTED SNAPSHOT; independently review before challenge expiry.')
    status = proposal['status']
    if status == 'pending':
        if assertion['settled']:
            alerts.append('UMA settled externally; controller.settle still needs to record the result.')
        elif assertion['disputed']:
            alerts.append('UMA assertion is disputed and cannot execute before a truthful final resolution.')
        elif assertion['challenge_expires_at'] <= now:
            alerts.append('Undisputed challenge window closed; settlement is available.')
        else:
            alerts.append('Challenge window is open; independently verify the assertion before expiry.')
    elif status == 'rejected':
        alerts.append('Assertion was rejected; a corrected bonded proposal may be submitted this quarter.')
    elif status == 'accepted':
        alerts.append('Accepted assertion awaits permissionless execution within the valuation safety gates.')
    if status in ('accepted', 'executed') and not (assertion['settled'] and assertion['settlement_result']):
        alerts.append('INCONSISTENT STATE: accepted proposal lacks a settled truthful UMA assertion.')
    if status == 'executed' and last != quarter:
        alerts.append('INCONSISTENT STATE: executed proposal is absent from lastExecutedQuarter.')
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--controller', required=True)
    parser.add_argument('--rpc-url', '--rpc', default=os.environ.get('BASE_RPC_URL'),
                        help='Base JSON-RPC endpoint; defaults to BASE_RPC_URL')
    parser.add_argument('--expected-snapshot', type=Path,
                        help='Local independently compiled index_snapshot.py JSON output; never fetched remotely')
    args = parser.parse_args()
    try:
        if not args.rpc_url:
            raise ValueError('Supply --rpc-url or BASE_RPC_URL')
        expected = json.loads(args.expected_snapshot.read_text()) if args.expected_snapshot else None
        report = monitor(args.controller, RPC(args.rpc_url), expected)
        print(json.dumps(report, indent=2))
        return 1 if report['alerts'] else 0
    except Exception as exc:
        print(json.dumps({'read_checks_passed': False, 'transactions_sent': False,
                          'error': str(exc), 'action': 'Independent review required; monitor could not establish state.'}, indent=2))
        return 2


if __name__ == '__main__':
    sys.exit(main())
