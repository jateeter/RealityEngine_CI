# MVP Release Roadmap

Last reviewed: 2026-08-09

The route from the current `v0.0.1-baseline` tag to a tagged MVP release of the
integrated RealityEngine application.

`ROADMAP.md` in this repo covers deployment and testing infrastructure and is
complete. This file covers what remains before the composed application can be
released, and is the place to record gate status as it changes.

## Gate summary

| Gate | What it means | Status |
|---|---|---|
| **G1** | Certification runs and passes on every merge to main | **Done** — all stages green (run 31297685782), running nightly |
| **G2** | Versions pinned across repos, reproducibly | **Done** — first certified pin at `releases/v0.1.0-rc1.json` |
| **G3** | Release documentation and process | **Done** — `RELEASE.md`, `scripts/cut-release.sh` |
| **G4** | MVP scope decision: PIM vs HealthKit bridge | **Blocked on a product decision** |

---

## G1 · Certification

The verification posture rests on distinct runtimes agreeing. Everything here
exists to make that claim checkable rather than asserted.

### G1.1 · Two-lane profile — done

`scripts/regression-test.sh --profile hosted|local`.

The hosted lane never loads the full corpus, never runs Ollama or OpenClaw, and
never runs the HealthKit bridge. These are enforced by refusal (exit 2), not by
defaults, so a run cannot quietly opt back in.

### G1.2 · Hosted `full` executes end to end — done

`full` had never started a universe on any runner. It now cold-starts
`cpp:1,lsp:1,scala:1` and runs every stage. A failing stage no longer aborts the
run, so one failure cannot hide the state of the stages behind it.

Fixing this exposed four checks that had been passing without checking anything:
`validate-versions.sh` (`-d .git`, which is a *file* in a worktree), universal-vector
discovery (non-recursive glob, 0 of 1,321 machines), the MQTT stage (reported a
skip), and the Scala PE's `make test` (no test sources, 0s).

### G1.3 · Stages green — done

First fully green certification run: **31297685782**, hosted profile,
`cpp:1,lsp:1,scala:1`.

| Stage | Status | Notes |
|---|---|---|
| Build (all repos) | ✓ | |
| Service inventory | ✓ | 6 health checks, all runtimes |
| Universal-vector parity | ✓ | cpp / lsp / scala byte-identical across 5 events |
| MQTT Yuma stream | ✓ | all three runtimes, retained-message seeding |
| MCP open service | ✓ | 30 calls passed, 3 skipped (empty ledger on a cold universe), 0 failures |
| OpenClaw handoff | n/a | out of scope on the hosted lane by policy (G1.1) |

**Universal-vector parity** closed on run 31291784885: 5 events × 3 runtimes,
all HTTP 200, zero signature mismatches, identical signature sizes per event.
Two defects had to be fixed to get there — Scala's `mergeBatch` unit and shape
(RealityEngine_Scala#33, #35) and a `compact` flag that froze LSP's perceptual
space so it never advanced (RealityEngine_LSP#38).

**MCP** required five fixes across three repos, three of which were found *by*
the new coverage rather than by the failure being chased:

| Defect | Repo | Found by |
|---|---|---|
| `re.read_state` → `/api/state`, a PE path no RE serves | CI#99 | the original failure |
| `trigger.replay` → a route no runtime serves | CI#99 | new route-table check, first run |
| Ollama status probe had no HTTP timeout | LSP#40 | the original failure |
| `/api/machines/:id` → 500, unbound variable | LSP#42 | new catalogue-driven smoke, first run |
| Completion ingest rejected a self-describing envelope | CPP#24 | the original failure |

### G1.4 · Nightly certification runs `full` — done

`REGRESSION_SCHEDULE_ENABLED = true`, but `REGRESSION_SCHEDULE_RUN_MODE =
build-only`, so no live stage runs on a schedule. Every green result so far
comes from a manual dispatch.

`REGRESSION_SCHEDULE_ENABLED = true` and, since 2026-08-09,
`REGRESSION_SCHEDULE_RUN_MODE = full`. Certification runs nightly at
`17 9 * * *` UTC against main.

It was deferred while a stage was red, because scheduled runs default to
`create_issue_on_failure` and would have filed an issue every night. Run
31297685782 went fully green, which removed the reason.

This is the gate that turns certification from something we run into something
that runs. Every green result before this one came from a manual dispatch.

### G1.5 · Local lane — not started

The counterpart to G1.1. Covers what the hosted lane refuses: full corpus, local
Ollama (now pinned to v0.32.0 by localAIStack#30), OpenClaw, and the iPhone
simulator bridge leg. Needs an operator-run entrypoint and a place to record
results.

### G1.6 · Bridge simulator leg — not started

`localHealthkitBridge` against the PE ingest contract, on the local lane.
Contract parity is already enforced by
`RealityEngine_Machines/tests/integration/healthkit-ingest-contract.spec.ts`;
what is missing is running the actual client.

---

## G2 · Version pinning — done

- `VERSION-COMPAT.md` records the compatible set.
- `scripts/validate-versions.sh` runs in the harness and now actually inspects
  worktrees (it was silently skipping every repo).
- localAIStack pins Ollama v0.32.0 and the observability stack
  (localAIStack#29, #30).
- **`scripts/release-manifest.py`** pins all eight repos to the SHA the build
  used, so a tagged release can be rebuilt exactly.

The manifest is derived from a *regression run*, not from whatever is on main,
so the pinned set and the evidence for it come from the same place. Pinning
from a run that did not pass is refused rather than defaulted —
`--allow-unverified` overrides it and records the override in the manifest, so
a provisional pin can never be mistaken for a certified one. A build that used
something other than the branch tip is refused too, rather than quietly
preferring one of the two commits.

`verify` checks a workspace against a manifest and treats three separate things
as drift: a different HEAD, uncommitted changes at the right commit, and a
pinned commit that is not in the checkout at all — the last of which would
otherwise read as clean.

Every regression run now emits `release-manifest.json` beside its reports, so a
green run yields a ready-to-tag manifest with no separate step to remember.

The first certified pin is checked in at `releases/v0.1.0-rc1.json`, generated
from run 31297685782 — non-provisional, all stages passed. Tagging a release
from it is a decision, not a task.

---

## G3 · Release documentation — done

[`RELEASE.md`](../RELEASE.md) defines a release as *a set of commits across
eight repos certified together by one regression run* — there is no build
artifact, because the application is composed from source at run time. It
covers cutting, certifying, verifying, tag conventions and rollback, and ends
in a checklist.

`scripts/cut-release.sh` makes the process executable rather than prose:
dry-run by default, refuses a provisional manifest, refuses a drifted
workspace, and treats pushing tags as a separate opt-in from creating them.

Certification is recorded as **hosted GitHub Actions, nightly at `17 9 * * *`
UTC plus manual dispatch** — the open acceptance criterion of #87.

`RELEASE.md` is explicit that a green hosted run does **not** cover the full
corpus, Ollama, OpenClaw or the HealthKit bridge, so the release notes cannot
imply coverage the lane refuses to provide.

Two gaps closed while writing it:

- `VERSION-COMPAT.md` listed five repos and omitted `RealityEngine_CPP` and
  `RealityEngine_LSP`, so `validate-versions.sh` reported "All sibling repos on
  compatible refs" while never checking two of the three runtimes — the two
  parity is measured against. Now seven.
- `release-manifest.py verify` counted untracked build output as drift, which
  made every real developer machine look drifted and would have trained people
  to pass `--allow-dirty` reflexively. It now counts only modified *tracked*
  files.

---

## G4 · MVP scope — needs a decision

`OpenCommons-Health---Personal-Information-Management` and
`localHealthkitBridge` both claim the health-data surface of the MVP, and the
roadmaps disagree about which one an MVP ships. This is a product call, not a
technical one, and it gates G1.6 and G3.

---

## Known open items

| Item | Where | Effect |
|---|---|---|
| Dispatch replay exists in no runtime | CI#100 | `trigger.replay` withdrawn from the MCP catalogue until it does |
| `startUniverse.sh` hangs when Docker is unavailable | CI#94 | blocks local rehearsal; hosted lane unaffected |
| Certification cadence undocumented | CI#87, #79 | G3 |
| ROBOT / OWL reasoner gap | Machines#46 | outside the MVP path |

## How to update this file

Change gate status in the same commit that changes the underlying state, and
name the run or PR that proves it. A gate marked green without a reference is
the same failure mode as a stage that passes without checking anything.
