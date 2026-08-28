# Perception Engine Metrics Contract

Last reviewed: 2026-07-31

Single source of truth for the Prometheus exposition served by every
Perception Engine runtime (C++, Lisp, Scala, TypeScript) at
`GET /api/metrics`. It exists so the **Semantic Guardrails** dashboard
(RealityEngine_CI `config/dashboards/semantic-guardrails.json`) shows the same
series regardless of which PE is active, and so metric drift between runtimes
is a test failure rather than a dashboard mystery.

Companion to `docs/SEMANTIC_AUDIT_CONTRACT.md`, which defines the audit
records these metrics count.

## Surface

```
GET /api/metrics
→ 200, Content-Type: text/plain
```

Every PE must serve this path. A PE that cannot resolve the corpus semantics
manifest still serves the endpoint, reporting `semantic_manifest_available 0`.

## Byte equivalence — what it means here

Metrics carry a `runtime` label that is necessarily different per engine
(`cpp`, `lsp`, `scala`, `ai`), so raw responses can never be byte-identical.
The contract is therefore:

> After replacing the value of the `runtime` label with a fixed placeholder,
> the **`semantic_*` block** of the exposition must be byte-identical across
> runtimes given identical engine state.

That normalization is the only permitted difference. Ordering, spacing,
`# HELP` / `# TYPE` wording, label order, and number formatting must match
exactly. `RealityEngine_CI/scripts/verify-metrics-parity.sh` enforces this.

## Exposition rules

1. Each metric emits exactly three lines, in this order:
   ```
   # HELP <name> <help text>
   # TYPE <name> <gauge|counter>
   <name>{<labels>} <value>
   ```
   A metric with multiple label sets repeats all three lines per series, in
   the order given by rule 4 (this is intentionally verbose but keeps every
   runtime's writer trivial and identical).
2. Labels are rendered `key="value"`, comma-separated, **sorted by key**.
   The `runtime` label is always present, so it sorts among the others
   (`integration` < `rag` < `runtime`).
3. Values are integers rendered without a decimal point or exponent. Counters
   are monotonic for the process lifetime; gauges are point-in-time.
4. Multi-series metrics are emitted with label values sorted ascending as
   byte strings (`healthkit` < `mqtt` < `unattributed`).
5. The block ends with a single trailing newline.

## Required metrics

### Core engine gauges

| Metric | Type | Meaning |
|---|---|---|
| `perception_engine_sources_total` | gauge | registered sources |
| `perception_engine_global_step` | gauge | pushes since start |
| `perception_engine_vector_size` | gauge | configured vector dimension |
| `perception_engine_last_push_ms` | gauge | wall clock of last successful push, 0 if never |

### Semantic guardrails

| Metric | Type | Labels | Meaning |
|---|---|---|---|
| `semantic_manifest_available` | gauge | — | corpus semantics manifest resolved (1/0) |
| `semantic_manifest_machines` | gauge | — | machines carrying a semantic identity |
| `semantic_audit_buffer_records` | gauge | — | `re:PerceptionEvent` records in the ring buffer |
| `semantic_perception_events_total` | counter | `integration` | perception events emitted |
| `semantic_perception_events_iri_joined_total` | counter | `integration` | of those, ones that resolved to a corpus ABox IRI |
| `semantic_dispatch_records_total` | counter | — | dispatch records created with a semantics link |
| `semantic_dispatch_records_iri_joined_total` | counter | — | of those, ones with a resolvable machine IRI |
| `semantic_escalation_dispatches_total` | counter | `rag` | escalation-class dispatches by RAG status |

**Exact HELP strings** (these are part of the contract — copy verbatim):

```
semantic_manifest_available            Corpus OWL semantics manifest resolved (1/0).
semantic_manifest_machines             Machines carrying a semantic identity in the manifest.
semantic_audit_buffer_records          re:PerceptionEvent records held in the audit ring buffer.
semantic_perception_events_total       re:PerceptionEvent records emitted, by originating integration.
semantic_perception_events_iri_joined_total  Perception events whose machine resolved to a corpus ABox IRI.
semantic_dispatch_records_total        Dispatch records created with a semantics link.
semantic_dispatch_records_iri_joined_total   Dispatch records whose machine resolved to a corpus ABox IRI.
semantic_escalation_dispatches_total   Escalation-class actions dispatched, by RAG status of the determination.
```

## Semantics of the counters

- **`integration`** attributes a write to the upstream that produced it:
  `healthkit`, `mqtt`, `acp`, `openai`, `ollama`, `localai`, or the source
  type when no origin is recorded. A source with no attribution uses
  `unattributed` — a rising count there means a new ingress path needs an
  origin tag, so the label must never be omitted.
- **`rag`** is the RAG status of the determination behind an escalation:
  `RED`, `AMBER`, `GREEN`, or `unstated`. `unstated` is tracked separately
  because `re:EscalationDetermination` is open-world: an absent status is
  consistent (a reasoner infers RED), while an explicit non-RED is a
  violation. Dashboards alarm on the latter only.
- Runtimes with no dispatch ledger still emit the two
  `semantic_dispatch_records_*` counters at `0`, so the family is present and
  the block stays byte-equivalent.

## Zero-state requirement

A freshly started PE that has taken no pushes must emit every metric above,
with the multi-series counters emitting **no series** (the `# HELP`/`# TYPE`
lines are still absent for those — a counter with no observed label values
emits nothing). This keeps the zero state identical across runtimes and is
what the parity check compares in CI, where engines start empty.

## Verification

| Check | Where |
|---|---|
| endpoint present, 200, parseable | `verify-metrics-parity.sh` |
| `semantic_*` block byte-identical after runtime-label normalization | `verify-metrics-parity.sh` |
| counters move as records are emitted | audit-chain e2e drives a push, then re-scrapes |
