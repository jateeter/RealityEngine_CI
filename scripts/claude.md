# RealityEngine_CI Scripts Guidance

This directory contains operational helpers for startup, testing, OpenAPI, and visualizer workflows.

- Keep script defaults aligned with `startUniverse.sh` and the root application map.
- Prefer explicit `RE_REGISTRY_URL`, `RE_BASE_URL`, `PE_BASE_URL`, `VIZ_BASE_URL`, and `VIZ_FRONTEND_URL`.
- Preserve compatibility with native multi-engine runs.
- Use `bash-language-server` for shell changes.

## Quorum is 3-of-3

Every stage in this directory that compares runtimes is bound by
`docs/QUORUM_CONTRACT.md`. The short form:

- **All three native runtimes must agree, or it is a disagreement.** No
  majority, no reference member, no designated baseline. A 2-1 split is not a
  result with an outlier; it is a disagreement with three parties.
- **A runtime that does not answer is not agreement.** `regression-universal-
  vectors.py` reports the composition up front (`quorum_composition`) so a
  two-runtime run is never read as parity.
- **Unanimous refusal is a finding**, and says nobody implements the shape.
- **A disagreement carries every party's emission**, not one measured against
  another, and states the rule it was held to on the failure line.

If you are adding a stage and reach for "compare everything against
`instance_order[0]`", that is the defect in #138 and the reason this rule is
written down.

## The CES contract, and why it has no oracle

`regression-ces-contracts.py` derives `config/ces-contracts.json` from **3-of-3
agreement** across the cpp, lsp and scala runtimes. It replaces
`cesgen-contracts.mjs`, which replayed the corpus through one nominated engine.

That difference is the point. A contract recorded by replaying through one
engine makes that engine **unfalsifiable**: regenerating makes it pass by
construction, the gate can never find a defect *in* it, and to regenerate you
must already trust the thing the gate exists to check. Its nominated engine was
the deprecated TypeScript prototype, which is out of the focus set; the oracle
is not being rebuilt, it is being removed (#327, direction (2)).

Four verdicts, and only the first becomes a contract:

| verdict | means |
|---|---|
| `agreed` | all three produced the same stream — **this is the contract** |
| `disagreement` | they differ; every cluster's stream is carried, none is the reference |
| `no-runtime-emits` | all three ran and emitted nothing — nobody implements this shape |
| `unmeasurable` | a runtime could not be driven; no evidence either way |

`unmeasurable` exists so a 500 never reads as silence, and `no-runtime-emits`
so silence never reads as a contract with an empty stream. All four are
enumerated in the artifact, never reduced to counts.

Recording is **refused** without a formed quorum or after a failed reset. The
comparison stages can report honestly against a partial lane; this one writes a
file that is consumed later *as* the contract, and a caveat inside a file is
read by whoever opens the file.

This is not an oracle in the strong sense — three runtimes can still be wrong
the same way. Deriving the expected stream from the corpus plus the declared
fold rule would be that, and it is option (3) on #327, not this.

## Parity stages

- `regression-trajectory-parity.py`: ISRE/OSRE trajectory comparison across the
  registered runtimes for one seed sequence against whatever corpus is loaded.
- `regression-universal-vectors.py`: single-step response contract checks. Not
  the parity gate (see the comment above `run_trajectory_parity` in
  `regression-test.sh`). It records **both halves of every observation** — the
  response payloads and, alongside each one, the source set that runtime was
  holding at the moment of the push (`<event>-<instance>-sources.json`, #174).
  The comparison census is keyed on machine **name** and drops ids, `lastValue`
  and `lastUpdated`, so only genuine stimulus differences register.

  A parity mismatch therefore states whether the runtimes were given the same
  thing, on the failure line itself:

  ```
  event-1 parity mismatch: cpp-1+scala-1 | lsp-1 [stimulus equal — same sources on every runtime]
  event-1 parity mismatch: cpp-1+scala-1 | lsp-1 [stimulus DIFFERS — source counts {...}; may not be an engine defect]
  event-1 parity mismatch: cpp-1+scala-1 | lsp-1 [stimulus unknown — source set unreadable on lsp-1]
  ```

  A source set that could not be read is recorded as an error and never as an
  empty set, and it suppresses the equality verdict rather than manufacturing an
  inequality out of a failed GET. Recording stimulus is diagnosis
  infrastructure: it adds no failure of its own and never changes the exit code.
- `test-corpus-parity-loop.sh` + `regression-corpus-parity-loop.py`: incremental
  corpus parity. Boots one universe holding a single machine, then adds one
  corpus machine per iteration over the RE/PE APIs and re-runs the trajectory
  comparison, so the first machine whose presence splits the runtimes is named.
  The loop driver reuses `regression-trajectory-parity.py` as a module — keep
  one definition of what parity means rather than restating the comparison.

  The stimulus is the corpus's own. Loading a machine interns its
  `inputSequences` as a test source over its region, so iteration n has machines
  1..n interned and activating all of them applies the merged set: one push
  advances every machine's sequence a step at once. There is no synthetic seed.

  Each iteration records wall-clock per phase under `timings` and prints it
  beneath the verdict line, because a 1328-iteration sweep is long enough that
  "it is slow" names nothing. `perStepPerRuntime` is the figure that stays
  comparable when the step count or instance count changes between runs.
  Measured at 1328 machines:

  ```
  [1/3] PASS AGX001 — 495.57s total: reset=4.55 ingestMachine=1.08
        bootstrapSources=16.89 activateSources=188.95 stepCycle=281.27
        trajectoryCompare=2.62 [79 steps, 1.1868s/step/runtime]
  [2/3] PASS AGX002 — 286.08s: activateSources=2.62 stepCycle=274.82
  ```

  `stepCycle` is ~96% in steady state. `activateSources` is large only on the
  first iteration — 1342 sequential PATCHes, and only lsp needs them, since its
  reset is the one that deactivates (#163). Inside a step the engine is ~95 ms
  of the ~1.1 s, so the remainder is PE-side assembly over the active sources
  and wants its own measurement; of the engine's share, 87% is OSRE
  construction (#256).

- `regression-reset-contract.py`: the acceptance stage for
  `RealityEngine_CI#163` and `#166`. Registers the corpus-test integration
  (`POST /api/sources/bootstrap-from-machines`), then reads `GET /api/sources`
  **as the first call after `POST /api/reset`** on each runtime and compares the
  declared sets. Ordering is the whole stage: cpp materialises its source set on
  the first read, so anything between the reset and that read repairs the defect
  before it can be seen. Reuses `regression-corpus-parity-loop.py` as a module,
  which in turn carries `regression-trajectory-parity.py` — one definition of
  parity, one definition of how a machine is loaded.

  **The contract landed, and this is now a wired gate.** It asserts the settled
  contract from #163 (registration declares; reset is membership-neutral and
  *validates* activity rather than assigning it). That used to fail on every
  runtime, which is why it was kept out of `regression-test.sh` — a harness
  stage that always fails is a harness stage everyone learns to ignore. It
  passes as of 2026-09-11 on cpp-1 + lsp-1 + scala-1 in 21s and runs beside the
  other conformance gates.

  One property it records but does not assert: activity *at registration*
  splits 2-1 (cpp and scala declare 1336 of 1351 active, lsp declares 0), while
  all three agree at 1336 after the reset. `compare_declared` compares
  membership only. Whether point 2a governs `test` sources is ambiguous in the
  settled text; see #358 rather than guessing.

  What it asserts about `active`, since this is the part that moved twice while
  the issue settled and is easy to re-break:

  | kind | validates active iff |
  |---|---|
  | sensor | it holds a value inside its TTL |
  | test | its interned sequence is **non-empty** — not unconditional `true` |
  | simulated | always |

  Reset recomputes from those rules *alone*. It never reads the prior `active`
  flag, so an operator pause is run state and does not survive a reset — the
  stage pauses one test source and arms another before resetting, and both must
  come back active. Sitting under all of it: **ingress is the only way an
  integration source becomes active**, so a source that never received a value
  reports inactive at every observation point, and the stage checks that at
  registration, before the reset and after it. One clock read per validation
  pass, with `--clock-margin-ms` skipping sensors too near their TTL boundary
  to call either way.

  The TypeScript PE in `RealityEngine_Manager` is the fourth implementation of
  this surface and is not in the runtime registry; pass it with
  `--extra-runtime ts-1=<re_url>,<pe_url>`.

## Push response shape

`regression-pe-step-contract.py` probes the push response at three levels, not
one — `response` (the top level, where `dispatch` lives), `step`, and
`step.mergeBatch[]` (element keys, unioned across elements). It read
`set(step.keys())` and stopped, so divergence above or below that level was
invisible to the stage whose job is catching it (#231), which is how #208
regressed after being closed.

Two properties, kept separate because they have different causes:

- **Conformance** — a runtime emits the declared key set. Only `step` has a
  declared set today (`COMPACT_KEYS` / `FULL_KEYS`, from SURFACE_SPEC.md).
- **Uniformity** — the runtimes emit the *same* key set as each other. Checkable
  at every probe point without first settling what the declared set ought to be,
  which is why it catches `dispatch` and `valuesPacked` now.

A runtime whose own `mergeBatch` elements disagree with each other is reported
separately again — that is a local defect, not a cross-runtime one.

`BOUNDARY_FILTERED` names the keys SURFACE_SPEC designates as **internal
augmentation** — `valuesPacked` on merge entries, C++'s `dispatch`, Scala's
top-level `id`. These are removed before the comparison, not reported after it,
and logged so the filtering is auditable rather than silent.

They are **not** pending defects. Per SURFACE_SPEC.md, "The observable
boundary", a runtime may carry more on its internal hop, and when that reaches
an observable route the correct handling is to filter it there rather than
require every other runtime to implement it. An earlier revision of this gate
registered them as divergences awaiting a fix — the exact reading that nearly
had base64 bit-packing implemented in a third runtime, byte-for-byte across
three languages, to satisfy a field no consumer reads (#208).

`scripts/lib/parity_identity.py` already applies this rule via `shape_only_keys`;
this is the same rule one layer down, so the two cannot disagree about what a
key set means. Adding a key here is a contract decision that belongs in
SURFACE_SPEC's "Already-settled instances" first. Anything not listed still
fails the stage.

A key present as `null` is not an observation and is dropped before comparison:
C++ and Scala carry `error: null` on a success response where LSP omits the key,
and all three are reporting the same absence of an error.

## Reset

`POST {pe}/api/reset` is **layer-local**: it resets the Perception Engine and
does not clear the RE's CES activation, its ISRE/OSRE histories or its step
counter. A defined starting point costs two calls and the obligation is the
caller's (SURFACE_SPEC.md, "Reset is layer-local", #211).

`scripts/lib/reset_contract.py` is the one implementation. Call
`reset_pair(post, re_url, pe_url, label)` or `reset_instances(post, instances)`
rather than restating the pair — it was restated in three stages and omitted in
two, which is how the asymmetry survived:

| stage | before | now |
|---|---|---|
| `regression-corpus-parity-loop.py` | both halves | delegates |
| `regression-universal-vectors.py` | RE only | both halves |
| `regression-trajectory-parity.py` | **no reset at all** | both halves |
| `regression-pe-step-contract.py` | RE only | both halves |
| `regression-arbiter.py` | RE only | both halves |
| `regression-reset-contract.py` | PE only, by design | unchanged — that *is* the contract it tests |

Reset **before** arming, never after: reset validates activity rather than
assigning it (#163), so arming first and resetting second discards the arming.

Both parity stages take `--no-reset` for a caller deliberately measuring
accumulated state.

- `corpus-parity-checkpoint.py`: reconstruct the corpus resident at iteration N
  of a completed loop run, from its `corpus-parity-loop.jsonl`.

  `--resume` reuses a *running* universe, which is no help once the universe is
  gone — and the interesting failures appear hundreds of iterations in. #167
  halted at iteration 862 after 6h27m; replaying that incrementally is ~6.5
  hours per attempt. The investigation instead rebuilt the resident manifest by
  hand and boot-loaded it, which ran in minutes. This is that, automated:

  ```bash
  scripts/corpus-parity-checkpoint.py summary  --results /tmp/re-corpus-parity/loop-*/corpus-parity-loop.jsonl
  scripts/corpus-parity-checkpoint.py command  --results ... --before 862 --out repro.txt
  ```

  **It reconstructs the corpus, not engine state.** A boot-loaded universe at N
  machines is not the same as one that reached N incrementally, and #167 turns
  on exactly that difference — the same machine set reproduced cleanly when
  boot-loaded, which is why "accumulated state surviving reset" is its leading
  hypothesis. A clean result means "not a function of corpus content", never
  "not reproducible".

  Machines from `skipped` iterations are never resident (they were not loaded),
  and an `isolated`-mode run is refused without `--force` because its corpus
  never existed all at once.

Notes that bite when changing these:

- What a comparison may compare is contract, not local convention:
  `SURFACE_SPEC.md`, "The OSRE value is the equality indicator across runtimes".
  In short — compare **values**, match by corpus `name`, never compare identity,
  and treat order as evidence only for the two fields that declare one
  (`activeRegions`, `mergeBatch`). Everything else compares as a multiset.
  `scripts/lib/parity_identity.py` applies the identity half so it is stated
  once rather than per stage.
- Per-iteration `POST /api/engine/reset` is what makes RE histories comparable:
  it clears ISRE/OSRE *and* zeroes the step counter.
- The corpus needs a perceptual space of 16944, well above the 7680 every engine
  defaults to. `test-corpus-parity-loop.sh` computes the requirement and exports
  `VECTOR_DIMENSION`; machines mapping outside the space are reported as a
  capacity class, never as a parity verdict.
- Sources must be equalised before anything is compared. An active source one PE
  has and another does not is stimulus, and the trajectory comparison will
  faithfully report the difference as engine divergence.

## Engine defects these stages are currently blocked by

Measured 2026-08-19 on cpp-1/lsp-1/scala-1, one machine with the interned
sequence `[[1,0,0,0],[0,1,0,0],[1,0,0,0]]`, pushes with no intervening reads:
scala walks idx 0→1→2→0 correctly, **cpp stays on idx 0 forever**, and **lsp
contributes nothing** because its reset discarded the source. Until the first
two are fixed, a corpus sweep rediscovers this on every iteration and no
machine-specific parity result can be trusted.

- `POST /api/reset` means three different things: cpp keeps its sources, lsp
  discards them, scala reactivates every one of them.
- cpp answers `PATCH /api/sources/:id {"active":true}` with 200 and the new
  value echoed back, then reports the old one on the next GET. Start the PEs
  with `PE_SOURCE_ACTIVATE_ON_LOAD=true` instead of activating over the API.
- `GET /api/engine/stats` is listed as uniform in `SURFACE_SPEC.md` but returns
  different payloads per runtime; use `GET /api/config` for `vectorDimension`.

`regression-trajectory-parity.py` shares the source-equalisation exposure — it
seeds one source without checking the others match.

