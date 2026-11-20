---
description: Set up bendit in this project with one plain question (--detailed for the step-by-step flow)
---

Use the `adopt-bendit` skill in the project the user is in. Its arguments:
$ARGUMENTS

If they contain `--detailed`, follow the skill's --detailed flow step by step,
in order. Otherwise follow its quick path (`references/quick.md`): one plain
question, then do everything it listed and nothing else.

Either way, do not call adoption complete unless every check in its "Prove it"
step passed. In the quick path, the only exception is its "almost set up: two
last steps" state: the harness approval only the person can give, and a live
check that needs a new session. Report those as the steps left, never as
passes.
