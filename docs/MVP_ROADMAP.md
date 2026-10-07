# MVP Release Roadmap

Last reviewed: 2026-10-07

The route from the current `v0.0.1-baseline` tag to a tagged MVP release of the
integrated RealityEngine application.

`ROADMAP.md` in this repo covers deployment and testing infrastructure and is
complete. This file covers what remains before the composed application can be
released, and is the place to record gate status as it changes.

## Gate summary

| Gate | What it means | Status |
|---|---|---|
| **G1** | Certification runs and passes on every merge to main | **Done again.** Scheduled nightlies green 2026-10-04 → 2026-10-07; latest **37601209935** (2026-10-07, `f4b8c46b`). The 2026-09-25 failures are fixed (#462, #463, #464). See *G1 status, 2026-10-07* |
| **G2** | Versions pinned across repos, reproducibly | **Tooling done; the pin is stale.** `releases/v0.1.0-rc1.json` is from 2026-08-09, covers 8 repos, and predates G4. A run now builds, and so pins, **10**. Re-pin from a green run (release step 7) |
| **G3** | Release documentation and process | **Done.** `RELEASE.md` and `scripts/cut-release.sh`; D1 decided 2026-09-25: application releases are tagged **`release-vN.M.Z`**, enforced by both tools |
| **G4** | MVP scope: PIM and HealthKit bridge | **Decided, and the mirror is built.** localHealthkitBridge#45 closed 2026-09-26 (contract #44, PIM#83, bridge #46, CI#473). Stage `pim-mirror` passes on the local lane (`pr544-1639`, `main-1006`). One gap remains: a `pim-mirror` **skip** does not yet block `cut-release.sh` |

**Release assets re-verified 2026-10-07** (*Release assets*): six of eight
pass. The OWL baselines and the OpenClaw agent index name the corpus as it was
before Machines#208 and need regenerating. **The route to MVP now runs through the local lane (step 2).**

---

## Steps to release the MVP

In order. Each step says what "done" means and where the proof goes. A step is
done when that proof exists, not when the work behind it merges.

| # | Step | Done when | Status |
|---|---|---|---|
| 1 | **Clear the nightly (G1).** Resolve #464 (cpp `wasJustMatched`) and #463 (scala omits MQTT sources at registration). Confirm the empty-MCP-URL fix (#462) clears `service-inventory` and `mcp` | a **scheduled** `regression-tests.yml` run concludes `success`, recorded here by run id and date | **done**: 36990104679 (2026-10-02) was the first scheduled green since 2026-09-10; after one red night (2026-10-03, below), green every night since, latest **37601209935** (2026-10-07) |
| 2 | **Clear the local lane.** `bash scripts/regression-test.sh --execute --profile local`. The hosted lane does not cover Ollama, OpenClaw, the full corpus or the HealthKit bridge (`RELEASE.md`), so this is the only proof of them | every stage passes on `main` of every repo, including `openclaw-integration-*` on all three runtimes, `pim-mirror` and `healthkit-bridge` (on the iPhone) | **open, one stage left.** `pr544-1639` (2026-10-05) passed every stage but built CI from a PR branch, so it cannot certify. `main-1006` (2026-10-06) failed only `healthkit-bridge`, a simulator race; #552 moves the stage to the physical iPhone. Re-run on `main` once #552 merges, with the iPhone connected |
| 3 | **Weekly full-corpus cycle green on schedule.** `full-corpus-cycle.yml`: 1,327 machines validated, loaded identically by all three runtimes, and the 1,322-spec agent corpus rebuilt and matched | a **scheduled** run concludes `success` | **done**: 36296119645 (2026-09-27) and 37184003178 (2026-10-04), both scheduled, both green |
| 4 | **Decide the release tag (D1)** | the decision is recorded here and in `RELEASE.md` *Tag conventions* | **done 2026-09-25**: `release-vN.M.Z` (candidates `release-vN.M.Z-rcN`) |
| 5 | **Build the mirror (D2, MVP-blocking):** bridge → PIM API → POD, per `localHealthkitBridge/docs/MIRROR_CONTRACT.md`: PIM metric catalog, `health-observations` domain, the dynamic approved-metric set, `healthkit/sync/preview` + `apply` with per-batch owner approval; the bridge `PIMClient`; the CI mirror leg | the local-lane **mirror leg is green**, recorded here by run id | **built**; leg green in `pr544-1639` and `main-1006`. **Open:** a `pim-mirror` skip does not block `cut-release.sh`, though D2 says the release waits on this leg (not yet filed) |
| 6 | **Re-verify release assets at the release commit** (commands under *Release assets*) | every check passes against the commits being pinned | **re-run 2026-10-07 at `origin/main`: 6 of 8 pass.** The OWL baselines and the agent index are stale by fingerprint since Machines#208; fixed by Machines#212 and localOpenClawStack#57 (open). Repeat at the commits pinned |
| 7 | **Generate the manifest from the certifying run** (see D3): `scripts/release-manifest.py generate … --version release-v0.1.0 --out releases/release-v0.1.0.json`. It must be non-provisional and cover all 10 repos | `releases/release-v0.1.0.json` exists and is committed | open (supersedes `v0.1.0-rc1`). Both local runs' manifests are provisional: `main-1006` failed, and `pr544-1639` built CI `ce3059fa` while `origin/main` was `793ca566` |
| 8 | **Rehearse the cut:** `scripts/cut-release.sh --manifest releases/release-v0.1.0.json` (dry run) | no drift, and no tag collision | open |
| 9 | **Tag, then push separately:** `--execute`, then `--execute --push` | tags exist on all 10 remotes | open |
| 10 | **Release notes:** what certified it, what the hosted lane did not cover, and the known limitations below | notes published with the tag | open |
| 11 | **Update this file** in the same change: G1–G4 to Done, naming the run | this table reads Done throughout | open |

### Decisions needed

- **D1: the application release tag. Decided 2026-09-25: `release-vN.M.Z`.**
  `RELEASE.md` puts the *same* tag on every repo in a release, and
  `cut-release.sh` refuses a tag that already exists at a different commit.
  `localHealthkitBridge` already carries its own `v0.1.0` (`e351651`), so a plain
  `v0.1.0` application tag could not be cut. Application releases therefore get
  their own namespace: `release-vN.M.Z` (candidates `release-vN.M.Z-rcN`).
  Components keep plain semver on their own schedules. `release-manifest.py
  generate` and `cut-release.sh` both refuse any other form. **The MVP is
  `release-v0.1.0`.**
- **D2: the mirror seam. Decided 2026-09-25: it blocks the MVP.** Specified in
  `localHealthkitBridge/docs/MIRROR_CONTRACT.md` (localHealthkitBridge#44), and
  tracked in #45. The owner's decisions:
  - the bridge talks to **PIM's API**, and PIM, which already holds the Solid
    session and the data workflows, writes the POD;
  - **D2a:** owner approval **per batch**;
  - **D2b:** **every health metric** goes to PIM, and the approved set can be
    **changed at runtime and is honored** everywhere, including PE ingest scope;
  - the surface is `healthkit/sync/preview` + `apply`.
- **#467: resolved, no longer a question.** The regression profile now derives
  from `config/regression-corpus.txt` and loads all 15 agents
  (localOpenClawStack#47), and #496 added the per-run `agent-corpus-current`
  stage and the §3.7(4) provenance check. Closed 2026-10-01.
- **D3, open: which run certifies the release.** Step 7 pins from one run, but
  the hosted nightly (step 1) does not cover Ollama, OpenClaw, the full corpus,
  the mirror or the bridge, and the local lane (step 2) is the only run that
  does. Either pin from a green **local** run on `main`, or require the hosted
  and local runs to have built the same commits. The local lane already writes
  `release-manifest.json`, so the first option needs no new tooling.

### Known limitations to state in the release notes

- **Hosted certification** does not cover the full corpus, Ollama, OpenClaw or
  the HealthKit bridge (`RELEASE.md`). Steps 2 and 3 cover them.
- **MQTT Yuma** runs against the live broker on every lane (#520) and skips,
  with the reason recorded, when the broker does not answer within 10s. Both
  recent local runs skipped it.
- **HealthKit bridge** is proven only on a physical iPhone (#552); with none
  connected the stage records a skip.

---

## Release assets: re-verified 2026-10-07, two stale

Checked against `origin/main` of every repo on 2026-10-07: Machines `2e907a3f`,
CPP `e40465a`, LSP `7d45555`, Scala `b7e2e77`, Manager `a8c0648`,
localOpenClawStack `e06c029`, CI `f4b8c46`; Node 26.8, ROBOT, pySHACL and QUDT
all present. No check wrote to a checkout. Repeat at the commits being pinned.

| Asset | State 2026-10-07 | Check |
|---|---|---|
| Machine corpus, 1,327 machines, 12 domains | **pass**: 0 errors, 0 warnings, **nothing skipped** (ROBOT, SHACL, QUDT all ran); arbitration 2,837 contended cells; one-CES-one-pattern OK | `bash scripts/validate-corpus.sh` in Machines, with `PYSHACL_PYTHON`/`QUDT_PYTHON` set |
| JSON Schema | **pass**: 1,337 artifacts, 0 invalid | `node scripts/validate-schemas.mjs` |
| Oracles | **pass**: 4,964 verified | `node scripts/cesgen-oracles.mjs --check` |
| cesgen bindings | **pass**: 1,327 machines verified | `node scripts/cesgen.mjs --all --check` |
| OpenAPI | **pass**: regeneration differs only in `x-generated-from` (the path it ran from); CPP, LSP and Manager mirrors byte-identical to CI's | `bash scripts/generate-openapi.sh`, then `git diff docs/openapi` |
| CES contract shards | **pass**: 16 scopes, **16 recorded** (the unrecorded scope of 2026-09-25 is closed) | `npm run ces-contracts:status` in Machines |
| OWL release baselines | **stale fingerprint.** Released at corpus `08e9269cb38d` (Machines#198, 2026-10-04); corpus is now `db2cbb45b46f`. The diff is the version annotations only; reasoning is consistent under ELK and HermiT | `reason-owl.sh` must report no changes against `semantics/released/` |
| OpenClaw agent corpus | **stale index.** All agent specs match; `INDEX.json` provenance still names `08e9269cb38d`, and `INDEX.md` differs. Exit criteria PASS; `--require-current-digest` FAILS. Regression profile current (15 agents) | `materialize_agents.py --check`; `check-corpus-exit-criteria.py … --require-current-digest` |

**Cause of both:** Machines#208 (2026-10-05, *one CES, one regular
expression*) changed 7 machine files after the 2026-10-04 baseline release and
weekly cycle, so the corpus fingerprint moved. The agent corpus and the OWL
baselines carry the **same fingerprint**, which is why they went stale
together. **Fixes open:** localOpenClawStack#57 (index digest only; all five
agent-corpus gates pass) and Machines#212 (12 domains + corpus re-released;
the only axiom changes are the 37 `elementLevel` values #208 corrected, and a
re-run reports `no axiom changes`). Merge both, then step 6 is 8 of 8.

Neither the per-run `agent-corpus-current` stage nor the regression lanes
caught it: the stage checks the 15 regression agents, which did not change.
Only the weekly cycle checks the index digest, and its next run is Sunday
2026-10-11.

---

## G1 status, 2026-10-07

**The nightly is green again.** It was red for 21 consecutive nights
(2026-09-11 → 2026-10-01) and has failed once since:

| Date | Run | Result |
|---|---|---|
| 2026-10-01 | 36922035240 (dispatch, nightly settings) | **success**: first green hosted run at `main` after the fixes for #463 and #464 merged; `reset-contract` and `export-parity` pass 3-of-3 |
| 2026-10-02 | 36990104679 (scheduled) | **success**: first scheduled green since 2026-09-10 |
| 2026-10-03 | 37113046063 (scheduled) | failed at `build-ci-mcp-routes-check`: the MCP engine-routes fixture was stale after that day's SURFACE_SPEC changes. Regenerated by #519; #530 made the stage regenerate the fixture rather than fail on it, per the *regenerate a stale registry* rule |
| 2026-10-04 → 10-07 | 37197442002, 37291753819, 37443457740, **37601209935** (scheduled) | **success** every night |

What closed the 2026-09-25 failures:

| Stage | Fix |
|---|---|
| `service-inventory`, `mcp` | #462: an empty MCP URL means the default |
| `export-parity` (CI#464) | #487 resets every runtime first and settles what RE reset leaves |
| `reset-contract` (CI#463) | engine fixes merged 2026-10-01 (CPP `0598e43`, LSP `d7cdec9`, Scala `83a8a12`) and #488, which asserts source activity at registration; all three now declare the same 34 sources |

The stage set has grown again since: arbiter conformance (#527),
arbitration retention (#524), boot-source declaration (#488), agent-corpus
currency (#496) and the step completion point that replaced `--settle-ms`
(#522, closing #375). A green nightly today covers all of them.

### G1 status, 2026-09-25 (superseded, kept as the record)

**The nightly certification lane had been red for 15 consecutive nights**
(2026-09-11 → 2026-09-25). The cause had moved twice, and the lane got
further each time:

| Period | Where it failed |
|---|---|
| 2026-09-11 → 09-17 | the MQTT-seeding step: a Python one-liner with broken quoting (`SyntaxError`); no engine started. Fixed 2026-09-17 |
| 2026-09-18 → 09-21 | the same step: `Error: Bad file descriptor` (#350) |
| **2026-09-25** (run 36118634489, `5f8bb315`) | seeding passes, all stages run, and **four fail** (below) |

| Failing stage | Cause | State |
|---|---|---|
| `service-inventory` | the scheduled run passed an empty MCP URL, so the stage probed `'/healthz'` (`ValueError: unknown url type`) | **fixed by #462**, merged after this run's commit; confirm on the next run |
| `mcp` | same empty URL: *"Failed to parse URL from /healthz"*, then `/mcp` | **fixed by #462**; confirm on the next run |
| `export-parity` | 19 of 21 machines differ **only** on `events[0].wasJustMatched`: cpp-1 `False`, lsp-1/scala-1 `True` | **open: #464** |
| `reset-contract` | at registration scala-1 declares none of the MQTT `LATERAL/*` sources that cpp-1 and lsp-1 declare | **open: #463** |

G1 returned to **Done** on a *scheduled* green run (36990104679, 2026-10-02),
not on the strength of the fixes alone.

### G1 status, 2026-09-17 (superseded, kept as the record)

The lane had been red for seven nights while this file recorded G1 as "Done —
hosted green nightly (run 31297685782)", a run from 2026-08-09. The cause was
the MQTT-seeding one-liner above. **What the seven days cost is the point:** a
gate marked green without a current reference is the failure this file's closing
section names, and it happened to the gate the rest of the verification posture
rests on.

---

## G1 · Certification

The verification posture rests on distinct runtimes agreeing, and quorum is
**3-of-3** (`docs/QUORUM_CONTRACT.md`): a 2-1 split is a disagreement, not a
result with an outlier. Everything here exists to make that claim checkable
rather than asserted.

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

### G1.3 · Stages green — done on 2026-08-09; the stage set has since grown

First fully green certification run: **31297685782**, hosted profile,
`cpp:1,lsp:1,scala:1`, 2026-08-09. The table is that run's stage set:

| Stage | Status | Notes |
|---|---|---|
| Build (all repos) | ✓ | |
| Service inventory | ✓ | 6 health checks, all runtimes |
| Universal-vector parity | ✓ | cpp / lsp / scala byte-identical across 5 events |
| MQTT Yuma stream | ✓ | all three runtimes, retained-message seeding |
| MCP open service | ✓ | 30 calls passed, 3 skipped (empty ledger on a cold universe), 0 failures |
| OpenClaw handoff | n/a | out of scope on the hosted lane by policy (G1.1) |

**Since then** the lane has added export parity, the reset contract (#163), PE
step contract, engine config and process parity, machine-set parity, and the
arbiter. `export-parity` and `reset-contract` were the last two to go green
(*G1 status*). A green run today proves considerably more than 31297685782
did.

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

`REGRESSION_SCHEDULE_ENABLED = true` and, since 2026-08-09,
`REGRESSION_SCHEDULE_RUN_MODE = full` (both confirmed 2026-09-25). Certification
runs nightly at `17 9 * * *` UTC against main.

It was deferred while a stage was red, because scheduled runs default to
`create_issue_on_failure` and would have filed an issue every night. Run
31297685782 went fully green, which removed the reason.

This is the gate that turns certification from something we run into something
that runs. *That it runs is done; that it passes is recorded under* G1 status.

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
do, so the two lanes are read the same way. The run history keeps the two most
recent runs (`--keep-runs`; see `scripts/CLAUDE.md`).

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

**Latest local runs:**

| Run | Finished | Result |
|---|---|---|
| `pr544-1639` | 2026-10-05 | **every stage passed**, including OpenClaw on all three runtimes, `local-ai`, `localai-machines`, `pim-mirror` and `healthkit-bridge`. Built CI from PR #544, not `main`, so it cannot certify. MQTT Yuma skipped; arbiter conformance not run |
| `main-1006` | 2026-10-06 | failed **only `healthkit-bridge`**: the simulator leg saw 0 sensors inside its fixed 30s wait while they landed about a second later. #552 replaces it with the physical-iPhone leg. MQTT Yuma and `arbiter-sweep` skipped |

The 2026-09-24 OpenClaw failure on scala-1 is gone: Scala#153 closed
2026-10-01, and #507 now names every OpenClaw failure stage, so a failure
can no longer report an empty `failureStage`. This is release step 2.

### G1.6 · Bridge simulator leg — done

Stage `healthkit-bridge` runs `localHealthkitBridge/scripts/e2e_simulator.sh`
against a live PE from the instance registry, on the local lane only.

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
stable token into `.secrets/healthkit-bridge-token` (0600, gitignored; owned by
`scripts/lib/healthkit-token.sh`) and handing it to the PE.
The stage launched the app without it, so every ingest was rejected 401.

That failure was badly legible, which is the part worth keeping in mind. The
app said `deliver failed unauthorized`, but that print goes to stdout, which
`simctl launch` only surfaces with `--console`. All the script could see was
`expected >=3 healthkit sensors, saw 0` — a 401 presenting as "the bridge
never ran". The stage now reads the token from the environment or the
persisted file, and says so explicitly when no token is configured, since
`--no-healthkit-token` is a legitimate mode.

The bridge itself shipped **v0.1.0 (MVP) on 2026-09-24**
(`localHealthkitBridge` `v0.1.0` → `e351651`). That is a component release,
which is why D1 exists.

### G1.7 · Weekly full-corpus cycle — done, green on schedule

`full-corpus-cycle.yml` is the only check over all 1,327 machines, which the
per-PR gates and the regression lanes deliberately do not load. Weekly since
#468 (Sunday 05:00 UTC), it runs three jobs:

- **static sweep:** every generator, schema, OWL reasoning and inventory gate,
  asserting nothing was skipped;
- **load parity:** each runtime loads the whole corpus from the 7,680 floor and
  must report 1,327;
- **agent corpus:** the full 1,323-spec OpenClaw agent corpus is rebuilt from
  the current machine corpus, and must pass `check-corpus-exit-criteria.py` and
  match the committed specs.

Until 2026-09-25 it had **never passed**. The sweep skipped its QUDT and
localAIStack-dependent checks and failed on the skip (fixed by #468). That
failure suppressed load parity, which therefore never ran; when it did, cpp
recorded `ERROR` because its `start.sh` refuses to run without Qdrant and was
never launched (#383, fixed by #469). Branch dispatch **run 36180913113 is the
first fully green run**: all three runtimes 1,328 at `eventDimension` 16,944.

Scheduled runs **36296119645 (2026-09-27) and 37184003178 (2026-10-04)** are
both green: 1,327 machines loaded on every runtime at `eventDimension` 16,944
(RS Flip Flop retired, #478), and 1,322 agents rebuilt and matched. #482 added
the localAIStack checkout the agent-corpus job needed.

---

## G2 · Version pinning — tooling done; pin stale

- `VERSION-COMPAT.md` records the compatible set.
- `scripts/validate-versions.sh` runs in the harness and now actually inspects
  worktrees (it was silently skipping every repo).
- localAIStack pins Ollama v0.32.0 and the observability stack
  (localAIStack#29, #30).
- **`scripts/release-manifest.py`** pins every repo **the certifying run built**
  to the SHA it built, so a tagged release can be rebuilt exactly. The set is the
  run's, not a fixed list, and both lanes now build **10 repos**: the original
  eight, plus `localHealthkitBridge` and
  `OpenCommons-Health---Personal-Information-Management`, which entered with G4
  (confirmed from the manifests of hosted run 36118634489 and local run
  `20260924T215111Z`).

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

Both recent local runs emitted 10-repo manifests, and both are provisional
(`main-1006` failed; `pr544-1639` built a CI commit that was not
`origin/main`). The refusal worked as designed.

**`releases/v0.1.0-rc1.json` is a historical pin, not a release candidate.**
It was generated from run 31297685782 on 2026-08-09, covers 8 repos, and
predates G4, so it omits both PIM and the HealthKit bridge, which G4 put in
scope. Release step 7 supersedes it with a pin from the next green run.

---

## G3 · Release documentation — done

[`RELEASE.md`](../RELEASE.md) defines a release as *a set of commits across the
application's repos certified together by one regression run* — there is no
build artifact, because the application is composed from source at run time. It
covers cutting, certifying, verifying, tag conventions and rollback, and ends
in a checklist.

`scripts/cut-release.sh` makes the process executable rather than prose:
dry-run by default, refuses a provisional manifest, refuses a drifted
workspace, refuses a tag that already exists at a different commit, and treats
pushing tags as a separate opt-in from creating them.

Certification is recorded as **hosted GitHub Actions, nightly at `17 9 * * *`
UTC plus manual dispatch** — the open acceptance criterion of #87.

`RELEASE.md` is explicit that a green hosted run does **not** cover the full
corpus, Ollama, OpenClaw or the HealthKit bridge, so the release notes cannot
imply coverage the lane refuses to provide.

**D1, decided 2026-09-25:** application releases are tagged `release-vN.M.Z`,
so they cannot collide with a component's own `vN.M.Z` (`localHealthkitBridge`
`v0.1.0`). `release-manifest.py generate` and `cut-release.sh` both refuse any
other form.

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
`docs/LOCALHOST_MVP_SCOPE.md` (in `OpenCommons-Health---Personal-Information-Management`)
excluded native iOS and HealthKit outright, while the bridge had already shipped
its host app (M3), simulator e2e (M4) and iPhone Patient Monitor UX (M7).
Neither was wrong about its own work; neither deferred to the other.

They divide cleanly: PIM does not implement native iOS — the bridge does — and
the bridge does not own durable storage — the SCS does. PIM's exclusion of
native iOS work is a statement about *PIM*, not about the MVP.

Both surfaces are already exercised. The bridge leg is green on the local lane
(G1.6), and PIM already exposes `GET /api/pod/healthkit/status` over the
pod-side `health-pim/healthkit/observations/` container.

### The mirror seam — D2, decided 2026-09-25: MVP-blocking

The mechanics are specified once, in `localHealthkitBridge/docs/MIRROR_CONTRACT.md`.
In short: the bridge sends readings to **PIM's API**, and PIM, which already
authenticates to the Solid server, validates with ShEx, reconciles and records
activity, is the only writer to the POD. A conflict leaves the POD record
unchanged, per the authority rule above. The **mirror leg in the local lane**
(happy path, a conflict that leaves the POD unchanged, no owner approval → 403)
enforces the rule by test rather than by agreement. It is release step 5,
tracked in localHealthkitBridge#45.

This decision is the single source of truth for the boundary. PIM's and the
bridge's own roadmaps point here rather than restating it, because two copies
of a boundary is what produced this gate.

---

## Known open items

### Closed since the last review

| Item | Where | Resolution |
|---|---|---|
| Dispatch replay exists in no runtime | CI#100 | **Closed** |
| `startUniverse.sh` hangs when Docker is unavailable | CI#94 | **Closed** |
| Certification cadence undocumented | CI#87, #79 | **Closed** — both |
| ROBOT / OWL reasoner gap | Machines#46 | **Closed** |
| `docs/LOCALHOST_MVP_SCOPE.md` "does not exist" | this file | **Resolved 2026-09-25**: it exists in `OpenCommons-Health---Personal-Information-Management`; this file cited it without naming the repo |
| Full-corpus load parity: cpp `ERROR` | CI#383 | **Closed** by #469: cpp's `start.sh` refused to run without Qdrant |
| OpenClaw agent corpus five weeks stale | localOpenClawStack#46 | **Closed**: regenerated, fixture guard fixed, provenance recorded |
| Scala cesgen bindings never checked | CI#466, Scala#161 | **Closed**: 355 files regenerated; the gate now reaches Scala |
| Nightly red: cpp `wasJustMatched` disagrees with lsp/scala | CI#464 | **Closed 2026-10-01** by #487; confirmed on 36922035240 |
| Nightly red: scala declares no MQTT sources at registration | CI#463 | **Closed 2026-10-01**: engine fixes + #488; confirmed on 36922035240 |
| `service-inventory` / `mcp` fail on an empty MCP URL | #462 | **Confirmed** by every scheduled green since 2026-10-02 |
| Local lane: OpenClaw fails on scala-1 | Scala#153, #507 | **Closed**: OpenClaw passes on all three in `pr544-1639` and `main-1006` |
| Mirror not built | localHealthkitBridge#45 | **Closed 2026-09-26**: PIM#83, bridge #46, CI#473 |
| Stale agent corpus detected weekly only; 12 of 15 agents | CI#467 | **Closed 2026-10-01**: localOpenClawStack#47, #496 per-run gate |
| No step-completion barrier | CI#375 | **Closed 2026-10-03** by #522; `--settle-ms` removed |
| TypeScript 7 in Manager PE backend | Manager#96 | **Done** by Manager#212 (2026-10-04): vitest + tsx, TypeScript 7 adopted |

### Open now

| Item | Where | Effect on release |
|---|---|---|
| HealthKit stage on the physical iPhone | CI#552 (open) | **blocks step 2**: `main-1006` failed only this stage |
| Local lane green on `main` of every repo | step 2 | **blocks step 7** under either answer to D3 |
| A `pim-mirror` skip does not block `cut-release.sh` | noted on localHealthkitBridge#45; not yet filed | D2 makes the leg release-blocking, so the tool should refuse a skip |
| Which run certifies the release | D3 | decide before step 7 |
| OWL baselines and agent index name corpus `08e9269cb38d`; corpus is `db2cbb45b46f` (Machines#208) | Machines#212, localOpenClawStack#57 | merge both; repeat step 6 at the release commit |
| Mirror PE scope push covered only by PIM unit tests; bridge mirror not wired into `App/` | localHealthkitBridge#45 (noted at close) | not blocking; state in the release notes |

## How to update this file

Change gate status in the same commit that changes the underlying state, and
name the run or PR that proves it. A gate marked green without a reference is
the same failure mode as a stage that passes without checking anything.
