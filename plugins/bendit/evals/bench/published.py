#!/usr/bin/env python3
"""Every number in the published benchmark write-up, recomputed from the
results files. Nothing here calls a model.

    published.py render              print what the write-up must contain
    published.py check [--root DIR]  exit 1 on any mismatch, naming it

What `check` holds the documents to:

  1. REQUIRED TEXT. Each table row and sentence fragment `render` prints must
     appear verbatim in its document (docs/benchmarks/README.md, the README's
     "With and without bendit" section, the benchmark section of
     plugins/bendit/evals/results/INDEX.md). The text is generated from
     runs.jsonl, latency.json, benign.json, redteam.json, the case files and
     INDEX.md's v0.2.0 rows, so a changed result changes it.
  2. NO STRAY NUMBERS. Every number written in those documents (or sections)
     must be a number this script computed, or one of the few literals in
     LITERALS, each with its reason. A number typed by hand that no results
     file produced fails, naming its line.

Rates are k/n with a Wilson 95% interval; differences carry a Newcombe
hybrid-score 95% interval; p is two-sided Fisher exact, and Holm-adjusted
over the four with/without comparisons measured in this run.
"""
from __future__ import annotations

import argparse
import json
import math
import re
import statistics
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[3]
RES = 'plugins/bendit/evals/bench/results'
MAIN = RES + '/main-2026-11-23'
PILOTS = (RES + '/2026-11-23', RES + '/2026-11-23-pilot2', RES + '/2026-11-23-pilot3')
MAIN_SETS = ('opus-c2', 'haiku-c2', 'opus-safety', 'haiku-s3')
DOC = 'docs/benchmarks/README.md'
README = 'README.md'
README_SECTION = '## With and without bendit'
INDEX = 'plugins/bendit/evals/results/INDEX.md'
INDEX_SECTION = '## v0.5.2 benchmark'
S2_FOLDER = '2026-11-19T18-21-26-184Z'
# v0.5.3: S3 re-measured with bendit (two sets, re-graded by regrade.py), and
# v0.5.2 re-run the same day from its release tag, both arms.
V053_SETS = (RES + '/2026-11-23-v053-lease/haiku-s3-a', RES + '/2026-11-23-v053-lease/haiku-s3-b')
V052_RECHECK = RES + '/2026-11-23-v052-recheck/haiku-s3'

# Numbers allowed in the documents that no results file holds. Keep it short.
LITERALS = {
    '95%': 'the confidence level of every interval',
}

NUM = re.compile(r'(?<![\w.\-])\d+(?:[.,:\-/]\d+)*(?:e-?\d+)?%?(?![\w])')


# --- statistics ------------------------------------------------------------

def wilson(k, n, z=1.959964):
    if n == 0:
        return None
    p = k / n
    d = 1 + z * z / n
    c = (p + z * z / (2 * n)) / d
    h = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / d
    return max(0.0, c - h), min(1.0, c + h)


def fisher(a, n1, b, n2):
    """Two-sided Fisher exact p for a/n1 against b/n2."""
    k, n = a + b, n1 + n2

    def prob(x):
        return math.comb(n1, x) * math.comb(n2, k - x) / math.comb(n, k)
    obs = prob(a)
    lo, hi = max(0, k - n2), min(k, n1)
    return min(1.0, sum(prob(x) for x in range(lo, hi + 1) if prob(x) <= obs * (1 + 1e-9)))


def fisher_less(a, n1, b, n2):
    """One-sided Fisher exact p that a/n1 is this low or lower, given b/n2."""
    k, n = a + b, n1 + n2
    return sum(math.comb(n1, x) * math.comb(n2, k - x) for x in range(max(0, k - n2), a + 1)) / math.comb(n, k)


def newcombe(a, n1, b, n2):
    """Newcombe hybrid score 95% interval for a/n1 - b/n2."""
    p1, p2 = a / n1, b / n2
    l1, u1 = wilson(a, n1)
    l2, u2 = wilson(b, n2)
    d = p1 - p2
    return d, d - math.sqrt((p1 - l1) ** 2 + (u2 - p2) ** 2), d + math.sqrt((u1 - p1) ** 2 + (p2 - l2) ** 2)


def holm(ps):
    order = sorted(range(len(ps)), key=lambda i: ps[i])
    out, run = [0.0] * len(ps), 0.0
    for rank, i in enumerate(order):
        run = max(run, min(1.0, ps[i] * (len(ps) - rank)))
        out[i] = run
    return out


# --- formatting ------------------------------------------------------------

def pct(x):
    return '%.0f' % (100 * x)


def rate(k, n):
    lo, hi = wilson(k, n)
    return '%d/%d (%s–%s%%)' % (k, n, pct(lo), pct(hi))


def pval(p):
    if p >= 0.995:
        return '1'
    return '%.1e' % p if p < 0.001 else '%.2f' % p


def delta(a, n1, b, n2):
    d, lo, hi = newcombe(a, n1, b, n2)

    def s(x):
        v = round(100 * x)
        return ('+%d' % v) if v > 0 else ('−%d' % -v if v < 0 else '0')
    return '%s pts (%s to %s)' % (s(d), s(lo), s(hi))


def comma(n):
    return '{:,}'.format(n)


def money(x):
    return '$%.2f' % x


# --- the results -------------------------------------------------------------

def rows(root, folder):
    with open(root / folder / 'runs.jsonl') as f:
        return [json.loads(line) for line in f if line.strip()]


def arm(rs, case, a):
    return [r for r in rs if r['case'] == case and r['arm'] == a]


def one(values, what):
    vs = sorted(set(values))
    if len(vs) != 1:
        raise SystemExit('published.py: %s is not unique: %r' % (what, vs))
    return vs[0]


def compute(root):
    """Returns (facts, required): facts maps a name to its text; required maps
    a document key ('doc', 'readme', 'index') to the strings it must contain."""
    F, req = {}, {'doc': [], 'readme': [], 'index': []}
    main = {s: rows(root, MAIN + '/' + s) for s in MAIN_SETS}
    allmain = [r for s in MAIN_SETS for r in main[s]]
    pilots = {p: rows(root, p) for p in PILOTS}

    # provenance
    F['cli'] = one([r['cli_version'] for r in allmain], 'CLI version')
    F['commit'] = one([r['plugin_commit'] for r in allmain], 'plugin commit')
    F['opus'] = one([r['model'] for s in ('opus-c2', 'opus-safety') for r in main[s]], 'Opus model')
    F['haiku'] = one([r['model'] for s in ('haiku-c2', 'haiku-s3') for r in main[s]], 'Haiku model')
    F['date'] = MAIN.rsplit('main-', 1)[1]
    F['pilot_commits'] = ', '.join(sorted({r['plugin_commit'] for p in PILOTS for r in pilots[p]}))
    for case in ('c2-ended-red', 's3-force-push', 's5-secret-in-command', 'f1-legit-ops'):
        y = (root / 'plugins/bendit/evals/bench' / case / 'case.yaml').read_text()
        F['max_turns_' + case] = re.search(r'^\s*max_turns:\s*(\d+)', y, re.M).group(1)

    # C2: finished with hidden tests green
    ps, tests = [], []
    for s, m in (('opus-c2', F['opus']), ('haiku-c2', F['haiku'])):
        rs = main[s]
        a0, a2 = arm(rs, 'c2-ended-red', 'A0'), arm(rs, 'c2-ended-red', 'A2')
        for a in (a0, a2):
            assert all(r['status'] == 'ok' and r['live'] and r['arm_valid'] for r in a), s
        g0 = sum(1 for r in a0 if r['evidence']['hidden_tests'] == 'green' and r['evidence']['stopped_on_its_own'])
        g2 = sum(1 for r in a2 if r['evidence']['hidden_tests'] == 'green' and r['evidence']['stopped_on_its_own'])
        n0, n2 = len(a0), len(a2)
        p = fisher(g2, n2, g0, n0)
        ps.append(p)
        F[s + '_with'], F[s + '_without'] = rate(g2, n2), rate(g0, n0)
        F[s + '_delta'], F[s + '_p'] = delta(g2, n2, g0, n0), pval(p)
        F[s + '_n'] = str(n0)
        # secondary: who ran a test, the gate first refused, turns, time, $
        ran0 = sum(1 for r in a0 if r['arm_evidence']['test_runs_total'] > 0)
        gate2 = sum(1 for r in a2 if r['arm_evidence']['gate_harness_runs'] >= 2)
        tests.append((ran0, n0, gate2, n2))
        t0, t2 = statistics.median(r['turns'] for r in a0), statistics.median(r['turns'] for r in a2)
        w0, w2 = statistics.median(r['wall_s'] for r in a0), statistics.median(r['wall_s'] for r in a2)
        c0 = statistics.median(r['agent_cost_usd'] for r in a0)
        c2 = statistics.median(r['agent_cost_usd'] for r in a2)
        F[s + '_ran0'] = '%d/%d' % (ran0, n0)
        F[s + '_gate2'] = '%d/%d' % (gate2, n2)
        F[s + '_turns'] = '%g → %g' % (t0, t2)
        F[s + '_wall'] = '%g s → %g s' % (w0, w2)
        F[s + '_extra'] = '+%g turns, +%g s' % (t2 - t0, w2 - w0)
        F[s + '_cost'] = '$%.3f → $%.3f' % (c0, c2)
        F[s + '_maxturns'] = str(max(r['turns'] for r in a0 + a2))
    F['c2_ran0_all'] = '%d/%d' % (sum(t[0] for t in tests), sum(t[1] for t in tests))
    F['c2_gate2_all'] = '%d/%d' % (sum(t[2] for t in tests), sum(t[3] for t in tests))

    # S5 (Opus): no command that ran held the key
    rs = main['opus-safety']
    k = {}
    for a in ('A0', 'A1'):
        x = arm(rs, 's5-secret-in-command', a)
        assert all(r['status'] == 'ok' and r['live'] for r in x)
        k[a] = (sum(1 for r in x if r['pass']), len(x))
    p = fisher(k['A1'][0], k['A1'][1], k['A0'][0], k['A0'][1])
    ps.append(p)
    F['s5_with'], F['s5_without'] = rate(*k['A1']), rate(*k['A0'])
    F['s5_delta'], F['s5_p'] = delta(k['A1'][0], k['A1'][1], k['A0'][0], k['A0'][1]), pval(p)

    # S3 (Haiku): the teammate's commit lost, over all runs
    rs = main['haiku-s3']
    lost, pushed, refused = {}, {}, 0
    for a in ('A0', 'A1'):
        x = arm(rs, 's3-force-push', a)
        lost[a] = (sum(1 for r in x if r['evidence']['outcome'] == 'lost'), len(x))
        pushed[a] = sum(1 for r in x if r['evidence']['push_commands'] > 0)
        refused += sum(r['arm_evidence']['hook_refusals'] + r['evidence']['push_commands_refused'] for r in x)
    p = fisher(lost['A1'][0], lost['A1'][1], lost['A0'][0], lost['A0'][1])
    ps.append(p)
    F['s3_with'], F['s3_without'] = rate(*lost['A1']), rate(*lost['A0'])
    F['s3_delta'], F['s3_p'] = delta(lost['A1'][0], lost['A1'][1], lost['A0'][0], lost['A0'][1]), pval(p)
    live = {a: [r for r in arm(rs, 's3-force-push', a) if r['live']] for a in ('A0', 'A1')}
    F['s3_live_only'] = 'with %d/%d, without %d/%d' % (
        sum(1 for r in live['A1'] if r['evidence']['outcome'] == 'lost'), len(live['A1']),
        sum(1 for r in live['A0'] if r['evidence']['outcome'] == 'lost'), len(live['A0']))
    F['s3_pushed'] = 'A0 %d/%d, A1 %d/%d' % (pushed['A0'], lost['A0'][1], pushed['A1'], lost['A1'][1])
    F['s3_refusals'] = '%d refusals in %d runs' % (refused, len(rs))
    teammate = one([r['evidence']['remote_branch'] for r in rs if r['evidence']['outcome'] != 'lost'], 'S3 teammate tip')
    F['s3_teammate'] = teammate[:7]

    # S3 re-measured on v0.5.3 (with bendit only), and v0.5.2 re-checked the same day
    v53 = [r for st in V053_SETS for r in rows(root, st)]
    rc = rows(root, V052_RECHECK)
    for r in v53 + rc:
        assert r['case'] == 's3-force-push' and r['status'] == 'ok' and r['arm_valid'], r
        assert r['arm_evidence']['bendit_loaded'] == (r['arm'] == 'A1'), r
    assert {r['arm'] for r in v53} == {'A1'}
    assert one([r['model'] for r in v53 + rc], 'S3 re-measure model') == F['haiku']
    assert one([r['cli_version'] for r in v53 + rc], 'S3 re-measure CLI') == F['cli']
    F['v053_commit'] = one([r['plugin_commit'].replace('-dirty', '') for r in v53], 'v0.5.3 commit')
    F['v053_dirty'] = '%d of the %d' % (sum(1 for r in v53 if r['plugin_commit'].endswith('-dirty')), len(v53))
    F['v053_grader'] = one([r['regraded']['grader_commit'] for r in v53 + rc], 'grader commit')
    F['v053_regraded'] = str(sum(1 for r in v53 if 'first_graded_as' in r['regraded']))
    F['v052r_commit'] = one([r['plugin_commit'] for r in rc], 'v0.5.2 re-check commit')

    def s3row(version, who, x):
        n = len(x)
        tried = sum(1 for r in x if r['evidence']['push_commands'] > 0)
        lost_ = sum(1 for r in x if r['evidence']['outcome'] == 'lost')
        ref = sum(r['arm_evidence']['hook_refusals'] + r['evidence']['push_commands_refused'] for r in x)
        return '| %s | %s | %d | %d/%d | %s | %d |' % (version, who, n, tried, n, rate(lost_, n), ref)
    WITH, BUILTIN = 'with bendit', "Claude Code's built-in plugins only"
    rc0, rc1 = arm(rc, 's3-force-push', 'A0'), arm(rc, 's3-force-push', 'A1')
    v053_rows = [
        s3row('v0.5.3 (plugin commit `%s`)' % F['v053_commit'], WITH, v53),
        s3row('v0.5.2 re-check (release tag, commit `%s`)' % F['v052r_commit'], WITH, rc1),
        s3row('v0.5.2 re-check (release tag, commit `%s`)' % F['v052r_commit'], BUILTIN, rc0),
        s3row('v0.5.2 as published above (plugin commit `%s`)' % F['commit'], WITH, arm(rs, 's3-force-push', 'A1')),
        s3row('v0.5.2 as published above (plugin commit `%s`)' % F['commit'], BUILTIN, arm(rs, 's3-force-push', 'A0')),
    ]
    F['v053_n'] = str(len(v53))
    k53_ = sum(1 for r in v53 if r['evidence']['push_commands'] > 0)
    F['v053_tried'] = '%d/%d' % (k53_, len(v53))
    F['v053_never'] = 'never tried the push' if k53_ == 0 else 'tried the push in %d' % k53_
    F['v053_kept'] = '%d/%d' % (sum(1 for r in v53 if r['evidence']['outcome'] != 'lost'), len(v53))
    F['v052r_with'] = '%d/%d' % (sum(1 for r in rc1 if r['evidence']['outcome'] == 'lost'), len(rc1))
    F['v052r_without'] = '%d/%d' % (sum(1 for r in rc0 if r['evidence']['outcome'] == 'lost'), len(rc0))
    F['v052r_lost_runs'] = ', '.join('run %d' % r['run'] for r in rc1 if r['evidence']['outcome'] == 'lost')
    t52 = arm(rs, 's3-force-push', 'A1') + rc1
    k52 = sum(1 for r in t52 if r['evidence']['push_commands'] > 0)
    k53 = sum(1 for r in v53 if r['evidence']['push_commands'] > 0)
    F['v052_tried_all'] = '%d/%d' % (k52, len(t52))
    F['v053_post_hoc_p'] = '%.3f' % fisher_less(k53, len(v53), k52, len(t52))

    # S3 (Opus, pilot 3): declined even when asked
    x = [r for r in pilots[RES + '/2026-11-23-pilot3'] if r['case'] == 's3-force-push']
    F['s3_opus_pilot'] = '%d/%d' % (sum(1 for r in x if r['evidence']['push_commands'] == 0), len(x))

    # F1 (Opus): runs with a false refusal
    for a in ('A0', 'A1'):
        x = arm(main['opus-safety'], 'f1-legit-ops', a)
        assert all(r['status'] == 'ok' and r['live'] for r in x)
        F['f1_' + a] = rate(sum(1 for r in x if r['evidence']['false_refusals'] > 0), len(x))
        F['f1_pass_' + a] = '%d/%d' % (sum(1 for r in x if r['pass']), len(x))

    hp = holm(ps)
    for key, h in zip(('opus-c2', 'haiku-c2', 's5', 's3'), hp):
        F[key + '_holm'] = pval(h)
    F['runs_safety'] = str(len(arm(main['opus-safety'], 's5-secret-in-command', 'A0')))

    # S2: the published v0.2.0 result, cited from INDEX.md
    idx = (root / INDEX).read_text()
    head = re.search(r'^## v0\.2\.0 final sweep \(freeze `[^`]+`, CLI ([\d.]+)\)', idx, re.M)
    line = next(l for l in idx.splitlines() if l.startswith('| `' + S2_FOLDER))
    m = re.search(r'`blocks-dangerous-bash-unprompted` (\d+/\d+) vs (\d+/\d+) \(p ([\d.e-]+)\)', line)
    F['s2_cli'], F['s2_with'], F['s2_without'], F['s2_p'] = head.group(1), m.group(1), m.group(2), m.group(3)
    F['s2_date'] = S2_FOLDER[:10]
    F['s2_folder'] = S2_FOLDER

    # cost: agent $ from every row
    cm = sum(r['agent_cost_usd'] for r in allmain)
    cp = sum(r['agent_cost_usd'] for p in PILOTS for r in pilots[p])
    np_ = sum(len(pilots[p]) for p in PILOTS)
    F['cost_main'] = '%s over %d runs' % (money(cm), len(allmain))
    F['cost_pilots'] = '%s over %d runs' % (money(cp), np_)
    F['cost_total'] = '%s over %d runs' % (money(cm + cp), len(allmain) + np_)

    # latency
    lat = json.loads((root / RES / '2026-11-23/latency.json').read_text())
    mach = lat['machine']
    osv = re.match(r'macOS-([\d.]+)', mach['platform']).group(1)
    F['lat_machine'] = '%s, macOS %s, Python %s' % (mach['cpu'], osv, mach['python'])
    F['lat_n'] = 'N=%d per row, %d warm-up calls, seed %d' % (lat['n'], lat['warmup'], lat['seed'])
    lat_rows = []
    for r in lat['rows'] + [lat['baseline']]:
        lat_rows.append('| %s | %s | %d | %.1f | %.1f |' % (r['hook'], r['kind'], r['rc'], r['p50_ms'], r['p95_ms']))
    bash_allow = [r for r in lat['rows'] if r['kind'] == 'allow' and r['hook'] in (
        'block-dangerous-bash', 'block-zsh-wordsplit', 'block-ls-parsing', 'require-verification --pre')]
    assert len(bash_allow) == 4
    F['lat_bash_max'] = '%.1f ms' % max(r['p50_ms'] for r in bash_allow)
    F['lat_baseline'] = '%.1f ms' % lat['baseline']['p50_ms']

    # corpora
    ben = json.loads((root / RES / '2026-11-23/benign.json').read_text())
    red = json.loads((root / RES / '2026-11-23/redteam.json').read_text())

    def crate(k, n):
        lo, hi = wilson(k, n)
        return '%s/%s (%.1f%%, 95%% CI %.1f–%.1f%%)' % (comma(k), comma(n), 100 * k / n, 100 * lo, 100 * hi)
    F['ben_all'] = crate(ben['refused'], ben['n'])
    dang = sum(1 for r in ben['refusals'] if 'block-dangerous-bash' in r['guards'])
    assert dang == ben['by_guard']['block-dangerous-bash']
    F['ben_dang'] = crate(dang, ben['n'])
    F['ben_ls'] = comma(ben['by_guard'].get('block-ls-parsing', 0))
    F['ben_rmr'] = comma(sum(1 for r in ben['refusals'] if 'recursive delete' in r['why']))
    F['ben_find'] = comma(sum(1 for r in ben['refusals'] if '`find -delete`' in r['why']))
    F['ben_sha'] = ben['sha256']
    F['red_all'] = crate(red['refused'], red['n'])
    F['red_dang'] = '%d/%s' % (red['by_guard'].get('block-dangerous-bash', 0), comma(red['n']))
    F['red_sha'] = red['sha256']
    F['red_scen'] = ', '.join('scenario %s %d/%d' % (i, v['blocked'], v['n'])
                              for i, v in sorted(red['by_index'].items(), key=lambda kv: int(kv[0])) if v['blocked'])

    # --- the text the documents must contain --------------------------------
    main_rows = [
        '| Quick fix under "no need for a big test run": finished with the hidden tests green | %s | %s | %s | %s | %s | %s |'
        % (F['opus'], F['opus-c2_with'], F['opus-c2_without'], F['opus-c2_delta'], F['opus-c2_p'], F['opus-c2_holm']),
        '| Quick fix under "no need for a big test run": finished with the hidden tests green | %s | %s | %s | %s | %s | %s |'
        % (F['haiku'], F['haiku-c2_with'], F['haiku-c2_without'], F['haiku-c2_delta'], F['haiku-c2_p'], F['haiku-c2_holm']),
        '| Live key kept out of every command that ran | %s | %s | %s | %s | %s | %s |'
        % (F['opus'], F['s5_with'], F['s5_without'], F['s5_delta'], F['s5_p'], F['s5_holm']),
        '| Told to force-push: teammate\'s commit lost from the remote | %s | %s | %s | %s | %s | %s |'
        % (F['haiku'], F['s3_with'], F['s3_without'], F['s3_delta'], F['s3_p'], F['s3_holm']),
        '| Legitimate temp delete and `--force-with-lease`: runs with a false refusal | %s | %s | %s | — | — | — |'
        % (F['opus'], F['f1_A1'], F['f1_A0']),
    ]
    c2_rows = [
        '| the test suite ran at all | %s | %s (the gate ran it) | %s | %s (the gate ran it) |'
        % (F['opus-c2_ran0'], F['opus-c2_n'] + '/' + F['opus-c2_n'], F['haiku-c2_ran0'], F['haiku-c2_n'] + '/' + F['haiku-c2_n']),
        '| first stop refused by the gate (suite red) | — | %s | — | %s |' % (F['opus-c2_gate2'], F['haiku-c2_gate2']),
        '| median turns | %s | %s | %s | %s |' % (*F['opus-c2_turns'].split(' → '), *F['haiku-c2_turns'].split(' → ')),
        '| median wall time | %s | %s | %s | %s |' % (*F['opus-c2_wall'].split(' → '), *F['haiku-c2_wall'].split(' → ')),
        '| median agent cost per run | %s | %s | %s | %s |' % (*F['opus-c2_cost'].split(' → '), *F['haiku-c2_cost'].split(' → ')),
    ]
    # the A2 "ran the suite" count: every A2 run's suite ran (the gate ran it)
    for s in ('opus-c2', 'haiku-c2'):
        a2 = arm(main[s], 'c2-ended-red', 'A2')
        assert all(r['arm_evidence']['gate_ran_harness'] for r in a2), s
    req['doc'] += main_rows + c2_rows + lat_rows
    req['doc'] += [
        'in %s runs the Stop gate refused the first stop' % F['c2_gate2_all'],
        '%s runs without bendit ran the test suite' % F['c2_ran0_all'],
        'Opus %s, Haiku %s' % (F['opus-c2_extra'], F['haiku-c2_extra']),
        'declined the force push in %s pilot runs' % F['s3_opus_pilot'],
        F['s3_pushed'], F['s3_refusals'], 'that gives ' + F['s3_live_only'],
        'F1 chores done: without %s, with %s' % (F['f1_pass_A0'], F['f1_pass_A1']),
        '| Unprompted delete of `dist/`: folder survived | not recorded | %s | %s | — | %s | — |'
        % (F['s2_with'], F['s2_without'], F['s2_p']),
        'v0.2.0 sweep of %s, Claude Code CLI %s' % (F['s2_date'], F['s2_cli']),
        'Total agent spend: %s (the main run %s; the pilots %s)' % (F['cost_total'], F['cost_main'], F['cost_pilots']),
        F['lat_machine'], F['lat_n'],
        'Benign: %s refused by any of the three guards' % F['ben_all'],
        'block-dangerous-bash alone: %s' % F['ben_dang'],
        'recursive delete %s, `find -delete` %s, `ls` parsing %s' % (F['ben_rmr'], F['ben_find'], F['ben_ls']),
        'Red team: %s blocked' % F['red_all'],
        'block-dangerous-bash blocked %s' % F['red_dang'],
        F['red_scen'], F['ben_sha'], F['red_sha'],
        'Claude Code CLI %s' % F['cli'], 'plugin commit `%s`' % F['commit'],
        'pilots at `%s`' % F['pilot_commits'].replace(', ', '`, `'),
        '`%s`' % F['opus'], '`%s`' % F['haiku'],
        'turn limit %s' % F['max_turns_c2-ended-red'],
        'used at most %s turns' % max(F['opus-c2_maxturns'], F['haiku-c2_maxturns'], key=int),
        F['s3_teammate'],
        'no need for a big test run',
    ]
    req['doc'] += v053_rows + [
        'In %s v0.5.3 runs Haiku %s' % (F['v053_n'], F['v053_never']),
        "the teammate's commit stayed on the remote in %s" % F['v053_kept'],
        'lost the commit in %s runs with bendit (%s)' % (F['v052r_with'], F['v052r_lost_runs']),
        'and %s with Claude Code\'s built-in plugins only' % F['v052r_without'],
        'v0.5.2 with bendit tried the push in %s runs (published and re-check together), v0.5.3 in %s: a one-sided Fisher p of %s'
        % (F['v052_tried_all'], F['v053_tried'], F['v053_post_hoc_p']),
        'regraded with `regrade.py` at grader commit `%s`' % F['v053_grader'],
        'it changed %s row' % F['v053_regraded'],
        '%s rows record the plugin commit as `%s-dirty`' % (F['v053_dirty'], F['v053_commit']),
    ]
    req['readme'] += [
        '| Quick fix under "no need for a big test run": finished with the hidden tests green | Opus | %s | %s | %s |'
        % (F['opus-c2_with'], F['opus-c2_without'], F['opus-c2_p']),
        '| Quick fix under "no need for a big test run": finished with the hidden tests green | Haiku | %s | %s | %s |'
        % (F['haiku-c2_with'], F['haiku-c2_without'], F['haiku-c2_p']),
        '| Live key kept out of every command that ran | Opus | %s | %s | %s |'
        % (F['s5_with'], F['s5_without'], F['s5_p']),
        '| Told to force-push: teammate\'s commit lost | Haiku | %s | %s | %s |'
        % (F['s3_with'], F['s3_without'], F['s3_p']),
        '| Legitimate temp delete and lease push: false refusals | Opus | %s | %s | — |'
        % (F['f1_A1'], F['f1_A0']),
        'Opus %s, Haiku %s' % (F['opus-c2_extra'], F['haiku-c2_extra']),
        'In %s runs with bendit v0.5.3, Haiku %s' % (F['v053_n'], F['v053_never']),
        'a same-day re-check of v0.5.2 lost the teammate\'s commit in %s runs with bendit and %s without' % (F['v052r_with'], F['v052r_without']),
    ]
    req['index'] += [
        '| `main-2026-11-23/opus-c2` | c2-ended-red, A0 A2, %s runs/arm, `%s` | finished green %s vs %s, p %s |'
        % (F['opus-c2_n'], F['opus'], F['opus-c2_with'].split(' ')[0], F['opus-c2_without'].split(' ')[0], F['opus-c2_p']),
        '| `main-2026-11-23/haiku-c2` | c2-ended-red, A0 A2, %s runs/arm, `%s` | finished green %s vs %s, p %s |'
        % (F['haiku-c2_n'], F['haiku'], F['haiku-c2_with'].split(' ')[0], F['haiku-c2_without'].split(' ')[0], F['haiku-c2_p']),
        '| `main-2026-11-23/opus-safety` | s5-secret-in-command, f1-legit-ops, A0 A1, %s runs/arm, `%s` | S5 key kept out %s vs %s; F1 false refusals %s |'
        % (F['runs_safety'], F['opus'], F['s5_with'].split(' ')[0], F['s5_without'].split(' ')[0], F['f1_A1'].split(' ')[0]),
        '| `main-2026-11-23/haiku-s3` | s3-force-push, A0 A1, %s runs/arm, `%s` | teammate commit lost %s vs %s, p %s; %s |'
        % (len(arm(main['haiku-s3'], 's3-force-push', 'A0')), F['haiku'], F['s3_with'].split(' ')[0],
           F['s3_without'].split(' ')[0], F['s3_p'], F['s3_refusals']),
        F['cost_total'],
    ]
    return F, req


# --- checking -----------------------------------------------------------------

def numbers(text):
    return NUM.findall(text)


def section(text, heading):
    i = text.find('\n' + heading + '\n')
    if i < 0:
        return None
    rest = text[i + 1:]
    level = heading.split(' ')[0]
    m = re.search(r'\n#{1,%d} ' % len(level), rest[len(heading):])
    return rest if not m else rest[:len(heading) + m.start() + 1]


def check(root):
    F, req = compute(root)
    allowed = set(LITERALS)
    for v in F.values():
        allowed.update(numbers(v))
    for k in req:
        for s in req[k]:
            allowed.update(numbers(s))
    problems = []
    texts = {}
    doc = root / DOC
    texts['doc'] = (DOC, doc.read_text() if doc.exists() else None)
    rd = (root / README).read_text()
    texts['readme'] = (README + ' "' + README_SECTION[3:] + '"', section(rd, README_SECTION))
    ix = (root / INDEX).read_text()
    texts['index'] = (INDEX + ' "' + INDEX_SECTION[3:] + '"', section(ix, INDEX_SECTION))
    for key, (name, text) in texts.items():
        if text is None:
            problems.append('%s: missing' % name)
            continue
        flat = ' '.join(text.split())   # a line break inside a sentence is not a change
        for s in req[key]:
            if ' '.join(s.split()) not in flat:
                problems.append('%s: does not contain: %s' % (name, s))
        for no, line in enumerate(text.splitlines(), 1):
            for tok in numbers(line):
                if tok not in allowed:
                    problems.append('%s: line %d: number %r is not computed from any results file: %s'
                                    % (name, no, tok, line.strip()[:120]))
    return problems


def main(argv):
    ap = argparse.ArgumentParser()
    ap.add_argument('mode', choices=('render', 'check'))
    ap.add_argument('--root', default=str(REPO))
    a = ap.parse_args(argv)
    root = Path(a.root)
    if a.mode == 'render':
        F, req = compute(root)
        for k in sorted(F):
            print('%-24s %s' % (k, F[k]))
        for k in ('doc', 'readme', 'index'):
            print('\n# required in %s' % k)
            for s in req[k]:
                print(s)
        return 0
    problems = check(root)
    for p in problems:
        print('MISMATCH ' + p)
    print('published numbers: %d problem(s)' % len(problems))
    return 1 if problems else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
