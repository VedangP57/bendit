#!/usr/bin/env bash
# plugin-lint.py drives against fixture plugins and the real ones. Each case
# checks the exit code AND that the finding names the thing that is wrong, so a
# lint that exits 1 for the wrong reason does not pass.
set -uo pipefail
SD="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SD/../../.." && pwd)"
L="$SD/plugin-lint.py"
PY_GIVEN="${PY:-}"
PY="${PY:-python3}"
T=$(mktemp -d); T=$(cd "$T" && pwd -P); pass=0; fail=0
trap 'rm -rf "$T"' EXIT
chk() { if [ "$2" = "$3" ]; then printf '  ok    %s\n' "$1"; pass=$((pass+1));
        else printf '  FAIL  %s (got [%s], wanted [%s])\n' "$1" "$2" "$3"; fail=$((fail+1)); fi; }
has() { case "$3" in *"$2"*) chk "$1" y y;; *) chk "$1 (missing '$2' in: $3)" n y;; esac; }
lint() { OUT="$("$PY" "$L" "$1" 2>&1)"; RC=$?; }

# mk <name> -- a good plugin: one skill, one command, one hook script
mk() {
  local d="$T/$1"; mkdir -p "$d/skills/s" "$d/commands" "$d/hooks" "$d/scripts"
  printf -- '---\nname: s\ndescription: A short skill description.\n---\nbody\n' > "$d/skills/s/SKILL.md"
  printf -- '---\ndescription: A short command.\n---\nbody\n' > "$d/commands/c.md"
  printf '#!/bin/sh\nexit 0\n' > "$d/scripts/h.sh"; chmod +x "$d/scripts/h.sh"
  : > "$d/scripts/p.py"
  cat > "$d/hooks/hooks.json" <<'J'
{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"python3 \"${CLAUDE_PLUGIN_ROOT}/scripts/p.py\" --flag || echo '{\"msg\": \"no path here\"}'"}]},
{"hooks":[{"type":"command","command":"\"${CLAUDE_PLUGIN_ROOT}/scripts/h.sh\""}]}]}}
J
}
hooks() { printf '%s\n' "$2" > "$T/$1/hooks/hooks.json"; }

echo "a good plugin passes (interpreter-run script need not be executable)"
mk good; lint "$T/good"
chk "exit 0" "$RC" 0

echo "a hook script that does not exist"
mk nohook; rm "$T/nohook/scripts/p.py"; lint "$T/nohook"
chk "exit 1" "$RC" 1
has "  ...names the missing path" "scripts/p.py" "$OUT"

echo "a directly-invoked hook script that is not executable"
mk noexec; chmod -x "$T/noexec/scripts/h.sh"; lint "$T/noexec"
chk "exit 1" "$RC" 1
has "  ...says not executable" "not executable" "$OUT"

echo "a hook path that climbs out of the plugin"
mk climb; hooks climb '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"python3 \"${CLAUDE_PLUGIN_ROOT}/../x.py\""}]}]}}'
lint "$T/climb"
chk "exit 1" "$RC" 1

echo "a path found only after || and unquoted still resolves"
mk later; hooks later '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"true || python3 ${CLAUDE_PLUGIN_ROOT}/scripts/gone.py"}]}]}}'
lint "$T/later"
chk "exit 1" "$RC" 1
has "  ...names it" "scripts/gone.py" "$OUT"

echo "a hooks.json with no command in it is a finding, not a pass"
mk nocmd; hooks nocmd '{"hooks":{}}'; lint "$T/nocmd"
chk "exit 1" "$RC" 1

echo "descriptions"
mk long; LONG=$(printf 'x%.0s' $(seq 1 301))
printf -- '---\nname: s\ndescription: %s\n---\nbody\n' "$LONG" > "$T/long/skills/s/SKILL.md"; lint "$T/long"
chk "a 301-char skill description: exit 1" "$RC" 1
has "  ...names the skill file" "skills/s/SKILL.md" "$OUT"
mk exact; EXACT=$(printf 'x%.0s' $(seq 1 300))
printf -- '---\nname: s\ndescription: %s\n---\nbody\n' "$EXACT" > "$T/exact/skills/s/SKILL.md"; lint "$T/exact"
chk "exactly 300 chars passes" "$RC" 0
mk longcmd; printf -- '---\ndescription: %s\n---\nbody\n' "$LONG" > "$T/longcmd/commands/c.md"; lint "$T/longcmd"
chk "a 301-char command description: exit 1" "$RC" 1
has "  ...names the command file" "commands/c.md" "$OUT"
mk folded; printf -- '---\nname: s\ndescription: first line\n  second line\nallowed-tools: Bash\n---\nbody\n' > "$T/folded/skills/s/SKILL.md"; lint "$T/folded"
chk "a folded description is read whole and passes" "$RC" 0
mk empty; printf -- '---\nname: s\ndescription:\n---\nbody\n' > "$T/empty/skills/s/SKILL.md"; lint "$T/empty"
chk "an empty skill description: exit 1" "$RC" 1
mk nodesc; printf -- '---\ndescription: ok\n---\n' > "$T/nodesc/commands/c.md"; printf -- '---\nname: s\n---\nbody\n' > "$T/nodesc/skills/s/SKILL.md"; lint "$T/nodesc"
chk "a skill with no description at all: exit 1" "$RC" 1
mk nofm; printf 'no frontmatter\n' > "$T/nofm/commands/c.md"; lint "$T/nofm"
chk "a command with no frontmatter: exit 1" "$RC" 1

echo "what is not a finding"
mk nohj; rm -r "$T/nohj/hooks" "$T/nohj/scripts"; lint "$T/nohj"
chk "no hooks.json at all, skills present: exit 0" "$RC" 0
mk onlyhooks; rm -r "$T/onlyhooks/skills" "$T/onlyhooks/commands"; lint "$T/onlyhooks"
chk "hooks only, no skills or commands: exit 0" "$RC" 0
mkdir -p "$T/bare/.claude-plugin"; lint "$T/bare"
chk "neither skills nor commands nor hooks: exit 1" "$RC" 1

echo "could not look: never a pass"
mk badjson; printf '{not json' > "$T/badjson/hooks/hooks.json"; lint "$T/badjson"
chk "hooks.json that is not JSON: exit 2" "$RC" 2
mk unread; chmod 000 "$T/unread/hooks/hooks.json"; lint "$T/unread"
if [ -r "$T/unread/hooks/hooks.json" ]; then echo "  skip  (running as a user who can read mode 000)"
else chk "unreadable hooks.json: exit 2" "$RC" 2; fi
chmod 644 "$T/unread/hooks/hooks.json"
lint "$T/does-not-exist"
chk "a plugin dir that does not exist: exit 2" "$RC" 2
"$PY" "$L" >/dev/null 2>&1; chk "no argument: exit 2" "$?" 2
mk badutf; printf -- '---\ndescription: \xff\xfe\n---\n' > "$T/badutf/commands/c.md"; lint "$T/badutf"
chk "a command that is not UTF-8: exit 2" "$RC" 2

echo "the real plugins"
for p in bendit bendit-web; do
  lint "$ROOT/plugins/$p"; chk "plugins/$p: exit 0" "$RC" 0
done

# Run the suite again under the oldest Python the kit supports.
if [ -z "$PY_GIVEN" ] && [ -x /usr/bin/python3 ] && [ "${PLUGIN_LINT_NO_RERUN:-}" != 1 ]; then
  echo "--- again under /usr/bin/python3 ($(/usr/bin/python3 -V 2>&1))"
  PY=/usr/bin/python3 PLUGIN_LINT_NO_RERUN=1 bash "$0" || fail=$((fail+1))
fi
printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
