# Changelog

All notable changes. Dates are UTC.

## [Unreleased]

### Added
- Plugin icon (`plugins/bendit/.claude-plugin/icon.png`), generated from
  `docs/icon/make_icon.py` with no dependencies.
- `CONTRIBUTING.md`, `SECURITY.md`, issue templates, and this changelog.
- The Bash guard refuses `git clean -f` in every spelling; `-n`/`--dry-run`
  stays allowed. Found by the unprompted-deletion eval.
- `verify` explains an app that never answers: its process group with each
  process's state, and probes of `127.0.0.1` and `localhost`.

### Changed
- CI: `actions/checkout` v7.0.1, `actions/setup-node` v7.1.0 (both on
  Node 24), Node 26 LTS, Claude Code CLI 2.1.328.
- `verify`'s readiness wait is a deadline in seconds. It counted attempts, so
  "within 90s" could take up to 270s.
- `verify` starts the app in its own process group with `setpgrp`, not bash
  job control.

### Fixed
- `verify-readiness` test fixtures hung on GitHub's macOS runners: Python's
  `HTTPServer` does a reverse-DNS lookup before it listens. Fixtures now use
  `socketserver.TCPServer`.
- bash's "Terminated: 15" job notice no longer leaks from `verify` teardown.

## [0.1.0] - 2026-11-18

First version: fail-closed guard hooks, the Stop gate, the verify-harness
generator, `/adopt`, `/new-guard`, `/ship`, `/review-diff`, the eval kit, and
the first measured result (Bash guard 12/12 vs 0/12 in two cases).
