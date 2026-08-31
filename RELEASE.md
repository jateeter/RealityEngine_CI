# Releasing RealityEngine

Last reviewed: 2026-08-09

How a release of the integrated RealityEngine application is defined, cut, and
verified.

`ROADMAP.md` covers the deployment and testing infrastructure. `docs/MVP_ROADMAP.md`
tracks what remains before an MVP. This file is the process itself.

---

## What a release is

**A release is a set of commits across eight repositories, certified together
by one regression run.** It is not a build artifact.

The application is composed at run time from sibling checkouts — `startUniverse.sh`
builds each repo from source and wires them together. There is no single
binary to ship, so "the release" can only mean *this commit of each repo, proven
to work together*.

That makes the release manifest the release:

```
releases/v0.1.0-rc1.json
```

It pins all eight repos to the commit the certification run actually built, and
records which run certified them and which stages passed. Given a manifest, the
application can be rebuilt exactly.

| Repo | Role in the release |
|---|---|
| `RealityEngine_CI` | orchestration, the harness, this process |
| `RealityEngine_CPP` | C++ RE + PE |
| `RealityEngine_LSP` | Common Lisp RE + PE |
| `RealityEngine_Scala` | Scala/Akka RE + standalone PE |
| `RealityEngine_Machines` | machine corpus, schemas, contract tests |
| `RealityEngine_Manager` | Visualizer, TypeScript PE |
| `localAIStack` | local RAG/vector/Ollama services |
| `localOpenClawStack` | ACP/OpenClaw gateway |

`localHealthkitBridge` is an iOS client, not part of the composed runtime, and
is released on its own cadence.

---

## What certifies a release

**Hosted GitHub Actions, nightly, plus manual dispatch.**

| | |
|---|---|
| Where | GitHub-hosted runners (`ubuntu-latest`), not self-hosted |
| Workflow | `.github/workflows/regression-tests.yml` |
| Cadence | nightly at `17 9 * * *` UTC, and on demand |
| Mode | `REGRESSION_SCHEDULE_RUN_MODE = full` |
| Enabled by | `REGRESSION_SCHEDULE_ENABLED = true` |
| Profile | `hosted` |
| Engines | `cpp:1,lsp:1,scala:1` — all three runtimes, in one universe |

Manual dispatch:

```bash
gh workflow run regression-tests.yml --ref main -f run_mode=full
```

### What the hosted profile deliberately does not cover

Enforced by refusal (exit 2), not by defaults, so a run cannot quietly opt back
in:

- Ollama and any local-AI path
- OpenClaw
- the HealthKit bridge

Those belong to the **local lane**, which is operator-run on hardware that has
Docker, Ollama and Xcode:

```bash
bash scripts/regression-test.sh --execute --profile local
```

The machine corpus is **not** a lane difference: both lanes boot
`standard-deployment` (12 machines). `--machine-corpus=full` is an explicit
opt-in available only on the local lane; full-corpus load behaviour is covered
by dedicated scaling tests.

It runs everything the hosted lane runs, plus two stages the hosted lane
cannot: `local-ai` (localAIStack health, every PE reporting Ollama reachable,
and the runtimes agreeing on the model) and `healthkit-bridge` (the bridge's
configured-sequence e2e against a live PE). Results land in
`.regression-tests/runs/<run-id>/` in the same shape as a hosted run.

**A hosted certification does not certify those surfaces.** Do not read a green
hosted run as covering them — the manifest records `coverage.localAI` and
`coverage.openclaw`, and on a hosted run both are `false`.

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

### 1. Get a green run

```bash
gh run list --workflow regression-tests.yml --limit 5
gh run view <run-id> --json conclusion -q .conclusion   # must be: success
```

Every run emits a candidate manifest at `<run-dir>/release-manifest.json`,
so a green run has already produced one.

### 2. Produce the manifest

From a downloaded artifact:

```bash
gh run download <run-id> -D /tmp/certified
scripts/release-manifest.py generate \
  --run-dir /tmp/certified/regression-<run>/<run> \
  --version v0.1.0 \
  --out releases/v0.1.0.json
```

Generating from a run that did not pass is **refused**. `--allow-unverified`
overrides it and stamps the manifest `provisional`, and `cut-release.sh`
refuses to tag a provisional manifest — so an uncertified set cannot reach a
release name by accident.

### 3. Rehearse the cut

```bash
scripts/cut-release.sh --manifest releases/v0.1.0.json
```

Dry-run by default. It verifies the workspace still matches the pinned set and
prints what it would tag. Drift is a hard stop: tagging a drifted workspace
puts the release name on commits that were never certified together.

### 4. Tag, then push

```bash
scripts/cut-release.sh --manifest releases/v0.1.0.json --execute          # local tags
scripts/cut-release.sh --manifest releases/v0.1.0.json --execute --push   # publish
```

Pushing is a separate opt-in because a pushed tag is the hard-to-reverse step.

### 5. Commit the manifest

```bash
git add releases/v0.1.0.json && git commit -m "release: v0.1.0"
```

The manifest is the record. Keep it even if the tags are later moved.

---

## Verifying a release

Rebuild a released set from nothing but the manifest:

```bash
# Confirm a workspace matches
scripts/release-manifest.py verify --manifest releases/v0.1.0.json

# Then bring it up
./startUniverse.sh --engines=cpp:1,lsp:1,scala:1 \
  --machine-load=runtime --pe-source-bootstrap=auto --warn-only
```

`verify` treats three distinct things as drift, and reports which:

- a repo at a different HEAD
- **modified tracked files** at the right commit — untracked build output does
  not count, or every real machine would read as drifted
- a pinned commit not present in the checkout at all, which would otherwise
  read as clean

`scripts/validate-versions.sh` is the lighter, day-to-day check that every
sibling repo is on a compatible ref, driven by `VERSION-COMPAT.md`.

---

## API references

Generated OpenAPI 3.1.0 contracts live in [`docs/openapi/`](docs/openapi/),
with a browsable [`index.html`](docs/openapi/index.html):

- six per-runtime documents — RE and PE for each of `cpp`, `lsp`, `scala` —
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
| `vX.Y.Z-rcN` | release candidate cut from a certified run |
| `vX.Y.Z` | release |

Every repo in a release carries the *same* tag, pointing at its own commit. The
tag is the same name across eight repos; the commit differs per repo. The
manifest is what ties them together.

The baseline tags stay unpushed by choice. Do not push them as part of a
release.

---

## Rolling back

There is nothing deployed to roll back — a release is a set of commits. To
return to a previous release:

```bash
scripts/release-manifest.py verify --manifest releases/<previous>.json
# then check each repo out at its pinned commit and restart the universe
```

If a bad tag was pushed, delete it in each repo (`git push --delete origin vX.Y.Z`)
and cut a new patch version rather than moving the tag. A moved tag makes the
manifest and the tag disagree, and the manifest is the record.

---

## Release checklist

- [ ] A regression run on `main` concluded `success`
- [ ] Manifest generated from that run, not hand-written, and **not** provisional
- [ ] `cut-release.sh` dry run reports no drift
- [ ] Manifest committed under `releases/`
- [ ] Tags created, then pushed as a separate step
- [ ] `docs/MVP_ROADMAP.md` gate status updated in the same change, naming the run
- [ ] Release notes state what the hosted profile did **not** cover
