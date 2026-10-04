## [2026-10-04 19:05] | Task: Remove the retired capture backend

### 🤖 Execution Context
* **Agent ID**: `Claude Code`
* **Base Model**: `claude-sonnet-5-5`
* **Runtime**: `Claude Code in VS Code on macOS (Swift 6.4)`

### 📥 User Query
> Remove every mention of the retired capture adapter from the workflow host,
> including its backend kind, rollback tests, fixture flag, docs, and the
> capture output directory that carried its name.

### 🛠 Changes Overview
**Scope:** `OpenComputerUseWorkflowKit`, `WorkflowMCPFakeBackend`, `docs/`

**Key Actions:**
- **Backend kind**: removed the retired capture backend kind. `captureBackend`
  now accepts only `browser-use-capture`, and a configuration that names the
  removed kind no longer decodes.
- **Output directory**: capture and frame output now go to
  `artifacts/design-inspiration/capture-evidence` to match the capture server.
- **Tests and fixture**: removed the rollback tests and the fake backend's
  second fixture flag, and added a check that an explicit `captureBackend`
  must reference a configured backend.
- **Docs**: updated `docs/workflow-mcp.md` and the active execution plan so
  Browser Use is the only capture backend.

### 🧠 Design Intent (Why)
The adapter was retired and its checkout removed, so the host's rollback
route could never be selected successfully. Keeping the kind in the contract
and the old directory name in the output paths misled readers and left two
code paths to maintain.

### 🧪 Verification
- The 46 workflow-kit tests pass. The fake-backend tests only find their
  backend when the test runner's `argv[0]` sits beside the staged binary, so
  they were run through `xctest` directly with that layout. They fail the same
  way on the unmodified baseline under plain `swift test` on this toolchain.
- A host built from this source completes the MCP initialize and tools/list
  handshake with `workflow-mcp --config` and lists 15 workflow tools.
- Earlier dated histories still use the old name; they record past state.

### 📁 Files Modified
- `packages/OpenComputerUseWorkflowKit/Sources/OpenComputerUseWorkflowKit/WorkflowContracts.swift`
- `packages/OpenComputerUseWorkflowKit/Sources/OpenComputerUseWorkflowKit/WorkflowChildMCPDispatcher.swift`
- `packages/OpenComputerUseWorkflowKit/Sources/OpenComputerUseWorkflowKit/WorkflowMCPServer.swift`
- `packages/OpenComputerUseWorkflowKit/Tests/OpenComputerUseWorkflowKitTests/WorkflowContractTests.swift`
- `packages/OpenComputerUseWorkflowKit/Tests/OpenComputerUseWorkflowKitTests/WorkflowChildMCPDispatcherTests.swift`
- `apps/WorkflowMCPFakeBackend/Sources/WorkflowMCPFakeBackend/main.swift`
- `docs/workflow-mcp.md`
- `docs/exec-plans/active/design-inspiration-ocu-workflow.md`
