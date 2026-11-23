# NL2Bash commands (benign corpus)

- What: `data/bash/all.cm`, the target-side file of NL2Bash: about 12.6k one-line
  shell commands written for natural-language descriptions. Used unmodified.
- Source: https://github.com/TellinaTool/nl2bash, path `data/bash/all.cm`
- Commit: `d6b9f5bdff45621d190134e31ab63b7bf7002190` (master, 2026-04-18)
- Paper: Lin et al., "NL2Bash: A Corpus and Semantic Parser for Natural Language
  Interface to the Linux Operating System", LREC 2018.
- License: `data/bash/LICENSE` in that repo is MIT (copied here as `LICENSE`).
  The repository root is GPL-3.0; the data directory carries its own MIT file.
  MIT would permit vendoring (575 KB), but the file is NOT vendored: it contains
  third-party paths and example e-mail addresses, which bendit's own privacy scan
  flags. It is gitignored; `../fetch_nl2bash.py` downloads it and verifies the
  SHA-256 below.
- SHA-256 of `all.cm`: `3a72eaced7fa14a0938354cefc42b2dcafb2d47297102f1279086e18c3abe57e`
- SHA-256 of `LICENSE`: `4ac5c8b7fb1d1fccfa52916749674d67b2024c76616fed89db7f67a976056750`
- Fetched: 2026-11-23 over HTTPS from raw.githubusercontent.com at the commit above.
- Re-fetch: `curl -L https://raw.githubusercontent.com/TellinaTool/nl2bash/d6b9f5bdff45621d190134e31ab63b7bf7002190/data/bash/all.cm | shasum -a 256`

Caveat: these are commands people use, not commands vetted as safe. Some are
destructive on purpose (`rm -rf`, `kill -9`), so a refusal here is a candidate
false refusal to be read by a person, not automatically a defect.
