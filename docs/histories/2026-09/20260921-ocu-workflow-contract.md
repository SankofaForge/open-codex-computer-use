# OCU workflow contract layer

**Scope:** `OpenComputerUseWorkflowKit` models, validation, deterministic unit
fixtures, and execution-plan trace.

## What changed

- Added a standalone `OpenComputerUseWorkflowKit` library and test target.
- Added versioned workflow-control envelopes, stage/status/error models, and
  backend configuration validation.
- Added pure evidence validation for strict v2 manifest and motion-analysis
  records, workspace-contained SHA-256 artifacts, the visual four-cell matrix,
  Open Design evidence, and fail-closed asset routes.
- Added deterministic fixtures for complete, partial, blocked, stale-hash,
  v1, missing-matrix, missing Open Design, and blocked-asset cases.

## Why

The workflow host needs a stable, portable contract boundary before it can
launch child MCP backends. Keeping this layer separate prevents workflow state
from leaking into `workflow-manifest.v2` and avoids changing the existing
Computer Use tool surface.

## Verification

- The workflow library and XCTest target compile on the remote verifier.
- Full root XCTest execution is deferred to macOS because unrelated existing
  targets require AppKit.
