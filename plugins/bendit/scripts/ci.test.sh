#!/usr/bin/env bash
# .github/workflows/ci.sh: the validate stage runs `claude plugin validate` and
# the skill budget over EVERY plugin under plugins/, not one hardcoded path.
#
# Run on a fixture tree (a copy of ci.sh beside two plugins) with `claude`
# stubbed on PATH to log its calls, so the suite needs neither the CLI nor the
# network, and cannot recurse into the real ci.sh.
set -uo pipefail
SD="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SD/../../.." && pwd)"
T=$(mktemp -d); T=$(cd "$T" && pwd -P); pass=0; fail=0
trap 'rm -rf "$T"' EXIT
chk() { if [ "$2" = "$3" ]; then printf '  ok    %s\n' "$1"; pass=$((pass+1));
        else printf '  FAIL  %s (got [%s], wanted [%s])\n' "$1" "$2" "$3"; fail=$((fail+1)); fi; }
has() { case "$3" in *"$2"*) chk "$1" y y;; *) chk "$1 (missing '$2' in: $3)" n y;; esac; }

# mkplugin <tree> <name> <skills:0|1> -- a plugin; with skills it gets one skill and one command
mkplugin() {
  local d="$1/plugins/$2"; mkdir -p "$d/.claude-plugin" "$d/skills"
  printf '{"name":"%s","version":"0.0.1","description":"x"}\n' "$2" > "$d/.claude-plugin/plugin.json"
  if [ "$3" = 1 ]; then
    mkdir -p "$d/skills/s" "$d/commands"
    printf -- '---\nname: s\ndescription: A short skill description.\n---\nbody\n' > "$d/skills/s/SKILL.md"
    printf -- '---\ndescription: A short command.\n---\nbody\n' > "$d/commands/c.md"
  else
    : > "$d/skills/.gitkeep"
  fi
}
# fixture <dir> -- ci.sh and skill-budget.py in place, two plugins, a stub claude
fixture() {
  mkdir -p "$1/.github/workflows" "$1/bin" "$1/plugins/bendit/scripts"
  cp "$ROOT/.github/workflows/ci.sh" "$1/.github/workflows/ci.sh"
  cp "$SD/skill-budget.py" "$1/plugins/bendit/scripts/skill-budget.py"
  mkplugin "$1" bendit 1
  mkplugin "$1" addon 0
  # The stub logs each call and answers as a passing validate; a plugin whose
  # path contains FAILME fails.
  cat > "$1/bin/claude" <<'STUB'
#!/bin/sh
echo "$*" >> "$STUB_LOG"
case "$*" in *FAILME*) echo "boom"; exit 1 ;; esac
echo "Validation passed"
STUB
  chmod +x "$1/bin/claude"
}
ci() {  # ci <fixture> [stages...] -- leaves CI_RC, CI_OUT, and the stub's log in $1/log
  local f="$1"; shift; : > "$f/log"
  CI_OUT="$(cd "$f" && STUB_LOG="$f/log" PATH="$f/bin:$PATH" bash .github/workflows/ci.sh "$@" 2>&1)"; CI_RC=$?
}

echo "validate runs once per plugin"
F="$T/two"; fixture "$F"; ci "$F" validate
chk "exit 0" "$CI_RC" 0
chk "claude plugin validate was invoked twice" "$(grep -c '^plugin validate' "$F/log")" 2
has "  ...for bendit" "plugin validate ./plugins/bendit" "$(cat "$F/log")"
has "  ...and for the add-on" "plugin validate ./plugins/addon" "$(cat "$F/log")"
has "final line names the stage" "CI passed: validate" "$CI_OUT"

echo
echo "budget: measured where there is something to measure, skipped with a note where not"
has "the plugin with a skill was measured" "TOTAL of 1 skills + 1 commands" "$CI_OUT"
has "the empty add-on is skipped, said so" "budget: ./plugins/addon has no skills and no commands, skipped" "$CI_OUT"
chk "  ...and the skip is not a failure" "$CI_RC" 0

echo
echo "one plugin failing validate fails the stage, and the other still runs"
F="$T/fail"; fixture "$F"; mv "$F/plugins/addon" "$F/plugins/FAILME"
ci "$F" validate
chk "exit 1" "$CI_RC" 1
chk "both plugins were still validated" "$(grep -c '^plugin validate' "$F/log")" 2
has "CI FAILED names the stage" "CI FAILED: validate" "$CI_OUT"

echo
echo "nothing to validate is a failure, never a pass"
F="$T/none"; fixture "$F"; rm -rf "$F/plugins"/*
ci "$F" validate
chk "a tree with no plugin under plugins/: exit 1" "$CI_RC" 1
chk "claude was never called" "$(wc -c < "$F/log" | tr -d ' ')" 0

echo
echo "every plugin skipped by budget is a failure (nothing was measured)"
F="$T/allskip"; fixture "$F"; rm -rf "$F/plugins/bendit/skills/s" "$F/plugins/bendit/commands"
ci "$F" validate
chk "exit 1" "$CI_RC" 1
has "  ...saying nothing was measured" "NOTHING was measured" "$CI_OUT"

echo
echo "shell: suites run concurrently, and every one is still reported and counted"
# a and c can only both pass if they run AT THE SAME TIME: each writes its
# marker, then waits up to 3s for the other's. Run one after the other, the
# first times out and fails. b fails on purpose: a failure must not be lost.
# shellfix <fixture> -- the three suites in <fixture>'s scripts/
shellfix() {
  local f="$1" n mine theirs
  fixture "$f"
  for n in a:c c:a; do
    mine="${n%%:*}"; theirs="${n##*:}"
    printf '#!/usr/bin/env bash\necho "%s-OUT"\n: > "%s/%s.mark"\nfor i in $(seq 1 30); do [ -e "%s/%s.mark" ] && exit 0; sleep 0.1; done\necho "%s never saw %s"; exit 1\n' \
      "$mine" "$f" "$mine" "$f" "$theirs" "$mine" "$theirs" > "$f/plugins/bendit/scripts/$mine.test.sh"
  done
  printf '#!/usr/bin/env bash\necho "b-OUT"\nexit 1\n' > "$f/plugins/bendit/scripts/b.test.sh"
}
F="$T/shell"; shellfix "$F"
ci "$F" shell
chk "a failing suite fails the stage" "$CI_RC" 1
has "  ...named" "FAIL: ./plugins/bendit/scripts/b.test.sh exited non-zero" "$CI_OUT"
has "  ...and counted" "shell: 2/3 suites passed" "$CI_OUT"
case "$CI_OUT" in *"never saw"*) o=serial ;; *) o=concurrent ;; esac
chk "two suites waiting on each other both passed (they ran at once)" "$o" concurrent
chk "each suite's output is printed whole, in suite order" \
    "$(grep -E '^(--- bash|[abc]-OUT)' <<<"$CI_OUT" | sed 's|^--- bash ./plugins/bendit/scripts/||')" \
    "a.test.sh
a-OUT
b.test.sh
b-OUT
c.test.sh
c-OUT"
F="$T/shell1"; shellfix "$F"
BENDIT_CI_JOBS=1 ci "$F" shell
has "BENDIT_CI_JOBS=1 runs them one at a time (so the knob is real)" "a never saw c" "$CI_OUT"
chk "  ...and that fails the stage" "$CI_RC" 1

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$pass" -gt 0 ] && [ "$fail" -eq 0 ]
