# Workflow host orchestration repair

The workflow host now enforces profile-specific stages, typed resume inputs,
stable workspace binding, UUID run IDs, one active executor per run, atomic
metadata checkpoints, cancellation, and a fresh GPU check for every capture
cell. A run pauses with an explicit gap when it needs reference selection,
motion analysis, Open Design approval, or asset results.

The host composes `workflow-manifest.v2` from stage outputs and validates it
before reporting completion. The Swift evidence validator binds capture-cell
v2 manifests to WebM and jank files, checks consent, cleanup, GPU and runner
egress proof, and matches analysis sources and frames by path and hash. The
Open Design adapter uses the published plugin/project/run tools and checks
the completed artifact inside the configured workspace.

Browser Use host preflight checks static backend configuration only. The
privileged capture runner owns the fresh per-capture egress attestation, which
may not exist on the host before GPU preflight.

The Swift workflow smoke and package suite passed 43 tests on Linux ARM64.
Native macOS validation passed 45 tests in [run 35951350278](https://github.com/SankofaForge/open-codex-computer-use/actions/runs/35951350278). The uploaded
`OpenComputerUse` arm64 executable is 3,924,960 bytes and matches the
SHA-256 manifest (`55b4d092e59ba5c75775315d17e0ee8a7474c87a6672a37d5372d2f20063d263`).
Live capture acceptance remains separate and unverified.
