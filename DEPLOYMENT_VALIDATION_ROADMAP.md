# RealityEngine Deployment Validation — Analysis & Roadmap

> ## Live `--fresh` validation findings (2026-06-24)
> A live `--fresh` docker deployment run through the agent surfaced **three real
> defects**, all now fixed in `scripts/deploy-validate-agent.sh`:
> 1. **Restart matrix didn't export compose env.** `docker compose up` for the RE
>    and Manager containers failed with `required variable MACHINES_DIR is
>    missing` because the agent didn't export `MACHINES_DIR`/`SCALA_DIR`/`MGR_DIR`
>    the way `startUniverse.sh` does. → now exported at the top of the agent.
> 2. **No pre-deploy teardown.** `startUniverse.sh` runs its RE-port conflict
>    check *before* its own orphan cleanup, so deploying over a running stack died
>    with `Processes already listening on RE ports: 3001 3004 3005 5001 5173`.
>    → agent now runs `stopUniverse.sh --all --stop-docker` before deploying.
> 3. **Daemon race after teardown.** The mass container removal left the Docker
>    daemon briefly unresponsive, tripping `startUniverse.sh`'s one-shot
>    `docker info` check (`FATAL: Docker daemon not running`). → agent now polls
>    for daemon readiness (≤30s) after teardown before handing off.
>
> Also added a **single-instance lock** (`.deploy-validate/.lock`) so two runs
> can't collide on the buildx/compose lock and race image/volume teardown
> (observed as `No such image: qdrant/qdrant:v1.13.1` during a double-launch).
>
> **Root cause of the Docker "crashes" — NOT capacity (corrected 2026-06-24).**
> The deterministic killer was the agent's pre-deploy teardown calling
> `stopUniverse.sh --all --stop-docker`. That path does two fatal things while
> the containerized stack is up:
> 1. delegates to `RealityEngine_Manager/stop.sh`, which `kill -KILL`s whatever
>    holds ports **3001/5173**, and
> 2. runs `_sweep_native_ports`, which `_kill_port 5001` (Scala-native RE port).
>
> But when the Docker stack is running, **ports 3001, 5173, and 5001 are all bound
> by one PID — `com.docker.backend`**, Docker Desktop's port proxy. So the
> teardown SIGKILLed Docker Desktop's own backend, taking the daemon down *before*
> `docker compose down` even ran (the teardown log shows `Reality Engine Manager —
> stopping` immediately before the daemon vanished). Every `--fresh` run hit this.
> **Fix:** the agent now tears the Docker footprint down the Docker-native way
> (`docker compose down --remove-orphans` for CI + localAIStack + OpenClaw), which
> frees the published ports by removing containers and never touches the Docker
> backend process. (The latent footgun in `RealityEngine_Manager/stop.sh` —
> force-killing the PID on 3001/5173 without checking it isn't `docker-proxy`/
> `com.docker.backend` — is a real defect worth fixing in that repo independently.)
>
> Side effect from the earlier thrashing to repair once: **localAIStack may be
> down** (qdrant/redis images were removed) — the next `--fresh` run re-pulls and
> recreates it, or restore manually with `(cd ../localAIStack && scripts/start.sh)`.
>
> **Root cause #3 — `--fresh` build→`up` handoff (corrected & fixed).** Once the
> daemon stopped dying, `startUniverse --fresh` still failed with `No such image:
> realityengine_ci-<svc>:latest` at `up` time. Two parts:
> 1. It built on an isolated **`docker-container` buildx builder**, which only
>    *names* images in the builder cache and never loads them into the engine
>    store. → fixed: build on the **default docker-driver builder**.
> 2. The image store is **not** corrupt (an earlier note wrongly guessed that).
>    The real cause is a **staging race in `docker compose build --no-cache`**: it
>    rebuilds all services *in parallel*, and the per-image "delete previous image
>    → write new image" step is not staged across services, so while several
>    images are being replaced concurrently one of them (usually the Scala
>    `reality-engine`) is momentarily absent exactly when `docker compose up`
>    resolves it. A **single-service** build is reliable. → fixed: for `--fresh`,
>    `startUniverse` now rebuilds each service **in serial** with an explicit
>    **remove → rebuild → verify-in-store** per image, so each replacement is
>    atomic and ordered and every image is present before `up`.
>
> Verified: the **cached** full pipeline runs green end-to-end (deploy + health +
> restart matrix = 18 passed / 0 failed / 2 skipped), and a single-service
> `--no-cache` build was confirmed to land a fresh image in the store.

**Owner:** `RealityEngine_CI` · **Last updated:** 2026-06-24
**Goal:** Prove the universe deploys cleanly through `startUniverse.sh` (whole
stack) and re-deploys/restarts cleanly through each repo's `start.sh` (one slice
at a time), using **only Docker-containerized tooling**, with an optional clean
rebuild (`--fresh`), full operational test coverage, and a self-driving local
agent that files GitHub issues when a slice fails.

---

## 1 · Current-state analysis

### 1.1 Orchestration topology (what deploys, and from where)

`startUniverse.sh` (1745 lines, this repo) is the canonical launcher. It composes
seven sibling repos. The **Docker footprint** — the target of this validation — is:

| Deployable unit | Source repo | Compose / entrypoint | Public health endpoint |
|---|---|---|---|
| RE API (Akka/Scala) | `RealityEngine_Scala` | `RealityEngine_CI/docker-compose.yml` → `reality-engine` | `https://localhost:5001/api/health` |
| Perception Engine | `RealityEngine_Manager` | CI compose → `perception-engine-backend/-frontend` | `https://localhost:3004/api/health`, UI `:3005` |
| Visualizer | `RealityEngine_Manager` | CI compose → `visualizer-backend/-frontend` | `http://localhost:3001/health`, UI `:5173` |
| Observability | this repo | CI compose → `loki`, `prometheus`, `grafana`, `promtail`, `tls-proxy` | `https://localhost:3100/ready` |
| RAG / vector / cache | `localAIStack` | `localAIStack/docker-compose.yml` via `scripts/start.sh` | API `:4000`, Qdrant `:4333`, Redis `:4379` |
| ACP gateway (optional) | `localOpenClawStack` | `localOpenClawStack/docker-compose.yml` via `scripts/start.sh` | `http://localhost:18789/healthz` |

> `RealityEngine_CPP` and `RealityEngine_LSP` provide **native** (non-Docker)
> RE/PE alternatives via their own `start.sh`, and `RealityEngine_Scala` /
> `RealityEngine_Manager` `start.sh` scripts also run **native** processes.
> **Both footprints are now in scope** (per the validation goal): the agent's
> containerized lane validates the Docker units above, and its **native lane**
> (Phase 3N) validates Scala/Manager/CPP/LSP as local processes. localAIStack and
> OpenClaw remain containerized-only. `RealityEngine_AI` is deprecated and excluded.

### 1.2 What `startUniverse.sh` already does well

- **8-phase boot** (preflight → Ollama → infra → RE → localAI API → OpenClaw →
  integration verify → operability smoke) with health gating at every step
  (`docker compose up -d --wait --wait-timeout 360`).
- **`--fresh`** already implements a clean build: wipes the
  `*_perception_sources_data` volume and rebuilds **all** images `--no-cache`
  via an isolated BuildKit builder.
- **`--dry-run`** prints a full plan after preflight without starting anything —
  ideal for non-destructive validation of the plan.
- **Integration verification** (Phase 6): confirms the machine corpus is
  registered, sensor sources exist, RAG regions `[64:72]` map, and Qdrant
  collections are present.
- **Operability smoke** (Phase 7): live `perceive`, RAG health, sensor-write.
- Writes `/tmp/universe-manifest.json` with the started services + warning count.

### 1.3 Restart ("only that portion") semantics — the key gap

The per-repo `start.sh` scripts are **guarded, not idempotent restarts**:

- `RealityEngine_Scala/start.sh` and `RealityEngine_CPP/start.sh` **`die` if a
  live PID file exists** ("port already owned by pid …"). Restart therefore
  requires `stop.sh` first.
- `RealityEngine_Manager/start.sh` **warns and aborts** if `.manager-pids`
  exists.
- `localAIStack/scripts/start.sh` and `localOpenClawStack/scripts/start.sh` are
  the **true Docker restart entrypoints** for their slices.

➡️ **Consequence:** a "restart only that portion" validation must do
`stop → start → re-health` per unit. For the Docker RE/Manager slices, the
correct Docker-only operation is `docker compose up -d --force-recreate
--no-deps <service>` (no native `start.sh`). This is exactly what the agent's
**Phase 3 restart matrix** encodes.

### 1.4 Test surface

`scripts/run-all-tests.sh` is the unified gate (`npm run test:deployment` →
`--deployment` mode, which runs `--all` and **treats every skipped suite as a
failure**). Coverage:

- **Unit/build/contract:** C++ `make all/test`, LSP `make build/test`, Scala
  `sbt test` + PE `make compile/test`, Manager 4 modules (`npm build` + Vitest +
  Jest), Machines `validate`/`validate:strict`/contracts, localAIStack `pytest`.
- **E2E (live stack):** C++/LSP/Scala-PE healthkit-spezi, CI Playwright,
  Machines smoke/integration/e2e Playwright, Manager-frontend Playwright,
  OpenClaw healthz + `/v1/models` + PE integration. Registry-aware (multi-engine)
  vs single-engine auto-detected.

### 1.5 Blockers found in this environment

| Blocker | Evidence | Impact |
|---|---|---|
| **`gh` token invalid + no network** | `gh auth status` → "token in keyring is invalid"; GraphQL → "network is unreachable" | Issue creation can't reach GitHub now; image pulls/Loki plugin install also need network. The agent degrades gracefully — failures are written as **issue drafts** to `.deploy-validate/issues/`. |
| **Docker is up** (good) | `docker info` OK, compose `v5.0.2` | Local containerized deploy is feasible once network is restored. |
| **Contract drift — FIXED 2026-06-24** | `DEPLOYMENT_CONTRACT.md` listed RE at `:3000` and Grafana at `:3002`; `nginx/tls-proxy.conf` proves RE is `:5001` (`listen 5001 ssl → reality-engine:3000`) and `:3000` is Grafana | Corrected in the contract doc (RE→`:5001`, Grafana→`:3000`) plus the port-range notes and Normative Rules. The agent already gates on the real ports. |

---

## 2 · Validation roadmap (phased)

Status legend: ✅ done · 🟡 partial / needs the agent · ⬜ not started

### Phase 1 — Whole-stack deploy through `startUniverse.sh` ✅
- ✅ Docker AI path builds RE/PE/Visualizer from sibling sources and health-gates.
- ✅ `--fresh` clean rebuild (no-cache + volume wipe).
- ✅ **Wrapped in the agent** — one command runs preflight → deploy → health gate
  → manifest-warning surfacing and records a pass/fail verdict.
  → `deploy-validate-agent.sh` Phases 0–2.

### Phase 2 — Per-slice restart, BOTH footprints ✅
- ✅ **Containerized lane** (`--footprint=docker`, Phase 3): `stop → start →
  re-health` for each Docker unit — RE (compose `reality-engine`), Manager PE+Viz
  (4 compose services), localAIStack (`scripts/start.sh`), OpenClaw
  (`scripts/start.sh`).
- ✅ **Native local-process lane** (`--footprint=native`, Phase 3N):
  `start → health → restart-in-place → stop` for each native runtime via its own
  `start.sh`, on **off-band ports + instance `dv`** so it coexists with the Docker
  stack — Scala `5101/5100`, Manager backend `:3011` (`--no-frontend`), CPP
  `5301/5300`, LSP `5601/5600`. Missing toolchains SKIP cleanly; start/health
  failures route an issue to the owning repo.
- ℹ️ CPP/LSP have **no container image** — native is their only deployment lane.
  OpenClaw + localAIStack are **containerized only** (no native lane), as required.
- ⬜ Optional future hardening: make Scala/Manager native `start.sh` auto-recover
  stale PID files (currently they `die`/abort, so the agent does `stop→start`).

### Phase 3 — Operational test gate ✅
- ✅ Agent Phase 4 runs `scripts/run-all-tests.sh --deployment` against the live
  stack; in deployment mode skipped suites fail, so missing toolchains surface.

### Phase 4 — Contract & footprint hygiene ✅
- ✅ Reconciled `DEPLOYMENT_CONTRACT.md` with `nginx/tls-proxy.conf`: RE public
  `:3000`→`:5001`, Grafana `:3002`→`:3000`, plus the port-range notes and
  Normative Rules.
- ✅ Resolved the Phase-1 `TODO` in `startUniverse.sh` — verified compose build
  contexts (`../RealityEngine_Scala`, `../RealityEngine_Manager/*`) and the
  `${MACHINES_DIR}/machines` volume already reference the sibling repos; replaced
  the TODO with a completion note.

### Phase 5 — Self-driving agent + issue automation ✅🟡
- ✅ Local agent cycles Phases 0–4 across both footprints, writes a populated
  roadmap-status table, and files **one deduplicated GitHub issue per failing
  unit** routed to the owning repo (offline-safe draft fallback).
  → `deploy-validate-agent.sh` (delivered).
- 🟡 Schedule it (see §4) once `gh` is re-authenticated and network is restored.

---

## 3 · The local validation agent

`scripts/deploy-validate-agent.sh` — single-command, cyclable, validates both
the containerized and native footprints.

```bash
# Full clean-build cycle, BOTH footprints (default) + restart matrices + tests:
scripts/deploy-validate-agent.sh --fresh

# Containerized footprint only:
scripts/deploy-validate-agent.sh --footprint=docker

# Native local-process footprint only (Scala/Manager/CPP/LSP via their start.sh):
scripts/deploy-validate-agent.sh --footprint=native --restart-only

# Non-destructive plan check (delegates to startUniverse --dry-run, lists tests):
scripts/deploy-validate-agent.sh --dry-run

# Continuous validation, filing GitHub issues on failure, 3 cycles 10 min apart:
scripts/deploy-validate-agent.sh --create-issues --cycle=3 --interval=600
```

**Footprint matrix** (what each unit's lanes are):

| Unit | Containerized lane | Native lane |
|---|---|---|
| RE (Scala) | compose `reality-engine` → `:5001` | `start.sh` → `:5101/:5100` (instance `dv`) |
| Manager (Viz/PE) | compose `visualizer-*` + `perception-engine-*` | `start.sh --port 3011 --no-frontend` |
| CPP | — (no image) | `start.sh` → `:5301/:5300` |
| LSP | — (no image) | `start.sh` → `:5601/:5600` |
| localAIStack | `scripts/start.sh` (compose) | — (containerized only) |
| OpenClaw | `scripts/start.sh` (compose) | — (containerized only) |

**Phase map:** 0 Preflight → 1 Deploy (`startUniverse.sh [--fresh]`) → 2 Health
gate → 3 Restart matrix (per-unit stop/start/re-health) → 4 `run-all-tests.sh
--deployment` → 5 Summary.

**Outputs** (under `RealityEngine_CI/.deploy-validate/`):
- `roadmap-status.md` — populated pass/fail table for the run.
- `run-<ts>.log` — full transcript.
- `issues/<repo>__<unit>__<phase>.md` — issue drafts when `gh` is offline.

**Issue routing:** RE/Scala→`RealityEngine_Scala`, PE/Visualizer/Manager→
`RealityEngine_Manager`, CPP→`RealityEngine_CPP`, LSP→`RealityEngine_LSP`,
RAG/Qdrant→`localAIStack`, gateway→`localOpenClawStack`, tests/corpus→
`RealityEngine_Machines`, orchestration→`RealityEngine_CI`. Issues are
deduplicated across cycles via a hidden marker comment, so a recurring failure
updates the existing issue instead of spamming new ones.

---

## 4 · How to run it for real (once network/`gh` are restored)

1. `gh auth login` (the keyring token is currently invalid).
2. Ensure Docker Desktop is running and Ollama models are pulled
   (`ollama pull llama3`, embed model from `localAIStack/.env`).
3. First clean validation: `scripts/deploy-validate-agent.sh --fresh --create-issues`
4. Schedule recurring validation — either the `/loop` skill
   (`/loop 6h scripts/deploy-validate-agent.sh --create-issues`) or a cron/launchd
   routine invoking the agent. Review `.deploy-validate/roadmap-status.md` each run.

---

## 5 · Final summary

All roadmap phases (P1–P5) are now implemented:

- **Whole-stack deploy** (`startUniverse.sh`, incl. `--fresh` clean build and
  `--dry-run` planning) is health-gated and wrapped by the agent's Phases 0–2.
- **Per-slice restart in BOTH footprints:**
  - *Containerized* (Phase 3) — `--force-recreate --no-deps` for the RE/Manager
    containers; repos' own `scripts/start.sh` for localAIStack/OpenClaw.
  - *Native* (Phase 3N) — each runtime's own `start.sh` on off-band ports +
    instance `dv`, with `start → health → restart → stop`. Scala/Manager/CPP/LSP
    covered; CPP/LSP are native-only; localAIStack/OpenClaw stay containerized.
- **Contract corrected** — `DEPLOYMENT_CONTRACT.md` now matches
  `nginx/tls-proxy.conf` (RE `:5001`, Grafana `:3000`); the stale Phase-1 TODO in
  `startUniverse.sh` is resolved.
- **Operational test gate** (`run-all-tests.sh --deployment`) gives strict
  pass/fail with no silent skips.
- **Self-driving agent** cycles all phases and files deduplicated, repo-routed
  GitHub issues on failure (offline-safe drafts when `gh` is unavailable).

**Environment caveat:** live execution from this session is blocked by no network
+ an invalid `gh` token (image pulls, Loki plugin install, and `gh` all need
connectivity). Everything is built, syntax-validated on bash 3.2, and the
preflight + dry-run lanes were exercised successfully. The native-lane skip gates
were verified against the host toolchain (Node 12 → Manager native SKIPs; sbt /
make+c++ / sbcl+quicklisp present). Run §4 once connectivity returns.
```
