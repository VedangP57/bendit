#!/usr/bin/env bash
# install-route.sh: the route decision, the credential-blocking form, and the
# refusal to re-point another project's global `bendit` marketplace entry.
set -uo pipefail
SD="$(cd "$(dirname "$0")" && pwd)"
S="$SD/install-route.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
AT=@   # built at runtime so no fixture reads as an email address
chk() { if [ "$2" = "$3" ]; then printf '  ok    %s\n' "$1"; pass=$((pass+1));
        else printf '  FAIL  %s (got [%s], wanted [%s])\n' "$1" "$2" "$3"; fail=$((fail+1)); fi; }
has() { case "$3" in *"$2"*) chk "$1" y y;; *) chk "$1 (missing '$2' in: $3)" n y;; esac; }

# stubcurl <exit> <code>: a curl that logs its argv, prints <code>, exits <exit>.
stubcurl() {
  mkdir -p "$T/bin"
  { printf '#!/bin/sh\n'
    printf '{ for a in "$@"; do printf "[%%s]" "$a"; done; echo; } >> "%s/curl.log"\n' "$T"
    printf 'printf "%%s" "%s"\nexit %s\n' "$2" "$1"; } > "$T/bin/curl"
  chmod +x "$T/bin/curl"; : > "$T/curl.log"
}
run() { PATH="$T/bin:$PATH" bash "$S" "$@"; }
SRC=https://github.com/o/r

echo "ROUTE (stub curl)"
stubcurl 0 200
out=$(run route $SRC); chk "200 -> github" "${out%% *}" "github"
log=$(cat "$T/curl.log")
has "  -q is the FIRST argument" "[-q][-fsS]" "$log"
has "  netrc disabled" "[--netrc-file][/dev/null]" "$log"
has "  asks the public git endpoint" "[https://github.com/o/r.git/info/refs?service=git-upload-pack]" "$log"
case "$log" in *"[-u]"*|*"[-H]"*|*"--user"*|*"[-n]"*) chk "  no credential flags" bad ok;; *) chk "  no credential flags" ok ok;; esac
out=$(run route https://github.com/o/r.git/); has "  .git and trailing slash accepted" "github" "$out"
stubcurl 22 401; out=$(run route $SRC); chk "401 -> vendor" "${out%% *}" "vendor"; has "  plain reason" "without signing in" "$out"
stubcurl 22 404; out=$(run route $SRC); chk "404 (private repos answer 404) -> vendor" "${out%% *}" "vendor"
stubcurl 28 000; out=$(run route $SRC); chk "timeout -> vendor" "${out%% *}" "vendor"
stubcurl 0 200
out=$(run route https://gitlab.com/o/r); chk "non-github https -> vendor" "${out%% *}" "vendor"; has "  says why" "not a public https://github.com" "$out"
out=$(run route "git${AT}github.com:o/r.git"); chk "ssh source -> vendor" "${out%% *}" "vendor"
chk "  ...and curl was not even asked" "$(cat "$T/curl.log")" ""
# R2: owner and repo are plain names; a query or fragment is not a repo.
for bad in 'https://github.com/o/r?x=1' 'https://github.com/o/r#frag' 'https://github.com/o?x/r' 'https://github.com/o/r%2F..'; do
  : > "$T/curl.log"; out=$(run route "$bad")
  chk "odd characters -> vendor: $bad" "${out%% *}" "vendor"
  chk "  ...and curl was not asked" "$(cat "$T/curl.log")" ""
done
# R1: BENDIT_PROBE_BASE is honoured only for a loopback test server.
for base in 'https://evil.example' 'http://127.0.0.1.evil.example:80' 'http://127.0.0.1:80/x' 'http://localhost:8080'; do
  : > "$T/curl.log"; out=$(BENDIT_PROBE_BASE="$base" run route $SRC)
  has "non-loopback BENDIT_PROBE_BASE ignored: $base" "[https://github.com/o/r.git/info/refs?service=git-upload-pack]" "$(cat "$T/curl.log")"
done
: > "$T/curl.log"; out=$(BENDIT_PROBE_BASE='http://127.0.0.1:4567' run route $SRC)
has "loopback BENDIT_PROBE_BASE honoured" "[http://127.0.0.1:4567/o/r.git/info/refs?service=git-upload-pack]" "$(cat "$T/curl.log")"
mkdir -p "$T/empty"; out=$(PATH="$T/empty" "$(type -P bash)" "$S" route $SRC); chk "curl missing -> vendor" "${out%% *}" "vendor"; has "  says why" "curl is not installed" "$out"

echo "ROUTE (real curl, tripwire)"
# A hostile HOME whose .curlrc and .netrc would add credentials and write a
# marker. The local server records any Authorization header and answers 401 to
# it, so an authenticated probe both shows up in the log and flips the result.
mkdir -p "$T/home"
printf 'user = "evil:pw"\nheader = "X-Tripwire: yes"\noutput = "%s/MARKER"\n' "$T" > "$T/home/.curlrc"
printf 'default login evil password pw\n' > "$T/home/.netrc"
cat > "$T/srv.py" <<PYEOF
import http.server, sys
log = sys.argv[1]
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        bad = self.headers.get("Authorization") or self.headers.get("X-Tripwire")
        open(log, "a").write("AUTH\n" if bad else "ANON\n")
        self.send_response(401 if bad else 200); self.end_headers()
    def log_message(self, *a): pass
s = http.server.HTTPServer(("127.0.0.1", 0), H)
open(log + ".port", "w").write(str(s.server_port))
s.serve_forever()
PYEOF
python3 -I "$T/srv.py" "$T/srv.log" 2>"$T/srv.err" & SRV=$!
trap 'kill $SRV 2>/dev/null; rm -rf "$T"' EXIT
# Wait (bounded, 30s: a cold CI runner can take seconds to start python) until
# the server has written its port AND accepts a connection; otherwise FAIL loudly.
READY=0
for _ in $(seq 300); do
  kill -0 $SRV 2>/dev/null || break
  if [ -s "$T/srv.log.port" ] && python3 -I -c 'import socket,sys; socket.create_connection(("127.0.0.1", int(sys.argv[1])), 2).close()' "$(cat "$T/srv.log.port")" 2>/dev/null; then READY=1; break; fi
  sleep 0.1
done
if [ "$READY" != 1 ]; then
  chk "loopback test server became ready ($(kill -0 $SRV 2>/dev/null && echo 'still starting after 30s' || echo 'exited'); stderr: $(head -c 300 "$T/srv.err" 2>/dev/null | tr '\n' ' '))" n y
  echo "pass=$pass fail=$fail"; exit 1
fi
rm -f "$T/bin/curl"
probe() { # $1 = script under test
  rm -f "$T/srv.log" "$T/MARKER"
  # CI proxies must not capture loopback (test env only; the product keeps honouring proxies).
  NO_PROXY=127.0.0.1,localhost no_proxy=127.0.0.1,localhost HOME="$T/home" BENDIT_PROBE_BASE="http://127.0.0.1:$(cat "$T/srv.log.port")" bash "$1" route $SRC
}
out=$(probe "$S")
chk "hostile ~/.curlrc and ~/.netrc: result is github" "${out%% *}" "github"
chk "  server saw an anonymous request only" "$(sort -u "$T/srv.log" 2>/dev/null)" "ANON"
chk "  .curlrc marker never written" "$([ -e "$T/MARKER" ] && echo written || echo absent)" "absent"
# Mutation: drop -q and the same test must go red (proves it can catch the leak).
sed 's/curl -q -fsS/curl -fsS/' "$S" > "$T/mutant.sh"
out=$(probe "$T/mutant.sh")
chk "mutant without -q is caught (not github, or marker written)" "$({ [ "${out%% *}" != github ] || [ -e "$T/MARKER" ] || grep -q AUTH "$T/srv.log"; } && echo caught || echo MISSED)" "caught"
printf '  (mutant: result=%s auth-seen=%s marker=%s)\n' "${out%% *}" "$(grep -c AUTH "$T/srv.log" 2>/dev/null)" "$([ -e "$T/MARKER" ] && echo written || echo absent)"
kill $SRV 2>/dev/null; wait $SRV 2>/dev/null

echo "CONFLICT"
export BENDIT_KNOWN_MARKETPLACES="$T/known.json"
chk "registry absent -> safe" "$(bash "$S" conflict https://github.com/o/r; echo "rc=$?")" "rc=0"
mkdir -p "$T/projA" "$T/projB"
printf '{"bendit":{"source":{"source":"directory","path":"%s"}}}' "$T/projA" > "$T/known.json"
out=$(bash "$S" conflict "$T/projB"); rc=$?
chk "entry points at another directory -> exit 3" "$rc" "3"
has "  names the other project" "$T/projA" "$out"
has "  plain question" "projA use this one too. Go ahead?" "$out"
chk "same directory re-add -> safe" "$(bash "$S" conflict "$T/projA"; echo "rc=$?")" "rc=0"
out=$(bash "$S" conflict https://github.com/o/r); chk "non-bendit directory entry vs github source -> exit 3" "$?" "3"
# A vendored copy of bendit in another project, replaced by the public repo:
# proceed (exit 0), and say which project switched.
V="$T/Shop/.claude/vendor/bendit"; mkdir -p "$V/.claude-plugin"
printf '{"name":"bendit"}' > "$V/.claude-plugin/marketplace.json"
printf '{"bendit":{"source":{"source":"directory","path":"%s"}}}' "$V" > "$T/known.json"
out=$(bash "$S" conflict https://github.com/o/r); rc=$?
chk "vendored bendit copy vs github source -> exit 0" "$rc" "0"
has "  says the switch, naming the project (not a path)" "switch: Your other project, Shop, uses its own copy" "$out"
has "  ...and that it may switch back" "Shop may switch back to its own copy" "$out"
case "$out" in *"$T"*) chk "  ...no path in the sentence" path none;; *) chk "  ...no path in the sentence" none none;; esac
out=$(bash "$S" conflict "$T/projB"); rc=$?
chk "vendored bendit copy vs another directory -> exit 3" "$rc" "3"
has "  names the project by its folder" "another project on this computer (Shop)" "$out"
# A bendit CHECKOUT (root marketplace also named bendit, not under
# .claude/vendor/bendit) is a working copy: moving it is a question.
W="$T/work/bendit"; mkdir -p "$W/.claude-plugin"; printf '{"name":"bendit"}' > "$W/.claude-plugin/marketplace.json"
printf '{"bendit":{"source":{"source":"directory","path":"%s"}}}' "$W" > "$T/known.json"
out=$(bash "$S" conflict https://github.com/o/r); chk "a bendit checkout (not vendored) vs github -> exit 3" "$?" "3"
printf '{"bendit":{"source":{"source":"directory","path":"%s"}}}' "$V" > "$T/known.json"
printf '{"name":"not-bendit"}' > "$V/.claude-plugin/marketplace.json"
out=$(bash "$S" conflict https://github.com/o/r); chk "directory whose marketplace is not bendit vs github -> exit 3" "$?" "3"
printf '{"bendit":{"source":{"source":"github","repo":"VedangP57/bendit"}}}' > "$T/known.json"
chk "same repo (https, .git) -> safe" "$(bash "$S" conflict https://github.com/VedangP57/bendit.git; echo "rc=$?")" "rc=0"
out=$(bash "$S" conflict https://github.com/other/fork); chk "different repo -> exit 3" "$?" "3"
has "  names the repo" "the version on GitHub (VedangP57/bendit)" "$out"
# The same repo written in another URL form is not a conflict (a git-source
# registry entry is how Claude Code records an https clone URL).
printf '{"bendit":{"source":{"source":"git","url":"https://github.com/VedangP57/bendit.git"}}}' > "$T/known.json"
for f in VedangP57/bendit https://github.com/VedangP57/bendit https://github.com/VedangP57/bendit.git \
         https://github.com/VedangP57/bendit/ "git${AT}github.com:VedangP57/bendit.git" https://github.com/vedangp57/BENDIT.git; do
  chk "git entry vs $f -> safe" "$(bash "$S" conflict "$f" >/dev/null; echo "rc=$?")" "rc=0"
done
out=$(bash "$S" conflict https://github.com/other/fork); chk "git entry vs a different repo -> exit 3" "$?" "3"
out=$(bash "$S" conflict "$T/projB"); chk "git entry vs a local path -> exit 3" "$?" "3"
printf '{"bendit":{"source":{"source":"github","repo":"VedangP57/bendit"}}}' > "$T/known.json"
chk "github entry vs git@ form -> safe" "$(bash "$S" conflict "git${AT}github.com:vedangp57/bendit.git" >/dev/null; echo "rc=$?")" "rc=0"
chk "github entry vs bare owner/repo -> safe" "$(bash "$S" conflict VedangP57/bendit >/dev/null; echo "rc=$?")" "rc=0"
printf '{"bendit":{"source":{"source":"git","url":"git%sgithub.com:VedangP57/bendit.git"}}}' "$AT" > "$T/known.json"
chk "git@ entry vs https form -> safe" "$(bash "$S" conflict https://github.com/VedangP57/bendit >/dev/null; echo "rc=$?")" "rc=0"
# Local path vs local path: matched by realpath (a symlink is the same place).
ln -sfn "$T/projA" "$T/linkA"
printf '{"bendit":{"source":{"source":"directory","path":"%s"}}}' "$T/linkA" > "$T/known.json"
chk "directory entry via symlink vs real path -> safe" "$(bash "$S" conflict "$T/projA" >/dev/null; echo "rc=$?")" "rc=0"
# A URL with credentials in the registry is never echoed.
printf '{"bendit":{"source":{"source":"git","url":"https://alice:s3cretTOKEN@example.com/x/y.git"}}}' > "$T/known.json"
out=$(bash "$S" conflict https://github.com/VedangP57/bendit); rc=$?
chk "git entry with credentials vs github -> exit 3" "$rc" "3"
case "$out" in *s3cretTOKEN*|*alice*) chk "  ...no credentials in the output" leaked none;; *) chk "  ...no credentials in the output" none none;; esac
printf '{"bendit":{"source":{"source":"git","url":"https://alice:s3cretTOKEN%sgithub.com/other/fork.git"}}}' "$AT" > "$T/known.json"
out=$(bash "$S" conflict https://github.com/VedangP57/bendit); rc=$?
chk "github git entry with credentials, other repo -> exit 3" "$rc" "3"
case "$out" in *s3cretTOKEN*|*alice*) chk "  ...no credentials in the output" leaked none;; *) chk "  ...no credentials in the output" none none;; esac
printf '{"bendit":{"source":{"source":"git","url":"https://alice:s3cretTOKEN%sgithub.com/VedangP57/bendit.git"}}}' "$AT" > "$T/known.json"
out=$(bash "$S" conflict https://github.com/VedangP57/bendit 2>&1); chk "credentials form of the same repo -> safe" "$?" "0"
case "$out" in *s3cretTOKEN*) chk "  ...no credentials in the output" leaked none;; *) chk "  ...no credentials in the output" none none;; esac
# Malformed entries fail closed, never "no conflict".
for bad in '{"bendit":{"source":"https://github.com/VedangP57/bendit"}}' '{"bendit":{"source":{"source":"git"}}}' \
           '{"bendit":{"source":{"source":"git","url":42}}}' '{"bendit":{"source":{"source":"github","repo":["a"]}}}' '[1,2]'; do
  printf '%s' "$bad" > "$T/known.json"
  out=$(bash "$S" conflict https://github.com/VedangP57/bendit); rc=$?
  chk "malformed registry $bad -> exit 3" "$rc" "3"
  [ -n "$out" ] || chk "  ...with a plain message" empty message
done
# Lookalikes: Kelvin sign (U+212A) and dotless i (U+0131) must not fold to ASCII.
printf '{"bendit":{"source":{"source":"github","repo":"kelvin/bendit"}}}' > "$T/known.json"
out=$(bash "$S" conflict "https://github.com/$(printf '\xe2\x84\xaa')elvin/bendit"); chk "Kelvin sign owner is not k -> exit 3" "$?" "3"
printf '{"bendit":{"source":{"source":"github","repo":"VedangP57/bendit"}}}' > "$T/known.json"
out=$(bash "$S" conflict "https://g$(printf '\xc4\xb1')thub.com/VedangP57/bendit"); chk "dotless i host is not github.com -> exit 3" "$?" "3"
out=$(bash "$S" conflict "https://github.com/VedangP57/bend$(printf '\xc4\xb1')t"); chk "dotless i repo -> exit 3" "$?" "3"
printf '{"bendit":{"source":{"source":"github","repo":"VedangP57/bendit"}}}' > "$T/known.json"
out=$(bash "$S" conflict $'https://github.com/VedangP57/bendit\n'); chk "trailing newline is not the same source -> exit 3" "$?" "3"
out=$(bash "$S" conflict $'VedangP57/bendit\n'); chk "bare form with trailing newline stays a path -> exit 3" "$?" "3"
# Bare owner/repo: one slash, no leading . or /; the current directory is irrelevant.
mkdir -p "$T/cwd/VedangP57/bendit"
chk "bare owner/repo is github even if a same-named dir exists" "$(cd "$T/cwd" && bash "$S" conflict VedangP57/bendit >/dev/null; echo "rc=$?")" "rc=0"
out=$(bash "$S" conflict ./VedangP57/bendit); chk "./owner/repo is a path -> exit 3" "$?" "3"
printf '{"other-kit":{}}' > "$T/known.json"
chk "no bendit entry -> safe" "$(bash "$S" conflict "$T/projB"; echo "rc=$?")" "rc=0"
printf 'not json' > "$T/known.json"
out=$(bash "$S" conflict "$T/projB"); chk "unreadable registry -> stop (exit 3)" "$?" "3"

printf '{"bendit":{"source":{"source":"directory","path":"/x"}}}' > "$T/known.json"
mkdir -p "$T/nopy"; ln -sf "$(type -P bash)" "$T/nopy/bash"
out=$(PATH="$T/nopy" "$T/nopy/bash" "$S" conflict "$T/projB"); chk "python3 missing -> exit 3, not 127" "$?" "3"
has "  plain message" "python3 is missing" "$out"
mkdir -p "$T/crashpy"; printf '#!/bin/sh\nexit 9\n' > "$T/crashpy/python3"; chmod +x "$T/crashpy/python3"
out=$(PATH="$T/crashpy:$PATH" bash "$S" conflict "$T/projB"); chk "python3 crashes -> exit 3" "$?" "3"
has "  plain message" "failed unexpectedly" "$out"

echo; echo "pass=$pass fail=$fail"; [ "$fail" -eq 0 ]
