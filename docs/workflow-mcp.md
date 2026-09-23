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
  "captureBackend": "browser-use-capture",
  "backends": [
    {
      "kind": "design-inspiration",
      "command": "design-inspiration-mcp",
      "arguments": [],
      "workingDirectory": ".",
      "permittedEnvironmentVariables": ["DESIGN_SEARCH_API_KEY"],
      "declaredTools": ["design_search_references", "design_prepare_references", "design_extract_tokens"],
      "launchPolicy": "direct"
    },
    {
      "kind": "browser-use-capture",
      "command": "browser-use-capture-mcp",
      "arguments": [],
      "workingDirectory": ".",
      "permittedEnvironmentVariables": ["VAST_INSTANCE_ID", "VAST_API_KEY", "BROWSER_USE_CHROMIUM_PATH"],
      "declaredTools": ["check_capture_gpu", "capture_site_motion"],
      "launchPolicy": "direct"
    },
    {
      "kind": "site-motion-capture",
      "command": "site-motion-capture-mcp",
      "arguments": [],
      "workingDirectory": ".",
      "permittedEnvironmentVariables": ["CAPTURE_SERVICE_API_KEY"],
      "declaredTools": ["check_capture_gpu", "capture_site_motion"],
      "launchPolicy": "direct"
    },
    {
      "kind": "open-design",
      "command": "open-design-mcp",
      "arguments": ["serve"],
      "workingDirectory": ".",
      "permittedEnvironmentVariables": [],
      "declaredTools": ["handoff_open_design"],
      "launchPolicy": "direct"
    }
  ]
}
```

The host launches backend commands directly rather than through a shell and
passes the configured environment names alongside its sanitized baseline.
Never put environment values or secrets in this JSON. The Browser Use backend
must permit exactly `VAST_INSTANCE_ID`, `VAST_API_KEY`, and
`BROWSER_USE_CHROMIUM_PATH`. Supply the Vast API key through the host
environment. The browser path must point to a real, executable, non-Snap
Chromium or Chrome binary on the Vast runner.
For the current runner, set `BROWSER_USE_CHROMIUM_PATH` to
`/opt/google/chrome/chrome`. Do not use `/usr/bin/google-chrome`: it resolves
through a launcher-script chain and is rejected. The adapter does not download
a browser at runtime. Startup/CDP, recording, instrumentation, NVIDIA, and
hardware-backed WebGL checks passed in the latest recorded probe. The
compatibility report separates CPU browser functions, GPU support, and egress
compliance. The proxy records explicit policy denials, but it does not prove
that every Chrome network path uses the proxy or that required browser
security services are reachable. Egress therefore remains unverified, and the
adapter must keep `check_capture_gpu` blocked until both facts are verified. No
destination has been allowlisted.

`captureBackend` selects one capture backend for both capture stages. If it is
omitted, Browser Use is selected. A blocked Browser Use result remains blocked;
the host does not retry through `site-motion-capture`. To select the legacy
backend manually during the acceptance window, set `captureBackend` to
`site-motion-capture` and provide its backend declaration. Only the selected
backend is launched.

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
  Browser Use is the default capture backend; the legacy site-motion-capture
  backend remains a manually selected rollback during acceptance.
- A manifest cannot report `complete` without the responsive and motion
  evidence matrix, Open Design handoff, and ready asset routes.
- Model-provider selection remains harness-specific. The host only validates a
  bounded analysis result and does not silently choose another provider.
- Asset routing remains declarative and fail-closed. A blocked asset is not
  replaced with CSS, a placeholder, or a different authoring tool.

## Smoke target

`make workflow-smoke` runs the deterministic workflow-server, transport, and
dispatcher tests. Linux builds and tests the Foundation-only workflow kit. The
complete OCU package, desktop approval, and GUI smoke tests remain macOS gates
because Apple frameworks are unavailable on Linux.
