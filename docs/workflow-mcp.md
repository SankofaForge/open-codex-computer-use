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
      "kind": "open-design",
      "command": "<Settings-generated Open Design command>",
      "arguments": ["<Settings-generated daemon CLI and MCP arguments>"],
      "workingDirectory": "<generated working directory>",
      "permittedEnvironmentVariables": [
        "OD_DAEMON_URL",
        "OD_DATA_DIR",
        "ELECTRON_RUN_AS_NODE",
        "OD_MCP_BOOTSTRAP_ARGS",
        "OD_MCP_BOOTSTRAP_COMMAND",
        "OD_MCP_DISCOVERY",
        "OD_SIDECAR_CLIENT_ENDPOINT"
      ],
      "declaredTools": ["list_plugins", "create_project", "start_run", "get_run", "cancel_run"],
      "launchPolicy": "direct"
    }
  ]
}
```

Generate this backend declaration from the local Open Design Settings MCP
snippet or `mcp install codex --print --json` output. Preserve its exact
command, argument list, working directory, and environment names; packaged
Electron installations may use the app executable as the command. Do not use
an assumed `open-design-mcp serve` executable. Verify the tool list with an
initialize/list-tools handshake and call `list_plugins` before a design run.
The list must include `od-web-effect-extractor` before visual handoff.

The host launches backend commands directly rather than through a shell and
passes the configured environment names alongside its sanitized baseline.
The workflow MCP process must also receive the environment values that the
Settings-generated Open Design entry uses. MCP server entries do not inherit
each other's environment. In Codex, set `OD_DAEMON_URL` in the workflow MCP
server's `env` table to the same value used by the direct Open Design entry.
The child allowlist forwards that value; it does not read the sibling entry's
environment. The host stops with `invalid_configuration` before it launches
Open Design when `OD_DAEMON_URL` is missing. Copy the other generated
environment values into the workflow server's environment when the generated
command requires them. Never put environment values or secrets in this JSON.

The Browser Use backend must permit exactly `VAST_INSTANCE_ID`, `VAST_API_KEY`,
`BROWSER_USE_CHROMIUM_PATH`. Supply the Vast API key through the host
environment. The browser path must point to a real, executable, non-Snap
Chromium or Chrome binary on the Vast runner.
For the current runner, set `BROWSER_USE_CHROMIUM_PATH` to
`/opt/google/chrome/chrome`. Do not use `/usr/bin/google-chrome`: it resolves
through a launcher-script chain and is rejected. The adapter does not download
a browser at runtime. Startup/CDP, recording, instrumentation, NVIDIA, and
hardware-backed WebGL checks passed in the latest recorded probe. The
compatibility report separates CPU browser functions and GPU support. Host
preflight checks the configured backend and declared tools. Each capture still
requires a fresh GPU check, HTTP(S) URL validation, consent, recording,
jank, artifact hashes, and cleanup. The capture workflow no longer requires an
egress attestation or proxy boundary.

`captureBackend` names the capture backend for both capture stages. If it is
omitted, Browser Use is selected, and `browser-use-capture` is the only accepted
value. A blocked Browser Use result remains blocked; the host does not retry
through another backend.

## Planned evidence and data boundary

The host preserves the existing workflow evidence contract:

- `workflow-manifest.v2` and `motion-analysis.v2` remain authoritative and
  receive no OCU-only fields.
- OCU control state uses a separate `workflow-control.v2` record.
- `workflow_run` returns a running record immediately. Use `workflow_status`,
  `workflow_resume`, and `workflow_cancel` for lifecycle control.
- Visual, evidence-only, and token-only runs require one search query or one
  selected reference. Search candidates pause for explicit selection.
  Nonvisual runs require a reason and stop after preflight.
- Resume submissions use a typed reference selection, motion-analysis path
  and cell ID, approval action ID and decision, or asset-results path. A
  paused run reports the required input in a `partial` response.
- The host binds each run to its configured workspace and UUID run ID. It
  composes `workflow-manifest.v2` atomically under `.workflow/manifests/` and
  validates the manifest before reporting completion.
- Checkpoints are atomic metadata-only records under
  `<workspaceRoot>/.workflow/checkpoints/<runId>.json`.
- Capture artifacts remain under
  `artifacts/design-inspiration/capture-evidence/`.
  Browser Use is the only capture backend.
- A manifest cannot report `complete` without the responsive and motion
  evidence matrix, Open Design handoff, and ready asset routes.
- Model-provider selection remains harness-specific. The host only validates a
  bounded analysis result and does not silently choose another provider.
- Asset routing remains declarative and fail-closed. A blocked asset is not
  replaced with CSS, a placeholder, or a different authoring tool.
- Open Design uses `list_plugins`, `create_project`, `start_run`, `get_run`,
  and `cancel_run`. Retries reuse the `start_run` request ID. Completion
  requires a workspace-contained artifact that passes size and hash checks.
  Verify at runtime that the plugin list includes
  `od-web-effect-extractor`; a missing plugin blocks visual handoff.

## Smoke target

`make workflow-smoke` runs the deterministic workflow-server, transport, and
dispatcher tests. Linux builds and tests the Foundation-only workflow kit. The
complete OCU package, desktop approval, and GUI smoke tests remain macOS gates
because Apple frameworks are unavailable on Linux.
