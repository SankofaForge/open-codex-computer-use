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

## Planned configuration contract

The scaffold loads one explicit JSON configuration file. The implemented
configuration shape is an array of backend declarations and an optional
checkpoint-directory path. Backend declarations are not started yet. The
future transport contract identifies executable commands and permitted
environment-variable *names* only. It must never contain secret values,
machine-specific paths, shell fragments, or unbounded tool access.

```json
{
  "backends": [
    {
      "id": "design-inspiration",
      "command": "design-inspiration-mcp",
      "arguments": [],
      "workingDirectory": ".",
      "environmentAllowlist": ["DESIGN_SEARCH_API_KEY"]
    },
    {
      "id": "site-motion-capture",
      "command": "site-motion-capture-mcp",
      "arguments": [],
      "workingDirectory": ".",
      "environmentAllowlist": ["CAPTURE_SERVICE_API_KEY"]
    },
    {
      "id": "open-design",
      "command": "open-design-mcp",
      "arguments": ["serve"],
      "workingDirectory": ".",
      "environmentAllowlist": []
    }
  ],
  "checkpointDirectory": "artifacts/design-inspiration/workflow-runs"
}
```

The example uses placeholders. A caller supplies any needed secret through its
own environment, subject to the configured name allowlist. The future host
will launch backend commands directly rather than through a shell and will
enforce declared backend tools. Open Design is deliberately a direct generated
command, not a secret-loading wrapper.

## Planned evidence and data boundary

The future host will preserve the existing workflow evidence contract:

- `workflow-manifest.v2` and `motion-analysis.v2` remain authoritative and
  receive no OCU-only fields.
- OCU control state uses a separate `workflow-control.v1` record.
- Capture artifacts remain under
  `artifacts/design-inspiration/site-motion-capture/`.
- A manifest cannot report `complete` without the responsive and motion
  evidence matrix, Open Design handoff, and ready asset routes.
- Model-provider selection remains harness-specific. The host only validates a
  bounded analysis result and does not silently choose another provider.
- Asset routing remains declarative and fail-closed. A blocked asset is not
  replaced with CSS, a placeholder, or a different authoring tool.

## Smoke target

`make workflow-smoke` runs the deterministic fake-MCP workflow tests covering
transport and dispatcher behavior. Linux builds and tests the Foundation-only
workflow kit. The complete OCU package, desktop approval, and GUI smoke tests
remain macOS gates because Apple frameworks are unavailable on Linux.
