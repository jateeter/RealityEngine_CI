# Perception Engine Metrics Contract

Last reviewed: 2026-10-08

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
> the **whole exposition** (core gauges, `semantic_*` block, `mqtt_*` block)
> must be byte-identical across runtimes given identical engine state.
> Without `--with-values` the verifier drops sample values and compares the
> structure: names, HELP/TYPE wording, label sets and order, series order.

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

### MQTT bridge

Emitted after the semantic block, in this order. Same names, HELP text and
order as the TypeScript PE, which introduced them.

| Metric | Type | Meaning |
|---|---|---|
| `mqtt_bridge_enabled` | gauge | a bridge is configured (1/0) |
| `mqtt_bridge_connected` | gauge | the bridge is connected to its broker (1/0) |
| `mqtt_messages_received_total` | counter | PUBLISH messages received |
| `mqtt_messages_mapped_total` | counter | rule matches that mapped to a region |
| `mqtt_messages_rejected_total` | counter | rule matches rejected by extract/normalize/length |
| `mqtt_messages_unmatched_total` | counter | messages whose topic matched no rule |
| `mqtt_pushes_triggered_total` | counter | perceive pushes triggered by MQTT ingest |
| `mqtt_mappings_loaded` | gauge | mapping rules in the registry |

**Exact HELP strings** (part of the contract — copy verbatim):

```
mqtt_bridge_enabled            MQTT bridge is configured (1) or disabled (0).
mqtt_bridge_connected          MQTT bridge is currently connected to the broker (1/0).
mqtt_messages_received_total   Total MQTT PUBLISH messages received.
mqtt_messages_mapped_total     Total messages successfully mapped to a region.
mqtt_messages_rejected_total   Total messages rejected by mapping/normalize.
mqtt_messages_unmatched_total  Total messages whose topic matched no rule.
mqtt_pushes_triggered_total    Total perceive pushes triggered by MQTT ingest.
mqtt_mappings_loaded           Number of mapping rules in the registry.
```

- **Disabled bridge:** emit `mqtt_bridge_enabled 0` and `mqtt_bridge_connected 0`
  and nothing else. The six other series appear only when a bridge is
  configured. That is configuration, not traffic, so engines launched alike
  emit the same set.
- **Mapped and rejected count per rule.** One PUBLISH fans out to every rule
  whose `topicFilter` matches, so a single message can add several to either.
- **A push is triggered only by a mapped message.** A rejected one wrote
  nothing, so it must not step the engine (RealityEngine_Scala#188 brought
  Scala into line with C++, LSP and TypeScript).
- `verify-metrics-parity.sh` requires the two gauges on every PE.

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

After deployment the engines are not empty, and not equally so: the regression
lane's HealthKit leg posts to one PE, and an integration that fails on one
runtime emits nothing there. Which `integration` / `rag` series exist is then
state. `verify-metrics-parity.sh` therefore compares a multi-series counter only
for label values every PE has emitted, and names the rest as `STATE`; everything
else, including HELP/TYPE wording, label sets and order for shared series, stays
byte-strict. `--with-values` asserts equal state and compares everything.

## Verification

| Check | Where |
|---|---|
| endpoint present, 200, parseable | `verify-metrics-parity.sh` |
| `semantic_*` and MQTT gauges present on every PE | `verify-metrics-parity.sh` |
| whole exposition byte-identical after runtime-label normalization | `verify-metrics-parity.sh` |
| counters move as records are emitted | audit-chain e2e drives a push, then re-scrapes |
