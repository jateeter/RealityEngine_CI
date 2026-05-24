# RealityEngine_CI — Deployment & Testing Roadmap

Orchestrates the full RealityEngine universe from these sibling source repos:

| Repo | Role |
|---|---|
| `RealityEngine_Scala` | RE API — Akka HTTP / SBT |
| `RealityEngine_Manager` | Visualizer (Node.js) + Perception Engine (Node.js) |
| `RealityEngine_Machines` | Machine corpus (skills) + all system-wide / e2e tests |
| `RealityEngine_CPP` | Native C++ runtime alternative |
| `RealityEngine_LSP` | Common Lisp runtime alternative |
| `localAIStack` | Qdrant, Redis, FastAPI RAG orchestration, Open WebUI |
| `localOpenClawStack` | OpenClaw ACP xACP gateway + Open WebUI |

`RealityEngine_CI` owns only: `docker-compose.yml`, `certs/`, `config/`,
`nginx/`, `scripts/`, and the `startUniverse.sh` / `stopUniverse.sh` orchestrators.
It does **not** own machine definitions, source code, or test suites.

---

## Status: All Phases Complete ✓

---

## Phase 0 · Establish RealityEngine_Machines Structure  ✓

**Completed layout:**
```
RealityEngine_Machines/
  machines/
    core/
    domains/
  tests/
    e2e/
      global-setup.ts          ← waits for all 5 services incl. PE + localAIStack
      global-teardown.ts       ← calls stopUniverse.sh in CI mode
      specs/
        api.spec.ts                          (migrated from CI)
        full-integration.spec.ts             (migrated from CI)
        multi-step-output-workflow.spec.ts   (migrated from CI)
        perceptual-space-interconnection.spec.ts (migrated from CI)
        visualizer-ui.spec.ts                (migrated from CI)
    smoke/
      services-up.spec.ts      ← lightweight HTTP checks, no browser
    integration/
      pe-sensor-registration.spec.ts
      rag-round-trip.spec.ts
      corpus-integrity.spec.ts
      openclaw-health.spec.ts
  scripts/
    seed-machines.sh           ← POST all machines/ JSON to a running RE
    validate-corpus.sh         ← schema-check before seed
  package.json
  playwright.config.ts
  tsconfig.json
```

---

## Phase 1 · Docker-Compose Source-Repo Wiring  ✓

`docker-compose.yml` build contexts updated:

| Service | Context |
|---|---|
| `reality-engine` | `../RealityEngine_Scala` |
| `visualizer-backend` | `../RealityEngine_Manager/visualizer/backend` |
| `visualizer-frontend` | `../RealityEngine_Manager/visualizer/frontend` |
| `perception-engine-backend` | `../RealityEngine_Manager/perception-engine/backend` |
| `perception-engine-frontend` | `../RealityEngine_Manager/perception-engine/frontend` |

Machine corpus volume: `${MACHINES_DIR}/machines:/app/machines:ro`

`docker/scala/Dockerfile` updated: removed `scala/` prefix from all COPY paths (context is now `RealityEngine_Scala` root). Machine directory changed from baked-in `examples/machines` to runtime-mounted `/app/machines`.

---

## Phase 2 · Machine Seeding from RealityEngine_Machines  ✓

`startUniverse.sh` Phase 4 now:
1. Runs `validate-corpus.sh` (schema check)
2. Calls `seed-machines.sh https://localhost:3000` (POST all JSON to RE)
3. Logs to `/tmp/corpus_seed.log`

New flag: `--skip-seed` bypasses seeding when corpus is already loaded.

---

## Phase 3 · .env and Certificate Setup  ✓

- Created `RealityEngine_CI/.env.example` with all required variables
- Rewrote `scripts/setup.sh`: prerequisites → .env → TLS certs → Loki driver → sibling repo check

---

## Phase 4 · GitHub Actions CI Workflow  ✓

Updated `.github/workflows/e2e-tests.yml`:
- Two jobs: `smoke-tests` (fast, blocks e2e) + `e2e-tests`
- Checks out all 6 sibling repos at sibling paths before starting
- Calls `startUniverse.sh` (not bare `docker compose up`)
- Runs tests from `RealityEngine_Machines/tests/` (smoke → integration → e2e)
- Logs all services on failure including corpus seed log
- `REPO_ACCESS_TOKEN` secret for private repo checkouts

---

## Phase 5 · End-to-End + Integration Test Suite  ✓

All suites live in `RealityEngine_Machines/tests/`:

| Suite | File | What it tests |
|---|---|---|
| smoke | `smoke/services-up.spec.ts` | All 5 service health endpoints, no browser |
| integration | `integration/pe-sensor-registration.spec.ts` | Sensor count + RAG region [64:72] |
| integration | `integration/rag-round-trip.spec.ts` | Qdrant, RAG health, machine registrations |
| integration | `integration/corpus-integrity.spec.ts` | Every corpus JSON present in RE after seed |
| integration | `integration/openclaw-health.spec.ts` | Gateway /healthz + ACP token (opt-in) |
| e2e | `specs/api.spec.ts` | RE API CRUD: vectors, sequences, engine stats |
| e2e | `specs/full-integration.spec.ts` | Create → process → visualizer → cleanup |
| e2e | `specs/visualizer-ui.spec.ts` | UI shell, machine cards, search, interconnect |
| e2e | `specs/perceptual-space-interconnection.spec.ts` | MultiStep → RS2 + RSFlipFlop interconnect |
| e2e | `specs/multi-step-output-workflow.spec.ts` | Both sequences, auto-play, metadata |

---

## Phase 6 · Manager Native-Mode Integration  ✓

New flag `--manager-native` on `startUniverse.sh`:
- Validates `RealityEngine_Manager/start.sh` exists
- After RE services are healthy, starts Manager with `--scala` preset (RE :5001, PE :5000)
- Polls `http://localhost:3001/health` and `http://localhost:5000/api/health`
- PID written to `/tmp/manager_universe.pid`

`stopUniverse.sh` extended with `stop_manager_native()`:
- Kills Manager PID from file
- Delegates to `RealityEngine_Manager/stop.sh`

---

## Phase 7 · Prometheus + Grafana  ✓

`config/prometheus.yml` additions:
- `localaistack-api` job — scrapes `host.docker.internal:4000/metrics`
- `qdrant` job — scrapes `host.docker.internal:4334/metrics`

New Grafana dashboard: `config/dashboards/localaistack-overview.json`
- Request rate + p95 latency panels (Prometheus)
- Qdrant collections + vectors stats
- localAIStack log panel (Loki)

---

## Phase 8 · Release Pinning + Version Validation  ✓

New files:
- `VERSION-COMPAT.md` — compatibility table (Repo | Version/Tag | Branch)
- `scripts/validate-versions.sh` — reads table, checks each sibling repo's current HEAD

`startUniverse.sh` pre-flight now calls `validate-versions.sh --warn-only` (non-blocking).

To pin a specific release:
```
# VERSION-COMPAT.md
| RealityEngine_Scala | v2.1.0 | main |
```

---

## Port Reference

| Service | Host Port | Protocol |
|---|---|---|
| RE API (Akka HTTP) | 3000 (docker) / 5001 (native Scala) | HTTPS / HTTP |
| Visualizer Backend | 3001 | HTTPS |
| Grafana | 3002 | HTTPS |
| Perception Engine Backend | 3004 (docker) / 5000 (native Scala) | HTTPS / HTTP |
| Perception Engine Frontend | 3005 | HTTPS |
| Visualizer Frontend | 5173 | HTTPS |
| CI Loki | 3100 | HTTPS |
| localAIStack FastAPI | 4000 | HTTP |
| Open WebUI (localAIStack) | 4080 | HTTP |
| Qdrant REST | 4333 | HTTP |
| Redis | 4379 | TCP |
| Ollama | 11434 | HTTP |
| OpenClaw Gateway | 18789 | HTTP |
| Open WebUI (OpenClaw) | 8080 | HTTP |
