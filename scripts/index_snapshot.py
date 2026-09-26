#!/usr/bin/env python3
"""Compile sourced quarter-end observations into deterministic human-token ratios."""
import argparse
import calendar
from datetime import date, datetime, timezone
from fractions import Fraction
import hashlib
import json
from pathlib import Path
import re
from urllib.parse import urlparse

SYMBOLS = ('AAPLc', 'AMZNc', 'GOOGLc', 'METAc', 'MSFTc', 'NVDAc', 'TSLAc')
CLASSES = {'GOOGLc': {'A': 'GOOGL', 'B': 'GOOGL', 'C': 'GOOG'},
           'METAc': {'A': 'META', 'B': 'META'}}
SCALE = 10**18


def decimal(value, signed=False):
    if not isinstance(value, str) or len(value) > 100:
        raise ValueError('Financial values must be decimal strings of at most 100 characters')
    pattern = r'(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)'
    if re.fullmatch(('-?' if signed else '') + pattern, value) is None:
        raise ValueError('Financial values must be plain decimal strings')
    # Validate before parsing, then preserve decimal input exactly without binary floats.
    return Fraction(value)


def positive(value):
    result = decimal(value)
    if result <= 0:
        raise ValueError('Financial values must be positive')
    return result


def instant(value):
    if not isinstance(value, str) or not value.endswith('Z'):
        raise ValueError('Timestamps must use UTC YYYY-MM-DDTHH:MM:SSZ')
    result = datetime.strptime(value, '%Y-%m-%dT%H:%M:%SZ').replace(tzinfo=timezone.utc)
    if result.strftime('%Y-%m-%dT%H:%M:%SZ') != value:
        raise ValueError('Noncanonical timestamp')
    return result


def source(value, sec=False):
    parsed = urlparse(value)
    if parsed.scheme != 'https' or not parsed.hostname:
        raise ValueError('Evidence must have an HTTPS URL')
    if sec and parsed.hostname not in ('www.sec.gov', 'sec.gov', 'data.sec.gov'):
        raise ValueError('Share-count filings must link to SEC evidence')


def allocate(values):
    """Largest-remainder normalization; canonical component order breaks ties."""
    scaled = [x * SCALE / sum(values) for x in values]
    floors = [x.numerator // x.denominator for x in scaled]
    remaining = SCALE - sum(floors)
    order = sorted(range(len(values)), key=lambda i: (-(scaled[i] - floors[i]), i))
    for i in order[:remaining]:
        floors[i] += 1
    if any(x <= 0 for x in floors):
        raise ValueError('Allocation too small for a nonzero 1e18-scaled ratio')
    return floors


def compile_snapshot(document):
    cutoff = instant(document['cutoff'])
    reference = instant(document['reference_at'])
    quarter = (cutoff.month - 1) // 3
    if (cutoff.month not in (3, 6, 9, 12) or
            cutoff.day != calendar.monthrange(cutoff.year, cutoff.month)[1] or
            cutoff.strftime('%H:%M:%S') != '23:59:59'):
        raise ValueError('Cutoff must be the UTC calendar-quarter end, 23:59:59')
    if not (cutoff.date().toordinal() - 7 <= reference.date().toordinal() <= cutoff.date().toordinal()):
        raise ValueError('Reference close must be in the final seven days of the quarter')
    if reference > cutoff:
        raise ValueError('Reference must precede cutoff')
    source(document['market_calendar_source'])
    companies = document['companies']
    if len(companies) != 7 or {c['symbol'] for c in companies} != set(SYMBOLS):
        raise ValueError('Exactly the seven unique canonical symbols are required')
    by_symbol = {c['symbol']: c for c in companies}
    quantities, caps = [], []
    for symbol in SYMBOLS:
        c = by_symbol[symbol]
        if c['share_basis'] != 'actual_outstanding_common':
            raise ValueError('Only actual outstanding common shares are accepted')
        if instant(c['token_price_at']) != reference or instant(c['multiplier_at']) != reference:
            raise ValueError('Token price and multiplier must match the reference close')
        source(c['token_price_source'])
        source(c['multiplier_source'])
        multiplier = positive(c['multiplier'])
        token_price = positive(c['token_price_usd'])
        expected = CLASSES.get(symbol, {'common': symbol[:-1]})
        classes = c['classes']
        if len(classes) != len(expected) or {x['id'] for x in classes} != set(expected):
            raise ValueError('Missing, duplicate, or unsupported share classes for ' + symbol)
        cap = Fraction(0)
        for cl in classes:
            source(cl['filing_source'], sec=True)
            source(cl['price_source'])
            share_date = date.fromisoformat(cl['shares_as_of'])
            filed = instant(cl['filing_published_at'])
            if share_date > reference.date() or filed > cutoff or share_date > filed.date():
                raise ValueError('Future share observation or filing published after cutoff')
            if instant(cl['price_at']) != reference or cl['price_symbol'] != expected[cl['id']]:
                raise ValueError('Class price/proxy must match the methodology and reference close')
            shares = positive(cl['shares_outstanding'])
            # Counts already include events on their observation date.
            last_action = datetime.combine(share_date, datetime.max.time(), tzinfo=timezone.utc)
            for adjustment in cl['adjustments']:
                effective = instant(adjustment['effective_at'])
                if effective <= last_action or effective > reference:
                    raise ValueError('Adjustments must follow the share observation in chronological order')
                if instant(adjustment['published_at']) > cutoff:
                    raise ValueError('Adjustment evidence published after cutoff')
                source(adjustment['source'])
                factor = positive(adjustment['factor'])
                delta = decimal(adjustment['delta_shares'], signed=True)
                shares = shares * factor + delta
                if shares <= 0:
                    raise ValueError('Adjusted outstanding shares must remain positive')
                last_action = effective
            cap += shares * positive(cl['price_usd'])
        held_class = 'A' if symbol in CLASSES else 'common'
        held_close = positive(next(cl['price_usd'] for cl in classes if cl['id'] == held_class))
        # Validate the identity; do not apply the multiplier a second time to the denominator.
        if abs(token_price - held_close * multiplier) > Fraction(1, 10**8):
            raise ValueError('Token reference price must equal held-class close times multiplier within 1e-8 USD')
        caps.append(cap)
        quantities.append(cap / token_price)
    canonical = json.dumps(document, sort_keys=True, separators=(',', ':'), ensure_ascii=False).encode()
    # Proposal happens in the following calendar quarter; Q4 naturally rolls into next year.
    proposal_quarter = cutoff.year * 4 + quarter + 1
    return {
        'methodology': 'M7CAP-v1', 'quarter_id': proposal_quarter,
        'cutoff': document['cutoff'], 'reference_at': document['reference_at'],
        'observation_sha256': '0x' + hashlib.sha256(canonical).hexdigest(),
        'symbols': list(SYMBOLS), 'quantity_ratios': [str(v) for v in allocate(quantities)],
        'reference_cap_weights': [str(v) for v in allocate(caps)],
        'scale': str(SCALE),
        'ratio_units': 'human token quantities, not base units or value percentages',
        'evidence_status': 'structurally validated; source truth requires independent review and UMA challenge',
    }


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('observations', type=Path)
    args = p.parse_args()
    try:
        print(json.dumps(compile_snapshot(json.loads(args.observations.read_text())), indent=2))
    except (ValueError, KeyError, TypeError, OSError) as exc:
        p.exit(1, 'Invalid observations: ' + str(exc) + '\n')


if __name__ == '__main__':
    main()
