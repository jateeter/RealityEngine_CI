# RealityEngine_CI Scripts Guidance

This directory contains operational helpers for startup, testing, OpenAPI, and visualizer workflows.

- Keep script defaults aligned with `startUniverse.sh` and the root application map.
- Prefer explicit `RE_REGISTRY_URL`, `RE_BASE_URL`, `PE_BASE_URL`, `VIZ_BASE_URL`, and `VIZ_FRONTEND_URL`.
- Preserve compatibility with native multi-engine runs.
- Use `bash-language-server` for shell changes.

## Parity stages

- `regression-trajectory-parity.py`: ISRE/OREV trajectory comparison across the
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

Notes that bite when changing these:

- Machines are matched by corpus `name`. Ids are minted per runtime and any
  check that reaches for one reports divergence unconditionally.
- Per-iteration `POST /api/engine/reset` is what makes RE histories comparable:
  it clears ISRE/OREV *and* zeroes the step counter.
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

