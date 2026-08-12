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
7. Provision runtime config into the CI worktree — `.env` and the four TLS
   artifacts under `certs/`. Both are gitignored, so a worktree created from
   `origin/main` never has them, and `startUniverse.sh` exits on the first
   missing one. On the local lane the operator's own `.env` is copied when it
   exists, since it carries the broker URLs and gateway keys the local stack
   needs; otherwise `.env.example` is used. Neither is overwritten if already
   present, so `--no-cold-start` against a real checkout is non-destructive.
8. Start the universe from the CI worktree.
9. Write a manifest containing repo remote URL, source `main` SHA, regression
   branch SHA, build status, test status, artifact paths, and the lane
   (`profile` plus the `coverage` it implies).

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
- Store one `mqtt-yuma-<instance>.json` report per PE with broker connection
  status, mapping count, expected Yuma source coverage, observed MQTT source
  count, final MQTT status, and categorized errors. If no broker URL is
  configured, write `mqtt-yuma-skipped.json` with the skip reason.

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

The executable MCP smoke writes `reports/mcp-smoke.json` with health status,
initialize status, session id, tool count, advertised tool names, and read-only
tool-call results for registry-backed runtimes. Mutation tools are not called by
the regression smoke.

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

Each OpenClaw run writes `openclaw-integration-<instance>.json` with dispatch
id, envelope id, correlation id, completion id, completion source id, ACP
status, handoff receipt, dispatch record, agent result, final PE source
observation, and downstream push response. When OpenClaw is disabled or no PE
instances are available, the runner writes `openclaw-skipped.json` with the skip
reason.

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
- Generate `summary.md` and `reports/regression-comparison.json` at the end of
  each run. By default, the comparison report uses the latest previous
  completed run; `--compare RUN_ID` pins a specific baseline, and
  `--archive PATH` exports a copy of certification artifacts without worktrees.

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

The executable automation lives in
`.github/workflows/regression-tests.yml`.

## Two Lanes

Regression runs in one of two lanes, selected by `--profile`. They are not
depth settings of one another: three things never run on a hosted runner, by
decision rather than by circumstance.

| | `--profile hosted` | `--profile local` |
|---|---|---|
| Runner | `ubuntu-latest` | operator hardware / self-hosted |
| Machine corpus | `standard-deployment` (12) | `standard-deployment` (12) |
| localAI + Ollama | never | yes |
| OpenClaw | never | yes |
| HealthKit bridge | never | yes (simulator) |

The lanes differ in **which services they are permitted to start**, not in how
much corpus they load. Both boot the same 12 machines, so a hosted-vs-local
comparison carries one variable rather than two. The local lane can still opt
into the full corpus explicitly with `--machine-corpus=full`; nothing does so
by default, and full-corpus load behaviour is covered by dedicated scaling
tests rather than by a lane default.

`local` is the default, so an operator running the script by hand gets the
whole stack of services.

The hosted profile **refuses** a flag that contradicts it — `--openclaw`,
`--local-ai` or `--machine-corpus=full` exit 2 with the conflict named. It does
not silently correct them. A quietly-enabled Ollama on a hosted runner does not
present as a mistake; it presents as a 350-minute timeout.

The workflow picks the lane from `runner.environment`, so registering a
self-hosted runner is sufficient to move a run to the local lane. Each run
records its lane and exclusions in `manifest.json` under `profile` and
`coverage`, because a hosted pass and a local pass are not interchangeable
certifications and the artifact should say which one it is.

Manual `workflow_dispatch` inputs:

- `run_mode`: `plan`, `build-only`, or `full`.
- `engine_spec`: default `cpp:1,lsp:1,scala:1`.
- `openclaw`: explicit opt-in for OpenClaw async integration checks. Setting it
  on a hosted runner fails the run — see Two Lanes above.
- `mqtt_broker_url` and `mqtt_mappings`: Yuma MQTT stream configuration.
- `mcp_url`: MCP Streamable HTTP service base URL.
- `swagger_url`: OpenAPI Swagger service base URL.
- `compare`: optional previous run id.
- `retain`: local retained run-history count.
- `archive_artifacts`: copy certification artifacts to the local archive.
- `create_issue_on_failure`: create or update a GitHub issue with the run id
  and selected summary sections when the workflow fails.

Scheduled execution is present but gated by repository configuration. Set
`REGRESSION_SCHEDULE_ENABLED=true` to allow the nightly schedule to run. The
schedule uses these optional repository variables:

- `REGRESSION_RUNNER_LABELS`: JSON runner label array; defaults to
  `["ubuntu-latest"]`. Setting it to a self-hosted label array also switches
  the run to the local lane, since the lane follows `runner.environment`.
- `REGRESSION_SCHEDULE_RUN_MODE`: defaults to `full`.
- `REGRESSION_ENGINE_SPEC`: defaults to `cpp:1,lsp:1,scala:1`.
- `REGRESSION_OPENCLAW`: defaults to `false`.
- `REGRESSION_MQTT_BROKER_URL`
- `REGRESSION_MQTT_MAPPINGS`
- `REGRESSION_MCP_URL`: defaults to `http://127.0.0.1:7331`.
- `REGRESSION_SWAGGER_URL`: defaults to `http://127.0.0.1:8088`.
- `REGRESSION_COMPARE_RUN`
- `REGRESSION_RETAIN`: defaults to `20`.
- `REGRESSION_ARCHIVE_ARTIFACTS`: defaults to `true`.

The workflow uses the `regression-live` GitHub environment so full or
credentialed runs can be protected by environment approvals and secrets. Use
`REPO_ACCESS_TOKEN` when private sibling repositories require a token beyond
the default `GITHUB_TOKEN`. OpenClaw-specific credentials should be scoped to
the same environment.

The workflow checks out these sibling repositories only:

- `RealityEngine_CI`
- `RealityEngine_CPP`
- `RealityEngine_LSP`
- `RealityEngine_Scala`
- `RealityEngine_Machines`
- `RealityEngine_Manager`
- `localAIStack`
- `localOpenClawStack`

`RealityEngine_AI` is deprecated and is intentionally not checked out or
touched by the regression automation.

Uploaded artifacts are limited to certification summaries and normalized
reports:

- `summary.md`
- `manifest.json`
- `reports/service-inventory.json`
- `reports/regression-comparison.json`
- `responses/universal-vectors/selected-events.json`
- `responses/universal-vectors/normalized-comparison.json`
- MQTT, MCP, and OpenClaw JSON reports when present

Run histories remain under `.regression-tests/` and are ignored by git.
