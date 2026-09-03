# RealityEngine Canonical Surface Specification

**Version:** 1.2.0  
**Date:** 2026-08-27  
**Scope:** All production runtimes — CPP, LSP, Scala, and the TypeScript PE

**This file is the single master.** It lives here, in `RealityEngine_CI`, and
nowhere else. Each runtime repository holds a `SURFACE_SPEC.md` that points
back to this one; those pointers are not copies and must never be forked into
copies. `scripts/check-surface-specs.sh` enforces that.

This document is the authoritative HTTP API contract for the RealityEngine platform. Every route listed here must be implemented by every runtime. The Manager frontend is built against this surface and performs no runtime-specific branching.

Runtimes: `CPP` = RealityEngine_CPP · `LSP` = RealityEngine_LSP · `Scala` = RealityEngine_Scala

The **TypeScript Perception Engine** in `RealityEngine_Manager`
(`perception-engine/backend/`) is a fourth implementation of the PE half of
this surface. Earlier revisions scoped the contract to the three native
engines and omitted it, which let it drift unnoticed — it carried the same
`POST /api/reset` defect as the other three and was found only when the
contract was written down (RealityEngine_CI#163, #166). Where this document
says "every runtime", the TypeScript PE is included for PE routes.

Consumers/tooling: `Manager` = RealityEngine_Manager · `CI` = RealityEngine_CI

---

## The observable boundary

**This document specifies the externally observable interface.** Everything
below — every route, every payload shape, every ordering rule — is a statement
about what a runtime presents to something outside itself.

**The PE→RE→PE path is internal to an engine pair.** Each instance's Perception
Engine talks to its own Reality Engine and back. That hop is not the observable
interface; it is how one pair does its work.

Three consequences, and none of them was written down before:

**1. Internal augmentation is permitted, and is not divergence.** A runtime may
carry more on its internal hop than another does — a packed representation, a
debug projection, a cached resolution, a field one implementation finds useful
and another has no need for. Two pairs doing the same work by different
internal means are not in disagreement.

**2. The boundary filters; it does not replicate.** When internal augmentation
reaches the observable interface, the correct handling is to filter it out
there — not to require every other runtime to implement it. Byte equivalence is
a property of the observable interface. Forcing internal parity in order to
achieve it inverts the requirement, and can cost real work: `valuesPacked`
(#208) was very nearly "fixed" by implementing base64 bit-packing in a third
runtime, byte-for-byte across three languages, to satisfy a field **no consumer
reads**.

**3. The scope of "every runtime must emit it" is this document.** The rule
under "Sensor source payload" — *a field only some runtimes emit is a defect in
the payload contract, not a feature of those runtimes* — is true **of the
observable interface**. It is not a claim about internal hops. Read as
universal it turns every internal difference into a defect, which is the
ambiguity that produced #208.

### What is observable

Everything reachable by a consumer that is not the pair itself: the Manager,
the CI regression stages, the MCP surface, an operator with `curl`. In practice
that is every route in this document.

What is **not** observable, and therefore not governed here: the request the PE
makes of its own RE and the response it gets back, except insofar as the PE
then presents that content on a route listed here. A PE that asks its RE for
more than it reports is doing its job.

### Already-settled instances

Two cases were resolved this way before the rule was stated, and both were
discovered rather than declared — which is the cost this section is meant to
end:

- **`valuesPacked`** on `mergeBatch` entries. Emitted by LSP and C++ under
  `compact`, absent on Scala, consumed by nothing.
  `scripts/lib/parity_identity.py` already treats it correctly — reported under
  `shape_only_keys`, never compared — and cites this section for why.
- **`perceptualSpaceIsDebugProjection`**. `step.perceptualSpace` is a debug
  rendering rather than an authoritative surface. A runtime is not obliged to
  make it byte-comparable, and comparing it produced a retracted 13-cell
  "divergence" that was a rendering difference.

`mergeBatch` itself is observable and governed: `docs/FOLD_PLACEMENT.md` §1
enumerates the `MergeOperation` shape, and §5a of that document records that a
runtime carrying an additional *internal* field is not violating that
enumeration.

---

## Reality Engine (RE) Surface

Served by `reality_engine_server` (CPP), `reality-service` (LSP), `Routes` (Scala).  
Default ports: Scala 5001 · CPP 5301 · LSP 5601

### Info & Health

| Method | Path | CPP | LSP | Scala |
|--------|------|-----|-----|-------|
| GET | `/` | ✓ | ✓ | ✓ |
| GET | `/api` | ✓ | ✓ | ✓ |
| GET | `/api/health` | ✓ | ✓ | ✓ |
| GET | `/api/metrics` | ✓ | ✓ | ✓ |

#### CES coverage: `ces_unfired_sequences` and `ces_unfired_vectors`

**A sequence is unfired when it has never emitted output, counted cumulatively
for the life of the process. Engine reset does not clear it.** `ces_unfired_vectors`
is the same predicate over Reality Events rather than sequences.

Reset clears what a *run* accumulates — the step count, the histories, the
perceptual space, per-vector activation. Coverage is a record of what the corpus
has been shown to do, and a reset does not un-show it. This is the one place the
two diverge, and it is the whole substance of the definition.

The counters are written at the transition touch point in the step path, so the
value reflects what actually fired rather than what a separate pass believed
would fire.

Stated here because the same metric name meant three different things
(`RealityEngine_CI#218`). On one corpus at one instant — 372 machines, 1661
sequences — the runtimes reported 33, 1661 and 0:

| runtime | reported | what it computed |
|---|---|---|
| cpp | 33 | never emitted output, cumulative — correct |
| lsp | 1661 | right predicate, but coverage was cleared on every engine reset, so under a reset-per-iteration loop it climbed toward the sequence total |
| scala | 0 | sequences with no currently-active vectors — structurally always zero, since `CriticalEventSequence` guarantees at least one initial Reality Event is always active |

Fixed in `RealityEngine_Scala#76` (read the coverage registry rather than the
active set) and `RealityEngine_LSP#77` (stop replacing the `cov-*` tables in
`reset-reality-state`). C++ never cleared coverage and needed no change.

What makes it a usable signal: the machine test sequences are driven on every
input cycle, so each machine should fire each of its CESs at least once. A
healthy corpus therefore trends toward zero unfired. **A count pinned at exactly
0 or at exactly the sequence total is a broken metric, not a corpus finding** —
that is the shape both defects took, and it is the thing to check first if this
number ever looks too clean.

`UnfiredCoverageSpec` pins the Scala half to behaviour: drive a corpus machine
with its own interned `inputSequences` and the unfired count must strictly
decrease. It was verified to fail against the old predicate.

### Configuration

| Method | Path | CPP | LSP | Scala |
|--------|------|-----|-----|-------|
| GET | `/api/config` | ✓ | ✓ | ✓ |
| PUT | `/api/config/dimension` | ✓ | ✓ | ✓ |
| PUT | `/api/config/threshold` | ✓ | ✓ | ✓ |

### Runtime Introspection

| Method | Path | CPP | LSP | Scala |
|--------|------|-----|-----|-------|
| GET | `/api/runtime/metrics` | ✓ | ✓ | ✓ |
| GET | `/api/runtime/vector-space` | ✓ | ✓ | ✓ |
| GET | `/api/runtime/storage-footprint` | ✓ | ✓ | ✓ |
| GET | `/api/runtime/options` | ✓ | ✓ | ✓ |
| PATCH | `/api/runtime/options` | ✓ | ✓ | ✓ |

### Vectors

| Method | Path | CPP | LSP | Scala |
|--------|------|-----|-----|-------|
| POST | `/api/vectors/search` | ✓ | ✓ | ✓ |
| POST | `/api/vectors` | ✓ | ✓ | ✓ |
| GET | `/api/vectors/:id` | ✓ | ✓ | ✓ |
| DELETE | `/api/vectors/:id` | ✓ | ✓ | ✓ |

### Sequences

| Method | Path | CPP | LSP | Scala |
|--------|------|-----|-----|-------|
| GET | `/api/sequences` | ✓ | ✓ | ✓ |
| POST | `/api/sequences` | ✓ | ✓ | ✓ |
| GET | `/api/sequences/:id` | ✓ | ✓ | ✓ |
| DELETE | `/api/sequences/:id` | ✓ | ✓ | ✓ |
| POST | `/api/sequences/:id/reset` | ✓ | ✓ | ✓ |
| POST | `/api/sequences/:id/vectors` | ✓ | ✓ | ✓ |
| POST | `/api/sequences/persist` | ✓ | ✓ | ✓ |

### Engine

| Method | Path | CPP | LSP | Scala |
|--------|------|-----|-----|-------|
| GET | `/api/engine/stats` | ✓ | ✓ | ✓ |
| GET | `/api/engine/active` | ✓ | ✓ | ✓ |
| GET | `/api/engine/history` | ✓ | ✓ | ✓ |
| GET | `/api/engine/osre-history` | ✓ | ✓ | ✓ |
| GET | `/api/engine/isre-history` | ✓ | ✓ | ✓ |
| POST | `/api/engine/process` | ✓ | ✓ | ✓ |
| POST | `/api/engine/reset` | ✓ | ✓ | ✓ |

#### `GET /api/engine/history` — the `/api/engine/process` audit trail

One record per `POST /api/engine/process` call, newest first, capped at 256:
`{"type": "engine-process", "result": …}`. `?limit=n` returns the n most recent.

This path meant three different things. C++ served the audit trail; LSP pushed
step records onto the same list and served both from it, so the endpoint
returned steps here and audit envelopes there; Scala served the CES transition
history. An observer asking one question of three engines got three kinds of
answer — the observability contract broken on a public surface, not a
behavioural difference (RealityEngine_CI#148).

Step records live at `GET /api/perceptual-simulation/history` and only there.
Scala's CES transition history remains available in-process and is still
counted by `ces_history_size` in `/api/metrics`; it is not a surface.

#### Trajectory histories

The two histories the cross-engine trajectory proof reads. What an engine is
actually presented with at step n is the seed mutated by arbitration feedback
from step n-1:

```
ISRE(1) = ISRESeed(1)
ISRE(n) = mergeBatch( ISRESeed(n), arbiter(OSRE(n-1)) )

ISRE-History = {ISRE(1) … ISRE(n)}
OSRE-History = {OSRE(1) … OSRE(n-1)}
```

**`ISRESeed(n)` is composed, not supplied.** It is the merge of the `n`-th
vector of every active test source, each written into its own machine's input
region — so one push advances every machine's sequence together, and the seed
queue is as long as the longest interned sequence. Those sources come from
machine ingestion (see "Machine ingestion" under Sources & Sensors); the seed
is the corpus's own stimulus.

This is not optional detail. A probe that registers its own source and pushes
values through it is measuring a **synthetic** stimulus: it exercises whatever
region it chose rather than the corpus, and three engines can agree on it while
disagreeing on everything the corpus would have driven. Any parity gate must
compose the seed from the interned test sources, and
`scripts/regression-trajectory-parity.py` is the definition of that comparison.

Every engine given the same corpus must produce the same two histories. That is
the claim the multi-engine deployment rests on, and neither history is
observable from a single-step response — two engines can agree at every step
examined in isolation and still be on different trajectories.

**OSRE(n)** — the output reality event vector: the resolved output-cell writes
committed by the corpus at step n. Observed at the commit, which is the only
instant the corpus's output for the step exists as a single-valued vector.

**ISRE(n)** — the input space reality event vector: the perceptual space as
presented to the corpus at step n. Observed immediately before the machines'
input snapshots are extracted from it.

The merge is not performed by the Reality Engine and is not observed here. The
Perception Engine assembles `ISRE(n)` from its sources — which the previous
step's output regions feed — and delivers it by push; the engine records what
it was presented with. So `ISRE-History` is the sequence of inputs the corpus
actually saw, whatever produced them, which is the only reading under which two
engines agreeing on it means anything.

Both observations are **atomic**: each is captured at its own point inside the
step and the pair is appended in one action, so the recorded entry and the
state the corpus saw cannot differ, and no observer can read a step whose
trajectories are half-written. Nothing needs to reconstruct a history after the
fact.

Arbiter *internals* are deliberately not covered. `mergeBatch` is a private
algorithm expected to change under training; its **effect** is fully captured
as the gap between `ISRESeed(n)` and `ISRE(n)`, without inspecting it.

Entry shape, both endpoints:

| Key | Notes |
|-----|-------|
| `stepNumber` | The step this entry records |
| `length` | Cells in the full input space — the dense width |
| `nonZero` | `[{index, value}]`, **ascending index**. A cell absent from this list is zero. |

Sparse because the dense vector is 16k+ cells of which a handful are ever
non-zero; lossless because `length` and the pairs reconstruct the dense vector
exactly, which is what makes a first-divergent-index comparison possible.

Ordering is **ascending `stepNumber`, oldest first** — the opposite of the step
history, which is newest-first because it is read as "what just happened".
These are read as sequences compared element by element, and the index of the
first disagreement is the answer they exist to give.

`?from=n` selects the first `stepNumber` to include; `?limit=n` caps the entries
returned from there. Both default to the whole history, which is capped at 1024
entries and cleared by `POST /api/reset`.

Regions are not compared. They are an abstraction laid across the input space
Reality Event: it is the vector that must be equivalent, and region
equivalence follows from it.

### Machines

| Method | Path | CPP | LSP | Scala |
|--------|------|-----|-----|-------|
| GET | `/api/machines` | ✓ | ✓ | ✓ |
| POST | `/api/machines` | ✓ | ✓ | ✓ |
| GET | `/api/machines/:id` | ✓ | ✓ | ✓ |
| PUT | `/api/machines/:id` | ✓ | ✓ | ✓ |
| PATCH | `/api/machines/:id` | ✓ | ✓ | ✓ |
| DELETE | `/api/machines/:id` | ✓ | ✓ | ✓ |
| POST | `/api/machines/:id/process` | ✓ | ✓ | ✓ |
| POST | `/api/machines/:id/process-universal` | ✓ | ✓ | ✓ |
| POST | `/api/machines/:id/whatif` | ✓ | ✓ | ✓ |
| POST | `/api/machines/:id/whatif-universal` | ✓ | ✓ | ✓ |
| POST | `/api/machines/process-universal/all` | ✓ | ✓ | ✓ |
| GET | `/api/machines/json/list` | ✓ | ✓ | ✓ |
| GET | `/api/machines/json/:name` | ✓ | ✓ | ✓ |
| POST | `/api/machines/json/import` | ✓ | ✓ | ✓ |
| GET | `/api/machines/:id/export` | ✓ | ✓ | ✓ |
| GET | `/api/machines/:id/checkpoints` | ✓ | ✓ | ✓ |
| POST | `/api/machines/:id/checkpoints` | ✓ | ✓ | ✓ |
| POST | `/api/machines/:machineId/checkpoints/:cpId/restore` | ✓ | ✓ | ✓ |
| DELETE | `/api/machines/:machineId/checkpoints/:cpId` | ✓ | ✓ | ✓ |
| GET | `/api/buses/semantic` | ✓ | ✓ | ✓ |
| GET | `/api/buses/semantic/:id` | ✓ | ✓ | ✓ |

### Machine Graph

| Method | Path | CPP | LSP | Scala |
|--------|------|-----|-----|-------|
| GET | `/api/machine-graph` | ✓ | ✓ | ✓ |

### Perceptual Simulation

| Method | Path | CPP | LSP | Scala |
|--------|------|-----|-----|-------|
| POST | `/api/perceptual-simulation/configure/chunk` | ✓ | ✓ | ✓ |
| POST | `/api/perceptual-simulation/configure/commit` | ✓ | ✓ | ✓ |
| POST | `/api/perceptual-simulation/start` | ✓ | ✓ | ✓ |
| POST | `/api/perceptual-simulation/stop` | ✓ | ✓ | ✓ |
| POST | `/api/perceptual-simulation/step` | ✓ | ✓ | ✓ |
| POST | `/api/perceptual-simulation/reset` | ✓ | ✓ | ✓ |
| GET | `/api/perceptual-simulation/state` | ✓ | ✓ | ✓ |
| GET | `/api/perceptual-simulation/history` | ✓ | ✓ | ✓ |

#### Active regions

`activeRegions` is emitted on every simulation step and **is ordered**. The
canonical order is `offset`, then `length`, then `machineId`, then `type`, all
ascending. Every runtime sorts before serializing; a consumer may rely on it,
and a byte comparison of the field is meaningful.

`machineId` is part of the key so the order is total. `offset`+`length`+`type`
alone is not — two machines may target the same region, which is precisely the
contended case the arbiter exists for, and leaving those two entries in
map-iteration order would reintroduce the defect below on exactly the cells
that matter most.

This is a fixed order rather than a declared-unordered field. Byte equivalence
is the acceptance test for these contracts, so a field that carries no order but
is compared as though it does cannot be checked at all — and that was the state
this replaces. All three runtimes built the list by walking their own machine
collection, each in its own iteration order, and reported the **same fifteen
regions in three different orders** (#197):

```
cpp-1 vs lsp-1:    order differs | set SAME
cpp-1 vs scala-1:  order differs | set SAME
lsp-1 vs scala-1:  order differs | set SAME
```

Because no two runtimes agreed byte-for-byte, the clustering in the
universal-vectors stage never found a majority, and **every** divergence in
that stage reported as "no majority — runtimes split evenly" regardless of what
the engines had actually done. An unactionable verdict on every run, which
masked the real content of #162 for as long as that issue was open.

Implemented in `reality.cpp` (`std::sort` after the machineResults walk),
`PerceptualSpaceRuntime.scala` (`sortBy`), and `reality-service.lisp`
(`sort-active-regions`, replacing an `nreverse` that only undid push order and
carried no meaning).

### Sampler

| Method | Path | CPP | LSP | Scala |
|--------|------|-----|-----|-------|
| POST | `/api/sampler/start` | ✓ | ✓ | ✓ |
| POST | `/api/sampler/stop` | ✓ | ✓ | ✓ |
| POST | `/api/sampler/sample` | ✓ | ✓ | ✓ |
| GET | `/api/sampler/stats` | ✓ | ✓ | ✓ |

### Perception

| Method | Path | CPP | LSP | Scala |
|--------|------|-----|-----|-------|
| POST | `/api/perception/observe` | ✓ | ✓ | ✓ |
| POST | `/api/perception/diagnostic` | ✓ | ✓ | ✓ |
| POST | `/api/perceive` | ✓ | ✓ | ✓ |

### Governance

| Method | Path | CPP | LSP | Scala |
|--------|------|-----|-----|-------|
| GET | `/api/governance/route` | ✓ | ✓ | ✓ |

### Demos

| Method | Path | CPP | LSP | Scala |
|--------|------|-----|-----|-------|
| GET | `/api/demo/multi-step` | ✓ | ✓ | ✓ |
| GET | `/api/demo/data-center` | ✓ | ✓ | ✓ |
| GET | `/api/demo/kleene-star` | ✓ | ✓ | ✓ |

### Streaming

| Protocol | Path | CPP | LSP | Scala |
|----------|------|-----|-----|-------|
| SSE | `/api/engine/stream` | ✓ | ✓ | ✓ |

---

## Perception Engine (PE) Surface

Served by `perception_engine_server` (CPP), `perception-service` (LSP), `PerceptionRoutes` (Scala).  
Default ports: Scala 5000 · CPP 5300 · LSP 5600

### Info & Health

| Method | Path | CPP | LSP | Scala |
|--------|------|-----|-----|-------|
| GET | `/` | ✓ | ✓ | ✓ |
| GET | `/api/health` | ✓ | ✓ | ✓ |
| GET | `/api/state` | ✓ | ✓ | ✓ |

### Push Cycle

| Method | Path | CPP | LSP | Scala |
|--------|------|-----|-----|-------|
| POST | `/api/push` | ✓ | ✓ | ✓ |
| GET | `/api/push/:id` | ✓ | ✓ | ✓ |
| POST | `/api/auto/start` | ✓ | ✓ | ✓ |
| POST | `/api/auto/stop` | ✓ | ✓ | ✓ |

#### `POST /api/push` response shape

The push response is how the Reality Engine's result travels back to the
Perception Engine, and it is a contract, not an implementation detail. Every
runtime emits the same `step` object with the same keys.

This was not previously specified, and all three runtimes diverged — for an
identical computation. LSP omitted `perceptualSpace` under `compact` and emitted an
`inputVector` the others did not, and Scala omitted `eventBus` and
`perceptualSpaceIsDebugProjection` entirely and ignored `compact`. Anything
walking the response saw three different pictures of the same reality, which is
what the cross-runtime parity stage was reporting as engine divergence.

`step` keys, every runtime:

| Key | compact | full | Notes |
|-----|---------|------|-------|
| `stepNumber` | ✓ | ✓ | |
| `timestamp` | ✓ | ✓ | |
| `perceptualSpace` | ✓ | ✓ | **Always present.** The Reality Event after the step — the reason the response exists. |
| `perceptualSpaceIsDebugProjection` | ✓ | ✓ | |
| `activeRegions` | ✓ | ✓ | |
| `mergeBatch` | ✓ | ✓ | |
| `eventBus` | ✓ | ✓ | |
| `machineResults` | — | ✓ | Per-machine detail; omitted when `compact` |

`compact: true` omits exactly `machineResults` — the heavy per-machine payload —
and nothing else. A runtime that ignores `compact` does not satisfy the
contract: `compact` is what makes the response affordable at corpus scale.

`inputVector` is deliberately **not** in the contract. LSP emitted one; the
other two never did. The Perception Engine assembled that vector and sent it,
so echoing it back is redundant, and C++'s `SimulationStep` has no step-level
input vector to echo — only per-machine ones inside `machineResults`.

Verified live by `RealityEngine_CI/scripts/regression-pe-step-contract.py`,
which drives a push against every running PE and compares the emitted key sets
against this table. It runs as the `pe-step-contract` stage of the regression
lane, so the contract is observable rather than aspirational.

### Configuration & Reset

| Method | Path | CPP | LSP | Scala |
|--------|------|-----|-----|-------|
| PATCH | `/api/config` | ✓ | ✓ | ✓ |
| POST | `/api/reset` | ✓ | ✓ | ✓ |

`POST /api/reset` is presence plus a post-state, not presence alone. Per
`RealityEngine_CI#163` points 3 and 4:

- **Run state is cleared.** `globalStep` returns to 0, the persistent vector is
  zeroed, test cursors rewind to step 0, RandomWalk state is re-seeded, and the
  route clears `lastPush`.
- **Membership is untouched.** Reset never manufactures a source and never
  re-derives the set from boot configuration or the corpus. Doing so would drop
  every integration registered dynamically since boot.
- **Activity is validated, not assigned.** Each source's `active` is recomputed
  from the rules for its kind, against the run state just cleared — sensor:
  active iff holding a value inside its TTL; test: active iff its interned
  sequence is non-empty; simulated: active. The prior flag is not consulted, so
  an operator-deactivated source is re-armed if it validates active: a pause is
  run state, and reset clears run state. `lastValue` and `lastUpdated` survive.

#### Reset is layer-local: the PE does not reset the RE

**`POST {pe}/api/reset` resets the Perception Engine and nothing else.** It does
not clear the Reality Engine's Critical Event Sequence state — the per-vector
active/inactive flags activation walks — and it does not clear ISRE/OSRE
histories or the RE step counter. Those persist until `POST {re}/api/engine/reset`.

This is the settled contract, not an accident: every runtime already implements
it (C++ `perception_engine_server.cpp`, LSP `perception-service.lisp`, the Scala
PE, and the TypeScript PE in `RealityEngine_Manager` all reset their own state
only). It is also the choice consistent with the rest of this section — a PE
that reached into the RE would make reset a cross-service side effect, in a
surface whose stated rule is that declaration is never a side effect of a read
and membership moves only on register/deregister. The PE does not own the RE.

The cost of that choice is that **a caller wanting a defined starting point must
reset both halves, and the obligation is the caller's.** Resetting one half
leaves the engine holding whatever earlier traffic armed:

```
POST {re}/api/engine/reset      # CES activation, ISRE/OSRE histories, step counter
POST {pe}/api/reset             # globalStep, persistent vector, test cursors, lastPush
```

Order is not load-bearing while nothing pushes between the two calls, but the
pair is: either alone is a partially-defined state that reads as a runtime
divergence. On 2026-08-29 a PE-only reset produced an apparent 6-event
divergence at step 0 across three runtimes — six of them `isInitial: false`,
which reads as two runtimes wrongly holding non-initial events active at rest.
After a full reset all three agreed exactly at 27 active events with zero
non-initial, which is the contract. The entire divergence was residue
(`RealityEngine_CI#211`).

A harness that resets through one half and then reads the other is comparing
accumulated history rather than a defined starting point, and two runs of the
same suite can differ by what ran before them. `scripts/lib/reset_contract.py`
is the one implementation of the pair; parity stages call it rather than
restating it.

### Sources & Sensors

| Method | Path | CPP | LSP | Scala |
|--------|------|-----|-----|-------|
| GET | `/api/sources` | ✓ | ✓ | ✓ |
| POST | `/api/sources` | ✓ | ✓ | ✓ |
| PATCH | `/api/sources/:id` | ✓ | ✓ | ✓ |
| DELETE | `/api/sources/:id` | ✓ | ✓ | ✓ |
| POST | `/api/sources/bootstrap-from-machines` | ✓ | ✓ | ✓ |
| POST | `/api/sensors/:sensorId` | ✓ | ✓ | ✓ |

Sources are declared by integrations, and declaration is never a side effect of
a read. An integration registers either at boot from configuration or
dynamically at runtime; the event is the same either way, and it declares the
full source set immediately, completely and inactive, so `GET /api/sources`
reflects it before any traffic arrives. Membership changes only on
register/deregister — reads, pushes and resets do not move it.

#### Sensor source payload

A sensor source serializes `sensorId`, `lastValue`, `lastUpdated`, `ttlMs` and,
when set, `origin` — alongside the fields common to every source kind. **It
does not carry derived freshness.** `ageMs` and `stale` are not part of the
shape, and a runtime must not add them.

They were emitted by LSP and by the Manager TypeScript PE, and not by C++ or
Scala, so `GET /api/sources` could not be byte-compared across runtimes at all;
`regression-reset-contract.py` had to skip the comparison and document why
rather than fake a pass (#176).

Removed rather than canonicalized, on two grounds. Nothing consumed them — the
visualizer declared both optional in `types.ts` and read neither. And `active`
already answers the question `stale` was introduced for: since `active` reports
`stored AND validated` at every read, a sensor past its TTL reports inactive
without the caller doing TTL arithmetic. A consumer that wants the arithmetic
anyway has `lastUpdated` and `ttlMs`, both of which stay on the payload.

The general rule this is an instance of: **a field that only one or two
runtimes emit is a defect in the payload contract, not a feature of those
runtimes.** Either every runtime emits it and this document says so, or none
does. Derived values that a caller can compute from fields already present
should be the ones that go.

That rule is scoped to the **observable interface** — see "The observable
boundary" above. It is not a claim about the PE→RE→PE hop, where a runtime may
carry more than another without that being divergence. Read as universal it
makes every internal difference a defect, which is how `valuesPacked` came to
be filed as one (#208).

### Machine ingestion

**Interning a machine's test source is part of ingesting the machine, not an
optional extra, and it happens by default on every runtime.**

When a machine is ingested, the runtime interns its `metadata.inputSequences`
as a **test source over that machine's own input region**. One machine, one test
source, declared inactive like any other source. This is the same path on C++,
LSP and Scala, and it runs unless explicitly suppressed.

That source set is not incidental — **it is the material the ISRE seed queue is
composed from**. See "Trajectory histories" above: `ISRESeed(n)` is the merge of
every active test source's `n`-th vector, each written into its own machine's
region. A runtime holding a corpus but no test sources has nothing to be
presented with, and a parity comparison against it measures a synthetic
stimulus rather than the corpus's own.

`PE_SOURCE_BOOTSTRAP` governs the boot-time intern, mirroring
`startUniverse.sh --pe-source-bootstrap`:

| value | behaviour |
|---|---|
| unset | **intern at boot** — the default |
| `auto`, `on`, `1`, `true`, `yes` | intern at boot |
| `off`, `0`, `false`, `no` | do not intern at boot |

`off` exists for a harness that registers sources itself and does not want the
boot set pre-empting it — `scripts/test-corpus-parity-loop.sh` passes it for
exactly that reason, because it drives its own `bootstrap-from-machines` after
each incremental load. `POST /api/sources/bootstrap-from-machines` is the
dynamic path and is unaffected by the flag in either direction.

Machine-derived test sources are the one source kind that does **not** wait for
an external integration to register: they arrive with the machines. Every other
kind — MQTT, ACP, MCP, HealthKit, localAI — is external and registers on its
own terms, per the paragraph above.

Activity is earned, and only by ingress. A sensor source is active iff it holds
a value inside its TTL: registration declares it inactive whatever flag the
caller asks for, the first value makes it active, and the TTL lapsing —
observed at the next reset — makes it inactive again.

### Signals

| Method | Path | CPP | LSP | Scala |
|--------|------|-----|-----|-------|
| POST | `/api/signals` | ✓ | ✓ | ✓ |

### Machines Proxy

| Method | Path | CPP | LSP | Scala |
|--------|------|-----|-----|-------|
| GET | `/api/machines` | ✓ | ✓ | ✓ |

### Integrations

| Method | Path | CPP | LSP | Scala |
|--------|------|-----|-----|-------|
| GET | `/api/integrations/status` | ✓ | ✓ | ✓ |
| POST | `/api/integrations/completions` | ✓ | ✓ | ✓ |
| GET | `/api/integrations/ollama/status` | ✓ | ✓ | ✓ |
| POST | `/api/integrations/ollama/dispatch` | ✓ | ✓ | ✓ |
| GET | `/api/integrations/openai/status` | ✓ | ✓ | ✓ |
| POST | `/api/integrations/openai/dispatch` | ✓ | ✓ | ✓ |
| GET | `/api/integrations/acp/status` | ✓ | ✓ | ✓ |
| POST | `/api/integrations/acp/dispatch` | ✓ | ✓ | ✓ |
| GET | `/api/integrations/healthkit/status` | ✓ | ✓ | ✓ |
| POST | `/api/integrations/healthkit/ingest` | ✓ | ✓ | ✓ |
| GET | `/api/integrations/carekit/status` | ✓ | ✓ | ✓ |
| POST | `/api/integrations/carekit/ingest` | ✓ | ✓ | ✓ |
| GET | `/api/integrations/localai/status` | ✓ | ✓ | ✓ |
| GET | `/api/integrations/localai/catalog` | ✓ | ✓ | ✓ |
| POST | `/api/integrations/localai/bootstrap` | ✓ | ✓ | ✓ |
| POST | `/api/integrations/localai/invoke` | ✓ | ✓ | ✓ |

### Dispatch & Triggers

| Method | Path | CPP | LSP | Scala |
|--------|------|-----|-----|-------|
| GET | `/api/dispatch/ledger` | ✓ | ✓ | ✓ |
| GET | `/api/dispatch/records/:id` | ✓ | ✓ | ✓ |
| PATCH | `/api/dispatch/records/:id` | ✓ | ✓ | ✓ |
| GET | `/api/triggers/status` | ✓ | ✓ | ✓ |

### MQTT Bridge

| Method | Path | CPP | LSP | Scala |
|--------|------|-----|-----|-------|
| GET | `/api/mqtt/status` | ✓ | ✓ | ✓ |
| GET | `/api/mqtt/mappings` | ✓ | ✓ | ✓ |
| PUT | `/api/mqtt/mappings` | ✓ | ✓ | ✓ |
| POST | `/api/mqtt/enable` | ✓ | ✓ | ✓ |
| POST | `/api/mqtt/disable` | ✓ | ✓ | ✓ |

### Streaming

| Protocol | Path | CPP | LSP | Scala |
|----------|------|-----|-----|-------|
| SSE | `/api/events` | ✓ | ✓ | ✓ |
| WebSocket | `/ws` | ✓ | ✓ | ✓ |

---

## Gap Register

### Resolved gaps (v1.1.0)

| Runtime | Route | Resolution |
|---------|-------|------------|
| LSP RE | 8 routes (vectors/search, vectors, vectors/:id×2, sequences×4) | Promoted from dead `reality-routes` block into active route table |
| Scala RE | `GET /` | Added bare root handler outside `pathPrefix("api")` via outer `concat` |
| Scala PE | `GET /` | Confirmed present at `pathEndOrSingleSlash` outside any prefix |
| All | HealthKit/CareKit status+ingest semantic shape | Unified (see Semantic Contracts section below) |

### Open gaps

None. All routes listed in this spec are implemented by all three runtimes.

---

## Response Shape Conventions

All runtimes must conform to these envelope shapes. Deviations are bugs in the runtime, not workarounds to implement in the Manager.

### Success envelope
```json
{ "success": true, "<resource>": { ... } }
```

### Error envelope
```json
{ "error": "<message>" }
```
HTTP status: 400 for bad input, 404 for not found, 500 for runtime error.

### Health response
```json
{ "status": "healthy", "timestamp": 1748000000000, "version": "x.y.z" }
```

### Streaming events (SSE and WebSocket)

Both SSE (`/api/engine/stream`, `/api/events`) and WebSocket (`/ws`) deliver newline-delimited JSON event objects. Each event has a `type` field:

**RE stream** (`/api/engine/stream`):
- `{ "type": "step-result", "step": { ... } }` — emitted after every `POST /api/perceive`

**PE stream** (`/api/events` and `/ws`):
- `{ "type": "state-update", ... }`
- `{ "type": "push-result", ... }`
- `{ "type": "agent.completion.received", ... }`
- `{ "type": "carekit.ingest", ... }`
- `{ "type": "mqtt-ingest", ... }`
- `{ "type": "dispatch-updated", ... }`

SSE framing: `data: <json>\n\n` with `: keepalive\n\n` every 15 s.  
WebSocket framing: RFC 6455 text frames; ping frames sent every 15 s on idle.

---

## Acceptance Smoke Test

A conformance script must make one request to each route listed in this spec against a running runtime instance and verify:
- HTTP status is not 404 (route exists)
- HTTP status is not 500 (handler is wired)
- Response body is valid JSON

Script location: `scripts/smoke-test.sh` (accepts `--target <url>` for RE and `--pe-target <url>` for PE).

---

## Semantic Contracts

Route parity (a route exists) is necessary but not sufficient. The following contracts specify the exact JSON fields each endpoint must emit and accept. Deviations are bugs in the runtime.

### HealthKit Integration

#### `GET /api/integrations/healthkit/status`

All runtimes must return:

```json
{
  "bridgeId":              "healthkit-ios-bridge",
  "enabled":               true,
  "tokenConfigured":       false,
  "nativeAppRequired":     true,
  "nativeWorkOutsideRepo": true,
  "registryKey":           "healthkit:<typeIdentifier>",
  "statusEndpoint":        "/api/integrations/healthkit/status",
  "ingestEndpoint":        "/api/integrations/healthkit/ingest",
  "contract": {
    "transport":    "https",
    "singleSample": ["type", "value", "sourceName"],
    "batchSamples": ["bridgeId", "samples[]"],
    "auth":         "none"
  }
}
```

`tokenConfigured` is `true` when `HEALTHKIT_BRIDGE_TOKEN` is set; `auth` becomes `"bridgeToken"` in that case.  
Field `enabled` reflects `HEALTHKIT_ENABLED` env (Scala) or `true` always (CPP/LSP — routes are always active).

**Removed fields (no longer emitted):** `tokenRequired`, `configured`, `bridgeEndpoint`.

#### `POST /api/integrations/healthkit/ingest`

**Request — single sample (flat body):**
```json
{ "type": "HKQuantityTypeIdentifierHeartRate", "value": 72.0, "sourceName": "Apple Watch" }
```

**Request — batch:**
```json
{ "bridgeId": "healthkit-ios-bridge", "bridgeToken": "<token>", "samples": [ { "type": "...", "value": 72.0 } ] }
```

**Token auth rules (all runtimes):**
- If `HEALTHKIT_BRIDGE_TOKEN` is unset: ingest is accepted with no auth check (no-token / dev mode).
- If set: body must contain `bridgeToken` (primary) or `token` (secondary alias). Bearer `Authorization` header is **not** accepted.
- Missing / wrong token → `401 Unauthorized`.

**Mapping lookup order (two-level registry):**
1. Explicit `sourceMappingId` or `mappingId` field in the sample, if present.
2. `healthkit:<type>:<sourceName>` if `sourceName` is non-empty.
3. `healthkit:<type>` (generic fallback).

**Response:**
```json
{
  "success":  true,
  "bridgeId": "healthkit-ios-bridge",
  "resolved": [ { "resolved": true, "sensorId": "...", "type": "...", "sourceMappingId": "...", "values": [...], "ttlMs": 3600000 } ],
  "unmapped": []
}
```

HTTP status: `200` (all resolved) · `207` (mixed) · `400` (all unmapped).

**Unmapped entry shape:**
```json
{ "unmapped": true, "type": "...", "sourceName": "...", "reason": "no registry mapping (declare healthkit:<type>[:<sourceName>])" }
```

---

### CareKit Integration

#### `GET /api/integrations/carekit/status`

```json
{
  "bridgeId":               "carekit-ios-bridge",
  "enabled":                true,
  "defaultSourceMappingId": "carekit-activity",
  "tokenConfigured":        false,
  "nativeAppRequired":      true,
  "nativeWorkOutsideRepo":  true,
  "registryKey":            "carekit:<sampleType>",
  "statusEndpoint":         "/api/integrations/carekit/status",
  "ingestEndpoint":         "/api/integrations/carekit/ingest",
  "contract": {
    "transport":    "https",
    "singleSample": ["bridgeId", "sampleType", "sourceMappingId", "values"],
    "batchSamples": ["bridgeId", "samples[]"],
    "auth":         "external-transport"
  }
}
```

`auth` becomes `"bridgeToken"` when `CAREKIT_BRIDGE_TOKEN` is set.

**Removed fields:** `tokenRequired`, `configured`, `bridgeEndpoint`.

#### `POST /api/integrations/carekit/ingest`

Same token auth rules as HealthKit. Same no-token / dev mode behavior.

Top-level body fields are merged into each batch sample (sample keys win); `samples`, `bridgeToken`, `token` are stripped from the merge.

**Response:**
```json
{
  "success":  true,
  "bridgeId": "carekit-ios-bridge",
  "results": [ { "success": true, "sampleType": "...", "sourceMappingId": "...", "sensorId": "...", "taskId": null, "carePlanId": null } ]
}
```

HTTP status: `200` (all ok) · `207` (partial failures).

---

## Out of Scope

The following routes appeared in the locked historical prototype surface
that has been replaced by Scala, but are not part of the canonical surface and
must not be implemented in CPP, LSP, or Scala:

- `GET /api/mqtt/example`
- `GET /api/integrations/healthkit/example`
- `GET /api/integrations/carekit/example`
- `POST /api/triggers/replay/:dispatchId`
- `GET /api/logs/ingest` (Loki-specific, Manager visualizer backend only)
- `GET /api/viz/*` (Manager visualizer backend only)

The Manager visualizer backend exposes `/api/pe/mqtt/*` proxy routes that
forward to the active Perception Engine (`GET /api/pe/mqtt/status`,
`GET /api/pe/mqtt/mappings`, `PUT /api/pe/mqtt/mappings`,
`POST /api/pe/mqtt/enable`, `POST /api/pe/mqtt/disable`). These are
Manager-internal forwarding routes and are not part of the runtime contract;
CPP, LSP, and Scala must not implement them.
