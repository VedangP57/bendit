---
name: blast-radius
description: Use before changing auth, payments, database policies, migrations, secrets, webhooks or customer data - maps what else the change reaches and states the evidence rung per claim.
paths:
  - "**/{auth,session,sessions,kms,secrets,policies,rls}/**"
  - "**/{auth,session}{.,_,-}*"
  - "**/{auth,session,Auth,Session}{Service,Options,Middleware,Manager,Provider,Client,Config,Guard,Store,Token,Utils,Helpers}*"
  - "**/*{-,_}{auth,session}.*"
  - "**/*{Auth,Session}.*"
  - "**/*{oauth,OAuth}*"
  - "**/{secret,secrets,kms,policy,policies,rls}{.,_,-}*"
  - "**/*{-,_}{secret,secrets,kms,rls,policies}.*"
  - "**/*.{rls,policy,policies}.*"
  - "**/{m,M}iddleware*"
  - "**/migrations/**"
  - "**/*webhook*"
  - "**/*{payment,billing,stripe}*"
  - "**/.env*"
  - ".github/workflows/**"
---

# Blast Radius

A blast-radius writeup that sounds right is worthless: it reads as convincing whether or not it is true. Cite or mark unknown.

## Map before you change

1. **Who calls this?** Grep every importer. Count them. Name the surprising ones.
2. **What runs with elevated privilege?** A privileged client that bypasses row-level authorization reaching a new caller is the highest-severity change you can make. Trace it to the boundary.
3. **What crosses to the client?** Anything under a public env prefix (`NEXT_PUBLIC_`, `VITE_`, `EXPO_PUBLIC_`, `PUBLIC_`) is compiled into the browser or app bundle and is public, permanently, for every build that shipped it. A credential there is not a config choice.
4. **What is triggered, not called?** Cron routes, webhooks, database triggers and scheduled jobs have no call site to grep. Search for the route path, not the function.
5. **What is irreversible?** Deletes, emails sent, charges taken, migrations applied. Those need rung 4 or 5 evidence before running, not after.

## State evidence per claim

For each thing you assert about reach, give the rung:

1. said (I said so)
2. pointed at the line (read it this session)
3. showed the bad case cannot happen
4. ran it and read the output
5. reproduced it in the running app

`api/widgets/route:12 - POST, checks session before work, writes via the privileged client [rung 2: read the file]`

Never round up. Anything you did not check gets written as a question, not an assumption.

## When the change touches a database

Reading policies is not proof. See `references/database.md`.

## Scope discipline

A change scoped to one concern stays scoped to one concern. If you find something else wrong, write it down and keep going; do not fold it in. Unrelated work inside a change is invisible to review and is how a dependency bump ships a refactor.
