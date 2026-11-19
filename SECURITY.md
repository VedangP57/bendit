# Security policy

Bendit runs as hooks inside your coding agent, so a bug in it can matter more
than a bug in ordinary tooling. Two kinds are security issues:

- **A bypass:** a command, write or payload that a guard is documented to
  refuse but lets through. (Gaps already listed in a guard's own header, such
  as a command hidden behind a shell variable, are known limits, not new
  reports; a cheap way to close one is still welcome as a normal issue.)
- **A fail-open:** any input that makes a guard crash or exit in a way Claude
  Code treats as "allow".

## Reporting

Please report privately, not in a public issue: open the repository's
**Security** tab and choose **Report a vulnerability**. Include the exact
command or hook payload, what the guard returned (exit code and message), and
what you expected.

You should get a first response within a week. Fixes land with a regression
test in the guard's suite, and the report is credited in the changelog unless
you ask otherwise.

## Supported versions

Only the latest release on `main` is supported.
