# Data Center Operations Machines

The `DCX001`-`DCX050` machines extend the data-center management domain with
24/7 operations coverage. They complement the original data-center monitoring,
thermal, network, memory, and critical-alert machines with operational awareness
for facilities, maintenance, upgrades, security, compliance, capacity, and SRE
handoff.

## Contract

Each `DCX` machine uses:

- Category: `data-center`
- Domain: `Data Center - 24x7 Operations`
- Input: 4D binary lane
  - availability margin
  - maintenance readiness
  - upgrade/lifecycle pressure
  - operational confidence
- Output: 4D binary lane
  - `[1,0,0,0]` = `URGENT_INTERVENTION`
  - `[0,1,0,0]` = `SCHEDULE_MAINTENANCE`
  - `[0,0,1,0]` = `PLAN_UPGRADE`
  - `[0,0,0,1]` = `OPERATING_NOMINAL`

Every machine includes e2e `inputSequences` for urgent intervention,
maintenance scheduling, upgrade planning, nominal operation, and a no-output
baseline.

## Coverage

The 50 machines cover:

- Utility power, UPS, generators, PDU balancing, and energy optimization.
- Cooling, chiller plants, thermal envelopes, leak detection, and fire
  suppression.
- Physical access, video surveillance, identity, compliance, and vulnerability
  management.
- Network core redundancy, WAN diversity, top-of-rack lifecycle, and fiber
  integrity.
- Server fleet health, firmware compliance, patch windows, virtualization,
  Kubernetes, and capacity forecasting.
- Storage arrays, backup assurance, disaster recovery drills, storage migration,
  and decommission safety.
- Change risk, incident command, observability, SLOs, alert fatigue, SRE
  handoff, maintenance blackout windows, and upgrade waves.

## Interconnection Model

The data-center domain now has `49` output-to-input interconnections:

- `6` original data-center edges across thermal, network, memory, and critical
  alert machines.
- `43` DCX automation edges for 24/7 operational management and prescriptive
  maintenance.

Key automation paths:

- Utility feed -> UPS health -> generator readiness.
- Utility feed -> PDU load -> rack thermal envelope -> CRAC/CRAH, chiller,
  leak response, and environmental calibration.
- Rack thermal envelope -> energy efficiency -> carbon-aware workload
  scheduling.
- Leak detection -> fire suppression readiness.
- Physical access -> surveillance coverage and identity privilege review.
- Network core -> WAN diversity, top-of-rack lifecycle, and spine/leaf
  expansion planning.
- Server fleet -> firmware compliance -> patch window orchestration.
- Server fleet -> cluster capacity -> virtualization HA -> Kubernetes control
  plane guard.
- Storage array -> backup assurance -> disaster recovery drill management.
- Storage array -> storage migration coordination.
- Capacity reservation -> asset lifecycle -> spares inventory -> change risk.
- Change risk -> maintenance blackout guard -> upgrade wave planner -> firmware
  rollback readiness.
- Incident command -> observability -> alert fatigue -> SLO burn-rate ->
  compliance evidence -> vulnerability exposure -> certificate rotation.
- Observability -> CMDB accuracy -> configuration drift.
- Capacity reservation -> tenant capacity guard.
- Asset lifecycle -> decommission safety -> 24x7 operations executive summary.

## Maintenance And Upgrade Use

Use these machines as operational guardrails:

- Feed CMDB, monitoring, change-calendar, ticketing, security, and AI-dispatch
  signals into the 4D input lane.
- Route `SCHEDULE_MAINTENANCE` outputs into maintenance workflow machines,
  work-order systems, or AI agents.
- Route `PLAN_UPGRADE` outputs into change-risk, canary, rollback, and capacity
  planning machines.
- Route `URGENT_INTERVENTION` outputs into incident command and alerting
  machines.
- Route `OPERATING_NOMINAL` outputs into executive-summary, SLO, and readiness
  dashboards.

The intent is to keep the data center aware of both immediate failures and
deferred operational debt. Maintenance and upgrade signals are first-class
outputs, not afterthoughts.

## 24/7 Projection

Every `DCX` machine includes a `24-hour prescriptive projection` input sequence.
It models four 6-hour windows:

- `0-6h`: current state is stable but lifecycle pressure is visible.
- `6-12h`: operational confidence starts to degrade.
- `12-18h`: maintenance readiness is insufficient for projected load.
- `18-24h`: the forecast crosses the prescriptive maintenance threshold.

The projection emits `[0,1,0,0]`, the same `SCHEDULE_MAINTENANCE` lane used by
direct service-due detection. This makes forward-looking maintenance a native
machine output rather than a separate reporting convention.

The projection metadata is stored on each machine as:

- `projectionHorizon: "24h"`
- `projectionWindows: ["0-6h", "6-12h", "12-18h", "18-24h"]`
- `prescriptiveMaintenanceRole`

## Regeneration

Run:

```bash
python3 scripts/generate_data_center_operations_machines.py
node scripts/repack_machine_connection_matrix.mjs
```

The repack step preserves existing interconnections while removing unused
coordinate positions from the example-machine matrix.
