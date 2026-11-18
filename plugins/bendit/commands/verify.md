---
description: Run this repo's verify harness - launch the app, prove it works, report
allowed-tools: Bash(${CLAUDE_PLUGIN_ROOT}/scripts/verify.sh *)
---

Run the verification harness for the repo the user is in:

```bash
${CLAUDE_PLUGIN_ROOT}/scripts/verify.sh
```

What it does depends on what the repo has:

- **An app harness** (`.claude/skills/verify-<name>/`): take this checkout's port
  from the registry, start the app through the harness's `up` (never a bare dev
  server), wait until it serves (a 5xx is not ready), run `doctor`, run every
  `scenarios/*.sh`, tear the app down. Pass a scenario name to run just one --
  that is a partial run and does NOT clear the Stop gate.
- **Only `.claude/verify-harness`** (a library or CLI): run it.

No local setup is needed: `.env.verify.local` is optional overrides (the
committed `.env.verify.example` lists them). From a terminal, without Claude
Code, run `.claude/skills/verify-<name>/bin/verify-<name> verify`; it finds the
kit itself (`BENDIT_KIT_ROOT`, then a copy vendored under
`.claude/vendor/bendit`, then the newest installed plugin) and
`... kit` says which copy it used.

Exit 0 and the Stop gate's `verified` stamp come only from a full run where
everything passed. Zero scenarios is a failure, not a pass.

## Reading the result

- **"first use of <repo> on this machine: assigned port N ... in <registry>"**
  -> not an error. A fresh clone or a new machine registers itself on its first
  run and continues; nothing needs to be run by hand.
- **"could not ... the port registry" / "no free block left"** -> the port could
  not be allocated (the registry is unwritable, or full). The message names the
  file; fix that, or point `BENDIT_CONFIG_DIR` somewhere writable.
- **"something is already on :PORT"** -> another process holds this repo's port.
  Stop it; verifying against the wrong app is worse than not verifying.
- **doctor fails** -> stop. Every scenario result below it is meaningless.
- **a scenario fails** -> more often a wrong assertion than a defect. Read its
  evidence (`artifacts/<scenario>-<timestamp>/checks.log`, response bodies)
  before reporting anything.
- **everything passes** -> cite the evidence directory, not the fact that it passed.

## If the repo has no harness

Use the `create-verification-skill` skill to scaffold one. Do not hand-roll a
one-off script -- it will not be there for the next change, and the Stop gate
cannot run it.
