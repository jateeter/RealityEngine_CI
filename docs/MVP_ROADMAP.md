# MVP Release Roadmap

Last reviewed: 2026-09-17

The route from the current `v0.0.1-baseline` tag to a tagged MVP release of the
integrated RealityEngine application.

`ROADMAP.md` in this repo covers deployment and testing infrastructure and is
complete. This file covers what remains before the composed application can be
released, and is the place to record gate status as it changes.

## Gate summary

| Gate | What it means | Status |
|---|---|---|
| **G1** | Certification runs and passes on every merge to main | **REGRESSED** — nightly red since 2026-09-11; last green 2026-09-10 (`cac03f01`). See *G1 status, 2026-09-17* below |
| **G2** | Versions pinned across repos, reproducibly | **Done** — first certified pin at `releases/v0.1.0-rc1.json` |
| **G3** | Release documentation and process | **Done** — `RELEASE.md`, `scripts/cut-release.sh` |
| **G4** | MVP scope: PIM and HealthKit bridge | **Decided** — both in; SCS POD is authoritative |

---

## G1 status, 2026-09-17

**The nightly certification lane has been red for seven consecutive nights.**
This file recorded G1 as "Done — hosted green nightly (run 31297685782)" for
that entire period, and that run is from 2026-08-09.

| | |
|---|---|
| Last green | **2026-09-10** (`cac03f01`) |
| Red since | **2026-09-11**, every night through 2026-09-17 |
| Failing job | `Regression workflow` (the `Regression Preflight` job passes) |

The cause is not a test result. The MQTT-seeding step picks a free port with a
Python one-liner, and its quoting was wrong:

```yaml
mqtt_port="$(python3 -c 'import socket; ... s.bind((\"\", 0)); ...')"
```

Inside bash single quotes `\"` is literal, so Python received `s.bind((\"\", 0))`
and died with `SyntaxError: unexpected character after line continuation
character` before any engine started. Fixed in the same change as this entry.

**What the seven days actually cost is the point.** The lane failed identically
every night, in a step that cannot pass, and the roadmap went on asserting the
gate was green because nobody re-read the run. A gate marked green without a
current reference is the failure this file's own closing section names — "a gate
marked green without a reference is the same failure mode as a stage that passes
without checking anything" — and it happened to the gate that the rest of the
verification posture rests on.

G1 returns to **Done** when a scheduled run goes green again, named here by run
id and date. Not before, and not on the strength of the fix alone: the fix
removes one syntax error, and what is behind it has not executed since
2026-09-10.

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

### G1.5 · Local lane — done

    bash scripts/regression-test.sh --execute --profile local

The profile already enabled OpenClaw, local AI and the full corpus. What was
missing is that **nothing tested them**: the lane started Ollama and
localAIStack and then ran only the stages the hosted lane already runs, so
`--profile local` bought a slower run rather than more coverage.

`scripts/regression-local-ai.py` (stage `local-ai`) closes that. It checks
three things that fail for different reasons:

1. localAIStack answers `/health`.
2. Every PE reports Ollama **reachable**. A PE that answers cleanly with
   `reachable: false` is a *failure* here — on a lane whose purpose is running
   that provider, an orderly "not there" is a defect, and accepting it would
   let the stage pass in exactly the state the hosted lane is already in.
3. Every runtime agrees which model it is configured for. Disagreement makes
   any downstream comparison meaningless.

OpenClaw was already covered: `run_openclaw` runs whenever `--openclaw` is
set, which is the local default.

The lane pins `OLLAMA_MODEL=llama3.1:8b` for all three engines. Without a pin
the runtimes answer from different models, which makes comparing their
provider output meaningless before it starts.

Results land in `.regression-tests/runs/<run-id>/` exactly as the hosted lane's
do, so the two lanes are read the same way.

**Validated live on 2026-08-09** against a real `cpp:1,lsp:1,scala:1` universe
with Ollama and localAIStack running. The stage found three defects on its
first run, none of which stub tests could have surfaced:

| Finding | Where |
|---|---|
| Runtimes default to different Ollama models | RealityEngine_Scala#38 |
| LSP let `integrations.json` override an explicit `OLLAMA_MODEL`, so the pin reached two of three engines | RealityEngine_LSP#44, fixed in #45 |
| All three reported `reachable: true` while configured for models Ollama had never pulled — every dispatch would have failed against a passing stage | fixed in the probe itself |

The third is the one worth remembering: the stage written to catch this class
of problem had the same blind spot, and only a live run exposed it.

### G1.6 · Bridge simulator leg — done

Stage `healthkit-bridge` runs `localHealthkitBridge/scripts/e2e_simulator.sh`
against a live PE from the registry, on the local lane only.

The leg itself already existed — the bridge's M4 records `e2e_simulator.sh`
and `e2e_seeded.sh` passing against both the TypeScript PE and the native C++
PE. The gap was never building it; it was that no lane invoked it. This wires
it in.

It runs against one PE rather than all three, which is sufficient because
`RealityEngine_Machines/tests/integration/healthkit-ingest-contract.spec.ts`
enumerates every running instance and asserts the ingest contract holds *on
every engine*. The bridge proves the client works; the contract spec proves
the runtimes agree.

Skips with a recorded reason, never silently, when: the profile is hosted, the
bridge is not checked out beside this repo, the toolchain (`xcrun`,
`xcodegen`, `jq`) is absent — Xcode is macOS-only and the lane is otherwise
valid on Linux — or no PE is running.

**Green live on 2026-08-09** against a real iPhone 17 Pro Max simulator and the
C++ PE:

```
  healthkit.sleep    @ [4340:4344] = [0.72, 0.222, 0.556, 1]
  healthkit.bp       @ [4320:4324] = [0.6, 0.65, 0.32, 1]
  healthkit.exercise @ [4330:4334] = [0.107, 0.35, 0.61, 1]
PASS: 3 healthkit sensor sources live on the PE
```

The first run failed with 0 sensors. The cause was authentication, not the
bridge: `startUniverse` enables HealthKit ingest auth by default, generating a
stable token into `config/.healthkit-bridge-token` and handing it to the PE.
The stage launched the app without it, so every ingest was rejected 401.

That failure was badly legible, which is the part worth keeping in mind. The
app said `deliver failed unauthorized`, but that print goes to stdout, which
`simctl launch` only surfaces with `--console`. All the script could see was
`expected >=3 healthkit sensors, saw 0` — a 401 presenting as "the bridge
never ran". The stage now reads the token from the environment or the
persisted file, and says so explicitly when no token is configured, since
`--no-healthkit-token` is a legitimate mode.

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

## G4 · MVP scope — decided 2026-08-09

**Both PIM and the HealthKit bridge are in the MVP.** They were never
alternatives; what was missing was a written boundary between them and a rule
for which copy of the data wins.

### Ownership

| Component | Owns |
|---|---|
| `OpenCommons-Health---Personal-Information-Management` | the **Solid Community Server**, and the POD(s) it maintains |
| `localHealthkitBridge` | a device-side pod, **mirrored into** the POD in the SCS |

### The authority rule

**The authoritative information repository is the POD(s) within the Solid
Community Server.**

The bridge's pod is a source that mirrors into it, not a second system of
record. Where the two disagree, the SCS POD is correct — that is what makes
`mirrorState: .conflict` in the bridge's `MobilePodModel` a resolvable state
rather than an ambiguous one. Nothing downstream should read the device pod as
authoritative, and nothing should treat a successful device-side write as
durable until it has mirrored.

### What this settles

The two repos had drifted into implying different MVPs. PIM's
`docs/LOCALHOST_MVP_SCOPE.md` excluded native iOS and HealthKit outright, while
the bridge had already shipped its host app (M3), simulator e2e (M4) and
iPhone Patient Monitor UX (M7). Neither was wrong about its own work; neither
deferred to the other.

They divide cleanly: PIM does not implement native iOS — the bridge does — and
the bridge does not own durable storage — the SCS does. PIM's exclusion of
native iOS work is a statement about *PIM*, not about the MVP.

Both surfaces are already exercised. The bridge leg is green on the local lane
(G1.6), and PIM already exposes `GET /api/pod/healthkit/status` over the
pod-side `health-pim/healthkit/observations/` container.

### Follow-on work, not blocking this decision

- Specify the mirror seam: who writes to the SCS POD, on what trigger, and how
  `pendingMirror` and `conflict` resolve. The bridge models these states
  already; the contract between the two sides is not written down.
- Add a mirror leg to the local lane once that contract exists, so the
  authority rule is enforced by a test rather than by agreement.

This decision is the single source of truth for the boundary. PIM's and the
bridge's own roadmaps point here rather than restating it, because two copies
of a boundary is what produced this gate.

---

## Known open items

Checked 2026-09-17: **every item this table listed has since closed.** They are
kept below with their resolution rather than deleted, because a table that
empties silently gives no way to tell "resolved" from "forgotten".

| Item | Where | Resolution |
|---|---|---|
| Dispatch replay exists in no runtime | CI#100 | **Closed** |
| `startUniverse.sh` hangs when Docker is unavailable | CI#94 | **Closed** |
| Certification cadence undocumented | CI#87, #79 | **Closed** — both |
| ROBOT / OWL reasoner gap | Machines#46 | **Closed** |

### Open now

| Item | Where | Effect |
|---|---|---|
| Nightly certification red since 2026-09-11 | this file, *G1 status* | **G1 regressed.** Returns to Done only on a named green scheduled run |
| `docs/LOCALHOST_MVP_SCOPE.md` is referenced here but does not exist | this file | a reader following the reference finds nothing; the scope it names is unrecorded |
| Mirror seam unspecified — who writes to the SCS POD, on what trigger, how `pendingMirror` and `conflict` resolve | G4 follow-on | the authority rule is enforced by agreement, not by a test |
| No mirror leg in the local lane | G4 follow-on | blocked on the contract above |

## How to update this file

Change gate status in the same commit that changes the underlying state, and
name the run or PR that proves it. A gate marked green without a reference is
the same failure mode as a stage that passes without checking anything.
