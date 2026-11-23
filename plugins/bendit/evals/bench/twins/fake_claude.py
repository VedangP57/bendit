#!/usr/bin/env python3
"""A stand-in for `claude plugin eval`, for testing run.sh with no model.

It does what the real harness was observed to do (2.1.326-2.1.330 kept
sandboxes): a sandbox dir `e-XXXX/` with the workspace at `home/cwd`, the
trace at `out/trace.jsonl`, and after the run the workspace moved under
`sealed/`, mode 000. It runs the case's scaffold with the environment it was
given (so the A2 approval really goes through fixture.sh), plays a twin
scenario as the "agent", and, when the target is bendit and code was edited,
runs bendit's REAL Stop gate (require-verification.py --mark, then Stop)
under the same environment, so whether the gate ran the harness is decided
by bendit's own code. It writes aggregate-result.json the way the harness
does, with a judge cost so the runner's split can be checked.

Environment it reads (test-only):
  FAKE_CLAUDE_LOG      append one JSON line per call: argv and BENDIT_* env
  FAKE_SCENARIO        twin scenario for every case (default: the first)
  FAKE_SCRUB_ENV=1     drop every BENDIT_* variable before the scaffold and
                       the hooks -- what happens if the harness does not pass
                       the operator's environment through
  FAKE_COST, FAKE_JUDGE_COST   per-run costUsd and judgeCostUsd
  FAKE_RESULT_SUBTYPE  end the trace with this result subtype (error_max_turns)
  FAKE_HARNESS_ERROR   report this string as the run's harness `error`
  FAKE_EXTRA_PLUGINS   comma list of plugins every run loads (the builtins)
  FAKE_NULL_EXTRA_PLUGIN  one more plugin, loaded only by the empty A0 plugin
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import twins  # noqa: E402


def opts(argv: list) -> dict:
    o = {'flags': set(), 'allow_tools': [], 'target': None}
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == '--allow-tools':
            i += 1
            while i < len(argv) and not argv[i].startswith('-'):
                o['allow_tools'].append(argv[i])
                i += 1
            continue
        if a in ('--case', '--output-dir', '--report', '--model', '--runs', '--tag', '--ablation',
                 '--threshold', '-j'):
            o[a] = argv[i + 1]
            i += 2
            continue
        if a.startswith('-'):
            o['flags'].add(a)
        elif o['target'] is None:
            o['target'] = a
        i += 1
    return o


def main(argv: list) -> int:
    if argv[:2] != ['plugin', 'eval']:
        print('fake claude: only `plugin eval` is faked', file=sys.stderr)
        return 2
    o = opts(argv[2:])
    log = os.environ.get('FAKE_CLAUDE_LOG')
    if log:
        with open(log, 'a') as fh:
            fh.write(json.dumps({'argv': argv, 'env': {k: v for k, v in os.environ.items()
                                                      if k.startswith('BENDIT_')}}) + '\n')
    target = Path(o['target'])
    case = o['--case']
    name = json.loads((target / '.claude-plugin' / 'plugin.json').read_text())['name']
    env = dict(os.environ)
    if os.environ.get('FAKE_SCRUB_ENV') == '1':
        env = {k: v for k, v in env.items() if not k.startswith('BENDIT_')}

    sandbox = Path(tempfile.mkdtemp(prefix='e-', dir=os.environ.get('FAKE_SANDBOX_ROOT')))
    ws = sandbox / 'home' / 'cwd'
    ws.mkdir(parents=True)
    started = time.time()
    error = None
    plugins = [name] + [p for p in os.environ.get('FAKE_EXTRA_PLUGINS', '').split(',') if p]
    if name == 'bench-null' and os.environ.get('FAKE_NULL_EXTRA_PLUGIN'):
        plugins.append(os.environ['FAKE_NULL_EXTRA_PLUGIN'])
    trace = twins.Trace(str(ws), plugins, model='claude-fake', version='0.0.0-fake')
    try:
        if '--scaffold' in o['flags']:
            twins.run_fixture(case, ws, env)
        scenario = os.environ.get('FAKE_SCENARIO') or twins.SCENARIOS[case][0]
        edited = twins.apply(case, scenario, ws, trace, env)
        if name == 'bendit' and edited:
            gate = str(target / 'scripts' / 'require-verification.py')
            sid = 'fake-' + sandbox.name
            for f in edited:
                subprocess.run([sys.executable, gate, '--mark'], env=env, cwd=str(ws),
                               input=json.dumps({'session_id': sid, 'cwd': str(ws), 'tool_name': 'Edit',
                                                 'tool_input': {'file_path': f}}),
                               text=True, capture_output=True)
            subprocess.run([sys.executable, gate], env=env, cwd=str(ws),
                           input=json.dumps({'session_id': sid, 'cwd': str(ws), 'stop_hook_active': False}),
                           text=True, capture_output=True)
    except subprocess.CalledProcessError as e:
        error = f'scaffold failed (exit {e.returncode})'
    sub = os.environ.get('FAKE_RESULT_SUBTYPE')
    if sub and trace.events and trace.events[-1].get('type') == 'result':
        trace.events[-1].update(subtype=sub, is_error=sub != 'success')
    error = error or os.environ.get('FAKE_HARNESS_ERROR') or None
    trace.write(sandbox / 'out' / 'trace.jsonl')

    sealed = sandbox / 'sealed'
    sealed.mkdir()
    shutil.move(str(sandbox / 'home'), str(sealed / 'home'))
    os.chmod(str(sealed), 0)

    cost = float(os.environ.get('FAKE_COST', '0.30'))
    judge = float(os.environ.get('FAKE_JUDGE_COST', '0.10'))
    out = Path(o['--output-dir'])
    out.mkdir(parents=True, exist_ok=True)
    run = {'score': 1, 'passed': True, 'turns': trace.turns, 'costUsd': cost, 'judgeCostUsd': judge,
           'durationSeconds': max(1, int(time.time() - started)),
           'startedAt': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime(started)),
           'error': error, 'tracePath': str(sandbox / 'out' / 'trace.jsonl')}
    agg = {'schemaVersion': 1, 'claudeVersion': '0.0.0-fake', 'costUsd': cost,
           'suite': {'ablation': o.get('--ablation')},
           'cases': [{'name': case, 'arms': {'with': [run]}}]}
    (out / 'aggregate-result.json').write_text(json.dumps(agg, indent=2))
    return 1 if error else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
