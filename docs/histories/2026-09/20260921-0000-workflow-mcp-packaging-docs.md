## [2026-09-21 00:00] | Task: prepare workflow MCP packaging docs

### 🤖 Execution Context
* **Agent ID**: `Codex`
* **Base Model**: `GPT-5`
* **Runtime**: `Codex`

### 📥 User Query
> Prepare the OCU workflow MCP package wiring and documentation without
> changing existing runtime behavior or client configuration.

### 🛠 Changes Overview
**Scope:** Swift package manifest, Make entry point, workflow documentation,
security boundary, provenance notice, and execution plan.

**Key Actions:**
- Added the `OpenComputerUseWorkflowKit` library product and target.
- Reserved `make workflow-smoke` with an explicit scaffold-only message.
- Documented the initial CLI scaffold and the future configuration, evidence,
  credential, and app-approval boundaries without changing client config.
- Recorded vendoring constraints and the active implementation plan.

### 🧠 Design Intent

The package boundary can be reviewed and consumed independently while the
existing MCP protocol remains stable. The early workflow scaffold is explicitly
marked non-production until child MCP transport, evidence validation, and its
safety policy are implemented.

### 📁 Files Modified
- `Package.swift`
- `Makefile`
- `README.md`
- `docs/SECURITY.md`
- `docs/workflow-mcp.md`
- `docs/notices/design-inspiration-workflow-vendor-notices.md`
- `docs/exec-plans/active/design-inspiration-ocu-workflow.md`
