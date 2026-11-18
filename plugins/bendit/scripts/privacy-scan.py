#!/usr/bin/env python3
"""Fail when files about to be published carry personal data.

    privacy-scan.py                    scan the git repo the cwd is in
    privacy-scan.py PATH...            scan these files / directories instead
    privacy-scan.py --denylist FILE    deny-list other than <root>/.privacy-denylist

What counts as a finding, each reported as `path:line: kind: redacted-match`:

  * an absolute home path -- /Users/<name>/, /home/<name>/, C:\\Users\\<name>\\ --
    except a handful of names that belong to no one (runner, user, example...)
  * an email address, except example.com / example.org / example.net (and their
    subdomains), the reserved TLDs .example .test .invalid .localhost (RFC 2606),
    and noreply@anthropic.com
  * a match for any regex in the OPTIONAL deny-list file, one per line (`#`
    comments and blank lines ignored). That file is how an owner lists private
    names -- people, clients, repos -- without publishing the list itself: keep
    it git-ignored. It is never scanned.

Matches are printed REDACTED (first character, then ***), because CI logs are
public and a scanner that re-prints what it found leaks it a second time.

Default file set: `git ls-files` plus untracked files that are not ignored --
everything a `git add -A` would publish. A tracked file deleted from the work
tree is skipped; it is not there to publish.

Exit codes. It fails CLOSED and refuses to pass having checked nothing:
  0  every file was read and nothing was found
  1  findings, or a file that could not be read (an unread file is unchecked)
  2  usage or configuration error, or ZERO files were scanned

Standard library only; Python 3.9+.
"""
import argparse
import os
import re
import subprocess
import sys
from typing import Iterator, List, Optional, Pattern, Tuple

DENYLIST_NAME = '.privacy-denylist'

HOME_PATH = re.compile(
    r'/(?:Users|home)/([A-Za-z0-9._-]+)/'
    r'|[A-Za-z]:\\\\?Users\\\\?([A-Za-z0-9._-]+)\\')
# Directory names under /Users or /home that identify nobody: CI runners,
# system accounts, and placeholders. Placeholder FIRST names (alice, bob) are
# deliberately absent -- a real person can be called either.
HOME_ALLOW = frozenset({
    'runner', 'user', 'username', 'you', 'yourname', 'me', 'name', 'example',
    'Shared', 'linuxbrew', 'ubuntu', 'vscode', 'node', 'root', 'admin',
    'USER', 'USERNAME', 'someone', 'dev',
})

EMAIL = re.compile(r'[A-Za-z0-9._%+-]+@([A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,})')
EMAIL_ALLOW_DOMAINS = ('example.com', 'example.org', 'example.net',
                       'example', 'test', 'invalid', 'localhost')
EMAIL_ALLOW_EXACT = frozenset({'noreply@anthropic.com', 'git@github.com'})


def redact(text: str) -> str:
    return (text[:1] + '***') if text else '***'


def email_allowed(addr: str, domain: str) -> bool:
    d = domain.lower()
    if addr.lower() in EMAIL_ALLOW_EXACT:
        return True
    return any(d == a or d.endswith('.' + a) for a in EMAIL_ALLOW_DOMAINS)


def load_denylist(path: str) -> List[Tuple[int, Pattern]]:
    """[(line_no, regex)]. Absent file = no rules. Unreadable or invalid = error."""
    if not os.path.lexists(path):
        return []
    try:
        with open(path, encoding='utf-8') as f:
            lines = f.read().splitlines()
    except (OSError, UnicodeDecodeError) as exc:
        raise SystemExit(_err(f'cannot read deny-list {path} ({type(exc).__name__}); '
                              'refusing to scan without it'))
    rules = []
    for n, line in enumerate(lines, 1):
        s = line.strip()
        if not s or s.startswith('#'):
            continue
        try:
            rules.append((n, re.compile(s)))
        except re.error as exc:
            # The pattern itself is not echoed: it is private by definition.
            # Nor is re's own wording, which differs between Python versions.
            raise SystemExit(_err(f'deny-list {path} line {n} is not a valid regex '
                                  f'(at position {exc.pos})'))
    return rules


def _err(msg: str) -> int:
    print(f'privacy-scan: {msg}', file=sys.stderr)
    return 2


def git_root(cwd: str) -> Optional[str]:
    try:
        out = subprocess.run(['git', 'rev-parse', '--show-toplevel'], cwd=cwd,
                             capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.SubprocessError):
        return None
    return out.stdout.strip() if out.returncode == 0 and out.stdout.strip() else None


def git_files(root: str) -> List[str]:
    def ls(*args: str) -> List[str]:
        out = subprocess.run(['git', 'ls-files', '-z', *args], cwd=root,
                             capture_output=True, timeout=60)
        if out.returncode != 0:
            raise SystemExit(_err(f'git ls-files {" ".join(args)} failed: '
                                  f'{out.stderr.decode("utf-8", "replace").strip()}'))
        return [p for p in out.stdout.decode('utf-8', 'surrogateescape').split('\0') if p]
    deleted = set(ls('--deleted'))
    files = set(ls('--cached')) | set(ls('--others', '--exclude-standard'))
    return sorted(os.path.join(root, p) for p in files - deleted)


def walk(paths: List[str]) -> Iterator[str]:
    for p in paths:
        if os.path.isdir(p) and not os.path.islink(p):
            for d, dirs, names in os.walk(p):
                dirs[:] = sorted(x for x in dirs if x != '.git')
                for n in sorted(names):
                    yield os.path.join(d, n)
        else:
            yield p   # a missing path is yielded too, and reported unreadable


def scan_text(text: str, deny: List[Tuple[int, Pattern]]) -> Iterator[Tuple[int, str]]:
    for ln, line in enumerate(text.splitlines(), 1):
        for m in HOME_PATH.finditer(line):
            name = m.group(1) or m.group(2)
            if name not in HOME_ALLOW:
                yield ln, f'home path: {m.group(0).replace(name, redact(name), 1)}'
        for m in EMAIL.finditer(line):
            if not email_allowed(m.group(0), m.group(1)):
                local = m.group(0).split('@', 1)[0]
                yield ln, f'email: {redact(local)}@{m.group(1)}'
        for rule_no, rx in deny:
            m = rx.search(line)
            if m:
                yield ln, f'deny-list line {rule_no}: {redact(m.group(0))}'


def main(argv: List[str]) -> int:
    ap = argparse.ArgumentParser(description='Fail on personal data in files to be published.')
    ap.add_argument('paths', nargs='*', help='files or directories (default: the git repo)')
    ap.add_argument('--denylist', help=f'regex deny-list (default: <root>/{DENYLIST_NAME})')
    args = ap.parse_args(argv)

    cwd = os.getcwd()
    root = git_root(cwd)
    if args.paths:
        files = list(walk(args.paths))
    else:
        if root is None:
            return _err('not inside a git repository and no paths given, so there is nothing to scan')
        files = git_files(root)
    deny_path = args.denylist or os.path.join(root or cwd, DENYLIST_NAME)
    if args.denylist and not os.path.lexists(args.denylist):
        return _err(f'--denylist {args.denylist} does not exist')
    deny = load_denylist(deny_path)
    deny_real = os.path.realpath(deny_path)

    scanned = 0
    findings = 0
    for path in files:
        if os.path.realpath(path) == deny_real:
            continue
        shown = os.path.relpath(path, cwd)
        try:
            if os.path.islink(path):
                text = os.readlink(path)
            else:
                with open(path, 'rb') as f:
                    text = f.read().decode('utf-8', 'replace')
        except OSError as exc:
            print(f'{shown}: unreadable ({type(exc).__name__}), so it was NOT checked')
            findings += 1
            continue
        scanned += 1
        # The path is published too: a file NAMED after a private project
        # leaks it as surely as its contents do. Reported as line 0.
        for _, what in scan_text(os.path.relpath(path, root or cwd), deny):
            print(f'{shown}:0: in the file name: {what}')
            findings += 1
        for ln, what in scan_text(text, deny):
            print(f'{shown}:{ln}: {what}')
            findings += 1

    rules = f'{len(deny)} deny-list rule{"s" * (len(deny) != 1)}'
    if scanned == 0:
        print(f'privacy-scan: 0 files scanned ({findings} unreadable), so NOTHING was checked',
              file=sys.stderr)
        return 2
    print(f'privacy-scan: {scanned} file{"s" * (scanned != 1)} scanned, {rules}, '
          f'{findings} finding{"s" * (findings != 1)}', file=sys.stderr)
    return 1 if findings else 0


if __name__ == '__main__':
    try:
        sys.exit(main(sys.argv[1:]))
    except SystemExit:
        raise
    except Exception as exc:  # fail closed: a crash is never a pass
        print(f'privacy-scan: crashed ({type(exc).__name__}: {exc}), so nothing is certified',
              file=sys.stderr)
        sys.exit(2)
