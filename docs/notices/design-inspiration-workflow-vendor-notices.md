# Design-inspiration workflow vendor notices

## Current package state

This checkout does not yet vendor workflow schemas, capture code, Open Design,
asset-routing implementations, or model-provider code. The early
`OpenComputerUseWorkflowKit` scaffold does not ship additional third-party
source.

The fork continues to carry the upstream Open Computer Use source under the
repository's [MIT License](../../LICENSE). Its upstream provenance is
[`iFurySt/open-codex-computer-use`](https://github.com/iFurySt/open-codex-computer-use).

## Required provenance for the implementation phase

Before an implementation change copies any workflow schema or fixture into
this repository, it must add the following to this notice:

- the source repository and immutable revision;
- the source path and SHA-256 of the imported file;
- the applicable license text or a precise reference to it; and
- any local modifications, if allowed.

The future host may invoke the existing capture service only through a
configured MCP process. The capture implementation must not be copied into
this repository because its source has no discoverable license notice.

`workflow-manifest.v2` and `motion-analysis.v2` may be vendored only as pinned
schema snapshots with the provenance record above. Their validation behavior
can be ported into Swift, but `workflow-manifest.v2` itself must not be changed
to add OCU execution fields.
