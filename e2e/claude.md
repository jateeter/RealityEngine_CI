# RealityEngine_CI E2E Guidance

This directory contains full-stack tests for the composed RealityEngine application.

- Prefer tests that consume `RE_REGISTRY_URL` and active engine metadata.
- Keep OpenClaw, Manager, Machines, and byte-equivalence assertions separated.
- Capture evidence without assuming generated reports should be committed.
- When failures diverge by engine, compare C++, LSP, and Scala payload identity before byte equality.

## Which specs run in which universe shape

`tests/` is the canonical home of the app-level specs — they were deduped here
from `RealityEngine_Machines` deliberately. Do not re-add copies there.

| Spec | Multi-engine | Why |
|---|---|---|
| `tree-to-pe-manager-equivalence.spec.ts` | ✅ runs | resolves endpoints from the registry |
| `api.spec.ts` | ⏭ skipped | hardcodes `https://localhost:5001` |
| `full-integration.spec.ts` | ⏭ skipped | hardcodes `:5001`, `:3001` |
| `multi-step-output-workflow.spec.ts` | ⏭ skipped | hardcodes `:5001`, `:3004` |
| `perceptual-space-interconnection.spec.ts` | ⏭ skipped | hardcodes `:3004`, `:3001` |
| `visualizer-ui.spec.ts` | ⏭ skipped | UI-only, but pinned to the Docker frontend |

Those endpoints are the **Docker** universe. A native `--engines=` launch binds
RE/PE at registry-assigned ports over HTTP (scala 5000/5001, cpp 5300/5301,
lsp 5600/5601), so the pinned specs fail on connection rather than behavior.

Selection lives in `scripts/lib/ci-e2e-specs.sh`; `scripts/run-all-tests.sh`
reports every skipped spec by name, and deployment mode escalates those skips to
failures. `scripts/tests/test-ci-e2e-specs.sh` asserts the run and skip lists
partition this directory exactly, so a new spec cannot land unrun and unreported.

**To promote a spec to multi-engine:** make it resolve its base URLs from
`RE_REGISTRY_URL` instead of hardcoding them, then add it to
`CI_E2E_MULTI_ENGINE_SPECS`. The unit test refuses any allowlisted spec that
still pins `:5001` or `:3004`.

