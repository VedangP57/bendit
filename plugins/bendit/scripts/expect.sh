#!/usr/bin/env bash
# Snapshot ("expect test") support for this plugin's hook suites.
#
# Every hook here delivers PROSE. The exit code says only that it fired; the
# message is the whole product -- it is what an agent reads and acts on. The
# assertion suites check the exit code and throw the message away
# (`python3 "$H" >/dev/null 2>&1`), so a message could rot into nonsense with
# every assertion still green. That is the gap this file closes.
#
# The idiom, from Jane Street: do not assert what you believe the output is.
# PRINT what it was, commit that, and diff it on every run. An assertion can
# quietly measure nothing; a transcript cannot. Three checks in this plugin
# have passed while measuring nothing, and what found them was dumping the
# real output and looking at it. This mechanises that.
#
# Usage, from a *.test.sh:
#
#   . "$(dirname "$0")/expect.sh"
#   expect_init "$(dirname "$0")/post-edit-review.expected"
#   expect_scrub "$T" '<tmp>'                    # before any capture
#   expect_capture "catch returns success" python3 "$H" <<<"$payload"
#   expect_verify || fail=$((fail+1))
#
# Accept a deliberate change with `--accept` (or EXPECT_ACCEPT=1) and READ THE
# DIFF before committing it. An accepted snapshot nobody read proves nothing --
# that is the one way this technique fails, so it is the one rule it has.

# expect_init <snapshot-file>
expect_init() {
  EXPECT_SNAP="$1"
  EXPECT_TXT="$(mktemp)"
  EXPECT_SED=()
  EXPECT_BROKEN=''
  : > "$EXPECT_TXT"
}

# expect_scrub <literal-string> <replacement>
# Registers a substitution applied to every LATER capture. Anything that varies
# between runs -- temp directories, commit ids, timestamps -- must be scrubbed,
# or the diff reports noise on every run and gets accepted blind.
#
# Registering one after captures have run is refused rather than ignored: it
# would scrub the remaining cases and leave the earlier ones carrying a machine
# specific path, which reads as a passing suite on the author's machine and a
# failing one everywhere else.
#
# On macOS a temp directory needs BOTH spellings -- mktemp hands back
# /var/folders/..., and anything that resolves the path reports
# /private/var/folders/... -- so prefer expect_scrub_dir, which registers both.
expect_scrub() {
  if [ -s "$EXPECT_TXT" ]; then
    # Sticky, and checked by expect_verify. Returning non-zero was decorative:
    # no caller tested the status and no suite runs under `set -e`, so the
    # scrub was dropped, a FAIL line scrolled past, and the suite still exited
    # 0 -- the guard against a machine-specific snapshot was itself a check
    # that could not fail.
    EXPECT_BROKEN="expect_scrub \"$1\" was called after the first capture; move it directly below expect_init"
    printf '  FAIL  %s\n' "$EXPECT_BROKEN" >&2
    return 1
  fi
  EXPECT_SED+=("$1" "$2")
}

# expect_scrub_dir <dir> <replacement>
# A temp directory under every spelling it can surface under, longest first.
expect_scrub_dir() {
  local d="$1" rep="$2" real
  real="$(cd "$d" 2>/dev/null && pwd -P)" || real=""
  [ -n "$real" ] && [ "$real" != "$d" ] && expect_scrub "$real" "$rep"
  expect_scrub "$d" "$rep"
  # Some messages name only the basename (`$(basename "$cwd")`), so it is
  # scrubbed too -- but ONLY for a mktemp directory, whose name is unique.
  # A repo's basename is an ordinary word that also appears in the output
  # ("[bendit] post-edit review:"), and replacing that would mangle every message
  # the snapshot exists to protect.
  case "$(basename "$d")" in
    tmp.*) expect_scrub "$(basename "$d")" "${rep%>}-name>" ;;
  esac
}

# expect_capture <label> <command...>   (stdin is passed through to the command)
# Records the label, the exit code and stdout+stderr interleaved, and leaves
# both in EXPECT_CODE and EXPECT_OUT so the caller can assert on the same run.
# Running the hook twice -- once to assert, once to record -- would let the two
# disagree, which is the defect class this whole file is about.
expect_capture() {
  local label="$1"; shift
  local eout code i oerr oout
  oerr="$(mktemp)"; oout="$(mktemp)"
  # Streams stay APART. Merging them with 2>&1 erased the one property two of
  # these suites were built on: a PreToolUse guard and a Stop gate must put
  # their reason on STDERR, because that is the channel Claude Code feeds back
  # to the agent. With the streams merged, moving every `print(file=sys.stderr)`
  # to stdout left all 56 block-dangerous-bash assertions and the snapshot
  # green -- "blocked, no reason given" with nothing red. Labelling the streams
  # restores that, and a snapshot now records WHICH channel each line came out
  # of. It also removes an interleaving flake: merged, the recorded order came
  # from Python's buffering rather than from program order.
  "$@" >"$oout" 2>"$oerr"; code=$?
  # Read EXACTLY, trailing newlines included. `$( )` strips every trailing
  # newline, so a message that grew a blank line or lost its final newline
  # recorded identically to the old one -- the snapshot could not see it. The
  # sentinel keeps them; the transcript below shows them.
  local eerr
  eout="$(cat "$oout"; printf x)"; eout="${eout%x}"
  eerr="$(cat "$oerr"; printf x)"; eerr="${eerr%x}"
  rm -f "$oerr" "$oout"
  EXPECT_CODE=$code
  # The variables keep their old meaning -- trailing newlines removed, as
  # `$( )` would -- because suites compare them as strings. Only the
  # TRANSCRIPT needs to be exact.
  local sout="${eout%"${eout##*[!$'\n']}"}" serr="${eerr%"${eerr##*[!$'\n']}"}"
  # Raw and merged, for callers that grep either stream -- with a NEWLINE
  # between them. Plain concatenation glued the last stderr line to the first
  # stdout line ("...deniedBLOCKED..."), so a grep for a line that spans that
  # join silently found nothing. Latent today, since no hook here writes to
  # both, and a trap for the first one that does.
  if [ -n "$serr" ] && [ -n "$sout" ]; then
    EXPECT_OUT="$serr
$sout"
  else
    EXPECT_OUT="$serr$sout"
  fi
  EXPECT_STDOUT=$sout
  EXPECT_STDERR=$serr
  for ((i = 0; i < ${#EXPECT_SED[@]}; i += 2)); do
    # Quoted, so the needle is literal: these are filesystem paths, and a
    # pattern read as a glob would over-match and scrub away real output.
    eout="${eout//"${EXPECT_SED[i]}"/${EXPECT_SED[i + 1]}}"
    eerr="${eerr//"${EXPECT_SED[i]}"/${EXPECT_SED[i + 1]}}"
  done
  {
    printf '=== %s\n' "$label"
    printf 'exit %d\n' "$code"
    if [ -z "$eout" ] && [ -z "$eerr" ]; then
      printf '(silent)\n'
    else
      [ -n "$eerr" ] && { printf -- '--- stderr\n'; _expect_exact "$eerr"; }
      [ -n "$eout" ] && { printf -- '--- stdout\n'; _expect_exact "$eout"; }
    fi
    printf '\n'
  } >> "$EXPECT_TXT"
}

# _expect_exact <text>
# Prints text so its ending is visible. Output ending in one newline looks as it
# always did; each EXTRA trailing newline is an extra blank line; and output
# with no final newline is marked, the way diff marks it.
_expect_exact() {
  case "$1" in
    *$'\n') printf '%s' "$1" ;;
    *) printf '%s\n\\ no newline at end of output\n' "$1" ;;
  esac
}

# expect_verify
# Diffs the transcript against the committed snapshot. Returns 0 on a match,
# 1 on a difference or a missing snapshot.
expect_verify() {
  local name n
  name="$(basename "$EXPECT_SNAP")"
  if [ -n "${EXPECT_BROKEN:-}" ]; then
    printf '  FAIL  the snapshot was not recorded correctly: %s\n' "$EXPECT_BROKEN"
    rm -f "$EXPECT_TXT"
    return 1
  fi
  # Counted from the transcript, never from a variable: these helpers are
  # routinely called inside `$( )`, and a counter incremented in that subshell
  # is discarded when it returns -- the count would read 0 with every case
  # recorded. Appends to the file survive because the file is the filesystem.
  n="$(grep -c '^=== ' "$EXPECT_TXT")"
  # Zero cases is never a pass. Against an empty snapshot the diff is empty
  # too, and this reported "matches (0 cases)" -- a suite whose captures all
  # stopped running would have stayed green.
  if [ "$n" -eq 0 ]; then
    printf '  FAIL  no cases were captured for %s, so nothing was compared\n' "$name"
    rm -f "$EXPECT_TXT"
    return 1
  fi
  if [ "${EXPECT_ACCEPT:-0}" = 1 ]; then
    if [ -f "$EXPECT_SNAP" ] && cmp -s "$EXPECT_SNAP" "$EXPECT_TXT"; then
      printf '  ok    %s unchanged (%s cases)\n' "$name" "$n"
      rm -f "$EXPECT_TXT"
      return 0
    fi
    cp "$EXPECT_TXT" "$EXPECT_SNAP"
    rm -f "$EXPECT_TXT"
    # Accepting FAILS the run, on purpose. A recorded snapshot is a claim nobody
    # has checked yet, and the rule this file states -- read the diff before you
    # commit it -- had no mechanism behind it: a stray `EXPECT_ACCEPT=1` left
    # exported in a shell silently rewrote a committed baseline to match a
    # regression and reported "18 passed, 0 failed".
    # Now the only way to a green suite is a second run with no --accept, which
    # compares against what was just written. That second run is the review.
    printf '  ACCEPTED  %s (%s cases) -- read the diff, then re-run WITHOUT --accept\n' "$name" "$n"
    return 1
  fi
  if [ ! -f "$EXPECT_SNAP" ]; then
    printf '  FAIL  no snapshot at %s\n' "$EXPECT_SNAP"
    printf '        Run this suite with --accept to record one.\n'
    rm -f "$EXPECT_TXT"
    return 1
  fi
  # Labelled, so the diff header reads `committed` / `this run` instead of two
  # absolute paths, one of them a temp file that means nothing to the reader.
  local d; d="$(diff -u --label committed --label 'this run' "$EXPECT_SNAP" "$EXPECT_TXT")"
  if [ -z "$d" ]; then
    printf '  ok    %s matches (%s cases)\n' "$name" "$n"
    rm -f "$EXPECT_TXT"
    return 0
  fi
  printf '  FAIL  what these hooks SAY changed:\n'
  printf '%s\n' "$d" | sed 's/^/        /'
  printf '        Re-run with --accept if the new wording is what you meant.\n'
  rm -f "$EXPECT_TXT"
  return 1
}

# --accept comes from THIS SUITE'S ARGV and nowhere else. Reading it from the
# environment meant one exported variable turned every snapshot check in the
# repo into an unconditional pass and overwrote the baselines while doing it.
# Recording a snapshot is a deliberate act at a keyboard, so it is spelled as
# one, and the variable is cleared rather than inherited.
EXPECT_ACCEPT=0
case " ${*:-} " in *" --accept "*) EXPECT_ACCEPT=1 ;; esac
