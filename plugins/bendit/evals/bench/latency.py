#!/usr/bin/env python3
"""Per-hook latency micro-benchmark. No model calls.

    latency.py [--n 200] [--out results.json]

Each hook script from hooks.json runs on representative allowed and refused
payloads, as a real subprocess (`python3 <script> <args>`, payload on stdin),
inside a throwaway project (hookenv.Sandbox). Warm-up calls first, then N timed
calls per (hook, payload); the order of all (hook, payload) pairs is shuffled
across repetitions with a fixed seed so drift lands evenly. The baseline is
`python3 -c pass`: what merely starting the interpreter costs.

The number is wall time of the subprocess as the harness would see it: spawn,
interpreter start, the hook, exit. Hooks for one event run in parallel in
Claude Code, so a tool call pays roughly the slowest hook per event, not the sum.
"""
from __future__ import annotations

import argparse
import json
import platform
import random
import subprocess
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from hookenv import Sandbox  # noqa: E402

LONG_CMD = "cat <<'EOF' > notes.txt\n" + ("line of heredoc text that is not a command\n" * 45) + "EOF\ncat notes.txt | wc -l"


def cases(sb: Sandbox):
    """(hook label, script, args, kind, payload bytes)"""
    bash, post = sb.bash, lambda c: sb.bash(c, "PostToolUse")
    edit = {"file_path": str(sb.project / "a.txt"), "old_string": "a", "new_string": "b"}
    big = {"file_path": str(sb.project / "a.txt"), "old_string": "a", "new_string": "x" * 200_000}
    write = {"file_path": str(sb.project / "w.txt"), "content": "hello\n"}
    ZSH = "v='a b c'; for x in $v; do echo $x; done"
    LS = "for f in $(ls); do echo $f; done"
    yield "block-dangerous-bash", "block-dangerous-bash.py", [], "allow", bash("npm test")
    yield "block-dangerous-bash", "block-dangerous-bash.py", [], "allow-long", bash(LONG_CMD)
    yield "block-dangerous-bash", "block-dangerous-bash.py", [], "refuse", bash("rm -rf ./build")
    yield "block-zsh-wordsplit", "block-zsh-wordsplit.py", [], "allow", bash("npm test")
    yield "block-zsh-wordsplit", "block-zsh-wordsplit.py", [], "refuse", bash(ZSH)
    yield "block-ls-parsing", "block-ls-parsing.py", [], "allow", bash("npm test")
    yield "block-ls-parsing", "block-ls-parsing.py", [], "refuse", bash(LS)
    yield "require-verification --pre", "require-verification.py", ["--pre"], "allow", bash("npm test")
    yield "require-verification --mark", "require-verification.py", ["--mark"], "allow", post("npm test")
    yield "warn-suppressed-stderr", "warn-suppressed-stderr.py", [], "allow", post("npm test")
    yield "path-contracts (Edit)", "path-contracts.py", [], "allow", sb.payload("Edit", edit)
    yield "path-contracts (Edit 200 KB)", "path-contracts.py", [], "allow-large", sb.payload("Edit", big)
    yield "path-contracts (Write)", "path-contracts.py", [], "allow", sb.payload("Write", write)
    yield "post-edit-review --pre", "post-edit-review.py", ["--pre"], "allow", sb.payload("Edit", edit)
    yield "post-edit-review (Post)", "post-edit-review.py", [], "allow", sb.payload("Edit", edit, "PostToolUse", {"success": True})
    yield "block-primary-checkout", "block-primary-checkout.py", [], "allow", sb.payload("Edit", edit)
    yield "require-verification (Stop, no edits)", "require-verification.py", [], "allow", sb.payload("Stop", {}, "Stop")
    yield "selfcheck --hook (SessionStart)", "selfcheck.py", ["--hook"], "allow", sb.payload("", {}, "SessionStart")
    yield "session-brief --hook (SessionStart)", "session-brief.py", ["--hook"], "allow", sb.payload("", {}, "SessionStart")


def pct(xs, q):
    xs = sorted(xs)
    i = (len(xs) - 1) * q
    lo = int(i)
    hi = min(lo + 1, len(xs) - 1)
    return xs[lo] + (xs[hi] - xs[lo]) * (i - lo)


def machine() -> dict:
    m = {"platform": platform.platform(), "machine": platform.machine(),
         "python": sys.version.split()[0], "python3_on_path": None, "power": "unknown"}
    try:
        m["python3_on_path"] = subprocess.run(["python3", "-c", "import sys;print(sys.version.split()[0])"],
                                              capture_output=True, text=True).stdout.strip()
    except OSError:
        pass
    if sys.platform == "darwin":
        try:
            m["power"] = subprocess.run(["pmset", "-g", "batt"], capture_output=True, text=True).stdout.splitlines()[0]
            m["cpu"] = subprocess.run(["sysctl", "-n", "machdep.cpu.brand_string"], capture_output=True, text=True).stdout.strip()
        except (OSError, IndexError):
            pass
    return m


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--n", type=int, default=200)
    ap.add_argument("--warmup", type=int, default=10)
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--out")
    a = ap.parse_args()
    sb = Sandbox()
    try:
        cs = list(cases(sb))
        warm = min(a.warmup, a.n)
        for label, script, args, kind, pl in cs:
            for _ in range(warm):
                sb.run(script, args, pl)
        for _ in range(warm):
            subprocess.run(["python3", "-c", "pass"], env=sb.env)
        slots = [i for i in range(len(cs)) for _ in range(a.n)] + [-1] * a.n
        random.Random(a.seed).shuffle(slots)
        times = {i: [] for i in range(-1, len(cs))}
        rcs = {i: set() for i in range(len(cs))}
        for i in slots:
            if i == -1:
                t0 = time.perf_counter()
                subprocess.run(["python3", "-c", "pass"], env=sb.env)
                times[-1].append(time.perf_counter() - t0)
                continue
            label, script, args, kind, pl = cs[i]
            rc, _, dt = sb.run(script, args, pl)
            rcs[i].add(rc)
            times[i].append(dt)
    finally:
        sb.close()
    rows = []
    for i, (label, script, args, kind, pl) in enumerate(cs):
        rc = sorted(rcs[i])
        rows.append({"hook": label, "kind": kind, "rc": rc[0] if len(rc) == 1 else rc, "n": len(times[i]),
                     "p50_ms": round(pct(times[i], .5) * 1e3, 1), "p95_ms": round(pct(times[i], .95) * 1e3, 1),
                     "max_ms": round(max(times[i]) * 1e3, 1)})
    base = {"hook": "python3 -c pass", "kind": "baseline", "rc": 0, "n": len(times[-1]),
            "p50_ms": round(pct(times[-1], .5) * 1e3, 1), "p95_ms": round(pct(times[-1], .95) * 1e3, 1),
            "max_ms": round(max(times[-1]) * 1e3, 1)}
    print(f"{'hook':<40} {'payload':<12} {'rc':>3} {'n':>4} {'p50 ms':>8} {'p95 ms':>8} {'max ms':>8}")
    for r in rows + [base]:
        print(f"{r['hook']:<40} {r['kind']:<12} {str(r['rc']):>3} {r['n']:>4} {r['p50_ms']:>8} {r['p95_ms']:>8} {r['max_ms']:>8}")
    out = {"n": a.n, "warmup": warm, "seed": a.seed, "machine": machine(), "baseline": base, "rows": rows}
    if a.out:
        Path(a.out).write_text(json.dumps(out, indent=1) + "\n")
    # A row whose exit code is not the kind it claims is a broken benchmark, not a result.
    bad = [r for r in rows if r["rc"] != (2 if r["kind"] == "refuse" else 0)]
    for r in bad:
        print(f"UNEXPECTED rc for {r['hook']} ({r['kind']}): {r['rc']}", file=sys.stderr)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
