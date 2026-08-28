# Semantic Audit Contract (roadmap milestone M5)

Last reviewed: 2026-07-29

Single source of truth for the audit records emitted by the PE→RE→PE cycle
and the HTTP surface that exposes them, across the C++, Lisp, Scala, and
TypeScript runtimes. Record types correspond to the PROV-aligned classes in
`semantics/ontology/re-core.ttl` (`re:PerceptionEvent`,
`re:SequenceObservation`, `re:DispatchRecord`); IRIs join runtime behavior to
the generated machine ABoxes with no name matching.

## Surface

Every RE and PE service exposes:

```
GET /api/audit/semantics?limit=N
→ { "records": [ ...oldest-to-newest... ], "count": <int> }
```

- Backing store: in-memory ring buffer, capacity ≥ 1000, non-persistent
  (v1 — durable ledgers may replace this without changing the shape).
- `limit` defaults to 100, capped at buffer capacity.
- Empty buffer → `{ "records": [], "count": 0 }` (200, never 404).

## IRI construction

From `semantics/abox-manifest.json`: a machine's `iri` is
`<base>#machine`; `base` is everything before the `#`. Local names are the
generator's `sanitize()` of the corpus ids (`[^A-Za-z0-9_-]` → `_`):

- sequence: `<base>#seq-<sequenceId>`
- step: `<base>#step-<vectorId>`
- determination: `<base>#out-<outputVectorId>`

Records carry raw ids alongside IRIs so auditors can fall back when a corpus
revision changes the manifest.

## Record shapes

### re:SequenceObservation — emitted by RE

When a critical event sequence advances to (or completes at) a step during
processing:

```json
{
  "type": "re:SequenceObservation",
  "at": 1690000000000,
  "machineId": "machine-falldetection",
  "machineName": "Fall Detection",
  "machineIri": "https://realityengine.example.org/machines/health-personal/FallDetection#machine",
  "sequenceId": "fall-confirmed",
  "sequenceIri": "https://realityengine.example.org/machines/health-personal/FallDetection#seq-fall-confirmed",
  "stepId": "fall-conf-v6",
  "stepIri": "https://realityengine.example.org/machines/health-personal/FallDetection#step-fall-conf-v6",
  "completed": true,
  "determinationIri": "https://realityengine.example.org/machines/health-personal/FallDetection#out-fall-conf-out",
  "actionCode": "emergency-dispatch",
  "ragStatus": "RED"
}
```

- One record per step match; `completed` is true when the step emits output
  vectors, and only then are `determinationIri`/`actionCode`/`ragStatus`
  present (from the first emitted output).
- `machineIri`/`sequenceIri`/`stepIri` are null when the machine is absent
  from the semantics manifest (ad-hoc imports); ids are always present.

### re:PerceptionEvent — emitted by PE

When the PE writes a source's data toward a machine's input region (push,
sensor update, signal ingest):

```json
{
  "type": "re:PerceptionEvent",
  "at": 1690000000000,
  "sourceId": "source-abc",
  "machineName": "Fall Detection",
  "machineIri": "https://realityengine.example.org/machines/health-personal/FallDetection#machine",
  "offset": 3813,
  "length": 2
}
```

- `machineName`/`machineIri` are best-effort (null when the PE cannot map the
  region to a machine); `offset`/`length` always describe the write.

### re:DispatchRecord — emitted by PE dispatch ledgers

Ledger entries gain a `semantics` object linking the dispatched action to the
corpus:

```json
{
  "...existing ledger fields...": "unchanged",
  "semantics": {
    "machineIri": "https://realityengine.example.org/machines/health-personal/FallDetection#machine",
    "sequenceIri": "https://realityengine.example.org/machines/health-personal/FallDetection#seq-fall-confirmed",
    "actionCode": "emergency-dispatch"
  }
}
```

Runtimes without a dispatch ledger omit this record type until one exists.

## Audit invariants (checked by RealityEngine_CI)

1. Driving the Fall Detection confirmed-fall input sequence
   (`[0,0]→[1,0]→[2,0]→[3,0]→[3,1]→[3,2]→[3,3]`) through an RE must produce a
   `re:SequenceObservation` with `completed: true`, `stepIri` ending
   `#step-fall-conf-v6`, `determinationIri` ending `#out-fall-conf-out`, and
   `actionCode: "emergency-dispatch"`.
2. All IRIs must share the machine's manifest `iri` base.
3. A dispatched escalation action whose determination is not RED is an
   invariant violation (`re:EscalationDetermination`).
