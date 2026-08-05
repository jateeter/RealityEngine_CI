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

## Which hosted job runs what

| Job | Universe | Specs |
|---|---|---|
| `e2e-tests` | single-engine Docker | `ci_e2e_single_engine_specs` — the five Docker-pinned specs |
| `multi-engine-tests` | `--engines=scala:2` + registry | Machines' `multi-instance.spec.ts` only |
| *(none yet)* | `--engines=cpp:1,lsp:1,scala:1` | `tree-to-pe-manager-equivalence.spec.ts` |

The `e2e-tests` step sources the library rather than listing specs inline, so
that split cannot drift between the local runner and hosted CI.

`tree-to-pe-manager-equivalence` hardcodes `lsp-1`, `scala-1` and `cpp-1`
because byte equivalence is only meaningful across distinct runtimes —
`--engines=scala:2` cannot substitute. **No hosted job spawns a tri-runtime
universe**, so it runs via `run-all-tests.sh --e2e` against a local
`--engines=cpp:1,lsp:1,scala:1` launch, and would run in the regression suite
once that is unblocked (#79). It self-skips elsewhere with the missing engine
ids in the reason.

## Corpus dependencies

`multi-step-output-workflow` and `perceptual-space-interconnection` drive the
digital-logic fixtures `MultiStep`, `RS2` and `RSFlipFlop`. Those are **not** in
`config/standard-deployment-corpus.txt` (12 machines), which is what the hosted
jobs boot with via `--machine-corpus=standard-deployment`.

Both specs guard on this through `helpers/require-machines.ts` and skip with a
reason naming the missing machines. They run for real against a full-corpus
universe — the default `startUniverse.sh`, and `run-all-tests.sh --e2e` locally.

A 404 for a machine the corpus never claimed to load is not a product signal, so
these skip rather than fail. Deployment mode still treats the skip as a failure
at the suite level, so a certification run cannot quietly omit them.

## Selector guidance

The landing surface is a domain **tree**, not the old card grid. `.mc-card` and
`.msv-search` still exist in the Manager frontend but are not on the landing
route.

Prefer stable classes over role+name where names collide:

| Want | Use | Not |
|---|---|---|
| Wordmark | `.rep-title` | `h1` (none exists) |
| Interconnect nav | `.rep-nav-interconnect` | `getByRole('button', {name:'Interconnect'})` — also matches the `Interconnects` filter chip |
| Machine list | `getByRole('tree', {name:/Machines grouped by domain/})` | `h3` (first match is a hidden Settings section) |
| Search | `getByPlaceholder(/search domains/)`, `.rep-search-clear` | `.msv-search` |

`RealityEngine_Manager/visualizer/frontend/e2e/` tracks this UI closely and is
the best reference for current selectors.

