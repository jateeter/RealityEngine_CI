# Releasing RealityEngine

Last reviewed: 2026-10-17

How a release of the integrated RealityEngine application is defined, built,
certified, cut, published, installed and rolled back.

`docs/ReleaseRoadmap.md` is the task tracker for the first release
(`release-v0.0.1`). `docs/MVP_ROADMAP.md` keeps the gate history and evidence.
`ROADMAP.md` covers the deployment and testing infrastructure. This file is the
process itself.

> **Implementation status.** The process below is decided (2026-10-17). Steps
> whose tooling is still being built name the roadmap task that delivers it,
> as *(pending Bn)*. Until that task is done, that step can't be run as
> written.

---

## What a release is

**A release is the set of commits across the application's ten repositories
that one certification certified together, plus the Docker images built from
exactly those commits, each pinned by digest in the release manifest**
(decision A2, 2026-10-17).

Until 2026-10-17 a release was commits only: the application was composed at
run time from sibling checkouts, so there was nothing to ship. The primary
target of the MVP is that a Mac on macOS 26 or later can download the images
and install a full deployment, with no checkout and no build toolchain. The
images are therefore part of the release, and the manifest is still the record
that ties it together:

```
releases/release-v0.0.1.json
```

It pins every repo to the commit the certification built, records which runs
certified it and which stages passed, and lists every image with its digest.
Given a manifest, the release can be rebuilt from source, or installed from its
images, and both are the same release.

| Repo | Role in the release | Ships as |
|---|---|---|
| `RealityEngine_CI` | orchestration, the harness, the installer, this process | the installer bundle; `re-init` and `re-registry` images |
| `RealityEngine_CPP` | C++ RE + PE | image `re-cpp` |
| `RealityEngine_LSP` | Common Lisp RE + PE | image `re-lsp` |
| `RealityEngine_Scala` | Scala/Akka RE + standalone PE | images `re-scala`, `re-scala-pe` |
| `RealityEngine_Machines` | machine corpus, schemas, contract tests | image `re-corpus` (the regression corpus, A8) |
| `RealityEngine_Manager` | Visualizer | images `re-visualizer-backend`, `re-visualizer-frontend` |
| `localAIStack` | local RAG/vector services and the RE bridge | image `re-localai-api` |
| `localOpenClawStack` | ACP/OpenClaw gateway | image `re-openclaw-gateway` |
| `OpenCommons-Health---Personal-Information-Management` | PIM and the Solid Community Server that holds the authoritative POD | images `re-pim`, `re-css` |
| `localHealthkitBridge` | iOS HealthKit → PE bridge | **source**, a development deployment built with Xcode (A10) |

The image catalog (repo, Dockerfile, image name) is
`release/images.json` *(pending B1)*. Third-party images (Loki, Prometheus,
Promtail, Grafana, Qdrant, Redis, Open WebUI, nginx, the OpenClaw browser) are
pinned by digest in the release compose file and are part of the release too
(B3).

### Platform

| | |
|---|---|
| Host | a Mac with **Apple Silicon** (M1 or later), **macOS 26** or later (A4) |
| Images | `linux/arm64` only; no `amd64` image is released (A4) |
| Container runtime | **Docker Desktop**, minimum version set by the clean-Mac test E3 (A5) |
| Ollama | **native on the host**, not in a container, so it uses the Apple GPU (A6). Containers reach it at `host.docker.internal:11434` |
| Image registry | public GitHub Container Registry, `ghcr.io/jateeter/re-<component>` (A3) |

### What is deployed

The installer starts the whole suite from images: the engine instances, the
instance registry, Manager, localAIStack with Qdrant and Redis, the OpenClaw
gateway with Open WebUI, PIM with the Solid Community Server, MCP, and one
monitoring stack.

- **Engine instances are configured at each start (A7).** The operator chooses
  the deployment the way `startUniverse.sh --engines=` does natively, for
  example `cpp:2,lsp:1,scala:1`. Each instance gets its own UUID, kept across
  restarts (#296), and its own entry in the instance registry. All three engine
  types (C++, Common Lisp, Scala) ship in every release (A9).
- **The shipped corpus is the regression corpus** (`config/regression-corpus.txt`,
  A8). After deployment, machines can be loaded dynamically from
  `RealityEngine_Machines`, which is expected to grow and change between
  releases: the installer refreshes the machine catalog from the repo, and
  machines are loaded into running engines through the RE API or Manager's Load
  Machines modal *(pending C6)*.
- **The HealthKit bridge is not part of the image deployment.** It is a Swift
  app installed on an iPhone from source with Xcode. In `release-v0.0.1` it
  ships as an **untested development deployment** (A10); the PIM mirror it
  feeds is tested (decision D2 in `docs/MVP_ROADMAP.md`).

---

## What certifies a release

Two green runs at the same commits:

1. **The native local lane on `main` of every repo** (D3, 2026-10-07). This is
   the run the parity results rest on.
2. **The containerized lane on the candidate images** built from those commits
   *(pending E1, CI#165)*. This proves the images are the same application.

The two runs are compared stage by stage *(pending E2)*. A disagreement that is
still there after a re-run blocks the release.

| | Native local lane | Containerized lane |
|---|---|---|
| Where | operator hardware: a Mac with Docker, Ollama and Xcode | the same Mac |
| Command | `bash scripts/regression-test.sh --execute --profile local` | `bash scripts/regression-test.sh --execute --profile local-containerized --images <candidate manifest>` *(pending E1)* |
| Free ports | `RE_FREE_PORTS=true` when a template port is held (macOS AirPlay holds 5000) | the installer's port check |
| Success | the run's `summary.md` reads `Status: completed`: no stage failed | same |
| Engines | `cpp:1,lsp:1,scala:1` by default; any `--engines=` spec | same spec |
| Record | `.regression-tests/runs/<run-id>/`, including `release-manifest.json` | same, plus the image digests it ran |

Only the local lanes run Ollama, OpenClaw and the PIM mirror, so only a local
run can certify them. A stage the run **skipped** (an unreachable MQTT broker,
an iPhone that isn't connected) is recorded in the manifest with its reason and
is not certified by it: name it in the release notes. The `pim-mirror` stage
may not be skipped (D2); `cut-release.sh` refuses a manifest where it is
*(pending E4)*.

A clean-Mac install from the published candidate images, following `INSTALL.md`
word for word, is part of acceptance *(pending E3)*.

### The hosted nightly is the per-merge gate, not the certifier

The hosted lane runs on every merge and nightly, and a green nightly is a
precondition (MVP gate G1). It does not certify a release.

| | |
|---|---|
| Where | GitHub-hosted runners (`ubuntu-24.04`), not self-hosted |
| Workflow | `.github/workflows/regression-tests.yml` |
| Cadence | nightly at `17 9 * * *` UTC, and on demand |
| Mode | `REGRESSION_SCHEDULE_RUN_MODE = full` |
| Enabled by | `REGRESSION_SCHEDULE_ENABLED = true` |
| Profile | `hosted` |
| Engines | `cpp:1,lsp:1,scala:1` |

Manual dispatch:

```bash
gh workflow run regression-tests.yml --ref main -f run_mode=full
```

### What the hosted profile deliberately does not cover

Enforced by refusal (exit 2), not by defaults, so a run cannot quietly opt back
in:

- Ollama and any local-AI path
- OpenClaw
- the PIM mirror
- the HealthKit bridge

Those belong to the **local lanes**, which run on hardware that has Docker,
Ollama and Xcode.

The machine corpus is **not** a lane difference: every lane boots the
`regression` corpus (`config/regression-corpus.txt`), which is also the corpus
the release ships. `--machine-corpus=full` is an explicit opt-in available only
on the local lane; full-corpus load behaviour is covered by the weekly
`full-corpus-cycle.yml`.

The local lane runs everything the hosted lane runs, plus the stages the hosted
lane cannot: `local-ai` and `localai-machines` (localAIStack health, every PE
reporting Ollama reachable, the runtimes agreeing on the model),
`openclaw-integration-*` on every runtime, `pim-mirror` (HealthKit → PIM →
POD), and `healthkit-bridge` (the real app on a connected iPhone, never the
simulator; optional for `release-v0.0.1`, A10). Results land in
`.regression-tests/runs/<run-id>/` in the same shape as a hosted run.

**A green hosted run does not cover those surfaces.** The manifest records
`coverage.localAI` and `coverage.openclaw`, and on a hosted run both are
`false`, which is why a hosted run does not certify a release.

### Stages a green run proves

| Stage | What it establishes |
|---|---|
| Build | every repo compiles from a cold-start worktree of `origin/main` |
| Service inventory | all RE and PE endpoints answer health checks |
| Universal-vector parity | cpp, lsp and scala produce identical signatures for the same input |
| MQTT Yuma stream | the MQTT bridge ingests on all three runtimes |
| MCP open service | every non-mutating MCP tool works against all three runtimes |

Byte-equivalence, service availability, contract parity and integration success
are distinct classes of result. One green stage does not imply another; see
`../CLAUDE.md` "Verification Posture".

---

## Cutting a release

### 1. Freeze, and get a green native local run on `main`

Every repo on `main`, current with `origin`, then:

```bash
RE_FREE_PORTS=true bash scripts/regression-test.sh --execute --profile local --run-id <run-id>
grep '^- Status' .regression-tests/runs/<run-id>/summary.md   # must be: completed
```

The hosted nightly must be green at the same time (gate G1).

### 2. Build and push the candidate images *(pending B5)*

The release image workflow builds every image in `release/images.json` from
the commit the run pinned, on `ubuntu-24.04-arm`, and pushes it to GHCR tagged
with the candidate tag (`release-v0.0.1-rcN`) and the commit SHA:

```bash
gh workflow run release-images.yml --ref main \
  -f manifest=.regression-tests/runs/<run-id>/release-manifest.json -f tag=release-v0.0.1-rc1
```

Each image carries OCI labels (`org.opencontainers.image.source`, `.revision`,
`.version`), an SBOM and a provenance attestation. The workflow writes the
digests back as `images.json` next to the run's manifest.

### 3. Certify the candidate images *(pending E1, E2, E3)*

Run the containerized lane on the candidate images, compare it with step 1,
and install the candidate on a clean Mac following `INSTALL.md`.

### 4. Produce the manifest

```bash
scripts/release-manifest.py generate \
  --run-dir .regression-tests/runs/<run-id> \
  --images <candidate images.json> \
  --version release-v0.0.1 \
  --out releases/release-v0.0.1.json
```

*(`--images` pending F2.)* The manifest records the run's profile, its
coverage, every stage's result (skips included), every repo's commit, and
every image's digest.

Generating from a run that did not pass is **refused**. `--allow-unverified`
overrides it and stamps the manifest `provisional`, and `cut-release.sh`
refuses to tag a provisional manifest, so an uncertified set cannot reach a
release name by accident. An image whose `revision` label differs from its
repo's pin is refused *(pending E4)*.

### 5. Rehearse the cut

```bash
scripts/cut-release.sh --manifest releases/release-v0.0.1.json
```

Dry run by default. It verifies the workspace still matches the pinned set and
prints what it would tag. Drift is a hard stop: tagging a drifted workspace
puts the release name on commits that were never certified together. It also
checks that no repo, locally or on its remote, and no image already carries the
tag at a different commit or digest *(remote and image checks pending E4)*.

### 6. Tag, then publish

```bash
scripts/cut-release.sh --manifest releases/release-v0.0.1.json --execute          # local tags
scripts/cut-release.sh --manifest releases/release-v0.0.1.json --execute --push   # publish tags
```

Then promote the certified candidate images to the release tag **by digest,
without rebuilding** *(pending F4)*:

```bash
gh workflow run release-images.yml --ref main \
  -f promote=releases/release-v0.0.1.json
```

Pushing is a separate opt-in because a pushed tag is the hard-to-reverse step.
A partial publication (a tag missing on one remote, an image not promoted) is
not a release: the cutter reports every failure and exits nonzero
*(pending E4)*.

### 7. Commit the manifest and publish the notes

```bash
git add releases/release-v0.0.1.json && git commit -m "release: release-v0.0.1"
```

Commit through a documentation PR; the CI commit the manifest pins stays the one
that was certified and tagged. The manifest is the record. Keep it even if the
tags are later moved. The release notes name the certifying runs, every stage
they skipped and why, and the known limitations.

---

## Installing and verifying a release

### Install from the images *(pending C3, C5)*

On a Mac that meets the platform table above:

```bash
curl -fsSL https://github.com/jateeter/RealityEngine_CI/releases/download/release-v0.0.1/realityengine -o realityengine
chmod +x realityengine
./realityengine install --version release-v0.0.1 --engines=cpp:1,lsp:1,scala:1
```

`INSTALL.md` covers the prerequisites, first run, URLs, troubleshooting,
upgrade and uninstall. A running install reports its release and image
digests with `realityengine status`.

### Rebuild from source

```bash
# Confirm a workspace matches
scripts/release-manifest.py verify --manifest releases/release-v0.0.1.json

# Then bring it up
./startUniverse.sh --engines=cpp:1,lsp:1,scala:1 \
  --machine-load=runtime --pe-source-bootstrap=auto --warn-only
```

`verify` treats three distinct things as drift, and reports which:

- a repo at a different HEAD
- **modified tracked files** at the right commit. Untracked build output does
  not count, or every real machine would read as drifted.
- a pinned commit not present in the checkout at all, which would otherwise
  read as clean

`scripts/validate-versions.sh` is the lighter, day-to-day check that every
sibling repo is on a compatible ref, driven by `VERSION-COMPAT.md`.

---

## API references

Generated OpenAPI 3.1.0 contracts live in [`docs/openapi/`](docs/openapi/),
with a browsable [`index.html`](docs/openapi/index.html):

- six per-runtime documents, RE and PE for each of `cpp`, `lsp` and `scala`,
  which are the ones a release covers
- `reality-engine.yaml` and `perception-engine.yaml`, describing the
  RealityEngine AI surfaces, which are **not** part of this release set

They are **generated**; edit the sources and regenerate rather than
hand-editing.

A `SURFACE_SPEC Drift Check` runs in CI, so a runtime that changes its HTTP
surface without regenerating fails before merge.

---

## Tag conventions

| Tag | Meaning |
|---|---|
| `v0.0.1-baseline` | pre-MVP snapshot. **Local only, deliberately not pushed.** |
| `release-vN.M.Z-rcN` | application release candidate. On images it marks a candidate built from a certified run; it can be overwritten by a later candidate of the same number only before the release is cut |
| `release-vN.M.Z` | **application release**: every pinned repo and every release image, one certified set |
| `vN.M.Z` | a **component's** own release, on its own schedule (e.g. `localHealthkitBridge` `v0.1.0`). Never produced by `cut-release.sh` |

The first release is **`release-v0.0.1`** (SemVer `0.0.1`, decision A1,
2026-10-17). Its milestone name is "Release 0.01".

Every repo in an application release carries the *same* `release-v…` tag,
pointing at its own commit, and every release image carries the same tag,
pointing at its own digest. The commit and digest differ per repo and image;
the manifest is what ties them together. Images are also tagged with the full
commit SHA they were built from. An image is never retagged to a different
digest under a release tag.

**Why a separate namespace (D1, decided 2026-09-25).** Components ship on their
own schedules: `localHealthkitBridge` tagged its own `v0.1.0` (`e351651`) on
2026-09-24. A plain `vN.M.Z` application tag on every pinned repo would collide
with any such component tag, and `cut-release.sh` refuses a tag that already
exists at a different commit. `release-vN.M.Z` cannot collide with component
semver, now or later. Both `release-manifest.py generate --version` and
`cut-release.sh` refuse any other form, so a component-style name cannot become
an application tag by mistake. `releases/v0.1.0-rc1.json` predates this; it is a
historical pin, and `cut-release.sh` will not cut from it.

The baseline tags stay unpushed by choice. Do not push them as part of a
release.

---

## Rolling back

**An installed release** rolls back to the previous release's images, keeping
its data volumes (instance UUIDs and clocks, localAI state, Qdrant, the PIM
PODs) *(pending C4)*:

```bash
./realityengine upgrade --to release-v<previous>
```

**A source checkout** returns to a previous release by checking each repo out
at the commit its manifest pins:

```bash
scripts/release-manifest.py verify --manifest releases/<previous>.json
# then check each repo out at its pinned commit and restart the universe
```

If a bad tag was pushed, delete it in each repo
(`git push --delete origin release-vX.Y.Z`) and cut a new patch version rather
than moving the tag. Do the same for images: leave the bad release images in
place, unlisted in any manifest, and publish the next patch version. A moved
tag makes the manifest and the tag disagree, and the manifest is the record.

---

## Release checklist

- [ ] A native local-lane run on `main` concluded `completed`, and the hosted nightly is green
- [ ] Candidate images built from that run's pins and pushed as `release-vN.M.Z-rcN`
- [ ] The containerized lane on those images concluded `completed`, and the two lanes agree
- [ ] The candidate installed on a clean Mac following `INSTALL.md`
- [ ] Manifest generated from the runs and the candidate digests, not hand-written, and **not** provisional
- [ ] `cut-release.sh` dry run reports no drift and no tag or image collision
- [ ] Tags created, then pushed as a separate step; images promoted by digest
- [ ] Manifest committed under `releases/` through a documentation PR
- [ ] `docs/ReleaseRoadmap.md` task status updated in the same change, naming the runs
- [ ] Release notes name every stage the certifying runs skipped, with its reason, and the known limitations
