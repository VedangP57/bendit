#!/usr/bin/env python3
"""Fail the build when the skill listing's per-session cost grows unnoticed.

Every skill's and every command's `description` is loaded into EVERY session,
in every repo, on every turn -- it is what the model reads to decide whether to
invoke it -- and each entry carries its listing name, `<plugin>:<name>`, too.

That is small. The point is not today's number: it is that nothing was watching
it, and the cost of a skill is paid by every session for ever while the benefit
is paid once by whoever added it. Claude Code caps the listing at a fraction of
the context window and SILENTLY TRUNCATES descriptions past it, so an unbudgeted
skill does not fail loudly -- it quietly shortens its neighbours' descriptions
until they stop triggering.

So this is a ratchet, not a limit. Going over is not forbidden; it is a decision
someone makes on purpose by raising the number here, in a commit, with a reason.

    skill-budget.py [--dir <skills dir>] [--commands <commands dir>]

Both default to this plugin's own. A commands dir that does not exist counts as
none (fixtures); a skills dir that does not exist is exit 2.

Exit 0 under budget, 1 over, 2 if it could not look (which is never a pass) --
including a SKILL.md or command whose description could not be parsed: a file
that reads as 0 characters is not a cheap entry, it is an unmeasured one.
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

TOTAL_CAP = 2800      # raise deliberately, in a commit, with a reason
PER_SKILL_CAP = 600   # one outlier crowds out the rest: past this, cut the description

PLUGIN = Path(__file__).resolve().parent.parent


def plugin_name(plugin: Path = PLUGIN) -> str:
    # The listing prefix is the plugin's manifest name. Falling back to the
    # directory name keeps the count honest (same length in the shipped layout)
    # rather than guessing a shorter one.
    try:
        name = json.loads((plugin / '.claude-plugin' / 'plugin.json').read_text())['name']
        if isinstance(name, str) and name:
            return name
    except (OSError, ValueError, KeyError, TypeError):
        pass
    return plugin.name


def description_of(md: Path) -> str | None:
    """The frontmatter `description:`, which may be folded over several lines.

    None when there is no frontmatter or no description -- the caller must
    treat that as unmeasured, never as 0.
    """
    text = md.read_text(encoding='utf-8')
    m = re.match(r'^---\n(.*?)\n---', text, re.S)
    if not m:
        return None
    fm = m.group(1)
    d = re.search(r'^description:[ \t]*(.*?)(?=\n[A-Za-z_-]+:|\Z)', fm, re.M | re.S)
    if not d:
        return None
    desc = ' '.join(d.group(1).split())
    return desc or None


def main(argv: list[str]) -> int:
    root = PLUGIN / 'skills'
    cmds = PLUGIN / 'commands'
    if '--dir' in argv:
        root = Path(argv[argv.index('--dir') + 1])
    if '--commands' in argv:
        cmds = Path(argv[argv.index('--commands') + 1])
    if not root.is_dir():
        print(f'skill-budget: {root} is not a directory, so NOTHING was measured', file=sys.stderr)
        return 2
    # --dir <plugin>/skills: the listing prefix is THAT plugin's name, not bendit's.
    owner = root.resolve().parent
    prefix = plugin_name(owner if (owner / '.claude-plugin' / 'plugin.json').is_file() else PLUGIN) + ':'
    entries = [(d.name, d / 'SKILL.md', True) for d in sorted(root.iterdir())
               if (d / 'SKILL.md').is_file()]
    if not entries:
        print(f'skill-budget: no SKILL.md under {root}, so NOTHING was measured', file=sys.stderr)
        return 2
    if cmds.is_dir():
        entries += [(p.stem, p, False) for p in sorted(cmds.glob('*.md'))]

    rows, unread = [], []
    for name, md, is_skill in entries:
        desc = description_of(md)
        if desc is None:
            unread.append(md)
            continue
        # What the listing carries: the name, then the description.
        rows.append((prefix + name, len(desc), len(prefix + name) + len(desc), is_skill))
    if unread:
        for md in unread:
            print(f'skill-budget: no description could be parsed from {md} (no '
                  f'frontmatter at byte 0? a BOM?), so it was NOT measured',
                  file=sys.stderr)
        return 2

    total = sum(r[2] for r in rows)
    over = [(name, n) for name, n, _, is_skill in rows if is_skill and n > PER_SKILL_CAP]
    for name, n, listed, is_skill in rows:
        flag = '  <-- over the per-skill cap' if is_skill and n > PER_SKILL_CAP else ''
        print(f'  {listed:5}  {name}{flag}')
    n_sk = sum(1 for r in rows if r[3])
    print(f'  {total:5}  TOTAL of {n_sk} skills + {len(rows) - n_sk} commands, '
          f'name + description, loaded every session (cap {TOTAL_CAP})')

    bad = False
    if total > TOTAL_CAP:
        print(f'skill-budget: {total} > {TOTAL_CAP}. Trim a description, or raise '
              f'TOTAL_CAP on purpose and say why in the commit.', file=sys.stderr)
        bad = True
    for name, n in over:
        print(f'skill-budget: {name} is {n} > {PER_SKILL_CAP}. A description this '
              f'long crowds out the others in the listing.', file=sys.stderr)
        bad = True
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
