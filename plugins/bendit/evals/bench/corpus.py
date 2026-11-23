#!/usr/bin/env python3
"""Replay a public command corpus through bendit's Bash guards. No model calls.

    corpus.py benign|redteam [--file F] [--workers N] [--out results.json]

  benign   NL2Bash (corpus/nl2bash/all.cm): ordinary one-liners. A refusal is
           a candidate FALSE REFUSAL; the person reads the list, the script
           does not decide which are false.
  redteam  RedCode-Exec bash cases (corpus/redcode/redcode-bash.jsonl): risky
           scripts from a published benchmark. A refusal is a BLOCK. Not
           every scenario in it is in bendit's policy; the per-index table
           (with the dataset's own summary of each scenario) shows which.

Each command is sent as a real PreToolUse Bash payload to the real guard
scripts, in a throwaway project (hookenv.Sandbox) with SHELL=zsh and the
ls-guard feature on:
  block-dangerous-bash, block-zsh-wordsplit, block-ls-parsing
A command is refused when any guard exits 2 (Claude Code's block code). Any
other non-zero exit is NOT a refusal -- Claude Code would run the command --
so it is counted separately as an error, never as a block.
Wilson score interval, z = 1.96.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import sys
from collections import Counter, defaultdict
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
from hookenv import Sandbox, wilson  # noqa: E402

GUARDS = [("block-dangerous-bash", "block-dangerous-bash.py"),
          ("block-zsh-wordsplit", "block-zsh-wordsplit.py"),
          ("block-ls-parsing", "block-ls-parsing.py")]
DEFAULTS = {"benign": HERE / "corpus" / "nl2bash" / "all.cm",
            "redteam": HERE / "corpus" / "redcode" / "redcode-bash.jsonl"}


def load(path: Path):
    """-> (cases, raw_count). A case is {id, command, index?, summary?}; duplicates collapse."""
    text = path.read_text(encoding="utf-8")
    items = []
    if path.suffix == ".jsonl":
        for ln in text.splitlines():
            if ln.strip():
                d = json.loads(ln)
                items.append({"id": d["id"], "command": d["command"], "index": d.get("index"),
                              "summary": d.get("summary", "")})
    else:
        for n, ln in enumerate(text.splitlines(), 1):
            if ln.strip():
                items.append({"id": f"line{n}", "command": ln, "index": None, "summary": ""})
    seen, cases = set(), []
    for it in items:
        if it["command"] not in seen:
            seen.add(it["command"])
            cases.append(it)
    return cases, len(items)


def judge(sb: Sandbox, case) -> dict:
    payload = sb.bash(case["command"])
    refused_by, errors, why = [], [], ""
    for name, script in GUARDS:
        rc, err, _ = sb.run(script, [], payload)
        if rc == 2:
            refused_by.append(name)
            why = why or err.strip().splitlines()[0][:200] if err.strip() else why
        elif rc != 0:
            errors.append(f"{name}:rc={rc}")
    return {**case, "refused_by": refused_by, "errors": errors, "why": why}


def main() -> int:
    ap = argparse.ArgumentParser(usage="corpus.py benign|redteam [--file F] [--workers N] [--out FILE]",
                                 description=__doc__.split("\n")[0])
    ap.add_argument("mode", choices=["benign", "redteam"])
    ap.add_argument("--file")
    ap.add_argument("--workers", type=int, default=8)
    ap.add_argument("--out")
    ap.add_argument("--show-commands", action="store_true",
                    help="print and store command text; off by default (public datasets hold third-party "
                         "paths and addresses that must not land in published results; ids point at the pinned file)")
    a = ap.parse_args()
    path = Path(a.file) if a.file else DEFAULTS[a.mode]
    if not path.is_file():
        print(f"corpus.py: {path} is missing; run corpus/fetch_nl2bash.py (see corpus/nl2bash/SOURCE.md)", file=sys.stderr)
        return 2
    cases, raw = load(path)
    sha = hashlib.sha256(path.read_bytes()).hexdigest()
    sb = Sandbox()
    try:
        with ThreadPoolExecutor(a.workers) as ex:
            res = list(ex.map(lambda c: judge(sb, c), cases))
    finally:
        sb.close()
    n = len(res)
    hit = [r for r in res if r["refused_by"]]
    k = len(hit)
    lo, hi = wilson(k, n)
    word = "refused" if a.mode == "benign" else "blocked"
    f = lambda x: f"{x * 100:.1f}%"  # noqa: E731
    print(f"{a.mode}: n={n} {word}={k} ({f(k / n if n else 0)}) wilson95=[{f(lo)}, {f(hi)}]"
          f"  errors={sum(1 for r in res if r['errors'])}")
    by_guard = Counter(g for r in hit for g in r["refused_by"])
    print("by guard (a command can be refused by more than one): " +
          (", ".join(f"{g} {c}" for g, c in sorted(by_guard.items())) or "none"))
    by_index = {}
    if any(r["index"] is not None for r in res):
        agg = defaultdict(lambda: [0, 0, ""])
        for r in res:
            e = agg[r["index"]]
            e[0] += 1
            e[1] += bool(r["refused_by"])
            e[2] = e[2] or r["summary"]
        print("per scenario index (summary is the dataset's own, first case):")
        for i in sorted(agg):
            tot, b, s = agg[i]
            by_index[i] = {"n": tot, "blocked": b, "summary": s}
            print(f"  index {i:>2}: {b:>2}/{tot}  {s[:90]}")
    if a.mode == "benign":
        for r in hit:
            shown = f" {r['command'][:120]!r}" if a.show_commands else ""
            print(f"  REFUSED {r['id']}{shown} by {','.join(r['refused_by'])}: {r['why'][:70]}")
    out = {"mode": a.mode, "source_file": str(path.name), "sha256": sha, "raw_lines": raw, "n": n,
           "refused": k, "rate": k / n if n else 0.0, "wilson95": [lo, hi], "by_guard": dict(by_guard),
           "by_index": by_index, "errors": [{"id": r["id"], "errors": r["errors"]} for r in res if r["errors"]],
           "refusals": [{"id": r["id"], "index": r["index"], "guards": r["refused_by"], "why": r["why"],
                         **({"command": r["command"][:400]} if a.show_commands else {})} for r in hit],
           "misses": [{"id": r["id"], "index": r["index"],
                       **({"command": r["command"][:400]} if a.show_commands else {})}
                      for r in res if not r["refused_by"]] if a.mode == "redteam" else []}
    if a.out:
        Path(a.out).write_text(json.dumps(out, indent=1) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
