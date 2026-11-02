# 0009 — Problem reports go to the owner's personal email

**Status:** Accepted (2026-11-01). Resolves #6.

## Decision
Report a Problem opens a compose-email window addressed to `basu.samit@gmail.com`,
with the diagnostics zip attached or revealed. The address is one constant,
`ProblemReport.destination` in `SceneItCore`.

## Trade-offs accepted
- The address ships inside every build and is visible to every user.
- Changing it means shipping a new release. A forwarding alias would have avoided this; revisit before a wide release.
- No GitHub-issue path, since writers are unlikely to have accounts.
