# Workflow MCP packaging boundary

## Current status

`OpenComputerUseWorkflowKit` is available as a Swift package target and
library product. This checkout has a stdio workflow host at:

```text
open-computer-use workflow-mcp --config <path>
```

The workflow kit launches configured child MCP processes, validates evidence,
and returns structured control records. Desktop input remains macOS-only and
requires the app-approval policy.

Existing `open-computer-use mcp` clients continue to receive the unchanged
nine-tool Computer Use surface.

The implementation contract is tracked in
[`docs/exec-plans/active/design-inspiration-ocu-workflow.md`](./exec-plans/active/design-inspiration-ocu-workflow.md).

## Configuration contract

The host loads one explicit JSON configuration file and launches configured
backends directly. Backend declarations identify executable commands and
permitted environment-variable names only. The host supplies a sanitized
baseline environment, never persists backend payloads in checkpoints, and
does not accept shell fragments or secret values in configuration.

```json
{
  "backends": [
    {
      "kind": "design-inspiration",
      "command": "design-inspiration-mcp",
      "arguments": [],
      "workingDirectory": ".",
      "permittedEnvironmentVariables": ["DESIGN_SEARCH_API_KEY"],
      "declaredTools": ["design_search_references", "design_prepare_references", "design_extract_tokens"]
    },
    {
      "kind": "browser-use-capture",
      "command": "browser-use-capture-mcp",
      "arguments": [],
      "workingDirectory": ".",
      "permittedEnvironmentVariables": ["BROWSER_USE_CHROMIUM_PATH"],
      "declaredTools": ["check_capture_gpu", "capture_site_motion"]
    },
    {
      "kind": "open-design",
      "command": "open-design-mcp",
      "arguments": ["serve"],
      "workingDirectory": ".",
      "permittedEnvironmentVariables": [],
      "declaredTools": ["handoff_open_design"]
    }
  ]
}
```

The example uses placeholders. A caller supplies any needed secret through its
own environment, subject to the configured name allowlist. The host launches
backend commands directly rather than through a shell and enforces declared
backend tools. Open Design is deliberately a direct generated command, not a
secret-loading wrapper.

## Planned evidence and data boundary

The host preserves the existing workflow evidence contract:

- `workflow-manifest.v2` and `motion-analysis.v2` remain authoritative and
  receive no OCU-only fields.
- OCU control state uses a separate `workflow-control.v2` record.
- `workflow_run` returns a running record immediately. Use `workflow_status`,
  `workflow_resume`, and `workflow_cancel` for lifecycle control.
- Checkpoints are atomic metadata-only records under
  `<workspaceRoot>/.workflow/checkpoints/<runId>.json`.
- Capture artifacts remain under
  `artifacts/design-inspiration/site-motion-capture/`.
- `BROWSER_USE_CHROMIUM_PATH` must identify an installed executable
  non-Snap Chromium or Chrome binary. CPU compatibility and GPU-authoritative
  capture are separate gates; a CPU-only probe cannot authorize evidence.
- A manifest cannot report `complete` without the responsive and motion
  evidence matrix, Open Design handoff, and ready asset routes.
- Model-provider selection remains harness-specific. The host only validates a
  bounded analysis result and does not silently choose another provider.
- Asset routing remains declarative and fail-closed. A blocked asset is not
  replaced with CSS, a placeholder, or a different authoring tool.

For blocked startup, provision a real browser, set `BROWSER_USE_CHROMIUM_PATH`,
rerun the compatibility probe, and rerun the GPU check. Use
`site-motion-capture` only as an explicit manual rollback; there is no
automatic fallback.

## Smoke target

`make workflow-smoke` runs the deterministic workflow-server, transport, and
dispatcher tests. Linux builds and tests the Foundation-only workflow kit. The
complete OCU package, desktop approval, and GUI smoke tests remain macOS gates
because Apple frameworks are unavailable on Linux.
