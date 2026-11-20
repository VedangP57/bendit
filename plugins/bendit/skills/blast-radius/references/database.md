# Reading policies is not proof

Row-level policies are easy to misread. Settle them by running, not by reading migration SQL.

## Worked example: Postgres permissive policies

Permissive policies on one table are OR-ed. A policy whose `qual` reads as a total bypass (for example `true`) looks like a hole. But the `roles` column decides whether that `qual` ever applies: if `roles` restricts it to a privileged role such as `service_role` (Supabase is one Postgres host that uses this name; others use their own), ordinary users never hit it.

1. Print `roles` alongside `qual` and `cmd` for every policy on the table (`select policyname, roles, cmd, qual, with_check from pg_policies where tablename = '...'`).
2. Combine them: a row is visible to a principal if ANY permissive policy naming that principal's role passes.
3. Settle it by impersonating a principal that should be denied (set the role, then query) and reading the result. That is rung 4; reading the SQL is rung 2.

A P0 filed from reading migration SQL alone is as likely to be wrong as right. A failing check is more often a wrong assertion than a defect: establish which before reporting.
