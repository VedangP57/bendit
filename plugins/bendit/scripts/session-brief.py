#!/usr/bin/env python3
"""Session brief: where this repo stands, for a fresh Claude Code session.

    python3 session-brief.py --cwd <dir> [--budget 1.8]

prints exactly one JSON line {"context": ..., "toast": ...} and exits 0, always.

    python3 session-brief.py --hook

is the SessionStart command hook: it reads the hook's JSON on stdin and prints
Claude Code's hook output (additionalContext plus a systemMessage) only for a
startup or clear in a project whose .claude/bendit.json turns `session-brief`
on; otherwise nothing. It exits 0, always.

CONFIG. The project's .claude/bendit.json, read from the MAIN checkout (the
folder that holds `git rev-parse --git-common-dir`), so every worktree of a
repo shares one file. The feature's optional "brief" object (validated by
features.py, defaults in DEFAULTS below):

    env_files       env files to read probe_env_vars from, highest priority first
    probe_env_vars  env vars holding a URL whose host:port is probed (DNS + TCP)
    local_ports     localhost ports probed (TCP)
    docs_glob       docs (relative to the repo root) checked for mentions of
                    this branch's changed files; null = no docs section

The brief is advice, not a guard: a malformed bendit.json is an alarm IN the
brief (and the defaults are used, which probe nothing), never silence and
never a traceback.

The brief's one promise is that nothing it could not verify is stated as a
fact. So every probe returns a Probe whose state is ok, failed or unknown -- a
timeout or a git error is never flattened into "nothing to report" or "no" --
and the text built on top prints failed/unknown as exactly that.

Read-only by construction: git runs with --no-optional-locks, and nothing here
fetches, writes into a repo, or talks to GitHub. The only network traffic is
the DNS/TCP liveness probes a repo's config lists; with nothing listed (the
default) there is none.

Standard library only; Python 3.9 compatible.
"""
import argparse
import glob
import json
import os
import re
import socket
import subprocess
import sys
import threading
import time
from concurrent.futures import ThreadPoolExecutor, wait
from typing import NamedTuple

# Imported here, not at the call: a missing or broken features.py must not
# become a traceback at session start (hook_main's catch-all turns the None
# into silence plus one stderr line; --cwd into "brief unavailable").
try:
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import features  # noqa: E402
except Exception:  # noqa: BLE001
    features = None


class Probe(NamedTuple):
    state: str  # 'ok' | 'failed' | 'unknown'
    value: "str | None" = None
    reason: "str | None" = None


def _ok(value):
    return Probe("ok", value, None)


def _failed(reason):
    return Probe("failed", None, reason)


def _unknown(reason):
    return Probe("unknown", None, reason)


def git(cwd, *args, timeout=1.5):
    """Run git in cwd. Stdout is returned unstripped: -z output is NUL-framed."""
    try:
        r = subprocess.run(["git", "--no-optional-locks", *args], cwd=cwd,
                           capture_output=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return _unknown(f"timed out after {timeout:g}s")
    except OSError as e:  # git missing, or cwd is not a directory
        return _failed(f"could not run git: {e}")
    if r.returncode != 0:
        err = r.stderr.decode("utf-8", "replace").strip().splitlines()
        return _failed(f"git exited {r.returncode}: {err[0] if err else ''}")
    return _ok(r.stdout.decode("utf-8", "replace"))


class Status(NamedTuple):
    branch: "str | None"
    oid: "str | None"
    upstream: "str | None"
    ahead: "int | None"
    behind: "int | None"
    entries: list


def parse_status_v2(z):
    """Parse `git status --porcelain=v2 -z --branch --untracked-files=all`.

    -z is what keeps paths with spaces or non-ASCII bytes intact. A rename
    (type 2) is followed by an extra NUL-separated record holding the old path.
    """
    branch = oid = upstream = ahead = behind = None
    entries = []
    recs = z.split("\0")
    i = 0
    while i < len(recs):
        rec = recs[i]
        i += 1
        if not rec:
            continue
        if rec.startswith("# "):
            key, _, val = rec[2:].partition(" ")
            if key == "branch.oid" and val != "(initial)":
                oid = val
            elif key == "branch.head":
                # A stopped rebase also reports (detached), so None covers both.
                branch = None if val == "(detached)" else val
            elif key == "branch.upstream":
                upstream = val
            elif key == "branch.ab":
                m = re.match(r"\+(\d+) -(\d+)$", val)
                if m:
                    ahead, behind = int(m.group(1)), int(m.group(2))
        elif rec[0] == "1":
            parts = rec.split(" ", 8)
            entries.append((parts[1], parts[8]))
        elif rec[0] == "2":
            parts = rec.split(" ", 9)
            orig = recs[i] if i < len(recs) else "?"
            i += 1
            entries.append((parts[1], f"{orig} -> {parts[9]}"))
        elif rec[0] == "u":
            parts = rec.split(" ", 10)
            entries.append((parts[1], parts[10]))
        elif rec[0] == "?":
            entries.append(("??", rec[2:]))
        # '!' (ignored) is not requested, and anything else is skipped rather
        # than guessed at.
    return Status(branch, oid, upstream, ahead, behind, entries)


def on_remote(cwd, branch):
    """Whether origin has the branch, independent of any configured upstream."""
    try:
        r = subprocess.run(["git", "--no-optional-locks", "show-ref", "--verify",
                            "--quiet", f"refs/remotes/origin/{branch}"],
                           cwd=cwd, capture_output=True, timeout=1.5)
    except subprocess.TimeoutExpired:
        return _unknown("timed out after 1.5s")
    except OSError as e:
        return _failed(f"could not run git: {e}")
    if r.returncode == 0:
        return _ok("yes")
    if r.returncode == 1:
        return _ok("no")
    err = r.stderr.decode("utf-8", "replace").strip().splitlines()
    return _failed(f"git exited {r.returncode}: {err[0] if err else ''}")


def unpushed(cwd, ref):
    """Commits on ref that no remote-tracking ref contains."""
    p = git(cwd, "rev-list", "--count", ref, "--not", "--remotes")
    if p.state != "ok":
        return p
    return _ok(str(int(p.value.strip())))


def _within(fn, deadline):
    """Run fn in a daemon thread; (finished, result, exception)."""
    box = {}

    def run():
        try:
            box["r"] = fn()
        except Exception as e:  # reported to the caller, not swallowed
            box["e"] = e

    t = threading.Thread(target=run, daemon=True)
    t.start()
    t.join(deadline)
    return (not t.is_alive()), box.get("r"), box.get("e")


def reach(host, port, deadline=0.8):
    """Can we resolve host, then connect to ANY of its addresses, within
    deadline for each of the two steps?

    Every address is tried, under one deadline for all of them: "localhost"
    resolves to ::1 and 127.0.0.1, and a service listening on only one of them
    is up. failed means every address refused or was unreachable; an attempt
    that timed out with none succeeding is unknown, never failed.
    """
    done, addrs, err = _within(lambda: socket.getaddrinfo(host, port, type=socket.SOCK_STREAM), deadline)
    if not done:
        return _unknown(f"lookup timed out after {deadline:g}s")
    if err is not None or not addrs:
        return _failed(f"could not resolve {host} — offline, or the project no longer exists; can't tell which")
    end = time.monotonic() + deadline

    def connect():
        timed_out = False
        for addr in addrs:
            left = end - time.monotonic()
            if left <= 0:
                return "timeout"
            try:
                socket.create_connection(addr[4][:2], timeout=left).close()
                return "ok"
            except (TimeoutError, socket.timeout):
                # (socket.timeout is a distinct class before Python 3.10, and an
                # OSError, so it is caught first.) No answer is not "refused".
                timed_out = True
            except OSError:
                pass  # refused or unreachable: try the next address
        return "timeout" if timed_out else "refused"

    done, result, err = _within(connect, deadline + 0.2)
    if not done or result == "timeout":
        return _unknown(f"connection to {host}:{port} timed out after {deadline:g}s")
    if err is not None:  # not an OSError, so not evidence the service is down
        return _unknown(f"connection to {host}:{port} not checked: {type(err).__name__}: {err}")
    if result == "refused":
        return _failed(f"{host}:{port} refused or unreachable")
    return _ok("reachable")


# dotenv's line grammar (the `dotenv` package's): optional `export `, key, then
# `=` with optional spaces around it or `:` and a space. A line starting with
# `#` matches nothing, so it is a comment.
ENV_LINE = re.compile(r"^\s*(?:export\s+)?([\w.-]+)(?:\s*=\s*|:\s+)(.*)$")
ENV_QUOTED = re.compile(r"""^(['"`])(.*?)\1""")


def _env_line_value(rest):
    """A value is quoted (quotes removed, ` #` kept) or runs up to ` #`."""
    q = ENV_QUOTED.match(rest)
    if q:
        return q.group(2)
    if rest.startswith("#"):  # `KEY= # note`: the separator ate the space
        return ""
    return re.split(r"\s#", rest, maxsplit=1)[0].rstrip()


def env_value(root, files, var, read=None):
    """var's value from the FIRST file in `files` that sets it (files are in
    priority order, highest first: [".env.local", ".env"] means .env.local
    wins, as dotenv loaders treat it); within that file the last assignment
    wins. None if no file sets it.

    None means "not set" and nothing else: a missing file is skipped, but any
    other read error (permissions, a directory, ...) raises OSError so the
    caller can report unknown instead of a false "not set". The names of the
    files actually read are appended to `read`, when given.
    """
    for name in files:
        try:
            with open(f"{root}/{name}", encoding="utf-8", errors="replace") as fh:
                lines = fh.read().splitlines()
        except FileNotFoundError:
            continue
        if read is not None:
            read.append(name)
        found = None
        for line in lines:
            m = ENV_LINE.match(line)
            if m and m.group(1) == var:
                found = _env_line_value(m.group(2))
        if found is not None:
            return found
    return None


# --- the brief ---------------------------------------------------------------
# Sections are small functions that each return a dict keyed by cut rank:
#   "alarms"  rank 1, never cut: failed/unknown probes, unreadable config or
#             env files, and any section that failed, raised or timed out as a whole
#   2         branch, push state, uncommitted count  -- never cut
#   3 4 5 6   file names, other worktrees, commits, feature docs -- cut 6 first
# A section that raises or misses the deadline becomes an alarm saying so; it
# never silently drops out, because a missing line reads as "nothing there".
# A single item's unknown (one worktree, the push line, the commits or docs
# line) stays in its own section; the toast still counts it, so the toast never
# says "no alarms" while anything in the brief is unknown, shown or cut.

HEADER = ("Session brief — snapshot taken {when}. Where it disagrees with live git "
          "or files, trust the live state and say so. Lines marked unknown were not "
          "checked successfully; treat them as unknown, not as no.")
CAP = 2000
TOAST_CAP = 120
ALARM_MAX = 300  # characters per alarm line, when alarms alone are over CAP
MARGIN = 0.05  # inner pools finish this long before the overall deadline
# What an absent "brief" key means. Nothing is probed unless it is listed.
DEFAULTS = {"env_files": [".env.local", ".env"], "probe_env_vars": [], "local_ports": [], "docs_glob": None}
STATUS_ARGS = ("status", "--porcelain=v2", "-z", "--branch", "--untracked-files=all")
TEMP_ROOTS = ("/tmp/", "/private/tmp/", "/var/folders/", "/private/var/folders/")
DOCS_MAX = 500          # docs checked per run; the rest are reported unknown
DOC_READ_MAX = 1000000  # characters read per doc; a longer doc is not fully checked
DEFAULT_PORTS = {"https": 443, "http": 80, "postgres": 5432, "postgresql": 5432}
CUT_NAMES = {6: "feature docs", 5: "this branch's commits", 4: "other worktrees", 3: "uncommitted file names"}


class Alarm(NamedTuple):
    line: str   # as it appears in the brief
    short: str  # as it appears in the toast


def _alarm(tag, text, short=None):
    return Alarm(f"{tag} {text}", short or text)


def _left(end):
    return max(0.0, end - time.monotonic())


def _plural(n, word):
    return f"{n} {word}{'' if n == 1 else 's'}"


def _more(shown, total):
    return [f"  +{total - shown} more"] if total > shown else []


def _show_path(path):
    home = os.path.expanduser("~")
    shown = "~" + path[len(home):] if home != "/" and (path + "/").startswith(home + "/") else path
    real = os.path.realpath(path)
    if any((p + "/").startswith(TEMP_ROOTS) for p in (path, real)):
        shown += " ⚠ temp folder, can be wiped"
    return shown


def push_line(cwd, st):
    # Every negative here is qualified: nothing is fetched, so "not on origin"
    # only ever means "not in the remote-tracking refs from the last fetch".
    if st.branch is None:
        p = unpushed(cwd, "HEAD")
        if p.state != "ok":
            return f"[git] Push: unknown ({p.reason})"
        return f"[git] Push: detached HEAD; {_plural(int(p.value), 'commit')} on no remote (as of the last fetch)."
    if st.upstream:
        if st.ahead is not None:
            return f"[git] Push: {st.upstream} ahead {st.ahead}, behind {st.behind} as of the last fetch."
        return (f"[git] Push: upstream {st.upstream} is gone as of the last fetch (often the "
                "remote branch was deleted after a merge). Not fetched now.")
    p = on_remote(cwd, st.branch)
    if p.state != "ok":
        return f"[git] Push: unknown ({p.reason})"
    if p.value == "yes":
        return f"[git] Push: on origin as origin/{st.branch}, but no upstream is set."
    return "[git] Push: not on origin (as of the last fetch)."


def sec_here(cwd, end):
    p = git(cwd, *STATUS_ARGS, timeout=_left(end))
    if p.state != "ok":
        return {"alarms": [_alarm("[git]", f"Branch and uncommitted files: unknown ({p.reason})")]}
    st = parse_status_v2(p.value)
    n = len(st.entries)
    where = st.branch or f"detached at {(st.oid or 'no commit')[:7]}"
    out = {"branch": st.branch or "HEAD", "count": str(n),
           2: [f"[git] Branch: {where} — {_plural(n, 'uncommitted file')}.", push_line(cwd, st)]}
    if n:
        names = ", ".join(f"{xy} {path}" for xy, path in st.entries[:8])
        out[3] = [f"[git] Uncommitted: {names}" + (f", +{n - 8} more" if n > 8 else "")]
    return out


def _host_port(value):
    """(host, port) from a URL (callers pass only values containing "://"). Never raises, and never looks
    inside the userinfo: a password is skipped by position, not parsed.

    Not urlsplit: an unencoded `[...]` in a password (`admin:[tok]@db...`) made
    it raise on 3.14, so the probe read "unknown (ValueError ...)" and lost its
    time stamp.
    """
    scheme, sep, rest = value.partition("://")
    if not sep:
        scheme, rest = "", value
    scheme = scheme.lower()
    auth = re.split(r"[/?#]", rest, maxsplit=1)[0]
    auth = auth.rpartition("@")[2]  # everything up to the LAST @ is userinfo
    if auth.startswith("["):  # [IPv6]:port
        host, _, tail = auth[1:].partition("]")
        port_s = tail[1:] if tail.startswith(":") else ""
    else:
        host, _, port_s = auth.partition(":")
    port = int(port_s) if port_s.isdigit() and 0 < int(port_s) < 65536 else None
    if port is None and not port_s:
        port = DEFAULT_PORTS.get(scheme)
    return host.strip().lower() or None, port


def _probe_lines(label, short_label, p, stamp):
    if p.state == "ok":
        return {2: [f"[probe {stamp}] {label}: reachable"]}
    if p.state == "unknown":
        return {"alarms": [_alarm(f"[probe {stamp}]", f"{label} unknown ({p.reason})",
                                  f"{short_label}: unknown ({p.reason})")]}
    short = (f"{short_label}: can't resolve host — offline or gone, can't tell which"
             if p.reason.startswith("could not resolve") else f"{short_label}: {p.reason}")
    return {"alarms": [_alarm(f"[probe {stamp}]", f"{label} failed: {p.reason}", short)]}


def sec_env_probe(root, files, var, end, why=None):
    if root is None:  # the env files' folder is not known, so "not set" can't be either
        return {"alarms": [_alarm("[files]", f"{var}: unknown (repo root unknown: {why})")]}
    read = []
    try:
        value = env_value(root, files, var, read)
    except OSError as e:  # not "not set": the file exists and could not be read
        return {"alarms": [_alarm("[files]", f"{var}: unknown (could not read env files: {type(e).__name__}: {e})")]}
    if value is None:
        if not files:
            return {2: [f"[files] {var}: not set in (no env files configured)"]}
        if not read:
            return {2: [f"[files] {var}: not set (no {', '.join(files)} present)"]}
        return {2: [f"[files] {var}: not set in {', '.join(read)}"]}
    if "://" not in value:  # not a URL: it may be a secret, so neither parse nor print it
        return {"alarms": [_alarm("[files]", f"{var} is not a URL; not probed")]}
    host, port = _host_port(value)
    if not host or not port:
        return {"alarms": [_alarm("[files]", f"{var}: unknown (no host and port in its value)")]}
    stamp = time.strftime("%H:%M")
    # Only host:port is ever printed: the value may carry credentials.
    p = reach(host, port, deadline=min(0.8, max(0.05, _left(end) / 2.5)))
    return _probe_lines(f"{var} ({host}:{port})", var, p, stamp)


def sec_port(port, end):
    stamp = time.strftime("%H:%M")
    # "localhost", not 127.0.0.1: a dev server may listen on ::1 only.
    p = reach("localhost", port, deadline=min(0.8, max(0.05, _left(end) / 2.5)))
    return _probe_lines(f"localhost:{port}", f"localhost:{port}", p, stamp)


def parse_worktrees(z):
    """`git worktree list --porcelain -z` -> [{path, branch (None if detached), head}]."""
    out = []
    for rec in z.split("\0"):
        if rec.startswith("worktree "):
            out.append({"path": rec[9:], "branch": None, "head": None, "bare": False})
        elif out and rec.startswith("HEAD "):
            out[-1]["head"] = rec[5:]
        elif out and rec.startswith("branch "):
            ref = rec[7:]
            out[-1]["branch"] = ref[11:] if ref.startswith("refs/heads/") else ref
        elif out and rec == "bare":
            out[-1]["bare"] = True
    return out


def _worktree_state(w, end):
    """(uncommitted, not-on-any-remote) as Probes, for one other worktree."""
    p = git(w["path"], *STATUS_ARGS, timeout=_left(end))
    n = _ok(str(len(parse_status_v2(p.value).entries))) if p.state == "ok" else p
    # "Unfinished" includes commits on no remote: covers a push without -u and
    # a fresh branch with no commits of its own, with no special cases.
    return n, unpushed(w["path"], w["branch"] or "HEAD")


def sec_worktrees(cwd, root, end):
    p = git(cwd, "worktree", "list", "--porcelain", "-z", timeout=_left(end))
    if p.state != "ok":
        return {"alarms": [_alarm("[git]", f"Other worktrees: unknown ({p.reason})")]}
    here = os.path.realpath(root)
    others = [w for w in parse_worktrees(p.value)
              if not w["bare"] and os.path.realpath(w["path"]) != here]
    gone = [w for w in others if not os.path.isdir(w["path"])]
    live = [w for w in others if os.path.isdir(w["path"])]
    rows, unknown = [], []
    if live:
        pool = ThreadPoolExecutor(max_workers=min(16, len(live)))
        futs = [(w, pool.submit(_worktree_state, w, end - MARGIN)) for w in live]
        wait([f for _, f in futs], timeout=_left(end - MARGIN))
        pool.shutdown(wait=False)
        for w, f in futs:
            name = w["branch"] or f"detached at {(w['head'] or '?')[:7]}"
            where = _show_path(w["path"])
            if not f.done():
                unknown.append(f"{name}: unknown (timed out) — {where}")
            elif f.exception() is not None:
                e = f.exception()
                unknown.append(f"{name}: unknown ({type(e).__name__}: {e}) — {where}")
            else:
                n, m = f.result()
                bad = n if n.state != "ok" else m if m.state != "ok" else None
                if bad is not None:
                    unknown.append(f"{name}: unknown ({bad.reason}) — {where}")
                elif int(n.value) or int(m.value):
                    size = int(n.value) + int(m.value)
                    rows.append((-size, name, f"{name}: {n.value} uncommitted, {m.value} not on any remote (as of the last fetch) — {where}"))
    lines = []
    if live:
        head = f"[git] Other worktrees with unfinished work: {len(rows)}"
        lines.append(head + (f" (+{len(unknown)} unknown)" if unknown else ""))
        # Unknowns first: a worktree we could not check must not hide in "+N more".
        shown = (unknown + [r[2] for r in sorted(rows)])[:5]
        lines += [f"  - {s}" for s in shown] + _more(len(shown), len(rows) + len(unknown))
    if gone:
        names = ", ".join(os.path.basename(w["path"].rstrip("/")) for w in gone)
        # isdir is also False for an unmounted volume or a permission error, so
        # this must not claim the folder was deleted.
        lines.append(f"[git] {len(gone)} worktree folder(s) missing or unreadable ({names})")
    return {4: lines}


def base_ref(cwd, end):
    p = git(cwd, "symbolic-ref", "--short", "refs/remotes/origin/HEAD", timeout=_left(end))
    if p.state == "failed" and "is not a symbolic ref" in p.reason:
        return _unknown("no origin/HEAD, so no base branch to compare with")
    return _ok(p.value.strip()) if p.state == "ok" else p


def sec_commits(cwd, end):
    b = base_ref(cwd, end)
    if b.state != "ok":
        return {5: [f"[git] Commits on this branch: unknown ({b.reason})"]}
    c = git(cwd, "rev-list", "--count", f"{b.value}..HEAD", timeout=_left(end))
    log = git(cwd, "log", "-5", "--format=%h %s", f"{b.value}..HEAD", timeout=_left(end))
    bad = c if c.state != "ok" else log if log.state != "ok" else None
    if bad is not None:
        return {5: [f"[git] Commits on this branch: unknown ({bad.reason})"]}
    n = int(c.value.strip())
    if n == 0:
        return {5: [f"[git] Commits not in {b.value}: 0."]}
    shown = log.value.strip().splitlines()
    return {5: [f"[git] Commits not in {b.value}: {n} (latest {len(shown)}):"]
               + [f"  {s}" for s in shown] + _more(len(shown), n)}


def sec_docs(cwd, root, pattern, end, why=None):
    if root is None:
        return {6: [f"[files] Feature docs: unknown (repo root unknown: {why})"]}
    b = base_ref(cwd, end)
    if b.state != "ok":
        return {6: [f"[files] Feature docs: unknown ({b.reason})"]}
    d = git(cwd, "diff", "--name-only", "-z", f"{b.value}...HEAD", timeout=_left(end))
    s = git(cwd, *STATUS_ARGS, timeout=_left(end))
    bad = d if d.state != "ok" else s if s.state != "ok" else None
    if bad is not None:
        return {6: [f"[files] Feature docs: unknown ({bad.reason})"]}
    changed = {p for p in d.value.split("\0") if p}
    changed |= {path.split(" -> ")[-1] for _, path in parse_status_v2(s.value).entries}
    needles = []
    for path in changed:
        stem = os.path.splitext(os.path.basename(path))[0]
        needles.append((path, stem if len(stem) > 5 else None))
    docs = sorted(glob.glob(os.path.join(root, pattern), recursive=True))
    # "none of N" may only count docs read to the end: a doc skipped, unreadable,
    # or cut off before a mention would otherwise become a false "none".
    scored, checked, unchecked = [], 0, max(0, len(docs) - DOCS_MAX)
    for doc in docs[:DOCS_MAX]:
        try:
            with open(doc, encoding="utf-8", errors="replace") as fh:
                text = fh.read(DOC_READ_MAX + 1)
        except OSError:
            unchecked += 1
            continue
        hits = sum(1 for path, stem in needles if path in text or (stem and stem in text))
        if hits:
            scored.append((-hits, os.path.relpath(doc, root)))
        elif len(text) > DOC_READ_MAX:
            unchecked += 1
        else:
            checked += 1
    scored.sort()
    lead = "[files] Feature docs that mention this branch's changed files: "
    if scored:
        line = lead + ", ".join(r for _, r in scored[:3]) + (f" (+{len(scored) - 3} more)" if len(scored) > 3 else "")
    else:
        line = lead + f"none of {checked}"
    if unchecked:
        line += f"; {unchecked} unknown (not checked)"
    return {6: [line]}


def _cut_to_cap(head, parts):
    """Drop whole sections, docs first, until the text fits; 1 and 2 are kept."""
    kept = dict(parts)
    cut = []

    def text():
        body = head + [line for k in (1, 2, 3, 4, 5, 6) for line in kept[k]]
        if cut:
            body.append(f"[brief] Not shown, to stay under {CAP} characters: {', '.join(cut)}.")
        return "\n".join(body)

    for k in (6, 5, 4, 3):
        if len(text()) <= CAP:
            break
        if kept[k]:
            kept[k] = []
            cut.append(CUT_NAMES[k])
    t = text()
    if len(t) <= CAP:
        return t
    # Alarms alone over the cap. Rank 2 is never cut, so the alarm block gives
    # way: long alarms are shortened, the last ones dropped, and a line says so.
    alarms = [(a if len(a) <= ALARM_MAX else a[:ALARM_MAX - 1] + "…", len(a) > ALARM_MAX) for a in kept[1]]

    def note(hidden, shortened):
        bits = ([f"{hidden} not shown"] if hidden else []) + ([f"{shortened} shortened (…)"] if shortened else [])
        return f"[brief] Alarms cut to stay under {CAP} characters: {', '.join(bits)}."

    kept[1] = []
    # Room is reserved for the longest the note can be, so it always fits.
    room = CAP - len(text()) - (len(note(len(alarms), len(alarms))) + 1)
    shown = []
    for a, short in alarms:
        if len(a) + 1 > room:
            break
        shown.append((a, short))
        room -= len(a) + 1
    kept[1] = [a for a, _ in shown] + [note(len(alarms) - len(shown), sum(s for _, s in shown))]
    t = text()
    # Reached only when rank 2 by itself is over the cap (hundreds of probe
    # lines): the cap is the hook contract, so it still holds.
    return t if len(t) <= CAP else t[:CAP - 1] + "…"


def build(cwd, config, budget):
    """(context, toast). config is load_config()'s dict; its "_alarms" are rank 1."""
    end = time.monotonic() + budget
    cfg = dict(DEFAULTS)
    cfg.update(config or {})
    alarms = list(cfg.get("_alarms") or [])
    top = git(cwd, "rev-parse", "--show-toplevel", timeout=max(0.05, budget / 4))
    # No repo root, no env files or docs to read: those sections say unknown.
    root = top.value.strip() if top.state == "ok" else None
    jobs = [("[git]", "Branch and uncommitted files", sec_here, (cwd, end))]
    for var in cfg["probe_env_vars"]:
        jobs.append(("[probe]", var, sec_env_probe, (root, cfg["env_files"], var, end, top.reason)))
    for port in cfg["local_ports"]:
        jobs.append(("[probe]", f"localhost:{port}", sec_port, (port, end)))
    jobs.append(("[git]", "Other worktrees", sec_worktrees, (cwd, root or cwd, end)))
    jobs.append(("[git]", "Commits on this branch", sec_commits, (cwd, end)))
    if cfg["docs_glob"]:
        jobs.append(("[files]", "Feature docs", sec_docs, (cwd, root, cfg["docs_glob"], end, top.reason)))

    pool = ThreadPoolExecutor(max_workers=len(jobs))
    futs = [(tag, label, pool.submit(fn, *args)) for tag, label, fn, args in jobs]
    wait([f for _, _, f in futs], timeout=_left(end))
    pool.shutdown(wait=False)  # stragglers are abandoned; main() exits without joining them

    parts = {k: [] for k in (2, 3, 4, 5, 6)}
    branch = count = "unknown"
    for tag, label, f in futs:
        if not f.done():
            r = {"alarms": [_alarm(tag, f"{label}: unknown (timed out)")]}
        elif f.exception() is not None:
            e = f.exception()
            r = {"alarms": [_alarm(tag, f"{label}: unknown ({type(e).__name__}: {e})")]}
        else:
            r = f.result()
        alarms += r.get("alarms", [])
        for k in parts:
            parts[k] += r.get(k, [])
        branch = r.get("branch", branch)
        count = r.get("count", count)
    head = [HEADER.format(when=time.strftime("%Y-%m-%d %H:%M %Z"))]
    # Counted before the cut: a cut section's unknown still reaches the toast.
    # "unknown (" is how every unknown item is written; a false match only
    # overstates, which is the safe direction for this check.
    n_unknown = sum(1 for k in parts for line in parts[k] if "unknown (" in line)
    if alarms:
        tail = alarms[0].short
    elif n_unknown:
        tail = f"{n_unknown} unknown"
    else:
        tail = "no alarms"
    toast = f"brief: {branch} · {count} uncommitted · {tail}"
    if len(toast) > TOAST_CAP:
        toast = toast[:TOAST_CAP - 1] + "…"
    parts[1] = [a.line for a in alarms]
    return _cut_to_cap(head, parts), toast


def main_checkout(cwd, timeout):
    """The folder whose .claude/bendit.json configures this session: the main
    checkout of cwd's repo (the parent of `git rev-parse --git-common-dir`), so
    a linked worktree reads the same file as the checkout it came from. Outside
    a repo (or a bare one) it is cwd itself."""
    p = git(cwd, "rev-parse", "--path-format=absolute", "--git-common-dir", timeout=timeout)
    if p.state == "ok":
        common = p.value.strip().rstrip("/")
        if os.path.basename(common) == ".git":
            return os.path.dirname(common)
    return cwd


def load_config(root):
    """(on, config). on is True, False, or None when bendit.json is malformed
    (it cannot say). config is DEFAULTS overlaid with the "brief" object, plus
    "_alarms": a malformed file is an alarm, never a silent default."""
    cfg = dict(DEFAULTS)
    try:
        data = features.load(root)
    except features.FeaturesError as e:
        cfg["_alarms"] = [_alarm("[files]", f"Brief config: unknown ({e}); this brief uses the defaults",
                                 "bendit.json is malformed")]
        return None, cfg
    entry = (data or {"features": {}})["features"].get("session-brief") or {}
    cfg.update(entry.get("brief") or {})
    cfg["_alarms"] = []
    return bool(entry.get("on")), cfg


class _Args(argparse.ArgumentParser):
    def error(self, message):  # raise into main()'s catch-all, print nothing
        raise ValueError(message)


# 1.8, not 2: interpreter start and config load come on top, and the whole
# hook must finish inside 2 s.
BUDGET = 1.8
MIN_BUILD = 0.3  # --hook: what build always gets after the config lookup


def _emit(out):
    """Print `out` (or nothing) and exit 0, whatever stdout does."""
    try:  # a closed or broken stdout must not turn into a non-zero exit
        if out is not None:
            sys.stdout.write(json.dumps(out) + "\n")
            sys.stdout.flush()
    finally:
        # Not sys.exit: that joins the pool's worker threads, and a git call
        # that outlived the budget would hold the process past it.
        os._exit(0)


HOOK_SOURCES = ("startup", "clear")  # resume, compact, fork carry their own history


def hook_main():
    """SessionStart command hook. Prints nothing unless this project turned
    the brief on: a project that did not ask for one must not get even an
    error line. A malformed bendit.json cannot say off, so it is briefed, with
    the alarm at the top."""
    # ONE deadline for the whole hook: the config lookup spends from BUDGET and
    # build gets the rest, never less than MIN_BUILD.
    start = time.monotonic()
    try:
        ev = json.loads(sys.stdin.read())
        if not isinstance(ev, dict) or ev.get("source") not in HOOK_SOURCES:
            _emit(None)
        cwd = features.project_root(ev)
        on, config = load_config(main_checkout(cwd, BUDGET - MIN_BUILD))
        if on is False:
            _emit(None)
    except BaseException as e:
        # Whether the brief is on is unknown here, so stdout stays empty (an
        # unasked-for project gets nothing); stderr names the failure for a
        # debug log.
        try:
            sys.stderr.write(f"bendit session-brief: not run: {type(e).__name__}: {e}\n")
        except BaseException:
            pass
        _emit(None)
    try:
        left = max(MIN_BUILD, BUDGET - (time.monotonic() - start))
        context, toast = build(cwd, config, left)
    except BaseException as e:  # turned on, so a failure is said, in one line
        context, toast = f"Session brief unavailable: {type(e).__name__}", "brief unavailable"
    _emit({"systemMessage": toast,
           "hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": context}})


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    if argv == ["--hook"]:
        hook_main()
    try:
        ap = _Args(prog="session-brief.py", add_help=False)
        ap.add_argument("--cwd", required=True)
        ap.add_argument("--budget", type=float, default=BUDGET)
        a = ap.parse_args(argv)
        start = time.monotonic()
        _on, config = load_config(main_checkout(a.cwd, max(0.05, a.budget - MIN_BUILD)))
        context, toast = build(a.cwd, config, max(MIN_BUILD, a.budget - (time.monotonic() - start)))
        out = {"context": context, "toast": toast}
    except BaseException as e:  # the hook must never fail, whatever went wrong
        out = {"context": f"Session brief unavailable: {type(e).__name__}", "toast": "brief unavailable"}
    _emit(out)


if __name__ == "__main__":
    main()
