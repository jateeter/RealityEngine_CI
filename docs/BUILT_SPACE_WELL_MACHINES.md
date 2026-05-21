# Built-Space WELL Machines

The `BSX001`-`BSX150` machines add a Built-Space domain for buildings operating
against WELL-aligned health and wellness requirements. They model operational
tracking, verification, and predictive optimization across building systems,
occupant experience, food/water operations, policy programs, and evidence
readiness.

The machine set is based on the supplied PDF,
`Implementing and Operating the WELL Building Standard - Google Docs.pdf`, and
WELL-oriented operational concepts including Air, Water, Nourishment, Light,
Fitness/Movement, Comfort, Mind, Sound, Materials, Community, verification, and
ongoing O&M governance.

## Contract

Each `BSX` machine uses:

- Category: `built-space`
- Domain: `Built Space - WELL <workstream>`
- Input: 4D binary lane
  - health-performance signal stable
  - evidence or policy current
  - maintenance or operational drift pressure
  - occupant impact or wellness risk
- Output: 4D binary lane
  - `[1,0,0,0]` = `VERIFY_WELL_CONFORMANCE`
  - `[0,1,0,0]` = `PREDICTIVE_OPTIMIZE`
  - `[0,0,1,0]` = `OPS_WORK_ORDER`
  - `[0,0,0,1]` = `COMPLIANT_WINDOW`

Every machine includes e2e `inputSequences` for conformance verification,
predictive optimization, operations work order creation, compliant-state
confirmation, 24-hour predictive optimization, and a no-output baseline.

## Workstreams

The 150 machines are organized as 15 workstreams with 10 machines each:

- Integrative Planning
- Design And Biophilia
- Air Quality
- Water Quality
- Nourishment
- Light And Circadian
- Thermal Comfort
- Sound And Acoustics
- Materials And Cleaning
- Movement And Fitness
- Mind And Wellness Policy
- Community And HR
- Occupant Feedback
- Performance Verification
- Predictive Operations

## PDF-Derived Coverage

The generated machines explicitly cover operational needs from the PDF:

- Stakeholder charrettes, values assessment, health mission plans, and O&M
  planning.
- Letters of assurance, design/engineering/contractor verification, and
  onboarding tours.
- Acoustic criteria, STC-oriented partitions, sound masking, thermal comfort,
  water filtration, and HVAC installation quality.
- Biophilia, ceiling height, educational space allocation, materials
  transparency, and construction/cleaning controls.
- On-site performance testing for water, acoustic, thermal, air, and light
  evidence.
- Water dispenser cleaning, quarterly aerator/filter work, quarterly metals
  testing, annual reporting, record retention, and Legionella management.
- Food storage temperatures, allergen/ingredient labeling, safe food-contact
  materials, fryer oil quality, sugar/portion controls, and diet alternatives.
- Annual occupant IEQ surveys, 30-day reporting, and corrective action loops.
- Health benefits, family support, nursing breaks, sleep/travel policies, EAP
  access, volunteer time, charitable matching, and fitness opportunities.

## Predictive Interconnections

The generator connects downstream machine inputs to upstream machine output
lanes to create operational dependency chains:

- Planning readiness feeds design, air, water, movement, mind, community, and
  verification operations.
- Air and water executive signals feed comfort, sound, materials, and predictive
  operations.
- Occupant feedback feeds verification readiness and corrective-action loops.
- Verification dashboards feed predictive operations and the Built Space Command
  Center.

Each machine carries:

- `aiTrigger`: stable WELL workstream/focus trigger key.
- `predictiveOptimizationTrigger`: key for building optimization orchestration.
- `dispatchableAgent`: the AI agent responsible for the next action.
- `upstreamMachine`, `upstreamOutputRegion`, and `downstreamMachines` metadata
  documenting the operational interconnect pattern.

## Domain Placement

After running the domain-aware remapper, Built-Space occupies:

```text
built-space [316:920]
```

The compact length is `604` positions because operational interconnections reuse
upstream 4D output lanes as downstream 4D input lanes.

## Regeneration

Run:

```bash
python3 scripts/generate_built_space_well_machines.py
node scripts/remap_machine_connection_matrix_by_domain.mjs
```

Then validate with:

```bash
npm run build
make -C ../RealityEngine_CPP e2e
```
