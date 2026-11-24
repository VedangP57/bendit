#!/usr/bin/env python3
"""Re-count S3's liveness from the traces a result set kept, with NO model call.

    regrade.py <result-dir> [<result-dir> ...]

For each S3 row of <result-dir>/runs.jsonl it finds the run's kept trace (the
tracePath in raw/<step>/aggregate-result.json), re-counts the push commands
with grade.is_push, and prints the published and the re-counted live and
push_commands side by side. Only `live` and the push counts depend on the push
test; `pass` reads the final workspace and is not re-derived. Nothing is
written: runs.jsonl is left as published.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import grade  # noqa: E402


def trace_of(raw: Path):
    agg = json.loads((raw / 'aggregate-result.json').read_text())
    for c in agg.get('cases') or []:
        for arm in (c.get('arms') or {}).values():
            for r in arm or []:
                if r.get('tracePath'):
                    return Path(r['tracePath'])
    return None


def regrade(result_dir: Path) -> list:
    out = []
    for line in (result_dir / 'runs.jsonl').read_text().splitlines():
        row = json.loads(line)
        if row.get('case') != 's3-force-push':
            continue
        raw = result_dir / 'raw' / f"r{row['run']}-{row['case']}-{row['arm']}"
        trace = trace_of(raw) if raw.is_dir() else None
        if trace is None or not trace.is_file():
            out.append(dict(row=row, new=None))
            continue
        calls = [c for c in grade.bash_calls(grade.load_trace(trace)) if grade.is_push(c['command'])]
        out.append(dict(row=row, new={'live': bool(calls), 'push_commands': len(calls),
                                      'refused': sum(1 for c in calls if not c['ran'])}))
    return out


def main(argv: list) -> int:
    if not argv:
        print(__doc__)
        return 2
    for d in argv:
        d = Path(d)
        print(f'== {d}')
        print('  run arm  pass  live(published -> re-graded)  pushes(pub -> new)')
        live = {}
        for x in regrade(d):
            r, n = x['row'], x['new']
            if n is None:
                print(f"  r{r['run']:<3} {r['arm']}  trace not kept: cannot re-grade")
                continue
            ev = r.get('evidence') or {}
            flag = '' if (r['live'], ev.get('push_commands')) == (n['live'], n['push_commands']) else '   CHANGED'
            print(f"  r{r['run']:<3} {r['arm']}  {str(r.get('graded_pass')):<5} "
                  f"{str(r['live']):<5} -> {str(n['live']):<5}  {ev.get('push_commands')} -> {n['push_commands']}{flag}")
            a = live.setdefault(r['arm'], [0, 0, 0])
            a[0] += 1
            a[1] += bool(r['live'])
            a[2] += n['live']
        for arm, (tot, old, new) in sorted(live.items()):
            print(f'  {arm}: live {old}/{tot} published, {new}/{tot} re-graded')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
