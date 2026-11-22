#!/usr/bin/env python3
"""The one module that reads, validates and writes a project's .claude/bendit.json.

Format, version 1:

  {"version": 1,
   "features": {"browser-driver": {"on": true, "why": "package.json:14 next"},
                "session-brief": {"on": true, "why": "git project",
                                  "brief": {"local_ports": [3000]}}}}

The "brief" object (session-brief only) is validated key by key, see
BRIEF_KEYS: env_files and probe_env_vars are lists of strings, local_ports a
list of integers 1-65535, docs_glob a string or null; any other key, or a
wrong type, is malformed. env_files is read highest priority first (.env.local
beats .env), and probe_env_vars must name variables whose values are URLs.

primary-checkout-guard may carry "integrationBranch" (a branch name, see
_branch_name): the branch its guard protects when origin/HEAD cannot say.

A malformed file is never read as "everything off": load() raises
FeaturesError naming the file, and every caller must refuse (fail closed).
Absent is different: it means the project never chose, and is_on() is False.

Stdlib only, Python 3.9 compatible -- hooks, prove.sh and selfcheck import it.

CLI:
  features.py get  <root> <name>              prints on / off; exit 2 if malformed
  features.py set  <root> <name> on|off <why> merges, keeping other keys
  features.py show <root>                     table: feature | on/off | why
  features.py integration-branch <root> <branch>
                                              records primary-checkout-guard's
                                              integrationBranch (set the feature first)
"""
import json
import os
import sys
import tempfile

FEATURES = ('browser-driver', 'ux-design-laws', 'session-brief', 'ls-guard', 'primary-checkout-guard')
VERSION = 1
# The one extra object a feature may carry, keyed by what it is called.
_CONFIG_KEY = {'session-brief': 'brief'}


class FeaturesError(Exception):
    pass


def _str_list(v):
    return isinstance(v, list) and all(isinstance(x, str) for x in v)


def _port_list(v):
    # bool is an int subclass: `true` is not port 1.
    return isinstance(v, list) and all(
        type(x) is int and 0 < x < 65536 for x in v)


# The session brief's object: every key optional (session-brief.py holds the
# defaults), each with one type. Anything else is refused, never defaulted.
BRIEF_KEYS = {
    'env_files': (_str_list, 'a list of strings'),
    'probe_env_vars': (_str_list, 'a list of strings'),
    'local_ports': (_port_list, 'a list of integers from 1 to 65535'),
    'docs_glob': (lambda v: v is None or isinstance(v, str), 'a string or null'),
}
_CONFIG_SCHEMA = {'brief': BRIEF_KEYS}


def _branch_name(v):
    """A plain branch name: what `git worktree add -b` and a comparison with
    `git symbolic-ref --short HEAD` can take as-is. No leading '-' (it would
    read as an option), no whitespace or control characters, no '..'."""
    return (isinstance(v, str) and 0 < len(v) <= 200 and not v.startswith(('-', '/'))
            and not v.endswith(('/', '.', '.lock')) and '..' not in v and '//' not in v
            and all(c.isalnum() or c in '._/-' for c in v))


# Single values a feature may carry beside "on" and "why", each with one type.
_SCALAR_KEYS = {
    'primary-checkout-guard': {'integrationBranch': (_branch_name, 'a branch name (letters, digits, . _ / -)')},
}


def path(root):
    return os.path.join(root, '.claude', 'bendit.json')


def _validate(data, where):
    if not isinstance(data, dict):
        raise FeaturesError('%s: top level must be an object' % where)
    for k in data:
        if k not in ('version', 'features'):
            raise FeaturesError('%s: unknown top-level key %r (only "version" and "features")' % (where, k))
    if type(data.get('version')) is not int or data.get('version') != VERSION:
        raise FeaturesError('%s: "version" must be %d, got %r' % (where, VERSION, data.get('version')))
    feats = data.get('features')
    if not isinstance(feats, dict):
        raise FeaturesError('%s: "features" must be an object' % where)
    for name, entry in feats.items():
        if name not in FEATURES:
            raise FeaturesError('%s: unknown feature %r (known: %s)' % (where, name, ', '.join(FEATURES)))
        if not isinstance(entry, dict):
            raise FeaturesError('%s: feature %r must be an object' % (where, name))
        if not isinstance(entry.get('on'), bool):
            raise FeaturesError('%s: feature %r: "on" must be true or false, got %r' % (where, name, entry.get('on')))
        why = entry.get('why')
        if not isinstance(why, str) or not why.strip():
            raise FeaturesError('%s: feature %r: "why" must be a non-empty string' % (where, name))
        cfg = _CONFIG_KEY.get(name)
        scalars = _SCALAR_KEYS.get(name, {})
        for k, v in entry.items():
            if k in ('on', 'why'):
                continue
            if k in scalars:
                ok, what = scalars[k]
                if not ok(v):
                    got = repr(v)
                    raise FeaturesError('%s: feature %r: %r must be %s, got %s'
                                        % (where, name, k, what, got if len(got) <= 80 else got[:77] + '...'))
                continue
            if k != cfg:
                raise FeaturesError('%s: feature %r: unknown key %r' % (where, name, k))
            if not isinstance(v, dict):
                raise FeaturesError('%s: feature %r: %r must be an object' % (where, name, k))
            schema = _CONFIG_SCHEMA[k]
            for ck, cv in v.items():
                if ck not in schema:
                    raise FeaturesError('%s: feature %r: %r: unknown key %r (known: %s)'
                                        % (where, name, k, ck, ', '.join(sorted(schema))))
                ok, what = schema[ck]
                if not ok(cv):
                    got = repr(cv)
                    raise FeaturesError('%s: feature %r: %r: %r must be %s, got %s'
                                        % (where, name, k, ck, what, got if len(got) <= 80 else got[:77] + '...'))
    return data


def _no_duplicates(pairs):
    """object_pairs_hook: json.loads keeps the LAST of a repeated key, so a
    file that says ls-guard twice would silently mean whichever came second."""
    seen = {}
    for k, v in pairs:
        if k in seen:
            raise FeaturesError('duplicate key %r' % k)
        seen[k] = v
    return seen


def load(root):
    """The parsed, validated file; None when absent; FeaturesError when malformed."""
    p = path(root)
    try:
        with open(p, encoding='utf-8') as f:
            text = f.read()
    except FileNotFoundError:
        return None
    except (OSError, ValueError) as e:  # ValueError: bad UTF-8, NUL byte in the path
        raise FeaturesError('%s: cannot be read: %s' % (p.replace('\0', '\\0'), e))
    try:
        data = json.loads(text, object_pairs_hook=_no_duplicates)
    except FeaturesError as e:
        raise FeaturesError('%s: %s' % (p, e))
    except RecursionError:
        raise FeaturesError('%s: nested too deeply to be a bendit.json' % p)
    except ValueError as e:
        raise FeaturesError('%s: not valid JSON: %s' % (p, e))
    return _validate(data, p)


def is_on(root, name):
    if name not in FEATURES:
        raise FeaturesError('unknown feature %r (known: %s)' % (name, ', '.join(FEATURES)))
    data = load(root)
    if data is None:
        return False
    entry = data['features'].get(name)
    return bool(entry and entry['on'])


def write(root, features):
    """Atomically write {"version": 1, "features": features}; the old file survives a failure."""
    p = path(root)
    data = _validate({'version': VERSION, 'features': features}, p)
    try:
        text = json.dumps(data, indent=2, sort_keys=True) + '\n'
    except (TypeError, ValueError, RecursionError) as e:
        raise FeaturesError('%s: value cannot be written as JSON: %s' % (p, e))
    d = os.path.dirname(p)
    tmp = None
    try:
        # Keep the old file's mode (mkstemp makes 0600, which would tighten a
        # shared file); a new file gets what open() would: 0666 & ~umask.
        try:
            mode = os.stat(p).st_mode & 0o7777
        except FileNotFoundError:
            um = os.umask(0)
            os.umask(um)
            mode = 0o666 & ~um
        os.makedirs(d, exist_ok=True)
        fd, tmp = tempfile.mkstemp(prefix='.bendit.json.', suffix='.tmp', dir=d)
        os.chmod(tmp, mode)
        with os.fdopen(fd, 'w', encoding='utf-8') as f:
            f.write(text)
        os.replace(tmp, p)
        tmp = None
    except (OSError, ValueError) as e:
        raise FeaturesError('%s: could not be written (the old file is untouched): %s' % (p, getattr(e, 'strerror', None) or e))
    finally:
        if tmp is not None:
            try:
                os.unlink(tmp)
            except OSError:
                pass


def project_root(payload):
    """CLAUDE_PROJECT_DIR (where the session started), else the payload's cwd
    when it is a non-empty string, else the process cwd. A deleted cwd makes
    os.getcwd() raise: fall back to $PWD, then '.', which reads as "no file"."""
    env = os.environ.get('CLAUDE_PROJECT_DIR')
    if env:
        return env
    cwd = payload.get('cwd') if isinstance(payload, dict) else None
    if isinstance(cwd, str) and cwd:
        return cwd
    try:
        return os.getcwd()
    except OSError:
        pwd = os.environ.get('PWD')
        return pwd if pwd else '.'


def _main(argv):
    usage = ('usage: features.py get <root> <name> | set <root> <name> on|off <why> | show <root>'
             ' | integration-branch <root> <branch>')
    try:
        cmd = argv[1] if len(argv) > 1 else ''
        if cmd == 'get' and len(argv) == 4:
            print('on' if is_on(argv[2], argv[3]) else 'off')
        elif cmd == 'set' and len(argv) == 6 and argv[4] in ('on', 'off'):
            root, name, state, why = argv[2], argv[3], argv[4], argv[5]
            if name not in FEATURES:
                raise FeaturesError('unknown feature %r (known: %s)' % (name, ', '.join(FEATURES)))
            data = load(root) or {'features': {}}
            feats = data['features']
            entry = dict(feats.get(name, {}))
            entry['on'] = state == 'on'
            entry['why'] = why
            feats[name] = entry
            write(root, feats)
        elif cmd == 'integration-branch' and len(argv) == 4:
            root, branch = argv[2], argv[3]
            feats = (load(root) or {'features': {}})['features']
            if 'primary-checkout-guard' not in feats:
                raise FeaturesError('%s: set primary-checkout-guard first (features.py set %s '
                                    'primary-checkout-guard on|off <why>), then its integrationBranch'
                                    % (path(root), root))
            entry = dict(feats['primary-checkout-guard'])
            entry['integrationBranch'] = branch
            feats['primary-checkout-guard'] = entry
            write(root, feats)
        elif cmd == 'show' and len(argv) == 3:
            feats = (load(argv[2]) or {'features': {}})['features']
            rows = [('feature', 'on/off', 'why')]
            for n in FEATURES:
                e = feats.get(n)
                rows.append((n, ('on' if e['on'] else 'off') if e else 'off', e['why'] if e else '(not set)'))
            w0 = max(len(r[0]) for r in rows)
            w1 = max(len(r[1]) for r in rows)
            for r in rows:
                print('%-*s | %-*s | %s' % (w0, r[0], w1, r[1], r[2]))
        else:
            print(usage, file=sys.stderr)
            return 2
    except FeaturesError as e:
        print('features: %s' % e, file=sys.stderr)
        return 2
    except Exception as e:  # exit 1 is non-blocking to a hook: never leak one
        print('features: unexpected %s: %s' % (type(e).__name__, e), file=sys.stderr)
        return 2
    return 0


if __name__ == '__main__':
    sys.exit(_main(sys.argv))
