# Release Roadmap: Release 0.01 / MVP (`release-v0.0.1`)

Last reviewed: 2026-10-17

This is the task tracker for the first MVP release of the integrated RealityEngine
application. It is the one place where release work is listed, ordered and
checked off. Everything here is a task with an ID, an owner area, its
dependencies and a definition of done.

[`MVP_ROADMAP.md`](MVP_ROADMAP.md) keeps the gate history (G1–G4) and the
evidence behind it. [`../RELEASE.md`](../RELEASE.md) defines how a release is
built, certified, cut, installed and rolled back. This file brings the
evaluation tasks R01–R15 (drafted in PR #560, not merged) into one sequence
together with the work the primary target adds; the
[mapping](#mapping-from-r01r15) shows where each R-task went.

**Decisions A1–A11 were made on 2026-10-17** (below). Work proceeds A → B → C →
D → E → F, followed by the full release documentation.

## The release target

> **A Mac with Apple Silicon running macOS 26 or later can download versioned
> RealityEngine Docker images and install, with one command, a full working
> deployment of the RealityEngine suite.**

A full deployment means all of the following, running from published images and
needing no source checkout, compiler or build toolchain on the Mac:

| Component | Runs as |
|---|---|
| C++, Common Lisp and Scala Reality Engines and Perception Engines, **as many instances of each as the operator configures at start-up** (A7, A9) | containers |
| Machine corpus: the **regression corpus**, plus dynamic loading of further machines from `RealityEngine_Machines` after deployment (A8) | data image and a catalog volume |
| Instance registry, MCP server, integrations config, instance UUID allocation | containers (today host processes, C2) |
| Manager: Visualizer backend and frontend | containers |
| localAIStack API, Qdrant, Redis | containers |
| OpenClaw gateway, browser, Open WebUI | containers |
| PIM and the Solid Community Server (the authoritative POD) | containers |
| Prometheus, Loki, Promtail, Grafana (one stack) | containers |
| TLS front end | container |
| Ollama with `llama3.1:8b` | **native on the host**, so it uses the Apple GPU (A6) |
| HealthKit bridge | iPhone app built with Xcode: an **untested development deployment** in this release (A10) |

## Where we are, 2026-10-12

| Area | State | Evidence |
|---|---|---|
| Source build of all ten repos | **Green.** Every repo builds through CI at `origin/main` | local run `20261008T215059Z` |
| Hosted nightly regression | **Green 8 nights running** (2026-10-05 → 10-12). Parity stages pass on cpp/lsp/scala. MQTT Yuma skips nightly (broker timeout); localAI, OpenClaw, PIM mirror and HealthKit are refused by the hosted profile | `regression-tests.yml`, latest scheduled run 2026-10-12 at CI `7f6849f` |
| Weekly full-corpus cycle | **Green 3 weeks running.** 1,327 machines and 12 domains, nothing skipped; all three runtimes load 1,327 at event dimension 16,944; 1,322 agents rebuilt and matched | run 38113606637, 2026-10-11 |
| Local-lane certification | **Last candidate predates current main.** `20261008T215059Z` passed 17 live stages and skipped 3 (iPhone, Yuma, arbiter sweep), with the deployment suite not run. CI#561, Manager#257 and localAIStack#122/#123 merged after it | `.regression-tests/runs/20261008T215059Z/` |
| **Downloadable images** | **None.** Every RealityEngine image builds from a sibling checkout (`build: ../RealityEngine_*`). No image is published, except PIM's `:latest` on main. localAIStack's release workflow builds with `push: false` | `docker-compose.yml`; workflows |
| **Self-contained deployment** | **No.** The Docker path needs `MACHINES_DIR` and bind-mounts `./config`, `./certs`, `nginx/` and `../localAIStack/data/machines`. The instance registry, MCP and Ollama run on the host | `startUniverse.sh`, `docker-compose.yml` |
| **One deployment** | **No: four compose stacks** (CI, localAIStack, localOpenClawStack, PIM). `scripts/check-shared-service-versions.py` reports 8 divergences from `config/shared-service-versions.json`: Loki, Promtail, Grafana and Prometheus in CI's compose, Qdrant in `Dockerfile.qdrant`, and Open WebUI (`:main` in localAIStack, v0.9.6 in localOpenClawStack). No workflow runs the checker | compose files; the checker |
| Engines in containers | **Fixed trio only.** The Docker path runs `cpp:1,lsp:1,scala:1` as six hand-written services, live-verified on this Mac on 2026-10-03 (#516). Multi-instance is native-only | `docker-compose.yml`, CI#165 |
| Release model | **Commits, not artifacts**, until 2026-10-17. `RELEASE.md` is now revised for A2 | `RELEASE.md` §What a release is |

## How to track this file

- Each task has a status: `open`, `in progress`, `blocked`, `done` or `decided`.
  Change it in the same PR that changes the underlying state, and name the PR,
  run ID or issue that proves it. A task marked done without a reference is the
  failure mode `MVP_ROADMAP.md` warns about.
- When a task gets its own GitHub issue, add the issue number in the Tracking
  column.
- An unchecked task is open even when the code behind it has merged. Acceptance
  is evidence, not a merge.
- Anything found during the work but not fixed is recorded under the task as
  *noticed, not chased* (engineering contract).

### Status summary

| ID | Task | Area | Depends on | Status | Tracking |
|---|---|---|---|---|---|
| **A1** | Release version: `release-v0.0.1` | owner | — | decided 2026-10-17 | |
| **A2** | A release includes its images | owner | — | decided 2026-10-17 | |
| **A3** | Public GHCR, `ghcr.io/jateeter/re-<component>` | owner | A2 | decided 2026-10-17 | |
| **A4** | Apple Silicon only | owner | — | decided 2026-10-17 | |
| **A5** | Docker Desktop | owner | — | decided 2026-10-17 | |
| **A6** | Ollama native on the host | owner | — | decided 2026-10-17 | |
| **A7** | Instances configured at each start | owner | — | decided 2026-10-17 | |
| **A8** | Regression corpus shipped; dynamic loading from Machines | owner | — | decided 2026-10-17 | |
| **A9** | Scala, LSP and C++ instances all in the release | owner | — | decided 2026-10-17 | |
| **A10** | HealthKit bridge as an untested Xcode development deployment | owner | — | decided 2026-10-17 | |
| **A11** | #562/#563/#564/#317 are next-release features | owner | — | decided 2026-10-17 | |
| **B1** | One Dockerfile per image, and the image catalog | CI + repos | A2 | in progress | |
| **B2** | Self-contained images | CI + repos | B1 | open | |
| **B3** | Pin and unify third-party images | CI + repos | — | in progress | OCS#58, localAIStack#129, PIM#84 |
| **B4** | Native arm64 builds | CI | A4, B1 | in progress | |
| **B5** | Release image workflow | CI | A3, B4 | in progress | |
| **B6** | Image hygiene | all | B1 | open | |
| **C1** | Release compose, engines generated from the instance spec | CI | B2, B3 | in progress: live on the developer Mac |  |
| **C2** | Instance registry, MCP, config and UUIDs in containers | CI | B2 | in progress: live on the developer Mac |  |
| **C3** | Installer CLI | CI | C1, C2, A5, A6 | in progress: live on the developer Mac |  |
| **C4** | Persistence and lifecycle | CI | C1 | in progress: down/up and spec change verified |  |
| **C5** | Install documentation | CI/docs | C3, A2 | in progress: `INSTALL.md` drafted |  |
| **C6** | Dynamic machine loading from `RealityEngine_Machines` | CI + Manager | C2 | in progress: live on the developer Mac | Manager#276 |
| **D1** | Runtime and observability soak, multi-instance | CI/engines | C3 | in progress: multi-instance soak passed | LSP#165, Scala#191 |
| **D2** | 2D/3D UI acceptance | Manager | C3 | open | |
| **D3** | localAI reaches every engine | localAI/CI | C2 | in progress: passes on the install | |
| **D4** | PIM mirror in the deployment; bridge as development deployment | PIM/bridge | C3, A10 | in progress: mirror passes on the install | |
| **D5** | MQTT disposition | CI/MQTT | A11 | in progress: Yuma answering; stage passes | CI#578 |
| **D6** | Release asset checks | Machines/OpenClaw/CI | A8 | in progress | |
| **D7** | Deployment suite | CI | C3 | in progress: live suites green on the install | CPP#171, Scala#190, LSP#164, Machines#217 |
| **E1** | `local-containerized` lane on published images | CI | B5, C3 | in progress: development form green, 20/20 (`e1-20261019c`); certifying form needs an `-rc` push | CI#165 |
| **E2** | Native vs containerized comparison | CI | E1 | in progress: 54/56 measurements identical, 2 explained (CI#581) | |
| **E3** | Clean-Mac install test | CI/operator | B5, C3, C4 | open | |
| **E4** | Release eligibility enforced | CI tooling | A1, A2, B5 | open | |
| **E5** | Release documentation aligned | CI/docs | A1, A2 | in progress: `RELEASE.md` revised for A1–A11 | |
| **F1** | Freeze and final certification | release operator | D*, E1–E5 | open | |
| **F2** | Versioned manifest with image digests | release operator | F1 | open | |
| **F3** | Cut rehearsal | release operator | F2 | open | |
| **F4** | Publish tags and images | release owner | F3 | open | |
| **F5** | Release notes, full release documentation, released-set smoke | CI/docs | F4 | open | |

---

## A. Decisions, made 2026-10-17

Each is reflected in `RELEASE.md` where it changes the process.

- [x] **A1 — Version: SemVer `0.0.1`, tagged `release-v0.0.1`.** The milestone
  name is "Release 0.01". The tag is inside D1's `release-vN.M.Z` namespace, so
  `release-manifest.py` and `cut-release.sh` accept it unchanged; it cannot
  collide with the local `v0.0.1-baseline` tag.
- [x] **A2 — A release is the certified commit set plus the images built from
  those commits, pinned by digest in the release manifest.** `RELEASE.md` is
  revised accordingly.
- [x] **A3 — Public GHCR, `ghcr.io/jateeter/re-<component>`.** Public images
  need no login on the Mac. A new GHCR package is private until its visibility
  is changed once in the package settings; that is an owner step the first
  time each image is pushed (B5).
- [x] **A4 — Apple Silicon only (M1 and later).** Images are `linux/arm64`; no
  `amd64` image is released, and an Intel Mac is not supported.
- [x] **A5 — Docker Desktop.** The minimum version is set by E3. Other runtimes
  are not tested.
- [x] **A6 — Ollama native, not in Docker,** so it uses the Apple GPU. Containers
  reach it at `host.docker.internal:11434`. The installer checks for it and pulls
  `llama3.1:8b`, the model the local lane pins.
- [x] **A7 — Not a fixed trio: each start-up configures its own instance
  deployment,** as `startUniverse.sh --engines=cpp:N,lsp:N,scala:N` does
  natively. The engine services are generated from that spec (C1), each
  instance with its own UUID (#296) and instance-registry entry (C2).
- [x] **A8 — The shipped corpus is the regression corpus**
  (`config/regression-corpus.txt`). After deployment, machines can be loaded
  dynamically from `RealityEngine_Machines`, which is expected to grow and
  change over time (C6).
- [x] **A9 — Scala, LSP and C++ instances are all available in the release.**
  The legacy TLS-proxied pair (Scala `reality-engine` plus the TypeScript PE) is
  not an engine instance (#363) and stays in the development compose only.
- [x] **A10 — The HealthKit bridge is a Swift app for the iPhone, released now as
  an untested development deployment that needs Xcode to build and install.**
  The iPhone leg is not a release requirement; the PIM mirror it feeds stays
  release-blocking (decision D2 in `MVP_ROADMAP.md`).
- [x] **A11 — #562, #563, #564 and #317 are feature enhancements prepared for
  the next release.** None is part of `release-v0.0.1`. The release makes no
  LLM-drift-evaluation or MQTT-parity claim.

## B. Images: build and publish

- [ ] **B1 — One Dockerfile per image, and the image catalog.** Commit
  `release/images.json`: for every image, its name, source repo, build context,
  Dockerfile and the commit it is built from. Remove the duplicates: CI
  `docker/visualizer-*` and `docker/perception-engine-*` (Manager's own
  Dockerfiles are the ones the compose uses), and `RealityEngine_Scala/Dockerfile`
  and Scala's `perception-engine/Dockerfile` (CI's `docker/scala*` are the ones
  the compose uses).
  - Image set: `re-cpp`, `re-lsp`, `re-scala`, `re-scala-pe`,
    `re-visualizer-backend`, `re-visualizer-frontend`, `re-localai-api`,
    `re-mcp`, `re-openclaw-gateway`, `re-pim`, `re-css`, `re-init` and
    `re-registry` (C2), and `re-corpus` (A8).
  - **Done:** the catalog is committed, and each image builds from exactly one
    Dockerfile.
  - **Progress (2026-10-17):** `release/images.json` is committed with 13
    images, validated by `scripts/check-release-images.py` and its unit test in
    the Scripts Unit Tests job. CI's unused `docker/visualizer-*` and
    `docker/perception-engine-*` are removed, and Scala's own drifted copies
    (RealityEngine_Scala#189, merged).
- [ ] **B2 — Self-contained images.**
  - Bake configuration, nginx configuration and Grafana dashboards into the
    images.
  - `re-corpus` carries the regression corpus, materialized by
    `scripts/materialize-machine-corpus.sh` from `RealityEngine_Machines` and
    `localAIStack/data/machines` at the release pins. Engines and the OpenClaw
    agents load the same corpus from it.
  - Replace the bind mounts (`MACHINES_DIR`, `./config`, `nginx/`,
    `../localAIStack/data/machines`) with `re-corpus` and named volumes.
  - Generate certificates and secrets at first run (C3); never put them in a
    layer.
  - **Done:** every image starts with no host path mounted except named volumes
    and the generated certificate and secret volume.
- [ ] **B3 — Pin and unify third-party images.**
  - Converge every declaration on `config/shared-service-versions.json`. Today
    there are 8 divergences: CI's Loki, Promtail, Grafana and Prometheus;
    `Dockerfile.qdrant`; Open WebUI in localAIStack (`:main`) and
    localOpenClawStack. Then pin each by digest in the release compose.
  - Wire `scripts/check-shared-service-versions.py` into a workflow so a new
    divergence or floating tag fails a PR.
  - Base images follow the owner's rules: PIM moves from `node:22` to Node 26.8.
    Check the Scala builder/runtime JDK pairing (Temurin 17 builder, Temurin 25
    runtime).
  - **Done:** the checker passes and runs on every PR; no floating tag in any
    release image or compose file.
  - **Progress (2026-10-17):**
    - CI's compose is on Loki/Promtail 3.4.2, Grafana 11.6.1 and Prometheus
      v2.53.4. `config/loki-config.yml` is migrated for 3.x (`shared_store`
      removed, `delete_request_store` added). Verified in an isolated compose
      project: Loki 3.4.2 starts on fresh storage and on a copy of the existing
      2.9 volume, a pushed line queries back, Promtail ships the native cpp,
      lsp and scala logs, Grafana loads all 8 dashboards, and both data sources
      connect.
    - `Dockerfile.qdrant` was used by no compose file and is removed; the
      engines use localAIStack's Qdrant.
    - Open WebUI is v0.11.3 everywhere: localOpenClawStack#58 (merged; v0.11.3
      migrates a copy of the v0.9.6 data and keeps what `sync-webui-admin.sh`
      needs) and localAIStack#129 (merged; `:main` already reported 0.11.3).
      The checker passes across all ten repos.
    - The checker now always scans its own repo, says which repos it scanned,
      and includes PIM. It used to resolve the workspace from the real path,
      so a worktree run scanned nothing and passed. It runs in the Scripts
      Unit Tests job.
    - PIM on Node 26.8, non-root with a health check, runners pinned
      (PIM#84).
    - **Open:** digest pins in the release compose (C1).
- [ ] **B4 — Native arm64 builds** (A4). Build every image on `ubuntu-24.04-arm`,
  available to these public repos. No QEMU emulation and no amd64 image. Fix
  PIM's `ubuntu-latest` runner pin.
  - **Done:** every image builds green on a hosted arm64 run.
  - **Progress (2026-10-17):** `release/build-images.py` builds the catalog
    natively for `linux/arm64`. Locally, on an Apple Silicon Mac, all 11
    buildable images built: `re-cpp` 167 MB, `re-lsp` 249 MB, `re-scala`
    701 MB, `re-scala-pe` 590 MB, `re-visualizer-backend` 268 MB,
    `re-visualizer-frontend` 104 MB, and the rest. `re-visualizer-frontend`
    first failed on a stale cached `npm install` layer (TypeScript 7 without
    its linux-arm64 binary), from a tree that builds cleanly without the
    cache. A pushed build therefore always uses `--no-cache --pull`, and
    Manager's Dockerfiles should move from `npm install` to `npm ci` (B6).
    `release-images.yml` builds every image on `ubuntu-24.04-arm` for any PR
    that touches the image build.
- [ ] **B5 — Release image workflow** (`release-images.yml`). From a candidate
  manifest it checks out each repo at its pinned commit and builds every image
  in the catalog. It pushes to `ghcr.io/jateeter/re-<component>` tagged with
  the candidate tag (`release-v0.0.1-rcN`) and the commit SHA. It adds OCI
  labels (`source`, `revision`, `version`), SBOM and provenance attestations,
  and writes every digest to `images.json`. A `promote` mode retags certified
  candidate digests as `release-v0.0.1` without rebuilding. Pull-request builds
  don't push.
  - **Done:** a candidate build produces images whose `revision` labels equal
    the manifest's pins, and every package is public (A3).
  - **Progress (2026-10-17):** `release-images.yml`, `release/build-images.py`
    and `release/promote-images.py`. A dispatch with a candidate tag builds
    from `pins` (default: each repo's main), pushes with SBOM and provenance,
    and uploads the images file. A dispatch with `promote_from` retags the
    candidates by digest and refuses to move an existing release tag. A
    release tag can only be promoted, never built. Not yet run with a push:
    that needs the first dispatch on main and the packages made public.
- [ ] **B6 — Image hygiene.** Each image runs as a non-root user, has a
  `HEALTHCHECK`, contains no secrets, and stays within a size budget recorded
  per image. Today localAI is 1.44 GB and the OpenClaw browser 4.4 GB.
  - **Done:** a hygiene check in the image workflow passes for every image.

## C. Install bundle for macOS

- [ ] **C1 — Release compose, with the engines generated from the instance
  spec.**
  - `release/compose.yml` holds the fixed services, by image digest only, with
    no `build:` and no sibling path. It merges the CI, localAIStack,
    localOpenClawStack and PIM stacks into one project, with one monitoring
    stack, one Open WebUI and one Qdrant.
  - The engine services are not hand-written. `re-init` generates them from the
    operator's spec (`--engines=cpp:2,lsp:1,scala:1`, default
    `cpp:1,lsp:1,scala:1`) as `compose.engines.yml`. It writes one RE and one PE
    service per instance (`engine-cpp-1-re`, `engine-cpp-1-pe`, …) and the
    matching Prometheus targets.
  - **Ports:** published in bands per engine type and stride 10 per instance
    (PE then RE): scala 6100/6101, 6110/6111, …; cpp 6300/6301, …; lsp
    6600/6601, …. That allows up to 20 instances of a type without overlap, and
    the bands avoid what macOS holds (5000/7000, AirPlay Receiver).
  - **Done:** `docker compose config` validates for several specs, and `up`
    brings every service healthy with nothing but images and volumes.
- [ ] **C2 — Instance registry, MCP, config and UUIDs in containers.** Today
  `startUniverse.sh` serves the instance registry from a host shim, runs MCP as
  a host `node` process, generates `config/integrations.json`, and allocates
  instance UUIDs (`scripts/lib/instance_uuids.py`) into `~/.reality-engine/`.
  - Move all of it into `re-init`, a one-shot job, plus `re-registry`, a small
    instance-registry service. `re-init` reuses `instance_uuids.py` and the
    `registry_add` entry shape unchanged.
  - UUIDs persist in a named volume, and #296's rules still hold: one UUID per
    instance, never shared, kept across restarts. An instance removed from the
    spec keeps its UUID for when it returns.
  - The instance registry is served in two views of the same instances: host
    addresses (`localhost:<port>`) at `/re-registry.json`, which
    `registry_url()` and its helpers resolve, and container-network addresses
    for the services inside the deployment.
  - **Done:** for a multi-instance spec, the instance registry lists every
    instance with its UUID and no host process; `instance_uuids.py
    check-registry` passes.

**Progress on C1–C4 and C6, 2026-10-17.** `release/compose.yml`,
`release/init/` (`re-init`), `release/corpus/` (`re-corpus`), `release/config/`
and `release/realityengine` were installed live on the developer Mac (Apple
Silicon, macOS 26.6, Docker Desktop 29.8) from locally built arm64 images,
with `realityengine install --local`:

- **Everything up.** All 26 services healthy or completed (20 fixed, plus the trio's 6 engine services): the engines,
  instance registry, localAI with Qdrant and Redis, OpenClaw with its browser
  and Open WebUI, PIM with CSS and its bootstrap, MCP, Manager behind the TLS
  proxy, Loki, Promtail, Prometheus and Grafana.
- **Every surface answered, against the install itself:**
  - each engine RE and PE healthy, with the 23-machine regression corpus;
  - the instance registry's two views; `check-registry` passes;
  - each engine's `/api/engine/clock` reports the UUID `re-init` allocated;
  - Manager's UI over TLS, `/api/engines` listing every instance, and
    `/api/pe/*` proxied to the active PE;
  - the Load Machines catalog: 1,335 machines;
  - localAI `ok`, with `bridge_engines` equal to the instance registry;
  - the Open WebUI admin signs in with the generated credentials;
  - PIM reports `podAccess: true`;
  - MCP `ok`;
  - all engine targets up in Prometheus, 8 dashboards in Grafana, and every
    container's logs in Loki through Promtail's Docker discovery.
- **A7, the spec changed live** from `cpp:1,lsp:1,scala:1` to
  `cpp:2,lsp:1,scala:1`: `cpp-2` joined on its band ports (6310/6311) with a
  fresh UUID, every existing UUID was kept, and localAI picked it up.
- **C4: `down`, then `up`** kept the UUIDs and their Lamport clocks (0 →
  1024), a record written to the Solid pod, and the loaded machines, which are
  replayed into every instance.
- **C6:**
  - `machines load --domain ai-services` loaded 9 machines into all four
    instances and refreshed every PE;
  - `machines sync` replaced the catalog with RealityEngine_Machines `main`
    (`dde5f97c3f06`, 1,327 files) in 5 seconds;
  - a bad ref is refused with the catalog unchanged.
- **Memory:** the default trio uses about 3.9 GB of Docker memory when idle.
  Open WebUI is the largest (1.3 GB); each engine container is under 200 MB
  idle. The installer warns below 8 GB. Under-load figures are D1's.

Found and fixed on the way:
- **localOpenClawStack#59:** three scripts named `claude.md` for the tracked
  `CLAUDE.md`. `harden-config.sh` therefore failed on any case-sensitive
  filesystem, and `start.sh --fresh` deleted the file.
- **Manager#276:** Load Machines decided presence by id. C++ and Scala mint
  ids, so a repeated load gave them `<name> v2` copies and left LSP without
  them: three runtimes holding different machine sets.
- **localAI must restart when the instance spec changes.** It registers its
  machines with each engine at start, so `cpp-2` lacked them until localAI
  carried `RE_ENGINES` in its environment.
- **An image built while Docker's disk was full** (`re-visualizer-frontend`)
  had an empty nginx config and site, with the build reporting success.
  Rebuilt.

**Open:** the image registry pull path (B5's first push), a clean Mac (E3),
and `upgrade` between two published versions.
- [ ] **C3 — Installer CLI** (`realityengine install | up | down | status |
  upgrade | uninstall | machines`).
  - It is a small shell script that runs on the stock macOS `/bin/bash` (3.2),
    because a clean Mac has nothing else; the logic runs in `re-init`.
  - **Checks first:** macOS ≥ 26, Apple Silicon, Docker Desktop and its version
    (A5), the memory and disk given to Docker, and free ports.
  - **First run:**
    - Generate the local CA and certificates (from
      `certs/generate-dev-certs.sh`) and offer to trust the CA in the Keychain.
    - Generate the secrets: the HealthKit ingest token, the OpenClaw gateway
      token and the Grafana admin login.
    - Check native Ollama and pull the model (A6).
    - Run `re-init` for the instance spec, then `docker compose pull`, `up`,
      wait for health, and print the URLs.
  - It never writes into a source checkout. The incident behind the rule "never
    run workflow setup on the real checkout" is the reason.
  - **Done:** on a prepared Mac, `realityengine install` reaches a healthy suite
    and `status` reports every component and instance.
- [ ] **C4 — Persistence and lifecycle.**
  - Named volumes for instance UUIDs and clocks, the localAI state directory
    (`llm-drift.jsonl` and the removal record), Qdrant, Redis, the PIM/Solid
    PODs, Grafana, Prometheus and the machine catalog (C6).
  - `up --engines=` changes the instance spec of an installed release.
    `upgrade` moves to new digests and keeps the data; `upgrade --to <previous>`
    rolls back; `uninstall` keeps the data unless `--purge` is given.
  - **Done:** changing the spec, upgrading from a candidate to the release, and
    rolling back all keep the UUIDs and the POD contents.
- [ ] **C5 — Install documentation.** `INSTALL.md`: prerequisites, install,
  first run, choosing instances, URLs, loading machines (C6), troubleshooting
  (ports, Docker memory, Ollama, certificate trust), upgrade, uninstall, and the
  HealthKit bridge as an Xcode development deployment (A10).
  `DOCKER_QUICKSTART.md` becomes the development path and points to
  `INSTALL.md` for users.
  - **Done:** reviewed, and followed word for word in E3.
- [ ] **C6 — Dynamic machine loading from `RealityEngine_Machines`** (A8).
  - `realityengine machines sync [--ref <git ref>]` downloads
    `RealityEngine_Machines` at a ref (default `main`) from GitHub into the
    catalog volume. It validates the machines against the schema before
    accepting them. No git or checkout is needed on the Mac.
  - Manager's Load Machines modal offers the whole catalog, every domain, from
    that volume (`MACHINES_CATALOG_DIR`, Manager#257).
  - `realityengine machines load <name…> | --domain <d> | --all` loads machines
    into **every** running engine through the RE API, as
    `RealityEngine_Machines/scripts/seed-machines.sh` does, then refreshes PE
    sources (`scripts/pe-source-bootstrap.sh`). Loading the same set into every
    instance keeps the engines in parity.
  - The installed state records the catalog's ref and commit, and which
    machines were loaded beyond the shipped corpus.
  - **Done:** a machine merged to Machines `main` after the release is synced,
    loaded into a running multi-instance install, and reported identically by
    every engine.

## D. Product acceptance, run on the installed images

- [ ] **D1 — Runtime and observability soak, multi-instance** (was R04).
  - **Spec:** the default `cpp:1,lsp:1,scala:1` and a multi-instance spec,
    `cpp:2,lsp:2,scala:2` (A7).
  - **Checks:** every RE/PE health endpoint, unique stable instance UUIDs,
    machine-load counts, and that the running image digests match the manifest.
  - **Soak:** at least ten minutes of stepping, stream heartbeats and metric
    scrapes with no stream loss, health starvation or orphaned container.
  - **Observability:** Prometheus targets are up for every instance, engine logs
    reach Loki, and the Grafana panels show live data (CI#557/#558); idle or
    disabled panels are explained.
  - **Done:** a soak log and an endpoint/UUID inventory for both specs, tied to
    the image digests.
- [ ] **D2 — 2D/3D UI acceptance** (was R05). Engine switching across cpp, lsp
  and scala instances in both views; arcs and arrowheads, state changes, popup
  placement, no stale activity after a switch. Across themes and small
  viewports.
  - **Criteria:** arc/arrowhead contrast ≥ 3:1 and labels ≥ 4.5:1.
  - **Manager#254's gaps:** the matched ring is 2.4:1 under Light, 32×32 nodes
    open no tooltip, and Firefox/WebKit are untested.
  - The Load Machines modal offers the whole catalog and every domain (C6,
    Manager#257).
  - **Done:** a matrix with screenshots; each gap fixed or recorded as a
    limitation.
- [ ] **D3 — localAI reaches every engine** (was R06). localAI fans out to every
  engine instance on the container network. `verify_localai_reach` passes:
  every engine holds the same localAI machines and sensors, and
  `bridge_engines` equals the instance registry.
  - An in-scope 3-of-3 disagreement on identical deterministic input blocks
    the release.
  - LLM drift is collected (`/observations/drift`) but not evaluated (A11).
  - **Done:** the check passes on the containerized lane for both D1 specs.
- [ ] **D4 — PIM mirror in the deployment; the bridge as a development
  deployment** (was R07).
  - **Mirror cases, required (D2):** an approved batch is written; a conflict
    leaves the POD unchanged; no owner approval gives 403; changing the metric
    scope at run time is honoured. Run against the containerized PIM and Solid
    server.
  - **Bridge (A10):** document building and installing it from source with
    Xcode against the installed PE, including the TLS/CA trust and the ingest
    token. Not tested for this release; an iPhone run, if one happens, is
    recorded as extra evidence.
  - **Done:** green mirror results at the release commits, and the bridge's
    development-deployment instructions in `INSTALL.md`.
- [ ] **D5 — MQTT disposition** (was R08). Yuma has timed out on every nightly
  and on the last local run. Re-probe it on its own: record a pass, or record
  the named external-broker limitation. No MQTT-parity claim (A11).
  - **Done:** a Yuma result or limitation recorded at the release commits.
- [ ] **D6 — Release asset checks** (was R09). All eight families at the release
  corpus fingerprint: corpus validation (ROBOT, SHACL, QUDT, nothing skipped),
  JSON Schema, oracles, cesgen bindings, OpenAPI and its mirrors, CES contract
  shards, OWL baselines, and the OpenClaw agent index
  (`--require-current-digest`).
  - Count corpus machines (1,327) and JSON artifacts (1,337) separately.
  - **In progress:** the weekly cycle of 2026-10-11 (run 38113606637) is current
    full-corpus evidence: static sweep, load parity and agent corpus. It is not
    yet at the release pins.
  - **Done:** 8/8 at the release commits, tied to the corpus fingerprint.
- [ ] **D7 — Deployment suite** (was R10). Run the deployment suites against the
  installed bundle and its instance registry. Report availability, instance
  registry alignment, contract parity, byte equivalence and integration success
  separately, and let no in-scope failure hide behind a summary pass.
  - **Done:** an exact-pin report attached to the release evidence.

**Phase D progress, 2026-10-18/19**, on the install (`cpp:2,lsp:1,scala:1`),
from images built at the current mains. Each defect found was fixed at the
source, the image rebuilt, and the check re-run.

- **D7, the live suites, all green:**
  - CI multi-engine e2e: 26 passed, 0 failed, including every byte-equivalence
    surface of `tree-to-pe-manager-equivalence`.
  - RealityEngine_Machines smoke, integration and e2e: 63 passed, 0 failed,
    including the new declared-id 3-of-3.
  - Manager frontend e2e: all pass, `openclaw-portal` 6/6 against the
    install's own OpenClaw config.
  - Not exercised on this lane: `pe-source-arcs` (3 tests) posts to Manager's
    reported `pe_url`, the instance registry's container view, and Manager
    has no proxy route for `/api/sensors`.
- **Defects the suites found, fixed:**
  - C++ and Scala minted an id for every POST, while LSP reused a held one,
    replacing the resident machine. Owner rule 2026-10-18, "POST
    /api/machines keeps a declared id": CPP#171, Scala#190, LSP#164; 3-of-3
    guard Machines#217.
  - Scala's runtime lost machines under concurrent loads, from an
    unsynchronized machine map (Scala#191).
  - localAI's embed model: `ternary-bonsai:4` is not an embedding model, so
    the release uses `nomic-embed-text`.
  - PEs and localAI did not restart when their dependency was recreated; they
    now do (`restart: true`).
  - OpenClaw's agents did not follow machines loaded at runtime; they now do.
  - The CLI's port check was missing on `up`.
- **D1, the 10-minute soak, passed with 0 problems** (`release/soak.py`):
  - every PE push succeeded, median 63 ms on C++ and Scala and 231 ms on LSP;
  - every RE streamed 600–641 frames, with a longest gap of 3.1 s;
  - health clean, clocks monotonic, no container restarted, every engine
    target up in Prometheus;
  - peak memory 4.77 GiB. The Scala RE (832 MiB) and the LSP RE (760 MiB) grew
    toward their heap limits; a longer soak decides whether that is warm-up.
  - The soak's first run found **LSP's SSE streams sent nothing at all**: text
    written to Hunchentoot's binary stream, and `"\n"` is not an escape in Lisp.
    So Manager never saw LSP's live activity (LSP#165).
- **D3:** `verify_localai_reach`'s conditions hold. Every engine holds
  localAI's machines and sensors, and `bridge_engines` equals the instance
  registry, including after a spec change and after an engine image upgrade.
- **D4:** the bridge's `PIMWireTests` pass against the installed PIM and CSS:
  the approved batch, the conflict leaving the POD unchanged, no approval 403,
  a stale set 409, and a wrong token 401. The POD status counts the mirrored
  records, and every PE holds PIM's scope generation (D2b).
- **D5:** Yuma answers again (CONNACK in 0.3 s). The universe now boots without
  a broker, and the live MQTT stage runs after every universe measurement
  (CI#578). Branch run 39140096263, with Yuma live, passed, and the MQTT stage
  passed on all three engines. Noticed for #317: Scala declares a source per
  mapping when enabled, C++ and LSP on a mapping's first message.
- **Open:** D2 (UI matrix; noticed: the engine switcher shows container
  addresses), D6 at the release pins (the weekly cycle of 2026-10-18 at CI
  `f415302` is green), and a soak on the default trio.

## E. Certify the image product

- [ ] **E1 — `local-containerized` lane on published images** (CI#165).
  `scripts/regression-test.sh --profile local-containerized`. It installs the
  candidate's **published** images through C3, not local builds, for the given
  `--engines=` spec, then runs the local lane's stages. Same corpus and instance
  registry contract as the native lane.
  - **Done:** a green run that recorded the image digests it ran.
  - **Progress (2026-10-19).**
    - The lane is in `scripts/lib/containerized-lane.sh` (CI#578, CI#579).
      Without `--images` it builds the images from the run's worktrees as
      `dev-<run id>` and installs them, the development form; with
      `--images FILE` it installs a published candidate, the certifying form.
      Either way each image's revision label must equal the run's pin.
    - Run `e1-20261019b` (development form, `cpp:1,lsp:1,scala:1`): 15 of 20
      stages passed, including machine-set, export, engine-process and
      reset-contract parity, MCP, localAI, OpenClaw, MQTT and `pim-mirror`.
      `healthkit-bridge` skipped: no iPhone connected.
    - It found two release defects, fixed in CI#580:
      - **No arbitration or semantic-bus registry in any engine image.** The
        engines read `domains/` from beside `MACHINES_DIR`; natively they
        found it only through a fallback to the sibling Machines checkout,
        which a container does not have. Every engine booted with 0 of 2,837
        arbitration entries, which failed `trajectory-parity` and
        `arbitration-retention`. `materialize-machine-corpus.sh` now copies
        `domains/`.
      - **No engine PE could reach Ollama.** The PEs defaulted to
        `localhost:11434`, the container itself. re-init now sets
        `OLLAMA_BASE_URL` to the host.
    - The other three failures were the lane assuming native paths:
      - service inventory probed a Swagger UI the release does not ship; it is
        now recorded as not checked, with the reason;
      - `universal-vectors` read the native materialized corpus; the lane now
        materializes its own;
      - the arbiter refused the new lane name.
    - Noticed, not chased: `local-ai` passed while every PE reported Ollama
      unreachable, so that stage does not require PE reachability.
    - Run `e1-20261019c`, after CI#580: all 20 stages passed (development
      form), `healthkit-bridge` and `arbiter-sweep` skipped with reasons.
      Trajectory parity ran over the 2,837 contended cells, and every PE
      reaches Ollama.
    - Its `local-ai` report said failed while the stage recorded passed: the
      stage returned only its last command's status, and the probe listed
      Ollama's models at `host.docker.internal`, which the Mac does not
      resolve. Both are fixed in CI#581, as is the same status defect in
      `engine-process-parity`, which hid nothing in these runs.
    - Next: the certifying form, `--images` against a pushed `-rc`
      candidate. Pushing to GHCR waits for the owner.
- [ ] **E2 — Native vs containerized comparison.** Run the native local lane
  and E1 at the same commits and spec on the same Mac and compare the parity
  stages.
  - A disagreement that is still there after a re-run blocks the release; this
    comparison is the evidence that the images are the product.
  - **Done:** a comparison report with no unexplained difference.
  - **Progress (2026-10-19).**
    - `scripts/compare-lane-runs.py` (CI#581) compares what two runs measured,
      not their stage statuses. `regression-report.py --compare-run` compares
      statuses only, so it reports two lanes that pass the same stages as
      identical whatever they measured. The script masks values that differ
      between any two runs (times, epochs, UUIDs, origins, paths, run and
      generated ids, previews) and sorts lists whose order is the instance
      registry's.
    - Native `e2-native-20261019b` (`RE_FREE_PORTS=true`: macOS AirPlay holds
      5000, the Scala PE's fixed port) against containerized `e1-20261019c`,
      the same commit in all 10 repos: 20/20 stages on both, and 54 of 56
      shared reports and responses identical. Both remaining differences are
      explained:
      - `local-ai`: the probe defect above;
      - `service-inventory`: the release does not ship the Swagger UI or the
        host-side OpenClaw adapter metrics exporter (`bridge-metrics`, :7342,
        optional), which the native universe starts.
    - Next: rerun both lanes after CI#581, expecting `local-ai` to match.
- [ ] **E3 — Clean-Mac install test.** A Mac with Apple Silicon on macOS 26 with
  no checkouts, toolchains or cached images, and only Docker Desktop and native
  Ollama installed. Follow `INSTALL.md` word for word, run the smoke tests and
  D7, sync and load a machine (C6), then change the spec, upgrade, roll back
  and uninstall.
  - Use a second Mac or a clean user account with the Docker data reset;
    Docker inside a macOS VM is not reliable on Apple Silicon.
  - **Done:** a timed transcript, with the Docker Desktop minimum version
    recorded.
- [ ] **E4 — Release eligibility enforced** (was R03, extended). The release
  cutter refuses when:
  - an image digest is missing, or an image's `revision` differs from its pin;
  - the E1 lane is missing or not green;
  - the `pim-mirror` stage is skipped or failed (decision D2 in
    `MVP_ROADMAP.md`, 2026-09-25);
  - a required stage is missing, or the run is provisional. Stage status comes
    from the structured stage results, never from `stage-results.tsv`, which
    records a skipped stage's wrapper exit as success;
  - the parity stages in the run summary are missing from the manifest's stage
    map.
  - Tag text is generated from the manifest; today `cut-release.sh` always
    writes "hosted profile".
  - Tag collisions are checked on every remote, not only locally, and image-tag
    collisions in GHCR.
  - Failed tag or image pushes are aggregated into a nonzero result.
  - **Done:** positive and refusal tests for each case.
- [ ] **E5 — Release documentation aligned** (was R02). `RELEASE.md` covers the
  ten-repo inventory, the image model (A2), the platform (A4–A6), the two
  certifying lanes, and the command order. `docs/README.md` indexes this file
  and `INSTALL.md`.
  - **In progress:** `RELEASE.md` revised for A1–A11 on 2026-10-17; steps whose
    tooling is not yet built are marked *pending* with their task.
  - **Done:** no step marked pending, and no contradiction between
    `RELEASE.md`, this file and `MVP_ROADMAP.md`.

## F. Freeze, cut and publish

- [ ] **F1 — Freeze and final certification** (was R11). Every accepted fix is
  merged; every repo is clean and current with `origin/main`. Then run, at the
  same commits:
  - the native local lane:
    `RE_FREE_PORTS=true bash scripts/regression-test.sh --execute --profile local --run-id <final>`;
  - E1 on the candidate images built from those commits.
  - **Done:** both runs are non-provisional, with no required skip or failure,
    clean provenance, and a recorded decision for every optional omission.
    Any runtime change after this needs recertification.
- [ ] **F2 — Versioned manifest** (was R12). Run
  `scripts/release-manifest.py generate --run-dir .regression-tests/runs/<final> --images <candidate images.json> --version release-v0.0.1 --out releases/release-v0.0.1.json`.
  `--images` records every image digest and is added for this task.
  - Never hand-edit a pin, and never pass `--allow-unverified`.
  - Keep the certifying runs' evidence somewhere run-history pruning can't reach;
    that is how `main-1007` was lost.
  - `releases/v0.1.0-rc1.json` (8 repos, 2026-08-09) is historical and is
    superseded.
  - **Done:** ten full SHAs and every image digest, with no provisional marker.
- [ ] **F3 — Cut rehearsal** (was R13). `release-manifest.py verify` and the
  cutter without `--execute`, with E4's collision checks.
  - Generate the manifest without moving CI's HEAD; the record is committed
    after the cut through a docs PR.
  - **Done:** no drift, no conflicting tag or image, and the dry run names the
    certified set.
- [ ] **F4 — Publish tags and images** (was R14). Create the tags with
  `--execute` and review them; push with `--execute --push`; promote the
  candidate images to `release-v0.0.1` by digest, without rebuilding. Attach the
  installer to the GitHub release.
  - **Done:** every remote tag resolves to its manifest SHA and every release
    image to its manifest digest. A partial publication is not a release.
- [ ] **F5 — Release notes, full release documentation, and released-set
  smoke** (was R15).
  - Publish the release notes: the manifest and the certifying run IDs, the
    evidence for D1–D7 and E1–E3, and the known limitations below.
  - Complete the release documentation set: `INSTALL.md` (C5), `RELEASE.md`
    (E5), an operator guide (instances, machine loading, monitoring, data and
    backup, upgrade and rollback), the HealthKit bridge development-deployment
    guide (A10), the architecture and service map of the deployment, and the
    API references (`docs/openapi/`).
  - Smoke-test the released set by repeating E3 from the published release.
  - **Done:** all ten tags and every image verified, the notes and
    documentation published, and G1–G4 in `MVP_ROADMAP.md` marked accepted with
    references.

---

## Sequence

| Phase | Tasks | Exit |
|---|---|---|
| A. Decide | A1–A11 | **done 2026-10-17** |
| B. Images | B1–B6 | every image builds natively on arm64 and is pushed as a candidate |
| C. Install bundle | C1–C2, then C3–C6 | the bundle installs from images on the developer Mac, for any instance spec |
| D. Accept | D1–D7 | acceptance evidence or a recorded limitation for each |
| E. Certify | E1–E5 | `local-containerized` green; native and containerized agree; clean-Mac install passes |
| F. Release | F1 → F2 → F3 → F4 → F5 | tags and images published and verified; full documentation published |

**Biggest risks**, each unproven today, so start with them:
1. ~~**C2:** the deployment has never run without the host-side instance
   registry shim, MCP process and config generation.~~ Proven live 2026-10-17.
2. ~~**C1:** engine services generated per instance have never run.~~ Proven live
   2026-10-17, including a spec change from three to four instances.
3. **B4:** the LSP (SBCL) and Scala builds on hosted arm64 runners.
4. **E3:** the first install on a Mac that has never seen a checkout.

## Known limitations for the release notes

- Apple Silicon Macs on macOS 26 or later only; no Intel or Linux images (A4).
- Docker Desktop is the only tested container runtime (A5).
- Ollama runs natively on the host and must be installed first (A6).
- The HealthKit bridge is an untested development deployment, built and
  installed with Xcode (A10).
- Hosted checks don't cover Ollama, OpenClaw, the PIM mirror or the iPhone.
  Certification comes from the local and containerized lanes.
- MQTT Yuma availability is external (D5); no MQTT-parity claim (A11).
- LLM drift is recorded but not evaluated (A11).

## Next release (A11) and backlog

**Prepared for the next release** (feature enhancements, owner 2026-10-17):

- CI#562: difference-net training, after the Reality Event ↔ LLM Node
  isomorphism.
- CI#563: drift record in a full universe; cap the drift file.
- CI#564: gate order: `dynamic_validation_test` and MCP calls from later suites.
- CI#317: the deterministic MQTT parity stage.

**Backlog, not scheduled:**

- CI#526: unnamed-provider review and trust ranking.
- CI#287: engine snapshots, phase 2.
- CI#256: the two-stage fold.
- PIM #68/#69 (UX).
- localHealthkitBridge#40 (silence watchdog).
- localAIStack#113 (Lang* docs).

## Mapping from R01–R15

| Draft task (PR #560) | Here |
|---|---|
| R01 version and scope | A1, A7, A10, A11 |
| R02 release docs | E5, C5, F5 |
| R03 enforced eligibility | E4 |
| R04 six-instance soak | D1 (on images, default and multi-instance specs) |
| R05 2D/3D acceptance | D2 |
| R06 CI#518 disposition | D3; #518 closed 2026-10-09, follow-ups in A11 |
| R07 iPhone and PIM | D4, A10 |
| R08 MQTT | D5 |
| R09 release assets | D6 |
| R10 deployment acceptance | D7 |
| R11–R15 certify, cut, publish | F1–F5, extended with images |
