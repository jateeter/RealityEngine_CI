# Semantic Guardrail Contract (ingress/egress)

Last reviewed: 2026-08-13

Single source of truth for the **admission rules** applied to information
crossing any RE/PE integration boundary, in either direction. The rules
themselves live in `semantics/shapes/re-guardrails.shacl.ttl`; this document
explains what they mean, what they deliberately do not cover, and how the four
runtimes must implement them.

Companion to `docs/SEMANTIC_AUDIT_CONTRACT.md`, which specifies the records
emitted *after* a decision. That contract observes; this one decides.

## What this contract owns

| Artifact | Owns |
| --- | --- |
| `semantics/shapes/re-guardrails.shacl.ttl` | Every admission rule. Normative. |
| `semantics/shapes/fixtures/cases.trig` + `cases.json` | Every accept/reject decision the runtimes must reproduce. Normative. |
| This document | The rules the shapes graph cannot express, and the rollout. |

## What it does not own

Saying "single source of truth" only means something if the boundary is drawn.
The shapes graph is authoritative for **whether a proposed write or dispatch is
admissible**. It is not authoritative for:

- **Allocations** — `domains/region-allocation.json` remains the source of
  truth for which span of the universal vector belongs to whom. The shapes
  validate a lane graph *projected from* it.
- **Behavior** — the machine JSON corpus remains the source of truth for what a
  machine does. `semantics/abox/` is generated from it; never hand-edited.
- **Vocabulary** — `semantics/ontology/re-core.ttl` remains the source of truth
  for machines, actions, autonomy modes and RAG statuses. The guardrail layer
  adds terms in its own `reg:` namespace and annotates re-core individuals with
  an ordering (`reg:autonomyRank`); it does not redefine them.

Anything that changes an allocation, a behavior or the vocabulary is a change
to those artifacts, and the guardrails follow.

## Rule 1 — one ingress chokepoint, one egress chokepoint

The strongest property of the existing design is that "all integration
boundaries" is a false plural. MQTT, localAI, OpenAI, Ollama, ACP/OpenClaw,
HealthKit, MCP and manual callbacks already converge on one commit path (source
mapping → `POST /api/signals`), and everything leaving converges on the trigger
envelope dispatcher and its ledger.

**Normative:** provider adapters translate syntax only. An adapter constructs a
`reg:IngressAdmission` or a `reg:EgressDispatch` and submits it; the decision is
taken once, in one place, from this shapes graph. Provider-specific admission
logic is a contract violation, not an optimization — the moment
`openai/dispatch` validates differently from `healthkit/ingest` there are eight
boundaries again and the system's guarantee is the weakest of them.

## Rule 2 — the lane is the type

A `{offset, length}` is an address, not a meaning. The guardrail promotes it to
a **typed lane** (`reg:IngressLane`) whose axes declare, per position: name,
unit, admissible range or enumerated domain, and optionally the SOSA
observable property it reports. The lane additionally declares its permitted
providers, permitted provenance classes, staleness ceiling, and — for lanes
feeding a machine with an `re:LifeSafetySequence` — the autonomy floor a source
must hold to write it.

Admission then answers a question no schema can: *does this source have the
standing to say this about this region, and is what it says within the declared
domain?*

The failure class this addresses is well-formed-and-wrong. In a shared vector
of 4,109 packed positions, `[1,0,0.82,0]` at 3813 and the same payload at 1933
are both valid JSON, both in range, and mean entirely different things.

## Ingress gates

Evaluated against `reg:IngressAdmission`. The shape is `sh:closed`: an
admission carrying properties this contract does not declare is refused rather
than silently narrowed to the fields we happen to read.

| Gate | Rule | Refuses |
| --- | --- | --- |
| I1 | Region addressing | Write offset ≠ lane offset; write length past the lane; a value at an index the lane does not declare |
| I2 | Authority | Provider not on the lane's permitted list; caller-supplied lane binding without `reg:callerAuthority`; source autonomy below the lane's floor; a life-safety lane written without a declared autonomy; any write under `re:Observe` |
| I3 | Meaning | Value outside declared axis bounds; value outside an enumerated domain; provenance class not permitted on the lane; `reg:Measured` with no `sosa:madeBySensor`; `reg:Derived`/`reg:Inferred` with no `sosa:usedProcedure` |
| I3b | Units | Arriving unit not in the axis's `reg:acceptedUcum`; a non-UCUM system with no declared bridge; a converted value on an axis that forbids conversion; a changed value where nothing should have been converted; a slot with no recorded unit |
| I4 | Freshness | Received later than the lane's staleness ceiling allows; observed after it was received |
| I5 | Model binding | `reg:Inferred` with no `reg:envelopeId` or no `reg:correlationId` |

Bounds and enumerated domains in I3 are checked against the **normalized**
value in the axis's canonical unit, never the value as received. Checking a raw
figure against canonical bounds is the bug this ordering exists to prevent.

### I2 and the completion endpoint

`RealityEngine_CI/docs/INTEGRATION_ARCHITECTURE.md` currently documents that
direct `sensorId`, `region` or `sourceMapping` fields on
`POST /api/integrations/completions` override the configured mapping, "for
manual and test callbacks". That is a caller declaring its own semantic
authority, and it is the sharpest edge in the current design.

This contract does not remove the capability; it makes it visible and gated.
An admission states how its lane was determined (`reg:ResolvedFromRegistry` or
`reg:SuppliedByCaller`), and a caller-supplied binding is refused unless the
admission also carries `reg:callerAuthority`.

**Normative:** deployed profiles grant `reg:callerAuthority` to no provider
adapter. Test harnesses may hold it.

### I5 and the model boundaries

OpenAI, Ollama, MCP and ACP are the only ingress whose content can be
adversarially shaped by upstream text. Three rules, all enforced above:

1. Model output is never authoritative for its own region binding. The
   `sourceMappingId` is resolved from the dispatch record, never read from the
   response body.
2. A completion inherits the envelope and correlation of the dispatch it
   answers, or it is not a completion — it is unsolicited input.
3. Model-derived values carry `reg:Inferred`, and a lane may refuse that class.
   A model value and an instrument value are never indistinguishable once
   merged.

## Egress gates

Evaluated against `reg:EgressDispatch`, also `sh:closed`.

| Gate | Rule | Refuses |
| --- | --- | --- |
| E1 | Escalation invariant | An `re:EscalationAction` dispatched from a determination not carrying `re:RED` |
| E2 | Closed action vocabulary | An action that is not a canonical individual of `re-core.ttl` (only those carry `re:actionCode`) |
| E3 | Autonomy | Autonomy above the binding's `re:maxAutonomy`; any dispatch under `re:Observe`; an escalation below automated-act without recorded approval; a binding requiring approval with none recorded; a binding blocked at the determination's RAG status |
| E4 | Permitted actions | An action code absent from the binding's `re:allowedAction` list |

E1 is the runtime counterpart of the `re:EscalationDetermination` axiom already
in `re-core.ttl`. There, a non-RED escalation is an inconsistency of the
*corpus*, caught in CI by `scripts/reason-owl.sh`. Here it refuses the
*dispatch*. Both are needed: the corpus can be correct and a runtime still
assemble a bad envelope.

`reg:humanApproved` is required on every dispatch, always asserted and never
inferred from absence. An adapter that cannot determine whether a human
approved must say `false`.

## Fail-closed rules

These are behaviors, not data constraints. A shapes graph judges a node; it
cannot specify what the runtime does next. They are normative anyway.

1. **A refused ingress is a no-write plus a recorded rejection.** Never a
   partial region write, never a substituted default. A partial write is the
   worst available outcome: after the merge phase it is indistinguishable from
   genuine machine output.
2. **A refused egress is a ledger record with `reg:Blocked`, not a dropped
   dispatch.** The ledger is an outbox and an audit trail; silence there
   destroys the evidence chain.
3. **Rejections carry the same IRI joins as acceptances** — machine IRI, lane
   id, determination IRI where known. Otherwise audit queries can only see what
   got through, which is the wrong half.
4. **A lane that fails the corpus-time shapes admits nothing.** A lane with no
   usable contract is closed, not open.

## Enforcement staging

`sh:severity` carries the rollout. Each constraint is `sh:Violation`,
`sh:Warning` or `sh:Info`, per shape, and the runtime maps them:

| Severity | Runtime behavior |
| --- | --- |
| `sh:Violation` | Block, per the fail-closed rules |
| `sh:Warning` | Admit, record the finding, increment the `semantic_*` counter |
| `sh:Info` | Admit, record only |

This is the same incremental-gate pattern the corpus already uses for
`STRICT_DOMAIN_CONTRACT` and `generate-owl.py --strict-actions`. With 1,006
mapped machines, enforcement cannot be flipped corpus-wide on day one — but the
staging lives in the shapes graph rather than in per-runtime configuration, so
four runtimes cannot drift into staging it differently.

Observe-phase telemetry is free: `PE_METRICS_CONTRACT.md` already requires the
`semantic_*` exposition block to be byte-identical across runtimes.

## Runtime architecture

**Ontology and shapes at build time; a decision table at runtime.**

```
OWL reasoner materializes inferences   (CI: scripts/reason-owl.sh, ROBOT/HermiT)
        ↓
SHACL validates the materialized graph (CI: scripts/validate-guardrails.sh)
        ↓
shapes compile to a lane decision table (engine load time)
        ↓
admission = table lookup + bounds test  (PE push cycle)
```

No reasoner and no SHACL engine belongs in the hot path. Every constraint in
the shapes graph is deliberately evaluable against asserted triples only — the
action individuals, autonomy modes and RAG individuals it joins against are
asserted directly in `re-core.ttl`, so no inference is required for a decision.
That is what makes the compile step sound.

## Decision parity

A guardrail that C++, Lisp, Scala and the TypeScript PE implement differently
is worse than none, because the multi-engine registry lets a caller route
around the strict one.

`semantics/shapes/fixtures/cases.trig` is the parity suite: 43 named graphs —
admissions, dispatches and malformed lane contracts — with the expected
decision in `cases.json`. Every runtime must reproduce all 43 decisions
exactly.

```bash
./scripts/validate-guardrails.sh
```

The script skips cleanly (exit 0) when pyshacl is absent, mirroring
`reason-owl.sh`; CI containers install it to make the gate real. As of this
review the suite is 43/43 against the reference shapes graph.

This is also the argument for SHACL over the current approach.
`tests/contracts/owl_semantics_test.py` is 242 lines of Python doing what
SHACL core constraint components do — vocabulary closure, cardinality,
controlled-code membership, the RED⇒escalation invariant, trigger/sequence
parity. Correct, but unshareable: three of the four runtimes cannot execute a
Python test, so each would reimplement the check and they would drift. A
shapes graph is data. Any conformant validator executes it identically, and it
ships in the corpus beside the machines it constrains.

## SOSA/SSN alignment

The integration surfaces are the heavily-used part of this system, so they
speak a standard observation vocabulary rather than a local one.
[SSN/SOSA](https://www.w3.org/TR/vocab-ssn/) is a W3C Recommendation (19 Oct
2017) and simultaneously an OGC implementation standard, which is what the MQTT
and HealthKit paths interoperate with.

| RealityEngine | SOSA/SSN |
| --- | --- |
| `re:PerceptionEvent` (committed write) | `sosa:Observation` — asserted as a subclass |
| `reg:IngressAdmission` (proposed write) | `sosa:Observation` — the same act, before the decision |
| PE source | `sosa:Sensor`, via `sosa:madeBySensor` |
| Model or computation | `sosa:Procedure`, via `sosa:usedProcedure` |
| `reg:EgressDispatch` | `sosa:Actuation` — asserted as a subclass |
| Subject of the observation | `sosa:hasFeatureOfInterest` |

The provenance distinction falls out of the alignment structurally rather than
by convention: `reg:Measured` requires `sosa:madeBySensor`, `reg:Derived` and
`reg:Inferred` require `sosa:usedProcedure`.

Two deliberate modeling choices, recorded so they are not re-litigated:

- **`reg:LaneAxis` links to `sosa:ObservableProperty`; it does not subclass
  it.** An axis is a position within a region; an ObservableProperty is a
  quality of a feature. Subclassing would make the same quality reported at two
  positions into one thing. `reg:LaneAxis` is instead a subclass of
  `re:SemanticAxis`, which keeps `re:axisName` functional across both the
  corpus and the lane registry — two sources naming one position differently
  stays an inconsistency rather than a spelling variant.
- **Units are declared on the axis, not taken from SOSA.**
  `sosa:hasSimpleResult` carries no unit, so the unit contract lives on
  `reg:LaneAxis`. See the next section.

## Units and quantity kinds

**Decision: UCUM canonical in data, QUDT canonical in semantics, OM
bridge-only.**

The split follows what each vocabulary is good for. UCUM codes are what travel
on the wire and what a device bridge can emit without carrying an ontology.
QUDT is what makes dimension compatibility and conversion *provable*, because
`qudt:hasQuantityKind`, `qudt:conversionMultiplier` and
`qudt:conversionOffset` are asserted facts a reasoner and these shapes can join
against. OM is a bridge: an OM-native contribution is mapped to UCUM at ingest
and the UCUM code is what gets stored.

### The wire contract

A unit on the wire is an object, not a string — `reg:Unit`, mirroring the JSON
exactly so an adapter serializes it without interpreting it:

| Field | |
| --- | --- |
| `reg:unitSystem` | `http://unitsofmeasure.org` for UCUM. Any other system requires `reg:bridgesToUcum`. |
| `reg:unitCode` | The code within that system. |
| `reg:unitDisplay` | Original human-readable text, preserved so normalization never destroys what the source said. |
| `reg:bridgesToUcum` | The UCUM code a non-UCUM unit maps to. The OM path. |

### The axis contract

| Annotation | |
| --- | --- |
| `reg:canonicalUcum` | The unit the vector position is stored in |
| `reg:expectedUcum` | What sources are expected to send |
| `reg:acceptedUcum` | Every admissible arriving unit; must include the canonical one |
| `reg:quantityKind` | QUDT quantity kind IRI — the dimension check a bare UCUM string cannot support |
| `reg:qudtUnitIri` | QUDT unit individual, carrying the conversion facts |
| `reg:conversionPolicy` | `none` \| `linear` \| `affine` \| `prohibited` |
| `reg:scaleType` | `ratio` \| `interval` \| `ordinal` \| `nominal` |

### `reg:scaleType` is an addition, and why

`conversionPolicy` is otherwise unguarded. `linear` applied to an interval
scale silently drops the offset; applied to an ordinal it is a category error
rather than an arithmetic one — and most of this corpus writes machine-native
progression ordinals, not physical quantities. The Stevens scale makes the
correct policy derivable instead of a matter of care, and three corpus-time
rules fall out of it:

- an ordinal or nominal axis must declare `prohibited`
- an interval axis may not declare `linear`
- an axis whose QUDT unit carries a non-zero `qudt:conversionOffset` may not
  declare `linear`

The third is the one worth the whole exercise. QUDT asserts
`qudt:conversionOffset` only where it is non-zero — in practice `unit:DEG_C`
(273.15) and `unit:DEG_F`. So "this axis must be affine, not linear" stops
being a naming convention a reviewer has to notice and becomes a check that
fails in CI. `semantics/shapes/fixtures/cases.trig` proves it in
`reject-affine-declared-linear`.

### Normalization is PE's job, before the vector write

The PE normalizes to the axis's canonical unit and writes the normalized
figure. Every value slot records **both** quantities and the unit received:

```turtle
[ reg:atIndex   0 ;
  reg:value     22.0 ;          # normalized, canonical unit (Cel)
  reg:originalValue 295.15 ;    # as received
  reg:observedUnit fx:u-kelvin ]
```

`reg:originalValue` is required even when nothing was converted, so audit
records have one shape rather than two. Dimension-incompatible input is refused
by the accepted-unit gate before any conversion is attempted.

### A limitation to design around

**These shapes compare UCUM codes as strings.** SHACL cannot parse UCUM, so
`mg/dL` and `mg.dL-1` are different codes here even though UCUM makes them
equal, as are `/min` and `min-1`. Codes must therefore already be in a single
canonical UCUM form by the time they reach a boundary graph. That is a
corpus-time and adapter-time job — a UCUM canonicalizer in the projector and in
the adapter SDK — not something the guardrail can do for you. Without it the
failure mode is false rejection, which is at least safe and loud.

### The QUDT subset

Do not merge all of QUDT into a validation or reasoning run; it is large and
the CI reasoner will not stay tractable. Extract a **pinned subset** containing
only the quantity kinds and units the corpus actually references, generated by
script from an upstream QUDT release and version-stamped, and merge that.

`semantics/shapes/fixtures/qudt-subset.ttl` is a fixture-scale stand-in,
hand-written so the unit gates can be exercised. Its header says so. It is
**not** an extraction and its conversion facts are representative rather than
verified against a QUDT release; a real extraction is required before the unit
gates run against the live corpus.

### OM

Bridge only. `reg:bridgesToUcum` on a non-UCUM unit is what makes an OM-native
contribution admissible, and the bridged UCUM code is what the axis contract is
evaluated against. An OM unit with no declared bridge is refused —
`reject-om-unbridged-unit`. OM never becomes primary, so no part of the corpus
has to understand two unit ontologies.

### The JSON side, not yet landed

The projector work is on hold, so `schemas/region-allocation.schema.json` is
unchanged — its `serviceLanes` items are `additionalProperties: false` and
carry no unit fields yet. The intended shape, ready to lift:

```json
"unit": {
  "type": "object",
  "required": ["system", "code"],
  "additionalProperties": false,
  "properties": {
    "system":  { "type": "string", "format": "uri" },
    "code":    { "type": "string", "minLength": 1 },
    "display": { "type": "string" },
    "bridgesToUcum": { "type": "string", "minLength": 1 }
  }
},
"axis": {
  "type": "object",
  "required": ["index", "name", "canonicalUcum", "acceptedUcum",
               "quantityKind", "conversionPolicy", "scaleType"],
  "additionalProperties": false,
  "properties": {
    "index":            { "type": "integer", "minimum": 0 },
    "name":             { "type": "string", "minLength": 1 },
    "canonicalUcum":    { "type": "string", "minLength": 1 },
    "expectedUcum":     { "type": "string", "minLength": 1 },
    "acceptedUcum":     { "type": "array", "items": { "type": "string" },
                          "minItems": 1, "uniqueItems": true },
    "quantityKind":     { "type": "string", "format": "uri" },
    "qudtUnitIri":      { "type": "string", "format": "uri" },
    "conversionPolicy": { "enum": ["none", "linear", "affine", "prohibited"] },
    "scaleType":        { "enum": ["ratio", "interval", "ordinal", "nominal"] }
  }
}
```

Machine metadata takes the same `axis` annotations. `schemas/machine.schema.json`
is permissive at the top level (`additionalProperties: true`) and declares no
`metadata` properties, so adding them is non-breaking — but also unvalidated
until the schema names them.

## Why SHACL rather than OWL

Not a replacement — the other half. OWL is open-world and does deduction; SHACL
is closed-world and does validation. Guardrails are the second question.

The decisive difference for a boundary is the output. A reasoner returns a
global verdict: the ontology is or is not consistent. It cannot say which node
broke which constraint. A [SHACL](https://www.w3.org/TR/shacl/) validation
report (W3C Recommendation, 20 July 2017) is itself an RDF graph, one result
per violation, each carrying `sh:focusNode`, `sh:resultPath`,
`sh:sourceConstraintComponent` and `sh:resultMessage`. An admission decision
needs the per-node result; a global verdict is a smoke alarm for the whole
building.

SHACL also expresses constraints OWL cannot express as *refusals* rather than
classifications: `sh:minInclusive`/`sh:maxInclusive` for unit bounds,
`sh:pattern` for id form, `sh:in` for closed enums, and `sh:closed` for "no
undeclared properties" — which is the entire no-unexpected-fields guarantee at
an ingress boundary.

What stays in OWL: the vocabulary, subsumption (`re:LifeSafetySequence` via
`owl:equivalentClass` is genuine deduction), and CI-time consistency through
ROBOT/HermiT. Keep all of it.

**Version caution:** this contract targets SHACL Core and SHACL-SPARQL as
published in the 2017 Recommendation. The SHACL 1.2 family (Core, Node
Expressions, Rules, Profiling, User Interfaces) is at Working Draft as of
August 2026. Do not take a dependency on 1.2 features.

## Where lane contracts live

**Semantics are a sidecar; allocation is untouched.**

`domains/region-allocation.json` remains the single authority on which span of
the universal vector belongs to whom. `domains/lane-contracts.json`
(`schemas/lane-contract.schema.json`) carries what those spans *mean* — per
position: name, unit, quantity kind, value domain, conversion policy and scale
type. The two are separate files with separate schemas so that neither can
quietly become the other's authority, and
`tests/contracts/lane_contracts_test.py` gates the separation: a service lane
whose offset or length drifts from the allocation fails.

**A lane is a region, not a machine.** 1,185 machines carry an
`openClawProjection`, but they land on 983 distinct write-back regions —
several machines legitimately read one externally-written lane. Modelling per
machine would invent lanes that overlap by construction.

**Axes carry only what varies.** Position and meaning live on the axis; the
unit contract comes from a named `derivationProfile`. That keeps a rule change
one edit rather than 3,617, keeps the rule legible rather than buried in
thousands of copies, and took the sidecar from 2.0 MB to 625 KB. The projector
resolves an axis as its lane's profile overlaid with the axis's own overrides.

### Derivation

`scripts/backfill-lane-contracts.py` derives from evidence, never from the
`normalization` label alone — the label is contradicted by the data often
enough not to be trusted on its own. The evidence is the label,
`perceptualMapping.bitsPerElement`, and the values the machine's own sequence
vectors actually contain:

| label | bits | values | scale | policy | domain |
| --- | ---: | --- | --- | --- | --- |
| `machine-native-binary` | 1 | `{0,1}` | nominal | prohibited | `[0,1]` |
| `machine-native-ordinal` | 4 | `{0..3}` | ordinal | prohibited | `[0..3]` |
| `machine-native-scalar` | 8 | 0..1 continuous | ratio | none | 0..1 |

All three are dimensionless — UCUM `1`, `qkind:Dimensionless`,
`unit:UNITLESS`. A machine-native ordinal or normalized index is not a physical
quantity, which is why the categorical cases prohibit conversion outright.

**Anything the evidence does not settle goes to `review` rather than being
guessed.** A fabricated unit sitting behind a guardrail is worse than an absent
one: the guardrail is the thing that is supposed to be trustworthy.

Current state — 990 lanes, 987 annotated (4079 positions),
3 in review:

| reason | lanes | |
| --- | ---: | --- |
| `physical-units-need-owner` | 3 | `agent-completion-risk`, `healthkit-activity`, `healthkit-steps` — no machine input region covers them, so there is no corpus evidence for what their positions mean |

The other five service lanes are derived: where a machine's input region covers
a lane, that machine's `inputSemantics` already names those positions, and
slicing it at the lane's offsets recovers the axes. `semanticsDerivedFrom`
records which machine each came from.

**The 42 label/width contradictions are resolved rather than deferred.** Those
machines declare `machine-native-binary` while carrying 8-bit elements and
continuous values in `[0,1]` — the same distribution as the declared scalars.
The width and the values agree with each other and disagree with the label, so
the positions are read as scalars under a `machine-native-binary/8` profile and
the lane is marked `labelInconsistent`. Nothing edits machine JSON to force the
question; the corpus review decides which side to correct.

### Enforcement staging

Every lane declares an `enforcement` stage, and the runtime maps it: **block**
refuses per the fail-closed rules, **warn** admits and counts, **observe**
records only.

| stage | lanes | |
| --- | ---: | --- |
| block | 10 | the life-safety lanes — a refusal there is the cheaper error |
| warn | 977 | everything with a settled contract |
| observe | 3 | contracts the evidence did not settle; blocking on a contract nobody has agreed is worse than not having one |

Staged in the corpus rather than in per-runtime configuration, so four runtimes
cannot drift into staging it differently.

### One region, one contract

A region declared twice — as a service lane and as a machine input — would give
the same cells two contracts and silently lose one when keyed for the runtime.
`acp-openclaw-completion` at 4210 is also `OpenClawCompletionE2E`'s input
region; the two are merged, with both provider classes on one lane and the
other id kept in `alsoDeclaredAs`. A contract test refuses any two lanes
claiming the same span.

### The runtime decision table

`scripts/compile-decision-table.py` emits `semantics/lanes/decision-table.json`:
the guardrail with every rule reduced to a lookup or a comparison.

```
CI            reasoner + SHACL over the lane graph   correctness
engine load   decision-table.json                    speed
push cycle    region lookup + bounds test            hot path
```

Keyed by `"offset:length"` — three regions in this corpus share an offset with
a different width, so offset alone does not identify a lane. Egress rules that
do not vary per lane travel in their own block, so a runtime does not need
`re-core.ttl` to evaluate a dispatch: the autonomy ranks, the 17 canonical
action codes with their consequence classes, and the escalation invariant.

A contract test asserts the table covers every annotated lane. A lane the
shapes validate but the table omits is a lane with no guardrail at runtime,
which is the failure this whole layer exists to prevent.

### An ingress lane is written from two directions

Worth stating plainly, because two earlier drafts of this contract got it
wrong. An ingress lane has **two classes of writer**:

- **external providers** — OpenClaw/ACP, HealthKit, localAI and the rest. This
  is what makes the lane *ingress*, and `reg:permittedProvider` lists them.
- **machine outputs** — `M1(output i)` feeding `M2(input j)` is how this
  perceptual space composes. `reg:machineWriter` names them.

The second is not an edge case. **703 of 983 lanes have at least one machine
writer**, 669 machine output regions equal a machine input region exactly, and
**2,835 of 4,005 lane cells are contended**. Contention is the normal state of
an ingress lane, not an exception to it.

**Definition.** Given a Reality Event `E = {c1 … cn}`, a cell `ci` is
*contended* when more than one writer competes for `ci`'s **next value** —
`M1(j)` and `M2(l)` both targeting `ci`. It is a property of a cell and its
writers, not of how two regions happen to overlap. Two earlier drafts of this
contract used "shared cell" for region-against-region overlap, which is a
different and much smaller set: 20 pairs against the registry's 2,837 cells.
Deriving the definition above from the corpus reproduces
`domains/arbitration-registry.json` exactly — 2,837 cells, none extra, none
missing — and `tests/contracts/lane_contracts_test.py` gates that agreement, so
a registry gone stale against the machines is caught rather than trusted.

So overlap is not the question and geometry is not the test. The first draft of
`IngressLaneShape` refused overlapping lanes outright, which would have rejected
the corpus's correct design; the second replaced that with a lane-against-lane
overlap check, which saw 20 pairs where the registry records 2,837 contended
cells — it was still measuring geometry, and still missing the machine writers
entirely.

What `docs/ARBITER_CONTRACT.md` calls a corpus error is a *contended* cell —
one with more than one writer — carrying **no declared resolution**. The
guardrail therefore constrains the declaration:

| | |
| --- | --- |
| a lane with a `reg:machineWriter` | must assert `reg:contentionArbitrated true` |
| a lane with `reg:contendedCellCount > 0` | must name its `reg:arbitrationRule` |
| a lane asserting arbitration with neither | warns — the declaration describes nothing |

`domains/arbitration-registry.json` holds the per-cell resolution itself: 2,837
cells, of which 2,796 have both an `acp` writer and a `machine` writer, under
PRECEDENCE. Every contended cell in the current corpus is declared there, which
is why `contention-undeclared` has zero members — an accurate statement about
this corpus rather than a silence.

## Implementation status

Written and gated:

- `semantics/shapes/re-guardrails.shacl.ttl` — vocabulary, SOSA alignment, the
  UCUM/QUDT unit contract, corpus-time lane shapes, ingress shapes, egress
  shapes.
- `semantics/shapes/fixtures/` — lane registry fixture and 47-case parity suite.
- `semantics/ontology/qudt-subset.ttl` — pinned QUDT v3.5.0 extraction, via
  `scripts/extract-qudt-subset.py`.
- `scripts/ucum.py` — canonicalizer, with `tests/contracts/ucum_test.py`.
- `domains/lane-contracts.json` — the semantics sidecar, via
  `scripts/backfill-lane-contracts.py`, with
  `tests/contracts/lane_contracts_test.py`.
- `scripts/validate_guardrails.py`, `scripts/validate-guardrails.sh`.

Not yet written — in dependency order:

1. **The lane projector.** `scripts/project-lanes.py`, consuming
   `region-allocation.json` (allocation) plus `lane-contracts.json`
   (semantics) plus the corpus, emitting the lane graph the shapes validate.
   Byte-deterministic with `--check`, mirroring `generate-owl.py`.
   `sharedOutputLanes` and `interDomainBuses` are machine-to-machine merges and
   are explicitly out of scope: they are not ingress.
2. **Life-safety lane derivation.** `reg:lifeSafetyLane` computed from the
   corpus — a lane feeding the input region of a machine carrying an
   `re:LifeSafetySequence` — not hand-flagged. This is the one flag whose being
   wrong is a safety issue.
3. **Resolving the 98 review lanes**, which needs domain owners rather than
   tooling.
4. **Per-lane severity configuration**, so the observe→warn→block staging can
   advance domain by domain.
5. **The compile step** in each runtime: shapes → decision table at load.
6. **Porting `owl_semantics_test.py`** to shapes.
7. **Wiring** `validate-guardrails.sh` into `npm run validate` and the
   `RealityEngine_CI` gate list in `INTEGRATED_SPECIFICATION.md`.

Deferred by decision: adding unit fields to
`schemas/region-allocation.schema.json` and `schemas/machine.schema.json`. The
sidecar makes them unnecessary for now, and the full corpus review will cover
both files together.
