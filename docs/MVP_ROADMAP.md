# MVP Release Roadmap — V0.01 evaluation

Last reviewed: 2026-10-08

The route from the local `v0.0.1-baseline` snapshot to a tagged MVP release of
the integrated RealityEngine application. **V0.01 is the requested milestone
label; its exact Git tag is an evaluation decision (R01).** The existing
approved application tag is `release-v0.1.0`; this update does not change it.

`ROADMAP.md` in this repo covers deployment and testing infrastructure and is
complete. This file covers what remains before the composed application can be
released, and is the place to record gate status as it changes.

## Gate summary

| Gate | What it means | Status |
|---|---|---|
| **G1** | Hosted checks stay green; a local run certifies the composed application | **Current evidence green, release acceptance incomplete.** Scheduled regression **37757370600** passed on 2026-10-08 at `980e75cb`; per-merge e2e **37843606612** passed at CI `2427181`. Local **20261008T215059Z** completed at that CI commit, with coverage gaps below |
| **G2** | Versions pinned across repos, reproducibly | **A current untagged candidate exists.** Local run `20261008T215059Z` emitted a non-provisional manifest for **10** repos. No versioned MVP manifest has been committed or released; R11–R15 complete that path |
| **G3** | Release documentation and process | **Core process implemented; refresh open.** D1's **`release-vN.M.Z`** namespace is enforced. Inventory/coverage prose and release-tool eligibility/metadata gaps are R02–R03 |
| **G4** | MVP scope: PIM and HealthKit bridge | **Implementation exists; device acceptance remains open.** `pim-mirror` passed in `20261008T215059Z`; `healthkit-bridge` skipped without an iPhone. D2 remains release-blocking, but the cutter does not enforce a mirror pass. R03 and R07 address those gaps |

**Release assets re-verified 2026-10-07** (*Release assets*): six of eight
passed at first; the OWL baselines and the agent index trailed Machines#208.
Both are fixed (Machines#212, localOpenClawStack#57, merged) and passed at the
commits `main-1007` built. This is historical evidence, not an eight-check
asset certification of the newer Machines commit (R09).

**Latest candidate: `20261008T215059Z`, 2026-10-08, 14:50–15:13 PDT.**
All ten repos built at the `origin/main` SHA recorded by the run, the engine
provenance gate passed, and the local lane completed with **17 live stages
passed, 3 skipped, 0 failed**. It ran `cpp:1,lsp:1,scala:1`, OpenClaw and local
AI, using the **regression corpus**, not the full corpus. The disposable
`Regression-Test-*` branch names are harness worktrees, not unmerged feature
commits. The candidate includes the tooltip, keep-alive, metrics and instance
registry address fixes merged since `main-1007`.

**Not certified by that run:** the physical iPhone (not connected), MQTT Yuma
(broker timeout), the opt-in arbiter sweep, the deployment suite (`not-run`,
not wired into the harness), the complete 2D/3D visual matrix, or a six-instance
full-corpus deployment. A completed run and a non-provisional manifest do not
turn those gaps into passes. No release tag was created by this update.

Evidence is under `.regression-tests/runs/20261008T215059Z/`: `manifest.json`,
`release-manifest.json`, `summary.md`, `reports/regression-status.json` and
`logs/verify-build-provenance.log`. The structured stage statuses carry the
skip reasons; `reports/stage-results.tsv` records successful wrapper exits
even for skipped stages and is insufficient on its own for release approval.

### Candidate pin inventory — evidence, not a release freeze

| Repository | SHA built by `20261008T215059Z` |
|---|---|
| RealityEngine_CI | `2427181` |
| RealityEngine_CPP | `ea6545f` |
| RealityEngine_LSP | `675e7b8` |
| RealityEngine_Scala | `06a4853` |
| RealityEngine_Machines | `dde5f97` |
| RealityEngine_Manager | `a7d4545` |
| localAIStack | `ab8de43` |
| localOpenClawStack | `6cda7e7` |
| OpenCommons-Health---Personal-Information-Management | `389eba2` |
| localHealthkitBridge | `dd3b188` |

The run manifest contains the full SHAs. Any implementation fixes arising
from this evaluation require a new final run; this candidate is the starting
evidence, not permission to tag a different set.

---

## Evaluation task list leading to the tagged release

This is a proposed execution backlog, not an approval to deploy or publish.
Owners below are proposed responsibility areas. **Blocking** means required
under the existing scope/contract; **acceptance** means a proposed release
criterion to evaluate; **decision** needs an explicit recorded disposition.
An unchecked task is open even when its underlying implementation has merged.

| Task | Priority / responsibility | Depends on | Deliverable |
|---|---|---|---|
| R01 | Decision — release owner | — | Exact version, scope and allowed skips |
| R02 | Blocking — CI/docs | R01 | Consistent release documentation |
| R03 | Blocking — CI/tooling | R01 | Required coverage enforced before tagging |
| R04 | Acceptance — CI/engine maintainers | relevant fixes merged | Six-instance runtime and observability proof |
| R05 | Acceptance — Manager | R04 | 2D/3D node-tooltip and live-activity acceptance |
| R06 | Decision — localAI/CI | R04 | Disposition of CI#518 parity gaps |
| R07 | Decision + acceptance — bridge/PIM/operator | R01 | Physical-device proof or explicit scope limitation |
| R08 | Decision + acceptance — CI/MQTT | R01, R04 | Deterministic MQTT proof and Yuma disposition |
| R09 | Blocking — Machines/OpenClaw/CI | candidate corpus fixed | Current release assets and full-corpus evidence |
| R10 | Acceptance — CI/deployment | R04, R06, R08 | Native deployment suite and legacy Docker smoke |
| R11 | Blocking — CI/release operator | R02–R10 dispositions complete | Final local certification at the release pins |
| R12 | Blocking — CI/release operator | R11 | Versioned ten-repo manifest |
| R13 | Blocking — CI/release operator | R12 | Clean cut rehearsal and tag collision check |
| R14 | Publication — release owner/operator | R13, release authorization | Same application tag on all ten remotes |
| R15 | Publication — CI/docs | R14 | Published notes, durable evidence and release verification |

### Scope and release controls

- [ ] **R01 — Confirm what V0.01 names and what it promises.** Keep the
  `release-vN.M.Z` namespace. Recommended: retain the approved
  `release-v0.1.0` application version and use V0.01 only as the milestone
  label. If the intent is SemVer `0.0.1`, record the revision to D1 and use
  `release-v0.0.1`; do not silently equate these versions. Confirm all ten
  repos remain in scope, whether six-instance/full-corpus operation is a
  release promise, and the disposition of iPhone, MQTT and arbiter-sweep skips.
  **Done:** one recorded scope/version decision reflected in this file and
  `RELEASE.md`. Running a lane without an iPhone is not a blanket device-proof
  waiver for the release.

- [ ] **R02 — Align the release instructions with the implemented system.**
  `RELEASE.md` says ten repos but lists eight and describes the bridge as
  outside the composed runtime without explaining its inclusion in the
  application pin. Add PIM and the bridge to the release inventory, replace
  the historical eight-repo manifest example, and distinguish per-merge
  `e2e-tests.yml` checks from scheduled `regression-tests.yml` certification
  evidence. Both regression profiles default to the regression corpus;
  full-corpus evidence is separate. **Done:** a reviewed documentation PR
  with one consistent version, scope, certification policy and command order.

- [ ] **R03 — Make release eligibility an enforced check.** At minimum,
  refuse a skipped/missing/failed `pim-mirror`, per D2; require local coverage,
  completed build/start/live-test phases, all expected repos/builds and a
  non-provisional run. Implement any additional required stages adopted in
  R01. Preserve real skip statuses and reasons instead of treating a wrapper
  exit of zero as a pass. Ensure the release evidence includes the parity
  stages currently present in the run summary but absent from the generated
  manifest's stage map. Derive the annotated tag's profile/engine text from
  the manifest: `cut-release.sh` currently always writes "hosted profile".
  Aggregate tag-push failures so a partial publication cannot report success.
  **Done:** positive and refusal tests for valid local, hosted, build-only,
  provisional, missing-stage and mirror-skipped candidates; correct tag
  metadata and a nonzero result on a simulated push failure. This task changes
  release tooling, not the functioning mirror implementation.

### Product and operational acceptance

- [ ] **R04 — Verify the deployed six-engine universe, not just its source.**
  Build through CI with `--execute --build-only --no-cold-start` when preparing
  the main-checkout artifacts; launch through CI with
  `--engines=cpp:2,lsp:2,scala:2` and the corpus selected in R01. Resolve the
  active instance registry through CI's helper; check all six RE/PE health
  endpoints, unique stable instance UUIDs, machine-load counts and running
  artifact provenance. Confirm Manager serves the selected build. Proposed
  acceptance: at least ten minutes of stepping, stream heartbeats and metrics
  scraping without stream loss, health starvation or orphan processes.
  Confirm Prometheus targets, engine logs in Loki and the relevant Grafana
  panels receive live data after CI#557/#558, with idle/disabled states
  explained. **Done:** launch manifest, endpoint/identity inventory, bounded
  scrape measurements and soak log tied to exact SHAs. The latest regression
  run proves three instances, not this six-instance load.

- [ ] **R05 — Accept node tooltips and CES activity in 2D and 3D.** Exercise
  cpp, lsp and scala engine selection in both views; verify arcs/arrowheads,
  event-state changes, bounded popup placement/resizing, and no stale activity
  after switching engines. Test Light, System with a light OS, all other
  themes, small viewports, and pinned plus hover panels together. Proposed
  criteria: arc/arrowhead contrast at least 3:1, label contrast at least 4.5:1,
  a visible state transition driven by a known step, and no viewport clipping.
  **Done:** matrix results, screenshots and automation attached to the
  release evidence. Manager#254 closes #253 and recorded 225 passing frontend
  tests plus 4/4 Chromium e2e checks; that is not the entire live matrix.
  Evaluate its noted gaps: the matched ring is 2.4:1 under Light, compact
  32×32 nodes open no tooltip, and Firefox/WebKit were not exercised. Fix any
  accepted-scope usability failure or record an explicit limitation.

- [ ] **R06 — Resolve the release disposition of localAI parity (CI#518).**
  The fan-out implementation exists; the issue remains open for separately
  generated engine-initiated LLM responses, health-slot convergence, and
  engine-minted identity differences. Test identical requests across the
  release engine set and capture identity-key differences before comparing
  serialized bodies. Distinguish different LLM inputs from disagreement over
  identical deterministic inputs; do not normalise away value differences.
  **Done:** each remaining item is fixed and proven, or excluded by the
  recorded scope decision. Any in-scope deterministic 3-of-3 disagreement
  blocks release. A green OpenClaw/localAI availability stage alone does not
  close this issue.

- [ ] **R07 — Prove the physical-iPhone path and the bridge-to-PIM boundary.**
  Recommended for the existing integrated-health scope: connect a signed,
  paired iPhone with Developer Mode, run the real app leg, and verify live
  HealthKit observations reach the PE. Re-prove the PIM mirror's approved
  batch write, conflict preserving the POD, denial without owner approval and
  runtime metric-scope changes. Inspect whether the mirror client is wired
  into the shipping app before claiming an automatic device-to-POD flow;
  the prior close of bridge#45 noted that gap. **Done:** device build/install/
  ingest evidence plus green mirror results at the release commits, or an
  explicit release-owner decision describing the unproven/device-app scope.
  The authoritative record remains the Solid Community Server POD; do not
  infer live Epic writeback from these tests. No simulator substitutes for
  the physical-iPhone acceptance leg.

- [ ] **R08 — Separate MQTT correctness from Yuma availability.** Evaluate
  CI#317's deterministic broker stage: feed a fixed mapped/unmapped/unchanged
  sequence, drain it, and compare mapping, rejection, change-only pushes and
  resulting values across cpp/lsp/scala. Keep the live bridge exclusive to
  that measurement stage. Re-probe Yuma independently; either record a pass
  or approve a named external-broker limitation. **Done:** deterministic
  results at the release commits plus a distinct Yuma result/disposition.
  The latest local run's Yuma timeout proves neither MQTT failure nor MQTT
  parity. New MQTT metric exports are implementation evidence, not ingest
  acceptance. Broader CI#317 implementation can be deferred only if the
  release makes no unproven MQTT-parity claim.

- [ ] **R09 — Re-verify all eight asset families at the selected commits.**
  Run corpus validation with all semantic tools, schema validation, oracles,
  cesgen bindings, generated OpenAPI/mirrors, CES contract shards, OWL
  baselines and the full OpenClaw agent index. Regenerate stale derived
  artifacts and fail only on disagreement that survives regeneration, per
  the engineering contract. Separately obtain full-corpus load/agent proof
  at the selected corpus digest; scheduled **37184003178** (2026-10-04) is
  green historical evidence, not proof of the 2026-10-08 pin. Record corpus
  machines, auxiliary artifacts and agent counts separately; do not equate
  1,337 JSON artifacts with 1,327 corpus machines. **Done:** eight check
  results and full-corpus evidence tied to exact SHAs/digests, with nothing
  required silently skipped. Fall Detection is contained in the full corpus;
  off-screen force-layout placement is not missing corpus membership.

- [ ] **R10 — Run deployment acceptance explicitly.** The local summary
  currently reports `deployment: not-run` because the suite is not wired
  into `regression-test.sh`. Run the native deployment suites against the
  intended active instance registry, and preserve/verify the legacy Docker
  startup, discovery and teardown path. Evaluate wiring the suite into
  certification versus attaching a separate exact-pin report. **Done:**
  deployment results distinguish availability, instance registry alignment,
  contract parity, byte equivalence and integration success; no in-scope
  failure is hidden by a summary pass. CI#165's additional local-containerized
  lane is a separate backlog item, not assumed required infrastructure.

### Certification, release cut and evidence

- [ ] **R11 — Freeze the intended source set and run final certification.**
  Merge accepted fixes through PRs; ensure every included repo is clean and
  current with `origin/main`, then run
  `RE_FREE_PORTS=true bash scripts/regression-test.sh --execute --profile local --run-id <final-run-id>`.
  Connect the iPhone if R07 requires its pass. The default trio is sufficient
  for the established certifier; attach R04's six-instance proof separately
  unless R01 adopts six instances as the final run requirement. Require the
  actual structured stage results to meet R01/R03, including a mirror pass.
  Keep the full-corpus and deployment reports linked to the same pins, and
  refresh hosted checks/nightly evidence for the final CI changes. **Done:**
  a completed non-provisional final run with no required skip/failure,
  clean provenance and a documented decision for every optional omission.
  Runtime changes after this run require recertification. The current
  candidate took about 23 minutes; that is an observation, not a scheduling
  estimate for the remaining work.

- [ ] **R12 — Generate the versioned manifest from that run.** Use
  `scripts/release-manifest.py generate --run-dir .regression-tests/runs/<final-run-id> --version <approved-application-tag> --out releases/<approved-application-tag>.json`.
  **Done:** all ten full SHAs and expected build/coverage/stage evidence are
  present, no provisional marker exists, and the supporting reports are
  preserved. CI#556 protects the newest completed live run from routine
  retention, but a release still needs a durable evidence archive. Do not
  hand-edit a pin to a later commit or use `--allow-unverified` to qualify it.

- [ ] **R13 — Rehearse the cut against the exact certified workspace.** Run
  `scripts/release-manifest.py verify --manifest releases/<approved-application-tag>.json`
  and the cutter without `--execute`. Check local **and remote** tag
  collisions across all ten repos; the current cutter checks local tags.
  **Done:** no tracked-file or HEAD drift, no tag at a conflicting SHA, all
  target repos accounted for, and the dry run names the right certified set.
  Generate the manifest without advancing CI's HEAD before this rehearsal:
  committing it first changes CI's HEAD and creates drift from its own pin.
  Follow `RELEASE.md`'s current order: cut the certified set, then commit its
  manifest record through a documentation PR; do not rewrite the certified
  CI SHA to that later record commit.

- [ ] **R14 — Create and publish the application tags.** After release
  authorization, run the cutter with `--execute` to create local annotated
  tags; review them, then use `--execute --push` separately. **Done:** query
  each remote and verify the tag resolves to that repo's full manifest SHA.
  Record every success/failure; a partial push is not a completed release.
  Do not publish the local baseline tags or overwrite a conflicting tag.

- [ ] **R15 — Publish notes and verify the released set.** Publish the
  versioned manifest, certifying run ID, full-corpus/deployment/UI/device
  evidence and explicit limitations. Preserve reports outside rotating run
  history without committing logs, credentials or generated runtime state.
  Commit the release record via a documentation PR; the pinned CI source
  commit remains the one certified and tagged. Verify a workspace at those
  pins, rebuild through CI and smoke the released application; document
  recovery to the previous pinned set. **Done:** all ten tags verified,
  notes/evidence discoverable, released-set smoke recorded, and G1–G4 marked
  accepted with references rather than only merged-PR numbers.

### Evaluation order and backlog boundary

Decide **R01**, align/enforce **R02–R03**, then work through acceptance
**R04–R10** (device preparation and static assets can proceed independently).
Freeze only after their findings are resolved or explicitly scoped, then
perform **R11 → R12 → R13 → R14 → R15**. The main uncertainty is acceptance
and scope disposition, not compilation: the current ten-repo build is green.

CI#526 (provider trust/ranking), #287 (Qdrant engine snapshots), #256
(two-stage fold, already deprioritised), and #165 (additional containerized
local lane) are proposed post-MVP work unless R01 changes that boundary.
CI#518 and #317 need explicit evaluation because they affect parity/ingest
claims; their open state must not disappear from release notes.

### Decisions needed

- **D1: the application release tag. Decided 2026-09-25: `release-vN.M.Z`.**
  `RELEASE.md` puts the *same* tag on every repo in a release, and
  `cut-release.sh` refuses a tag that already exists at a different commit.
  `localHealthkitBridge` already carries its own `v0.1.0` (`e351651`), so a plain
  `v0.1.0` application tag could not be cut. Application releases therefore get
  their own namespace: `release-vN.M.Z` (candidates `release-vN.M.Z-rcN`).
  Components keep plain semver on their own schedules. `release-manifest.py
  generate` and `cut-release.sh` both refuse any other form. **The approved
  MVP version remains `release-v0.1.0`; R01 evaluates the requested V0.01
  milestone label without silently changing it.**
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
- **D3: which run certifies the release. Decided 2026-10-07: a green
  local-lane run on `main`.** The hosted profile cannot run Ollama,
  OpenClaw, the mirror or the bridge, so a hosted run cannot certify them;
  the local lane provides those surfaces. Full-corpus evidence is separate
  because both profiles default to the regression corpus. The release manifest
  is generated from that run's directory, which already holds
  `release-manifest.json`. The hosted nightly remains G1 regression evidence;
  `e2e-tests.yml` is the per-merge check. R03 strengthens eligibility without
  changing which lane certifies the composed application.

### Known limitations to state in the release notes

- **Hosted checks** do not cover the full corpus, Ollama, OpenClaw, the PIM
  mirror or the HealthKit bridge (`RELEASE.md`). R07, R09 and R11 cover the
  relevant surfaces at the selected release pins.
- **MQTT Yuma** runs against the live broker on every lane (#520) and skips,
  with the reason recorded, when the broker does not answer within 10s. The
  latest candidate `20261008T215059Z` skipped it because
  `yuma.lateraledge.cloud:1883` timed out, so it does not certify MQTT ingest.
- **HealthKit bridge** is proven only on a physical iPhone (#552); with none
  connected the stage records a skip.
- **Visual acceptance gaps** noted in Manager#254 are tracked in R05;
  **deployment not run** and **localAI parity dispositions** are R10 and R06.

---

## Release assets: historical 2026-10-07 checks and fixes

Checked against `origin/main` of every repo on 2026-10-07: Machines `2e907a3f`,
CPP `e40465a`, LSP `7d45555`, Scala `b7e2e77`, Manager `a8c0648`,
localOpenClawStack `e06c029`, CI `f4b8c46`; Node 26.8, ROBOT, pySHACL and QUDT
all present. No check wrote to a checkout. Repeat at the commits being pinned.

| Asset | Initial state 2026-10-07, before fixes | Check |
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
together. **Fixes merged 2026-10-07:** localOpenClawStack#57 (index digest only; all five
agent-corpus gates pass) and Machines#212 (12 domains + corpus re-released;
the only axiom changes are the 37 `elementLevel` values #208 corrected, and a
re-run reports `no axiom changes`). The re-check was **8 of 8** at Machines
`9775da6` and localOpenClawStack `6cda7e7`. R09 repeats the evidence at the
newer release pins; neither stale condition remains open from this incident.

Neither the per-run `agent-corpus-current` stage nor the regression lanes
caught it: the stage checks the 15 regression agents, which did not change.
Only the weekly cycle checks the index digest. Its next configured run is
2026-10-11 at 05:00 UTC (2026-10-10 at 22:00 PDT); R09 need not wait for the
schedule to obtain release-commit evidence.

---

## G1 status, 2026-10-08

The scheduled regression run [37757370600](https://github.com/jateeter/RealityEngine_CI/actions/runs/37757370600)
passed at `980e75cb`. The per-merge e2e run
[37843606612](https://github.com/jateeter/RealityEngine_CI/actions/runs/37843606612)
passed at current CI `2427181`. Local candidate `20261008T215059Z` subsequently
completed at that CI SHA with the ten-repo pins above. This does not imply
the scheduled nightly tested CI#557–#559, which merged after its checkout;
R11 refreshes evidence for the final source set.

### G1 status, 2026-10-07 (historical)

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

The profile already enabled OpenClaw and local AI. Full-corpus loading is
available by explicit opt-in, not the profile default. What was
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
do, so the two lanes are read the same way. After CI#556, run history keeps
the configured newest runs by time and additionally protects the newest
completed live run (`--keep-runs`; see `scripts/CLAUDE.md`).

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
| **`20261008T215059Z`** | 2026-10-08 | **completed** at all ten recorded `origin/main` tips; 17 live stages passed, 3 skipped, 0 failed. Non-provisional, regression corpus, one instance per runtime. Skipped: iPhone, Yuma, opt-in arbiter sweep. Deployment suite not run. See current candidate inventory and R04–R15 |
| `pr544-1639` | 2026-10-05 | **every stage passed**, including OpenClaw on all three runtimes, `local-ai`, `localai-machines`, `pim-mirror` and `healthkit-bridge`. Built CI from PR #544, not `main`, so it cannot certify. MQTT Yuma skipped; arbiter conformance not run |
| **`main-1007`** (run directory deleted 2026-10-08; this row is the record) | 2026-10-07 | **no failures, on `main` of all 10 repos.** 19 passed, including OpenClaw on all three runtimes, `local-ai`, `localai-machines`, `pim-mirror` and arbiter conformance. Skipped: `healthkit-bridge` (no iPhone connected), MQTT Yuma (broker timeout), `arbiter-sweep` (opt-in). Run with `RE_FREE_PORTS=true`: macOS AirPlay holds 5000 and CI's `.env` no longer carries `SCALA_PE_BASE=5100`. Manifest non-provisional |
| `main-1006` | 2026-10-06 | failed **only `healthkit-bridge`**: the simulator leg saw 0 sensors inside its fixed 30s wait while they landed about a second later. #552 replaces it with the physical-iPhone leg. MQTT Yuma and `arbiter-sweep` skipped |

The 2026-09-24 OpenClaw failure on scala-1 is gone: Scala#153 closed
2026-10-01, and #507 now names every OpenClaw failure stage, so a failure
can no longer report an empty `failureStage`. Final acceptance is R11.

### G1.6 · Bridge leg — done, now on the physical iPhone

Stage `healthkit-bridge` runs `localHealthkitBridge/scripts/e2e_device.sh`: the
real HealthKitBridge app, built, installed and launched on a connected iPhone,
against a live PE from the instance registry, on the local lane only. Owner
decision 2026-10-06: never the simulator. With no iPhone connected, or no
`DEVELOPMENT_TEAM` (environment or `.env`) to sign with, the stage records a
skip with that reason rather than falling back. The simulator leg it replaced
raced a cold-booted simulator with a fixed 30s wait (main-1006: "saw 0" while
the sensors landed a second later).

The history below describes the simulator leg as it was wired in.

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

## G2 · Version pinning — tooling done; current untagged candidate

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
green run yields a candidate manifest with no separate step to remember.
Release eligibility still depends on required stage coverage (R03).

The older local runs emitted 10-repo manifests, and both were provisional
(`main-1006` failed; `pr544-1639` built a CI commit that was not
`origin/main`). The refusal worked as designed. The current
`20261008T215059Z` candidate is non-provisional and covers all ten repos.

**`releases/v0.1.0-rc1.json` is a historical pin, not a release candidate.**
It was generated from run 31297685782 on 2026-08-09, covers 8 repos, and
predates G4, so it omits both PIM and the HealthKit bridge, which G4 put in
scope. R12 supersedes it with the approved versioned final-run manifest.

---

## G3 · Release documentation — core implemented; R02–R03 refresh open

[`RELEASE.md`](../RELEASE.md) defines a release as *a set of commits across the
application's repos certified together by one regression run* — there is no
build artifact, because the application is composed from source at run time. It
covers cutting, certifying, verifying, tag conventions and rollback, and ends
in a checklist.

`scripts/cut-release.sh` makes the process executable rather than prose:
dry-run by default, refuses a provisional manifest, refuses a drifted
workspace, refuses a tag that already exists at a different commit, and treats
pushing tags as a separate opt-in from creating them.

Scheduled regression evidence runs on GitHub Actions nightly at `17 9 * * *`
UTC plus manual dispatch. D3 makes the **local lane** the application
certifier; R02 aligns the remaining historical inventory/coverage prose.

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
enforces the rule by test rather than by agreement. It is covered by R03/R07,
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
| Local lane green at recorded `origin/main` tips | R11 | **Current candidate** `20261008T215059Z` (2026-10-08), iPhone leg skipped; final release acceptance remains open |
| Which run certifies the release | D3 | **Decided 2026-10-07**: a green local-lane run on `main` |
| OWL baselines and agent index trailed Machines#208 | Machines#212, localOpenClawStack#57 | **Merged 2026-10-07**; both pass at `main-1007`'s commits |
| HealthKit stage ran the simulator | CI#552 | **Merged 2026-10-07**: the stage runs the physical iPhone, or skips |
| Retention deleted `main-1007` after a build-only run | CI#556 | **Merged 2026-10-08**, `d32df39`: time ordering plus protection of the newest completed live run. Included in the current candidate; deleted historical evidence is not restored |
| CES tooltip arcs invisible under Light | Manager#253 / PR#254 | **Closed/merged 2026-10-08**, `8ae977e`: theme paints and per-graph arrowhead IDs. Included in Manager candidate `a7d4545`; wider visual acceptance is R05 |
| C++ SSE/WebSocket timeouts | CPP#167 | **Merged**, `7feb92f`: sessions no longer inherit short HTTP deadlines. Included in CPP candidate `ea6545f`; release soak is R04 |
| Native Grafana data/config and slow/high-cardinality engine metrics | CI#557, CPP#168, LSP#161, Scala#184/#185 | **Merged/closed 2026-10-08**; candidate startup measured RE metric bodies around 29 KB. Under-load observability acceptance remains R04 |
| Native PE MQTT metrics missing | CI#558, CPP#170, LSP#163, Scala#188 | **Merged** and included in candidate pins; deterministic ingest acceptance is separate (R08) |
| Free-port instance registry resolution | CI#559, Manager#255 | **Merged**, CI `2427181`, Manager `a7d4545`; deployment acceptance remains R10 |

### Open now

| Item | Where | Effect on release |
|---|---|---|
| V0.01 label versus existing approved version | R01 | Record the exact three-part application tag before generating it |
| Candidate exists, but final release acceptance/pin is not complete | R11–R15 | Current candidate includes recent fixes; resolve the listed acceptance gaps before the final freeze/cut |
| Physical-iPhone leg skipped | R07 | `20261008T215059Z` had no iPhone; obtain device proof or record an explicit scope limitation |
| Required coverage not enforced, and tag metadata always says hosted | R03 | A mirror skip can still reach the cutter; coverage/status and publication reporting must be reliable |
| Full visual matrix and six-instance soak not evidenced by the latest run | R04–R05 | Merged fixes are not full deployed acceptance |
| localAI parity follow-ups | CI#518 / R06 | Resolve/dispose engine-initiated LLM input, health convergence and minted identity questions |
| Yuma broker timeout; dedicated deterministic MQTT stage open | CI#317 / R08 | Separate external availability from runtime ingest/parity proof |
| Asset/full-corpus proof predates the current Machines pin | R09 | Repeat at the selected digest; distinguish JSON artifact and corpus-machine counts |
| Deployment suite not wired into regression certification | R10 | Run and attach exact-pin acceptance rather than implying the local lane ran it |
| Mirror PE scope push covered only by PIM unit tests; bridge mirror previously not wired into `App/` | localHealthkitBridge#45 / R07 | Evaluate current shipping app before claiming automatic device-to-POD flow |

## How to update this file

Change gate status in the same commit that changes the underlying state, and
name the run or PR that proves it. A gate marked green without a reference is
the same failure mode as a stage that passes without checking anything.
