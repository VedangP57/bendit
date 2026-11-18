---
name: subtract-before-you-add
description: Use before adding a file, dependency, abstraction, config option or rule.
---

# Subtract Before You Add

Sequence removal before construction. The cheapest version of most changes is a deletion (layer L0 of the ladder).

## Ask first

1. **Does this already exist?** Grep before you write. Duplicate helpers never start as duplicates: each copy was once "just a quick one".
2. **Would deleting something solve this?** A dead config file, a duplicate path, an unused option: removing it is often the whole fix. Configuration that looks live and is not is the commonest trap, so confirm a config file is actually read before editing it.
3. **Is the new thing a second way to do something there is already one way to do?** Then you are not adding a feature, you are adding a fork. Extend the existing path or replace it; do not run both.
4. **What is the per-change cost?** A rule, a skill and a config option each cost attention on every future change, forever.

## When you do add

- Add it in one place, exported once.
- Delete what it replaces in the same change. "Migrate callers later" means never, and now there are two.
- If you cannot delete the old one yet, mark it `@deprecated` and make the linter say so.

## Copy-then-drift

Copying a config, command or helper into a second project creates two things that drift silently, and nobody knows which is correct. If something belongs in more than one project, it belongs in one shared place (a package, a plugin) that each project consumes.
