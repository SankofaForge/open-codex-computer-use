## [2026-10-08 20:29] | Task: simplify capture outputs

### 🤖 Execution Context
* **Agent ID**: `/root`
* **Base Model**: `GPT-6`
* **Runtime**: `Codex on macOS`

### 📥 User Query
> Remove the extra capture-cell evidence and check which files can go.

### 🛠 Changes Overview
**Scope:** Browser Use capture MCP, Open Computer Use workflow kit, and
`agent-infrastructure` evidence validation.

**Key Actions:**
- **Capture outputs**: Removed the worker manifest and capture-cell sidecar.
  The MCP writes the WebM and jank report, checks transferred hashes, and
  returns the two artifact paths.
- **Workflow validation**: Removed the sidecar parser. Validators check the
  two artifact hashes and jank report. Analysis remains bound to its capture
  run and WebM path/hash.
- **Workflow routing**: Removed the single-choice capture backend setting.
  Open Computer Use now maps the named video and jank outputs into its
  workflow manifest.
- **Dead code and files**: Removed the unused local GPU probe, unused native
  analysis adapter, two unused v1 fixtures, and completed egress proposal.
  Kept the dated capture history.

### 🧠 Design Intent (Why)
The capture MCP already checks media, consent, GPU, and cleanup. A second JSON
file only repeated those results and the hashes for the same two files. Hashes
still cross the worker boundary and the adapter verifies them after transfer.

### 📁 Files Changed

This change also updates the matching fixtures, tests, workflow configuration,
and journal entries across the three repositories. It removes the completed
egress proposal and two unreferenced v1 fixtures.
