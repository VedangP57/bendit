#!/usr/bin/env bash
# Probe layer of the session brief. The brief's one promise is that nothing it
# cannot verify is stated as a fact, so every probe is tested in the state that
# tempts a script to lie: not a repo, corrupt repo, odd paths, a stopped rebase,
# a gone upstream, no network. Each case has a snapshot AND a line assertion --
# the snapshot records what it said, the assertion pins the one line that matters.
set -uo pipefail
SD="$(cd "$(dirname "$0")" && pwd)"
S="$SD/session-brief.py"
T=$(mktemp -d); pass=0; fail=0

. "$SD/expect.sh"
expect_init "$SD/session-brief.expected"
# Confine git discovery to the fixtures: the "not a repo" case must not walk up
# into a real repository and succeed.
export GIT_CEILING_DIRECTORIES="$(dirname "$T")"
# Fixtures must not depend on this machine's git config.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
# The hook reads bendit.json from CLAUDE_PROJECT_DIR before the payload's cwd;
# inside a Claude session that names the REAL project, so it must not leak in.
unset CLAUDE_PROJECT_DIR
expect_scrub_dir "$T" '<tmp>'

# Every case runs the script's real functions through this prelude, which
# prints one fact per line so assertions can match whole lines.
PRE='
import importlib.util, sys, time
spec = importlib.util.spec_from_file_location("sb", sys.argv[1])
sb = importlib.util.module_from_spec(spec); spec.loader.exec_module(sb)
def show(label, p):
    print(f"{label} state: {p.state}")
    if p.value is not None: print(f"{label} value: {p.value}")
    if p.reason is not None: print(f"{label} reason: {p.reason}")
def show_status(st):
    print(f"branch: {st.branch}")
    print(f"upstream: {st.upstream}")
    print(f"ahead: {st.ahead}")
    print(f"behind: {st.behind}")
    for xy, path in st.entries: print(f"entry: {xy}|{path}")
def status(d):
    p = sb.git(d, "status", "--porcelain=v2", "-z", "--branch", "--untracked-files=all")
    print(f"status state: {p.state}")  # raw value holds commit ids: not snapshotable
    return sb.parse_status_v2(p.value) if p.state == "ok" else None
'
# PY overrides the interpreter, to prove the script runs on the oldest python3 in use.
PY_GIVEN="${PY:-}"
PY="${PY:-python3}"
# py <label> <python>  -- run a driver against $S, record, keep output for asserts
py() { local label="$1" code="$2"; shift 2
       expect_capture "$label" "$PY" -c "$PRE
$code" "$S" "$@"; }
# has <label> <exact line>
has() { if grep -qxF -- "$2" <<<"$EXPECT_OUT"; then printf '  ok    %s\n' "$1"; pass=$((pass+1));
        else printf '  FAIL  %s (no line: %s)\n' "$1" "$2"; printf '%s\n' "$EXPECT_OUT" | sed 's/^/        | /'; fail=$((fail+1)); fi; }
# lacks <label> <exact line>
lacks() { if grep -qxF -- "$2" <<<"$EXPECT_OUT"; then printf '  FAIL  %s (unexpected line: %s)\n' "$1" "$2"; fail=$((fail+1));
          else printf '  ok    %s\n' "$1"; pass=$((pass+1)); fi; }
g() { local d="$1"; shift; git -C "$d" "$@"; }
# mk <dir> -- a repo on `main` with one commit
mk() { mkdir -p "$1"; git -C "$1" init -q -b main; echo base > "$1/base.txt"
       git -C "$1" add base.txt; git -C "$1" commit -q -m base; }

# --- git(): failure is failure, never empty output ---------------------------
mkdir -p "$T/plain"
py "not-a-repo" 'show("git", sb.git(sys.argv[2], "status"))' "$T/plain"
has "not-a-repo -> failed" "git state: failed"
lacks "not-a-repo is not ok" "git state: ok"

mkdir -p "$T/corrupt"; echo 'gitdir: /nonexistent' > "$T/corrupt/.git"
# state only: git's wording for a broken gitdir differs between versions
py "corrupt-git" 'print("git state:", sb.git(sys.argv[2], "status").state)' "$T/corrupt"
has "corrupt-git -> failed" "git state: failed"

# --- parse_status_v2 ---------------------------------------------------------
mk "$T/first"; echo x > "$T/first/CLAUDE.md"; g "$T/first" add CLAUDE.md; g "$T/first" commit -q -m c
echo y >> "$T/first/CLAUDE.md"
py "first-path-intact" 'show_status(status(sys.argv[2]))' "$T/first"
has "first path is CLAUDE.md, not LAUDE.md" "entry: .M|CLAUDE.md"
has "first-path branch" "branch: main"

mk "$T/ren"; echo r > "$T/ren/a b.txt"; g "$T/ren" add "a b.txt"; g "$T/ren" commit -q -m r
g "$T/ren" mv "a b.txt" "c d.txt"; echo u > "$T/ren/café ü.txt"
py "rename-and-space" 'show_status(status(sys.argv[2]))' "$T/ren"
has "rename shown old -> new" "entry: R.|a b.txt -> c d.txt"
has "unicode untracked path intact" "entry: ??|café ü.txt"

mk "$T/det"; g "$T/det" checkout -q --detach
py "detached" 'show_status(status(sys.argv[2]))' "$T/det"
has "detached -> branch None" "branch: None"

# A rebase stopped on a conflict reports branch.head as (detached) too, plus
# unmerged `u` records; the parser must cope with both.
mk "$T/reb"; echo one > "$T/reb/f"; g "$T/reb" add f; g "$T/reb" commit -q -m f
g "$T/reb" checkout -q -b topic; echo topic > "$T/reb/f"; g "$T/reb" commit -q -am topic
g "$T/reb" checkout -q main; echo main > "$T/reb/f"; g "$T/reb" commit -q -am main
g "$T/reb" checkout -q topic; g "$T/reb" rebase main >/dev/null 2>&1
test -d "$T/reb/.git/rebase-merge" || test -d "$T/reb/.git/rebase-apply" \
  || { printf '  FAIL  fixture: rebase did not stop\n'; fail=$((fail+1)); }
py "mid-rebase" 'show_status(status(sys.argv[2]))' "$T/reb"
has "mid-rebase -> branch None, no exception" "branch: None"
has "mid-rebase unmerged entry parsed" "entry: UU|f"
lacks "mid-rebase did not crash" "Traceback (most recent call last):"

# --- remote tracking ---------------------------------------------------------
git init -q --bare -b main "$T/origin.git"
mk "$T/rem"; g "$T/rem" remote add origin "$T/origin.git"; g "$T/rem" push -q origin main 2>/dev/null
g "$T/rem" checkout -q -b feat; echo f > "$T/rem/feat.txt"; g "$T/rem" add feat.txt; g "$T/rem" commit -q -m feat
g "$T/rem" push -q origin feat 2>/dev/null
py "pushed-without-u" 'show("remote", sb.on_remote(sys.argv[2], "feat")); show_status(status(sys.argv[2]))' "$T/rem"
has "pushed branch is on remote" "remote value: yes"
has "no -u -> upstream None" "upstream: None"

g "$T/rem" checkout -q -b gone; echo g > "$T/rem/gone.txt"; g "$T/rem" add gone.txt; g "$T/rem" commit -q -m gone
g "$T/rem" push -q -u origin gone 2>/dev/null
g "$T/origin.git" branch -q -D gone; g "$T/rem" fetch -q --prune
py "gone-upstream" 'show("remote", sb.on_remote(sys.argv[2], "gone")); show_status(status(sys.argv[2]))' "$T/rem"
has "gone upstream still named" "upstream: origin/gone"
has "gone upstream -> ahead None" "ahead: None"
has "gone branch is not on remote" "remote value: no"

# Base goes to origin BEFORE the new branch exists, or inherited commits count.
mk "$T/unp"; g "$T/unp" remote add origin "$T/origin.git"; g "$T/unp" push -q origin main:unp-base 2>/dev/null
g "$T/unp" fetch -q origin
g "$T/unp" checkout -q -b fresh
py "unpushed-new-branch-0" 'show("unpushed", sb.unpushed(sys.argv[2], "fresh"))' "$T/unp"
has "new branch with no own commits -> 0" "unpushed value: 0"
echo n > "$T/unp/n.txt"; g "$T/unp" add n.txt; g "$T/unp" commit -q -m n
py "unpushed-new-branch-1" 'show("unpushed", sb.unpushed(sys.argv[2], "fresh"))' "$T/unp"
has "one own commit -> 1" "unpushed value: 1"

# --- reach() -----------------------------------------------------------------
py "dns-fail" 'show("reach", sb.reach("nonexistent.invalid", 443))'
has "unresolvable host -> failed" "reach state: failed"
has "says it cannot tell which" "reach reason: could not resolve nonexistent.invalid — offline, or the project no longer exists; can't tell which"

py "dns-timeout" '
import socket
socket.getaddrinfo = lambda *a, **k: time.sleep(3)
t = time.monotonic()
show("reach", sb.reach("slow.example", 443))
print("fast: %s" % (time.monotonic() - t < 1.5))' 
has "stalled lookup -> unknown" "reach state: unknown"
has "stalled lookup returns promptly" "fast: True"
has "unknown reason names the deadline" "reach reason: lookup timed out after 0.8s"

# reach()'s connect phase, with local stand-ins only: no real black-hole host.
py "connect-timeout" '
import socket
def slow(*a, **k): raise TimeoutError("timed out")
socket.create_connection = slow
show("reach", sb.reach("127.0.0.1", 9))'
has "connect timeout -> unknown" "reach state: unknown"
lacks "connect timeout is not failed" "reach state: failed"
has "connect timeout reason" "reach reason: connection to 127.0.0.1:9 timed out after 0.8s"

py "connect-socket-timeout" '
import socket
def slow(*a, **k): raise socket.timeout("timed out")
socket.create_connection = slow
show("reach", sb.reach("127.0.0.1", 9))'
has "socket.timeout -> unknown" "reach state: unknown"
lacks "socket.timeout is not failed" "reach state: failed"

py "connect-stalled" '
import socket
socket.create_connection = lambda *a, **k: time.sleep(3)
show("reach", sb.reach("127.0.0.1", 9))'
has "stalled connect -> unknown" "reach state: unknown"

py "connect-refused" '
import socket
s = socket.socket(); s.bind(("127.0.0.1", 0)); port = s.getsockname()[1]; s.close()
p = sb.reach("127.0.0.1", port)
show("reach", p._replace(reason=p.reason.replace(str(port), "<port>")))'
has "refused -> failed" "reach state: failed"
has "refused reason" "reach reason: 127.0.0.1:<port> refused or unreachable"

py "connect-ok" '
import socket
s = socket.socket(); s.bind(("127.0.0.1", 0)); s.listen(1)
show("reach", sb.reach("127.0.0.1", s.getsockname()[1]))'
has "listening -> ok" "reach state: ok"
has "listening value" "reach value: reachable"

# --- env_value() -------------------------------------------------------------
mkdir -p "$T/env"
printf '#X=1\n  X=2\nX=3\nQ="quoted"\n' > "$T/env/.env"; printf '#Y=1\n' > "$T/env/.env.local"
py "dotenv-last-wins" '
r = sys.argv[2]
print("X: %s" % sb.env_value(r, [".env"], "X"))
print("Q: %s" % sb.env_value(r, [".env"], "Q"))
print("Y: %s" % sb.env_value(r, [".env", ".env.local"], "Y"))
print("missing: %s" % sb.env_value(r, [".nope"], "X"))' "$T/env"
has "last uncommented assignment wins" "X: 3"
has "quotes stripped" "Q: quoted"
has "only a commented assignment -> None" "Y: None"
has "missing file -> None" "missing: None"

# Files are in priority order, highest first (the default is .env.local, .env):
# the first file that sets the var wins, a later one is only a fallback.
mkdir -p "$T/prio"; printf 'X=from-env\nZ=only-env\n' > "$T/prio/.env"; printf 'X=from-local\n' > "$T/prio/.env.local"
py "dotenv-priority" '
r = sys.argv[2]
print("X: %s" % sb.env_value(r, [".env.local", ".env"], "X"))
print("Z: %s" % sb.env_value(r, [".env.local", ".env"], "Z"))
print("defaults: %s" % sb.DEFAULTS["env_files"])' "$T/prio"
has ".env.local beats .env" "X: from-local"
has "a var only in .env falls back to it" "Z: only-env"
has "the default order is .env.local, then .env" "defaults: ['.env.local', '.env']"

# A read error is not "not set": it must raise, never return None.
mkdir -p "$T/env/.env.dir"
py "dotenv-unreadable" '
try:
    print("got:", sb.env_value(sys.argv[2], [".env.dir"], "X"))
except OSError as e:
    print("raised:", type(e).__name__)' "$T/env"
has "unreadable env file raises OSError" "raised: IsADirectoryError"

# dotenv's line grammar: a value dotenv sees but this parser misses reads "not
# set", and a missed comment poisons the host.
# repr() so a trailing space would show.
{ printf 'A = https://a.example.com\n'
  printf 'C: https://c.example.com\n'
  printf 'B=https://b.example.com # prod\n'
  printf 'export E=https://e.example.com\n'
  printf 'H="keep # this" # but not this\n'
  printf "S='single # too'\n"
  printf 'K=`back`\n'
  printf '# A=https://commented.example.com\n'; } > "$T/env/.env.grammar"
py "dotenv-grammar" '
r = sys.argv[2]
for v in "ACBEHSK":
    print("%s: %r" % (v, sb.env_value(r, [".env.grammar"], v)))
print("B host: %r" % (sb._host_port(sb.env_value(r, [".env.grammar"], "B")),))' "$T/env"
has "spaces around = are allowed" "A: 'https://a.example.com'"
has "colon separator is allowed" "C: 'https://c.example.com'"
has "unquoted value stops at ' #'" "B: 'https://b.example.com'"
has "export prefix allowed" "E: 'https://e.example.com'"
has "double-quoted value keeps its ' #'" "H: 'keep # this'"
has "single-quoted value keeps its ' #'" "S: 'single # too'"
has "back-quoted value unquoted" "K: 'back'"
has "commented host is not the host" "B host: ('b.example.com', 443)"

# host:port is parsed by hand, not by urlsplit: an unencoded `[...]` in a
# password made urlsplit raise on 3.14 ("does not appear to be an IPv4 or IPv6
# address"), so the probe read "unknown (ValueError ...)" and lost its HH:MM.
py "host-port-grammar" '
for v in ["postgres://admin:[tok]@db.example.com:5432/x",
          "postgres://admin:p@ss@db.example.com/x",
          "postgresql://u:p@[::1]:6543/db",
          "https://Example.COM/path?q=1",
          "http://h.example.com:8080",
          "db.example.com:6543",
          "https://h.example.com:notaport/",
          "mysql://h.example.com/x"]:
    print("%s -> %r" % (v.split("@")[-1], sb._host_port(v)))'
has "[...] in the password still parses" "db.example.com:5432/x -> ('db.example.com', 5432)"
has "@ in the password: the LAST @ ends it" "db.example.com/x -> ('db.example.com', 5432)"
has "bracketed IPv6 host" "[::1]:6543/db -> ('::1', 6543)"
has "host lowercased, scheme default port" "https://Example.COM/path?q=1 -> ('example.com', 443)"
has "explicit port" "http://h.example.com:8080 -> ('h.example.com', 8080)"
has "no scheme, host:port" "db.example.com:6543 -> ('db.example.com', 6543)"
has "a bad port is no port, not an exception" "https://h.example.com:notaport/ -> ('h.example.com', None)"
has "unknown scheme, no port -> no port" "mysql://h.example.com/x -> ('h.example.com', None)"

# --- no network unless listed -------------------------------------------------
# The brief's only network traffic is the probes a project LISTS. Here the
# resolver and connect are stubs that record any call, so "no probe ran" is
# measured, not inferred from the absence of a line. The CONTROL lists one port
# and must record a call, or the stub could never have caught anything.
mk "$T/nonet"; printf 'APP_URL=https://x.invalid\n' > "$T/nonet/.env.local"
printf '.claude/\n' >> "$T/nonet/.git/info/exclude"; mkdir -p "$T/nonet/.claude"
NONET='
import socket
calls = []
def resolver(*a, **k):
    calls.append(a); raise OSError("stub: no network in this test")
socket.getaddrinfo = resolver
socket.create_connection = resolver
open(sys.argv[2] + "/.claude/bendit.json", "w").write(sys.argv[3])
on, cfg = sb.load_config(sb.main_checkout(sys.argv[2], 1.0))
ctx, toast = sb.build(sys.argv[2], cfg, 5)
print("on:", on)
print("network calls:", len(calls))
print("probe lines:", sum(1 for l in ctx.splitlines() if l.startswith("[probe ")))'
bj() { printf '{"version":1,"features":{"session-brief":{"on":true,"why":"t"%s}}}' "${1:+,\"brief\":$1}"; }
py "no-network-by-default" "$NONET" "$T/nonet" "$(bj)"
has "no brief object -> on" "on: True"
has "no brief object -> no network call at all" "network calls: 0"
py "no-network-empty-lists" "$NONET" "$T/nonet" "$(bj '{"local_ports": [], "probe_env_vars": []}')"
has "empty local_ports and probe_env_vars -> no network call" "network calls: 0"
has "  ...and no probe line" "probe lines: 0"
py "network-control" "$NONET" "$T/nonet" "$(bj '{"local_ports": [1]}')"
lacks "CONTROL: a listed port DOES reach the (stub) network" "network calls: 0"
has "  ...and prints its probe line" "probe lines: 1"

# --- the brief (CLI) -----------------------------------------------------------
# The CLI is the product: it is run as the hook runs it, as a child process, and
# its stdout must be exactly one JSON line. This driver checks that, then prints
# the context one line per `| ` row so assertions match whole lines. Everything
# that varies between runs (time, commit ids, temp paths) is scrubbed HERE, so
# the assertions and the snapshot see the same text.
RUN='
import json, os, re, subprocess, sys, time
t0 = time.monotonic()
r = subprocess.run([sys.executable, *sys.argv[1:]], capture_output=True, timeout=30)
wall = time.monotonic() - t0
T = os.environ["BT"]
def scrub(s):
    for p in sorted({os.path.realpath(T), T}, key=len, reverse=True):
        s = s.replace(p, "<tmp>")
    s = re.sub(r"taken \d{4}-\d\d-\d\d \d\d:\d\d [^.]+\.", "taken <time>.", s)
    s = re.sub(r"\[probe \d\d:\d\d\]", "[probe <hh:mm>]", s)
    for port in os.environ.get("BPORTS", "").split():
        s = re.sub(r"\b%s\b" % port, "<port>", s)
    return re.sub(r"\b[0-9a-f]{7}\b", "<sha>", s)
print("exit:", r.returncode)
if r.stderr: print("stderr:", scrub(r.stderr.decode("utf-8", "replace")))
out = r.stdout.decode("utf-8", "replace")
print("stdout lines:", len(out.splitlines()))
try:
    d = json.loads(out)
except ValueError:
    print("json: INVALID"); print(scrub(out)); sys.exit(0)
print("json: valid, keys", sorted(d))
ctx = d["context"]
print("context <= 2000 chars:", len(ctx) <= 2000)
print("first:", scrub(ctx.splitlines()[0]) if ctx else "(empty)")
for line in ctx.splitlines(): print("| " + scrub(line))
print("toast:", scrub(d["toast"]))
print("toast <= 120 chars:", len(d["toast"]) <= 120)
if os.environ.get("WALL"): print("wall < %ss: %s" % (os.environ["WALL"], wall < float(os.environ["WALL"])))
'
export BT="$T"
# brief <label> <args...>  -- run the CLI, record, keep output for asserts
brief() { local label="$1"; shift; expect_capture "$label" "$PY" -c "$RUN" "$S" "$@"; }
# conf <main checkout> <brief json | "" | - | raw:<text>>  -- its .claude/bendit.json:
# session-brief on with that brief object ("" = none), "-" = no file, raw: =
# exactly <text>. .claude/ is git-excluded so the file is not an uncommitted one.
conf() { local d="$1" gd; gd="$(git -C "$d" rev-parse --git-common-dir 2>/dev/null)" || gd=""
  if [ -n "$gd" ]; then case "$gd" in /*) ;; *) gd="$d/$gd";; esac
    grep -qxF '.claude/' "$gd/info/exclude" 2>/dev/null || { mkdir -p "$gd/info"; printf '.claude/\n' >> "$gd/info/exclude"; }; fi
  mkdir -p "$d/.claude"
  case "$2" in
    -) rm -f "$d/.claude/bendit.json" ;;
    raw:*) printf '%s\n' "${2#raw:}" > "$d/.claude/bendit.json" ;;
    *) printf '%s\n' "$(bj "$2")" > "$d/.claude/bendit.json" ;;
  esac; }
# contains <label> <fixed substring>
contains() { if grep -qF -- "$2" <<<"$EXPECT_OUT"; then printf '  ok    %s\n' "$1"; pass=$((pass+1));
             else printf '  FAIL  %s (nothing contains: %s)\n' "$1" "$2"; printf '%s\n' "$EXPECT_OUT" | sed 's/^/        | /'; fail=$((fail+1)); fi; }
# count <label> <regex> <n>  -- exactly n output lines match
count() { local n; n="$(grep -cE -- "$2" <<<"$EXPECT_OUT")"
          if [ "$n" = "$3" ]; then printf '  ok    %s\n' "$1"; pass=$((pass+1));
          else printf '  FAIL  %s (%s lines match %s, want %s)\n' "$1" "$n" "$2" "$3"; fail=$((fail+1)); fi; }
# valid <label>  -- the hook contract: exit 0, one JSON line, both caps held
valid() { has "$1 exits 0" "exit: 0"; has "$1 is one JSON line" "stdout lines: 1"
          has "$1 JSON has context and toast" "json: valid, keys ['context', 'toast']"
          has "$1 within 2000 chars" "context <= 2000 chars: True"; has "$1 toast within 120" "toast <= 120 chars: True"; }
HEADER='Session brief — snapshot taken <time>. Where it disagrees with live git or files, trust the live state and say so. Lines marked unknown were not checked successfully; treat them as unknown, not as no.'

mk "$T/b-plain"; echo dirty >> "$T/b-plain/base.txt"
brief "header-and-tags" --cwd "$T/b-plain"
valid "header"
has "first line is the fixed copy" "first: $HEADER"
has "branch line tagged [git]" "| [git] Branch: main — 1 uncommitted file."
has "no remote -> not on origin, qualified" "| [git] Push: not on origin (as of the last fetch)."
has "uncommitted names listed" "| [git] Uncommitted: .M base.txt"
has "toast counts the unknown commits line" "toast: brief: main · 1 uncommitted · 1 unknown"

# A repo with no commit at all (fresh `git init`): no traceback, the unborn
# branch is named, and what cannot be known says unknown.
mkdir -p "$T/b-zero"; git -C "$T/b-zero" init -q -b main
brief "zero-commits" --cwd "$T/b-zero"
valid "zero-commits"
has "unborn branch is named" "| [git] Branch: main — 0 uncommitted files."
lacks "no traceback" "Traceback (most recent call last):"
has "toast names the unborn branch" "toast: brief: main · 0 uncommitted · 1 unknown"

mk "$T/b-dead"; printf 'APP_URL=https://x.invalid\n' > "$T/b-dead/.env.local"
conf "$T/b-dead" '{"probe_env_vars": ["APP_URL"]}'
brief "probe-dead-host" --cwd "$T/b-dead"
valid "probe-dead-host"
has "dead host is an alarm that can't tell which" "| [probe <hh:mm>] APP_URL (x.invalid:443) failed: could not resolve x.invalid — offline, or the project no longer exists; can't tell which"
has "toast carries the alarm" "toast: brief: main · 1 uncommitted · APP_URL: can't resolve host — offline or gone, can't tell which"

mk "$T/b-secret"; printf 'DB_URL=postgres://admin:[s3cret]@x.invalid:5432/db\n' > "$T/b-secret/.env.local"
conf "$T/b-secret" '{"probe_env_vars": ["DB_URL"]}'
brief "probe-bracketed-password" --cwd "$T/b-secret"
valid "probe-bracketed-password"
has "a [..] password still probes host:port, with its time" "| [probe <hh:mm>] DB_URL (x.invalid:5432) failed: could not resolve x.invalid — offline, or the project no longer exists; can't tell which"
count "the password is never printed" 's3cret' 0

# A value that is not a URL is never parsed as host:port nor printed: `token:1234`
# would have read as host "token", port 1234 and been echoed as "VAR (token:1234)".
mk "$T/b-nonurl"; printf 'API_TOKEN=tok3nvalue:1234\n' > "$T/b-nonurl/.env.local"
conf "$T/b-nonurl" '{"probe_env_vars": ["API_TOKEN"]}'
brief "probe-non-url" --cwd "$T/b-nonurl"
valid "probe-non-url"
has "a non-URL value is reported as not probed" "| [files] API_TOKEN is not a URL; not probed"
count "the non-URL value is never printed" 'tok3nvalue' 0
count "...nor any part of it as host:port" '1234' 0

# listen <4|6>  -- a loopback-only listener in the background, for the rest of
# the suite; sets LPORT, or LPORT="" if that loopback cannot be bound here.
LPIDS=()
listen() { local f="$T/listen-$1-$RANDOM" i
  "$PY" -c '
import socket, sys, time
fam, host = (socket.AF_INET6, "::1") if sys.argv[1] == "6" else (socket.AF_INET, "127.0.0.1")
try:
    s = socket.socket(fam, socket.SOCK_STREAM); s.bind((host, 0)); s.listen(16)
except OSError:
    print("nobind", flush=True); sys.exit(0)
print(s.getsockname()[1], flush=True); time.sleep(120)' "$1" > "$f" &
  LPIDS+=($!)
  for i in $(seq 1 50); do [ -s "$f" ] && break; sleep 0.1; done
  LPORT="$(head -n1 "$f")"; [ "$LPORT" = nobind ] && LPORT=""; }

# localhost may resolve to ::1 first: a v4-only service must not read as down
# because the first address refused.
listen 4; P4="$LPORT"
mk "$T/b-port4"
conf "$T/b-port4" "{\"local_ports\": [$P4]}"
BPORTS="$P4" brief "local-port-v4-only" --cwd "$T/b-port4" --budget 5
valid "local-port-v4-only"
has "v4-only listener on local_ports -> reachable" "| [probe <hh:mm>] localhost:<port>: reachable"
count "v4-only listener raises no alarm" '^\| \[probe .*failed' 0

printf 'APP_URL=http://localhost:%s/app\n' "$P4" > "$T/b-port4/.env.local"
conf "$T/b-port4" '{"probe_env_vars": ["APP_URL"]}'
BPORTS="$P4" brief "env-url-localhost-v4-only" --cwd "$T/b-port4" --budget 5
valid "env-url-localhost-v4-only"
has "localhost URL to a v4-only listener -> reachable" "| [probe <hh:mm>] APP_URL (localhost:<port>): reachable"

# And a ::1-only service must not read as down because only 127.0.0.1 was
# asked. Where ::1 cannot be used, the case says so -- and the snapshot diff
# fails the run, so a machine without IPv6 never passes silently.
listen 6; P6="$LPORT"
if [ -n "$P6" ] && "$PY" -c 'import socket,sys; sys.exit(0 if any(a[4][0] == "::1" for a in socket.getaddrinfo("localhost", 1, type=socket.SOCK_STREAM)) else 1)'; then
  mk "$T/b-port6"
  conf "$T/b-port6" "{\"local_ports\": [$P6]}"
  BPORTS="$P6" brief "local-port-v6-only" --cwd "$T/b-port6" --budget 5
  valid "local-port-v6-only"
  has "v6-only listener on local_ports -> reachable" "| [probe <hh:mm>] localhost:<port>: reachable"
  count "v6-only listener raises no alarm" '^\| \[probe .*failed' 0
else
  expect_capture "local-port-v6-only" printf 'skipped: no IPv6 loopback\n'
  printf '  SKIP  local-port-v6-only (skipped: no IPv6 loopback)\n'
fi

conf "$T/b-dead" -
brief "probe-unconfigured" --cwd "$T/b-dead"
valid "probe-unconfigured"
count "no probe line without probe_env_vars" '^\| \[probe ' 0
has "absent config -> defaults, no config alarm" "toast: brief: main · 1 uncommitted · 1 unknown"

mk "$T/b-unset"; printf '#APP_URL=https://x.invalid\n' > "$T/b-unset/.env.local"
conf "$T/b-unset" '{"probe_env_vars": ["APP_URL"]}'
brief "probe-var-unset" --cwd "$T/b-unset"
has "commented var -> not set, from files, no probe" "| [files] APP_URL: not set in .env.local"
count "commented var is not probed" '^\| \[probe ' 0

mk "$T/b-noenv"
conf "$T/b-noenv" '{"probe_env_vars": ["APP_URL"]}'
brief "probe-var-no-env-file" --cwd "$T/b-noenv"
valid "probe-var-no-env-file"
has "no env file at all -> says none is present" "| [files] APP_URL: not set (no .env.local, .env present)"
lacks "no env file is never 'not set in' it" "| [files] APP_URL: not set in .env.local"

# Alarms alone over the cap: rank 2 (branch, push) must survive, and the cut is named.
mk "$T/b-alarms"; vars=""
for i in $(seq -w 1 30); do
  v="A_DELIBERATELY_LONG_ENVIRONMENT_VARIABLE_NAME_$i"; vars="$vars${vars:+, }\"$v\""
  printf '%s=http://\n' "$v" >> "$T/b-alarms/.env.local"
done
conf "$T/b-alarms" "{\"probe_env_vars\": [$vars]}"
brief "alarms-over-cap" --cwd "$T/b-alarms" --budget 5
valid "alarms-over-cap"
has "branch line survives long alarms" "| [git] Branch: main — 1 uncommitted file."
has "push line survives long alarms" "| [git] Push: not on origin (as of the last fetch)."
has "first alarm shown whole" "| [files] A_DELIBERATELY_LONG_ENVIRONMENT_VARIABLE_NAME_01: unknown (no host and port in its value)"
contains "the alarm cut is named" "| [brief] Alarms cut to stay under 2000 characters: "

mk "$T/b-envdir"; mkdir "$T/b-envdir/.env.local"
conf "$T/b-envdir" '{"probe_env_vars": ["APP_URL"]}'
brief "env-unreadable" --cwd "$T/b-envdir"
valid "env-unreadable"
contains "unreadable env file -> unknown alarm" "| [files] APP_URL: unknown (could not read env files: IsADirectoryError"
lacks "unreadable env file is never 'not set'" "| [files] APP_URL: not set in .env.local"

# A malformed bendit.json is an ALARM in the brief, never silence and never a
# silent default: invalid JSON, and a brief key of the wrong type.
conf "$T/b-plain" 'raw:{not json'
brief "config-unreadable" --cwd "$T/b-plain"
valid "config-unreadable"
contains "invalid config -> unknown alarm" "| [files] Brief config: unknown (<tmp>/b-plain/.claude/bendit.json: not valid JSON"
contains "  ...saying the defaults are used" "); this brief uses the defaults"
has "config alarm reaches the toast" "toast: brief: main · 1 uncommitted · bendit.json is malformed"
conf "$T/b-plain" '{"local_ports": ["3000"]}'
brief "config-wrong-type" --cwd "$T/b-plain"
valid "config-wrong-type"
contains "a wrong-typed brief key -> alarm naming the key" "'local_ports' must be a list of integers from 1 to 65535"
count "  ...and its value is never probed" '^\| \[probe ' 0
conf "$T/b-plain" -

# main + 3 linked worktrees, origin has main: dirty, ahead (one unpushed commit),
# clean (no commits of its own) -> exactly the first two are unfinished.
git init -q --bare -b main "$T/wt-origin.git"
mk "$T/wt/main"; g "$T/wt/main" remote add origin "$T/wt-origin.git"; g "$T/wt/main" push -q -u origin main 2>/dev/null
for w in dirty ahead clean; do g "$T/wt/main" worktree add -q -b "$w" "$T/wt/$w" 2>/dev/null; done
echo d > "$T/wt/dirty/d.txt"
echo a > "$T/wt/ahead/a.txt"; g "$T/wt/ahead" add a.txt; g "$T/wt/ahead" commit -q -m ahead
brief "unfinished-worktrees" --cwd "$T/wt/main"
valid "unfinished-worktrees"
has "dirty worktree listed, temp flagged" "|   - dirty: 1 uncommitted, 0 not on any remote (as of the last fetch) — <tmp>/wt/dirty ⚠ temp folder, can be wiped"
has "unpushed worktree listed" "|   - ahead: 0 uncommitted, 1 not on any remote (as of the last fetch) — <tmp>/wt/ahead ⚠ temp folder, can be wiped"
count "exactly two worktree lines" '^\|   - ' 2
has "worktree section counts two" "| [git] Other worktrees with unfinished work: 2"
has "upstream with ab -> ahead/behind as of last fetch" "| [git] Push: origin/main ahead 0, behind 0 as of the last fetch."

# A linked worktree reads its MAIN checkout's bendit.json: one file per repo.
printf 'APP_URL=https://x.invalid\n' > "$T/wt/clean/.env.local"
conf "$T/wt/main" '{"probe_env_vars": ["APP_URL"]}'
brief "worktree-reads-main-config" --cwd "$T/wt/clean"
valid "worktree-reads-main-config"
has "the main checkout's config probes the worktree's env file" "| [probe <hh:mm>] APP_URL (x.invalid:443) failed: could not resolve x.invalid — offline, or the project no longer exists; can't tell which"
conf "$T/wt/main" -; rm -f "$T/wt/clean/.env.local"

g "$T/wt/main" worktree add -q -b gone "$T/wt/gone" 2>/dev/null
rm -rf "$T/wt/gone"
brief "vanished-worktree" --cwd "$T/wt/main"
valid "vanished-worktree"
has "vanished folder noted, not called deleted" "| [git] 1 worktree folder(s) missing or unreadable (gone)"

# A git shim that stalls `status` in ONE worktree only, on PATH for this one run.
mkdir -p "$T/shim"; REAL_GIT="$(command -v git)"
SLOW="$(cd "$T/wt/dirty" && pwd -P)"
cat > "$T/shim/git" <<EOF
#!/bin/bash
if [ "\$(pwd -P)" = "$SLOW" ]; then for a in "\$@"; do [ "\$a" = status ] && exec sleep 2; done; fi
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$T/shim/git"
# macOS vets a freshly written executable on its first run (measured ~0.35s),
# which would eat the whole 0.3s budget; run it once so only the stall is timed.
"$T/shim/git" --version >/dev/null
PATH="$T/shim:$PATH" WALL=1 brief "slow-worktree" --cwd "$T/wt/main" --budget 0.3
valid "slow-worktree"
has "stalled worktree -> unknown (timed out)" "|   - dirty: unknown (timed out) — <tmp>/wt/dirty ⚠ temp folder, can be wiped"
has "the others still print" "|   - ahead: 0 uncommitted, 1 not on any remote (as of the last fetch) — <tmp>/wt/ahead ⚠ temp folder, can be wiped"
has "returns inside 1s" "wall < 1s: True"
has "toast never says no alarms beside an unknown" "toast: brief: main · 0 uncommitted · 2 unknown"
if [ "$(command -v git)" = "$REAL_GIT" ]; then printf '  ok    shim left PATH\n'; pass=$((pass+1));
else printf '  FAIL  shim leaked onto PATH\n'; fail=$((fail+1)); fi

# A call that outlives the budget: on_remote's show-ref has its own fixed 1.5s
# timeout, so the section's thread is still running when the brief prints. The
# process must still exit at the budget, not when that thread finishes. (A new
# shim file, not a rewrite: macOS re-vets a rewritten executable on first run.)
mkdir -p "$T/shim2"
cat > "$T/shim2/git" <<EOF
#!/bin/bash
for a in "\$@"; do [ "\$a" = show-ref ] && exec sleep 2; done
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$T/shim2/git"; "$T/shim2/git" --version >/dev/null
mk "$T/b-hang"
PATH="$T/shim2:$PATH" WALL=1 brief "section-past-budget" --cwd "$T/b-hang" --budget 0.3
valid "section-past-budget"
has "unfinished section -> alarm, timed out" "| [git] Branch and uncommitted files: unknown (timed out)"
has "toast carries the timeout" "toast: brief: unknown · unknown uncommitted · Branch and uncommitted files: unknown (timed out)"
has "exits at the budget, not when the thread ends" "wall < 1s: True"

# One repo, two sizes. Commit subjects are long on purpose: the cut must happen
# on any machine, including one whose temp paths are short.
C="$T/cap/repo"; git init -q --bare -b main "$T/cap-origin.git"
mk "$C"; g "$C" remote add origin "$T/cap-origin.git"; g "$C" push -q origin main 2>/dev/null
g "$C" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
g "$C" checkout -q -b feature-with-a-reasonably-long-descriptive-name
for i in $(seq -w 1 20); do
  echo "$i" > "$C/module_number_$i.ts"; g "$C" add "module_number_$i.ts"
  g "$C" commit -q -m "change $i: a commit subject long enough to look like a real one, describing what was changed and why, with a ticket reference"
done
mkdir -p "$C/docs"
for i in 1 2 3 4 5; do printf 'Feature %s touches module_number_0%s and module_number_1%s.\n' "$i" "$i" "$i" > "$C/docs/F$i.md"; done
echo 'and module_number_20' >> "$C/docs/F5.md"
g "$C" add docs; g "$C" commit -q -m docs

# Room to spare: docs and commits appear, capped.
conf "$C" '{"docs_glob": "docs/F*.md"}'
brief "docs-and-commits" --cwd "$C" --budget 5
valid "docs-and-commits"
has "commits vs base, latest 5" "| [git] Commits not in origin/main: 21 (latest 5):"
has "commits +N more" "|   +16 more"
has "nothing unknown -> toast says no alarms" "toast: brief: feature-with-a-reasonably-long-descriptive-name · 0 uncommitted · no alarms"
has "docs ranked by matches, top 3" "| [files] Feature docs that mention this branch's changed files: docs/F5.md, docs/F1.md, docs/F2.md (+2 more)"

# Over the cap: 40 dirty files, 20 commits, 12 dirty worktrees, 5 matching docs.
for i in $(seq -w 1 40); do echo x > "$C/an_uncommitted_file_with_a_long_name_$i.txt"; done
for i in $(seq -w 1 12); do g "$C" worktree add -q -b "wt-$i" "$T/cap/worktree-number-$i" 2>/dev/null; echo d > "$T/cap/worktree-number-$i/d.txt"; done
printf 'APP_URL=https://x.invalid\n' > "$C/.env.local"
conf "$C" '{"probe_env_vars": ["APP_URL"], "docs_glob": "docs/F*.md"}'
brief "cap-and-cut" --cwd "$C" --budget 5
valid "cap-and-cut"
count "docs cut first" '^\| \[files\] Feature docs' 0
count "commits cut next" '^\| \[git\] Commits ' 0
has "worktrees kept" "| [git] Other worktrees with unfinished work: 12"
contains "alarm never cut" "| [probe <hh:mm>] APP_URL (x.invalid:443) failed: "
has "branch line never cut" "| [git] Branch: feature-with-a-reasonably-long-descriptive-name — 41 uncommitted files."
has "file names capped at 8" "| [git] Uncommitted: ?? .env.local, ?? an_uncommitted_file_with_a_long_name_01.txt, ?? an_uncommitted_file_with_a_long_name_02.txt, ?? an_uncommitted_file_with_a_long_name_03.txt, ?? an_uncommitted_file_with_a_long_name_04.txt, ?? an_uncommitted_file_with_a_long_name_05.txt, ?? an_uncommitted_file_with_a_long_name_06.txt, ?? an_uncommitted_file_with_a_long_name_07.txt, +33 more"
has "says what was cut" "| [brief] Not shown, to stay under 2000 characters: feature docs, this branch's commits."

# Docs the brief did not read to the end are unknown, never part of "none":
# 502 docs (2 over the 500 limit) including one past the read limit whose only
# mention comes after it: 499 read in full, 3 unknown.
D="$T/docs-lim"; git init -q --bare -b main "$T/docs-lim-origin.git"
mk "$D"; g "$D" remote add origin "$T/docs-lim-origin.git"; g "$D" push -q origin main 2>/dev/null
g "$D" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
g "$D" checkout -q -b topic; echo x > "$D/a_distinct_module.ts"; g "$D" add a_distinct_module.ts; g "$D" commit -q -m m
mkdir -p "$D/docs"
for i in $(seq -w 1 501); do echo nothing > "$D/docs/F$i.md"; done
"$PY" -c 'import sys; open(sys.argv[1], "w").write("x" * 1000000 + " a_distinct_module")' "$D/docs/A-big.md"
conf "$D" '{"docs_glob": "docs/*.md"}'
brief "docs-not-all-checked" --cwd "$D" --budget 5
valid "docs-not-all-checked"
has "none counts only docs read in full; the rest unknown" "| [files] Feature docs that mention this branch's changed files: none of 499; 3 unknown (not checked)"
has "a docs unknown reaches the toast" "toast: brief: topic · 502 uncommitted · 1 unknown"

# The push line's remaining fixed copy, each from a real fixture.
brief "push-detached" --cwd "$T/det"
valid "push-detached"
has "detached -> HEAD's commits on no remote" "| [git] Push: detached HEAD; 1 commit on no remote (as of the last fetch)."
has "detached toast says HEAD" "toast: brief: HEAD · 0 uncommitted · 1 unknown"
brief "push-upstream-gone" --cwd "$T/rem"
valid "push-upstream-gone"
has "gone upstream -> as of the last fetch, deletion only likely" "| [git] Push: upstream origin/gone is gone as of the last fetch (often the remote branch was deleted after a merge). Not fetched now."
g "$T/rem" worktree add -q "$T/rem-feat" feat 2>/dev/null
brief "push-without-u" --cwd "$T/rem-feat"
valid "push-without-u"
has "pushed without -u -> on origin, no upstream" "| [git] Push: on origin as origin/feat, but no upstream is set."

mk "$T/b-nodocs"; mkdir -p "$T/b-nodocs/docs"; echo base.txt > "$T/b-nodocs/docs/F1.md"
brief "docs-off-by-default" --cwd "$T/b-nodocs"
valid "docs-off-by-default"
count "no docs section without docs_glob" '^\| \[files\] Feature docs' 0

brief "catch-all" --cwd "$T/does-not-exist"
valid "catch-all"
contains "missing cwd -> unknown" "unknown ("
lacks "no traceback on stdout" "Traceback (most recent call last):"
contains "toast says unknown, not clean" "toast: brief: unknown · unknown uncommitted · "

# Outside any repo (the folder exists, git finds no repo above it): the config
# is read from the folder itself, and every section that needs the repo root
# says unknown with the reason -- never "not set", never "none of 0".
mkdir -p "$T/norepo"; conf "$T/norepo" '{"probe_env_vars": ["APP_URL"], "docs_glob": "docs/*.md"}'
brief "catch-all-probe" --cwd "$T/norepo"
valid "catch-all-probe"
contains "no repo root -> probe var unknown with the reason, not 'not set'" "| [files] APP_URL: unknown (repo root unknown: git exited 128: fatal: not a git repository"
lacks "no repo root is never 'not set'" "| [files] APP_URL: not set in .env.local"
contains "no repo root -> docs unknown, never 'none of 0'" "| [files] Feature docs: unknown (repo root unknown: git exited 128: fatal: not a git repository"

# stdout closed, and stdout a pipe whose reader is gone: still exit 0.
expect_capture "stdout-unwritable" bash -c '
"$1" "$2" --cwd "$3" >&-; echo "closed stdout: exit $?"
"$1" "$2" --cwd "$3" | true; echo "broken pipe: exit ${PIPESTATUS[0]}"' _ "$PY" "$S" "$T/b-plain"
has "closed stdout -> exit 0" "closed stdout: exit 0"
has "broken pipe -> exit 0" "broken pipe: exit 0"
lacks "no traceback on a broken stdout" "Traceback (most recent call last):"

brief "internal-error" --cwd "$T/b-plain" --budget not-a-number
has "bad arguments still exit 0" "exit: 0"
has "bad arguments -> unavailable line" "| Session brief unavailable: ValueError"
has "bad arguments toast" "toast: brief unavailable"

# --- --hook: the SessionStart command hook ----------------------------------
# Silent unless the project's .claude/bendit.json turns session-brief on. The
# context is printed one `| ` row per line, scrubbed like RUN's.
HOOKRUN='
import json, os, re, subprocess, sys
py, script, stdin = sys.argv[1:4]
r = subprocess.run([py, script, "--hook"], input=stdin.encode(), capture_output=True, timeout=30)
T = os.environ["BT"]
def scrub(s):
    for p in sorted({os.path.realpath(T), T}, key=len, reverse=True):
        s = s.replace(p, "<tmp>")
    s = re.sub(r"taken \d{4}-\d\d-\d\d \d\d:\d\d [^.]+\.", "taken <time>.", s)
    return re.sub(r"\b[0-9a-f]{7}\b", "<sha>", s)
print("exit:", r.returncode)
err = r.stderr.decode("utf-8", "replace")
if err: print("stderr:", scrub(err.strip().splitlines()[-1]))
out = r.stdout.decode("utf-8", "replace")
if not out:
    print("stdout: empty"); sys.exit(0)
print("stdout lines:", len(out.splitlines()))
try:
    d = json.loads(out)
except ValueError:
    print("json: INVALID"); print(out); sys.exit(0)
print("json keys:", sorted(d))
h = d.get("hookSpecificOutput", {})
print("event:", h.get("hookEventName"))
ctx = h.get("additionalContext", "")
print("context <= 2000 chars:", len(ctx) <= 2000)
print("first:", scrub(ctx.splitlines()[0]) if ctx else "(empty)")
for line in ctx.splitlines()[1:]: print("| " + scrub(line))
print("systemMessage:", scrub(d.get("systemMessage") or ""))
'
# hook <label> <stdin json> -- run --hook as Claude Code would
hook() { expect_capture "$1" "$PY" -c "$HOOKRUN" "$PY" "$S" "$2"; }
mk "$T/proj"; g "$T/proj" worktree add -q -b feat "$T/proj-elsewhere" 2>/dev/null
start() { printf '{"session_id": "s", "cwd": "%s", "hook_event_name": "SessionStart", "source": "%s"}' "$1" "${2:-startup}"; }

hook "hook-off-by-default" "$(start "$T/proj")"
has "no bendit.json -> exit 0" "exit: 0"
has "no bendit.json -> says nothing" "stdout: empty"

conf "$T/proj" 'raw:{"version":1,"features":{"session-brief":{"on":false,"why":"declined"}}}'
hook "hook-feature-off" "$(start "$T/proj")"
has "session-brief off -> says nothing" "stdout: empty"

conf "$T/proj" 'raw:{"version":1,"features":{"ls-guard":{"on":true,"why":"zsh"}}}'
hook "hook-other-feature-on" "$(start "$T/proj")"
has "another feature on, session-brief absent -> says nothing" "stdout: empty"

conf "$T/proj" ''
hook "hook-startup" "$(start "$T/proj")"
has "on -> exit 0" "exit: 0"
has "on -> one JSON line" "stdout lines: 1"
has "on -> SessionStart hook output" "json keys: ['hookSpecificOutput', 'systemMessage']"
has "context is for SessionStart" "event: SessionStart"
has "context opens with the fixed header" "first: $HEADER"
has "context within 2000 chars" "context <= 2000 chars: True"
contains "the person sees the toast line" "systemMessage: brief: main · "

hook "hook-linked-worktree" "$(start "$T/proj-elsewhere")"
has "a linked worktree is on through its main checkout's bendit.json" "event: SessionStart"
contains "the worktree's own branch is briefed" "systemMessage: brief: feat · "

hook "hook-clear" "$(start "$T/proj" clear)"
has "clear gets a brief" "event: SessionStart"

for src in resume compact fork; do
  hook "hook-$src" "$(start "$T/proj" "$src")"
  has "$src gets no brief" "stdout: empty"
done

# CLAUDE_PROJECT_DIR (where the session started) decides, before the payload's
# cwd -- the same precedence as every other bendit.json reader.
mkdir -p "$T/off-proj"
CLAUDE_PROJECT_DIR="$T/off-proj" hook "hook-project-dir-off" "$(start "$T/proj")"
has "CLAUDE_PROJECT_DIR without the feature -> says nothing" "stdout: empty"
CLAUDE_PROJECT_DIR="$T/proj" hook "hook-project-dir-on" "$(start "$T/off-proj")"
has "CONTROL: CLAUDE_PROJECT_DIR with it on -> briefed" "event: SessionStart"

mkdir -p "$T/not-a-repo"
hook "hook-not-a-repo" "$(start "$T/not-a-repo")"
has "outside a repo, no bendit.json -> says nothing" "stdout: empty"

mkdir -p "$T/b-zero-hook"; git -C "$T/b-zero-hook" init -q -b main; conf "$T/b-zero-hook" ''
hook "hook-zero-commits" "$(start "$T/b-zero-hook")"
has "no commits yet -> exit 0" "exit: 0"
contains "  ...briefed, naming the unborn branch" "systemMessage: brief: main · 0 uncommitted"
lacks "  ...no traceback" "Traceback (most recent call last):"

# Malformed: the file cannot say "off", and the brief is advice, so it speaks --
# with the alarm first -- rather than going quiet.
conf "$T/proj" 'raw:{"version":1,"features":{"session-brief":{"on":true,"why":"t","brief":{"local_ports":[true]}}}}'
hook "hook-malformed" "$(start "$T/proj")"
has "malformed bendit.json -> exit 0" "exit: 0"
has "  ...still briefed" "event: SessionStart"
contains "  ...the alarm names the bad key" "| [files] Brief config: unknown (<tmp>/proj/.claude/bendit.json: feature 'session-brief': 'brief': 'local_ports' must be"
has "  ...and the toast says it" "systemMessage: brief: main · 0 uncommitted · bendit.json is malformed"
conf "$T/proj" 'raw:{not json'
hook "hook-malformed-json" "$(start "$T/proj")"
has "invalid JSON -> still briefed" "event: SessionStart"
lacks "  ...no traceback" "Traceback (most recent call last):"
conf "$T/proj" ''

hook "hook-garbage-stdin" 'not json'
has "unreadable hook input -> exit 0" "exit: 0"
has "unreadable hook input -> says nothing" "stdout: empty"
hook "hook-stdin-not-an-object" '[1]'
has "a JSON list as input -> says nothing" "stdout: empty"

# One deadline for the whole hook. The config lookup's git call spends from the
# same 1.8s budget as the brief. A shim stalls that lookup 1.2s and every
# status for good.
mkdir -p "$T/shim3"
cat > "$T/shim3/git" <<EOF
#!/bin/bash
for a in "\$@"; do
  [ "\$a" = --git-common-dir ] && { sleep 1.2; exec "$REAL_GIT" "\$@"; }
  [ "\$a" = status ] && exec sleep 5
done
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$T/shim3/git"; "$T/shim3/git" --version >/dev/null
PATH="$T/shim3:$PATH" expect_capture "hook-one-deadline" "$PY" -c '
import subprocess, sys, time
py, script, stdin = sys.argv[1:4]
t = time.monotonic()
r = subprocess.run([py, script, "--hook"], input=stdin.encode(), capture_output=True, timeout=30)
wall = time.monotonic() - t
print("exit:", r.returncode)
print("briefed:", b"SessionStart" in r.stdout)
# 2.0 is the spec; the hook budget is 1.8 so interpreter start fits inside it.
print("wall < 2.0s:", wall < 2.0)' "$PY" "$S" "$(start "$T/proj")"
has "a slow config lookup -> still exit 0" "exit: 0"
has "  ...still briefed (the stall is said, not hidden)" "briefed: True"
has "  ...and the whole hook is under 2s" "wall < 2.0s: True"
expect_verify || fail=$((fail+1))

{ kill "${LPIDS[@]}"; wait "${LPIDS[@]}"; } 2>/dev/null
rm -rf "$T"
# Left unset, PY is python3 -- then the whole suite runs AGAIN on
# /usr/bin/python3 (3.9 on macOS), against the same snapshot.
if [ -z "$PY_GIVEN" ] && [ -x /usr/bin/python3 ]; then
  echo
  echo "=== again under /usr/bin/python3 ($(/usr/bin/python3 -V 2>&1))"
  PY=/usr/bin/python3 bash "$0" || { fail=$((fail+1)); printf '  FAIL  the suite under /usr/bin/python3\n'; }
fi
echo; echo "$pass passed, $fail failed"; [ "$fail" -eq 0 ]
