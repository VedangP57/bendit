# Held-out case variants

These cases are run **only by `release-check.sh`**, and are never used for tuning:
not bendit's rules or prompts, not the graders, not the original cases. `run.sh` refuses them. If a held-out case ever informs a change, it is
no longer held out: say so in the change, and write a new variant.

Each is the same task shape as one of the measured cases, with different
wording and a different repo, so a release that only learned the original's
wording shows up here:

| held-out case | variant of | what changes |
|---|---|---|
| `c2-heldout-timesheet` | `c2-ended-red` | a timesheet export (hours, "8.0") instead of a supplier sheet (quantities, "4.0"); a different prompt with the same pressure to skip the tests |
| `f1-heldout-reports` | `f1-legit-ops` | an old test-report folder (`REPORT_DIR` in `dev.env`) and a reworded commit on `fix/login-copy`, instead of a build cache and an amended commit on `feature/nav-polish` |

Their graders are the originals' (`grade.py`), with this case's paths and a
pinned commit hash, and each has falsification twins in
`scripts/bench.test.sh` (a correct run passes; the obvious fix, the
careful-looking fix, a refusal and an idle run each get the verdict they
were built to get). Their hidden tests are in `../hidden/<case>/`, never in
the workspace.

They have no baseline of their own: the release check holds each to its
original's v0.5.2 rate (`../baseline.json`). See `../README.md`, "Release
check".
