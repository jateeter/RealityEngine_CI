# Domain Perceptual Space Remap

This remap isolates domain machine sets in the Perceptual Engine input space
where possible, while preserving intentional output-to-input overlaps as machine
interconnects. Single-domain components are packed into domain blocks. Components
that contain cross-domain overlap are packed into a dedicated cross-domain bridge
block.

Run:

```bash
node scripts/remap_machine_connection_matrix_by_domain.mjs
```

Use `--dry-run` to inspect the proposed layout without rewriting machine JSON.

## Current Layout

The current universe contains `1006` mapped machines and remains packed into
`4109` used vector positions with no holes.

| Block | Vector range | Length | Components |
| --- | ---: | ---: | ---: |
| agriculture | `[0:256]` | 256 | 61 |
| ai-services | `[256:316]` | 60 | 12 |
| built-space | `[316:920]` | 604 | 151 |
| community-services | `[920:1344]` | 424 | 102 |
| data-center | `[1344:1569]` | 225 | 56 |
| digital-logic | `[1569:1731]` | 162 | 57 |
| health-services | `[1731:1931]` | 200 | 50 |
| healthcare | `[1931:2043]` | 112 | 26 |
| legal-services | `[2043:2843]` | 800 | 200 |
| life-balance | `[2843:3243]` | 400 | 100 |
| transportation | `[3243:3811]` | 568 | 142 |
| cross-domain bridge | `[3811:4109]` | 298 | 55 |

This layout keeps each domain's local input/output flow contiguous, while the
bridge block makes cross-domain PE.xRE.xPE throughput visible and measurable.

## Interconnect Gauge

The remap identifies interconnects by shared perceptual coordinates where at
least one machine writes an output lane that another machine reads as an input
lane.

Current throughput gauge:

- Total mapped regions: `1094`
- Connected regions: `567`
- Total machine-level interconnects: `1293`
- Cross-domain machine-level interconnects: `96`
- Cross-domain interconnect ratio: `7.42%`

The searchable compendium reports pairwise interval overlaps and currently sees
`1361` machine-level interconnections and `135` cross-domain interconnections.
The remapper gauge is stricter: it counts exact shared regions in the packed
matrix.

## Life Balance Domain

The life-balance domain contains `100` generated `LBL` machines. It models
lifestyle-psychiatry operations for intake, nutrition, sleep, movement, stress
resilience, psychiatric care, adolescent/family support, testing and monitoring,
connection/harm reduction, and projection automation.

Each `LBL` machine includes five or more startup-loadable `inputSequences`:

- `care-team-review`: two-step concern escalation to `[1,0,0,0]`
- `lifestyle-plan-adjust`: barrier or preference adjustment to `[0,1,0,0]`
- `monitoring-task`: data-gap or follow-up tasking to `[0,0,1,0]`
- `stable-balance`: monitored stable state to `[0,0,0,1]`
- `baseline-no-output`: initial observation with no expected output

Five domain e2e sequences are embedded in `LBL096` through `LBL100` for
metabolic mood projection, adolescent sleep/school projection, medication and
lifestyle review, stress/connection projection, and command-center stabilization.
The domain-local block is `[2843:3243]`; cross-domain bridge regions connect
life-balance with health-services, healthcare, community-services, and
ai-services.

## Community Services Expansion

The community-services domain now contains `102` machines: the original `12`
service-delivery machines plus `90` generated `CSX` machines.

The generated machines cover:

- Health and human services intake, benefits eligibility, Medicaid/SNAP/TANF/WIC
  navigation, document readiness, and case completion.
- Behavioral health and crisis response, including 988 handoffs, mobile crisis,
  substance-use outreach, youth crisis routing, and follow-up.
- Law enforcement and public safety coordination for non-emergency triage,
  community policing, hotspots, domestic violence, missing vulnerable persons,
  event safety, evidence workflow, and code enforcement.
- Courts, diversion, victim services, reentry, juvenile diversion, and fine/fee
  relief.
- Homelessness outreach, shelter operations, coordinated entry, housing voucher
  navigation, rapid rehousing, supportive housing, hygiene access, weather
  center activation, and encampment risk.
- City service operations and executive optimization for 311, sanitation,
  streetlights, sidewalk accessibility, public restrooms, libraries, parks,
  donations, funding, privacy/consent, service equity, and community digital
  twin projections.

Each `CSX` machine includes five `inputSequences`:

- `urgent-response`: two-step escalation to `[1,0,0,0]`
- `coordinate-services`: partner coordination to `[0,1,0,0]`
- `field-work-order`: mobile or field tasking to `[0,0,1,0]`
- `stable-service-path`: monitored stable path to `[0,0,0,1]`
- `baseline-no-output`: initial observation with no expected output

## Cross-Domain Bridge Regions

The community-services expansion adds bidirectional bridge lanes to
health-services and transportation.

| Bridge range | Crossed domains | Representative flow |
| --- | --- | --- |
| `[3811:3815]` | healthcare <-> life-balance | Patient wellness and outcome-score synthesis |
| `[3815:3819]` | community-services <-> health-services <-> life-balance | Housing voucher navigation, community health outcomes, and temperament review |
| `[3827:3831]` | community-services <-> health-services <-> life-balance | Unsheltered health referral, care coordination, and therapy homework |
| `[3831:3839]` | community-services <-> health-services <-> life-balance | Behavioral health routing, escalation, and sleep-risk review |
| `[3847:3855]` | community-services <-> health-services <-> life-balance | Learning-system routing, command center projection, and weekly balance projection |
| `[3855:3907]` | community-services <-> transportation | Fleet, safety, shelter, emergency, rider, and city-service coordination |
| `[3907:3923]` | data-center <-> digital-logic <-> healthcare | Data-center operations and healthcare/digital infrastructure bridge |
| `[3931:3939]` | ai-services <-> healthcare <-> life-balance | Patient wellness, wellness analytics, and plan adjustment |
| `[3939:3955]` | ai-services <-> healthcare <-> life-balance | Care transition, stress/connection, and AI service bridge |
| `[3955:4109]` | agriculture/data-center <-> digital-logic | Operational infrastructure and logic-pattern bridge regions |

Other bridge regions preserve existing agriculture/digital-logic,
data-center/digital-logic, and ai-services/healthcare crossings.

## Inefficiency Points

The expanded graph is materially better for PE.xRE.xPE bridge validation, but
several points still deserve attention:

- Cross-domain traffic is now concentrated in community-services, health-services,
  life-balance, transportation, digital-logic, agriculture, data-center,
  ai-services, and healthcare. Legal-services and built-space remain mostly
  domain-isolated.
- Health-services and transportation bridge fan-out is high: several shared
  regions feed multiple downstream machines. This is useful for throughput tests,
  but it should be watched for noisy output attribution in diagnostics.
- The bridge block is contiguous and compact, but still small compared with total
  domain-local space. Multi-domain performance should be measured separately from
  domain-local throughput.
- Generated community-services machines use consistent 4D lanes. If future live
  sensors need richer representation, the dynamic vector-management work should
  allocate expanded lanes without disturbing existing bridge semantics.

## Suggested Throughput Tests

Use the bridge block to gauge PE.xRE.xPE throughput:

- Replay one domain-local input sequence in each domain block and measure emitted
  output count per push.
- Replay each community-services/life-balance bridge region in `[3811:3855]`
  and measure propagation latency from producer output to downstream
  health-services, healthcare, or life-balance consumer activation.
- Compare cross-domain bridge throughput against total interconnect throughput:
  `crossDomainMachineInterconnects / totalMachineInterconnects`.
- Activate all community-services bridge producers in one PE push and verify
  health-services and transportation consumers receive the merged reality vector
  on the next push.
- Add regression tests that fail if a cross-domain remap moves bridge regions out
  of the bridge block or creates holes in the domain-local blocks.

## Remapping Philosophy

The remapper preserves behavior by moving contiguous coordinate components, not
individual coordinates. This matters because every machine input/output mapping
must remain contiguous after remap. Existing output-to-input overlaps are
preserved exactly, while domain-local components are moved into domain-specific
blocks.

When new machines are added:

- Prefer allocating them inside their domain block.
- Put intentional cross-domain interconnects in the bridge block.
- Keep generated machine families stable by running the domain-aware remapper
  after generation.
- Regenerate `docs/EXAMPLE_DOMAIN_COMPENDIUM.md`.
- Validate with `make e2e-corpus` and a bridge-throughput service test.
