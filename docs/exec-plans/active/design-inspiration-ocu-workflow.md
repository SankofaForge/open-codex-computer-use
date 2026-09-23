# OCU-hosted design-inspiration workflow

## Goal

Provide a macOS-first, separate `workflow-mcp` surface that orchestrates the
existing design-inspiration, Browser Use capture, Open Design, and asset-route
MCP backends without changing the existing nine-tool `mcp` surface.

## Scope

- Include the `OpenComputerUseWorkflowKit` target and the
  `open-computer-use workflow-mcp --config <workflow-config>` command, child
  MCP transport, workflow control records, evidence validation, app approval,
  backend adapters, and workflow-specific smoke coverage.
- Preserve `workflow-manifest.v2`, `motion-analysis.v2`, authoritative capture
  paths, provider boundaries, and declarative fail-closed asset routing.
- Browser Use capture is the default implementation behind the existing
  `check_capture_gpu` and `capture_site_motion` stages. The legacy capture
  backend remains available only as a manual rollback during acceptance.
- Target runtime: the workflow launches a local stdio adapter; the adapter
  runs the pinned Browser Use worker on the rented GPU runner over Vast-managed
  SSH. Chrome is provisioned on that runner and selected by an explicit
  absolute executable path, not by a Snap shim or local workstation browser.
- Exclude automatic client configuration changes, publication, model-provider
  selection, capture-server source vendoring, and fallback asset generation.

## Constraints

- Existing `open-computer-use mcp` output, tools, behavior, and installation
  flow remain compatible.
- Child processes launch directly, use JSON-RPC over stdio, enforce declared
  tools and bounded timeouts, preserve backend errors, and clean up on
  cancellation.
- Backend configuration contains commands, arguments, working directories, and
  allowed environment-variable names only. It never contains secret values.
- Open Design keeps its direct generated command and daemon configuration; it
  does not use a secret-loading launcher.
- Workflow app access is allowlist- and session-approval-gated before app state
  or input dispatch. Sensitive actions require another confirmation, global
  pointer use is denied by default, and the password-manager denylist remains.

## Milestones

1. Contract: define tool schemas, `workflow-control.v2`, run-state transitions,
   capability records, error taxonomy, pinned schema fixtures, and parity
   requirements.
2. Validation and transport: port pure evidence validation and implement child
   MCP process lifecycle, JSON-RPC handshake, timeouts, cancellation, and fake
   backend fixtures.
3. Server: add granular stage tools, checkpointing, resume, cancellation, and
   the `workflow_run` convenience runner.
4. Safety and adapters: add app approval policy and configured adapters for
   search, preparation, token extraction, capture, analysis submission, frame
   extraction, Open Design handoff, and asset routes.
5. Packaging and QA: ship CLI/configuration documentation, provenance notices,
   deterministic workflow smoke coverage, and an acceptance report.

## Verification

- `swift build`
- `swift test`
- `make smoke`
- `make agent-smoke`
- `make check-docs`
- `make workflow-smoke` after milestone 3 replaces the current explicit
  placeholder with fake-backend end-to-end coverage.

The eventual workflow suite also covers malformed JSON, unknown tools, crash
and timeout cleanup, cancellation, resume after backend failure, app approval
and denial, global-pointer rejection, artifact containment and SHA-256,
four-cell matrix completeness, Open Design redaction, and no-secret logging.

## Progress

- [x] Confirm separate workflow MCP, child-process backend boundary, additive
  compatibility, session approval, harness-specific motion analysis, and
  declarative asset routing.
- [x] Add package/product wiring, an initial `workflow-mcp` scaffold,
  documentation, provenance notice, active plan, and reserved `workflow-smoke`
  entry point.
- [x] Implement contract and validator layers.
- [x] Implement child transport and asynchronous workflow server lifecycle.
- [ ] Implement approvals and external adapters.
- [x] Add the Browser Use capture backend contract and fail-closed adapter
  boundary; runtime capture remains blocked until compatibility validation.
- [x] Replace the manual Browser Use compatibility override with explicit
  non-Snap executable validation, a locked compatibility probe, and an
  expiring GPU-check capability. Chrome startup, recording, instrumentation,
  `nvidia-smi`, and hardware-backed WebGL passed in the latest recorded probe.
- [x] Report CPU browser functions, GPU support, and egress compliance as
  separate compatibility results. Treat `domain-not-approved` as a recorded
  proxy denial, not a CPU-function failure. Preserve fail-closed capture
  authorization while the browser-wide egress boundary remains unverified.
- [x] Replace the placeholder smoke target with deterministic lifecycle coverage.
- [x] Split the SwiftPM graph by platform so Linux can test the Foundation-only
  workflow kit while macOS retains the complete OCU package gate.
- [x] Implement the local stdio adapter's Vast-managed SSH bridge, remote
  worker invocation, artifact transfer, and cleanup lifecycle. The remote
  worker launches real Chrome explicitly and attaches through CDP.
- [ ] Verify the browser-wide egress boundary. The exact-host SOCKS proxy
  denies unapproved requests, but current evidence does not prove that all
  Chrome network paths use it. Earlier diagnostics recorded six Google
  destinations without URL paths or request initiators, so do not attribute
  them to Chrome services or expand the policy without reviewed authorization.

## Browser Use runner and acceptance boundary

The local stdio MCP adapter owns the workflow-facing contract and artifact
transfer. It must resolve the active Vast-managed SSH endpoint for the
configured rented instance, run the pinned worker remotely, and clean up the
exact per-run remote profile, recording, and staging directory on success,
failure, timeout, and cancellation. Keep the Vast API key in the local
secret-aware process environment. Configuration may name allowed environment
variables but must not store credential values. `BROWSER_USE_CHROMIUM_PATH` is
the remote absolute path to a provisioned Chrome binary. The current dependency
pin is `browser-use[video]==0.13.10`, locked with `uv.lock`.

The compatibility probe must emit machine-readable JSON that records the
browser executable, Browser Use release, Chrome version, separate CPU, GPU,
and egress results, and a concrete failure reason when blocked. The CPU gate
covers browser startup/CDP attachment, page evaluation and jank
instrumentation, viewport and reduced-motion control, recording, domain policy,
and cleanup. The GPU gate checks both `nvidia-smi` and a hardware-backed WebGL
renderer. The egress gate requires proof that all browser network paths use
the approved boundary and that required browser security services are
reachable; a SOCKS negative control or successful TCP connection alone is
insufficient. A CPU or GPU pass alone must not produce an authoritative
`gpu_check_id` or authorize capture.

Test both blocked paths, including a CPU-gate failure while the GPU gate passes;
the successful GPU result must not hide the CPU failure reason.

### Startup-timeout recovery

The configured `/usr/bin/chromium-browser` was a Snap shim and caused the
initial startup timeout. The rented runner now uses the real executable at
`/opt/google/chrome/chrome`; its version check succeeds. The tested recovery
path launches Chrome with an isolated profile and loopback CDP port, then
attaches `BrowserSession` to the ready endpoint. Chrome starts on a local
`data:` document to avoid the Browser Use `about:blank` logo request. Browser
startup now passes. The compatibility probe reports CPU functionality
separately from proxy outcomes. It does not collect URL paths or initiators,
and observations before or after fixture navigation do not establish request
ownership. Keep capture blocked until CPU, GPU, and browser-wide egress checks
pass; do not add a manual compatibility override.

### Runtime candidate check (2026-09-22)

The bounded A-path investigation found no browser that passes the current
policy. Stock Chrome 153.0.8010.52 reached the fixture and passed the browser
and hardware-WebGL checks, but the proxy rejected six Google service hosts.
Chrome for Testing Stable 154.0.8037.57 passed those checks except for five
rejected Google hosts. Its headless shell failed the fixture-title and
hardware-WebGL checks. Microsoft Edge Stable 153.0.4234.48 passed the page,
viewport, reduced-motion, jank, recording, cleanup, and GPU checks, but the
proxy rejected `edge.microsoft.com` on ports 80 and 443, `www.bing.com`, and
`nav-edge.smartscreen.microsoft.com`.

No browser default or egress rule changed. The workflow remains blocked and
must not issue a `gpu_check_id` until CPU, GPU, and egress gates pass.

### Acceptance gates

The runner provisioning checks currently show Chrome and an NVIDIA device to
`nvidia-smi`. Exploratory startup and page-evaluation checks are not the full
compatibility gate. Acceptance remains incomplete until the CPU,
hardware-WebGL GPU, and browser-wide egress gates pass, followed by consent and
animated/WebGL fixtures for all four evidence cells. Each cell must retain the
existing `capture-cell.v2`, WebM, jank, consent, path, size, and SHA-256
requirements and pass downstream `motion-analysis.v2` validation. The test
suite must also cover
JSON-RPC routing, timeout, cancellation, domain rejection, profile isolation,
and cleanup.

The performance comparison is three cold and five warm four-cell runs. Each
cell must meet its existing timeout, with no more than a 20% regression in p95
duration or peak memory versus the existing capture baseline. Until these
results are recorded, Browser Use must not report complete evidence. Missing
GPU, non-hardware WebGL, recording or jank failure, consent uncertainty,
timeout, domain violation, cleanup failure, or artifact mismatch returns
`blocked` or `partial`. `site-motion-capture` is available only through an
explicit manual rollback configuration; automatic fallback is prohibited.

## Decisions

- 2026-09-21: Package `OpenComputerUseWorkflowKit` separately. The early CLI
  scaffold is documented as non-production until transport, validation, and
  app-approval boundaries exist; the existing MCP tool surface remains
  compatible.
- 2026-09-21: Keep workflow control data in `workflow-control.v2` rather than
  extending strict `workflow-manifest.v2`.

## Contract milestone

Status: implemented in `OpenComputerUseWorkflowKit`; integration and the
macOS acceptance gate remain.

The contract layer owns control envelopes, backend configuration, strict v2
evidence validation, artifact containment and SHA-256 checks, four-cell visual
evidence, Open Design evidence, and fail-closed asset-route readiness.

## macOS GUI acceptance boundary

- `SkyClickLiveTests` is the direct low-level XCTest gate. It runs CoreGraphics/SkyLight from the XCTest host, so its test-only Accessibility and Screen Recording permissions belong to the app that launches XCTest.
- `make sky-click-app-agent-acceptance` is the production path. It builds `Open Computer Use.app`, invokes the existing CLI proxy, and exercises LaunchServices plus the Unix-domain app-agent IPC path. Production permissions belong only to `Open Computer Use.app`.
- Neither gate is valid from a headless process, SSH tty, or remote shell without a logged-in macOS GUI session.
