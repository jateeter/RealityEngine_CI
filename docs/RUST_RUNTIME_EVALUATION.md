# RealityEngine_Rust: evaluation against the memorialized specifications

Evaluated 2026-10-24 at `RealityEngine_Rust@aab9085` (the merge of the first agent-authored PR),
against `RealityEngine_CI@1f676ce`. Nothing here was changed in `RealityEngine_Rust`; every
number below was measured, and the commands that produced it are in "Reproducing".

Tracking: the repair plan and index of every finding is `jateeter/RealityEngine_Rust#2` (issues #3 to
#17, in three post-RC3 milestones); the comparator document defect is RealityEngine_CI#606, the
`/api/health` disagreement #610, the application map #611, and the quorum role and conformance lane
#607.

## Verdict

**Not yet a conforming runtime, and not ready to be a voting member of the quorum.** It is a
promising start: a working Reality Engine core with the right architecture and, once three
specific defects are accounted for, behaviour that matches the reference engines exactly on every
input sequence tried (55 of 55). What is missing is almost everything around the core:

| measure | result |
|---|---|
| RE surface implemented | **14 of 78** routes (18%) |
| PE surface implemented | **0 of 45** route rows; there is no PE |
| Behaviour on the routes that exist | 0 of 55 input sequences as shipped; 55 of 55 with three fixes (below) |
| Builds, unit tests | yes; 8 of 8 pass (they use the retired key names, so they cannot see the defect) |
| Instance identity (#296), metrics, config pathway, step completion, arbitration retention | none |
| Repo conventions (`CLAUDE.md`, CI workflow, `.nvmrc`, standing-rules table) | none |

The README is candid about the scope ("the core RE surface rather than the complete RE/PE
contract"); this document measures how far that core is from the contract.

## How it was measured

- **Route coverage:** every method/path row of the RE section of `SURFACE_SPEC.md` (78 rows)
  against the routes the Rust router registers (14).
- **Differential black-box test:** the Rust RE and the live C++ reference RE (cpp-1) were loaded with
  the same 23 corpus machines (the regression corpus) at the same event dimension (16960). For each
  machine's declared `inputSequences`, both engines were reset and driven event by event through
  `POST /api/engine/process` as Universal Reality Events, and the outputs attributable to that
  machine (matched by provenance event ids) were compared step by step. 55 input sequences.
- **Harness stages:** the unmodified `regression-machine-set-parity.py` and
  `regression-engine-config-parity.py` were run against a registry with `rust-1` added.

Limits: one reference engine (cpp-1) rather than all three; 23 of 1327 machines; 55 input
sequences; the RE surface only. The three reference engines agree with each other on this corpus
(that is what the regression lane certifies), so using one is not a majority judgement, but it is
narrower than the 3-of-3 rule would ask of a real gate.

## Compliance by specification

### Machine ingestion and the Reality Event key names (SURFACE_SPEC, "Reality Event key names")

**Fails, and it is the finding that matters most.** The loader reads `sequence.vectors`,
`event.outputVectors` and `event.nextVectorIds`. Those are the **pre-migration** spellings; the
spec records that only the canonical `events`, `outputEvents` and `nextEventIds` are accepted, and
the machine schema now rejects the old ones. Every canonical corpus machine therefore loads with
**zero events** (`totalEvents: 0`) and can never fire. Nothing errors: the server starts, reports
23 machines, and answers every request with a well-formed empty result.

This is the failure the spec's own migration section describes: "a reader looking for a spelling
that had moved returned an empty list and reported success… found by comparing counts, never by a
test going red." Rust's tests pass because they build machines with the old names.

Response keys have the same problem: `POST /api/machines/:id/process` returns `inputVector`
(canonical: `inputEvent`), and `GET /api/config` returns `dimension` / `threshold` where the spec
reads `eventDimension` / `matchThreshold` (CI documents that key as the one to read).

### Machine semantics (MACHINE_CONCEPT, and what the engines actually do)

**Fails, and exposes a defect in the specification, not only in Rust.** Rust implements the
comparator table in `MACHINE_CONCEPT.md` literally:

| comparator | `MACHINE_CONCEPT.md` says | C++, LSP and Scala do (`reality.cpp` `RealityEvent::match`) |
|---|---|---|
| `gte` (default) | `input >= value` | binarize both at `threshold` (default 0.5) and require agreement: `(input >= t) == (value >= t)` |
| `threshold` | `input >= threshold` | `abs(value - input) <= threshold` (default 0.1) |
| `pattern` | `abs(value - input) <= threshold` | `1 - abs(value - input) >= threshold` (default 0.5) |
| `equals` | `input == value` | same |

The engines agree with one another and disagree with the document; neither the schema nor
`SURFACE_SPEC.md` defines the comparators, so the document is the only written statement and it is
wrong. Rust followed the document. This is tracked as RealityEngine_CI#606.

### `POST /api/engine/process` (SURFACE_SPEC, "map across machines, in parallel")

Partially conforms. Right: the `{result:{inputEvent, outputs, timestamp}}` envelope, universal-event
decomposition by `perceptualMapping.input` (length equal to the dimension), machine-level iteration.
Wrong: each entry of `outputs[]` is the whole per-machine result (`{machineId, machineOutput:{…},
sequenceResults, …}`); the spec says `outputs = [r.machineOutput for r in results if r.machineOutput]`,
i.e. the arbitrated output itself.

### Differential results

| configuration | identical input sequences |
|---|---|
| as shipped | 6 of 55 (all six: both engines fire nothing) |
| + legacy key names fed to Rust, output unwrapped | 39 of 55 (33 with real outputs) |
| + comparator changed to the engines' semantics (scratch copy) | **55 of 55** (49 with real outputs) |

The sixteen that remained after the key names were accommodated were all the comparator: eleven
where Rust fired nothing (`rag_corrective_cycle`, `session_agent_context`, `session_rag_context`,
`OpenClawCompletionE2E`: non-binary inputs such as 0.95 and 0.5 against explicit thresholds) and
five where it fired differently. So the core (initial and deferred successor activation,
arbitration, output merge, provenance) is right; what separates it from the reference is three
fixable things: key names, comparator semantics, and the shape of `outputs[]`.

### Other surface

| area | result |
|---|---|
| Error envelope `{error}` with 400/404 | conforms |
| Health `{status, timestamp, version}` | conforms to the spec, and differs from **all three** engines, which return `{status}` (measured on cpp-1, lsp-1, scala-1): the spec and the engines disagree, tracked in RealityEngine_CI#610 |
| `GET /api/machines/json/list` | fails: aliased to the `/api/machines` list; the spec requires `relFile`, `filename`, `semanticsHash`, `semanticsIri`, `version` (enforced by `machine-json-listing.spec.ts`) |
| Participation states ("silence is not a state") | not emitted: an unimplemented route answers a bare 404 with an empty body. No runtime emits them yet (`QUORUM_CONTRACT.md` lists it as known non-conformance and has the harness read a non-2xx as the proxy), and the wire shape for an unimplemented route is not specified, so this is blocked on a spec decision, not on Rust (jateeter/RealityEngine_Rust#15) |
| `GET /api/engine/config` pathway, `/api/metrics`, `/api/arbitration`, step completion (`/api/engine/steps/:n/pair`), perceptual simulation, sampler, vectors/sequences CRUD, semantic buses, machine graph, whatif, demo | not implemented (64 of the 78 RE rows) |
| Perception Engine (45 route rows), `POST /api/push`, sources, sensors, integrations | not implemented; there is no PE |
| Instance identity (#296: `INSTANCE_UUID`, clock dir, exclusive lock, `X-RE-Instance`) | none |

## Integration into the _CI workflow

### What a fourth runtime touches

The runtime triple `cpp,lsp,scala` is named in about **32 files**: `startUniverse.sh` and
`stopUniverse.sh` (engine specs, spawn, ports), `scripts/regression-test.sh` (repos, worktrees,
build, provenance), `scripts/regression-universal-vectors.py` and the other parity stages (quorum
composition), `scripts/allocate-ports.sh` (port templates), `docker-compose.yml`, the release
bundle (`release/init/reinit.py`, `release/realityengine`, `releases/*.json`), the e2e quorum spec
(`e2e/tests/tree-to-pe-manager-equivalence.spec.ts`), the MCP server, the OpenAPI generators, and
the docs and workflows that list them. Rust's default port, 5801 (RE) with 5800 (PE), already fits
the allocation scheme (Scala 5100, C++ 5300, LSP 5600) and would be a template of its own.

### The quorum question must be decided first

`QUORUM_CONTRACT.md` and `SURFACE_SPEC.md` define quorum as **exactly the three native runtimes**
and say nothing about a fourth. The harness already behaves correctly when handed one it cannot
compare: with `rust-1` in the instance registry, `regression-engine-config-parity.py` reports
"QUORUM NOT FORMED; rust-1 does not implement GET /api/engine/config" and refuses to compare, and
`regression-machine-set-parity.py` fails on the machine-set difference. **A half-implemented Rust in
the main instance registry would turn the regression lane red** (every stage that iterates the
registry), for reasons that are not divergences. Two coherent choices:

1. **Conformance follower (recommended first).** Rust conforms to the behaviour the three agree on
   and is measured against it, but does not vote, exactly as the TypeScript PE does today
   (`QUORUM_CONTRACT` section 1: "conforms to the agreed contract; it is not a fourth vote"). It
   lives in its own lane, not in the main instance registry.
2. **Full member, 4-of-4.** The contract is amended so all four must agree. Only sensible once Rust
   implements the whole RE and PE surface; until then it blocks every stage.

### Recommended path

1. **Fix the three core defects in `RealityEngine_Rust`** (canonical key names; the engines' comparator
   semantics; `outputs[]` as the arbitrated output) and make its own tests use canonical keys. With
   those, the differential above is 55 of 55.
2. **Add a conformance lane in CI** (non-voting): build, start the Rust RE on 5801 beside a universe,
   and run the RE-only stages (`machine-set-parity`, `engine-process-parity`, `export-parity`,
   `reset-contract`, `config-parity`) with Rust as an extra, non-quorum runtime, reporting per-surface
   participation state. The harness accepts an extra runtime by registry entry, as the TypeScript PE
   does with `--extra-runtime`.
3. **Grow the surface in the order the harness consumes it:** `/api/engine/config`, `/api/metrics`,
   `json/list`, step completion, arbitration retention, then the PE (`/api/push`, sources, sensors).
   Emit participation states for everything not yet implemented.
4. **Decide the quorum rule** (follower, or amend to 4-of-4) when the RE and PE surfaces are complete,
   then do the ~32-file sweep: engine spec, ports, provenance, registry, release bundle, docs.
5. **Repo hygiene now:** `CLAUDE.md`/`AGENTS.md` with the standing-rules index, a CI workflow that
   runs `cargo test`, `cargo clippy` and `cargo fmt --check`, and an `.nvmrc`-style pin
   (`rust-toolchain.toml`).

## Noticed, not chased

Recorded rather than pursued, per the engineering contract:

- Only 23 of 1327 machines were loaded. Rust's default `MACHINES_DIR` is the whole corpus; load time,
  memory and the full-corpus machine count were not measured.
- Trajectory behaviour (ISRE/OSRE histories, `GET /api/engine/history` shape and bounds,
  `stats`) was not compared; Rust's `stats` is `{dimension, machineCount, step}` and the spec's
  runtime facts live elsewhere (`/api/runtime/*`, `/api/engine/config`).
- Concurrency: the spec requires machine-level parallelism with atomic collection and join for
  `POST /api/engine/process`. Rust's implementation was not read for it, and its throughput under
  concurrent callers was not tested.
- `VECTOR_DIMENSION` defaults to 7680; the spec says the dimension grows during machine loading to
  fit each declared mapping. Whether Rust grows it was not checked (it was started at the reference's
  16960).
- Only `cpp-1` was used as the reference. The three engines agree on this corpus, but a gate would
  hold Rust to all three.
- Edition 2024 and the dependency set (axum 0.8, tokio) were taken as given; no toolchain pin exists.

## Specification defects found along the way

- **`MACHINE_CONCEPT.md` comparator table is wrong** against all three engines (above).
- **The "integrated application map" is a copy of this repo's `CLAUDE.md`, not a map.** Every
  `CLAUDE.md` says to update `/Users/johnt/workspace/GitHub/CLAUDE.md`. That file was absent when
  this was measured and has since been added, but it is byte-identical to `RealityEngine_CI/CLAUDE.md`:
  headed "RealityEngine_CI Guidance", pointing at itself for "the integrated application map", and
  listing no repositories, roles, ports or ownership (and not `RealityEngine_Rust`). Its relative
  links (`docs/ENGINEERING_CONTRACT.md`) do not resolve from the workspace root, and the standing
  rules would be maintained in two places that drift.
- **`OpenTwin.code-workspace`** in the workspace root points at unrelated `~/Documents/GitHub/OpenTwin`
  paths and lists the same folder twice; it is not the RealityEngine workspace.
- **SURFACE_SPEC and all three engines disagree on `GET /api/health`:** the spec requires
  `{status, timestamp, version}`; C++, LSP and Scala return `{status}`. (Rust follows the spec.) RealityEngine_CI#610.

## Repair plan, after the RC3 milestone

None of this starts before `release-v0.0.1-rc3` is certified, and none of it is part of
`release-v0.0.1` (ReleaseRoadmap A11). Sizes are estimates for one developer. The plan, with an issue
per item, is `jateeter/RealityEngine_Rust#2`.

| phase | scope | exit | rough size |
|---|---|---|---|
| P1 | canonical keys (#3), comparator (#4), `outputs[]` shape (#5), response/config keys (#6), `json/list` (#7), repo hygiene (#8), in-repo differential and load guard (#9) | the 55-sequence differential is identical on the unmodified loader | 1-1.5 weeks |
| P2 | engine config and metrics (#10), step completion and trajectories (#11), arbitration and clock (#12), remaining RE routes (#13), concurrency and full-corpus baseline (#14), participation states (#15, blocked on spec) | every RE-only harness stage runs with `rust-1` as a non-voting member | 5-8 weeks |
| P3 | instance identity (#16), the Perception Engine (#17) | Rust is a full RE/PE pair; the quorum-promotion decision (RealityEngine_CI#607) can be taken | several weeks |

On the CI side, in parallel and independent of Rust: the comparator document (#606, verify first,
then correct), `/api/health` (#610, decide spec or engines), the application map (#611), and the
follower-role decision, harness support and lane (#607).

## Reproducing

```bash
git clone https://github.com/jateeter/RealityEngine_Rust && cd RealityEngine_Rust
cargo test && cargo build --release
# same corpus as the reference lane, same dimension
MACHINES_DIR=<regression corpus dir> VECTOR_DIMENSION=16960 REALITY_ENGINE_PORT=5801 \
  ./target/release/reality-engine
# registry with rust-1 added (re_url only), then the harness stages unmodified:
python3 scripts/regression-machine-set-parity.py --registry registry4.json --out msp.json
python3 scripts/regression-engine-config-parity.py --registry registry4.json --json ecp.json --no-step
```

The differential driver is a short script: reset both engines, then for every `inputSequences`
entry post each event as a length-`dimension` vector with the machine's input slice set, and compare
the outputs whose `provenance` event ids belong to that machine.
