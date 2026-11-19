#!/usr/bin/env bash
# privacy-scan.py: both halves. It must FIND personal data, and stay silent on
# the placeholders every public repo is full of -- a scanner that cries wolf on
# example.com gets switched off. And it must never pass having read nothing.
#
# NOTE: this file must itself pass the scan, so every fixture that IS personal
# data is assembled at run time ("/Us""ers", "@" passed separately) rather than
# written here literally. The snapshot holds only REDACTED matches.
set -uo pipefail
SD="$(cd "$(dirname "$0")" && pwd)"
S="$SD/privacy-scan.py"
# PY picks the interpreter under test. Left unset, the suite runs on python3 and
# then AGAIN on /usr/bin/python3 (3.9 on macOS) when it exists.
PY_GIVEN="${PY:-}"
PY="${PY:-python3}"
T=$(mktemp -d); pass=0; fail=0
. "$SD/expect.sh"
# The snapshot is recorded once, under python3; the 3.9 rerun checks exit codes.
if [ -z "$PY_GIVEN" ]; then expect_init "$SD/privacy-scan.expected"; expect_scrub_dir "$T" '<tmp>'; fi
export GIT_CEILING_DIRECTORIES="$(dirname "$T")"
chk() { if [ "$2" = "$3" ]; then printf '  ok    %s\n' "$1"; pass=$((pass+1));
        else printf '  FAIL  %s (got %s, wanted %s)\n' "$1" "$2" "$3"; fail=$((fail+1)); fi; }
# scan <dir> [args...] -- run from inside <dir>, so reported paths are relative.
scan() { local d="$1"; shift; ( cd "$d" && "$PY" "$S" "$@" ); }
# case_ <want> <label> <dir> [args...] -- assert the exit, and snapshot the words.
case_() {
  local want="$1" label="$2"; shift 2
  local got
  if [ -z "$PY_GIVEN" ]; then expect_capture "$label" scan "$@"; got=$EXPECT_CODE
  else scan "$@" >/dev/null 2>&1; got=$?; fi
  chk "$label" "$got" "$want"
}

U="/Us""ers"; HM="/ho""me"; AT="@"
mk() { mkdir -p "$(dirname "$T/$1")"; printf '%s\n' "$2" > "$T/$1"; }

echo "MUST FIND"
mk a/home.md "see $U/jdoe/projects/app for the build"
case_ 1 "a macOS home path" "$T/a" .
mk b/linux.sh "cd $HM/jdoe/src"
case_ 1 "a Linux home path" "$T/b" .
mk c/win.txt 'C:\Us''ers\jdoe\AppData'
case_ 1 "a Windows home path" "$T/c" .
mk d/mail.md "write to jane.doe${AT}corp.io"
case_ 1 "an email address" "$T/d" .
mk e/gh.md "jdoe${AT}users.noreply.github.com"
case_ 1 "a GitHub noreply address still names a person" "$T/e" .

# Shapes the first regex missed (red team): no trailing slash, JSON-escaped
# slashes, a name with a space or outside ASCII, a lowercase Windows path, and
# an email whose @ is URL- or HTML-encoded.
mk i/noslash.json "{\"cwd\": \"$U/jdoe\"}"
case_ 1 "a home path with NO trailing slash, at the end of a quoted string" "$T/i" .
mk j/eol.txt "workspace: $U/jdoe"
case_ 1 "a home path with no trailing slash, at the end of a line" "$T/j" .
mk k/escaped.json "{\"cwd\": \"\\$U\\/jdoe\\/app\"}"
case_ 1 "a JSON-escaped home path (\\/Users\\/name\\/)" "$T/k" .
mk l/space.md "open $U/Jane Doe/Desktop/plan.md"
case_ 1 "a home dir name with a space" "$T/l" .
mk m/accent.md "cd $U/josé/src"
case_ 1 "a non-ASCII home dir name" "$T/m" .
mk n/win.txt 'c:\us''ers\jdoe\appdata'
case_ 1 "a lowercase Windows home path" "$T/n" .
mk o/pct.txt "mailto:jane.doe%4""0corp.io"   # split: this file is scanned too
case_ 1 "an email with a URL-encoded @ (%40)" "$T/o" .
mk p/ent.html "jane.doe&#6""4;corp.io"
case_ 1 "an email with an HTML-entity @ (&#64;)" "$T/p" .

echo
echo "MUST STAY SILENT"
mk f/ok.md "you${AT}example.com, ops${AT}mail.example.org, noreply${AT}anthropic.com, x${AT}evil.example, y${AT}ci.test
$HM/runner/work and $U/Shared/x and $U/<name>/ and ~/projects
git${AT}github.com:org/repo.git and @anthropic-ai/claude-code@2.1.0 and react@18.3.1"
case_ 0 "placeholders, CI paths, package pins" "$T/f" .
# Controls for the wider patterns. /Users/ alone (docs about the folder), CI
# runners with no trailing slash, app ROUTES under /home/ (`/home/dashboard`
# is a web page, so a /home/<x> with no trailing slash is not reported), a URL
# path that merely contains /Users/, and %40 in a package spec.
mk q/ok.md "macOS keeps homes under $U/ and Linux under $HM/.
\"$HM/runner\" and \"$U/Shared\" and C:\\Us""ers\\runneradmin\\work
router.push(\"$HM/dashboard\") and https://api.example.com$U/42/profile
npm i %40scope/pkg and user%40example.com and ${AT}types/node"
case_ 0 "the wider patterns stay silent on folders, CI, routes, URLs" "$T/q" .

echo
echo "THE DENY-LIST -- the owner's private names, never published"
mk g/notes.md "the Zephyrcorp migration"
case_ 0 "CONTROL: with no deny-list, an unknown name passes" "$T/g" notes.md
printf '# comment line\n\n(?i)zephyrcorp\n' > "$T/g/.privacy-denylist"
case_ 1 "a .privacy-denylist in the scanned root is loaded by default" "$T/g" notes.md
case_ 1 "a deny-listed name is found, case-insensitively" "$T/g" notes.md --denylist "$T/g/.privacy-denylist"
mk g/zephyrcorp-plan.md "nothing inside"
case_ 1 "a deny-listed name in a FILE NAME is found" "$T/g" zephyrcorp-plan.md --denylist "$T/g/.privacy-denylist"
case_ 1 "the deny-list file itself is never scanned or reported" "$T/g" . --denylist "$T/g/.privacy-denylist"
printf '(unclosed\n' > "$T/bad-denylist"
case_ 2 "an invalid deny-list regex is a config error" "$T/g" notes.md --denylist "$T/bad-denylist"
case_ 2 "a --denylist that does not exist is a config error" "$T/g" notes.md --denylist "$T/missing"

echo
echo "FAILS CLOSED -- an unread file is not a clean file"
mkdir -p "$T/empty"
case_ 2 "zero files scanned is exit 2, never a pass" "$T/empty" .
case_ 2 "a path that does not exist scans nothing: exit 2" "$T/empty" no-such-file
mk h/a.md "fine"; mk h/b.md "fine"; chmod 000 "$T/h/b.md"
# Asserted directly, NOT snapshotted: root reads everything, so this case can
# only run for a normal user, and a snapshot that depends on the uid would fail
# in a root container (found running CI in Docker).
if [ "$(id -u)" -ne 0 ]; then
  out=$(scan "$T/h" . 2>&1); got=$?
  chk "an unreadable file is a finding" "$got" "1"
  case "$out" in *"b.md: unreadable (PermissionError), so it was NOT checked"*) m=yes ;; *) m=no ;; esac
  chk "it names the unread file and says it was NOT checked" "$m" "yes"
else
  printf '  skip  an unreadable file is a finding (running as root reads everything)\n'
fi
chmod 644 "$T/h/b.md"
crash=$(cd "$T/h" && "$PY" -c '
import importlib.util, sys
spec = importlib.util.spec_from_file_location("ps", sys.argv[1])
ps = importlib.util.module_from_spec(spec); spec.loader.exec_module(ps)
def boom(*_a): raise RuntimeError("synthetic")
ps.scan_text = boom
try:
    rc = ps.main(["."])
except SystemExit as e:
    rc = e.code
except Exception:
    rc = "raised"
print(rc)' "$S" 2>/dev/null)
# main() lets the exception out; the __main__ wrapper turns it into exit 2.
chk "CONTROL: an injected crash really raises out of main()" "$crash" "raised"
chk "a crash is exit 2, not a pass" \
  "$(cd "$T/h" && "$PY" - "$S" <<'PY' 2>/dev/null; echo $?
import sys
path = sys.argv[1]
src = open(path).read().replace("def scan_text(", "def _real_scan_text(", 1)
src = src.replace("def main(", "def scan_text(*a):\n    raise RuntimeError('synthetic')\n\n\ndef main(", 1)
sys.argv = [path, "."]
exec(compile(src, path, "exec"), {"__name__": "__main__"})
PY
)" "2"

echo
echo "GIT MODE -- the default: tracked plus untracked, never ignored"
R="$T/repo"; mkdir -p "$R"; git -C "$R" init -q
printf 'secret.txt\n.privacy-denylist\n' > "$R/.gitignore"
printf 'clean\n' > "$R/tracked.md"
git -C "$R" add -A; git -C "$R" -c user.name=t -c user.email=t${AT}example.com commit -qm init
printf 'ops %s\n' "jdoe${AT}corp.io" > "$R/secret.txt"           # ignored: never published
case_ 0 "an IGNORED file is not scanned" "$R"
printf '(?i)zephyrcorp\n' > "$R/.privacy-denylist"
printf 'Zephyrcorp\n' > "$R/untracked.md"
case_ 1 "an UNTRACKED file is scanned, with the root deny-list" "$R"
rm "$R/untracked.md"
printf 'x\n' > "$R/gone.md"; git -C "$R" add gone.md; rm "$R/gone.md"
case_ 0 "a tracked file deleted from the work tree is skipped, not unreadable" "$R"
mkdir -p "$T/nogit"
case_ 2 "outside a repo with no paths is exit 2" "$T/nogit"

if [ -z "$PY_GIVEN" ]; then
  echo
  echo "WHAT IT SAYS (snapshot)"
  expect_verify || fail=$((fail+1))
fi
rm -rf "$T"
if [ -z "$PY_GIVEN" ] && [ -x /usr/bin/python3 ]; then
  echo
  echo "=== again under /usr/bin/python3 ($(/usr/bin/python3 -V 2>&1))"
  PY=/usr/bin/python3 bash "$0" || { fail=$((fail+1)); printf '  FAIL  the suite under /usr/bin/python3\n'; }
fi
echo; echo "$pass passed, $fail failed"; [ "$fail" -eq 0 ]
