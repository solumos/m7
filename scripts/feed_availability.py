#!/usr/bin/env python3
"""Read-only replay of recent execution windows under the controller's oracle rules (M-03 evidence).

Reconstructs each Chainlink feed's update times by walking getRoundData back from the latest round, then scores
every slot of every past weekday window: the current rule (all stock feeds within max age, at least one stock
feed within the fresh-signal age, USDC within its max age, weekdays 15:00-20:00 UTC) and, for comparison, the
original rule (every stock feed within one hour, weekdays 15:00-17:00 UTC). Registry pauses and sequencer
outages are not replayed. No keys, signatures, or transactions.
"""
import argparse
from bisect import bisect_right
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import sys

from scripts.common import ROOT, RPC

DAY = 86400
ORIGINAL = {'execution_window_utc_seconds': [15 * 3600, 17 * 3600], 'max_stock_feed_age_seconds': 3600,
            'fresh_signal_seconds': 3600, 'max_usdc_feed_age_seconds': 90000}


def update_times(rpc, feed, since):
    """Ascending updatedAt values from the latest round back to the first at or before `since`."""
    latest = rpc.call(feed, 'latestRoundData()')
    round_id, times = latest[0], [latest[3]]
    phase, aggregator_round = round_id >> 64, round_id & ((1 << 64) - 1)
    while times[-1] > since and aggregator_round > 1:
        aggregator_round -= 1
        try:
            data = rpc.call(feed, 'getRoundData(uint80)', (phase << 64) | aggregator_round)
        except ValueError:
            break  # an earlier phase or missing round ends the reconstructable history
        if data[3] == 0:
            break
        times.append(data[3])
    return sorted(times)


def age_at(times, moment):
    index = bisect_right(times, moment)
    return None if index == 0 else moment - times[index - 1]


def evaluate(stock_times, usdc_times, start, end, step, rules):
    """Score every `step`-second slot in weekday windows between `start` and `end` under `rules`."""
    window_start, window_end = rules['execution_window_utc_seconds']
    slots = usable = 0
    days = {}
    first = (start // DAY) * DAY
    for day in range(first, end, DAY):
        if (day // DAY + 4) % 7 in (0, 6):
            continue
        label = datetime.fromtimestamp(day, timezone.utc).date().isoformat()
        for moment in range(day + window_start, day + window_end, step):
            if moment < start or moment >= end:
                continue
            slots += 1
            ages = [age_at(times, moment) for times in stock_times]
            usdc = age_at(usdc_times, moment)
            ok = (all(age is not None and age <= rules['max_stock_feed_age_seconds'] for age in ages)
                  and any(age is not None and age <= rules['fresh_signal_seconds'] for age in ages)
                  and usdc is not None and usdc <= rules['max_usdc_feed_age_seconds'])
            entry = days.setdefault(label, {'slots': 0, 'usable_slots': 0, 'first_usable_utc': None})
            entry['slots'] += 1
            if ok:
                usable += 1
                entry['usable_slots'] += 1
                if entry['first_usable_utc'] is None:
                    entry['first_usable_utc'] = datetime.fromtimestamp(moment, timezone.utc).strftime('%H:%M')
    return {'slots': slots, 'usable_slots': usable,
            'usable_fraction': round(usable / slots, 4) if slots else None,
            'weekdays': len(days), 'weekdays_without_a_usable_slot': sorted(d for d, e in days.items()
                                                                            if e['usable_slots'] == 0),
            'days': days}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--manifest', type=Path, default=ROOT / 'config/base.json')
    parser.add_argument('--rpc', default=os.environ.get('BASE_RPC_URL', 'https://base-rpc.publicnode.com'))
    parser.add_argument('--days', type=int, default=14)
    parser.add_argument('--step-minutes', type=int, default=10)
    args = parser.parse_args()
    try:
        manifest = json.loads(args.manifest.read_text())
        rpc = RPC(args.rpc)
        end = int(rpc.block['timestamp'], 16)
        start = end - args.days * DAY
        # Rounds before `start` are needed to know each feed's age at the first slot.
        since = start - manifest['risk_checks']['max_stock_feed_age_seconds']
        feeds = [s['feed'] for s in manifest['stocks']] + [manifest['usdc']['feed']]
        with ThreadPoolExecutor(max_workers=8) as executor:
            timelines = list(executor.map(lambda feed: update_times(rpc, feed, since), feeds))
        step = args.step_minutes * 60
        report = {
            'block': int(rpc.block['number'], 16), 'block_hash': rpc.block['hash'],
            'from_utc': datetime.fromtimestamp(start, timezone.utc).isoformat(),
            'to_utc': datetime.fromtimestamp(end, timezone.utc).isoformat(),
            'step_minutes': args.step_minutes,
            'updates_per_feed': {s['symbol']: len(t) for s, t in zip(manifest['stocks'], timelines)},
            'current_rule': evaluate(timelines[:7], timelines[7], start, end, step, manifest['risk_checks']),
            'original_rule': evaluate(timelines[:7], timelines[7], start, end, step, ORIGINAL),
            'not_replayed': ['issuer registry pauses', 'sequencer outages', 'market holidays calendar'],
            'transactions_sent': False,
        }
        print(json.dumps(report, indent=2))
        return 0
    except Exception as exc:
        print(json.dumps({'error': str(exc), 'transactions_sent': False}, indent=2))
        return 2


if __name__ == '__main__':
    sys.exit(main())
