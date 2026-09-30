# 2026-09-30 13:27 | Task: Fix workflow MCP audit findings

### Execution Context

- Agent ID: Claude Code primary
- Base model: Claude Sonnet 5
- Runtime: macOS

### User Query

> Audit the visual-handoff-workflow MCP for improvements, then resolve all 7 findings.

### Changes Overview

**Scope:** `OpenComputerUseWorkflowKit` (the workflow MCP server behind the
`visual-handoff-workflow` MCP entry) and its test suite.

- Let `workflow_cancel` stop a run that is `partial` or `blocked`, not only
  `running`; previously a run waiting on human input (reference selection,
  motion analysis, an Open Design approval, or asset results) silently ignored
  cancellation.
- Gave each of the 15 `workflow_*` tools its own `tools/list` description
  instead of one identical generic string.
- Documented, at the source and in the `workflow_status` tool description,
  that polling status can resume checkpointed execution as a side effect.
- Made `writeCheckpoint` report write failures to stderr instead of swallowing
  them silently.
- Extracted the six near-identical stage-completion blocks in `execute()`
  into one `recordStageCompletion` helper.
- Broadened `containsSecretAssignment` to also catch colon-style and
  bearer-token credential shapes, matching `ChildMCPTransport`'s diagnostic
  redaction.
- Replaced the hand-rolled SHA-256 implementation with `apple/swift-crypto`
  (added as the project's first dependency); it verifies every artifact hash
  in the evidence pipeline, and is the one place a vetted implementation
  matters most in an otherwise dependency-free codebase.

### Design Intent

All seven items came from a source-level audit of this module, not from a
reported bug. Each was verified by reading the code and its existing tests
before changing it; one initial suspicion (a `nil` boxed as `Any` breaking
JSON error encoding) was tested empirically and ruled out rather than "fixed."
New tests cover the cancel and tool-description changes; the deduplication
refactor was verified byte-for-byte identical to its tested pre-commit form
before being split into its own commit.

### Files Modified

- `Package.swift`
- `Package.resolved` (new)
- `packages/OpenComputerUseWorkflowKit/Sources/OpenComputerUseWorkflowKit/WorkflowContracts.swift`
- `packages/OpenComputerUseWorkflowKit/Sources/OpenComputerUseWorkflowKit/WorkflowMCPServer.swift`
- `packages/OpenComputerUseWorkflowKit/Sources/OpenComputerUseWorkflowKit/WorkflowSHA256.swift`
- `packages/OpenComputerUseWorkflowKit/Tests/OpenComputerUseWorkflowKitTests/WorkflowMCPServerTests.swift`
