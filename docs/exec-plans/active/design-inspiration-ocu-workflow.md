# OCU-hosted design-inspiration workflow

## Goal

Add a macOS-first, separate `workflow-mcp` surface that orchestrates the
existing design-inspiration, site-motion-capture, Open Design, and asset-route
MCP backends without changing the existing nine-tool `mcp` surface.

## Scope

- Include a new `OpenComputerUseWorkflowKit` target, a future
  `open-computer-use workflow-mcp --config <workflow-config>` command, child
  MCP transport, workflow control records, evidence validation, app approval,
  backend adapters, and workflow-specific smoke coverage.
- Preserve `workflow-manifest.v2`, `motion-analysis.v2`, authoritative capture
  paths, provider boundaries, and declarative fail-closed asset routing.
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

1. Contract: define tool schemas, `workflow-control.v1`, run-state transitions,
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
- [ ] Implement contract and validator layers.
- [ ] Implement transport, server, approvals, and adapters.
- [ ] Replace the placeholder smoke target and complete integration QA.
- [x] Split the SwiftPM graph by platform so Linux can test the Foundation-only
  workflow kit while macOS retains the complete OCU package gate.

## Decisions

- 2026-09-21: Package `OpenComputerUseWorkflowKit` separately. The early CLI
  scaffold is documented as non-production until transport, validation, and
  app-approval boundaries exist; the existing MCP tool surface remains
  compatible.
- 2026-09-21: Keep workflow control data in `workflow-control.v1` rather than
  extending strict `workflow-manifest.v2`.

## Contract milestone

Status: implemented in `OpenComputerUseWorkflowKit`; integration and the
macOS acceptance gate remain.

The contract layer owns control envelopes, backend configuration, strict v2
evidence validation, artifact containment and SHA-256 checks, four-cell visual
evidence, Open Design evidence, and fail-closed asset-route readiness.
