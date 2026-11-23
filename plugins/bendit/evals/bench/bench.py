#!/usr/bin/env python3
"""Run the with/without-bendit benchmark, interleaved, one run at a time.

    run.sh --cases <c1,c2> --arms A0,A1[,A2] --runs N --model <id>
           [--pilot] [--dry-run] [--out <dir>] [--trust-plugin]

WHY ONE INVOCATION PER RUN. `claude plugin eval` runs every with-plugin run
of a case before any without-plugin run, so a sweep's arms never overlap in
time and API load drift lands on one arm. Here every (run, case, arm) is its
own `claude plugin eval --runs 1 --ablation none`, and the arm order rotates
with the run index (A0 A1 A2, then A1 A2 A0, ...), so each arm is spread
over the whole sweep.

THE ARMS.
  A0  no bendit: the target is an empty plugin carrying only the case files
  A1  bendit, no harness approved (the out-of-box state)
  A2  bendit, and the case's .claude/verify-harness approved -- written by
      the case fixture into THIS run's own BENDIT_CONFIG_DIR, a directory
      under the results folder carrying a marker file; never the person's
      ~/.config/bendit
Every run gets its own BENDIT_CONFIG_DIR and BENDIT_VERIFY_INDEX. A2 is
proven, not assumed: the row records whether the approval was written and
whether bendit's Stop gate itself ran the harness (the workspace's
test-runs.log names the process chain of every test run). --pilot turns any
arm whose evidence does not match its name into a failure.

THE ROW. One JSON line per run in <out>/runs.jsonl: case, arm, run, pass,
live, evidence, secondary, wall_s, turns, agent_cost_usd (costUsd minus the
judge), judge_cost_usd, cli_version, model, plugin_commit, arm_evidence,
arm_valid, error. A run that cannot be graded has pass null and an error,
never a pass.

Grants: each call passes exactly the case's tools (cases.json, the same list
as its case.yaml) as --allow-tools, plus --scaffold --keep-temp --no-publish.
"""
from __future__ import annotations

import argparse
import json
import os
import shlex
import shutil
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import grade  # noqa: E402
import summarise  # noqa: E402

PLUGIN = HERE.parent.parent
ARMS = ('A0', 'A1', 'A2')
MARKER = '.bench-isolated'


def load_cases() -> dict:
    data = json.loads((HERE / 'cases.json').read_text())
    return {k: v for k, v in data.items() if not k.startswith('_')}


CASES = load_cases()


class Usage(Exception):
    pass


def parse(argv: list):
    p = argparse.ArgumentParser(prog='run.sh', add_help=True)
    p.add_argument('--cases', required=True)
    p.add_argument('--arms', required=True)
    p.add_argument('--runs', type=int, required=True)
    p.add_argument('--model')
    p.add_argument('--pilot', action='store_true')
    p.add_argument('--dry-run', action='store_true')
    p.add_argument('--out')
    p.add_argument('--trust-plugin', action='store_true')
    try:
        a = p.parse_args(argv)
    except SystemExit as e:
        if e.code == 0:
            raise
        raise Usage('bad arguments (see run.sh --help)')
    a.cases = [c for c in a.cases.split(',') if c]
    a.arms = [x for x in a.arms.split(',') if x]
    for c in a.cases:
        if c not in CASES:
            raise Usage(f'unknown case {c!r}; known: {", ".join(CASES)}')
    for x in a.arms:
        if x not in ARMS:
            raise Usage(f'unknown arm {x!r}; arms are {", ".join(ARMS)}')
    if len(set(a.arms)) != len(a.arms) or len(set(a.cases)) != len(a.cases):
        raise Usage('a case or an arm is listed twice')
    if a.runs < 1:
        raise Usage('--runs must be at least 1')
    if not a.dry_run and not a.model:
        raise Usage('--model is required for a real run: a result must name its model, never "default"')
    return a


def plan(cases: list, arms: list, runs: int):
    """[(run, case, arm)] in execution order, and the (case, arm) pairs
    skipped because the case is not meant for that arm."""
    steps, skipped = [], []
    for r in range(1, runs + 1):
        k = (r - 1) % len(arms)
        order = arms[k:] + arms[:k]
        for c in cases:
            for arm in order:
                if arm in CASES[c]['arms']:
                    steps.append((r, c, arm))
                elif r == 1:
                    skipped.append((c, arm))
    return steps, skipped


def step_id(r: int, case: str, arm: str) -> str:
    return f'r{r}-{case}-{arm}'


def claude_cmd() -> list:
    return shlex.split(os.environ.get('BENDIT_BENCH_CLAUDE') or 'claude')


def eval_command(case: str, target: Path, raw: Path, model, trust: bool) -> list:
    cmd = claude_cmd() + ['plugin', 'eval', str(target), '--case', case, '--tag', 'bench',
                          '--runs', '1', '--ablation', 'none', '--scaffold', '--keep-temp',
                          '--no-publish', '--threshold', '0', '-j', '1',
                          '--output-dir', str(raw), '--report', str(raw / 'report.html')]
    if model:
        cmd += ['--model', model]
    if trust:
        cmd.append('--trust-plugin')
    return cmd + ['--allow-tools'] + list(CASES[case]['tools'])


def real_config_dirs() -> list:
    home = Path.home()
    dirs = [home / '.config' / 'bendit']
    xdg = os.environ.get('XDG_CONFIG_HOME')
    if xdg:
        dirs.append(Path(xdg) / 'bendit')
    return dirs


def assert_isolated(path: Path) -> None:
    """Refuse a results folder (and so a BENDIT_CONFIG_DIR) inside the
    person's real bendit config dir."""
    p = os.path.realpath(str(path))
    for d in real_config_dirs():
        r = os.path.realpath(str(d))
        if p == r or p.startswith(r + os.sep):
            raise Usage(f'{path} is inside the real bendit config dir ({d}); the benchmark writes '
                        'approvals into isolated dirs only')


def plugin_commit() -> str:
    try:
        head = subprocess.run(['git', '-C', str(PLUGIN), 'rev-parse', '--short', 'HEAD'],
                              capture_output=True, text=True).stdout.strip()
        dirty = subprocess.run(['git', '-C', str(PLUGIN), 'status', '--porcelain', '--', '.',
                                ':!evals/bench/results'], capture_output=True, text=True).stdout.strip()
    except OSError:
        return 'unknown'
    return (head or 'unknown') + ('-dirty' if dirty else '')


def build_null_plugin(out: Path, cases: list) -> Path:
    d = out / 'null-plugin'
    (d / '.claude-plugin').mkdir(parents=True, exist_ok=True)
    (d / '.claude-plugin' / 'plugin.json').write_text(json.dumps({
        'name': 'bench-null', 'version': '0.0.0',
        'description': 'Empty plugin: carries the benchmark cases for the no-bendit arm.'}, indent=2) + '\n')
    for c in cases:
        dst = d / 'evals' / 'bench' / c
        if dst.exists():
            shutil.rmtree(str(dst))
        shutil.copytree(str(HERE / c), str(dst))
    return d


# --- after a run: find what it left, grade it, check the arm ---------------

def _openable(p: Path) -> None:
    """The harness seals a kept workspace (mode 000). It is ours: let us read it."""
    if p.is_dir() and not os.access(str(p), os.R_OK | os.X_OK):
        os.chmod(str(p), 0o700)


def locate_workspace(sandbox: Path, anchor: str) -> Path:
    _openable(sandbox)
    sealed = sandbox / 'sealed'
    _openable(sealed)
    cands = [sandbox / 'home' / 'cwd', sealed / 'home' / 'cwd', sealed / 'cwd']
    if sealed.is_dir():
        for child in sorted(sealed.iterdir()):
            _openable(child)
            cands.append(child / 'cwd')
    for c in cands:
        for part in (c.parent, c):
            _openable(part)
    found = []
    for c in cands:
        if (c / anchor).exists() and os.path.realpath(str(c)) not in found:
            found.append(os.path.realpath(str(c)))
    if len(found) != 1:
        raise RuntimeError(f'expected one kept workspace holding {anchor} under {sandbox.name}, '
                           f'found {len(found)}')
    return Path(found[0])


def find_run(agg: dict, case: str) -> dict:
    for c in agg.get('cases') or []:
        if c.get('name') == case:
            runs = [r for arm in (c.get('arms') or {}).values() for r in (arm or [])]
            if len(runs) != 1:
                raise RuntimeError(f'expected 1 run of {case}, the harness reported {len(runs)}')
            return runs[0]
    raise RuntimeError(f'the harness reported no case {case}')


def arm_evidence(case: str, events: list, cfg: Path, ws) -> dict:
    plugins = grade.plugins_loaded(events)
    ev = {'bendit_loaded': 'bendit' in plugins, 'plugins': plugins,
          'hooks_seen': grade.hooks_seen(events), 'bendit_hooks_seen': grade.bendit_hooks_seen(events),
          'hook_refusals': grade.hook_refusals(events)}
    if CASES[case].get('harness_log'):
        trust = cfg / 'trusted-harnesses.json'
        try:
            ev['approval_written'] = bool(json.loads(trust.read_text()).get('trusted'))
        except (OSError, ValueError, AttributeError):
            ev['approval_written'] = False
        lines = []
        if ws is not None:
            try:
                lines = (Path(ws) / '.git' / 'test-runs.log').read_text().splitlines()
            except OSError:
                lines = []
        gate = [l for l in lines if 'require-verification.py' in l]
        ev['gate_ran_harness'] = bool(gate)
        ev['gate_harness_runs'] = len(gate)
        ev['test_runs_total'] = len(lines)
    return ev


def check_arm(case: str, arm: str, ev: dict) -> list:
    """What does not match the arm's name. Empty = valid."""
    problems = []
    if arm == 'A0' and ev.get('bendit_loaded'):
        problems.append('A0 has bendit loaded')
    if arm in ('A1', 'A2') and not ev.get('bendit_loaded'):
        problems.append(f'{arm} does not have bendit loaded')
    if CASES[case].get('harness_log'):
        if arm == 'A1' and (ev.get('approval_written') or ev.get('gate_ran_harness')):
            problems.append('A1 has an approved harness or a gate harness run')
        if arm == 'A2' and not ev.get('approval_written'):
            problems.append('A2: no harness approval was written to its config dir')
        if arm == 'A2' and not ev.get('gate_ran_harness'):
            problems.append('A2: the Stop gate never ran the harness')
    return problems


def _cost(v):
    try:
        return None if v is None else float(v)
    except (TypeError, ValueError):
        return None


def build_row(r: int, case: str, arm: str, raw: Path, cfg: Path, commit: str) -> dict:
    """One row. `status` is one of ok / error / not_finished / contaminated
    (not_finished: the recorded stop reason is the turn limit, nothing else),
    and `pass` is null unless status is ok and the run is live: the
    pre-registered denominator (docs/benchmarks/design.md, "The denominator")."""
    row = {'case': case, 'arm': arm, 'run': r, 'pass': None, 'live': None, 'status': 'error',
           'graded_pass': None, 'evidence': {},
           'secondary': {}, 'wall_s': None, 'turns': None, 'agent_cost_usd': None,
           'judge_cost_usd': None, 'cli_version': None, 'model': None, 'plugin_commit': commit,
           'arm_evidence': {}, 'arm_valid': False, 'arm_problems': [], 'harness_error': None,
           'error': None, 'stop_reason': None}
    ws = None
    events: list = []
    try:
        agg = json.loads((raw / 'aggregate-result.json').read_text())
        run = find_run(agg, case)
        cost, judge = _cost(run.get('costUsd')), _cost(run.get('judgeCostUsd'))
        # A missing cost stays null: a row never understates what a run cost.
        row.update(wall_s=run.get('durationSeconds'), turns=run.get('turns'),
                   agent_cost_usd=None if cost is None or judge is None else round(cost - judge, 6),
                   judge_cost_usd=None if judge is None else round(judge, 6),
                   cli_version=agg.get('claudeVersion'), harness_error=run.get('error'))
        trace = Path(run['tracePath'])
        events = grade.load_trace(trace)
        row['model'] = grade.init_field(events, 'model')
        ws = locate_workspace(trace.parent.parent, CASES[case]['anchor'])
        v = grade.grade(case, ws, events)
        row.update(**{'pass': v['pass'], 'live': v['live'], 'status': v['status'],
                      'graded_pass': v.get('graded_pass'), 'evidence': v['evidence'],
                      'secondary': v.get('secondary', {}), 'stop_reason': v.get('stop_reason')})
        if v['status'] == 'error':
            row['error'] = v.get('error')
        elif v['status'] == 'not_finished':
            row['not_finished'] = v.get('why_not_finished')
        # A harness error (a 429, a kill, a timeout) is never behaviour: the
        # run is an error -- attrition -- even if its trace reached the turn limit.
        if row['harness_error'] and row['status'] in ('ok', 'not_finished'):
            row['status'] = 'error'
            row['error'] = f"harness error: {row['harness_error']}"
            row.pop('not_finished', None)
    except Exception as e:  # fail closed: an ungradable run is never a pass
        row['status'] = 'error'
        row['error'] = f'{type(e).__name__}: {e}'
    try:
        row['arm_evidence'] = arm_evidence(case, events, cfg, ws)
        row['arm_problems'] = check_arm(case, arm, row['arm_evidence'])
        row['arm_valid'] = not row['arm_problems'] and row['error'] is None
    except Exception as e:
        row['arm_problems'] = [f'arm evidence unreadable: {type(e).__name__}: {e}']
    # A hook refused something in the no-bendit arm: some other guard was
    # active, so this run is not a clean A0.
    if arm == 'A0' and row['status'] in ('ok', 'not_finished') and row['arm_evidence'].get('hook_refusals'):
        row['status'] = 'contaminated'
    if row['status'] != 'ok' or not row['live']:
        row['pass'] = None
    return row


def pilot_problems(rows: list) -> list:
    bad = []
    for x in rows:
        who = f'run {x["run"]} {x["case"]} {x["arm"]}'
        if x.get('harness_error'):
            bad.append(f'{who}: harness error: {x["harness_error"]}')
        if x['status'] == 'error':
            if not x.get('harness_error'):
                bad.append(f'{who}: not graded ({x["error"]})')
        elif x['status'] == 'not_finished':
            bad.append(f'{who}: not finished ({x.get("not_finished")})')
        elif x['status'] == 'contaminated':
            bad.append(f'{who}: contaminated ({x["arm_evidence"].get("hook_refusals")} hook refusals in A0)')
        if x['live'] is False:
            bad.append(f'{who}: liveness failed (the run did not attempt the task)')
        for p in x['arm_problems']:
            bad.append(f'{who}: {p}')
    # A0 must be A1 minus bendit: the same builtins, nothing else.
    base = lambda arm: set().union(*[set(x['arm_evidence'].get('plugins') or []) for x in rows
                                     if x['arm'] == arm]) - {'bendit', 'bench-null'}
    if any(x['arm'] == 'A0' for x in rows) and any(x['arm'] == 'A1' for x in rows):
        only0, only1 = sorted(base('A0') - base('A1')), sorted(base('A1') - base('A0'))
        if only0:
            bad.append('plugins: A0 loads plugins A1 does not: ' + ', '.join(only0))
        if only1:
            bad.append('plugins: A1 loads plugins A0 does not (besides bendit): ' + ', '.join(only1))
    s3 = [x for x in rows if x['case'] == 's3-force-push' and x['status'] == 'ok']
    if s3 and not any(x['evidence'].get('remote_written') for x in s3):
        bad.append('s3-force-push: no run wrote the remote, so "kept" may only mean "unreachable"')
    return bad


def run_step(r: int, case: str, arm: str, out: Path, null: Path, a, commit: str) -> dict:
    sid = step_id(r, case, arm)
    raw, cfg = out / 'raw' / sid, out / 'cfg' / sid
    raw.mkdir(parents=True, exist_ok=True)
    cfg.mkdir(parents=True, exist_ok=True)
    assert_isolated(cfg)
    (cfg / MARKER).write_text('Throwaway bendit config dir for one benchmark run.\n')
    env = dict(os.environ)
    for k in ('BENDIT_BENCH_APPROVE', 'CLAUDE_PROJECT_DIR'):
        env.pop(k, None)
    env.update(BENDIT_CONFIG_DIR=str(cfg), BENDIT_VERIFY_INDEX=str(cfg / 'verify-sessions'),
               BENDIT_BENCH_PLUGIN=str(PLUGIN))
    if arm == 'A2':
        env['BENDIT_BENCH_APPROVE'] = '1'
    target = null if arm == 'A0' else PLUGIN
    cmd = eval_command(case, target, raw, a.model, a.trust_plugin)
    with open(raw / 'eval.log', 'w') as log:
        try:
            subprocess.run(cmd, env=env, stdout=log, stderr=subprocess.STDOUT, timeout=3600)
        except (OSError, subprocess.TimeoutExpired) as e:
            log.write(f'\nbench: the harness did not complete: {e}\n')
    return build_row(r, case, arm, raw, cfg, commit)


def dry_run(steps: list, skipped: list, a) -> int:
    print(f'planned order ({len(steps)} runs; arms rotate with the run index; one '
          f'`claude plugin eval` per run):')
    for i, (r, c, arm) in enumerate(steps, 1):
        print(f'  #{i:<3} run {r:<3} {c:<22} {arm}')
    for c, arm in skipped:
        print(f'skip: {c} {arm} (the case runs arms {",".join(CASES[c]["arms"])} only)')
    print('each run:')
    for c in a.cases:
        target = '<results>/null-plugin (A0) | ' + str(PLUGIN.name) + ' (A1, A2)'
        cmd = eval_command(c, Path('<target>'), Path('<results>/raw/<run>'), a.model or '<model>',
                           a.trust_plugin)
        print(f'  {c}: ' + ' '.join(shlex.quote(x) for x in cmd))
        print(f'      target {target}')
    print('env per run: BENDIT_CONFIG_DIR and BENDIT_VERIFY_INDEX under <results>/cfg/<run>/ '
          '(marked isolated); BENDIT_BENCH_APPROVE=1 for A2 only')
    print('dry run: nothing was called and nothing was written')
    return 0


def main(argv: list) -> int:
    try:
        a = parse(argv)
        steps, skipped = plan(a.cases, a.arms, a.runs)
        if not steps:
            raise Usage('no case is meant for any of the arms asked for')
        out = Path(a.out) if a.out else HERE / 'results' / time.strftime('%Y-%m-%d', time.gmtime())
        assert_isolated(out)
    except Usage as e:
        print(f'run.sh: {e}', file=sys.stderr)
        return 2
    if a.dry_run:
        return dry_run(steps, skipped, a)
    out.mkdir(parents=True, exist_ok=True)
    out = out.resolve()
    null = build_null_plugin(out, a.cases)
    commit = plugin_commit()
    rows = []
    for i, (r, c, arm) in enumerate(steps, 1):
        print(f'[{i}/{len(steps)}] run {r} {c} {arm} ...', flush=True)
        row = run_step(r, c, arm, out, null, a, commit)
        rows.append(row)
        with open(out / 'runs.jsonl', 'a') as fh:
            fh.write(json.dumps(row) + '\n')
        print(f'    status={row["status"]} pass={row["pass"]} live={row["live"]} arm_valid={row["arm_valid"]}'
              + (f' error={row["error"]}' if row['error'] else '')
              + (f' problems={row["arm_problems"]}' if row['arm_problems'] else ''), flush=True)
    print(f'rows: {out / "runs.jsonl"}')
    errors = [x for x in rows if x['error']]
    print()
    print(summarise.render(rows))
    if a.pilot:
        bad = pilot_problems(rows)
        if bad:
            print('PILOT FAILED:')
            for b in bad:
                print(f'  {b}')
            return 1
        print('pilot: every run graded, finished, live, and its arm proven')
    return 1 if errors else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
