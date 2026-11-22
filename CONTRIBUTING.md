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

## Releasing

1. Bump the version in all five places, to the same value (the Homebrew template
   has no version of its own; step 6 passes it in, and the suite renders it and
   compares it with `BENDIT_VERSION`): `BENDIT_VERSION` in
   `install.sh`, `version` in `plugins/bendit/.claude-plugin/plugin.json` and
   `plugins/bendit-web/.claude-plugin/plugin.json`, `packages/npm/package.json`
   and `packages/pypi/pyproject.toml` (`scripts/packages.test.sh` fails if they
   differ).
2. Run `packages/sync.sh` (copies `install.sh` into both wrappers) and commit.
3. `bash .github/workflows/ci.sh` must end `CI passed: ...`.
4. Tag `vX.Y.Z`, then push main and the tag together:
   `git push --atomic origin main vX.Y.Z`. The installer on main fetches that
   tag, so neither may land without the other.
5. Publish, **only after the repo is public**, by the owner, from their own
   accounts: `npm publish` in `packages/npm`. For PyPI, in `packages/pypi`:
   `python3 -m pip install build twine`, then `rm -rf dist`,
   `python3 -m build`, check the wheel holds the installer
   (`unzip -l dist/*.whl | grep bendit/install.sh`), and `twine upload dist/*`.
6. Homebrew, after the tag is pushed (the formula needs the tag tarball). The
   template is `packages/homebrew/bendit.rb.tmpl`; it takes the version and the
   tarball's sha256, never a copy of `install.sh`:
   `curl -fsSL https://github.com/VedangP57/bendit/archive/refs/tags/vX.Y.Z.tar.gz | shasum -a 256`,
   then `bash packages/homebrew/render.sh X.Y.Z <sha256> > bendit.rb`, push it
   to `VedangP57/homebrew-tap` as `Formula/bendit.rb`, and verify with
   `brew install vedangp57/tap/bendit && bendit --version`.

## Reporting bugs and ideas

Use the issue templates. For anything security-related, see
[SECURITY.md](SECURITY.md) and do not open a public issue.
