# RealityEngine Regression Test Workflow

This document defines the roadmap and initial executable framework for a
certification-grade Regression Test workflow over the standard deployed
multi-engine system.

The workflow is owned by `RealityEngine_CI` because it coordinates sibling
repositories, starts the universe, owns the runtime registry, and already hosts
deployment validation, MCP, Swagger/OpenAPI, MQTT, OpenClaw, and observability
contracts.

## Goals

- Build every development asset from a reproducible `Regression-Test` branch
  cut from current `main` in each participating repository.
- Cold-start the standard multi-engine universe:
  `cpp:1,lsp:1,scala:1` with PE source bootstrap, MCP HTTP, OpenAPI Swagger,
  localAIStack, and OpenClaw where configured.
- Exercise live PE universal input event vectors and verify parity of their
  downstream effect across CPP, LSP, and Scala.
- Exercise MQTT with the Yuma example stream.
- Exercise MCP through the open Streamable HTTP service exposed by the
  deployment (`http://127.0.0.1:7331/mcp`).
- Exercise OpenClaw step by step, including async handoff and return through
  the configured PE completion source.
- Preserve a queryable history of regression runs without committing generated
  logs, local state, or transient worktrees.

## Framework Choice

The regression framework should be a shell-first orchestrator with small Python
or Node helpers where structured comparison is required.

Use the existing CI primitives as the test framework:

- `scripts/deploy-validate-agent.sh` for deployment lifecycle discipline.
- `startUniverse.sh` / `stopUniverse.sh` for the authoritative start/stop
  contract.
- `/tmp/re-registry/re-registry.json` as the service inventory for active RE/PE
  pairs.
- `scripts/test-three-engine-full.sh` for existing multi-engine service
  discovery patterns and parity precedent.
- `scripts/test-mqtt-yuma.sh` for MQTT validation using the Yuma stream.
- `mcp/src/http-server.js` and `mcp/bin/realityengine-mcp.js` for MCP service
  verification.
- `scripts/test-openclaw-integration.sh` for OpenClaw async PE completion
  verification.
- `scripts/regression-service-inventory.py` for deployed-service inventory,
  readiness gates, and Swagger proxy verification.
- `scripts/regression-universal-vectors.py` for regression-specific universal
  vector parity checks.

This keeps the workflow close to the deployed system and avoids introducing a
second test framework that would need its own runtime model.

## Testable Service Inventory

The regression runner identifies testable services in this order:

1. Runtime registry: `/tmp/re-registry/re-registry.json`
   - `runtime`
   - `id`
   - `re_url`
   - `pe_url`
   - `status`
2. Fixed CI infrastructure:
   - Grafana: `http://localhost:3002/api/health`
   - Prometheus: `http://localhost:9090/-/ready`
   - Loki: `https://localhost:3100/ready`
   - Qdrant: `http://localhost:4333/collections`
   - Ollama: `http://localhost:11434/api/tags`
   - localAIStack: `http://localhost:4000/health`
   - Bridge metrics: `http://localhost:7342/healthz`
3. MCP HTTP:
   - health: `http://127.0.0.1:7331/healthz`
   - endpoint: `http://127.0.0.1:7331/mcp`
4. OpenAPI Swagger:
   - portal: `http://127.0.0.1:8088/`
   - proxy execution: `/proxy/{cpp,lsp,scala}/{re,pe}/api/health`
5. OpenClaw:
   - gateway: `http://localhost:18789/healthz`
   - async completion path through PE:
     `/api/integrations/acp/dispatch` ->
     `/api/integrations/completions` ->
     `/api/sources`

The executable inventory gate writes
`.regression-tests/runs/<run-id>/reports/service-inventory.json`. Runtime
shape, RE/PE health, MCP health, Swagger health, and Swagger proxy health are
required checks. Grafana, Prometheus, bridge metrics, localAIStack, Ollama, and
OpenClaw readiness are recorded separately; OpenClaw becomes required when the
regression run is configured with `--openclaw`.

## Cold Start Model

The fully operational workflow should never mutate the developer's checked-out
working branches directly. It should:

1. Create a run id: `YYYYMMDDTHHMMSSZ`.
2. Create `.regression-tests/runs/<run-id>/`.
3. For every participating repo, fetch `origin/main`.
4. Create a run-local worktree at:
   `.regression-tests/runs/<run-id>/worktrees/<repo-name>`
5. Reset or create a run-unique branch in the `Regression-Test` family from
   `origin/main`, for example `Regression-Test-20260630T120000Z`. A unique
   branch avoids conflicts when previous run worktrees are retained for
   inspection.
6. Build from those worktrees only.
7. Start the universe from the CI worktree.
8. Write a manifest containing repo remote URL, source `main` SHA, regression
   branch SHA, build status, test status, and artifact paths.

For provenance and build certification without a deployed universe, use
`--build-only`. That mode still creates the run-local worktrees and executes the
full build phase, but skips universe startup and all live tests.

Participating repos:

- `RealityEngine_CI`
- `RealityEngine_CPP`
- `RealityEngine_LSP`
- `RealityEngine_Scala`
- `RealityEngine_Machines`
- `RealityEngine_Manager`
- `localAIStack`
- `localOpenClawStack`

`RealityEngine_AI` is deprecated and must remain untouched.

## Live Universal Vector Parity

The regression-specific parity probe should send at least five universal input
event vectors through each active PE and compare downstream effects across all
registered engines.

The current scaffold selects five event vectors dynamically from the
authoritative machine corpus:

1. Find startup-loadable machines with `perceptualMapping.input`.
2. Select `inputSequences[]` entries with non-zero `expectedOutputCount`.
3. Register a temporary PE source at the machine's universal input region.
4. `POST /api/push` through each engine's PE.
5. Save raw responses per engine.
6. Extract comparable signatures from each response.
7. Fail if signatures diverge.

This avoids hard-coded offsets and keeps the regression events tied to the
current corpus.

The selected set is written to `selected-events.json` with machine file,
machine id, sequence id, input region, values, expected output count, and
selection policy. A pinned `--event-fixture` may be supplied when a release or
certification run needs an exact event set. Raw engine responses remain
per-runtime files, while `normalized-comparison.json` captures signature
differences without transient ids or timestamps.

## MQTT Requirement

MQTT regression uses the Yuma example stream.

Required behavior:

- Use `scripts/test-mqtt-yuma.sh`.
- Prefer explicit `--mqtt-broker-url` and `--mqtt-mappings`.
- Fall back to the CPP Yuma mapping file or PE `/api/mqtt/example`.
- Run against each active PE URL discovered from the registry.
- Store one MQTT log per engine under the run history. The regression runner
  invokes `scripts/test-mqtt-yuma.sh` directly for each registered PE so the
  Yuma phase does not restart or reshape the deployed universe.

## MCP Requirement

MCP regression should connect to the open MCP service started by the universe:

- `GET /healthz`
- Streamable HTTP `initialize`
- `npm run -s list-tools`
- Read-only tool smoke against each runtime where possible:
  - `re.read_state`
  - `re.list_machines`
  - `pe.read_state`
  - `dispatch.read_ledger`

Mutating MCP tools remain gated unless the regression run explicitly sets
`RE_MCP_ALLOW_MUTATION=true` or `RE_MCP_ALLOWED_TOOLS`.

## OpenClaw Requirement

OpenClaw validation must remain asynchronous with respect to PE cycles.

Required step-by-step checks:

1. `GET /api/integrations/acp/status` confirms:
   - enabled
   - `adapter=openclaw-xacp`
   - `surface=xACP`
   - `noWaitDispatch=true`
2. Register the deterministic OpenClaw E2E dispatch seed PE source.
3. `POST /api/push` creates a dispatch ledger record.
4. `POST /api/integrations/acp/dispatch` accepts handoff with HTTP `202`.
5. Dispatch record moves to accepted state with correlation fields.
6. Local OpenClaw hello-agent posts a correlated completion.
7. Completion appears as the configured PE source mapping.
8. Downstream push demonstrates that PE has received the return path through
   source state rather than by blocking an engine cycle.

`scripts/test-openclaw-integration.sh` already covers most of this and should be
used as the executable baseline. The regression runner invokes it once per
active PE URL in the registry so the async return path is verified for each
engine runtime.

## History Management

Run history is stored under `.regression-tests/runs/<run-id>/` and ignored by
git. Each run should include:

- `manifest.json`
- `summary.md`
- `logs/`
- `reports/`
- `responses/`
- optional `worktrees/`

Best practices:

- Never commit run history by default.
- Store only metadata needed to reproduce a run in PRs or issues.
- Keep large raw logs local; summarize failures into issue bodies.
- Use a stable `run_id` and include it in every generated file.
- Retain the latest N local runs by default; archive selected certification
  runs outside the repo or attach them to release artifacts.

## Roadmap

### Phase 1 - Land the Scaffold

- Add `scripts/regression-test.sh`.
- Add `scripts/regression-universal-vectors.py`.
- Add `npm run test:regression`.
- Add `.regression-tests/` to `.gitignore`.
- Document the workflow in this file.

### Phase 2 - Cold Worktree Build

- Implement `--execute --cold-start`.
- Create `Regression-Test` worktrees from `origin/main` for all repos.
- Build:
  - CI: `npm ci`, OpenAPI generation/checks, MCP package install/tests.
  - CPP: `make all`.
  - LSP: `make build`.
  - Scala: `sbt clean compile`.
  - Machines: `scripts/validate-corpus.sh`.
  - Manager: `npm ci && npm run build` for visualizer and PE frontend/backend
    packages.
  - localAIStack/OpenClaw: `docker compose build`.
- Record build artifacts and SHAs in `manifest.json`.

### Phase 3 - Standard Multi-Engine Deploy

- Start from the CI worktree:
  `./startUniverse.sh --fresh --engines=cpp:1,lsp:1,scala:1 --openclaw --machine-load=runtime --pe-source-bootstrap=auto --warn-only`
- Verify registry has exactly one CPP, one LSP, and one Scala RE/PE pair.
- Verify observability, Swagger proxy, MCP HTTP, localAIStack, OpenClaw, and
  bridge metrics.
- Fail before payload tests when the runtime registry, RE/PE health, MCP
  health, or Swagger proxy health is not ready.

### Phase 4 - Regression Assertions

- Run five universal vector parity events.
- Run Yuma MQTT against every active PE.
- Run MCP health, initialize, tool catalogue, and read-only tool smoke.
- Run OpenClaw async handoff and completion return.
- Run deployment tests with `scripts/run-all-tests.sh --deployment`.

### Phase 5 - History and Certification

- Generate `summary.md` and machine-readable `manifest.json`.
- Produce a stable comparison report against the previous successful run.
- Add retention controls:
  - `--retain N`
  - `--archive PATH`
  - `--compare RUN_ID`
- Add optional GitHub issue creation for regressions.

### Phase 6 - CI Automation

- Add a manually triggered GitHub Actions workflow.
- Support scheduled nightly execution on a host with Docker, SBCL, SBT, Node,
  and local model dependencies.
- Upload selected run summaries as artifacts.
- Keep raw logs local or artifact-scoped, never committed to repo history.
