#!/usr/bin/env python3
"""Fail the build when a plugin ships a hook that cannot start or a description
that is empty or too long to read in the skill listing.

    plugin-lint.py <plugin dir>

Checks, per plugin:
  1. every `command` in hooks/hooks.json: each ${CLAUDE_PLUGIN_ROOT}/<path> in it
     is an existing file inside the plugin. A hook whose script is missing does
     not fail loudly: the shell errors, the hook "passes", the guard is silently
     OFF. A path is also required to be executable when the command runs it
     directly (the path is where a command starts); a script handed to an
     interpreter (`python3 "${CLAUDE_PLUGIN_ROOT}/x.py"`) need not be.
  2. every skills/*/SKILL.md `description:` and every commands/*.md
     `description:` is non-empty and at most 300 characters.
  3. the plugin has something to lint: skills, commands or hooks.json. A plugin
     with none of them is exit 1. No hooks.json is fine (bendit-web has none).

What `claude plugin validate` already covers, and so is NOT repeated here. It was
run (claude 2.x, 2026-11-21) on a copy of this plugin whose Stop hook pointed at
scripts/does-not-exist.py, whose doctor command had a 500+ character description
and whose blast-radius skill had an empty one: it printed "Validation passed",
exit 0, for all three. It checks the manifest, lists what the plugin provides,
and (directory profile) README, LICENSE and OS files. So the checks above are
the gap, not a duplicate.

Not covered: hooks declared in plugin.json instead of hooks/hooks.json;
${CLAUDE_PLUGIN_ROOT} paths in a command's `allowed-tools`.

Exit 0 clean, 1 findings, 2 could not look (a missing/unreadable/unparseable
file, no argument). 2 is never a pass, and wins over 1: a half-read plugin is
not a verdict. Python 3.9 stdlib only.
"""
from __future__ import annotations

import json
import os
import re
import sys
from pathlib import Path

DESC_CAP = 300

# ${CLAUDE_PLUGIN_ROOT}/<path> (or the unbraced $CLAUDE_PLUGIN_ROOT/<path>). The
# path ends at whitespace, a quote, or shell punctuation, so it is read out of
# `python3 "${...}/x.py" --flag || echo '...'` without the rest.
ROOT_PATH = re.compile(r'\$\{?CLAUDE_PLUGIN_ROOT\}?/([^\s"\'`\;|&()<>]+)')
# Text before the path that makes it the program being run: start of the
# command, or just after a separator, with an optional opening quote.
RUNS_DIRECTLY = re.compile(r'(?:^|[;&|(]\s*)["\']?$')


def commands_in(node) -> list[str]:
    """Every string under a `command` key, wherever the nesting puts it."""
    out: list[str] = []
    if isinstance(node, dict):
        for k, v in node.items():
            if k == 'command' and isinstance(v, str):
                out.append(v)
            else:
                out += commands_in(v)
    elif isinstance(node, list):
        for v in node:
            out += commands_in(v)
    return out


def description_of(text: str) -> str | None:
    """The frontmatter description, folded over lines. None: no frontmatter or
    no description key. '' : the key is there and empty."""
    m = re.match(r'^---\n(.*?)\n---', text, re.S)
    if not m:
        return None
    d = re.search(r'^description:[ \t]*(.*?)(?=\n[A-Za-z_-]+:|\Z)', m.group(1), re.M | re.S)
    if not d:
        return None
    desc = ' '.join(d.group(1).split())
    desc = re.sub(r'^[>|][+-]?\s*', '', desc)
    if len(desc) >= 2 and desc[0] == desc[-1] and desc[0] in '"\'':
        desc = desc[1:-1]
    return desc


def lint(plugin: Path) -> tuple[list[str], list[str]]:
    findings: list[str] = []
    unread: list[str] = []
    root = plugin.resolve()

    def read(p: Path) -> str | None:
        try:
            return p.read_text(encoding='utf-8')
        except (OSError, UnicodeDecodeError) as e:
            unread.append(f'{p.relative_to(plugin)}: could not read it ({type(e).__name__})')
            return None

    skills = sorted(plugin.glob('skills/*/SKILL.md'))
    cmds = sorted(plugin.glob('commands/*.md'))
    hooks_json = plugin / 'hooks' / 'hooks.json'
    has_hooks = hooks_json.is_file() or hooks_json.is_symlink()
    if not skills and not cmds and not has_hooks:
        findings.append('no skills/*/SKILL.md, no commands/*.md and no hooks/hooks.json: '
                        'nothing to lint, so this is not a plugin that does anything')

    if has_hooks:
        text = read(hooks_json)
        data = None
        if text is not None:
            try:
                data = json.loads(text)
            except ValueError as e:
                unread.append(f'hooks/hooks.json: not valid JSON ({e})')
        if data is not None:
            cmdlist = commands_in(data)
            if not cmdlist:
                findings.append('hooks/hooks.json: declares no hook command')
            for cmd in cmdlist:
                for m in ROOT_PATH.finditer(cmd):
                    rel = m.group(1)
                    target = (root / rel).resolve()
                    if root != target and root not in target.parents:
                        findings.append(f'hooks/hooks.json: ${{CLAUDE_PLUGIN_ROOT}}/{rel} leaves the plugin')
                    elif not target.is_file():
                        findings.append(f'hooks/hooks.json: ${{CLAUDE_PLUGIN_ROOT}}/{rel} does not exist')
                    elif RUNS_DIRECTLY.search(cmd[:m.start()]) and not os.access(target, os.X_OK):
                        findings.append(f'hooks/hooks.json: ${{CLAUDE_PLUGIN_ROOT}}/{rel} is run '
                                        f'directly but is not executable')

    for md in skills + cmds:
        text = read(md)
        if text is None:
            continue
        rel = md.relative_to(plugin)
        desc = description_of(text)
        if desc is None:
            findings.append(f'{rel}: no description (no frontmatter at byte 0, or no description: key)')
        elif not desc:
            findings.append(f'{rel}: empty description')
        elif len(desc) > DESC_CAP:
            findings.append(f'{rel}: description is {len(desc)} characters, over {DESC_CAP}')
    return findings, unread


def main(argv: list[str]) -> int:
    if len(argv) != 1:
        print('usage: plugin-lint.py <plugin dir>', file=sys.stderr)
        return 2
    plugin = Path(argv[0])
    if not plugin.is_dir():
        print(f'plugin-lint: {plugin} is not a directory, so NOTHING was checked', file=sys.stderr)
        return 2
    findings, unread = lint(plugin)
    for u in unread:
        print(f'plugin-lint: {plugin}: {u}', file=sys.stderr)
    for f in findings:
        print(f'plugin-lint: {plugin}: {f}', file=sys.stderr)
    if unread:
        return 2
    if findings:
        return 1
    print(f'plugin-lint: {plugin}: ok')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
