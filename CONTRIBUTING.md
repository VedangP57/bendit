# Contributing to Bendit

Thanks for helping. Bendit's whole pitch is *enforcement with evidence*, so
contributions are held to the same rule the kit holds agents to: show that a
change works, and say how far you checked it.

## Before you open a pull request

1. **Run the full CI locally.** It is the same command GitHub runs:

   ```bash
   bash .github/workflows/ci.sh shell imports privacy validate
   ```

   It needs `python3` (3.9 or newer), `bash`, `git`, `curl` and the Claude
   Code CLI on your PATH. Every stage must pass; a stage that ran nothing is a
   failure, not a skip.

2. **Behaviour changes come with a test that failed first.** Add the case to
   the relevant `plugins/bendit/scripts/*.test.sh`, watch it fail, then fix
   the code. Suites use `scripts/expect.sh` snapshots: if output changes on
   purpose, re-record with `bash <suite>.test.sh --accept`, read the diff,
   and say in the PR why it changed.

3. **Guards fail closed.** A guard that crashes must refuse, never allow. Keep
   false positives low as well: quoted text such as
   `git commit -m "explain rm -rf"` must stay allowed.

4. **No personal data.** `scripts/privacy-scan.py` runs in CI and fails on
   home paths and email addresses (example.com, .test and .invalid are fine).

## Adding a new guard

Use the kit's own tool: `/bendit:new-guard <name>` scaffolds a guard and its
test suite from `plugins/bendit/templates/guard/`. The method behind it (the
ladder: delete, then structure, then deterministic enforcement, and only then
prose) is in [docs/ladder.md](docs/ladder.md).

## Claims need evidence

If a change says a rule *works*, include how you measured it: an eval case
under `plugins/bendit/evals/` and its result, or a reproduction. The method,
and the traps that make eval numbers lie, are in
[plugins/bendit/evals/README.md](plugins/bendit/evals/README.md). Every quoted
number must be traceable to `evals/results/INDEX.md`.

When you report what you verified, use the evidence rungs:
1 said so · 2 pointed at the line · 3 showed the bad case cannot happen ·
4 ran it and read the output · 5 reproduced it in the running app.

## Reporting bugs and ideas

Use the issue templates. For anything security-related, see
[SECURITY.md](SECURITY.md) and do not open a public issue.
