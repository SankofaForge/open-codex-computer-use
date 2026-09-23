# 2026-09-23 11:38 | Task: route capture through Browser Use

### 🤖 Execution Context
* **Agent ID**: `/root`
* **Base Model**: `GPT-6`
* **Runtime**: `Codex`

### 📥 User Query
> Complete these.

### 🛠 Changes Overview
**Scope:** `OpenComputerUseWorkflowKit`

**Key Actions:**
- **Routing**: Send `check_capture_gpu` and `capture_site_motion` through `browser-use-capture`.
- **Configuration**: Require those two tools and allow `BROWSER_USE_CHROMIUM_PATH` by name.
- **Documentation**: Describe browser setup, GPU checks, and manual rollback.
- **Tests**: Cover backend routing and configuration validation.

### 🧠 Design Intent (Why)
Route capture through Browser Use so the workflow uses its browser setup and GPU checks. Keep the existing evidence gate in place. Require a manual choice to return to `site-motion-capture`; do not fall back automatically.

### 📁 Files Modified
- `docs/workflow-mcp.md`
- `packages/OpenComputerUseWorkflowKit/Sources/OpenComputerUseWorkflowKit/WorkflowChildMCPDispatcher.swift`
- `packages/OpenComputerUseWorkflowKit/Sources/OpenComputerUseWorkflowKit/WorkflowContracts.swift`
- `packages/OpenComputerUseWorkflowKit/Tests/OpenComputerUseWorkflowKitTests/WorkflowChildMCPDispatcherTests.swift`
- `packages/OpenComputerUseWorkflowKit/Tests/OpenComputerUseWorkflowKitTests/WorkflowContractTests.swift`
- `docs/histories/2026-09/20260923-1138-browser-use-capture-backend.md`
