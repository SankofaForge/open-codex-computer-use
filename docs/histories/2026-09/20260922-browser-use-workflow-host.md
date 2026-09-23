## 2026-09-22 — Route capture stages to Browser Use

The workflow host now selects `browser-use-capture` for the GPU-check and live
motion-capture stages. It preserves the existing stage names, tool names,
evidence schemas, and legacy site-motion-capture implementation.

The backend configuration enforces the bounded two-tool surface, and focused
fake-backend tests cover routing, missing backends, and invalid declarations.
