# Machine Tagging

Every example machine uses a managed tag structure in `machine.metadata`.

## Shape

| Field | Purpose |
| --- | --- |
| `metadata.tags` | Backwards-compatible flattened search index. |
| `metadata.tagging.schemaVersion` | Tag schema version. |
| `metadata.tagging.managedBy` | Script that owns regeneration. |
| `metadata.tagging.primaryDomain` | Normalized primary domain/category. |
| `metadata.tagging.domainTags` | Domain and workstream tags. |
| `metadata.tagging.family` | Machine family, usually derived from filename prefix. |
| `metadata.tagging.machineCode` | Stable machine code derived from filename. |
| `metadata.tagging.capabilityTags` | Operational capabilities such as monitoring, routing, optimization, projection, compliance, or maintenance. |
| `metadata.tagging.workflowTags` | Topic and workflow search terms. |
| `metadata.tagging.integrationTags` | AI trigger, dispatchable-agent, machine-interconnect, and cross-domain tags. |
| `metadata.tagging.validationTags` | Startup, CES, and authored input-sequence coverage tags. |
| `metadata.tagging.allTags` | Canonical flattened tag set copied into `metadata.tags`. |

## Management

Run after adding or regenerating machines:

```bash
node scripts/manage_machine_tags.mjs
node scripts/generate_example_machine_compendium.mjs
```

Validate without rewriting:

```bash
node scripts/manage_machine_tags.mjs --check
```

The tag manager normalizes tags to lowercase ASCII kebab-case and derives
consistent domain, family, integration, and validation tags from each machine's
metadata, filename, perceptual interconnects, CES sequences, and input
sequences.

## workflowTag Vocabulary

See [TAG_REGISTRY.md](TAG_REGISTRY.md) for the full canonical tag vocabulary,
including established (≥ 10), provisional (2–9), and single-use tiers, plus
consolidation rules and governance.
