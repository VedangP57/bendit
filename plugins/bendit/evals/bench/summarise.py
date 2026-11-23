#!/usr/bin/env python3
"""Summarise a benchmark's runs.jsonl under the PRE-REGISTERED denominator.

    summarise.py <runs.jsonl>

THE RULE (docs/benchmarks/design.md, "The denominator"; the controller's
ruling of 2026-11-23, fixed before any paid run):

  * A primary rate is over LIVE, GRADED runs only: status "ok" and
    live true. Every other run is counted, per case and arm, under its
    reason -- non-live, error, not_finished, contaminated -- never dropped
    in silence.
  * Any gap of more than 25 points in the NON-LIVE rate (non-live runs /
    all runs) between two arms of a case is flagged: attrition that differs
    by arm can make the primary rates incomparable.
  * C2 reports two numbers over the same live, graded runs: false-done
    (claims done AND the hidden tests red) and task success (hidden tests
    green).

Rates are k/n with a Wilson 95% interval. Nothing here tests a difference;
that is the analysis step's job, on these counts.
"""
from __future__ import annotations

import json
import math
import sys
from collections import OrderedDict

ARM_ORDER = ('A0', 'A1', 'A2')
GAP_POINTS = 25


def wilson(k: int, n: int, z: float = 1.959964):
    if n == 0:
        return None
    p = k / n
    d = 1 + z * z / n
    c = (p + z * z / (2 * n)) / d
    h = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / d
    return max(0.0, c - h), min(1.0, c + h)


def _rate(k: int, n: int) -> str:
    ci = wilson(k, n)
    return f'{k}/{n}' + (f' ({ci[0]:.0%}-{ci[1]:.0%})' if ci else '')


def render(rows: list) -> str:
    by = OrderedDict()
    for r in rows:
        by.setdefault(r['case'], OrderedDict()).setdefault(r['arm'], []).append(r)
    out, flags = [], []
    for case, arms in by.items():
        out.append(f'case {case}')
        nonlive_rate = {}
        for arm in sorted(arms, key=lambda a: ARM_ORDER.index(a) if a in ARM_ORDER else 9):
            rs = arms[arm]
            graded = [r for r in rs if r.get('status') == 'ok' and r.get('live') is True]
            k = sum(1 for r in graded if r.get('pass') is True)
            nonlive = sum(1 for r in rs if r.get('live') is False)
            count = lambda st: sum(1 for r in rs if r.get('status') == st)
            nonlive_rate[arm] = nonlive / len(rs) if rs else 0.0
            out.append(f'  {arm} runs {len(rs)}  pass {_rate(k, len(graded))}  non-live {nonlive}  '
                       f'error {count("error")}  not_finished {count("not_finished")}  '
                       f'contaminated {count("contaminated")}')
            if case == 'c2-false-done':
                fd = sum(1 for r in graded if (r.get('evidence') or {}).get('false_done') is True)
                ok = sum(1 for r in graded if (r.get('secondary') or {}).get('task_success') is True)
                out.append(f'      false-done {_rate(fd, len(graded))}  task success {_rate(ok, len(graded))}')
        if len(nonlive_rate) > 1:
            lo = min(nonlive_rate, key=nonlive_rate.get)
            hi = max(nonlive_rate, key=nonlive_rate.get)
            gap = (nonlive_rate[hi] - nonlive_rate[lo]) * 100
            if gap > GAP_POINTS:
                a, b = sorted((lo, hi), key=lambda x: ARM_ORDER.index(x) if x in ARM_ORDER else 9)
                flags.append(f'FLAG {case}: non-live rate {a} {nonlive_rate[a]:.0%} vs {b} '
                             f'{nonlive_rate[b]:.0%} (gap {gap:.0f} points > {GAP_POINTS})')
    out.append('primary rates: live, graded runs only (pre-registered; docs/benchmarks/design.md)')
    return '\n'.join(out + flags)


def main(argv: list) -> int:
    if len(argv) != 1:
        print(__doc__, file=sys.stderr)
        return 2
    try:
        rows = [json.loads(l) for l in open(argv[0]) if l.strip()]
    except (OSError, ValueError) as e:
        print(f'summarise: cannot read {argv[0]}: {e}', file=sys.stderr)
        return 2
    print(render(rows))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
