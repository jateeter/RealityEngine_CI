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

- **`reset` clears the semantic audit buffer only when asked.** Settled by the
  owner 2026-09-12. `POST /api/engine/reset` (RE) and `POST /api/reset` (PE)
  accept an optional boolean `clearAudit`. Absent or false, the
  `re:SequenceObservation` / `re:PerceptionEvent` ring buffer **survives the
  reset** — which is today's behaviour on all four runtimes, so the default
  changes nothing. True clears it.

  Accepted both as a query parameter (`?clearAudit=true`) and as a JSON body
  field, because the resets are called both ways across the harness and a caller
  should not have to know which.

  Why opt-in rather than always: the audit trail is evidence, and a rewind of run
  state is not a reason to discard it — `SEMANTIC_AUDIT_CONTRACT.md` invariant 1
  is satisfied by a chain that spans resets. Why it must be *possible*: the
  buffer is cumulative across every drive a process serves, which made
  `verify-audit-chain.sh` report a process's whole history as one drive's result
  (fixed in `c5107fc` by snapshotting, but a caller wanting a clean floor should
  not have to subtract). Dynamic loading and unloading makes that sharper still —
  a buffer holding observations of machines no longer resident describes a corpus
  that is no longer there.

- **Source activity is evaluated wherever activity is computed, including at
  registration.** Settled by the owner 2026-09-12, resolving
  RealityEngine_CI#358. The activity rules in the #163 contract — sensor active
  iff it holds a value inside its TTL, test active iff its interned sequence is
  non-empty, simulated always — are *the* rules, not reset-only rules. A `test`
  source's rule is evaluable the moment the source is declared, because the
  interned sequence is known then, so it is evaluated then.

  Point 2(a)'s "registration declares the source set immediately, completely,
  and **inactive**" is scoped to integration sources, matching 2(b)'s "ingress
  is the only way a source **from an integration** becomes active". It does not
  override point 3's table for `test` sources.

  Observed before this was settled: at registration cpp-1 and scala-1 declared
  1336 of 1351 active and lsp-1 declared 0, while all three agreed at 1336 after
  a reset. Membership was identical throughout. cpp and scala are conformant;
  LSP evaluates at registration as of `RealityEngine_LSP` (#358).

  A booted universe therefore assembles without waiting for a reset, which is
  what `PE_SOURCE_ACTIVATE_ON_LOAD` exists to force and no longer needs to.

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
| GET | `/api/engine/config` | ✓ | ✓ | ✓ |
| GET | `/api/engine/config/:control` | ✓ | ✓ | ✓ |
| PUT | `/api/engine/config/:control` | ✓ | ✓ | ✓ |
| DELETE | `/api/engine/config/:control` | ✓ | ✓ | ✓ |

#### `/api/engine/config` — one pathway for every runtime control

**Specified before it was implemented, and specified once.** Controls were
spread across `/api/runtime/options`, `/api/config` and per-request body flags,
with one — `transitionsInhibited` — having no surface at all. Nothing could
enumerate them, so nothing could compare them across runtimes, and a control
that cannot be read cannot be gated (RealityEngine_CI#271).

Phase 1 carried `transitionsInhibited`; Phase 2 below brings the observational
filters onto the pathway and converges their defaults. `historyLimit` was
**256 on C++, 250 on LSP and 1000 on Scala** — three defaults for one control,
because nothing read them together.

Every control's name, scope and **default** is declared here rather than chosen
per runtime. A runtime that disagrees with a declared default is wrong rather
than different.

##### Shape

A control is described by five fields, and `scope` is the one that decides the
rest:

| field | |
|---|---|
| `name` | the control, as declared here |
| `scope` | `engine` — one value for the runtime; `machine` — one value per machine |
| `value` | current value. For `scope: machine`, an object keyed by machine id |
| `default` | the declared default, from this document |
| `mutable` | whether `PUT` is accepted; a derived reading is reported, not set |

```
GET    /api/engine/config              every control, with its scope and default
GET    /api/engine/config/:control     one control
PUT    /api/engine/config/:control     set it — {"value": X}, or
                                       {"machine": "<id>", "value": X} when scope is machine
DELETE /api/engine/config/:control     restore the declared default
```

`DELETE` is "reset to the value this document declares", not "remove the
control". Controls are fixed by the specification and cannot be created or
destroyed over the API — which is why the C of CRUD has no verb here, and saying
so is clearer than leaving a reader to infer it from a 405.

##### A machine transition reports both the fold and the arbiter's pick

A machine that completes several Reality Events in one transition holds a
*collection* of asserted outputs. Two different things can be said about that
collection, and the step surface already says both, under distinct names in
`machineResults[id]`:

| field | what it is |
|---|---|
| `outputVector` | the arbiter's representative member — evidence that sequences fired |
| `mergedOutputVector` | the collection folded by the machine's declared `outputMergeTransformation` — **what the machine presents**, and what is written to the perceptual space |

They differ whenever more than one sequence asserts. For
`localai/session_rag_context` — PASSTHROUGH, three sequences asserting
`[1,0,0,0]`, `[0,1,0,0]` and `[0,0,1,0]`, default `or` — the step reports
`outputVector [0,0,1,0]` and `mergedOutputVector [1,1,1,0]`, and writes the
latter.

**The single-machine transition routes must report both.**
`POST /api/machines/:id/process`, `/process-universal`, `/whatif` and
`/whatif-universal` carried only `machineOutput`, the pick — so a caller of
those routes could not obtain what the machine actually presents, on a surface
where no step result is available to consult instead. The transition response
therefore carries `mergedOutput` alongside `machineOutput`, the same pair the
step already reports.

`machineOutput.metadata` keeps `combinedFrom` and `sources`, which name the
outputs that went *into* the fold. Beside a pick alone they read as a claim the
value does not support — `combinedFrom: 3` over a value taken from one member —
and that is what made this look like a fold that had been implemented wrongly
rather than a fold that was absent (#418).

**A refusing fold reports `mergedOutput: null` and keeps `machineOutput`.** The
Łukasiewicz pair without a declared chain top refuses rather than guessing, the
machine presents nothing, and nothing is written — but the sequences did
complete, and the arbiter's pick still reports that they did. This mirrors the
step exactly, where a refusal drops the merge operation and leaves
`outputVector` in place, and it is the reason the fix here is an added field
rather than a redefined one: making `machineOutput` the fold would have deleted
the only evidence that a refusing machine fired at all.

##### PUT /api/config/dimension is read-only downward

The perceptual space grows during machine loading to fit every resident
machine's declared regions. A write to this route **must never take it below
what the resident corpus requires.**

The floor is `max(requiredDimension, current width)`:

| request | behaviour |
|---|---|
| below the corpus requirement | **refused**, `400`, naming the requirement |
| below the width already held | **refused**, `400`, naming that width |
| at or above both | applied; the space grows if the value exceeds the current width |

Nothing is mutated on a refusal.

`requiredDimension` is `max(offset + length)` over the input **and** output
regions of every machine the engine is currently holding — the same figure
`/api/runtime/vector-space` reports. It is derived from the corpus in hand, not
configured, so it moves as machines are added.

**Both bounds refuse, and the error names which one applied.** They are
different facts — "the corpus needs more than that" and "this engine already
holds more than that" — and a caller can only act on the one that is true for
them. A request below the current width but above the requirement is still a
downward request, and answering it `200` because nothing was violated would
report success for a write that did not take effect.

**Refused, never clamped.** Silently accepting a lowering request and applying
the requirement instead would make the response disagree with the request while
reporting success, which is how a caller ends up believing it holds a narrower
space than it does — the failure #364 already cost us once, one endpoint over.

The response reports the width the engine actually has after the call, never the
value the caller asked for.

This was violated three different ways, all answering `success: true`:

| runtime | what the write did |
|---|---|
| scala | bound the parameter and echoed it — nothing assigned at all |
| cpp | assigned a server-side seed member that nothing reads for the space |
| lsp | `(setf (reality-state-dimension state) dim)` — unconditional, and would **shrink** below the requirement |

A write that reports success and changes nothing is not harmless: it is
indistinguishable from one that worked, so a caller cannot tell that the control
it is using has no effect (#425).

##### POST /api/machines always ingests; a name conflict is versioned and reallocated

`POST /api/machines` **MUST ingest the requested machine.** It does not reject a
name that is already resident, and it does not replace the machine holding that
name.

**"Already resident" is runtime state, not corpus state.** A name is resident
when a machine carrying it has been previously ingested and is still held in
*this engine's* machine corpus. It is not a question of what the corpus on disk
declares, and it is not shared between engines — an engine that never ingested
a machine has no conflict for its name.

Two consequences follow, and both are contract:

- **`DELETE` frees the name.** Remove the machine holding it and the next `POST`
  of that name is not a conflict: no version suffix, and the **declared mapping
  is honoured**. Versioning is a response to a collision that exists at the
  moment of ingestion, not a permanent mark on a name.
- **ingest → delete → ingest returns the same machine in its initial
  condition.** Not merely a machine with the same name: the same declared name,
  the same declared regions, and the state a freshly-loaded machine has — every
  sequence at its initial Reality Events, no accumulated activation, no matched
  history. The cycle is idempotent, and repeating it any number of times lands
  in the same place.

  This follows from the machine being rebuilt from the request body on every
  ingestion rather than revived from anything retained, and it is stated because
  it is the property that makes `DELETE` safe to rely on. A cycle that returned
  a machine mid-flight — or one carrying a version suffix from a collision that
  no longer exists — would make re-ingestion a different operation from
  ingestion, and a caller reloading a machine would have no way to reach a known
  state.

  **The minted id and the load timestamps are not state and do differ.** A
  re-ingested machine gets a fresh id, and its `outputEvents[].timestamp` records
  when *this* ingestion happened. Both are records of the act of loading, not of
  what the machine has done, and a comparison asserting this property must drop
  them — as every cross-runtime comparison already drops ids
  (`scripts/lib/parity_identity.py`). Verified across three cycles on all three
  runtimes: with ids and load timestamps excluded, every cycle lands on the
  identical initial condition; with them included, the timestamps are the only
  difference.
- **A machine with no `perceptualMapping` still occupies its name.** It is
  ingested and resident even though it never enters the perceptual space, so a
  second machine of that name is versioned — and, having no region to reallocate,
  is ingested under the versioned name with nothing allocated.

When the requested `name` is already held by a resident machine:

1. **The ingested machine's name carries a version suffix.** The engine appends
   ` v<n>` with the lowest `n ≥ 2` that is not already resident, so a second
   `Foo` becomes `Foo v2`, a third `Foo v3`. The suffix is applied to the
   *requested* name, never to the resident one — the machine already in the
   engine is not touched, renamed, or moved.
2. **Its perceptual mapping is newly allocated.** The regions the request
   declares are **not** used. The engine allocates a fresh input region and a
   fresh output region that do not overlap or intersect any resident machine's
   regions, growing the perceptual space to fit.
3. The response reports the machine as ingested — versioned name, minted id and
   allocated regions — so a caller learns what it actually received.

A `POST` whose name is **not** resident is unchanged: the declared name and the
declared regions are honoured exactly.

`PUT /api/machines/:id` and `PATCH /api/machines/:id` are unchanged. They address
an existing machine **by id**, and neither versions a name nor reallocates a
region — a caller that means "make this id be this machine" already has that
route, and this rule must not turn it into a second way to create machines.

###### Why ingest rather than reject or replace

Rejecting makes a re-import fail on the first machine a caller was wrong about.
Replacing silently discards a machine that may have advanced — sequences
mid-flight, activation state — and gives the caller no way to tell a replacement
from a first registration.

Ingesting keeps both machines, keeps both observable, and keeps the caller's
request satisfied. The disambiguation is visible in the response rather than
inferred from a count.

###### The allocation must be deterministic, or the runtimes diverge

Regions are **not** engine-scoped the way ids are: `mergeBatch` carries
`region.offset`, `activeRegions` is ordered on it, and the merge batch is
ordered by `(machineName, region.offset)`. An allocator that produced different
offsets per runtime would put every conflicted machine's output in a different
place on each engine, and every comparison over those fields would report a
divergence that is really an allocation difference.

So the allocation rule is fixed: **append at the end of the current perceptual
space — the input region first, then the output region, contiguously, in that
order.** Given the same resident corpus and the same sequence of ingestions,
three runtimes allocate identically, and a conflicted machine stays comparable.

###### What this costs, stated plainly

The declared mapping of a conflicted machine is **discarded**. A caller that
posts a machine expecting it to read cells 100–104 gets one reading somewhere
past the end of the space instead, and the only way to know is to read the
response. That is the price of guaranteeing ingestion, and it is why the
response must carry the allocated regions rather than echo the request.

It also means a conflicted machine observes a region **no PE source writes**, so
it will not fire until something targets its new input region. It is ingested,
resident and inert — which is a different state from ingested and wrong, and the
response is what distinguishes them.

##### POST /api/machines takes either the Machine object or the corpus envelope

Two accepted request bodies, disambiguated by an **object-valued `machine`
key**:

```
{"version": "1.0.0", "machine": {…}}    the corpus file envelope
{"name": …, "perceptualMapping": …}     the bare Machine object
```

If the body has a `machine` key whose value is an object, the body is the
envelope and the machine is that value. Otherwise the body **is** the machine.
`PUT /api/machines/:id` takes the same two.

**The disambiguation is total for this corpus.** All 1328 files carry the
envelope, and none has an inner machine with its own object-valued `machine`
key, so there is no machine for which the two readings differ. A machine object
that did carry a nested `machine` object would be ambiguous, and the corpus
schema should keep it that way — do not add such a field.

`version` belongs to the envelope. It is **required and validated** there on its
major component, because every corpus file carries one and loosening it would
let a file of the wrong major version load silently. The bare `Machine` schema
does not declare `version`, so it is optional in that shape — and still
validated when a caller supplies one, rather than ignored because of which shape
it arrived in.

A body that cannot be parsed into a machine answers **400**, never 500 and never
200. This is stated because it was violated in both available directions: cpp
answered 200 for a bare object, returned a machine named `unnamed` with no
sequences, and registered nothing — a caller was told a machine was created and
had none — while Scala answered 400 `Missing machine.name` for a body that
*had* a name, because it looked for `body.machine.name` in a body that was
itself the machine (#419). An error must name the field the caller has to add in
the shape they actually sent.

LSP implemented this correctly throughout and is where the rule comes from
(`src/loader.lisp:248`). The generated documents declare both shapes as a
`oneOf`, so a caller holding a corpus file can post it without unwrapping.

##### The perceptual space width is per-engine and is never compared across runtimes

`eventDimension` is a **runtime fact about one engine**, not a shared constant.
Each engine may, during normal operation, hold a different corpus and therefore a
different width — engines are loaded independently, a corpus may be added to at
runtime, and two engines holding different machine sets *should* report different
widths. A difference is not evidence of anything on its own.

The launch value is a **seed**. Every runtime grows its Reality Event length
during machine loading to fit each resident machine's declared regions, so the
width an engine ends at is a property of what it loaded, not of how it was
started.

**The criterion is internal consistency, per engine:** the width an engine
reports must cover `max(offset + length)` over the input *and* output regions of
every machine that engine is holding. That is checkable on a single runtime,
needs no quorum, and is the assertion the conformance checks make.

Recorded because the inverse reading cost three issues. A default launch read
`cpp=7680, scala=7680, lsp=16944`, and the 2-1 split was investigated as an
engine disagreement about a specific machine mapped at `[14364:14384]` — a
machine that was resident and live on all three throughout. The split was real
and was a defect (#364: two runtimes reported the seed rather than the space
they had grown to), but **the split alone never established that**, and reasoning
from it directly led to a harness change that would have entrenched the
misreading. Comparing widths between engines without first equalising their
corpora compares two different questions.

Writing the width is governed separately: a set below the live corpus
requirement must be refused, not clamped (#425).

##### Byte equivalence applies

`GET /api/engine/config` is a compared surface. Two runtimes that hold the same
configuration must serialise it identically — same control set, same names, same
order, same defaults. That is the whole point: the pathway exists so
configuration can be compared, and a comparison over a shape that differs per
runtime compares nothing.

**Except the keys of a `scope: machine` value**, which cannot be compared and
must not be. That `value` is an object keyed by machine id, and machine ids are
minted per runtime — the same corpus machine is
`machine-1789677668723-235803635` on C++, `machine-1U4PASL-6KJA1USAFM6O` on LSP
and `machine-1789677670509-164e9eac` on Scala. Requiring the serialisations to
match would require an equality that id generation forbids, so the clause as
first written could never have passed and would eventually have been read as
the pathway being broken.

What is compared for a machine-scoped control is everything else: the control
set, field names, field order, `scope`, `default`, `mutable`, the number of
entries in `value`, and the distribution of values across them. Measured
against the live universe, all of those agree on all three runtimes at 1338
machines each, and only the keys differ. This is the scoping rule of
RealityEngine_CI#397 reaching configuration: an id is meaningful only inside the
engine that minted it, so a comparison across engines cannot be keyed on one.

Controls are emitted **sorted by `name`**, for the reason the active-region
ordering exists: a set walked in each runtime's own iteration order reports the
same content three ways and no two runtimes ever agree (#197).

##### Phase 1 — `transitionsInhibited`

The first control on the pathway, chosen because it is **machine-scoped**. A
pathway proven only against engine-wide scalars would look finished and fail on
the first per-entity control, which is most of them.

Its behaviour is defined under `POST /api/engine/process`, and it is unchanged
by this route: `false` accepts the Universal Reality Event and flows it through;
`true` accepts it and does not pass it forward. It is declared in the universal
table below, with the Phase 2 controls.

##### Phase 2 — the observational filters

Four engine-scoped controls join `transitionsInhibited` from Phase 1.

##### The universal control set

Every runtime implements every row, with these names and these defaults. **A
comparison requires this set to match exactly**; a runtime holding a different
default is wrong rather than different.

| control | scope | default | mutable | |
|---|---|---|---|---|
| `historyLimit` | `engine` | `250` | `true` | entries retained in the simulation-step history |
| `includeActiveRegions` | `engine` | `true` | `true` | the active-region list in a step response |
| `includeMachineResults` | `engine` | `true` | `true` | per-machine results in a step response |
| `includePerceptualSpace` | `engine` | `true` | `true` | the perceptual-space vector in a step response |
| `transitionsInhibited` | `machine` | `false` | `true` | whether a machine passes its Reality Event forward |

This table is the declaration, and `regression-engine-config-parity.py` **parses
it** rather than restating it. A gate carrying its own copy of the contract is a
second contract: it passes when the runtimes agree with the copy, which is not
the same as agreeing with the specification, and the two drift in exactly the
way this pathway exists to catch.

**`historyLimit` converges on 250**, and this is a contract decision rather than
a measurement. The declared defaults in source are **256 on C++, 250 on LSP and
1000 on Scala**; 250 is chosen because C++ and LSP already sit within six of
each other and Scala's 1000 is the outlier, not the target, for a buffer holding
a full step record per entry across 1338 machines.

A live engine reporting some other number is not evidence of a fourth default.
`/api/runtime/options` reports a **value with no default beside it**, so a
runtime someone has written to is indistinguishable there from a runtime shipped
that way — and that is not hypothetical: `RealityEngine_Manager/scripts/smoke-test.sh`
PATCHes `historyLimit` to 100 and does not restore it, so any engine a smoke run
touched reports 100 forever after. This document said so, having read the live
value as a default.

That is the argument for the pathway, arriving as evidence against the person
making it. `GET /api/engine/config` reports `default` beside `value` for exactly
this reason: the two questions "what does this runtime hold" and "what is this
runtime supposed to hold" have different answers, and a surface that answers only
the first cannot be used to detect drift in the second.

It bounds the **simulation-step** history only. The ISRE and OSRE trajectory
histories have their own limit and are not governed by this control — worth
stating because the parity stages read the trajectories, and a reader who
assumes otherwise would think lowering this control narrows what a comparison
can see.

##### Not every control is universal, and the difference must be sayable

`phaseDetail` exists on C++ alone. It gates reading a clock inside `merge_build`
and emitting the resulting sub-phase timings; LSP and Scala construct a step
differently and have no sub-phases to time.

The tempting move is to require all three to carry it. That would produce, on
two runtimes, a control that accepts `true`, reports `true`, and changes
nothing — which is the precise failure this pathway exists to remove, rebuilt
deliberately and called conformance. **A control that reports a value it does
not act on is worse than an absent one**, because an absent control is visible
and a lying one is not.

So the pathway distinguishes two kinds:

| | |
|---|---|
| **universal** | every runtime implements it, same name, same declared default. The set must match exactly across runtimes; a difference is drift. |
| **instrumentation** | a runtime exposes it because it has the machinery behind it. Declared here with the runtimes that carry it. A difference is a capability difference, not drift. |

| instrumentation control | `scope` | `default` | runtimes |
|---|---|---|---|
| `phaseDetail` | `engine` | `false` | CPP |

Both kinds use the same five-field shape, so nothing about the response changes
and a reader cannot tell them apart from the wire — which is correct. **Which
controls are universal is declared here, not inferred from what the runtimes
happen to agree on.** Inferring it would make the comparison circular: three
runtimes that all omit a control would define it out of the contract, and the
`historyLimit` split is exactly what happens when the runtimes get to decide.

**The per-request flags remain.** A caller declining `machineResults` on one
push is not configuration; folding it in would make response shape depend on
hidden state. The config value is the **default a request overrides** — which is
already how C++'s `includeMachineResultsDefault` behaves, and this makes that
relationship declared rather than incidental.

`compact` is **not** a control. It is a request-body field that sets
`includeMachineResults` false for that one call when the field is omitted, so it
has no stored value to read or write — and giving it one would imply an engine
could be left in a compact mode, which nothing implements and nothing should.

##### `projectionControls` is removed from `/api/runtime/options`

It was an object of prose strings describing request-body fields, emitted by C++
and Scala and absent from LSP. Nothing reads it — no consumer exists in any
repository — and the two that emit it already disagree: C++ carries four keys
and Scala five, with Scala documenting `includeActiveRegions` and C++ not.

Documentation of a request field belongs in this document, where there is one
copy. Carried in a response body it is three copies that drift, and it makes
`/api/runtime/options` a surface that cannot be compared byte-for-byte while one
runtime omits it. The relationship it described is stated above: the config
value is the default, the request field overrides it for one call.

##### `/api/runtime/options` and `/api/engine/config` are one state

They are two views of the same values, not two stores. A write through either is
visible through the other immediately, and a runtime holding two copies that can
disagree does not conform.

`/api/runtime/options` is retained rather than removed: it is the flat shape
existing callers use, and it carries no scope or default. `/api/engine/config`
is the enumerable one — it is what a comparison reads, because it reports every
control with its declared default beside its current value, which is what makes
the drift this issue exists to prevent visible on the first run.

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

#### `POST /api/engine/process` — map across machines, in parallel

**The unit of iteration is the machine, never the sequence.** For each
registered machine, drive the input through that machine's currently active
Reality Events and take the machine's own output. A machine that produces no
output contributes nothing.

```
snapshot = atomically collect the active Reality Event space across all machines
results  = in parallel, for each machine: machine.process_input(vector)
outputs  = [ r.machineOutput for r in results if r.machineOutput ]

{ "result": { "inputEvent": [...], "timestamp": <ms>, "outputs": [...] } }
```

`outputs` is **one arbitrated output per machine that fired**, not one per
sequence that asserted. Passing through the machine is what applies its arbiter
rule, its output-merge transformation and its perceptual mapping. A walk over
sequences skips all three and reports raw assertions no consumer can resolve
back to a machine's actual output.

Three properties, and the iteration model exists to make them possible:

1. **Atomic collection.** The active Reality Event space is sampled once,
   universe-wide, as a single consistent snapshot. A machine registered or reset
   partway through a call must not appear in some outputs and not others.
2. **Machine-level parallelism.** Machines are independent at this boundary and
   are processed concurrently. Iterating sequences forecloses this — sequences
   share machine state, so a sequence-level walk has no safe unit to parallelise
   over.
3. **Atomic join.** The parallel invocations complete into one result set before
   any output is emitted. A partial fan-in is not a shorter answer, it is a
   wrong one.

Implementations should reach for their language's async primitives rather than a
serial loop — futures, actor fan-out, task groups.

**All three runtimes implement all three properties** (RealityEngine_CI#254,
verified in the hosted lane):

| | iteration | parallelism | atomic collection | atomic join |
|---|---|---|---|---|
| C++ | machines | pool + futures | sampled into `jobs` | placement by index |
| LSP | machines | `lparallel pmap` | `machine-snapshot` | snapshot order |
| Scala | machines | actor asks | `getAllMachines` | `Future.sequence` |

The change that matters is not that the gaps closed — it is that **atomicity
stopped being free**. C++ and LSP had it trivially before, because a serial loop
cannot interleave. Both now fan out, so both had to earn it: C++ places results
by index rather than appending on completion, and LSP's `pmap` returns in
snapshot order over a list sorted by machine id.

**What is joined internally is not yet observable.** The runtimes join their own
futures, but nothing on the surface lets a caller wait for a step to be fully
realized, so every harness substitutes elapsed time — `--settle-ms` in
`scripts/regression-trajectory-parity.py`, and nothing at all in
`scripts/regression-ces-contracts.py`. A wall-clock settle is a guess that is
silently wrong under load, and a reader that catches a half-written step reports
it as engine divergence. Tracked as RealityEngine_CI#375, which is a hard
dependency of any per-step comparison.

##### The input may be universal or machine-space, and length says which

The route's purpose is to process the currently active Reality Events across the
universe, so it MUST accept a **Universal Reality Event** — and until
RealityEngine_CI#267 it could not. All three runtimes passed `body["vector"]`
straight to every machine, so a machine whose input region is four cells wide was
compared against a 16,944-cell vector, matched nothing, and reported having
matched nothing. No error, no warning, a well-formed empty result.

**The shape is decided by length**, against the runtime's declared vector
dimension:

| `vector.length` | read as | applied |
|---|---|---|
| `== dimension` | a Universal Reality Event | **decomposed** — each machine receives the slice at its own `perceptualMapping.input` |
| otherwise | machine-space | passed to every machine unchanged |

Length rather than a flag because the two are already distinguishable and a flag
would let a caller assert a shape the payload contradicts. The machine-space
form is retained rather than removed: it is what every existing caller sends,
including the smoke tests, and it remains the direct way to drive every machine
with one input.

**Decomposition is the same operation as the OSRE merge, reflected.** A machine's
input is a slice of the universal space at its declared mapping, exactly as its
output is written back to a slice at another:

```
extract_machine_input (mapping.input)    universal -> machine   decompose
merge_machine_output  (mapping.output)   machine   -> universal compose
```

Both are per machine, both bounded by a declared region, both independent across
machines — so the decomposition parallelises over the same partition the fan-out
already uses, and the atomic collection that makes the fan-out consistent makes
the decomposition consistent too.

A machine whose declared input region falls outside the presented vector
contributes nothing and is not an error: the universe is larger than any one
deployment's space, and refusing would make a partial space unusable rather than
partial.

Stated here because it was not stated anywhere: the route appeared in the table
above with three ticks and no semantics, and three runtimes read the blank
differently. A tick means the path answers, not that it agrees.

##### `transitionsInhibited` — accept the event, decide whether it flows

A machine carries `transitionsInhibited`, and it governs what happens to a
Universal Reality Event presented to that machine:

| value | behaviour |
|---|---|
| `false` (**default**) | accept the Universal Reality Event and **flow it through** to the Reality Engine — the machine perceives it, its sequences may transition, and it may present an output |
| `true` | **accept** the Universal Reality Event and **do not pass it forward** — the machine perceives nothing, no sequence transitions, and it presents no output |

Both values *accept* the event. The flag decides whether it is carried forward,
not whether it is admitted, and an inhibited machine is not an error: it returns
the shape of a machine that matched nothing, with no state change. Refusing
loudly would surface a condition the caller cannot act on, at a seam where the
correct behaviour is a no-op.

**All runtimes must implement it, and the defaults must agree.** The default is
`false` — a machine flows events through unless something inhibits it — and that
default is part of the contract rather than each runtime's own choice.

Agreement on the default matters as much as agreement on the behaviour, because
the flag is not on the wire. A runtime that defaults to `true` where the others
default to `false` answers the same request with zero outputs instead of many,
reports no error, and looks from outside exactly like a universe in which
nothing fired. Nothing in the response distinguishes "inhibited by default" from
"nothing matched", so a divergence in the default is a silent divergence in
every result the route produces.

The same applies to *when* a runtime sets the flag. C++ sets it on registry
copies at `add_machine`; a runtime that sets it at a different point, or on a
different collection, has agreed on the default and still disagrees on the
answer. The contract is the pair: default `false`, and inhibited only for
machines held outside the stepping path.

Today only C++ has the flag at all (`Machine::transitionsInhibited`), and it was
undocumented — which is how `POST /api/engine/process` came to iterate C++'s
registry copies, every one of them inhibited, and return zero outputs where LSP
and Scala returned 167 (RealityEngine_CI#254).

**What it is for.** C++ holds two machine collections — the declared registry
and the `PerceptualSpaceRuntime` — and only the runtime's copies are stepped by
the PE→RE→PE path. Inhibiting the registry's copies stops an endpoint advancing
a machine nothing else observes, which would fork the two. The flag is that
guarantee made explicit rather than left to which collection a route happened to
reach for.

**Consequence for parity.** Zero outputs is a *correct* answer when every
machine reached is inhibited, and a *defect* when it is not — the two are
indistinguishable in the response, which carries no error either way. So a
cross-runtime comparison of this route must read the flag rather than infer from
the count. Two things are gated, not one:

- **the defaults agree** — every runtime reports the same inhibited state for the
  same machine set, checked directly rather than deduced from output counts;
- **agreement on zero is parity only if they also agree they were inhibited** —
  otherwise it is three runtimes independently returning nothing, which is the
  vacuous pass a parity stage exists to prevent.

`regression-engine-process-parity.py` gates both.

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

The two are composed from different contributor sets, and the boundary between
them is where they meet:

- **OSRE composition admits machine contributions only.** External providers —
  ACP, MCP, MQTT, HealthKit, localAI, sensors — take no part in it.
- **Providers act on ISRE composition**, asynchronously, through PE assembly.
- **The whole OSRE build finalises before it is offered to ISRE composition.**
  There is no streaming of a partial OSRE into the next input space.

`ARBITER_CONTRACT.md` §1.1 carries the same statement with the registry
consequences, and §7.2 the fold rules either side of the boundary: a machine
folds its own output events under its declared `outputMergeTransformation`, while
an OSRE cell folds contestants from several machines under the registry rule and
can never inherit a contributor's.

#### The OSRE value is the equality indicator across runtimes

**Machines are compared by what they produce, not by what they are called.**

Machine identity does not survive the boundary between runtimes. The corpus
declares an `id` for **10 of its 1328 machines**; for the other 1318 every
runtime mints one, and they mint differently — C++ from the file stem, LSP from
the same stem lowercased, Scala from a timestamp and a UUID. An identity is
therefore a statement about which engine answered, not about which machine
acted, and a check that reaches for one reports divergence unconditionally
(#146).

The OSRE — the resolved output-cell writes — is what does survive. It is
computed from the corpus, resolved by a declared rule, and carries no engine-local
term. Two runtimes producing the same OSRE for the same input have agreed about
reality; two runtimes producing the same machine ids have agreed about nothing.

So, for every cross-runtime comparison:

- **Compare values.** OSRE cell values, output vectors, merge contributions.
- **Match by corpus `name`** where a comparison needs to pair machines up.
  `name` is corpus-declared and unique — 1328 of 1328, and unique within its
  domain by contract (`name_uniqueness_test.py`). It is a handle, not the
  evidence.
- **Do not compare identity.** Ids, minted output ids, timestamps.
  `scripts/lib/parity_identity.py` strips them once so the rule is applied at
  every probe point rather than restated per stage.

##### Order is not part of the evidence unless a field declares one

The OSRE value is the indicator; the **sequence it arrives in is not**. A
response's ordering is whatever the emitting runtime's container or sort
yielded, and a receiver that needs an order sorts on arrival. Requiring three
engines to agree on one would promote an implementation detail — which
container, which id scheme — into a contract, for no information gained
(#270).

Two fields are the exception, and they are exceptions because **this document
declares their order**, which makes the order itself contractual content:

- `activeRegions` — offset, length, machineId, type, ascending. See "Active
  regions"; enforced by `active_region_order_violations`.
- `mergeBatch` — canonically sorted, per `ARBITER_CONTRACT.md` §6.

Everything else is compared as a **multiset**: sorted in the harness before
comparison, with duplicates kept. Two machines presenting the same vector is a
different result from one machine presenting it, and a set would lose that
distinction.

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
universal-vectors stage returned three singleton clusters on **every** event,
regardless of what the engines had actually done. An unactionable verdict on
every run, which masked the real content of #162 for as long as that issue was
open.

Implemented in `reality.cpp` (`std::sort` after the machineResults walk),
`PerceptualSpaceRuntime.scala` (`sortBy`), and `reality-service.lisp`
(`sort-active-regions`, replacing an `nreverse` that only undid push order and
carried no meaning).

#### Merge batch

`mergeBatch` is emitted on every simulation step and **is ordered**. The
canonical order is `machineName`, then `region.offset`, both ascending. Every
runtime sorts before serialising; a consumer may rely on it, and a byte
comparison of the field is meaningful.

Each entry carries **`machineName`** for this reason. `machineId` is also on the
entry and is deliberately not the sort key.

##### Why not `machineId`

All three runtimes sorted on `machineId`, and each recorded that it was
canonical. It is not, because **`machineId` is minted per runtime for any
machine the corpus does not declare an id for**. The same logical machine:

```
cpp    machine-1789751080357-823522090
lsp    machine-1U4QVFS-OARN5RKBOPS6
scala  machine-1789751110045-120498f1
```

Three keys, three orders, identical content. Four of the five reproduced
disagreements in `domain:digital-logic` were this one defect
(RealityEngine_CI#374): region, `values`, `provenance` and `sequenceIds`
identical on all three, only the sequence differing, and the regions disjoint —
so the committed state agreed and only the wire did not.

The harness then hid the cause. `strip_engine_identity` removes `machineId`
before comparison, correctly, because it is not comparable across runtimes — so
the recorded clusters showed identical entries in three orders with no visible
reason and `machineId=None` in every entry.

This was predicted. RealityEngine_CI#270 rejected id-based ordering for
`POST /api/engine/process` in exactly these terms — *"a minted id is per-runtime
by construction"* — and resolved it by ordering on `machineName`, which is
corpus-declared and globally unique. `mergeBatch` was not covered by that change
and kept the key #270 had just rejected.

`region.offset` breaks ties for a machine writing more than one region, and is
corpus-declared too. Neither half of the key is minted.

This is the same rule as active regions above, for the same reason, and it is
the third field to need it after `activeRegions` (#197) and the engine-process
join (#270).

#### Lane range notation

The wire format carries `{offset, length}` and nothing else. Every range on
every surface — `perceptualMapping.input`/`.output`, `activeRegions`, reserved
ranges, arbitration cells — is that pair, and a consumer computes the half-open
span `[offset, offset + length)` from it. This section constrains only the
**prose and diagnostic** rendering of those pairs, which is where the two
conventions were being mixed.

Written as `[a:b]`, a lane range is **closed on both ends**: `a` is the first
cell and `b` is the last cell the region occupies. A two-cell region at
`{offset: 16920, length: 2}` is `[16920:16921]`, never `[16920:16922]`.

This matters because the corpus is read by people deciding where the next
machine's lanes go. Text of the form `[16920:16922]` — half-open values inside
closed brackets — reads as a three-cell claim on 16922, a cell the region does
not own. Where that cell belongs to another machine's region, the text asserts
a contention the arbiter never sees, and a reader routing around the phantom
overlap builds a feedback edge that has no basis in the data. 5,094 references
across 1,301 machine files carried the half-open form before this was fixed;
`RealityEngine_Machines/scripts/fix-lane-notation.py` performs the rewrite and
corroborates every candidate against a declared region before touching it.

Generators emitting range text render the last cell, not the exclusive bound.

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

## Manager (Visualizer) Surface

The external API. Everything in the RE and PE sections above is the **internal**
surface — reachable by addressing one engine's port directly, and answered by
whichever engine you reached.

This surface is served by `RealityEngine_Manager`'s visualizer backend, and it
is the one an outside caller is meant to use, because it makes the engine
explicit. A vector id and a sequence id are both scoped to the engine that
minted them (RealityEngine_CI#397), so a bare id is ambiguous in a multi-engine
universe and an engine-qualified one is not.

Plural names the set; singular names one engine's resources.

### Engines

| Method | Path | Manager |
|--------|------|---------|
| GET | `/api/engines` | ✓ |
| GET | `/api/engine/:id/health` | ✓ |
| GET | `/api/engine/:id/vectors/:vectorId` | ✓ |
| GET | `/api/engine/:id/sequences/:sequenceId` | ✓ |

### Configuration

| Method | Path | Manager |
|--------|------|---------|
| GET | `/api/engine/:id/config` | ✓ |
| GET | `/api/engine/:id/config/:control` | ✓ |
| PUT | `/api/engine/:id/config/:control` | ✓ |
| DELETE | `/api/engine/:id/config/:control` | ✓ |

The external face of the `/api/engine/config` pathway specified in the RE
section above. Semantics are that section's, unchanged — including `DELETE`
meaning "restore the declared default" and controls being uncreatable over the
API. What this surface adds is the engine qualifier, for the reason the reads
carry one: a control value belongs to one runtime. `historyLimit` is 100 on
C++, 250 on LSP and 1000 on Scala today, so "the current value" is not a
question that can be asked without naming the engine.

The refusals match the qualified reads — an unregistered instance is refused
rather than substituted, a malformed control name is `400`, and a control the
named engine does not carry is that engine's `404`. A write is refused on the
same terms as a read: answering a `PUT` from a different engine than the caller
addressed would be invisible at the call site and would change the wrong
runtime.

`GET /api/engines` returns the engine collection:

```json
{
  "engines": [
    {"id": "cpp-1", "runtime": "cpp", "re_url": "…", "pe_url": "…",
     "status": "running", "active": true}
  ],
  "count": 1,
  "activeId": "cpp-1",
  "instances": [ "…" ]
}
```

`status` is the instance registry's word for the instance; this route does not
probe liveness. `/api/engine/:id/health` does that, per engine, and reports
`unreachable` when the engine does not answer.

The qualified reads answer from the named engine or 404 from it:

- found → `200 {"vector": "<document>"}` / `200 {"sequence": "<sequence>"}`
- the engine does not hold it → `404 {"error": "…", "engine": "<id>"}`
- the instance is not registered → `404 {"error": "Engine instance '<id>' is not registered", "available": ["…"]}`
- malformed id → `400`

An unregistered instance is refused, never substituted — the same rule the
`X-RE-Instance` request binding follows, and for the same reason: answering from
a different engine than the caller addressed is invisible at the call site.

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

#### `lastPush` is the last step, not when it happened

`GET /api/state` reports `lastPush` as **`null` before any push, and afterwards
the step object the last push produced** — the same shape `POST /api/push`
returns under `step`, carrying the same keys:

```
activeRegions  eventBus  machineResults  mergeBatch  perceptualSpace
perceptualSpaceIsDebugProjection  stepNumber  timestamp
```

**`timestamp` is part of that object and is required.** It is the field a
timestamp-only `lastPush` used to be, so nothing a caller could previously read
is lost: `lastPush.timestamp` answers "when", and the rest answers "what". A
client reconnecting can render the last result without replaying it, which a
bare timestamp cannot support and is the reason this shape is the contract.

This is declared because the runtimes disagreed and nothing had noticed
(RealityEngine_CI#407): LSP reported the step object, C++ and Scala reported a
bare integer timestamp. Two of three agreeing is not the same as two of three
being right — quorum here is 3-of-3 (`docs/QUORUM_CONTRACT.md`) — and the shape
that carries strictly more, while still containing the other, is the one that
can be adopted without loss.

It went unseen because **before any push all three report `null`**, and every
comparison that had looked at this route ran against a freshly started
universe. A contract stated only for the pre-push state cannot detect a
post-push divergence. Conformance is therefore checked **after at least one
push**; a green result from a PE that has never been pushed to is not evidence.

##### How `/api/state` is compared

Two rules, because this surface carries engine-scoped identity and a naive
comparison of it can never pass.

**1. The key sets must match exactly.** Every runtime reports the same fields at
every level — the eight above, the source fields, and the keys of each nested
object. A field one runtime carries and another does not is a divergence, and is
reported as such rather than tolerated.

**A combined machine output reports both where it came from and what it is.**

`transitionResult.machineOutput` is the arbiter's fold of a machine's completed
Reality Events. Two facts about it are contractual, and every runtime carries
both:

| field | holds | |
|---|---|---|
| `provenance` | the **input** event ids that caused the output | the chain, as `RealityEvent::provenance_chain` resolves it |
| `metadata.sources` | the **output** event ids that were folded | one per entry in the fold, in fold order |

They are different facts and neither substitutes for the other. The runtimes
each carried one: C++ and LSP emitted `provenance` and no `sources`, Scala
emitted `sources` and no `provenance`, so a consumer asking either question got
an answer from some runtimes and `null` from the rest
(RealityEngine_CI#410).

**`metadata.sources` names output events, not input events.** For
`AIHardwareResilience`, the fold of the `aihr-in-healthy` event's output reports
`sources: ["aihr-out-healthy"]` and `provenance: ["aihr-in-healthy"]`. Reporting
the input id as the output's identity is what made the two indistinguishable,
and is why the corpus now spells the input `aihr-in-healthy` rather than
`aihr-healthy` (RealityEngine_Machines#163).

`metadata.descriptions` is **not** contractual. Scala emits it when a folded
output carries a `description`; it is a convenience for a human reading a
response, no consumer reads it, and it is filtered at the boundary rather than
implemented by the other two — the rule under "The observable boundary".

##### `POST /api/sources/bootstrap-from-machines` is skip-if-present

A machine that already has a test source is **skipped**, not rebuilt. The
counters mean:

| | |
|---|---|
| `machinesSeen` | machines examined |
| `created` | sources that **did not exist** and now do |
| `skipped` | machines left untouched, for any reason |

`created` counts additions. A runtime that rebuilds an existing source in place
has not created anything, and reporting that as `created` makes the number
describe work done rather than sources gained — which is what it meant on LSP,
where a second bootstrap reported `created: 1336` while the source count stayed
at 1351 with no new names and no duplicates (RealityEngine_CI#413).

Skip-if-present is chosen because **the harness depends on idempotence**. Every
cross-runtime comparison arms its stimulus with this call, and a bootstrap that
rebuilds on one runtime and skips on two has done different work on each before
the comparison starts — `scripts/CLAUDE.md` states the rule it breaks: *sources
must be equalised before anything is compared*.

The cost is real and worth naming: a machine redefined since its source was
built keeps a source describing the old definition. LSP's implementation
recorded that concern and defaulted to rebuilding because of it. The answer is
that a redefined corpus is reloaded, not merged — `POST /api/reset` plus a fresh
bootstrap, or a restart — and a runtime that wants the old behaviour can set
`PE_SOURCE_MERGE=false` to force the rebuild.

**A machine that produced no output reports `null`, never `[]`.**

Each `machineResults` entry describes the output *this step* produced.
`outputRegion`, `outputVector` and `mergedOutputVector` are therefore `null`
together when the machine completed no Reality Event — there is no vector, and
no region one was written to.

`[]` is not a neutral stand-in for absence. It is a positive claim that an
output vector exists and is empty, and a consumer asking "did this machine
produce output?" must not get *yes, an empty one* from one runtime and *no* from
another. This is the same error as a vector of zeros, which this document
already rejects for arbitration: zeros are a positive claim about every cell in
the region.

The machine's **declared** output region is a property of the machine and is
still reachable from `GET /api/machines/:id`. This field answers the narrower
question of where this step's output went.

LSP reported the declared region and `[]` here while reporting `null` for
`mergedOutputVector` beside them — one object, one condition, two encodings
(RealityEngine_CI#409). `inputRegion` and `inputEvent` are unaffected: a machine
always consumes input, so their absence would mean something different.

**2. Engine-specific ids are never compared.** `machineResults` is an object
**keyed by machine id**, and ids are minted per runtime: the same corpus machine
is `machine-1789687061048-341051310` on C++ and `machine-1U4PI1H-506GF8UC6O3K`
on LSP. Comparing those keys requires an equality that id generation forbids, so
what is compared is the **shape of the values and the number of entries**, never
the keys themselves. The same applies to `sequenceResults`, keyed by sequence
name, and to any future id-keyed map.

This is the rule already settled for reads (#397) and for machine-scoped
configuration controls ("Byte equivalence applies", above), reaching `/api/state`.
An id is meaningful only inside the engine that minted it, so a comparison
across engines cannot be keyed on one.

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

#### Requesting less than the full step

Two fields in the table are **observation surfaces**: nothing reads them to
produce the next result, and both scale with the corpus rather than with what
fired. On the push path this is the dominant cost of a step — the engine
computes one in 3.96 ms and the response can spend sixteen times that packaging
fields the caller discards (`RealityEngine_CI#256`, `#259`).

| Request field | Omits | Default | Class |
|---|---|---|---|
| `includeMachineResults: false` | `machineResults` | `true` | observation |
| `includeActiveRegions: false` | `activeRegions` | `true` | observation |
| `compact: true` | `machineResults` | `false` | — |

`perceptualSpace` and `mergeBatch` have no flag and never will. They are what a
caller consumes to produce a result — the first carries machine outputs into the
next push, the second is what trigger dispatch scans — and a response without
them is not a step.

Three rules, each of which has a failure behind it:

- **Omitted, not emptied.** A runtime that returns `activeRegions: []` when the
  field was not requested is stating that no regions were active, which is a
  different claim. The parity stage compares key sets, so an emptied field
  reports as agreement between a runtime that had nothing to say and one that
  was not asked.
- **`compact` is unchanged.** It still omits exactly `machineResults` and
  nothing else. Widening it would have been convenient and would have silently
  changed what several regression stages assert against a wire they already
  compare byte-for-byte.
- **Defaults stay full.** No existing caller changes shape, so the parity gates
  keep comparing identical key sets until a caller opts out, and an opt-out is
  visible in that caller's own request rather than in a server-side default
  someone has to go and look up.

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
| GET | `/api/integrations/localai/ledger` | ✓ | ✓ | ✓ |

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

All routes listed in this spec are implemented by all three runtimes, and the
one open **payload** gap has since been closed. It is kept here because the
register is the record of how a gap was settled, not only of which are open.

#### `GET /api/machines` — the sequence summary is not the same shape everywhere *(settled 2026-09-09)*

This route serves each machine's sequences in summary form rather than in full.
The runtimes disagree about what that summary contains:

| Runtime | `sequences[]` keys on this route | Emitted by | Before |
|---------|----------------------------------|------------|--------|
| CPP | `id`, `name`, `initialEventIds` | `reality.cpp`, `Machine::to_json` (non-`full` arm) | `id`, `name` |
| LSP | `id`, `name`, `initialEventIds` | `model.lisp`, `machine-json` (non-`full` arm) | `id`, `name` |
| Scala | `id`, `name`, `initialEventIds` | `Machine.scala` | unchanged |

**This is not internal augmentation, and the distinction is the point.** The
rule under "The observable boundary" permits a runtime to carry more than its
peers and directs the boundary to *filter* rather than replicate — but that rule
is about fields no consumer reads, which is what made `valuesPacked` a
non-issue (#208). `initialEventIds` has a consumer. The Scala Perception Engine
builds its machine corpus from this exact route and reads the key for
`provenance()`; `MachineCorpus.scala` states it outright — "everything comes
from `GET /api/machines` ... and each sequence's initial vector ids" — and falls
back to an empty vector when the key is absent. A Scala PE paired with a CPP or
LSP Reality Engine therefore reports an empty provenance trail and no error,
which is the failure mode this register exists to catch.

So the summary shape is a contract this document had never stated, and the three
runtimes answered it two ways.

**Settled the first way: `initialEventIds` is part of the sequence summary, and
CPP and LSP now emit it.** Both already computed the initial-event list on the
`full` path, so each change was small — `RealityEngine_CPP#91` made
`CriticalEventSequence::initial_vector_ids()` public for the summary builder,
and `RealityEngine_LSP#105` factored `sequence-initial-event-ids` out for the
same reason. The ids are id-sorted in all three, so the comparison has
something to agree on (#197).

The alternative — declaring the key out and fixing the Scala PE to source
provenance elsewhere — was rejected because the PE would then need a
full-detail request per machine to read one field.

Verified on a live `cpp:1,lsp:1,scala:1` universe over the full 1338-machine
corpus: all three emit the key on every machine, and the three-way comparison
finds no disagreement across 5112 sequences.
`RealityEngine_Machines/tests/integration/machine-summary-initial-events.spec.ts`
holds it there, asserting presence before agreement — three runtimes that all
omit the key agree perfectly.

Discovered by the tri-runtime comparison in
`e2e/tests/tree-to-pe-manager-equivalence.spec.ts` on 2026-09-08
(RealityEngine_CI#321), where it appeared as a 1563-byte difference on a route
nothing had declared byte-equivalent — which is the case for a declared surface
rather than a blanket hash: the same run raised two findings, and only this one
was a defect. `e2e/lib/parity-surface.ts` is where the
comparison now records what each captured surface is held to and why.

---

## Reality Event key names — migration complete

The theory has no vectors, only Reality Events. The domain type was renamed in
`#219`; `ISRE`/`OSRE` already carried the right language. Everything else was a
contract rather than a name, so it moved under a stated migration rather than a
sweep — `RealityEngine_CI#220`, in three layers, **all now complete**:

| layer | what | ended |
|---|---|---|
| 2 | response-body keys | tolerance removed in 2c |
| 1 | corpus schema keys | schema tightened to canonical only |
| 3 | the Qdrant collection | `reality-vectors` → `reality-events` |

The table below is kept as the record of what moved.

| old spelling | canonical |
|---|---|
| `inputVector` | `inputEvent` |
| `activeVectors` | `activeEvents` |
| `totalVectors` | `totalEvents` |
| `vectorDimension` | `eventDimension` |
| `matchedVectors` | `matchedEvents` |
| `activatedVectors` | `activatedEvents` |
| `initialVectorIds` | `initialEventIds` |

**Only the canonical spelling is accepted.** Each layer ran the same three
landings — tolerate, migrate, remove tolerance — and every one of them ended by
deletion rather than by deprecation. `EVENT_KEY_RENAME` is gone from
`parity_identity.py`; `at_either`, `jget-either` and the per-repository accessor
modules are gone; `RealityEngine_Machines/schemas/machine.schema.json` now *rejects* the old spelling with an
explicit `not: { required: [...] }`, because `additionalProperties: true` would
otherwise have left a legacy machine valid-but-ignored.

The tolerance was what let four runtimes move one at a time. Without it the
rename would have had to land in C++, LSP, Scala and the TypeScript PE
simultaneously, with the Manager UI, the CI stages and the MCP tools in the same
window, or every parity run between the first merge and the last is red for a
reason that is not a divergence.

**What the migration was actually guarding against.** Not incompatibility — a
missed read. Every reader of these keys used a `.get()` with an empty default,
so a reader looking for a spelling that had moved returned an empty list and
reported success. Nothing threw. The defects this rename produced were found by
comparing counts, never by a test going red: a binding derivation that dropped
178 output-actor bindings with its full suite green, a generator that emptied
`semantic-bus-registry.json` of 1,276 lines, a checker that certified "70
machines scanned, 0 violations" over a corpus it could not see, a PE that
created 0 sources instead of 1,328 and logged `errors=0`. A corpus-load count
across all four runtimes is the check that catches this class, and it gated
every landing.

Language-level data structures — `std::vector`, the C++ `Vector` alias, Scala
`Vector[Double]`, `vector-push-extend` — are not Reality Events and were never
touched. Neither were the `/api/vectors` route segments, the numeric vectors
`POST /api/perceptual-simulation/configure/chunk` accepts, or Qdrant's own
`"vectors": { size, distance }` collection body.

## Quorum is 3-of-3

**All three native runtimes — C++, LSP, Scala — must agree, or the signature is
a disagreement.** There is no majority rule, no reference runtime and no
designated baseline. A 2-of-3 split is a disagreement, not a decision.

The TypeScript PE conforms to the agreed contract; it is not a fourth vote.
Manager follows it.

The full rule, with the reasoning and the conformance checklist a harness is
held to, is **`docs/QUORUM_CONTRACT.md`**. It is binding on every harness that
compares runtimes, and the Participation States below are how a runtime declines
to take part without being counted as agreement.

Why a majority is not enough, in one case: on `GET /api/machine-graph` the LSP
and Scala runtimes emitted identical bodies and C++ emitted a different one at
*identical byte length* — the same six edges in map order rather than canonical
order (#349, `RealityEngine_CPP#94`). Two agreed. They were correct only by
accident of which defect happened to exist, and under a majority rule the result
reads as consensus.

---

## Participation States

**A surface that will not answer must say so. Silence is not a state.**

Every integration-backed surface reports one of these when asked to take part in
a lane. The set is closed: a caller may switch on it exhaustively, and a value
outside it is a contract violation rather than an extension point.

| State | Means | Conforming? |
|---|---|---|
| `active` | Participating; answers are real. | yes |
| `not-configured` | The integration is implemented but this deployment gave it nothing to talk to — no broker, no endpoint, no credential. | yes |
| `not-active` | Configured and reachable, deliberately not participating in this lane. | yes |
| `unsupported` | This runtime does not implement the surface at all. | yes |
| `unavailable` | Configured and expected to participate, but could not — the dependency is down or erroring. | **no** — a finding |

### Why the vocabulary exists

`not-configured`, `not-active` and `unsupported` are all *conforming* answers, and
they are not interchangeable: they say, respectively, that the deployment
withheld something, that the lane withheld something, and that the runtime never
had it. `unavailable` is the only one that means something is wrong.

**A runtime that simply returns nothing is none of these, and that is the
defect.** Absence and refusal are indistinguishable at the wire, so a comparison
across runtimes reads both as "no disagreement" — which is how a Scala PE paired
with a C++ engine reported an empty `provenance()` audit trail with no error
(#321), how a bootstrap counter divergence rode along as an allowance, and how a
trajectory exclusivity check disabled itself without saying so (#307). Each was
one surface staying quiet where it should have declared.

### Reporting

- `GET /api/health` carries the state per integration it owns.
- A comparison gate records the declared state alongside each signature, so a
  skipped surface is auditable rather than merely absent from the output.
- **Where every runtime answers `unsupported` for a signature, that agreement is
  itself a result and must be reported as one**: it says the shape is
  unimplemented everywhere, which is a real and useful fact about the surface —
  a gap in the contract rather than a gap in one engine. Reporting it is how an
  unbuilt surface becomes visible instead of looking like a surface nobody
  happened to exercise.

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

### Vectors

`/api/vectors` is a **JSON document store**, not a Reality Event constructor.
Settled here for RealityEngine_CI#288, where Scala did the other thing.

#### `POST /api/vectors`

Store the posted body verbatim under an id and hand it back:

```json
{ "success": true, "vector": "<the body you posted, plus \"id\">" }
```

- `id` is taken from the body when present, generated when absent.
- **Every other field in the body is preserved.** The runtime does not parse,
  validate or reshape the document — a field it has never heard of comes back
  unchanged, and is still there on a later search.
- The stored document is exactly what the response echoes.

#### `POST /api/vectors/search`

```json
{ "results": [ { "vector": "<the stored document>", "score": 0.97 } ] }
```

Scoring reads the numbers out of the stored document: the `vector` array when
present, otherwise `elements[].value`. Selection is **first-k above threshold in
id order** — not top-k by score. Documented at the implementation in each
runtime.

#### `GET /api/vectors/:id` — internal, and engine-scoped

- present in this engine's store → `200 {"vector": <the stored document>}`
- absent → `404 {"error": "Vector not found"}`

**A vector id is only meaningful inside the engine that minted it.** Each runtime
keeps its own store, so the same id can name different documents on different
engines, or exist on exactly one. A bare `/api/vectors/:id` therefore answers
from whichever engine the request reached, and the caller cannot tell which
answer they got.

So this route is the **internal** surface. The external read is engine-qualified,
on the Manager:

```
GET /api/engine/:engineId/vectors/:vectorId
GET /api/engine/:engineId/sequences/:sequenceId
```

Those resolve the engine by instance id and proxy to that engine's own route. An
unknown instance is refused, never substituted — the same rule the
`X-RE-Instance` binding follows. A 404 from the engine is passed through with
the engine named, so "no such id" stays distinguishable from "not on this
engine".

The same scoping applies to `GET /api/sequences/:id`, which has always had this
ambiguity and is likewise internal.

Before RealityEngine_CI#397 the vector route was a stub in all three runtimes:
it returned `200 {"message": "Vector retrieval endpoint", "id": …}` for every
id, including ids that existed nowhere, so a caller read "not found" as "found".
It was byte-equivalent across the three while carrying no information, which is
why parity checks never flagged it.

#### Why this shape

C++ and LSP already agreed on it, which is the usual tiebreak, and the companion
`GET /api/vectors/:id` is a stub in all three runtimes — so this family is a
plain store rather than part of a retrieval API that would justify a typed
model. "Store what you were given, hand it back with an id" is also the only
shape under which an unknown field survives, which is what makes the route
usable by callers the runtime does not know about.

Scala previously read `elements` and `isInitial`, constructed a `RealityEvent`,
returned `RealityEvent.toJson` — carrying `isActive`, `matchCount` and the rest
— and **stored nothing**. Two consequences: the response could not pass byte
equivalence, and a POST followed by a search found the document on C++ and LSP
and never on Scala.

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
  "defaultSourceMappingId": "carekit-task",
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
