#!/usr/bin/env bash
# Decide how a project gets bendit, and guard the one global thing an install
# can break. Read-only: it never runs `claude plugin`, never writes anything.
#
#   install-route.sh route <source>
#       prints "github <reason>" or "vendor <reason>" (always exit 0).
#       github = anyone can fetch <source> with NO credentials, so a marketplace
#       entry in the project's settings works for teammates and fresh clones.
#       Anything else (private, offline, ssh, a local path) = vendor.
#   install-route.sh conflict <source>
#       <source> is what is about to be added: an https/ssh git URL or a
#       directory. Marketplace names are global per machine, so an existing
#       `bendit` entry that points elsewhere would be silently re-pointed.
#       exit 0 and silent: safe. exit 0 WITH a line "switch: <sentence>":
#       safe too -- the existing entry is a vendored copy of bendit in another
#       project and the new source is the public GitHub repo, so that project
#       moves to the copy everyone can download; say the sentence in the
#       report. ANY non-zero exit (3, or a crash) with a plain message: stop and
#       ask the person; it fails closed.
#       The registry is $BENDIT_KNOWN_MARKETPLACES, else
#       ~/.claude/plugins/known_marketplaces.json (absent = safe).
set -uo pipefail

route() {
  local src="${1:-}" base="https://github.com" path code
  # BENDIT_PROBE_BASE exists only so the test can aim the real curl at a local
  # tripwire server, so it is honoured for http://127.0.0.1:<port> and nothing
  # else: any other value is ignored and github.com is asked. The source must
  # still look like a github.com address.
  if [[ "${BENDIT_PROBE_BASE:-}" =~ ^http://127\.0\.0\.1:[0-9]+$ ]]; then base="$BENDIT_PROBE_BASE"; fi
  # Owner and repo are plain names (letters, digits, . _ -): a ?query, #fragment
  # or %-escape would change what curl asks for, so it is not a repo.
  if ! [[ "$src" =~ ^https://github\.com/([A-Za-z0-9._-]+)/([A-Za-z0-9._-]+)/?$ ]]; then
    printf 'vendor %s\n' "the source is not a public https://github.com address, so I cannot check it anonymously"; return 0
  fi
  path="${BASH_REMATCH[1]}/${BASH_REMATCH[2]%.git}"
  if ! command -v curl >/dev/null 2>&1; then
    printf 'vendor %s\n' "curl is not installed, so I cannot check whether bendit is public"; return 0
  fi
  # Anonymous by construction, not by git config: -q (first argument) skips
  # ~/.curlrc, --netrc-file /dev/null skips ~/.netrc, and no -u/-H is passed.
  code=$(curl -q -fsS --max-time 10 --netrc-file /dev/null -o /dev/null -w '%{http_code}' \
           "$base/$path.git/info/refs?service=git-upload-pack" 2>/dev/null </dev/null) || code="${code:-none}"
  if [ "$code" = "200" ]; then
    printf 'github %s\n' "anyone can download bendit from there without signing in"
  else
    printf 'vendor %s\n' "bendit could not be downloaded without signing in (private, offline, or moved; answer was $code)"
  fi
}

conflict() {
  local src="${1:-}" reg="${BENDIT_KNOWN_MARKETPLACES:-$HOME/.claude/plugins/known_marketplaces.json}"
  [ -f "$reg" ] || return 0
  if ! command -v python3 >/dev/null 2>&1; then
    echo "I cannot read $reg because python3 is missing, so I cannot tell whether another project already uses the name bendit."; return 3
  fi
  local out rc
  out=$(python3 -I - "$reg" "$src" <<'PY'
import json, os, re, sys
reg, src = sys.argv[1], sys.argv[2]
try:
    entry = json.load(open(reg)).get("bendit")
except Exception as e:
    print(f"I could not read {reg} ({e}), so I cannot tell whether another project already uses the name bendit.")
    sys.exit(3)
if not isinstance(entry, dict):
    sys.exit(0)
s = entry.get("source") or {}
def repo_of(u):
    m = re.match(r"^(?:https://github\.com/|git@[^:]+:)([^/]+/[^/]+?)(?:\.git)?/?$", u)
    return m.group(1) if m else u
if re.match(r"^(https://|git@)", src):
    new = ("github", repo_of(src))
else:
    new = ("directory", os.path.realpath(src))
if s.get("source") == "github":
    cur = ("github", s.get("repo") or "")
elif s.get("source") == "directory":
    cur = ("directory", os.path.realpath(s.get("path") or ""))
else:
    cur = (s.get("source"), s.get("url") or s.get("path") or "")
if cur[0] == new[0] and cur[1].lower() == new[1].lower():
    sys.exit(0)

TAIL = os.sep + os.path.join(".claude", "vendor", "bendit")

def vendored(path):
    # Only <project>/.claude/vendor/bendit is a vendored copy. A bendit
    # checkout (its root marketplace is also named bendit) is someone's working
    # copy, and moving it is a question.
    return path.rstrip(os.sep).endswith(TAIL)

def project_of(path):
    # <project>/.claude/vendor/bendit -> <project>'s folder name; else the path
    p = path.rstrip(os.sep)
    return os.path.basename(p[:-len(TAIL)]) if vendored(p) else p

def is_bendit_copy(path):
    if not vendored(path):
        return False
    try:
        return json.load(open(os.path.join(path, ".claude-plugin", "marketplace.json"))).get("name") == "bendit"
    except Exception:
        return False

if new[0] == "github" and cur[0] == "directory" and is_bendit_copy(cur[1]):
    # A vendored copy of bendit moving to the public repo loses nothing: same
    # kit, and now one anyone can download. Proceed, and say so.
    n = project_of(cur[1])
    # True whichever way Claude Code settles it: the other project's own
    # settings still name its copy, and nothing in its files is changed.
    print(f"switch: Your other project, {n}, uses its own copy of bendit. bendit on this computer "
          f"will now point at the public version on GitHub; {n} may switch back to its own copy "
          f"the next time you open Claude there. Nothing in {n}'s files changes.")
    sys.exit(0)
if cur[0] == "directory":
    name = project_of(cur[1]) if cur[1] else "a project I cannot name"
    print(f"bendit is already set up in another project on this computer ({name}) from a different copy. "
          f"Setting it up here makes {name} use this one too. Go ahead?")
else:
    where = f"the version on GitHub ({cur[1]})" if cur[0] == "github" and cur[1] else "a copy I cannot name"
    print(f"bendit is already set up on this computer from a different copy ({where}). "
          f"Setting it up here makes every project that uses that copy use this one too. Go ahead?")
sys.exit(3)
PY
  )
  rc=$?
  [ -n "$out" ] && printf '%s\n' "$out"
  case "$rc" in 0|3) return "$rc" ;; esac
  echo "Checking $reg failed unexpectedly (code $rc), so I cannot tell whether another project already uses the name bendit."; return 3
}

case "${1:-}" in
  route) route "${2:-}" ;;
  conflict) conflict "${2:-}" ;;
  *) echo "usage: install-route.sh route <source> | conflict <source>" >&2; exit 2 ;;
esac
