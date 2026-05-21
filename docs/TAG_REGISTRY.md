# workflowTag Registry

Canonical reference for `metadata.tagging.workflowTags` across all example machines.

Tags are classified into three tiers based on corpus frequency:

| Tier | Threshold | Count | Meaning |
|------|-----------|-------|---------|
| **Established** | ≥ 10 machines | 199 | Stable vocabulary; preferred for all machines |
| **Provisional** | 2–9 machines | 29 | Growing tags; promote to established at ≥ 10 |
| **Single-use** | 1 machine | ~1660 | Narrative detail; consolidate where possible |

Single-use tags are allowed for free-text detail but should be consolidated toward
established equivalents wherever a semantic match exists (see [Consolidation Rules](#consolidation-rules)).

---

## Established Tags (≥ 10 machines)

### Universal / Cross-Domain

These tags apply regardless of domain and appear on nearly every machine.

| Tag | Count | Meaning |
|-----|-------|---------|
| `ai-trigger` | 891 | Machine exposes an AI-dispatch trigger surface |
| `dispatchable-agent` | 890 | Machine acts as a dispatchable AI agent role |
| `cross-domain` | 91 | Machine operates across two or more primary domains |
| `security` | 153 | Machine has security monitoring or enforcement responsibility |
| `verification` | 150 | Machine performs correctness or compliance verification |
| `operational-management` | 50 | Machine governs day-to-day operations |
| `incident-response` | 50 | Machine participates in incident detection or escalation |
| `upgrade-cycle` | 50 | Machine manages component refresh or software upgrade cycles |
| `cleaning` | 152 | Machine is responsible for sanitation or cleaning workflows |

---

### Health Services Domain

Domain marker and public-health transformation tags.

| Tag | Count | Meaning |
|-----|-------|---------|
| `health-services-generated` | 200 | Machine belongs to the Health Services domain |
| `community-health-care-delivery` | 200 | Community-level health care delivery machine |
| `evaluation-plan` | 200 | Machine supports formal program evaluation planning |
| `logic-model` | 200 | Machine is structured around a program logic model |
| `public-health-system-transformation` | 200 | Machine advances systemic public-health improvement |

**Health Services subcategory tags** — each marks a specific program area:

| Tag | Count |
|-----|-------|
| `health-services-evaluability-readiness` | 10 |
| `health-services-interest-holder-alignment` | 10 |
| `health-services-public-health-financing` | 10 |
| `health-services-policy-implementation` | 10 |
| `health-services-workforce-development` | 10 |
| `health-services-service-delivery-models` | 10 |
| `health-services-performance-standards` | 10 |
| `health-services-community-health-outcomes` | 10 |
| `health-services-foundational-public-health-services` | 10 |
| `health-services-care-coordination` | 10 |
| `health-services-behavioral-health-integration` | 10 |
| `health-services-maternal-child-family-health` | 10 |
| `health-services-chronic-disease-prevention` | 10 |
| `health-services-environmental-health-response` | 10 |
| `health-services-emergency-preparedness` | 10 |
| `health-services-learning-health-system` | 10 |

**Health Services agent-role tags**:

| Tag | Count | Role |
|-----|-------|------|
| `community-health-worker-agent` | 20 | Community-level health worker |
| `care-coordinator-agent` | 20 | Care coordination across providers |
| `public-health-nurse-agent` | 20 | Public health nursing services |
| `behavioral-health-crisis-agent` | 20 | Behavioral health crisis response |
| `evaluation-analyst-agent` | 20 | Program evaluation analysis |
| `measure-tracker` | 20 | Performance measure tracking |
| `partner-coordination-agent` | 20 | Cross-agency partner coordination |
| `resource-dispatch-agent` | 20 | Resource allocation and dispatch |
| `quality-improvement-agent` | 20 | Quality improvement workflows |
| `benefits-navigation-agent` | 30 | Benefits navigation and eligibility |
| `psychiatric-care-agent` | 11 | Psychiatric care management |
| `water-quality` | 11 | Water quality monitoring |

---

### Life Balance Domain (Personal Health / Lifestyle Medicine)

| Tag | Count | Meaning |
|-----|-------|---------|
| `life-balance-generated` | 100 | Machine belongs to the Life Balance / lifestyle-medicine domain |
| `lifestyle-psychiatry` | 100 | Lifestyle-psychiatry methodology |
| `adolescent-psychiatry` | 101 | Adolescent psychiatric care |
| `metabolic-health` | 100 | Metabolic health monitoring or intervention |
| `cgm` | 100 | Continuous glucose monitoring integration |
| `nutrition` | 104 | Nutritional monitoring or guidance |
| `sleep` | 102 | Sleep tracking or intervention |
| `temperament-testing` | 100 | Temperament and personality assessment |
| `elder-care` | 13 | Elder care or aging-services context |
| `low-income` | 13 | Low-income population services |

**Life Balance subcategory tags**:

| Tag | Count |
|-----|-------|
| `life-balance-whole-person-intake-and-goals` | 10 |
| `life-balance-nutrition-and-metabolic-health` | 10 |
| `life-balance-sleep-and-circadian-rhythm` | 10 |
| `life-balance-movement-and-physical-health` | 10 |
| `life-balance-stress-resilience-and-psychotherapy` | 10 |
| `life-balance-medication-and-psychiatric-care` | 10 |
| `life-balance-social-connection-and-harm-reduction` | 10 |
| `life-balance-adolescent-family-and-school` | 12 |

**Life Balance agent-role tags**:

| Tag | Count | Role |
|-----|-------|------|
| `life-balance-intake-agent` | 10 | Whole-person intake |
| `life-balance-command-agent` | 10 | Life balance command orchestration |
| `nutrition-metabolic-agent` | 10 | Nutrition and metabolic health |
| `sleep-circadian-agent` | 10 | Sleep and circadian rhythm |
| `movement-health-agent` | 10 | Physical health and movement |
| `stress-resilience-agent` | 10 | Stress and psychotherapy |
| `adolescent-family-agent` | 10 | Adolescent family and school |
| `testing-personalization-agent` | 10 | Temperament-based personalization |
| `connection-harm-reduction-agent` | 10 | Social connection and harm reduction |

---

### Built Space / WELL Building Standard Domain

| Tag | Count | Meaning |
|-----|-------|---------|
| `built-space-well-generated` | 150 | Machine belongs to the Built Space / WELL Standard domain |
| `well-building-standard` | 150 | Implements WELL Building Standard concepts |
| `well-building-standard-operations` | 150 | Operational management under the WELL Standard |
| `well-operations` | 150 | Day-to-day WELL building operations |
| `occupant-health` | 150 | Occupant health and wellness |

**WELL concept tags and their corresponding agent-role + built-space-well-* subcategory tags**:

| Concept | Concept Tag | Agent Tag | Space Tag |
|---------|-------------|-----------|-----------|
| Air Quality | `air-quality` | `well-air-quality-agent` | `built-space-well-air-quality` |
| Water Quality | `water-quality` | `well-water-quality-agent` | `built-space-well-water-quality` |
| Nourishment | `nourishment` | `well-nourishment-agent` | `built-space-well-nourishment` |
| Light & Circadian | `light-and-circadian` | `well-light-agent` | `built-space-well-light-and-circadian` |
| Thermal Comfort | `thermal-comfort` | `well-thermal-agent` | `built-space-well-thermal-comfort` |
| Sound & Acoustics | `sound-and-acoustics` | `well-acoustic-agent` | `built-space-well-sound-and-acoustics` |
| Materials & Cleaning | `materials-and-cleaning` | `well-materials-cleaning-agent` | `built-space-well-materials-and-cleaning` |
| Movement & Fitness | `movement-and-fitness` | `well-movement-agent` | `built-space-well-movement-and-fitness` |
| Mind & Wellness Policy | `mind-and-wellness-policy` | `well-mind-policy-agent` | `built-space-well-mind-and-wellness-policy` |
| Community & HR | `community-and-hr` | `well-community-hr-agent` | `built-space-well-community-and-hr` |
| Occupant Feedback | `occupant-feedback` | `well-feedback-agent` | `built-space-well-occupant-feedback` |
| Performance Verification | `performance-verification` | `well-verification-agent` | `built-space-well-performance-verification` |
| Design & Biophilia | `design-and-biophilia` | — | `built-space-well-design-and-biophilia` |
| Integrative Planning | `integrative-planning` | `well-integrative-agent` | `built-space-well-integrative-planning` |

All concept/agent/space tags appear at count 10. The built-space command agent:
`built-space-command-agent` (10) — top-level orchestration for a WELL building.

---

### Transportation / Transit Fleet Domain

| Tag | Count | Meaning |
|-----|-------|---------|
| `transportation-generated` | 150 | Machine belongs to the Transportation domain |
| `public-transit` | 150 | Public transit system operation |
| `100-bus-fleet` | 150 | Applies to 100-vehicle electric bus fleet |
| `rider-experience` | 140 | Rider-facing quality and satisfaction |
| `transportation` | 16 | General transportation context |

**Transportation fleet subcategory tags**:

| Tag | Count |
|-----|-------|
| `transportation-fleet-rider-experience` | 10 |
| `transportation-fleet-vehicle-operations` | 10 |
| `transportation-fleet-cleaning-and-sanitation` | 10 |
| `transportation-fleet-security-and-safety` | 10 |
| `transportation-fleet-dispatch-and-flow-control` | 10 |
| `transportation-fleet-charging-and-fueling` | 10 |
| `transportation-fleet-depot-operations` | 10 |
| `transportation-fleet-workforce-operations` | 10 |
| `transportation-fleet-customer-communications` | 10 |
| `transportation-fleet-network-planning` | 10 |
| `transportation-fleet-asset-infrastructure` | 10 |
| `transportation-fleet-finance-and-cost` | 10 |

**Transit agent-role tags**:

| Tag | Count |
|-----|-------|
| `transit-rider-experience-agent` | 10 |
| `transit-dispatch-agent` | 10 |
| `transit-vehicle-health-agent` | 10 |
| `transit-cleaning-agent` | 10 |
| `transit-security-agent` | 10 |
| `transit-energy-agent` | 10 |
| `transit-depot-agent` | 10 |
| `transit-workforce-agent` | 10 |
| `transit-customer-comms-agent` | 10 |
| `transit-planning-agent` | 10 |
| `transit-asset-agent` | 10 |
| `transit-finance-agent` | 10 |
| `transit-command-center-agent` | 10 |

---

### Legal Services / IP Domain

| Tag | Count | Meaning |
|-----|-------|---------|
| `legal-services-generated` | 100 | Machine belongs to the Legal Services / IP domain |
| `intellectual-property` | 100 | Intellectual property management |
| `copyright` | 100 | Copyright filing or registration |
| `trademark` | 100 | Trademark prosecution or portfolio |
| `provisional-patent` | 100 | Provisional patent application workflows |
| `productization` | 100 | Product commercialization and licensing |

**Legal Services subcategory tags**:

| Tag | Count |
|-----|-------|
| `legal-services-provisional-patent-filing` | 10 |
| `legal-services-portfolio-operations` | 10 |
| `legal-services-individual-creator-services` | 10 |
| `legal-services-filing-and-portal-operations` | 10 |
| `legal-services-corporate-legal-services` | 10 |
| `legal-services-commercialization-and-enforcement` | 10 |
| `legal-services-ai-assisted-legal-operations` | 10 |

**Legal Services agent-role tags**:

| Tag | Count | Role |
|-----|-------|------|
| `product-counsel-agent` | 10 | Product and commercialization counsel |
| `docketing-agent` | 10 | Patent/trademark docketing |
| `filing-portal-agent` | 10 | USPTO/EPO portal filing |
| `ip-portfolio-agent` | 10 | IP portfolio management |
| `legal-ops-agent` | 10 | Legal operations |
| `attorney-review-agent` | 10 | Attorney review and sign-off |

---

### Community Services Domain

| Tag | Count | Meaning |
|-----|-------|---------|
| `community-services-generated` | 92 | Machine belongs to the Community Services domain |
| `city-services` | 90 | City-administered service delivery |
| `health-and-human-services` | 90 | Health and human services programs |
| `homelessness` | 90 | Homelessness prevention and services |
| `law-enforcement` | 90 | Law enforcement coordination |
| `public-safety` | 90 | Public safety services |

**Community Services subcategory tags**:

| Tag | Count |
|-----|-------|
| `community-services-benefits-and-eligibility` | 10 |
| `community-services-behavioral-health-and-crisis` | 10 |
| `community-services-law-enforcement-and-public-safety` | 10 |
| `community-services-courts-diversion-and-victim-services` | 10 |
| `community-services-homelessness-outreach` | 10 |
| `community-services-shelter-housing-and-supportive-services` | 10 |
| `community-services-city-service-operations` | 10 |
| `community-services-health-and-human-services-intake` | 12 |

**Community Services agent-role tags**:

| Tag | Count | Role |
|-----|-------|------|
| `community-intake-agent` | 10 | Community intake and assessment |
| `community-command-agent` | 10 | Community services command orchestration |
| `behavioral-crisis-agent` | 10 | Behavioral health crisis response |
| `public-safety-agent` | 10 | Public safety coordination |
| `victim-services-agent` | 10 | Victim services and support |
| `homeless-outreach-agent` | 10 | Homelessness outreach |
| `housing-services-agent` | 10 | Housing and shelter services |
| `city-operations-agent` | 10 | City service operations |

---

### Agriculture Domain

| Tag | Count | Meaning |
|-----|-------|---------|
| `agriculture-generated` | 54 | Machine belongs to the Agriculture domain |
| `agriculture-indoor-grow-house` | 27 | Indoor controlled-environment growing facility |
| `agriculture-aquaculture` | 25 | Aquaculture system operation |
| `indoor-growing` | 10 | Indoor growing environment |

---

### Data Center / Digital Logic Domain

| Tag | Count | Meaning |
|-----|-------|---------|
| `data-center-generated` | 50 | Machine belongs to the Data Center domain |
| `data-center-24x7-operations` | 50 | Continuous 24×7 data center operations |
| `data-center` | 54 | General data center context |
| `logical-infrastructure` | 52 | Logical network or infrastructure management |
| `digital-logic-generated` | 52 | Machine belongs to the Digital Logic / Primitives domain |
| `digital-logic-infrastructure` | 50 | Digital logic infrastructure |
| `asic-pattern` | 50 | ASIC or hardware pattern implementation |
| `regular-expression` | 50 | Regular-expression pattern matching |
| `kleene-plus` | 35 | Kleene-plus (one-or-more) pattern structure |
| `24x7-operations` | 151 | Continuous around-the-clock operations (also used in transit, health) |

---

## Provisional Tags (2–9 machines)

These tags are approaching established status. Prefer them over new single-use synonyms; do not create new tags that overlap with these.

### Health / Personal Care

| Tag | Count | Use when |
|-----|-------|---------|
| `health-personal-operations` | 5 | Health-personal assisted-living or care-level operations |
| `wellness` | 4 | General wellness monitoring (prefer specific subcategory) |
| `chronic-disease` | 4 | Chronic disease management |
| `mental-health` | 3 | Mental health services (non-crisis; for crisis use `behavioral-health-crisis-agent`) |
| `medication` | 9 | Medication management or adherence |
| `intake` | 8 | Intake assessment (use `life-balance-intake-agent` or `community-intake-agent` for agent roles) |
| `benefits-eligibility` | 4 | Benefits eligibility determination |
| `food-insecurity` | 2 | Food insecurity screening or intervention |
| `case-management` | 2 | Case management workflows |
| `anomaly-detection` | 9 | Anomaly or outlier detection (sensor monitoring, fall detection, trend analysis) |

### Agriculture Agents

| Tag | Count | Role |
|-----|-------|------|
| `growhouse-climate-agent` | 5 | Grow house climate control |
| `growhouse-irrigation-agent` | 5 | Grow house irrigation |
| `growhouse-ipm-agent` | 5 | Integrated pest management |
| `growhouse-crop-steering-agent` | 5 | Crop steering and yield optimization |
| `aquaculture-water-quality-agent` | 5 | Aquaculture water quality |
| `aquaculture-health-agent` | 5 | Aquaculture fish health |

### Data Center Agents

| Tag | Count | Role |
|-----|-------|------|
| `dc-facilities-agent` | 5 | Facilities management |
| `dc-power-agent` | 5 | Power distribution and UPS |
| `dc-cooling-agent` | 5 | Cooling and thermal management |
| `dc-network-agent` | 5 | Network infrastructure |
| `dc-compute-agent` | 5 | Compute node management |
| `dc-storage-agent` | 5 | Storage array management |
| `dc-security-agent` | 5 | Physical and cyber security |
| `dc-sre-agent` | 5 | Site reliability engineering |
| `dc-change-manager-agent` | 5 | Change and release management |

### General / Digital Logic

| Tag | Count | Use when |
|-----|-------|---------|
| `flip-flop` | 7 | Machine implements a flip-flop state element |
| `trigger` | 6 | Machine implements a trigger or gating condition |
| `service-delivery` | 6 | Service delivery tracking or compliance |
| `ai-workload` | 5 | AI/ML workload management (DC context) |

---

## Consolidation Rules

The `scripts/consolidate-tags.py` script enforces these rules automatically.

### Stage 1 — Remove Noise Tags

The following tag patterns are removed entirely; they are internal state codes or
function names, not taxonomy:

| Pattern | Reason |
|---------|--------|
| `ag-*` | Machine-internal agriculture state codes |
| `agx*` | Machine-internal agriculture state codes (digit-prefixed variant) |
| `agriculture-<domain>-<sub>-<detail>` (3+ segments) | Over-specific compound tags |
| `aicr-*`, `aihr-*`, `aimw-*`, `aipe-*`, `aism-*`, `aiwc-*`, `aict-*`, `air-*` | Internal state abbreviations |
| `offset`, `input`, `output`, `length`, `sequences`, `family`, `tagging` | Structurally redundant noise words |
| `activity` | Overly broad, no classification signal |

### Stage 2 — Consolidate via Prefix Matching

Tags not in the established set are matched against it with a longest-prefix rule.
For example, `built-space-well-air-quality-sensor` → `built-space-well-air-quality`.

The explicit semantic override map handles cases where the prefix rule gives the
wrong answer:

| Single-use tag (example) | → Canonical tag |
|--------------------------|-----------------|
| `healthcare-operations-*` | `health-personal-operations` |
| `anomaly-detection` variants (`fall-detection`, `in-home-monitoring`, `continuous`, `trend`) | `anomaly-detection` |
| `cooling`, `humidity`, `climate-control` | `thermal-comfort` |
| `enrollment`, `intake-assessment`, `aging-services-intake` | `intake` |
| `snap`, `wic` | `benefits-eligibility` |
| `binary` | `digital-logic-generated` |
| `network` | `logical-infrastructure` |
| `harvest` | `agriculture-generated` |
| `ai` | `ai-trigger` |
| `safety` | `security` |
| `adolescent`, `age-cohort` | `adolescent-psychiatry` |
| `adolescent-guardian-alignment`, `adolescent-mental-health-monitor`, `adolescent-safety-signal` | `life-balance-adolescent-family-and-school` |
| `nutrient-solution` | `nutrition` |
| `patient-wellness` | `wellness` |

### Stage 3 — Singular/Plural Fix (flat `tags` array)

| Before | After |
|--------|-------|
| `dispatchable-agents` | `dispatchable-agent` |
| `ai-triggers` | `ai-trigger` |

---

## Adding New Established Tags

A tag becomes established by meeting **all three** of these criteria:

1. It appears in ≥ 10 distinct machine files in `examples/machines/`.
2. It represents a stable domain concept that is unlikely to be renamed.
3. It is not a more-specific variant of an existing established tag (use the existing tag instead).

To promote a provisional tag, add it to the `ESTABLISHED` list in
`scripts/consolidate-tags.py` (sorted longest-first) and re-run the script.

To add an entirely new tag family, also add appropriate keyword entries to
`visualizer/frontend/src/components/machineDomains.ts` so the domain classifier
can recognize machines carrying the new tags.

---

## Running Consolidation

```bash
# Dry run — show how many files would change without writing
python3 scripts/consolidate-tags.py --dry-run

# Apply consolidation to all machine files
python3 scripts/consolidate-tags.py
```

The script rewrites files in place with 2-space JSON indentation and a trailing
newline, matching the format used by all other machine generation scripts.
