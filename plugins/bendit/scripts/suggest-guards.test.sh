#!/usr/bin/env bash
# suggest-guards.py: mine THIS project's Claude Code transcripts for the
# corrections the person keeps repeating. Read-only, never another project's
# sessions, never more of a message than one redacted example of 160
# characters, and no secret in ANY printed field.
#
#   bash suggest-guards.test.sh
set -uo pipefail
SD="$(cd "$(dirname "$0")" && pwd)"
PY_GIVEN="${PY:-}"
PY="$(command -v "${PY:-python3}")"
S="$SD/suggest-guards.py"
FX="$SD/fixtures/suggest-guards"
pass=0; fail=0
unset CLAUDE_PROJECT_DIR
T=$(mktemp -d); T=$(cd "$T" && pwd -P)
trap 'rm -rf "$T"' EXIT

ok()  { printf '  ok    %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  FAIL  %s%s\n' "$1" "${2:+ -- $2}"; fail=$((fail+1)); }
chk() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "got [$2], wanted [$3]"; fi; }
has() { case "$2" in *"$3"*) ok "$1";; *) bad "$1" "no [$3] in: $2";; esac; }
# hasnt compares case-insensitively: a lowercased secret is still a secret.
hasnt() {
  local h n; h="$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')"; n="$(printf '%s' "$3" | tr '[:upper:]' '[:lower:]')"
  case "$h" in *"$n"*) bad "$1" "[$3] found in: ${2:0:300}";; *) ok "$1";; esac
}
run() { OUT="$("$PY" "$S" "$@" 2>"$T/err")"; CODE=$?; ERR="$(cat "$T/err")"; }

# The project, and a fake ~/.claude/projects. The folder name is worked out
# here independently of the script: every character that is not an ASCII
# letter or digit becomes `-` (what Claude Code does, checked against real
# folder names: `/`, `.` and `_` all turn into `-`).
P="$T/my_proj.v2"; mkdir -p "$P"
PD="$T/projects"
slug() { printf '%s' "$1" | sed 's/[^A-Za-z0-9]/-/g'; }
SLUG="$(slug "$P")"
HERE="$PD/$SLUG"
# The fixtures say __ROOT__ where a real transcript holds the session's cwd.
place() { sed "s|__ROOT__|$2|g" "$FX/$1" >"$3/$1"; }

echo "NO PAST SESSIONS"
run --root "$P" --projects-dir "$PD"
chk "no projects folder at all: exit 0"          "$CODE" 0
has "  and says so"                              "$OUT" "No past sessions found for this project"
mkdir -p "$HERE"
run --root "$P" --projects-dir "$PD"
chk "an empty project folder: exit 0"            "$CODE" 0
has "  and says so"                              "$OUT" "No past sessions found for this project"

echo; echo "REPEATED CORRECTIONS CLUSTER; A ONE-OFF DOES NOT SHOW"
for f in session-a.jsonl session-b.jsonl malformed.jsonl; do place "$f" "$P" "$HERE"; done
run --root "$P" --projects-dir "$PD" --json
chk "exit 0"                                     "$CODE" 0
chk "  nothing on stderr (no traceback)"         "$ERR" ""
J="$T/out.json"; printf '%s' "$OUT" >"$J"
q() { "$PY" -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$J" "$1" 2>&1; }
chk "one cluster at --min 2"                     "$(q 'len(d["clusters"])')" 1
chk "  it is the git push corrections"           "$(q 'd["clusters"][0]["tool"] + " " + d["clusters"][0]["command"]')" "Bash git push"
chk "  counted twice (tool output, a subagent prompt, a meta line and a /command are not the person)" \
                                                 "$(q 'd["clusters"][0]["count"]')" 2
has "  its pattern names a shared keyword"       "$(q 'd["clusters"][0]["pattern"]')" "force"
has "  its example quotes the person"            "$(q 'd["clusters"][0]["example"]')" "force push"
hasnt "the one-off rm correction is absent"      "$OUT" "build output"
chk "the malformed lines were counted as skipped" "$(q 'd["skipped_malformed"] >= 2')" True
run --root "$P" --projects-dir "$PD" --min 1 --json
printf '%s' "$OUT" >"$J"
chk "at --min 1 the one-off shows (2 clusters)"  "$(q 'len(d["clusters"])')" 2
run --root "$P" --projects-dir "$PD"
chk "text mode: exit 0"                          "$CODE" 0
has "  names the tool and command"               "$OUT" "Bash git push"
has "  and the count"                            "$OUT" "2 times"

echo; echo "A 5 MB LINE, A 200 000-DEEP LINE AND MALFORMED LINES ARE SKIPPED, NO TRACEBACK"
"$PY" - "$HERE/huge.jsonl" <<'PY'
import json, sys
with open(sys.argv[1], 'w') as f:
    f.write('{"type":"user","message":{"role":"user","content":"no, wrong HUGELINE ' + 'x' * (5 * 1024 * 1024) + '"}}\n')
    f.write('{"type":"user","message":{"role":"user","content":"this line is cut off by the end of the file, stop')
PY
"$PY" - "$HERE/deep.jsonl" "$P" <<'PY'
import json, sys
path, root = sys.argv[1], sys.argv[2]
with open(path, 'w') as f:
    f.write(json.dumps({"type": "assistant", "cwd": root, "message": {"role": "assistant", "content": []}}) + '\n')
    f.write('[' * 200000 + ']' * 200000 + '\n')
    f.write('{"type":"user","cwd":"' + root + '","message":{"role":"user","content":'
            + '[' * 200000 + '"no, wrong DEEPLINE"' + ']' * 200000 + '}}\n')
PY
run --root "$P" --projects-dir "$PD" --json
chk "exit 0"                                     "$CODE" 0
hasnt "  no traceback"                           "$ERR" "Traceback"
hasnt "  no RecursionError"                      "$OUT$ERR" "RecursionError"
hasnt "  the huge line's text never appears"     "$OUT" "HUGELINE"
hasnt "  the deep line's text never appears"     "$OUT" "DEEPLINE"
printf '%s' "$OUT" >"$J"
chk "  the huge line is counted as oversized"    "$(q 'd["skipped_oversized"]')" 1
chk "  the two deep lines are counted as malformed" "$(q 'd["skipped_malformed"] >= 5')" True
chk "  the cluster is unchanged"                 "$(q 'd["clusters"][0]["count"]')" 2

echo; echo "ANOTHER PROJECT'S FOLDER IS NEVER READ"
# Siblings whose names start with this project's name, and a link into one.
# Their lines even claim this project's cwd, so only the folder rule keeps
# them out.
for sib in "$PD/$SLUG-other" "$PD/${SLUG}x" "$PD/-elsewhere"; do
  mkdir -p "$sib"
  for i in 1 2 3; do
    printf '%s\n' \
      "{\"type\":\"assistant\",\"cwd\":\"$P\",\"message\":{\"role\":\"assistant\",\"content\":[{\"type\":\"tool_use\",\"name\":\"Bash\",\"input\":{\"command\":\"git push --force\"}}]}}" \
      "{\"type\":\"user\",\"cwd\":\"$P\",\"message\":{\"role\":\"user\",\"content\":\"no, never force push CANARY_SIBLING\"}}" >"$sib/s$i.jsonl"
  done
done
ln -s "$PD/$SLUG-other/s1.jsonl" "$HERE/linked.jsonl"
run --root "$P" --projects-dir "$PD" --json
chk "exit 0"                                     "$CODE" 0
hasnt "  the canary is absent"                   "$OUT" "CANARY_SIBLING"
printf '%s' "$OUT" >"$J"
chk "  the git push count is still 2"            "$(q 'd["clusters"][0]["count"]')" 2
AUDIT_CACHE="$T/pycache-prefix"; mkdir -p "$AUDIT_CACHE"
PYTHONPYCACHEPREFIX="$AUDIT_CACHE" "$PY" - "$S" "$P" "$PD" "$T/opened" "$T/wrote" <<'PY'
# Every file the script opens, and every write or mkdir it attempts, recorded
# with an audit hook (3.8+). PYTHONPYCACHEPREFIX points at an empty folder, so
# importing a helper WOULD write bytecode unless the script forbids it.
import os, pkgutil, runpy, sys   # pkgutil: runpy imports it lazily on 3.14; not the script's import
script, root, pd, log, wlog = sys.argv[1:6]
opened, wrote = [], []
WRITE = os.O_WRONLY | os.O_RDWR | os.O_CREAT | os.O_APPEND | os.O_TRUNC
def hook(ev, args):
    if ev == 'open':
        path, mode, flags = (list(args) + [None, None])[:3]
        opened.append(str(path))
        if (isinstance(mode, str) and set(mode) & set('wax+')) or (isinstance(flags, int) and flags & WRITE):
            wrote.append('open-for-write ' + str(path))
    elif ev in ('os.mkdir', 'os.rename', 'os.remove', 'shutil.copyfile'):
        wrote.append(ev + ' ' + str(args[0]))
sys.addaudithook(hook)
sys.argv = [script, '--root', root, '--projects-dir', pd]
try:
    runpy.run_path(script, run_name='__main__')
except SystemExit:
    pass
o, w = list(opened), list(wrote)
with open(log, 'w') as f:
    f.write('\n'.join(o))
with open(wlog, 'w') as f:
    f.write('\n'.join(w))
PY
hasnt "  no file under a sibling folder was opened" "$(cat "$T/opened")" "$PD/$SLUG-other"
hasnt "  nor under the prefix-trap sibling"       "$(cat "$T/opened")" "$PD/${SLUG}x"
has   "  (the audit did see this project's files)" "$(cat "$T/opened")" "$HERE/session-a.jsonl"
chk   "the script opened nothing for writing and made no folder (bytecode included)" "$(cat "$T/wrote")" ""

echo; echo "A FOLDER-NAME COLLISION: ANOTHER PROJECT'S SESSIONS IN THIS FOLDER ARE NOT READ"
# /a/b-c and /a/b/c are different projects with the same folder name.
C1="$T/a/b-c"; C2="$T/a/b/c"; mkdir -p "$C1" "$C2"
chk "  (the two roots do collide)" "$(slug "$C1")" "$(slug "$C2")"
CF="$PD/$(slug "$C1")"; mkdir -p "$CF"
mine_line() {  # mine_line <cwd> <command> <text>
  "$PY" -c 'import json,sys
cwd, cmd, text = sys.argv[1:4]
print(json.dumps({"type": "assistant", "cwd": cwd, "message": {"role": "assistant", "content": [{"type": "tool_use", "name": "Bash", "input": {"command": cmd}}]}}))
print(json.dumps({"type": "user", "cwd": cwd, "message": {"role": "user", "content": text}}))' "$@"
}
mine_line "$C1" "npm test" "no, run the unit tests only" >"$CF/mine.jsonl"
mine_line "$C1/sub" "npm test" "wrong again, unit tests only" >>"$CF/mine.jsonl"
# A line in my own file whose cwd only STARTS with my root's text.
mine_line "${C1}x" "git push" "never force push CANARY_COLLISION" >>"$CF/mine.jsonl"
for i in 1 2; do mine_line "$C2" "git push --force" "no, never force push CANARY_COLLISION" >"$CF/theirs$i.jsonl"; done
# A cwd that only LOOKS under my root: /a/b-c/../b-cx is /a/b-cx.
mine_line "$C1/../b-cx" "git push" "never force push CANARY_COLLISION" >>"$CF/mine.jsonl"
# A file with no cwd at all is nobody's for sure: skipped.
printf '%s\n' '{"type":"user","message":{"role":"user","content":"no, never CANARY_COLLISION"}}' >"$CF/nocwd.jsonl"
run --root "$C1" --projects-dir "$PD" --min 1 --json
chk "exit 0"                                     "$CODE" 0
hasnt "  the other project's canary is absent"   "$OUT" "CANARY_COLLISION"
printf '%s' "$OUT" >"$J"
chk "  one session is mine"                      "$(q 'd["sessions"]')" 1
chk "  my two corrections, from root and a subfolder, cluster" "$(q '[(c["command"], c["count"]) for c in d["clusters"]]')" "[('npm test', 2)]"
chk "  the other lines are counted as another project's" "$(q 'd["skipped_other_project"] >= 6')" True
run --root "$C1" --projects-dir "$PD" --min 1
hasnt "  text mode: the canary is absent"        "$OUT$ERR" "CANARY_COLLISION"

echo; echo "SECRETS: NONE IN ANY FIELD, ANY MODE"
# Keys are assembled at run time so this file never holds one. They are not
# repetitive, so a 6-character window of one cannot turn up by accident.
STRIPE="sk_live_""Q7vK2pR9xW4mT8nB""3hJ6cL1d"
GH="ghp_""R7kQ2mX9vL4pT8wN3jH6""cY1bF5dZ0gS2aE7u"
AWS="AKIA""J4QX7ZP2LM9WRT3K"
JWT="eyJhbGciOiJIUzI1NiJ9.""eyJzdWIiOiJxN2s5In0.""Tq8vZ3mWk1pR6xL0nB4c"
AWSS="wJalrXUtnFEMI/K7MDENG""/bPxRfiCYzqvwkeyQ12"   # an AWS secret with no name beside it
R="$T/redact"; RS="$PD/$(slug "$R")"; mkdir -p "$R" "$RS"
for i in 1 2; do
  "$PY" - "$RS/s$i.jsonl" "$R" "$STRIPE" "$GH" "$AWS" "$JWT" "$AWSS" <<'PY'
import json, sys
path, root, stripe, gh, aws, jwt, awss = sys.argv[1:8]
allkeys = ' '.join((awss, stripe, gh, aws, jwt))
# Lowercased copies too, for the keys whose shape survives lowercasing (a
# prefix such as sk_live_ / ghp_ / AKIA / eyJ). Not the AWS secret: lowercased
# it is no longer the key, and no rule could tell it from an ordinary word.
lowkeys = ' '.join((stripe, gh, aws, jwt)).lower()
calls = [  # every source of printed text: the command, its subcommand, a file path, a tool name, an input field
    ('Bash', {'command': gh + ' curl https://api.example.test'}),
    ('Bash', {'command': 'TOKEN=1 ' + aws + ' --run'}),
    ('Bash', {'command': 'git ' + stripe + ' main'}),
    ('Bash', {'command': 'cd x && ' + jwt + ' go'}),
    ('Write', {'file_path': '/tmp/note.' + stripe, 'content': gh}),
    ('Write', {'file_path': '/tmp/' + gh + '.md', 'content': aws}),
    ('WebFetch', {'url': 'https://x.test/?k=' + jwt, 'prompt': stripe}),
    (aws, {'command': gh}),
]
with open(path, 'w') as f:
    for name, inp in calls:
        f.write(json.dumps({"type": "assistant", "cwd": root, "message": {"role": "assistant", "content": [
            {"type": "tool_use", "name": name, "input": inp}]}}) + '\n')
        f.write(json.dumps({"type": "user", "cwd": root, "message": {"role": "user", "content":
            "no, never paste keys " + allkeys + " into curl again " + lowkeys + ' ' + "z" * 300}}) + '\n')
    # and a correction with no tool call before it
    f.write(json.dumps({"type": "user", "cwd": root, "message": {"role": "user", "content":
        "wrong, never " + allkeys + " again " + lowkeys}}) + '\n')
PY
done
# leaks <file> <secret>...: every 6-character window of each secret past its
# first 4 characters, searched case-insensitively.
leaks() {
  "$PY" -c 'import sys
out = open(sys.argv[1], encoding="utf-8", errors="replace").read().lower()
for s in sys.argv[2:]:
    tail = s[4:].lower()
    hits = sorted({tail[i:i + 6] for i in range(len(tail) - 5) if tail[i:i + 6] in out})
    if hits:
        print(s[:4] + "...: " + " ".join(hits[:5]))' "$@"
}
for mode in "--min 1" "--min 1 --json" "--min 2" "--min 2 --json"; do
  # shellcheck disable=SC2086
  "$PY" "$S" --root "$R" --projects-dir "$PD" $mode >"$T/sec.out" 2>"$T/sec.err"; code=$?
  chk "[$mode] exit 0"                           "$code" 0
  cat "$T/sec.out" "$T/sec.err" >"$T/sec.all"
  chk "  [$mode] no part of any key past its first 4 characters, stdout or stderr" "$(leaks "$T/sec.all" "$STRIPE" "$GH" "$AWS" "$JWT" "$AWSS")" ""
done
"$PY" "$S" --root "$R" --projects-dir "$PD" --min 1 --json >"$J"
chk "  every call made a cluster (8 tool calls + 1 with none)" "$(q 'sum(c["count"] for c in d["clusters"])')" 18
has "  an example says [REDACTED]"               "$(q 'd["clusters"][0]["example"]')" "[REDACTED]"
chk "  every example is at most 160 characters"  "$(q 'all(len(c["example"]) <= 160 for c in d["clusters"])')" True
chk "  a command that is a key prints as ?"      "$(q 'sorted({c["command"] for c in d["clusters"] if c["tool"] == "Bash"})')" "['?', 'git ?']"

echo; echo "CONTROL CHARACTERS NEVER REACH THE TERMINAL"
K="$T/ctl"; KS="$PD/$(slug "$K")"; mkdir -p "$K" "$KS"
for i in 1 2; do
  "$PY" -c 'import json,sys
print(json.dumps({"type": "user", "cwd": sys.argv[1], "message": {"role": "user", "content": "no, wrong \x1b]0;pwned\x07 title \x1b[31m red \x9b again"}}))' "$K" >"$KS/s$i.jsonl"
done
run --root "$K" --projects-dir "$PD"
chk "exit 0"                                     "$CODE" 0
chk "  no ESC, BEL or C1 byte in the output"     "$(printf '%s' "$OUT" | LC_ALL=C grep -c "$(printf '[\033\007]')" )" 0
chk "  no C1 CSI either"                         "$(printf '%s' "$OUT" | "$PY" -c 'import sys; print(sum(1 for c in sys.stdin.read() if 0x80 <= ord(c) <= 0x9f))')" 0

echo; echo "BIDI CONTROLS NEVER REACH THE TERMINAL EITHER"
B="$T/bidi"; BS="$PD/$(slug "$B")"; mkdir -p "$B" "$BS"
for i in 1 2; do
  "$PY" -c 'import json,sys
print(json.dumps({"type": "user", "cwd": sys.argv[1], "message": {"role": "user", "content": "no, wrong ‮evil‬ and ⁦iso⁩ again ‏"}}))' "$B" >"$BS/s$i.jsonl"
done
run --root "$B" --projects-dir "$PD" --min 1
chk "exit 0"                                     "$CODE" 0
has "  the example is shown"                     "$OUT" "evil"
chk "  no bidi override, isolate or mark in the output" \
    "$(printf '%s' "$OUT" | "$PY" -c 'import sys; print(sum(1 for c in sys.stdin.read() if 0x202a <= ord(c) <= 0x202e or 0x2066 <= ord(c) <= 0x2069 or ord(c) in (0x200e, 0x200f, 0x061c)))')" 0

echo; echo "A 1 MB LINE IS READ IN SECONDS: A MESSAGE IS CUT BEFORE IT IS REDACTED"
# Lines just under the 1 MiB line cap, so they are read, not skipped: a
# Bash command and a correction, each ~1 MB of the shapes that once made
# redaction super-linear. Past the cap nothing is used, so the canaries at
# the end never print.
L="$T/long"; LS="$PD/$(slug "$L")"; mkdir -p "$L" "$LS"
"$PY" - "$LS/s1.jsonl" "$L" <<'PY'
import json, sys
path, root = sys.argv[1:3]
junk = ('a-' * 1000 + 'x-PASSWORD-' * 300 + 'eyJ-' * 500 + 'mysql ' * 300 + '@=' * 500 + 'Ab3+/x9Z' * 500)
big = (junk * (990000 // len(junk) + 1))[:990000]
with open(path, 'w') as f:
    for i in range(2):
        f.write(json.dumps({"type": "assistant", "cwd": root, "message": {"role": "assistant", "content": [
            {"type": "tool_use", "name": "Bash", "input": {"command": "git push --force " + big + " CMDCANARY"}}]}}) + '\n')
        f.write(json.dumps({"type": "user", "cwd": root, "message": {"role": "user", "content":
            "no, never again " + big + " MSGCANARY"}}) + '\n')
    for i in range(2):   # a short correction after each, so the run has something to show
        f.write(json.dumps({"type": "assistant", "cwd": root, "message": {"role": "assistant", "content": [
            {"type": "tool_use", "name": "Bash", "input": {"command": "rm -rf build " + big + " CMDCANARY"}}]}}) + '\n')
        f.write(json.dumps({"type": "user", "cwd": root, "message": {"role": "user", "content": "no, never delete the build folder"}}) + '\n')
PY
chk "  (the lines are under the line cap, so they are read)" \
    "$("$PY" -c 'import sys; print(max(len(l) for l in open(sys.argv[1], "rb")) < (1 << 20))' "$LS/s1.jsonl")" True
t0=$("$PY" -c 'import time;print(time.time())')
run --root "$L" --projects-dir "$PD" --min 1 --json
el=$("$PY" -c 'import sys,time;print("%.1f" % (time.time() - float(sys.argv[1])))' "$t0")
chk "exit 0, under 5 s (took ${el}s)"            "$CODE $("$PY" -c 'import sys; print(float(sys.argv[1]) < 5)' "$el")" "0 True"
hasnt "  the message canary never appears"       "$OUT" "MSGCANARY"
hasnt "  the command canary never appears"       "$OUT" "CMDCANARY"
printf '%s' "$OUT" >"$J"
chk "  the short corrections still cluster under rm" "$(q '[(c["command"], c["count"]) for c in d["clusters"]]')" "[('rm', 2)]"

echo; echo "ONLY REAL CORRECTIONS: QUESTIONS, ANSWERS, APPROVALS AND NEW REQUESTS ARE NOT"
# Every message in this fixture once matched a marker word ("no", "don't",
# "again", "instead", "wrong", "never", "stop") somewhere in it.
N="$T/plain"; NS="$PD/$(slug "$N")"; mkdir -p "$N" "$NS"; place not-corrections.jsonl "$N" "$NS"
run --root "$N" --projects-dir "$PD" --min 1 --json
chk "exit 0"                                     "$CODE" 0
printf '%s' "$OUT" >"$J"
chk "  no correction found in 13 ordinary messages" "$(q 'd["corrections"]')" 0
chk "  and no cluster"                           "$(q 'len(d["clusters"])')" 0

echo; echo "REAL CORRECTIONS, EACH PAIRED WITH THE TOOL CALL BEFORE IT"
C="$T/corr"; CS="$PD/$(slug "$C")"; mkdir -p "$C" "$CS"; place corrections.jsonl "$C" "$CS"
run --root "$C" --projects-dir "$PD" --min 1 --json
chk "exit 0"                                     "$CODE" 0
printf '%s' "$OUT" >"$J"
chk "  six corrections (no / stop / undo / not what I asked / I told you / please don't)" "$(q 'd["corrections"]')" 6
chk "  each aimed at the call before it"         "$(q 'sorted((c["tool"], c["command"], c["count"]) for c in d["clusters"])')" \
    "[('Bash', 'git push', 2), ('Bash', 'npm publish', 1), ('Bash', 'rm', 1), ('Edit', '*.ts', 2)]"
chk "  every session row says source: session"   "$(q 'sorted({c["source"] for c in d["clusters"]})')" "['session']"

echo; echo "LABELS ARE WHOLE WORDS, NEVER STEMS"
P1="$(q '[c["pattern"] for c in d["clusters"] if c["command"] == "git push"][0]')"
has   "  the git push label says 'anything'"     "$P1" "anything"
hasnt "  and never the stem 'anyth'"             "$(q 'd["clusters"]' | sed 's/anything//g')" "anyth"
P2="$(q '[c["pattern"] for c in d["clusters"] if c["command"] == "*.ts"][0]')"
has   "  'page' and 'pages' still join one cluster, labelled with a whole word" "$P2" "login"
case "$P2" in *"pag,"*|*"pag"|*"pag "*) bad "  no 'pag' stem" "$P2";; *) ok "  no 'pag' stem";; esac

echo; echo "TWENTY MESSAGES THE FIXTURES' AUTHOR DID NOT WRITE (A REVIEWER'S TABLE): AT LEAST 18 RIGHT"
cat >"$T/table.py" <<'PY'
import importlib.util, sys
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('sg', sys.argv[1]); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
# (message, the agent's last turn asked a question, is it a correction?)
cases = [
    ("no, that's fine, go ahead", False, False),
    ("Never thought of that. Good idea, go with it", False, False),
    ("Stop here for today, we'll pick it up tomorrow", False, False),
    ("Don't forget to also update the changelog when you're done", False, False),
    ("Wrong file name in the spec doc too, can you rename it to plan.md", False, False),
    ("no worries, take your time", False, False),
    ("no rush.", False, False),
    ("Nope, all good. Merge it.", True, False),
    ("add a settings page with a dark mode toggle", False, False),
    ("looks great, thanks! now wire it into the nav", False, False),
    ("can you check why the build fails? don't change any code yet", False, False),
    ("no, it's ok, leave it as is", False, False),
    ("why did you delete the migration? I told you to keep it", False, True),
    ("no no no, put it back", True, True),
    ("ugh, you broke the login page again", False, True),
    ("Why are you running the migration against prod?", False, True),
    ("no, don't force push to main", False, True),
    ("stop, that's the wrong branch", False, True),
    ("undo that, it broke the tests", False, True),
    ("That's not what I asked for, use the existing helper", False, True),
]
right = 0
for text, asked, want in cases:
    got = m.is_correction(text, asked)
    right += got == want
    if got != want:
        print('    miss: %r (wanted %s)' % (text, want), file=sys.stderr)
print(right)
PY
SCORE="$("$PY" -B "$T/table.py" "$S")"
echo "  score: $SCORE/20"
chk "  at least 18 of 20 right"                  "$("$PY" -c 'import sys; print(int(sys.argv[1] or 0) >= 18)' "$SCORE")" True

echo; echo "--git: THIS REPO'S HISTORY, READ-ONLY, BOUNDED"
G="$T/gitrepo"; mkdir -p "$G"; REALGIT="$(command -v git)"
"$REALGIT" -C "$G" init -q && "$REALGIT" -C "$G" symbolic-ref HEAD refs/heads/main
# 5 000 commits through fast-import (seconds, not minutes). Oldest first:
# two fix commits to src/old.py that lie past the 2 000-commit bound, filler
# commits a day apart, then the recent ones the test is about.
"$PY" - "$STRIPE" <<'PY' | "$REALGIT" -C "$G" fast-import --quiet
import sys
stripe = sys.argv[1]
out = sys.stdout
recent = []
def c(msg, files, gap=86400):
    recent.append((msg, files, gap))
c('fix: empty cart crashes checkout', ['src/cart.py'])
c('fix(cart): empty cart total, key ' + stripe, ['src/cart.py'])
c('Fix cart rounding on empty cart', ['src/cart.py', 'tests/cart_test.py'])
c('Revert "feat: new checkout"', ['src/checkout.py'])
# a file and its test, the test sorting first: one row, code named first
c('fix: refund rounding', ['src/pay.py', 'src/a_pay_test.py'])
c('fix: refund twice', ['src/a_pay_test.py', 'src/pay.py'])
c('feat: add the banner', ['src/ui.py'], 600)
c('tweak the banner colour', ['src/ui.py'], 600)
c('adjust the banner spacing', ['src/ui.py'])
c('docs: usage', ['docs/use.md'])
c('docs: more usage', ['docs/use.md'])
# three files fixed together, but not by exactly the same commits: one row
for i in range(5):
    c('fix: install step %d' % i, ['install.sh', 'tests/install.test.sh', 'tests/install.expected'])
c('fix: install pacman', ['install.sh', 'tests/install.test.sh'])
# ten fixes to one hot file
for i in range(10):
    c('fix: hot path %d' % i, ['src/hot.py'])
# churn: 4 fixes among 40 commits, against 3 fixes out of 3
for i in range(36):
    c('feat: busy %d' % i, ['src/busy.py'])
for i in range(4):
    c('fix: busy %d' % i, ['src/busy.py'])
for i in range(3):
    c('fix: focused %d' % i, ['src/focused.py'])
# a docs-only row with more fixes than cart.py: still ranked after code
for i in range(5):
    c('fix: guide typo %d' % i, ['docs/guide.md'])
for k in range(1, 5):
    for i in range(2):
        c('fix: m%d %d' % (k, i), ['src/m%d.py' % k])
c('feat: step last', ['notes/n0.txt'])
n = 0
t = 946684800          # 2000-01-01
def commit(msg, files, ts):
    global n
    n += 1
    m = msg.encode()
    out.write('commit refs/heads/main\nmark :%d\ncommitter T <> %d +0000\ndata %d\n' % (n, ts, len(m)))
    out.write(msg + '\n')
    if n > 1:
        out.write('from :%d\n' % (n - 1))
    for f in files:
        body = '%s %d\n' % (f, n)
        out.write('M 100644 inline %s\ndata %d\n%s\n' % (f, len(body), body))
day = 86400
commit('fix: old bug in the parser', ['src/old.py'], t); t += day
commit('fix: old bug in the parser again', ['src/old.py'], t); t += day
for i in range(5000 - 2 - len(recent)):
    commit('feat: step %d' % i, ['notes/n%d.txt' % (i % 100)], t); t += day
for msg, files, gap in recent:
    commit(msg, files, t); t += gap
assert n == 5000, n
PY
chk "  (the scratch repo has 5 000 commits)"     "$("$REALGIT" -C "$G" rev-list --count main)" 5000
# A git shim on PATH: it records every call and refuses any subcommand
# but log, show and rev-parse.
SHIM="$T/shim"; mkdir -p "$SHIM"; : >"$T/gitcalls"; : >"$T/gitrefused"
cat >"$SHIM/git" <<SH
#!/bin/sh
sub=""; skip=0
for a in "\$@"; do
  if [ \$skip = 1 ]; then skip=0; continue; fi
  case "\$a" in -C|-c) skip=1;; -*) ;; *) sub="\$a"; break;; esac
done
echo "\$sub" >>"$T/gitcalls"
case "\$sub" in log|show|rev-parse) exec "$REALGIT" "\$@";; esac
echo "\$*" >>"$T/gitrefused"; echo "shim: refused git \$sub" >&2; exit 97
SH
chmod +x "$SHIM/git"
grun() { OUT="$(PATH="$SHIM:$PATH" "$PY" "$S" "$@" 2>"$T/err")"; CODE=$?; ERR="$(cat "$T/err")"; }
grun --root "$G" --projects-dir "$PD" --min 2
chk "without --git, git is never run"            "$(wc -l <"$T/gitcalls" | tr -d ' ')" 0
t0=$("$PY" -c 'import time;print(time.time())')
grun --root "$G" --projects-dir "$PD" --min 2 --git --json
el=$("$PY" -c 'import sys,time;print("%.1f" % (time.time() - float(sys.argv[1])))' "$t0")
chk "exit 0, under 5 s on 5 000 commits (took ${el}s)" "$CODE $("$PY" -c 'import sys; print(float(sys.argv[1]) < 5)' "$el")" "0 True"
chk "  nothing on stderr"                        "$ERR" ""
has "  git ran"                                  "$(cat "$T/gitcalls")" "log"
chk "  and only read-only subcommands"           "$(cat "$T/gitrefused")" ""
printf '%s' "$OUT" >"$J"
chk "  no sessions here, but the git rows still show" "$(q 'd["sessions"]')" 0
chk "  every row says source: git"               "$(q 'sorted({c["source"] for c in d["clusters"]})')" "['git']"
chk "  the rows, by file and count"              "$(q 'sorted((c["file"], c["count"]) for c in d["clusters"])')" \
    "[('docs/guide.md', 5), ('install.sh', 6), ('src/busy.py', 4), ('src/cart.py', 3), ('src/focused.py', 3), ('src/hot.py', 10), ('src/m1.py', 2), ('src/m2.py', 2), ('src/m3.py', 2), ('src/m4.py', 2), ('src/pay.py', 2), ('src/ui.py', 2)]"
chk "  three install files fixed by nearly the same commits are one row" \
    "$(q '[c["files"] for c in d["clusters"] if c["file"] == "install.sh"]')" "[['install.sh', 'tests/install.test.sh', 'tests/install.expected']]"
chk "  in a merged row the code comes before its test, though the test sorts first" \
    "$(q '[c["files"] for c in d["clusters"] if c["file"] == "src/pay.py"]')" "[['src/pay.py', 'src/a_pay_test.py']]"
chk "  ranked: 10 fixes first, then the install row" "$(q '[c["file"] for c in d["clusters"]][:2]')" "['src/hot.py', 'install.sh']"
chk "  3 fixes out of 3 touches outrank 4 fixes out of 40" \
    "$(q '[c["file"] for c in d["clusters"]].index("src/focused.py") < [c["file"] for c in d["clusters"]].index("src/busy.py")')" True
chk "  a docs-only row comes after every code row"  "$(q '[c["file"] for c in d["clusters"]][-1]')" "docs/guide.md"
chk "  a revert weighs 3, a fix 2, a follow-up 1" "$(q '[(c["file"], c["score"]) for c in d["clusters"] if c["file"] in ("src/hot.py", "src/ui.py")]')" "[('src/hot.py', 20), ('src/ui.py', 2)]"
chk "  only the last 2 000 commits are read"     "$(q 'd["commits_read"]')" 2000
hasnt "  nothing past the bound (src/old.py)"    "$OUT" "old.py"
hasnt "  two docs commits a day apart are not a pattern" "$OUT" "use.md"
hasnt "  the commit subject's key is redacted"   "$OUT" "$STRIPE"
chk "  no part of the key past its first 4 characters" "$(printf '%s' "$OUT" >"$T/g.out"; leaks "$T/g.out" "$STRIPE")" ""
has  "  the label is whole words from the subjects" "$(q '[c["pattern"] for c in d["clusters"] if c["file"] == "src/cart.py"][0]')" "cart, empty"
chk "  every example is at most 160 characters"  "$(q 'all(len(c["example"]) <= 160 for c in d["clusters"])')" True
grun --root "$G" --projects-dir "$PD" --min 1 --git --json
printf '%s' "$OUT" >"$J"
has "  at --min 1 the Revert shows"              "$(q '[c["file"] for c in d["clusters"]]')" "src/checkout.py"
grun --root "$G" --projects-dir "$PD" --min 2 --git
chk "text mode: exit 0"                          "$CODE" 0
has "  marks the source"                         "$OUT" "source: git"
chk "  prints the top 8 git rows"                "$(printf '%s\n' "$OUT" | grep -c 'source: git')" 8
has "  and says how many more"                   "$OUT" "4 more git rows (--json for all)"
chk "  still only read-only subcommands"         "$(cat "$T/gitrefused")" ""

echo; echo "--git: SESSION ROWS COME FIRST"
GS="$PD/$(slug "$G")"; mkdir -p "$GS"; place corrections.jsonl "$G" "$GS"
grun --root "$G" --projects-dir "$PD" --min 2 --git --json
printf '%s' "$OUT" >"$J"
chk "  the two session rows (2 each) sit above a git row of 10" \
    "$(q '[(c["source"], c["count"]) for c in d["clusters"]][:3]')" "[('session', 2), ('session', 2), ('git', 10)]"
grun --root "$G" --projects-dir "$PD" --min 2 --git
chk "  text mode: the first row is a session row" "$(printf '%s\n' "$OUT" | grep -m1 'source:' | sed 's/ *source: \([a-z]*\).*/\1/')" "session"
rm -rf "$GS"

echo; echo "--git: A PROJECT INSIDE A BIGGER REPO READS ONLY ITS OWN FOLDER"
OUTER="$T/outer"; mkdir -p "$OUTER/proj" "$OUTER/other"
"$REALGIT" -C "$OUTER" init -q
for i in 1 2; do
  echo "$i" >"$OUTER/other/x.py"; "$REALGIT" -C "$OUTER" add -A
  "$REALGIT" -C "$OUTER" -c user.name=T -c user.email= commit -q -m "fix: outside $i"
  echo "$i" >"$OUTER/proj/y.py"; "$REALGIT" -C "$OUTER" add -A
  "$REALGIT" -C "$OUTER" -c user.name=T -c user.email= commit -q -m "fix: inside $i"
done
grun --root "$OUTER/proj" --projects-dir "$PD" --min 2 --git --json
printf '%s' "$OUT" >"$J"
chk "  only the project's own file"              "$(q '[c["files"] for c in d["clusters"]]')" "[['proj/y.py']]"
hasnt "  nothing from outside it"                "$OUT" "outside"

echo; echo "--git THAT FINDS NOTHING DOES NOT CALL GIT ROWS CORRECTIONS"
grun --root "$OUTER/proj" --projects-dir "$PD" --min 5 --git
has   "  says no pattern repeats"                "$OUT" "No pattern repeats 5 or more times"
hasnt "  not 'No correction repeats'"            "$OUT" "No correction repeats"

echo; echo "--git AND A FOLDER THAT IS NOT A GIT REPO"
grun --root "$C" --projects-dir "$PD" --min 1 --git --json
chk "exit 0"                                     "$CODE" 0
printf '%s' "$OUT" >"$J"
chk "  the session rows still show"              "$(q 'len(d["clusters"])')" 4
chk "  and it says there is no git history"      "$(q 'd["git"]')" "no git history"

echo; echo "IT NEVER WRITES"
before="$(cd "$T" && /usr/bin/find . -print | sort | cksum)"
run --root "$P" --projects-dir "$PD"
run --root "$P" --projects-dir "$PD" --json
PATH="$SHIM:$PATH" "$PY" "$S" --root "$G" --projects-dir "$PD" --git >/dev/null 2>&1
after="$(cd "$T" && /usr/bin/find . -print | sort | cksum)"
chk "no file created or removed under the fixtures (err capture aside)" "$before" "$after"

if [ -z "$PY_GIVEN" ] && [ -x /usr/bin/python3 ]; then
  echo; echo "=== again under /usr/bin/python3 ($(/usr/bin/python3 -V 2>&1))"
  PY=/usr/bin/python3 bash "$0" || { fail=$((fail+1)); printf '  FAIL  the suite under /usr/bin/python3\n'; }
fi
echo; echo "suggest-guards.test.sh: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
