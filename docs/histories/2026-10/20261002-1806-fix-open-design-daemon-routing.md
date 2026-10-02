## [2026-10-02 18:06] | Task: Fix Open Design daemon routing

### User request

Implement the next steps for making the visual handoff workflow usable with the
local Open Design daemon.

### Changes

- Require `OD_DAEMON_URL` in the Open Design child environment allowlist.
- Fail before child launch when the workflow MCP process has no daemon URL.
- Add a child-process test for allowlisted and filtered environment values.
- Make transport tests use the fake MCP executable built with the current test
  bundle instead of a stale output directory.
- Document how the workflow MCP process receives the same daemon URL as the
  direct Open Design MCP entry.
- Remove public-address, private-address, proxy, and egress checks from the
  active disposable-worker acceptance plan. Keep the earlier investigation as
  historical context.
- Update the live status: the local daemon and plugin are available, but the
  workflow MCP entry is not registered in the current Codex configuration.
- Correct the macOS validation follow-up now that the workflow is on `main`.

### Design intent

Each MCP server entry has its own process environment. The workflow host must
receive the daemon URL itself and explicitly allow that name through to the
Open Design child. A missing value now produces a clear configuration error
instead of a misleading daemon connection failure.

### Validation

`make workflow-smoke && swift test && make check-docs` passed on Linux ARM64
in VM run `20261002T222013Z-3865905-11467`. The focused child environment test
also passed in run `20261002T221321Z-3811242-25155`.
