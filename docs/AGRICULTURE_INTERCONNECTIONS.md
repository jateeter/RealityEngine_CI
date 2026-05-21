# Agriculture Interconnections

The agriculture example corpus uses perceptual-space overlaps to turn individual
machines into operational and predictive management chains.

## Intent

The agriculture domain should not behave as a set of isolated monitors. Upstream
machines that detect operational conditions should feed downstream machines that
predict risk, optimize timing, or schedule preventive work.

The AGX aquaculture and indoor grow-house machines therefore use 4D output
signals as 4D downstream inputs where one operational signal directly improves a
later management decision.

## Current Matrix

The agriculture domain has:

- `64` active machines (59 generated AGX001-050 + 5 Yuma MQTT-driven
  maintenance machines AGX051-055).
- `36` output-to-input overlaps inside the agriculture domain.
- `28` AGX predictive-management interconnections.
- `5` MQTT-direct connections from `yuma.lateraledge.cloud` into the
  domain (4 sensor banks + 1 AI bridge — see "Yuma MQTT Chain" below).

## Aquaculture Chains

Key predictive paths:

- Water quality stability -> biofilter health -> ammonia/nitrite risk ->
  aquaponic nutrient coupling.
- Recirculation pump reliability -> dissolved oxygen control -> pond turnover
  prevention.
- Quarantine biosecurity -> fish health surveillance -> hatchery/nursery
  transition, harvest readiness, and probiotic treatment tracking.
- Feeding efficiency -> solids removal -> water exchange planning -> effluent
  compliance.
- Stocking density -> animal welfare response.
- Hatchery/nursery transition -> larval survival optimization.

These links let the domain detect compound risk earlier: water chemistry,
circulation, stocking, feeding, and biosecurity outputs become direct predictors
for downstream health, welfare, compliance, and harvest decisions.

## Indoor Grow-House Chains

Key predictive paths:

- VPD climate management -> airflow circulation.
- Lighting schedule integrity -> crop steering -> canopy height control.
- Nutrient reservoir balance -> fertigation recipe verification -> tissue test
  response.
- Irrigation line maintenance -> root-zone oxygenation and drainage wastewater
  capture.
- Integrated pest management -> sanitation turnover and beneficial insect
  release.
- HVAC preventive maintenance -> dehumidifier reliability and energy demand
  response.
- Sensor calibration program -> facility alarm triage.
- Harvest labor coordination -> postharvest cold chain.

These links bias the grow-house domain toward predictive maintenance and
operational optimization: climate, fertigation, irrigation, IPM, HVAC, and
sensor-calibration signals drive the machines that should plan corrective action
before production loss appears.

## Yuma MQTT Chain

AGX051-AGX055 are the live-broker-driven machines.  They consume the
sensor regions populated by `RealityEngine_CPP/config/mqtt-mappings.yuma-agriculture.json`
and project the result onto `AgYieldOptimizationAI`'s input window —
giving the agriculture domain a complete path from physical sensor to
cross-domain yield AI.

```
yuma.lateraledge.cloud:1883
  │
  ├─ LATERAL/WaterSuite/DEV0000001/SensorReadings/v1
  │     pH / EC / ORP / turbidity        → cells [40:44)
  │           ├── AGX001 operational stability → [44:48)
  │           └── AGX051 maintenance forecast  → [256:260)
  │
  ├─ LATERAL/DOSuite/DEV0000017/SensorReadings/v1
  │     DO level / temp / watch bands    → cells [84:88)
  │           ├── AGX005 operational DO control → [68:72)
  │           └── AGX052 DO-probe reliability   → [260:264)
  │
  ├─ LATERAL/AmbientSuite/DEV0000009/SensorReadings/v1
  │     ambient T / RH / watch bands     → cells [184:188)
  │           ├── AGX026 operational VPD climate → [188:192)
  │           └── AGX053 HVAC service plan       → [264:268)
  │
  └─ LATERAL/AmbientSuite/DEV0000009/SensorReadings/v1
        CO2 enrichment / watch / danger  → cells [228:232)
              ├── AGX032 operational CO2 safety  → [232:236)  (life-safety)
              └── AGX054 CO2 compliance officer  → [268:272)  (life-safety)

                                  ▼
                       AGX055 Yuma Facility AI
                            Synthesis Bridge
                       in [256:272)  out [3959:3971)
                                  │
                                  ▼
                        AgYieldOptimizationAI
                       in [3959:3971)  out [310:316)
                            (cross-domain AI)
```

**Design principle.** AGX001/005/026/032 already consume the four MQTT
sensor banks for an *operational stability* lens.  AGX051/052/053/054
read the *same* cells but apply a *maintenance* lens — distinct
sequences, distinct output regions, distinct dispatchable agents.
Multiple machines sharing an input region is the normal CES pattern;
perceptual space is read-shared.

**Output-region map for the Yuma maintenance machines (16 cells in
total):**

| Machine | Input  | Output  | Agent |
|---------|--------|---------|-------|
| AGX051 Yuma Aqua Maintenance Forecaster        | [40:44)   | [256:260) | `aquaculture_predictive_maintenance_agent` |
| AGX052 Yuma DO Probe Reliability Tracker       | [84:88)   | [260:264) | `aquaculture_do_probe_reliability_agent`   |
| AGX053 Yuma VPD HVAC Service Planner           | [184:188) | [264:268) | `growhouse_hvac_service_agent`             |
| AGX054 Yuma CO2 Safety Compliance Officer      | [228:232) | [268:272) | `growhouse_safety_compliance_agent` (life-safety) |
| AGX055 Yuma Facility AI Synthesis Bridge       | [256:272) | [3959:3971) | `agriculture_yield_optimization_ai`    |

**Output semantics (AGX051-054).** Each emits a 4-cell one-hot:

- `[1,0,0,0]` URGENT_MAINT — immediate maintenance dispatch
- `[0,1,0,0]` FORECAST_MAINT — schedule service in upcoming window
- `[0,0,1,0]` CALIBRATE — sensor drift suspected
- `[0,0,0,1]` NORMAL — equipment healthy

**Output semantics (AGX055).** 12-cell one-hot — three slots per source
(URGENT / FORECAST / STABLE) for AQUA, DO, CLIMATE, SAFETY — matches the
12-cell input window AgYieldOptimizationAI consumes.

## Maintenance Rule

When AGX machines are regenerated, run:

```bash
python3 scripts/generate_agriculture_aquaculture_growhouse_machines.py
python3 scripts/generate_yuma_mqtt_maintenance_machines.py
node scripts/repack_machine_connection_matrix.mjs
```

The repack step removes unused coordinate positions while preserving the
intended output-to-input overlap topology.  The Yuma generator script
emits AGX051-AGX055 from a compact spec and re-runs are safe — it
rewrites the five files in place.
