# 2026-09-24 08:57 | Task: Fix workflow MCP arguments

### Execution Context

- Agent ID: Codex primary
- Base model: GPT-6
- Runtime: macOS

### User Query

> Route the design-inspiration workflow through Browser Use from Codex.

### Changes Overview

**Scope:** Open Computer Use CLI and workflow documentation.

- Fixed `workflow-mcp` parsing so it accepts the documented `--config <path>` arguments.
- Added `workflow-mcp` to the CLI commands listed in the architecture guide.

### Design Intent

The command checked its full argument list as if the subcommand were absent, so every valid invocation failed. Parsing the arguments after the subcommand lets the workflow host start with its explicit configuration file.

### Files Modified

- `packages/OpenComputerUseKit/Sources/OpenComputerUseKit/OpenComputerUseCLI.swift`
- `packages/OpenComputerUseWorkflowKit/Sources/OpenComputerUseWorkflowKit/WorkflowMCPServer.swift`
- `packages/OpenComputerUseWorkflowKit/Tests/OpenComputerUseWorkflowKitTests/WorkflowMCPServerTests.swift`
- `docs/ARCHITECTURE.md`
