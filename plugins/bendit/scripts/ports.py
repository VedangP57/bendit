#!/usr/bin/env python3
"""Resolve the port a repo's verify harness must use, from a machine-wide registry.

WHY THIS EXISTS. When every harness defaults to PORT=3000, and verify.sh
refuses to run when its port already answers -- correctly, because "something
answers on :3000" does not mean "this repo answers" -- only one verify can run
on the machine at a time, and two worktrees of one repo can never both run.

THE RULE. Each repo owns a block of `block_size` ports starting at its base.
The main checkout takes the base. A worktree is ASSIGNED the lowest port in the
block above the base that no other live worktree of the repo holds, and keeps
it: the assignment is recorded in the main checkout's
.git/bendit-ports.json (under a lock) and nothing is probed -- see
port_for for why. An unregistered repo is never quietly given 3000, because
that is the bug: `port` refuses it, and `ensure` (what verify.sh calls)
allocates it a block of its own under the lock, says so, and only refuses
when allocation genuinely fails -- the registry cannot be written, or no free
block is left below 65536.

WHERE THE REGISTRY LIVES. Per-user state never lives in the plugin folder:
  $BENDIT_CONFIG_DIR/ports.json                         when set (tests)
  ${XDG_CONFIG_HOME:-~/.config}/bendit/ports.json   otherwise
It is created, empty, on first use. A repo is keyed by the absolute path of its
MAIN checkout, so two unrelated projects that share a folder name never share
a block.

A ROOT UNDER THE SYSTEM TEMP FOLDER IS NEVER WRITTEN DOWN ($TMPDIR, /tmp,
/var/tmp). A scaffold preview or a scratch clone is gone within the hour, and
its block would stay in the registry for good. `add` and `ensure` give such a
root the port it WOULD get -- its block if it is already registered, else the
next free one -- for this run only, say so on stderr, and write nothing: not
the registry, not even an empty one, not its lock. (Its worktree assignments
still go in its own .git, which is as temporary as it is.) Tests whose
scratch repos must register set BENDIT_PORTS_REGISTER_TEMP=1.

Commands:
  port <repo-path>   print the port for that checkout      (exit 2 if unknown)
  add <repo-path>    allocate the repo's block, print it    (idempotent)
  ensure <repo-path> add if missing (one line on stderr saying so), then
                     print the port for that checkout, like `port`
  check              fail if any two blocks overlap         (exit 2 on overlap)
  audit              fail if any key is not an existing directory (exit 2)
  show               print the registry as a table
  where              print the registry's path
"""
# 3.9 is the stock macOS python3: keep `Path | None` an unevaluated annotation.
from __future__ import annotations

import fcntl
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

BLOCK_SIZE = 100
FIRST_BASE = 3100
PREFIX = '[bendit ports]'


def config_dir() -> Path:
    explicit = os.environ.get('BENDIT_CONFIG_DIR')
    if explicit:
        return Path(explicit)
    xdg = os.environ.get('XDG_CONFIG_HOME') or str(Path.home() / '.config')
    return Path(xdg) / 'bendit'


def registry_path() -> Path:
    return config_dir() / 'ports.json'


def _temp_roots() -> list[str]:
    """The system temp folders, resolved (on macOS /tmp is /private/tmp).
    Not tempfile.gettempdir(): with nothing writable it answers the cwd, and
    then every repo would count as temporary."""
    roots = []
    for r in (os.environ.get('TMPDIR'), os.environ.get('TMP'),
              os.environ.get('TEMP'), '/tmp', '/var/tmp'):
        if not r:
            continue
        r = os.path.realpath(r)
        # A TMPDIR of / would make every path temporary.
        if r != os.path.sep and r not in roots:
            roots.append(r)
    return roots


def is_temp(key: str) -> bool:
    """True when this main checkout lives under a system temp folder, so it
    must not be written to the registry."""
    if os.environ.get('BENDIT_PORTS_REGISTER_TEMP') == '1':
        return False
    k = os.path.realpath(key)
    return any(k == r or k.startswith(r + os.path.sep) for r in _temp_roots())


def die(msg: str) -> None:
    print(f'{PREFIX} {msg}', file=sys.stderr)
    sys.exit(2)


def _atomic_write(path: Path, text: str) -> None:
    """A reader never sees a half-written file, which it would reject or, worse,
    parse as empty and so forget every other assignment."""
    fd, tmp = tempfile.mkstemp(dir=str(path.parent), prefix='.' + path.name + '.')
    try:
        with os.fdopen(fd, 'w') as fh:
            fh.write(text)
        os.replace(tmp, str(path))
    except OSError:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


class _Locked:
    """flock on <file>.lock. Released when the process exits, so a crashed run
    cannot wedge it. Refuses rather than proceeding unlocked."""

    def __init__(self, target: Path):
        self.path = str(target) + '.lock'
        self.fh = None

    def __enter__(self):
        try:
            Path(self.path).parent.mkdir(parents=True, exist_ok=True)
            self.fh = open(self.path, 'a')
        except OSError as e:
            die(f'could not open the lock {self.path} ({e}). Refusing rather than '
                f'handing out a port another run may also be given.')
        fcntl.flock(self.fh, fcntl.LOCK_EX)
        return self

    def __exit__(self, *exc):
        self.fh.close()
        return False


def _validate(d, p: Path) -> dict:
    # An EMPTY repos map is allowed: that is a registry being bootstrapped, and
    # `add` has to be able to fill it. `port` still refuses an unknown repo with
    # its own message, so nothing is handed a default.
    if not isinstance(d, dict) or not isinstance(d.get('repos'), dict):
        die(f'{p} has no "repos" object. Fix it; do not fall back to a default.')
    if not isinstance(d.get('block_size'), int) or d['block_size'] < 2:
        die(f'{p} has no usable block_size.')
    return d


def load() -> dict:
    """The registry, created empty on first use (under the lock)."""
    p = registry_path()
    _ensure(p)
    return _read(p)


def _ensure(p: Path) -> None:
    if not p.exists():
        with _Locked(p):
            if not p.exists():
                try:
                    _atomic_write(p, json.dumps(
                        {'block_size': BLOCK_SIZE, 'repos': {}}, indent=2) + '\n')
                except OSError as e:
                    die(f'could not create the port registry at {p} ({e}).')


def _read(p: Path) -> dict:
    try:
        with open(p, 'rb') as fh:
            d = json.load(fh)
    except (json.JSONDecodeError, ValueError) as e:
        die(f'{p} is not valid JSON ({e}). Fix it; do not fall back to a default.')
    except OSError as e:
        die(f'could not read the port registry at {p} ({e}).')
    return _validate(d, p)


def overlaps(d: dict) -> list[str]:
    """Every pair of blocks that share a port. Empty list means disjoint."""
    size = d['block_size']
    spans = sorted((base, base + size - 1, name) for name, base in d['repos'].items())
    found = []
    for (a0, a1, an), (b0, b1, bn) in zip(spans, spans[1:]):
        if b0 <= a1:
            found.append(f'{an} [{a0}-{a1}] overlaps {bn} [{b0}-{b1}]')
    return found


def _git(start: str, *args: str) -> str:
    try:
        r = subprocess.run(['git', '-C', start, *args],
                           capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.SubprocessError) as e:
        die(f'could not ask git where this repo is ({e})')
    if r.returncode != 0:
        die(f'{start} is not inside a git repository')
    return r.stdout.strip()


def _common_dir(start: str) -> Path:
    return Path(os.path.realpath(os.path.join(start, _git(start, 'rev-parse', '--git-common-dir'))))


def toplevel(start: str) -> tuple[str, bool]:
    """(main checkout's absolute path, is_worktree).

    A worktree must resolve to its parent repo's block, not a block of its own,
    so the key comes from --git-common-dir, which points at the main
    checkout's .git in both cases.
    """
    c = _common_dir(start)
    g = Path(os.path.realpath(os.path.join(start, _git(start, 'rev-parse', '--git-dir'))))
    # Resolve both sides: on macOS /var is a symlink to /private/var, and
    # comparing one resolved path with one unresolved path silently reports
    # every checkout as a worktree.
    return str(c.parent), (c != g)


def port_for(root: str, d: dict | None = None, base: int | None = None) -> int:
    """`base` is given only for a temp root, whose block is not in `d`."""
    d = d or load()
    key, is_wt = toplevel(root)
    if base is None:
        base = d['repos'].get(key)
    if base is None:
        die(f'repo "{key}" is not in the port registry ({registry_path()}), so '
            f'it will not be assigned a port.\n'
            f'  Add it with:  python3 {os.path.realpath(__file__)} add "{key}"\n'
            f'  It is NOT given 3000: when several repos share that port, '
            f'verifying against the wrong app is worse than not verifying.')
    if not is_wt:
        return base

    # A worktree never takes the base: that belongs to the main checkout.
    #
    # ASSIGNED AND PERSISTED, NOT PROBED. "the next free port" sounds right and
    # is not: it asks what is LISTENING, so two worktrees that are not running
    # yet both get the same answer -- the very collision this registry exists
    # to end, moved one level down.
    here = os.path.realpath(root)
    store = _common_dir(root) / 'bendit-ports.json'
    # Read-pick-write is one critical section: without the lock two worktrees
    # started together both read the same file and both take base+1.
    with _Locked(store):
        return _assign(store, here, base, d['block_size'], key)


def _assign(store: Path, here: str, base: int, size: int, name: str) -> int:
    """Pick and record this worktree's port. Caller holds the lock."""
    try:
        held = json.loads(store.read_text()) if store.is_file() else {}
        if not isinstance(held, dict):
            held = {}
    except (OSError, json.JSONDecodeError, ValueError):
        held = {}

    # Drop worktrees that no longer exist, or a deleted one keeps its port
    # forever and a busy repo exhausts its block.
    held = {k: v for k, v in held.items()
            if isinstance(v, int) and os.path.isdir(k)}

    if here in held and base < held[here] < base + size:
        return held[here]

    taken = set(held.values())
    for candidate in range(base + 1, base + size):
        if candidate not in taken:
            held[here] = candidate
            try:
                _atomic_write(store, json.dumps(held, indent=2, sort_keys=True) + '\n')
            except OSError as e:
                die(f'could not record the port assignment in {store} ({e}). '
                    f'Refusing rather than handing out a port that another '
                    f'worktree may also be given.')
            return candidate
    die(f'every port in {name}\'s block [{base}-{base + size - 1}] '
        f'is assigned to a live worktree. Remove one, or widen block_size.')
    return -1  # unreachable: die exits


def _next_base(d: dict, p: Path) -> int:
    size = d['block_size']
    used = set(d['repos'].values())
    base = max(used) + size if used else FIRST_BASE
    while base in used:
        base += size
    if base + size - 1 > 65535:
        die(f'no free block left in {p}: the next one would start at {base}, '
            f'past the last TCP port. Remove keys for checkouts that are gone '
            f'(`ports.py audit` lists them).')
    return base


def _peek() -> dict:
    """The registry WITHOUT creating it or its lock: for a temp root, which
    may read but never write. A missing registry reads as an empty one."""
    p = registry_path()
    if not p.exists():
        return {'block_size': BLOCK_SIZE, 'repos': {}}
    return _read(p)


def _temp_base(key: str) -> tuple[int, dict]:
    """A temp root's base for this run: its block if registered, else the
    next free one. Writes nothing."""
    d = _peek()
    if key in d['repos']:
        return d['repos'][key], d
    base = _next_base(d, registry_path())
    print(f'{PREFIX} {key} is under the system temp folder, so it is not '
          f'registered: port block {base}-{base + d["block_size"] - 1} for '
          f'this run only. {registry_path()} is unchanged.', file=sys.stderr)
    return base, d


def add(root: str) -> int:
    key, _ = toplevel(root)
    if is_temp(key):
        return _temp_base(key)[0]
    p = registry_path()
    _ensure(p)  # takes and drops its own lock: flock is not re-entrant
    with _Locked(p):
        # Read UNDER the lock: two scaffolds run together must not both
        # read "the next base is 3200" and both take it.
        d = _read(p)
        if key in d['repos']:
            return d['repos'][key]
        base = _next_base(d, p)
        d['repos'][key] = base
        if overlaps(d):
            die('allocating that block would create an overlap; registry left '
                'unchanged')
        try:
            _atomic_write(p, json.dumps(d, indent=2, sort_keys=True) + '\n')
        except OSError as e:
            die(f'could not write the port registry at {p} ({e}).')
        return base


def ensure(root: str) -> int:
    """The port for this checkout, registering its repo first if this machine
    has never seen it. A fresh clone on a fresh machine is the normal first
    use, not an error: refusing there made every new machine need a command
    typed by hand. Allocation goes through `add`, under the registry lock, so
    two first runs together still get disjoint blocks."""
    key, _ = toplevel(root)
    if is_temp(key):
        base, d = _temp_base(key)
        return port_for(root, d, base)
    d = load()
    if key not in d['repos']:
        base = add(root)
        size = d['block_size']
        print(f'{PREFIX} first use of {key} on this machine: assigned port {base} '
              f'(block {base}-{base + size - 1}) in {registry_path()}', file=sys.stderr)
    return port_for(root)


def main(argv: list[str]) -> int:
    args = argv[1:]
    if not args:
        print(__doc__)
        return 2
    cmd = args[0]
    if cmd == 'where':
        print(registry_path())
        return 0
    if cmd == 'check':
        bad = overlaps(load())
        if bad:
            for b in bad:
                print(f'{PREFIX} OVERLAP: {b}', file=sys.stderr)
            return 2
        print(f'{PREFIX} no two blocks overlap')
        return 0
    if cmd == 'audit':
        d = load()
        # Fails CLOSED on an empty registry: "every key is real" over zero keys
        # is a pass that checked nothing.
        if not d['repos']:
            die(f'cannot audit: {registry_path()} holds no repos, so nothing was checked.')
        bad = sorted(k for k in d['repos'] if not os.path.isdir(k))
        if bad:
            for k in bad:
                print(f'{PREFIX} NOT AN EXISTING DIRECTORY: "{k}" (port {d["repos"][k]})',
                      file=sys.stderr)
            print(f'{PREFIX} a moved or deleted checkout keeps its block until '
                  f'its key is removed from {registry_path()}.', file=sys.stderr)
            return 2
        print(f'{PREFIX} all {len(d["repos"])} keys are existing directories')
        return 0
    if cmd == 'show':
        d = load()
        for name, base in sorted(d['repos'].items(), key=lambda kv: kv[1]):
            print(f'{base:>6}-{base + d["block_size"] - 1:<6} {name}')
        return 0
    if cmd == 'port':
        if len(args) < 2:
            die('port needs a repo path')
        print(port_for(args[1]))
        return 0
    if cmd == 'ensure':
        if len(args) < 2:
            die('ensure needs a repo path')
        print(ensure(args[1]))
        return 0
    if cmd == 'add':
        if len(args) < 2:
            die('add needs a repo path')
        print(add(args[1]))
        return 0
    die(f'unknown command: {cmd}')
    return 2


if __name__ == '__main__':
    sys.exit(main(sys.argv))
