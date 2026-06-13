# Integrated RealityEngine Specification

This document is the cross-repository specification index for the deployable
RealityEngine system. `DEPLOYMENT_CONTRACT.md` remains the authoritative
service, port, and environment contract. `SURFACE_SPEC.md` remains the
authoritative RE/PE HTTP surface for the runtimes that carry it. This file ties
those contracts together and records the documentation roadmap needed for a
full integrated deployment.

## Repository Roles

| Repository | Role | Primary specification documents |
| --- | --- | --- |
| `RealityEngine_CI` | Deployment orchestrator, Docker public endpoints, native runtime registry, full-system gates | `DEPLOYMENT_CONTRACT.md`, this file |
| `RealityEngine_CPP` | Native C++ RE/PE runtime and adapter CLI | `SURFACE_SPEC.md`, `README.md`, `docs/INTEGRATION_ARCHITECTURE.md` |
| `RealityEngine_Scala` | Scala RE/PE runtime and active reference implementation | `SURFACE_SPEC.md`, `README.md`, `perception-engine/docs/HEALTHKIT_SPEZI_BRIDGE.md` |
| `RealityEngine_LSP` | Common Lisp RE/PE runtime | `SURFACE_SPEC.md`, `README.md`, `docs/CONFIGURATION_EQUIVALENCE.md` |
| `RealityEngine_Manager` | Visualizer, operator controls, registry-aware runtime switching | `SURFACE_SPEC.md`, `README.md` |
| `RealityEngine_Machines` | Authoritative machine corpus, domain policy, trigger contracts, machine validation | `README.md`, `docs/REALITY_PERCEPTION_OPERATIONS.md`, `docs/ARCHITECTURE_AUDIT.md` |

## Authoritative Contract Stack

1. `RealityEngine_CI/DEPLOYMENT_CONTRACT.md`
   Defines service ownership, port bands, environment names, native runtime
   pairs, Docker public endpoints, localAIStack ports, OpenClaw ports, and
   normative deployment rules.

2. `SURFACE_SPEC.md`
   Defines the canonical RE and PE API surfaces. Copies must be byte-identical
   across `RealityEngine_CPP`, `RealityEngine_LSP`, `RealityEngine_Scala`, and
   `RealityEngine_Manager`.

3. `RealityEngine_Machines/docs/REALITY_PERCEPTION_OPERATIONS.md`
   Defines how machines, perceptual regions, RE transitions, PE sources,
   dispatch, and write-back operate as one system.

4. Runtime-local README and integration docs
   Explain local build and operator usage, but must not override the documents
   above.

## Deployment Contract Summary

Native runtime ports:

| Runtime | PE | RE |
| --- | ---: | ---: |
| Scala | `5000` | `5001` |
| CPP | `5300` | `5301` |
| LSP | `5600` | `5601` |

CI Docker public endpoints:

| Service | URL |
| --- | --- |
| Reality Engine API | `https://localhost:3000` |
| Manager / Visualizer backend | `https://localhost:3001` |
| Perception Engine API | `https://localhost:3004` |
| Manager frontend | `https://localhost:5173` |

Shared support services:

| Service | URL |
| --- | --- |
| localAI API | `http://localhost:4000` |
| Qdrant REST | `http://localhost:4333` |
| Ollama | `http://localhost:11434` |
| OpenClaw gateway | `http://localhost:18789` |

## Required Environment Names

Every deployment-facing script and runtime should support these names:

| Variable | Purpose |
| --- | --- |
| `REALITY_ENGINE_PORT` | Native RE bind port |
| `PERCEPTION_ENGINE_PORT` | Native PE bind port |
| `REALITY_ENGINE_URL` | PE target for RE |
| `PERCEPTION_ENGINE_URL` / `PE_URL` | Tool target for PE |
| `RE_REGISTRY_URL` | Multi-engine registry URL for Manager and tests |
| `VECTOR_DIMENSION` | Dense compatibility floor for RE/PE vectors |
| `MACHINES_DIR` | Machine corpus path |
| `QDRANT_URL` | Shared Qdrant REST URL |
| `LOCAL_AI_API_URL` / `LOCAL_AI_BASE_URL` | localAIStack API URL |
| `INTEGRATIONS_CONFIG` | PE source and provider registry |
| `HEALTHKIT_BRIDGE_ID`, `HEALTHKIT_BRIDGE_TOKEN` | HealthKit bridge identity and optional token |

## Documentation Audit Findings

Current state:

- Runtime startup defaults are aligned to the canonical native port bands.
- HealthKit bridge templates use runtime-specific PE ports: Scala `5000`,
  CPP `5300`, LSP `5600`.
- `RealityEngine_Machines` owns the machine corpus and validates with zero hard
  corpus errors in compatibility mode.
- `RealityEngine_Manager` supports registry-aware runtime switching through
  `RE_REGISTRY_URL`.

Remaining documentation gaps:

- Historical examples still exist in some runtime docs. These must be labeled
  as deprecated compatibility examples when they mention `3299`, `3300`, or
  `VECTOR_DIMENSION=768`.
- The surface specification has multiple copies. CI must enforce byte-for-byte
  equality so doc drift is caught before deployment.
- Machine operations need to be described from the point of view of both RE
  and PE. That specification now lives in
  `RealityEngine_Machines/docs/REALITY_PERCEPTION_OPERATIONS.md`.
- Multi-engine conformance must require at least two registered engines in the
  multi-engine job. Single-engine smoke should remain a separate test class.

## Full Deployment Gates

The integrated system is deployable only when all of the following pass from a
clean source state:

| Gate | Command |
| --- | --- |
| CPP build | `make all` in `RealityEngine_CPP` |
| CPP unit tests | `make test` in `RealityEngine_CPP` |
| CPP HealthKit e2e | `make e2e-healthkit-spezi` in `RealityEngine_CPP` |
| Scala RE compile | `sbt compile` in `RealityEngine_Scala` |
| Scala PE compile | `sbt compile` in `RealityEngine_Scala/perception-engine` |
| Scala HealthKit e2e | `make e2e-healthkit-spezi` in `RealityEngine_Scala/perception-engine` |
| LSP build | `make build` in `RealityEngine_LSP` |
| LSP tests | `make test` in `RealityEngine_LSP` |
| LSP HealthKit e2e | `make e2e-healthkit-spezi` in `RealityEngine_LSP` |
| Manager frontend build | `npm run build` in `RealityEngine_Manager/visualizer/frontend` |
| Machines corpus validation | `bash scripts/validate-corpus.sh` in `RealityEngine_Machines` |
| CI shell lint | `bash -n startUniverse.sh stopUniverse.sh statusUniverse.sh scripts/*.sh scripts/tests/*.sh` in `RealityEngine_CI` |
| Surface spec drift | `bash scripts/check-surface-specs.sh` in `RealityEngine_CI` |
| Multi-engine conformance | `_CI/startUniverse.sh --no-openclaw --skip-seed --engines=scala:1,lsp:1` plus `RealityEngine_Machines/tests/integration/multi-instance.spec.ts` |

## Current Validation Snapshot

As of this audit, the following gates are green:

- CPP build: `make all`
- CPP unit tests: `make test`
- CPP HealthKit Spezi e2e: `make e2e-healthkit-spezi`
- Scala RE compile: `sbt compile`
- Scala PE compile: `sbt compile`
- LSP build: `make build`
- Manager frontend build: `npm run build`
- Manager backend build: `npm run build`
- Machines corpus validation: `bash scripts/validate-corpus.sh`
- CI shell lint: `bash -n startUniverse.sh stopUniverse.sh statusUniverse.sh scripts/check-surface-specs.sh scripts/*.sh scripts/tests/*.sh`
- Surface spec drift: `bash scripts/check-surface-specs.sh`

The full CPP corpus e2e gate is not yet green. `make e2e` currently stops in
`e2e-corpus` with machine sequence expectation mismatches in:

- `CommunityCommandAgent.json`
- `FallSensorMotionPreaggregator.json`

These failures block a full deployment declaration even though the focused
HealthKit BP/exercise/sleep bridge path is passing.

## Roadmap To Full Integrated Specifications

### Phase 1: Freeze Contract Sources

- Treat `DEPLOYMENT_CONTRACT.md`, `SURFACE_SPEC.md`, and this file as the only
  cross-repo deployment authorities.
- Add a CI check that fails when runtime `SURFACE_SPEC.md` copies differ.
- Keep runtime README files descriptive and link back to these authorities.

### Phase 2: Remove Documentation Drift

- Replace old native examples that use `3299/3300` with canonical runtime
  ports, or explicitly mark them as deprecated compatibility examples.
- Standardize all references to `VECTOR_DIMENSION=7680` as the deployment
  floor. Smaller values may appear only in algorithm examples or test fixtures
  that are clearly scoped.
- Keep HealthKit Spezi bridge examples runtime-specific.

### Phase 3: Enforce Runtime Parity

- Require all runtime builds and HealthKit BP/exercise/sleep e2e tests.
- Keep smoke scripts in each runtime repo and use the same `--target` and
  `--pe-target` argument names.
- Promote failures in startup scripts, registry loading, source ingest, and
  multi-engine routing to hard failures.

### Phase 4: Validate Multi-Engine Deployment

- Start one runtime at a time through `_CI/startUniverse.sh`.
- Seed `RealityEngine_Machines`.
- Verify Manager reads `RE_REGISTRY_URL` and can switch active runtime.
- Run a true two-runtime multi-instance conformance job.

### Phase 5: Publish Release Contract

- Tag the six repositories at compatible commits.
- Record the deployment contract version and surface spec hash in release
  notes.
- Keep the machine corpus validation summary with the release artifact.
