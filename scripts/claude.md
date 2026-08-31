# RealityEngine_CI Scripts Guidance

This directory contains operational helpers for startup, testing, OpenAPI, and visualizer workflows.

- Keep script defaults aligned with `startUniverse.sh` and the root application map.
- Prefer explicit `RE_REGISTRY_URL`, `RE_BASE_URL`, `PE_BASE_URL`, `VIZ_BASE_URL`, and `VIZ_FRONTEND_URL`.
- Preserve compatibility with native multi-engine runs.
- Use `bash-language-server` for shell changes.

## Parity stages

- `regression-trajectory-parity.py`: ISRE/OSRE trajectory comparison across the
  registered runtimes for one seed sequence against whatever corpus is loaded.
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

- `regression-reset-contract.py`: the acceptance stage for
  `RealityEngine_CI#163` and `#166`. Registers the corpus-test integration
  (`POST /api/sources/bootstrap-from-machines`), then reads `GET /api/sources`
  **as the first call after `POST /api/reset`** on each runtime and compares the
  declared sets. Ordering is the whole stage: cpp materialises its source set on
  the first read, so anything between the reset and that read repairs the defect
  before it can be seen. Reuses `regression-corpus-parity-loop.py` as a module,
  which in turn carries `regression-trajectory-parity.py` — one definition of
  parity, one definition of how a machine is loaded.

  **It fails against today's engines, by design.** It asserts the settled
  contract from #163 (registration declares; reset is membership-neutral and
  *validates* activity rather than assigning it), which no runtime implements
  yet. It is deliberately not wired into `regression-test.sh`: a harness stage
  that always fails is a harness stage everyone learns to ignore. Wire it in
  when the contract lands.

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

Notes that bite when changing these:

- Machines are matched by corpus `name`. Ids are minted per runtime and any
  check that reaches for one reports divergence unconditionally.
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

