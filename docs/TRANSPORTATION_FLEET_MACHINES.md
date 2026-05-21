# Transportation Fleet Machines

The `TFX001`-`TFX150` machines add a public transportation domain for a
100-bus 24/7 operation. The examples cover rider experience, vehicle operations,
maintenance, cleaning, security, dispatch, energy/fueling, depot operations,
workforce, compliance, customer communications, planning, infrastructure,
finance, and executive optimization.

## Contract

Each `TFX` machine uses:

- Category: `transportation`
- Domain: `Transportation Fleet - <workstream>`
- Fleet size metadata: `100`
- Input: 4D binary lane
  - service reliability
  - rider impact
  - asset readiness
  - safety/security risk
- Output: 4D binary lane
  - `[1,0,0,0]` = `CRITICAL_EVENT`
  - `[0,1,0,0]` = `PREDICTIVE_FLOW_ADJUST`
  - `[0,0,1,0]` = `OPS_TASK`
  - `[0,0,0,1]` = `SERVICE_NOMINAL`

Every machine includes e2e `inputSequences` for a critical event, predictive
flow adjustment, operational tasking, nominal service, and a no-output baseline.

## Critical Event Sequence Length

Every generated machine includes one `Critical event sequence` with exactly
five input vectors:

```text
OBSERVE -> WATCH -> DEGRADED -> ESCALATING -> CRITICAL_EVENT
```

Because all `150` transportation machines use the same critical-event length,
the generated family average is exactly `5.0`.

## Workstreams

The machines are organized as 15 workstreams with 10 machines each:

- Rider Experience
- Vehicle Operations
- Predictive Maintenance
- Cleaning And Sanitation
- Security And Safety
- Dispatch And Flow Control
- Charging And Fueling
- Depot Operations
- Workforce Operations
- Compliance And Reporting
- Customer Communications
- Network Planning
- Asset Infrastructure
- Finance And Cost
- Executive Optimization

## Predictive Flow Interconnections

The generator creates AI trigger interconnections by mapping selected downstream
machine inputs onto upstream machine output lanes. This forms predictive
flow-management chains such as:

- Rider experience signals feeding dispatch and service-control decisions.
- Vehicle operational health feeding maintenance and pullout readiness.
- Cleaning, security, depot, workforce, and compliance signals feeding
  executive fleet optimization.
- Dispatch and energy signals feeding depot readiness, charging/fueling, and
  100-bus command-center decisions.

Each machine carries:

- `aiTrigger`: stable workstream/focus trigger key.
- `predictiveFlowTrigger`: trigger key for fleet-flow orchestration.
- `dispatchableAgent`: the AI agent responsible for the next action.
- `upstreamMachine`, `upstreamOutputRegion`, and `downstreamMachines` metadata
  describing the predictive interconnect pattern.

## Domain Placement

After running the domain-aware remapper, transportation occupies:

```text
transportation [1939:2559]
```

The compact length is `620` positions rather than `1200` because predictive
flow interconnections intentionally reuse upstream 4D output lanes as downstream
4D input lanes.

## Regeneration

Run:

```bash
python3 scripts/generate_transportation_fleet_machines.py
node scripts/remap_machine_connection_matrix_by_domain.mjs
```

Then validate with:

```bash
npm run build
make -C ../RealityEngine_CPP e2e
```
