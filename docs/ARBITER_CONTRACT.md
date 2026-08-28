# Output Arbiter Contract v1.0

Status: **implemented in all four runtimes**, with conformance partially gated.
Applies to: RealityEngine_CPP, RealityEngine_LSP, RealityEngine_Scala, RealityEngine_Manager (TypeScript PE).

| | |
|---|---|
| resolution | implemented in all four |
| `GET /api/arbitration` (§6 observability) | all four — Scala first, the rest in jateeter/RealityEngine_CPP#31, jateeter/RealityEngine_LSP#49, jateeter/RealityEngine_Manager#60 |
| §9 fixtures | in the corpus, and exercised by the `arbiter` regression stage (jateeter/RealityEngine_CI#123) |
| §8 acceptance | criteria 1, 2, 4, 5, 5a, 8 and 9 gated; 3, 5b–5e, 7, 10 and 11 deferred with their blockers recorded in that issue |

The header said "no runtime implements this yet" until 2026-08-16, well after all
four did. It is restated here because this document is what the conformance
stage is built against, and a status line that lags the runtimes invites
building against a specification everyone already left behind.

This document is the single source of truth for how output Reality Events are
resolved into the next InputSpace Reality Event. All four runtimes build to it,
and byte equivalence across them is the acceptance test.

## 1. Why

At any instant a machine `M` has exactly one input Reality Event Vector, compared
against all active CES Reality Events. Its next value is produced by whatever
final Reality Events targeted its input positions. When more than one such event
targets the same position, something must decide the resolved value.

Today nothing does:

| level | current behaviour | defect |
|---|---|---|
| machine (`OutputArbiter`) | `AND`/`OR`/`PASSTHROUGH` decide *whether* to emit; `combineOutputs` takes **the first** output as the value | selects, does not resolve |
| universal (merge) | `perceptualArray[offset+i] = value` per machine in list order | **last writer wins** |

All 1323 machines declare `PASSTHROUGH`, so the machine gate is always open. The
merge order is a `ListBuffer` in machine-iteration order — stable, therefore a
wrong resolution reproduces perfectly and reads as correct. There is also an
internal contradiction: one machine with N asserted outputs enqueues N writes to
the same region, so the merge applies *last* while its own arbiter declared
*first* representative.

## 1.1 Contributors are not only machines

A position is a bus member because *some output event targets it and some machine
reads it*. Nothing in that definition says the writer must be a machine. An
external provider emitting through a PE source is structurally identical to a
machine emitting a final Reality Event: both are contributions to a position.

**These providers do not share a path.** ACP, MCP, MQTT, HealthKit, localAI and
sensors each have their own PE source, with its own transport and its own
transformation from that transport's return structure or stream into Event Vector
Values. What is uniform is their **behaviour at the source boundary**, not their
implementation:

- each transforms using the declared semantic content of the target axes (§4.3b)
- each yields no contribution where an axis cannot be resolved
- each diverts its failures to the analysis stream
- each produces contributions that are **indistinguishable downstream** — once a
  contribution exists, the arbiter cannot tell which transport produced it, and
  must not care beyond the `determinism` class

So this is a behavioural contract satisfied independently N times, once per source
type, rather than one implementation reused. That is harder, not easier:
conformance does not transfer. A passing ACP source is no evidence about MQTT.

**The obligation is on the integration surface, not on a fixed list.** The
providers named here are the current instances, not the definition. Supporting
this transformation is a requirement every integration surface must meet, and the
set is expected to grow — **adding an integration is adding a conformance
obligation**, discharged before that integration may contribute. A surface that
cannot express the transformation cannot become a source; it does not get an
exemption, because an exemption is exactly a path into the reality vector that
skips the gate (§2.1).

This is not hypothetical. Of 4,003 cells targeted by `openClawProjection`
write-backs across 1,184 machines, **2,794 are already bus members** — a machine
output writes them too. **898 of 1,184 machines** have an agent write-back landing
on a position a machine output also writes.

Measured contention in the corpus (1323 machines):

| | positions |
|---|--:|
| domain bus (DB) total | 2,802 |
| single-writer among machines | 2,534 |
| contended, **machines only** | 268 |
| contended, **including external providers** | **2,833** |
| — of which machine *and* agent write the same cell | 2,794 |

Counting machines alone understates contention by **10.6×**. The 268 are
structured — repeated blocks of four writers (`signal-monitor`,
`capacity-balancer`, `agent-dispatcher`, `outcome-stabilizer`) converging on three
readers (`resource-router`, `referral-optimizer`, `governance-escalator`) — but
they are the minority case. The dominant case is a deterministic machine output
and an advisory agent assessment landing on one position in one instant with no
rule to resolve them.

The ACP completion band `[17000:25000]` that once sat above the corpus has been
retired. It contained **0** bus cells and was read by **0** machines, so
completions landing there contributed to nothing and arbitrated over nothing —
the observation that motivated jateeter/localOpenClawStack#18. ACP completions
reach the vector through the `acp-openclaw-completion` service lane instead,
where they are read and arbitrated like any other writer.

Removing the band from `rangePolicy.reservedRanges` retires the declaration.
The 1,216 per-machine completion source mappings in
`RealityEngine_CI/config/integrations.json` that still target `17000+` are the
other half and are retired separately; until they are, they write cells no
allocation declares and nothing reads.

## 2. Position

The arbiter is one stage with three phases, placed between the final Reality
Events of instant `k` and the InputSpace Reality Event of instant `k+1`:

The InputSpace is not a single vector but a **queue** of Input Reality Event
Vectors (IREQ), fed by the PE simulation stream, by the UI, and by synthetic
queue generation. Arbitration finalizes by merging into the **head** of that
queue.

```
IREQ:  [ head ][ +1 ][ +2 ] ...        ← PE simulation stream / UI / synthetic generation
          ▲
          │  MERGE INTO HEAD  (exactly one resolved value per cell)
          │
   L2 ── universal arbiter ── contributions → 1 value per cell
          ▲
        GATHER  (cell → [contribution])          ← nothing written yet
          ▲
   L1 ── machine arbiter ── N CES outputs → 1 machine vector
          ▲
   final Reality Events emitted
          ▲
   every machine compares its input EV to active CES events
          ▲
        IS(k)  ── dequeued from IREQ head
```

This position is forced. It is the only point where every contribution for the
instant is known *and* the head of the queue has not yet been consumed as
`IS(k+1)`. Resolving earlier cannot see all contributors; resolving later mutates
an event already dequeued.

**No runtime may write into the perceptual array during gather.** Gather produces
contributions; only the head-merge writes.

### 2.1 Nothing bypasses the arbiter

**Every path that affects an Input Reality Event Vector goes through
arbitration.** There is no privileged writer and no direct-write escape hatch.
That includes:

| path | contributor, not a bypass |
|---|---|
| machine final Reality Events | yes |
| PE sources — ACP, MCP, MQTT, localAI, sensor | yes |
| PE simulation stream | yes |
| UI-injected values | yes |
| synthetic IREQ generation | yes |

Head-merge content already present in the queue entry is itself a contributor set
and is arbitrated with the rest — a queue entry does not get to *be* the next
input event by virtue of arriving first. An operator forcing a value is expressed
as a **declared ranking in the arbitration registry**, never as a write that
skips the stage. If a value can reach `IS` without producing an
`ArbitrationRecord`, that path is a defect.

The practical test is negative: instrument the perceptual array so any write not
originating from the head-merge fails the build.

## 3. Contribution

A contribution is provider-tagged. Machine outputs and PE sources use the same
shape; only `provider` and the origin fields differ.

```
// Provider is an OPEN registry, not a closed enum. New integration surfaces
// register here; the listed values are the current instances.
Provider   := "machine" | "acp" | "mcp" | "mqtt" | "healthkit" | "localai"
            | "sensor" | "stream" | "ui" | "synthetic" | <registered surface>
Determinism := "deterministic" | "measured" | "generated"

Contribution := {
  cell            : uint32       // absolute InputSpace position
  value           : float64      // clamped [0,1]
  provider        : Provider
  determinism     : Determinism
  originId        : string       // machineId, or the PE sourceId for non-machine providers
  cesId           : string?      // machine providers only
  outputVectorId  : string?      // machine providers only
  ragStatusCode   : string?      // "GREEN"|"AMBER"|"RED", when the provider supplies one
}
```

`determinism` is the load-bearing classification; `provider` is transport.

| class | meaning | default providers |
|---|---|---|
| `deterministic` | reproducible from the corpus and `IS(k)` alone | `machine` |
| `measured` | exogenous but not generated — a reading or a specified injection, reproducible under replay | `sensor`, `mqtt`, `healthkit`, `stream`, `ui`, `synthetic` |
| `generated` | produced by a non-deterministic process; not reproducible | `acp`, `mcp`, `localai` |

A newly registered surface MUST declare its class. When in doubt it is
`generated`: misclassifying a generated source as `measured` lets irreproducible
content outrank a reading, which is the failure §4.3a exists to prevent.

Queue-supplied content (`stream`, `ui`, `synthetic`) is `measured`: it is
exogenous to the corpus but specified and replayable. It therefore ranks below a
machine determination under `PRECEDENCE`. An operator who needs an injection to
win a cell raises that cell's ranking in the registry — deliberately, with a
rationale — rather than relying on arrival order.

A provider's default class may be overridden per source, but a `generated`
contribution may never be reclassified upward.

Non-machine contributions enter only through their own PE source's transformation
(§4.3b). A response the transformation cannot resolve produces no contribution —
not a contribution with a null value — and must not reach the arbiter.

### 3.1 Conformance is per source type

Each PE source type is a separate implementation of §4.3b. The contract is
therefore satisfied `runtimes × source types` times, and conformance does not
transfer between them: ACP passing says nothing about MQTT, and the Scala ACP
source passing says nothing about the C++ ACP source.

Every source type MUST be exercised independently against the §9b fixture and
acceptance criteria 5b, 5c, 5c′ and 5c″. A source type that has not been
exercised is unverified, not assumed-conformant — and because each owns its own
transformation, a defect in one is invisible from the others.

**This applies to future integration surfaces on the same terms.** The §9b
fixture and criteria 5b–5c″ constitute the admission test for a new source: it
is run against the surface before that surface may contribute, and the surface
registers its `provider` value and `determinism` class as part of passing. The
test suite is therefore parameterised over registered surfaces rather than
enumerating them, so a new integration inherits the obligation automatically
instead of needing the suite rewritten.

## 4. Rules

### 4.1 The binding invariant

Every admissible rule MUST be a **commutative monoid**: commutative, associative,
and with an identity. This is not stylistic — it is what permits parallel
reduction in any order, and what makes four independent implementations agree.

*First* and *last*, the two rules in use today, satisfy none of it.

### 4.2 Rule set

Values are float64 clamped to `[0,1]` (`dense-float64-clamped-0-1`).

| rule | definition | identity | exact in IEEE-754 |
|---|---|---|---|
| `OR` | `max(a,b)` | `0.0` | yes |
| `AND` | `min(a,b)` | `1.0` | yes |
| `MAX` | `max(a,b)` | `0.0` | yes |
| `MIN` | `min(a,b)` | `1.0` | yes |
| `SEVERITY` | see 4.3 | lowest severity, `0.0` | yes |
| `PRECEDENCE` | see 4.3a | lowest rank, `0.0` | yes |
| `MEAN` | see 4.4 | — | **no** — restricted |

`OR` and `MAX` are the same operation on `[0,1]`; both names are kept because
they express different intent (asserted-ness vs magnitude). Implementations MUST
treat them identically.

### 4.3 `SEVERITY`

Contributions carry the `ragStatusCode` of the determination that produced them.
Order `GREEN(0) < AMBER(1) < RED(2)`. Resolve to the maximum severity present;
among contributions at that severity, resolve the value by `MAX`. Both steps are
commutative monoids, so the composite is one.

A contribution from a sequence typed `re:LifeSafetySequence` is promoted to
severity `3` and dominates unconditionally.

#### 4.3.1 Obtaining the severity — the trigger-rule join

`ragStatusCode` is **not** carried on the output vector. Only 24 of 5,128 output
vectors have it in `metadata`; it lives in `metadata.triggerConfig.rules`, keyed
by sequence and output value, on all 1,328 machines. A runtime that reads it off
the output vector will find it absent essentially always.

A machine contribution's severity is therefore obtained by joining, at merge
time:

```
severity(contribution) :=
    rules := machine.metadata.triggerConfig.rules
    hits  := { r ∈ rules | r.sequenceId == contribution.cesId
                         ∧ r.outputMatches == contribution.outputVector }
    → max(hit.ragStatusCode for hit in hits)
```

**The join is total over the corpus.** Measured across all 5,128 output vectors:
0 have no matching rule, 5,110 match exactly one, 18 match more than one. Of the
18, 16 are duplicate rules carrying the same value.

`max` over the severity order handles the remainder and keeps the join a
commutative monoid, so §4.1 survives. It is also the safe direction: treating an
emergency as routine is the worse error. Exactly one machine currently needs it —
`AIHardwareResilience` / `aihr-hw-degradation` / `[0,0,0,0,0,1]` maps to both
`GREEN` ("schedule maintenance window") and `RED` ("emergency hardware
replacement — pull from production"). That is a corpus defect rather than a
modelling nuance and is tracked separately; the join must not depend on its being
fixed.

**Non-machine contributions** supply `ragStatusCode` from their own surface when
they have one. Absent, the contribution sits at `GREEN` — a floor in the ranking,
not a substituted value, and distinct from the prohibition in §4.3b, which
governs the *value* and not this metadata. Under `PRECEDENCE` a generated
contribution ranks below every deterministic one regardless, so its severity only
discriminates against other contributions in its own class.

Implementing this join is in scope for every runtime. Without it `SEVERITY` and
every `withinRank: SEVERITY` entry are undefined, which today is 270 of the 2,837
registry entries.

### 4.3a `PRECEDENCE` — determinism ranking

The dominant contention case is a deterministic machine output and a generated
agent assessment on one position. `OR`/`MAX` would let the generated value
override the determination whenever it happened to be larger — a non-deterministic
process silently overwriting a deterministic one, decided by magnitude.

`PRECEDENCE` resolves by **determinism class** first, then by `MAX` on value
among contributions at the winning class:

```
deterministic (3)  >  measured (2)  >  generated (1)
```

Resolution is the lexicographic maximum of `(class, value)`. Lexicographic max
over a totally-ordered pair is commutative, associative and idempotent, so §4.1
holds and parallel reduction remains safe.

**`withinRank` — the second axis.** A cell is often contended on two axes at
once, and in this corpus almost every one is: a machine determination contends
with a generated assessment *across* classes, while several machine
determinations contend with each other *within* the winning class. Falling back
to `MAX` among the winners collapses those determinations to one value and
discards which of them asserted — the outcome `SEVERITY` exists to avoid.

An entry may therefore declare `withinRank`, one of `OR`/`AND`/`MAX`/`MIN`/
`SEVERITY`, applied among the contributions at the winning rank. Absent, it is
`MAX`. Since both stages are commutative monoids, so is the composite, and §4.1
still holds.

Measured over the corpus: **2,833** contended cells, of which **268** carry more
than one machine writer and so require a `withinRank` rule. `withinRank` is
meaningful only under `PRECEDENCE`; on any other rule it is an error.

**The ordering is not a status hierarchy and not a preference.** It follows from
reproducibility. A deterministic contribution is derivable from the corpus and
`IS(k)` alone; a generated one is not derivable from anything and cannot be
reproduced by re-running the instant. Letting the irreproducible term win would
make `IS(k+1)` irreproducible, and with it every downstream determination — the
corpus would lose the property that makes it provable at all.

A domain may raise a specific cell's ranking in the registry, but doing so
deliberately imports irreproducibility into that lane and must carry a rationale
saying so.

### 4.3b The transformation is the quality gate

As information flows back from OpenClaw or Ollama, **the transformation from the
return structure or stream into Event Vector Values is the gate.** It is not a
validation step that precedes a transformation. The transformation is given the
agent response and uses the **declared semantic content of the target axes** to
produce the values — and a transformation that cannot produce a value for an axis
has failed for that position.

There is therefore exactly one question per position: *does the response contain
content that the declared semantics of this axis resolve to a value?* If yes, a
contribution exists. If no, it does not.

This subsumes shape and meaning into one operation rather than two gates:

- arity, type and range fall out of the target region's declared axes — a
  response that yields values for the wrong number of axes has not transformed
- meaning falls out of the axis semantics driving the extraction — a well-formed
  response that asserts a different quantity does not resolve against the axis it
  was asked for, and so yields nothing for that position

**A failed transformation produces no contribution.** Not a null, not a zero, and
above all not a default. The cell then resolves from its `deterministic`
contributors, which is the correct outcome rather than a degraded one.

#### A default substitution destroys the gate

If the transformation substitutes a value when extraction fails, it can never
fail, and the gate does not exist. This is the corpus's present state:

| | |
|---|--:|
| agent specs with a `responseMapping` | 1,320 |
| response fields total | 8,531 |
| **fields carrying `textFallback.default`** | **8,531 (100%)** |
| distinct default values | one — `0.5` |

Every field of every agent, without exception, substitutes `0.5` when the JSON
pointer misses and no phrase matches. An empty, malformed, off-topic or
hallucinated response therefore produces a perfectly well-formed contribution
asserting `0.5` on every axis, indistinguishable from a confident assessment.

The chosen value makes it worse. `0.5` is the modal element threshold in the
corpus — **33,277** elements sit exactly there — so under `gte` the failure value
lands precisely *on* the decision boundary rather than safely below it. A
transformation failure does not degrade toward silence; it degrades toward
assertion.

**Defaults are therefore prohibited on the generated path.** An axis that cannot
be extracted yields no contribution for that position. Where a genuine neutral
resting value is meaningful for an axis it must be declared as that axis's
semantics and justified there, not applied blanket as an extraction fallback.

#### Failure diverts to the analysis stream

A failed transformation is not waste. It carries information the system wants:
*this agent, asked this trigger, for this machine, on this axis, returned
something the declared semantics could not resolve.* Discarding it keeps the
reality vector clean and throws away the only evidence that the binding is wrong.

So failure has two effects, not one:

1. **No contribution** into the Input Reality Event Vector. Unchanged — the
   vector stays clean.
2. **Diversion into the analysis stream**, carrying the axis and its declared
   semantics, the extraction attempted, the response received, the agent and
   trigger, the target machine and cell, and the instant.

The analysis stream is a **learning feedback path**, not a log. It is what lets
the system observe which agents, which axes, and which prompts fail to resolve,
and it is the natural input to refining axis semantics, response mappings, and
agent bindings. The interconnection graph is part of the learning regime; failed
transformations are part of the same regime, and they are the higher-signal half
because a failure localises a specific broken binding.

**The analysis stream never writes the reality vector.** It may inform changes to
the corpus, to a response mapping, or to a source configuration — all of which
take effect on a later instant through the ordinary path. Nothing on the analysis
stream reaches an Input Reality Event Vector except by becoming a contribution
and going through the arbiter like anything else (§2.1). A learning path that
short-circuits into the vector would reintroduce exactly the bypass §2.1
prohibits, and would let irreproducible content in through a side door.

Silent rejection is as damaging as silent acceptance: it presents as an agent
that never answers, and it starves the learning path.

The 9 machines where `openClawProjection.semantics` and the derived agent
write-back semantics genuinely disagree (jateeter/localOpenClawStack#17) are
exactly the population this gate exists to catch — and cannot catch while every
field defaults.

### 4.4 `MEAN` — restricted

Floating-point addition is **not associative**, so a parallel reduction of
`MEAN` is not order-independent and will break byte equivalence.

`MEAN` is therefore permitted only under a mandated canonical order:
contributions MUST be sorted ascending by `(machineId, cesId, outputVectorId)`
and summed in that order, then divided by the count. The sum is serial *within* a
cell; cells remain independent, so parallelism across cells is unaffected.

Runtimes that cannot guarantee this ordering MUST reject `MEAN` at load time
rather than approximate it.

### 4.5 Uncontended cells

A cell with exactly one contributing machine resolves to that contribution
regardless of declared rule. Implementations SHOULD short-circuit; the result
MUST be identical either way.

## 5. Declaration

Contention is a property of the corpus, not of a machine, so it is declared
centrally in `domains/arbitration-registry.json` (schema:
`schemas/arbitration-registry.schema.json`), generated and drift-checked like
`region-allocation.json`.

```json
{
  "schemaVersion": "1.0.0",
  "entries": [
    { "cell": 1735, "rule": "SEVERITY",
      "writers": [
        { "provider": "machine", "originId": "HSPH001_...json" },
        { "provider": "machine", "originId": "HSPH004_...json" }
      ],
      "readers": ["HSPH002_...json"],
      "rationale": "four-way convergence; suppressed contributors must stay attributable" },

    { "cell": 928, "rule": "PRECEDENCE",
      "providerRanks": { "machine": 3, "acp": 1 },
      "writers": [
        { "provider": "machine", "originId": "DocumentSigningWorkflowMonitor.json" },
        { "provider": "acp", "originId": "acp.openclaw.documentsigningworkflowmonitor.input-analyst.assessment" }
      ],
      "readers": ["DocumentSigningWorkflowMonitor.json"],
      "rationale": "agent assessment is advisory; the machine determination wins" }
  ]
}
```

**Validation: any cell with more than one writer — counting machine outputs and
PE sources alike — MUST have an entry.** An undeclared contended cell is a corpus
error, not a runtime default.

Registry generation must enumerate PE source write-back regions
(`openClawProjection.writeBackRegion`, MQTT mappings, sensor and localAI source
regions) alongside machine output regions. Deriving from machine outputs alone
misses **2,794** of **2,833** contended cells.

## 6. Observability

The domain bus exists to observe and manage dynamic operation, so resolution
must not be invisible. For every contended cell, every instant, the arbiter emits:

```
ArbitrationRecord := {
  instant, cell, rule, resolved : float64,
  contributors : [ {provider, originId, cesId?, outputVectorId?, value} ],
  suppressed   : [ {provider, originId, cesId?, outputVectorId?, value} ]
}
```

`provider` is mandatory on every entry. A suppressed agent assessment must remain
attributable — "the agent's answer was discarded" is exactly the operational fact
the domain bus exists to surface.

`suppressed` is what the resolution discarded. Emitting records for uncontended
cells is OPTIONAL and SHOULD be off by default.

## 7. Parallelism directives

The stage is structurally parallel: gather is a map, resolve is a per-cell
reduction over an independent contributor set, commit is a scatter over disjoint
cells. **Cells never interact.** Partition by cell range and the work is
embarrassingly parallel; the commutative-monoid requirement in 4.1 is what makes
any partitioning safe.

Each runtime SHOULD use its idiomatic concurrency rather than a ported design:

- **RealityEngine_CPP** — `std::future` / `std::async` over disjoint cell
  partitions, or a thread pool with per-thread gather buffers merged at the
  barrier. No shared mutable state during resolve; commit writes disjoint cells
  so it needs no locking.

- **RealityEngine_LSP** — actor-theory decomposition: an actor per contended cell
  (or per cell shard) receiving contribution messages and resolving at the
  instant barrier. Mailbox accumulation is naturally commutative, which matches
  4.1 exactly; prefer message passing over shared structure.

- **RealityEngine_Scala** — the runtime is already Akka-based with per-machine
  actors. Shard L2 across typed actors by cell range and join with
  `Future.traverse` / `Future.sequence`; parallel collections are acceptable for
  the pure reduce. *(Proposed — confirm against the existing actor supervision
  before building.)*

- **RealityEngine_Manager (TypeScript PE)** — `Promise.all` over cell shards;
  `worker_threads` for the resolve when the contended set is large, since the
  Node event loop will not otherwise overlap CPU-bound reduction.

Parallelism MUST NOT change results. Byte equivalence is the gate, and any
implementation whose output depends on partitioning has violated 4.1.

## 8. Acceptance

0. **Byte equivalence is only defined over reproducible contributions.** A
   `generated` contribution is not reproducible by construction, so §8.1 is
   tested either with generated sources disabled, or by **replaying a recorded
   contribution set** so every runtime sees identical inputs. Comparing two live
   agent runs and expecting identical vectors is not a test — it is a
   misunderstanding of what `generated` means.
1. Given one corpus, one `IS(k)`, and one replayed contribution set, all four
   runtimes produce a byte-identical `IS(k+1)`.
2. Shuffling machine load order does not change `IS(k+1)` in any runtime.
3. Varying the parallel partitioning does not change `IS(k+1)`.
4. **Varying the arrival order of PE source contributions does not change
   `IS(k+1)`.** Non-machine contributions arrive asynchronously, so this is the
   externally-visible form of §4.1 and the one most likely to be violated.
5. A cell written by both a machine output and a PE source resolves per its
   declared rule, in all four runtimes.
5a. A `generated` contribution never overrides a `deterministic` one under
   `PRECEDENCE`, at any value.
5b. A response the transformation cannot resolve against a declared axis produces
   **no contribution** for that position and one rejection record; the cell
   resolves from its remaining contributors.
5c. A well-formed response asserting a different quantity than the axis asked for
   does not transform, and produces no contribution.
5c'. **No extraction path substitutes a default.** An empty response, a
   malformed response and an off-topic response are each distinguishable from an
   assessment, and none of them yields a value.
5c''. Every failed transformation appears on the **analysis stream** with its
   axis, declared semantics, attempted extraction and received response — and
   **nothing on the analysis stream reaches an Input Reality Event Vector**
   except as a contribution through the arbiter.
5d. **No write reaches an Input Reality Event Vector without a corresponding
   `ArbitrationRecord`.** Tested negatively: instrument the perceptual array so
   any write not originating from the head-merge fails the build. UI injection,
   synthetic queue generation and the PE simulation stream are each exercised to
   confirm they arbitrate rather than bypass.
5e. Arbitration merges into the **head** of the IREQ, and the head is not
   consumed as `IS(k+1)` until the merge completes. A queue entry with
   pre-existing content is arbitrated with the instant's contributions, not
   overwritten by them and not preferred over them.
6. An undeclared contended cell fails corpus validation, counting machine and
   non-machine writers alike.
7. `MEAN` without canonical ordering is rejected at load.
8. Every contended cell emits an `ArbitrationRecord` whose `contributors ∪
   suppressed` equals the full contribution set for that cell and instant, with
   `provider` populated on every entry.
9. Both minimal fixtures (§9) resolve per their declared rules in all four
   runtimes.
10. **§9b and criteria 5b–5c″ are run once per registered source type**, not once
   per runtime. Source types do not share a transformation (§3.1), so conformance
   does not transfer between them.
11. The conformance suite is **parameterised over the provider registry**, so a
   newly registered integration surface is exercised without the suite being
   modified. A surface that has registered but not passed may not contribute.

## 9. Minimal fixtures

The RS ring latch (`RSRingLatchStageA/B`) proves propagation but has no
contention — every DB position it uses has one writer. Two fixtures are needed,
and they are not interchangeable:

**9a — machine/machine contention.** Two machines writing one cell, read by a
third, with a declared rule. The least structure that distinguishes resolution
from overwrite.

**9b — machine/provider contention.** One machine and one PE source writing one
cell, read by that machine, with `PRECEDENCE` declared. This is the dominant real
case (2,794 cells) and 9a cannot exercise it: only 9b can prove that an advisory
contribution does not override a determination, and that an asynchronous arrival
order does not change the result.

Both belong beside the ring in the regression corpus.

## 10. Open

- ~~`SEVERITY` needs `ragStatusCode` on the contribution.~~ **Decided: implement
  the trigger-rule join as part of the arbiter work.** Specified in §4.3.1 and in
  scope for every runtime. The 270 registry entries that depend on `SEVERITY`
  stand as written; fixture §9a will fail until the join exists, which is the
  correct behaviour for a conformance fixture.

  The plumbing gap it closes, using Scala as the illustration: `OutputVector`
  carries `metadata`, but the merge discards the wrapper —
  `pendingOutputs` is `ListBuffer[(Machine, Vector[Double])]`, built by
  `sr.assertedOutputs.foreach { ao => pendingOutputs += ((machine, ao.vector)) }`.
  Carrying the contribution rather than the bare vector into the gather phase is
  a prerequisite of §4.3.1 in every runtime, not only Scala.
- Whether L1 should become element-wise (`OR`/`MAX`) or keep gate semantics with
  a separate value rule. This document assumes element-wise; the current
  "first representative" behaviour is replaced either way.
- **The transformation gate is defeated corpus-wide today.** All 8,531 response
  fields across all 1,320 agent specs carry `textFallback.default: 0.5`, so the
  transformation cannot fail and §4.3b is unenforceable until those are removed.
  Tracked as jateeter/localOpenClawStack#21. The contract is written to the
  intended behaviour; implementers should expect the corpus to violate it until
  that issue lands.
- **Per-source conformance is unverified across the board.** The source types do
  not share a path — ACP, MCP, MQTT, localAI and sensors each own their own
  transformation — so §4.3b must hold independently in every one of them, and
  none has been read in any runtime. The surface is `runtimes × source types`,
  and because each owns its transform, a defect in one source is invisible from
  the others by construction. This is the largest unverified area in the
  contract.
