# Release Roadmap: Release 0.01 / MVP

Last reviewed: 2026-10-12

This is the task tracker for the first MVP release of the integrated RealityEngine
application. It is the one place where release work is listed, ordered and
checked off. Everything here is a task with an ID, an owner area, its
dependencies and a definition of done.

[`MVP_ROADMAP.md`](MVP_ROADMAP.md) keeps the gate history (G1–G4) and the
evidence behind it. [`../RELEASE.md`](../RELEASE.md) defines how a release is
certified, cut and rolled back. This file brings the evaluation tasks R01–R15
(drafted in PR #560, not merged) into one sequence together with the work the
primary target adds; the [mapping](#mapping-from-r01r15) shows where each R-task
went.

## The release target

> **A Mac running macOS 26 or later can download versioned RealityEngine Docker
> images and install, with one command, a full working deployment of the
> RealityEngine suite.**

A full deployment means all of the following, running from published images and
needing no source checkout, compiler or build toolchain on the Mac:

| Component | Runs as |
|---|---|
| C++, Common Lisp and Scala Reality Engines and Perception Engines (`cpp-1`, `lsp-1`, `scala-1`) | containers |
| Machine corpus (regression corpus; full corpus optional, A8) | data image |
| Instance registry, MCP server, integrations config, instance UUID allocation | containers (today host processes, C2) |
| Manager: Visualizer backend and frontend | containers |
| localAIStack API, Qdrant, Redis | containers |
| OpenClaw gateway, browser, Open WebUI | containers |
| PIM and the Solid Community Server (the authoritative POD) | containers |
| Prometheus, Loki, Promtail, Grafana (one stack) | containers |
| TLS front end | container |
| Ollama with `llama3.1:8b` | **native on the host** for Metal acceleration (A6) |
| HealthKit bridge | iPhone app, built and installed separately (A10) |

## Where we are, 2026-10-12

| Area | State | Evidence |
|---|---|---|
| Source build of all ten repos | **Green.** Every repo builds through CI at `origin/main` | local run `20261008T215059Z` |
| Hosted nightly regression | **Green 8 nights running** (2026-10-05 → 10-12). Parity stages pass on cpp/lsp/scala. MQTT Yuma skips nightly (broker timeout); localAI, OpenClaw, PIM mirror and HealthKit are refused by the hosted profile | `regression-tests.yml`, latest scheduled run 2026-10-12 at CI `7f6849f` |
| Weekly full-corpus cycle | **Green 3 weeks running.** 1,327 machines and 12 domains, nothing skipped; all three runtimes load 1,327 at event dimension 16,944; 1,322 agents rebuilt and matched | run 38113606637, 2026-10-11 |
| Local-lane certification | **Last candidate predates current main.** `20261008T215059Z` passed 17 live stages and skipped 3 (iPhone, Yuma, arbiter sweep), with the deployment suite not run. CI#561, Manager#257 and localAIStack#122/#123 merged after it | `.regression-tests/runs/20261008T215059Z/` |
| **Downloadable images** | **None.** Every RealityEngine image builds from a sibling checkout (`build: ../RealityEngine_*`). No image is published, except PIM's `:latest` on main. localAIStack's release workflow builds with `push: false` | `docker-compose.yml`; workflows |
| **Self-contained deployment** | **No.** The Docker path needs `MACHINES_DIR` and bind-mounts `./config`, `./certs`, `nginx/` and `../localAIStack/data/machines`. The instance registry, MCP and Ollama run on the host | `startUniverse.sh`, `docker-compose.yml` |
| **One deployment** | **No: four compose stacks** (CI, localAIStack, localOpenClawStack, PIM). Two monitoring stacks at different versions (Loki 2.9.3/3.4.2, Grafana 10.2.3/11.6.1, Prometheus 2.51.2/2.53.4). Qdrant 1.19.1/1.14.1. Open WebUI twice, once unpinned (`:main`) | compose files |
| Engines in containers | **Fixed trio only.** The Docker path runs `cpp:1,lsp:1,scala:1`, live-verified on this Mac on 2026-10-03 (#516). Multi-instance and every parity certification are native | CI#518 record, CI#165 |
| Release model | **Commits, not artifacts.** `RELEASE.md`: a release "is not a build artifact" | `RELEASE.md` §What a release is |

The primary target therefore changes what a release *is*: from a certified
commit set to a certified commit set **plus the images built from it** (A2).

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
| **A1** | Release version tag | owner | — | open | |
| **A2** | A release includes its images | owner | — | open | |
| **A3** | Image registry and visibility | owner | A2 | open | |
| **A4** | Supported architectures | owner | — | open | |
| **A5** | Supported container runtime on macOS | owner | — | open | |
| **A6** | Ollama placement | owner | — | open | |
| **A7** | Engine topology in the image release | owner | — | open | |
| **A8** | Corpus shipped | owner | — | open | |
| **A9** | Legacy TLS-proxied Scala + TypeScript PE pair | owner | — | open | |
| **A10** | HealthKit bridge delivery and device proof | owner | — | open | |
| **A11** | Release boundary for CI#562/#563/#564/#317 | owner | — | open | |
| **B1** | One Dockerfile per image | CI + repos | A2 | open | |
| **B2** | Self-contained images | CI + repos | B1 | open | |
| **B3** | Pin and unify third-party images | CI | — | open | |
| **B4** | Native multi-arch builds | CI | A4, B1 | open | |
| **B5** | Release image workflow | CI | A3, B4 | open | |
| **B6** | Image hygiene | all | B1 | open | |
| **C1** | One release compose file | CI | B2, B3 | open | |
| **C2** | Instance registry, MCP, config and UUIDs in containers | CI | B2 | open | |
| **C3** | Installer CLI | CI | C1, C2, A5, A6 | open | |
| **C4** | Persistence and lifecycle | CI | C1 | open | |
| **C5** | Install and release documentation | CI/docs | C3, A2 | open | |
| **D1** | Runtime and observability soak | CI/engines | C3 | open | |
| **D2** | 2D/3D UI acceptance | Manager | C3 | open | |
| **D3** | localAI reaches every engine | localAI/CI | C2 | open | |
| **D4** | iPhone → containerized PE, PIM mirror | bridge/PIM | C3, A10 | open | |
| **D5** | MQTT disposition | CI/MQTT | A11 | open | |
| **D6** | Release asset checks | Machines/OpenClaw/CI | A8 | in progress | |
| **D7** | Deployment suite | CI | C3 | open | |
| **E1** | `local-containerized` lane on published images | CI | B5, C3 | open | CI#165 |
| **E2** | Native vs containerized comparison | CI | E1 | open | |
| **E3** | Clean-Mac install test | CI/operator | B5, C3, C4 | open | |
| **E4** | Release eligibility enforced | CI tooling | A1, A2, B5 | open | |
| **E5** | Release documentation aligned | CI/docs | A1, A2 | open | |
| **F1** | Freeze and final certification | release operator | D*, E1–E5 | open | |
| **F2** | Versioned manifest with image digests | release operator | F1 | open | |
| **F3** | Cut rehearsal | release operator | F2 | open | |
| **F4** | Publish tags and images | release owner | F3 | open | |
| **F5** | Release notes and released-set smoke | CI/docs | F4 | open | |

---

## A. Decisions

These come first; they shape everything after. Each has a recommendation. A
decision is recorded here, with its date, and in `RELEASE.md` where it changes
the process.

- [ ] **A1 — Version tag.** D1 (2026-09-25) fixed the namespace as
  `release-vN.M.Z`. **Recommended:** tag `release-v0.1.0` and use "Release 0.01"
  as the milestone name. If 0.01 means SemVer `0.0.1`, tag `release-v0.0.1` and
  record the revision. Don't treat the two as the same.
- [ ] **A2 — A release includes its images.** **Recommended:** a release is the
  certified commit set **plus** the images built from exactly those commits,
  each pinned by digest in the release manifest. This revises `RELEASE.md`
  ("not a build artifact").
- [ ] **A3 — Image registry and visibility.** **Recommended:** public GitHub
  Container Registry, `ghcr.io/jateeter/re-<component>`. The repos are already
  public, and public images need no login on the Mac.
- [ ] **A4 — Architectures.** **Recommended:** `linux/arm64` (Apple Silicon) is
  required and certified. `linux/amd64` is built, since the hosted lane runs on
  amd64 and macOS 26 still supports some Intel Macs, but it is certified only by
  the hosted lane.
- [ ] **A5 — Container runtime on macOS.** **Recommended:** Docker Desktop is
  supported, with a minimum version set by E3. OrbStack, Colima and Apple's
  `container` are best-effort and not certified.
- [ ] **A6 — Ollama.** **Recommended:** native on the host (`brew install
  ollama`), reached from containers via `host.docker.internal:11434`, as
  localAIStack does today. Ollama in a container on a Mac gets no Metal GPU. The
  installer checks it and pulls `llama3.1:8b`, the model the local lane pins.
- [ ] **A7 — Engine topology.** **Recommended:** the image release runs the
  fixed trio `cpp:1,lsp:1,scala:1`, the same set the Docker path runs today.
  Six instances (`cpp:2,lsp:2,scala:2`) stays a native-lane proof (D1) and is
  not a promise the images make.
- [ ] **A8 — Corpus.** **Recommended:** ship the regression corpus
  (`config/regression-corpus.txt`) by default, and the full corpus (1,327
  machines) as an opt-in. Both go in a corpus data image tagged with the corpus
  fingerprint, so the engines and the OpenClaw agents load the same corpus.
- [ ] **A9 — Legacy pair.** The Scala `reality-engine` plus TypeScript PE behind
  `tls-proxy` is Manager's, not an engine instance (#363). **Recommended:**
  leave it out of the release bundle; keep it in the development compose.
- [ ] **A10 — HealthKit bridge.** It is an iOS app, not an image.
  **Recommended:** ship it as a source build with step-by-step signing and
  install instructions (TestFlight later). Prove it on a physical iPhone against
  the containerized PE (D4), or record it as a limitation. Never use the
  simulator (owner, 2026-10-06).
- [ ] **A11 — Release boundary.**
  - **#562** (difference-net training) and **#563** (drift record in a full
    universe, file cap) are post-MVP. Drift can't be evaluated until Reality
    Events and LLM Nodes have an isomorphic relationship, which is not part of
    this release (owner, 2026-10-09).
  - **#564** (gate order) must be resolved only if the release gate runs on a
    reused stack.
  - **#317** (deterministic MQTT stage) is out of scope, as long as the release
    makes no MQTT-parity claim.

## B. Images: build and publish

- [ ] **B1 — One Dockerfile per image.** List every image with its source repo
  and the owner of its Dockerfile, and remove the duplicates: CI `docker/scala`
  vs `RealityEngine_Scala/Dockerfile`, CI `docker/scala-perception-engine` vs
  Scala's `perception-engine/Dockerfile`, and CI `docker/visualizer-*` and
  `docker/perception-engine-*` vs Manager's own.
  - Image set: `re-cpp`, `re-lsp`, `re-scala`, `re-scala-pe`,
    `re-visualizer-backend`, `re-visualizer-frontend`, `re-localai-api`,
    `re-mcp`, `re-openclaw-gateway`, `re-pim`, `re-css`, `re-init` (C2),
    `re-corpus` (A8).
  - **Done:** the image table is committed and each image builds from one
    Dockerfile.
- [ ] **B2 — Self-contained images.**
  - Bake configuration, nginx configuration and Grafana dashboards into the
    images.
  - Replace the bind mounts (`MACHINES_DIR`, `./config`, `nginx/`,
    `../localAIStack/data/machines`) with the corpus data image and named
    volumes.
  - Generate certificates and secrets at first run (C3); never put them in a
    layer.
  - **Done:** every image starts with no host path mounted except named volumes
    and the generated certificate and secret volume.
- [ ] **B3 — Pin and unify third-party images.**
  - One version, pinned by digest, of each: Loki, Prometheus, Promtail,
    Grafana, Qdrant, Redis, Open WebUI (not `:main`), nginx and the OpenClaw
    browser.
  - Base images follow the owner's rules: PIM moves from `node:22` to Node 26.8.
    Check the Scala builder/runtime JDK pairing (Temurin 17 builder, Temurin 25
    runtime).
  - **Done:** no floating tag in any release image or compose file. The
    version-check script, or a new gate, fails a floating tag.
- [ ] **B4 — Native multi-arch builds.** Build arm64 on `ubuntu-24.04-arm` and
  amd64 on `ubuntu-24.04` (both available to these public repos), then join them
  into one multi-arch manifest. Don't build under QEMU: the SBCL (LSP) and sbt
  builds are the risk. Fix PIM's `ubuntu-latest` runner pin.
  - **Done:** every image has arm64 and amd64 variants built natively, and the
    arm64 build is green on a hosted run.
- [ ] **B5 — Release image workflow.** Triggered by the release (F4), it builds
  each image from the commit the release manifest pins and tags it
  `release-vX.Y.Z` and with the commit SHA. It adds OCI labels (`source`,
  `revision`, `version`), SBOM and provenance attestations, and writes every
  image digest back into the release manifest. Pull-request builds don't push.
  - **Done:** a dry run against a candidate manifest produces images whose
    `revision` labels equal the manifest's pins.
- [ ] **B6 — Image hygiene.** Each image runs as a non-root user, has a
  `HEALTHCHECK`, contains no secrets, and stays within a size budget recorded
  per image. Today localAI is 1.44 GB and the OpenClaw browser 4.4 GB.
  - **Done:** a hygiene check in the image workflow passes for every image.

## C. Install bundle for macOS

- [ ] **C1 — One release compose file** (`release/compose.yml`). It references
  images by digest only, with no `build:` and no sibling path. It merges the CI,
  localAIStack, localOpenClawStack and PIM stacks into one project, with one
  monitoring stack, one Open WebUI and one Qdrant. The host ports are those of
  the expected live surfaces (root `CLAUDE.md`), and the file avoids the ports
  macOS holds (5000/7000, AirPlay Receiver).
  - **Done:** `docker compose -f release/compose.yml config` validates, and
    `up` brings every service healthy with nothing but images and volumes.
- [ ] **C2 — Instance registry, MCP, config and UUIDs in containers.** Today
  `startUniverse.sh` serves the instance registry from a host shim, runs MCP as
  a host `node` process, generates `config/integrations.json`, and allocates
  instance UUIDs (`scripts/lib/instance_uuids.py`) into `~/.reality-engine/`.
  Move all of it into `re-init` (a one-shot job) plus a small instance-registry
  service.
  - UUIDs persist in a named volume; the rules of #296 still hold: one UUID per
    instance, never shared, kept across restarts.
  - The instance registry's address is published the same way it is today, so
    `registry_url()` and its helpers resolve it unchanged.
  - **Done:** the instance registry lists `cpp-1`, `lsp-1` and `scala-1` with
    their UUIDs and no host process; `instance_uuids.py check-registry` passes.
- [ ] **C3 — Installer CLI** (`realityengine install | up | down | status |
  upgrade | uninstall`).
  - **Checks first:** macOS ≥ 26, the architecture, the Docker runtime and its
    version (A5), the memory and disk given to Docker, and free ports.
  - **First run:**
    - Generate the local CA and certificates (from
      `certs/generate-dev-certs.sh`) and offer to trust the CA in the Keychain.
    - Generate the secrets: the HealthKit ingest token, the OpenClaw gateway
      token and the Grafana admin login.
    - Check Ollama and pull the model (A6).
    - `docker compose pull`, `up`, wait for health, and print the URLs.
  - It never writes into a source checkout. The incident behind the rule "never
    run workflow setup on the real checkout" is the reason.
  - **Done:** on a prepared Mac, `realityengine install` reaches a healthy suite
    and `status` reports every component.
- [ ] **C4 — Persistence and lifecycle.**
  - Named volumes for instance UUIDs and clocks, the localAI state directory
    (`llm-drift.jsonl` and the removal record), Qdrant, Redis, the PIM/Solid
    PODs, Grafana and Prometheus.
  - `upgrade` moves to new digests and keeps the data; `upgrade --to <previous>`
    rolls back; `uninstall` keeps the data unless `--purge` is given.
  - **Done:** upgrading from a candidate to the release, and rolling back, keep
    the UUIDs and the POD contents.
- [ ] **C5 — Install documentation.** `INSTALL.md`: prerequisites, install,
  first run, URLs, troubleshooting (ports, Docker memory, Ollama, certificate
  trust), upgrade, uninstall. `DOCKER_QUICKSTART.md` becomes the development
  path and points to `INSTALL.md` for users.
  - **Done:** reviewed, and followed word for word in E3.

## D. Product acceptance, run on the installed images

- [ ] **D1 — Runtime and observability soak** (was R04).
  - **Checks:** all six RE/PE health endpoints of the trio, unique stable
    instance UUIDs, machine-load counts, and that the running image digests
    match the manifest.
  - **Soak:** at least ten minutes of stepping, stream heartbeats and metric
    scrapes with no stream loss, health starvation or orphaned container.
  - **Observability:** Prometheus targets are up, engine logs reach Loki, and
    the Grafana panels show live data (CI#557/#558); idle or disabled panels are
    explained.
  - The six-instance proof stays on the native lane (A7).
  - **Done:** a soak log and an endpoint/UUID inventory tied to the image
    digests.
- [ ] **D2 — 2D/3D UI acceptance** (was R05). Engine switching across cpp, lsp
  and scala in both views; arcs and arrowheads, state changes, popup placement,
  no stale activity after a switch. Across themes and small viewports.
  - **Criteria:** arc/arrowhead contrast ≥ 3:1 and labels ≥ 4.5:1.
  - **Manager#254's gaps:** the matched ring is 2.4:1 under Light, 32×32 nodes
    open no tooltip, and Firefox/WebKit are untested.
  - The Load Machines modal offers the full corpus and every domain (Manager#257).
  - **Done:** a matrix with screenshots; each gap fixed or recorded as a
    limitation.
- [ ] **D3 — localAI reaches every engine** (was R06). localAI fans out to every
  engine on the container network. `verify_localai_reach` passes: every engine
  holds the same localAI machines and sensors, and `bridge_engines` equals the
  instance registry.
  - An in-scope 3-of-3 disagreement on identical deterministic input blocks
    the release.
  - LLM drift is collected (`/observations/drift`) but not evaluated (A11).
  - **Done:** the check passes on the containerized lane.
- [ ] **D4 — iPhone → containerized PE, and the PIM mirror** (was R07). The phone
  must reach the published PE port and trust the generated CA.
  - **Mirror cases:** an approved batch is written; a conflict leaves the POD
    unchanged; no owner approval gives 403; changing the metric scope at run
    time is honoured.
  - Check that the shipping app actually wires in the mirror client before
    claiming an automatic device-to-POD flow.
  - **Done:** device build, install and ingest evidence plus green mirror
    results at the release commits, or a recorded limitation (A10).
- [ ] **D5 — MQTT disposition** (was R08). Yuma has timed out on every nightly
  and on the last local run. Re-probe it on its own: record a pass, or approve a
  named external-broker limitation.
  - No MQTT-parity claim unless #317 is done (A11).
  - **Done:** a Yuma result or limitation recorded at the release commits.
- [ ] **D6 — Release asset checks** (was R09). All eight families at the release
  corpus fingerprint: corpus validation (ROBOT, SHACL, QUDT, nothing skipped),
  JSON Schema, oracles, cesgen bindings, OpenAPI and its mirrors, CES contract
  shards, OWL baselines, and the OpenClaw agent index (`--require-current-digest`).
  Plus full-corpus load evidence if A8 ships the full corpus.
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

## E. Certify the image product

- [ ] **E1 — `local-containerized` lane on published images** (CI#165).
  `scripts/regression-test.sh --profile local-containerized`. It installs the
  candidate's **published** images through C3, not local builds, then runs the
  local lane's stages. Same corpus and instance registry contract as the
  native lane.
  - **Done:** a green run that recorded the image digests it ran.
- [ ] **E2 — Native vs containerized comparison.** Run the native local lane
  and E1 at the same commits on the same Mac and compare the parity stages.
  - A disagreement that is still there after a re-run blocks the release; this
    comparison is the evidence that the images are the product.
  - **Done:** a comparison report with no unexplained difference.
- [ ] **E3 — Clean-Mac install test.** A macOS 26 Mac (Apple Silicon) with no
  checkouts, toolchains or cached images, and only the A5/A6 prerequisites.
  Follow `INSTALL.md` word for word, run the smoke tests and D7, then upgrade,
  roll back and uninstall.
  - Use a second Mac or a clean user account with the Docker data reset;
    Docker inside a macOS VM is not reliable on Apple Silicon.
  - **Done:** a timed transcript, with the Docker Desktop minimum version
    recorded.
- [ ] **E4 — Release eligibility enforced** (was R03, extended). The release
  cutter refuses when:
  - an image digest is missing, or an image's `revision` differs from its pin;
  - the E1 lane is missing or not green;
  - the `pim-mirror` stage is skipped or failed (decision D2 in `MVP_ROADMAP.md`, 2026-09-25);
  - a required stage is missing, or the run is provisional.
  - Tag text is generated from the manifest; today `cut-release.sh` always
    writes "hosted profile".
  - Failed tag or image pushes are aggregated into a nonzero result.
  - **Done:** positive and refusal tests for each case.
- [ ] **E5 — Release documentation aligned** (was R02). `RELEASE.md` covers the
  ten-repo inventory (it lists eight), the image model (A2), the two
  certifying lanes, and the command order. `docs/README.md` indexes this file
  and `INSTALL.md`.
  - **Done:** one reviewed docs PR, with no contradiction between `RELEASE.md`,
    this file and `MVP_ROADMAP.md`.

## F. Freeze, cut and publish

- [ ] **F1 — Freeze and final certification** (was R11). Every accepted fix is
  merged; every repo is clean and current with `origin/main`. Then run, at the
  same commits:
  - the native local lane:
    `RE_FREE_PORTS=true bash scripts/regression-test.sh --execute --profile local --run-id <final>`
    (with the iPhone connected if D4 requires its pass);
  - E1 on the candidate images built from those commits.
  - **Done:** both runs are non-provisional, with no required skip or failure,
    clean provenance, and a recorded decision for every optional omission.
    Any runtime change after this needs recertification.
- [ ] **F2 — Versioned manifest** (was R12). Run
  `scripts/release-manifest.py generate --run-dir .regression-tests/runs/<final> --version <A1 tag> --out releases/<A1 tag>.json`,
  extended to record every image digest.
  - Never hand-edit a pin, and never pass `--allow-unverified`.
  - `releases/v0.1.0-rc1.json` (8 repos, 2026-08-09) is historical and is
    superseded.
  - **Done:** ten full SHAs and every image digest, with no provisional marker.
- [ ] **F3 — Cut rehearsal** (was R13). `release-manifest.py verify` and the
  cutter without `--execute`. Check for tag collisions locally and on all ten
  remotes, and for image-tag collisions in the image registry.
  - Generate the manifest without moving CI's HEAD; the record is committed
    after the cut through a docs PR.
  - **Done:** no drift, no conflicting tag, and the dry run names the certified
    set.
- [ ] **F4 — Publish tags and images** (was R14). Create the tags with
  `--execute` and review them; push with `--execute --push`; promote the
  candidate images to the release tag by digest, without rebuilding.
  - **Done:** every remote tag resolves to its manifest SHA and every release
    image to its manifest digest. A partial publication is not a release.
- [ ] **F5 — Release notes and released-set smoke** (was R15). Publish:
  - install instructions (`INSTALL.md`);
  - the manifest and the certifying run IDs;
  - the evidence for D1–D7 and E1–E3;
  - the known limitations below.
  - Smoke-test the released set by repeating E3 from the published release.
    Document how to recover the previous release (C4 rollback).
  - **Done:** all ten tags and every image verified, the notes published, and
    G1–G4 in `MVP_ROADMAP.md` marked accepted with references.

---

## Sequence

| Phase | Tasks | Exit |
|---|---|---|
| 0. Decide | A1–A11 | every decision recorded here |
| 1. Build and package | B1–B6, C1–C2, then C3–C5 | the bundle installs from images on the developer Mac |
| 2. Certify the containers | E1, E2, E4, E5 (D6 can run any time) | `local-containerized` green; native and containerized agree |
| 3. Accept | D1–D7, E3 | acceptance evidence or a recorded limitation for each |
| 4. Release | F1 → F2 → F3 → F4 → F5 | tags and images published and verified |

**Biggest risks**, each unproven today, so start with them:
1. **C2:** the deployment has never run without the host-side instance
   registry shim, MCP process and config generation.
2. **B4:** the LSP (SBCL) and Scala builds on hosted arm64 runners.
3. **D4:** an iPhone reaching TLS endpoints inside containers and trusting a
   locally generated CA.
4. **E3:** the first install on a Mac that has never seen a checkout.

## Known limitations for the release notes

- Hosted checks don't cover Ollama, OpenClaw, the PIM mirror or the iPhone.
  Certification comes from the local and containerized lanes (decision D3 in `MVP_ROADMAP.md`).
- MQTT Yuma availability is external (D5).
- The image release runs one instance per engine type (A7). Multi-instance is
  native-only.
- Ollama runs on the host (A6).
- LLM drift is recorded but not evaluated (A11).
- The HealthKit bridge is a separate iPhone app (A10).

## Post-MVP (excluded unless an A-decision brings it in)

- CI#562: difference-net training, after the Reality Event ↔ LLM Node
  isomorphism.
- CI#563: drift record in a full universe; cap the drift file.
- CI#526: unnamed-provider review and trust ranking.
- CI#287: engine snapshots, phase 2.
- CI#256: the two-stage fold.
- CI#317: the broader deterministic MQTT stage.
- Six instances in containers.
- PIM #68/#69 (UX).
- localHealthkitBridge#40 (silence watchdog).
- localAIStack#113 (Lang* docs).

## Mapping from R01–R15

| Draft task (PR #560) | Here |
|---|---|
| R01 version and scope | A1, A7, A10, A11 |
| R02 release docs | E5, C5 |
| R03 enforced eligibility | E4 |
| R04 six-instance soak | D1 (trio on images); six instances stay native |
| R05 2D/3D acceptance | D2 |
| R06 CI#518 disposition | D3; #518 closed 2026-10-09, follow-ups in A11 |
| R07 iPhone and PIM | D4, A10 |
| R08 MQTT | D5 |
| R09 release assets | D6 |
| R10 deployment acceptance | D7 |
| R11–R15 certify, cut, publish | F1–F5, extended with images |
