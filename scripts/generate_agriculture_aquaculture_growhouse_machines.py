#!/usr/bin/env python3
"""
Generate agriculture example machines for aquaculture and indoor grow-house
operations.

The generated machines model operational best practices as AI-triggered
automation points: monitor normalized sensor streams, dispatch a specialized
agent when risk emerges, and emit compact 4D outputs for downstream machines.
"""

from __future__ import annotations

import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
OUT_DIR = ROOT / "examples" / "machines"

AQUACULTURE_FOCUS_AREAS = [
    ("Water Quality Stability", "dissolved oxygen, pH, temperature, and ammonia balance"),
    ("Biofilter Health", "nitrification capacity, media flow, alkalinity, and microbial stability"),
    ("Stocking Density", "biomass loading, growth stage, carrying capacity, and welfare margin"),
    ("Feeding Efficiency", "feed conversion, appetite response, waste load, and feed timing"),
    ("Dissolved Oxygen Control", "aeration capacity, oxygen drawdown, backup oxygen, and alarm response"),
    ("Ammonia Nitrite Risk", "total ammonia nitrogen, nitrite rise, pH interaction, and water exchange"),
    ("Fish Health Surveillance", "behavior, mortality trend, lesion observations, and treatment routing"),
    ("Recirculation Pump Reliability", "pump status, flow velocity, redundancy, and service interval"),
    ("Solids Removal", "settling, filtration differential, backwash timing, and sludge handling"),
    ("Water Exchange Planning", "makeup water quality, salinity match, temperature match, and discharge limits"),
    ("Quarantine Biosecurity", "isolation status, equipment segregation, pathogen screen, and movement control"),
    ("Hatchery Nursery Transition", "size grading, acclimation, feed change, and transfer stress"),
    ("Algae Culture Balance", "light, nutrients, contamination, and harvest timing"),
    ("Shellfish Nursery Flow", "upweller flow, food availability, density, and fouling pressure"),
    ("Effluent Compliance", "nutrient discharge, suspended solids, treatment status, and reporting readiness"),
    ("Energy Backup Readiness", "generator availability, battery runtime, critical loads, and failover test"),
    ("Harvest Readiness", "size distribution, withdrawal interval, market schedule, and cold-chain capacity"),
    ("RAS Thermal Management", "heater/chiller status, thermal drift, species target, and seasonal load"),
    ("Salinity Osmotic Balance", "salinity drift, freshwater addition, evaporation, and species tolerance"),
    ("Animal Welfare Response", "stress behavior, handling load, crowding, and corrective action completion"),
    ("Probiotic Treatment Tracking", "dose adherence, water response, disease pressure, and observation log"),
    ("Pond Turnover Prevention", "stratification, wind mixing, oxygen reserve, and bloom crash risk"),
    ("Predator Exclusion", "net integrity, intrusion signal, perimeter status, and loss trend"),
    ("Larval Survival Optimization", "live feed density, water quality, lighting, and cannibalism pressure"),
    ("Aquaponic Nutrient Coupling", "fish waste load, plant uptake, pH compromise, and mineral supplementation"),
]

GROWHOUSE_FOCUS_AREAS = [
    ("VPD Climate Management", "temperature, relative humidity, VPD, and transpiration stability"),
    ("Lighting Schedule Integrity", "photoperiod, dimming curve, fixture health, and crop-stage target"),
    ("Nutrient Reservoir Balance", "EC, pH, temperature, and mixing consistency"),
    ("Irrigation Line Maintenance", "flow uniformity, emitter clogging, pressure, and flush schedule"),
    ("Integrated Pest Management", "scouting count, sticky-card trend, beneficial release, and treatment threshold"),
    ("Airflow Circulation", "fan status, canopy air movement, dead zones, and condensation prevention"),
    ("CO2 Enrichment Safety", "CO2 setpoint, occupancy status, ventilation interlock, and leak alarm"),
    ("Root Zone Oxygenation", "root temperature, dissolved oxygen, moisture, and anaerobic risk"),
    ("Sanitation Turnover", "room cleaning, tool disinfection, waste removal, and pre-plant checklist"),
    ("Propagation Uniformity", "germination rate, clone rooting, humidity dome timing, and tray grading"),
    ("Crop Steering", "generative/vegetative balance, dryback, EC stacking, and climate cue alignment"),
    ("Canopy Height Control", "growth rate, distance to fixture, pruning schedule, and trellis status"),
    ("HVAC Preventive Maintenance", "filter pressure, coil status, condensate drain, and service interval"),
    ("Dehumidifier Reliability", "runtime, condensate output, RH recovery, and compressor fault trend"),
    ("Water Treatment Maintenance", "filter life, RO rejection rate, UV status, and storage tank hygiene"),
    ("Fertigation Recipe Verification", "recipe version, injector calibration, batch conductivity, and pH correction"),
    ("Harvest Labor Coordination", "ripeness signal, crew capacity, packaging readiness, and cold room space"),
    ("Postharvest Cold Chain", "pre-cool timing, room temperature, humidity, and inventory dwell time"),
    ("Safety Compliance", "worker entry, chemical storage, PPE readiness, and lockout status"),
    ("Energy Demand Response", "peak load, lighting schedule, thermal reserve, and utility signal"),
    ("Sensor Calibration Program", "calibration age, drift detection, reference check, and replacement queue"),
    ("Drainage Wastewater Capture", "runoff EC, volume, treatment capacity, and discharge authorization"),
    ("Beneficial Insect Release", "release timing, pest pressure, climate suitability, and scouting confirmation"),
    ("Tissue Test Response", "leaf nutrient status, deficiency pattern, recipe adjustment, and retest interval"),
    ("Facility Alarm Triage", "alarm priority, affected zone, redundancy status, and response SLA"),
]

AGENTS = [
    "aquaculture_water_quality_agent",
    "aquaculture_health_agent",
    "aquaculture_maintenance_agent",
    "aquaculture_feed_optimization_agent",
    "aquaculture_compliance_agent",
    "growhouse_climate_agent",
    "growhouse_irrigation_agent",
    "growhouse_ipm_agent",
    "growhouse_maintenance_agent",
    "growhouse_crop_steering_agent",
]

# Deliberate predictive-management edges. The target machine reads the 4D output
# of the source machine as its input. This turns isolated AGX monitors into
# operational dependency chains without changing the compact 4D output contract.
UPSTREAM_BY_INDEX = {
    # Aquaculture: water chemistry -> biology -> welfare/harvest/compliance
    2: 1,    # water quality stability drives biofilter health
    5: 8,    # pump reliability drives dissolved oxygen control
    6: 2,    # biofilter health drives ammonia/nitrite risk
    7: 11,   # quarantine biosecurity drives fish health surveillance
    9: 4,    # feeding efficiency drives solids removal
    10: 9,   # solids removal drives water exchange planning
    12: 7,   # fish health surveillance drives hatchery/nursery transition
    15: 10,  # water exchange planning drives effluent compliance
    17: 7,   # fish health surveillance drives harvest readiness
    20: 3,   # stocking density drives animal welfare response
    21: 7,   # fish health surveillance drives probiotic treatment tracking
    22: 5,   # dissolved oxygen control drives pond turnover prevention
    24: 12,  # hatchery/nursery transition drives larval survival optimization
    25: 6,   # ammonia/nitrite risk drives aquaponic nutrient coupling

    # Indoor grow house: climate/nutrients/maintenance -> predictive actions
    31: 26,  # VPD climate drives airflow circulation
    33: 29,  # irrigation maintenance drives root-zone oxygenation
    34: 30,  # IPM drives sanitation turnover
    36: 27,  # lighting integrity drives crop steering
    37: 36,  # crop steering drives canopy height control
    39: 38,  # HVAC preventive maintenance drives dehumidifier reliability
    41: 28,  # nutrient reservoir drives fertigation verification
    42: 17,  # aquaculture harvest readiness informs shared labor planning
    43: 42,  # harvest labor coordination drives cold-chain readiness
    45: 38,  # HVAC maintenance drives energy demand response
    47: 29,  # irrigation maintenance drives wastewater capture
    48: 30,  # IPM drives beneficial insect release
    49: 41,  # fertigation verification drives tissue-test response
    50: 46,  # sensor calibration drives facility alarm triage
}


def slug(value: str) -> str:
    while "--" in (result := "".join(ch.lower() if ch.isalnum() else "-" for ch in value).strip("-")):
        value = result.replace("--", "-")
    return result


def vector_elements(values: list[float]) -> list[dict[str, float]]:
    return [{"value": value, "threshold": 0.5} for value in values]


def machine_payload(index: int, program: str, focus: str, description: str, specs: list[tuple[str, str, str]]) -> dict:
    zero_based = index - 1
    base = 637 + zero_based * 8
    output_offset = base + 4
    upstream_index = UPSTREAM_BY_INDEX.get(index)
    input_offset = (637 + (upstream_index - 1) * 8 + 4) if upstream_index else base
    topic_slug = slug(f"{program}-{focus}")
    code = f"agx-{index:03d}"
    agent = AGENTS[zero_based % len(AGENTS)]
    name = f"Agriculture {program} {focus}"
    upstream_name = None
    upstream_output = None
    if upstream_index:
        upstream_program, upstream_focus, _ = specs[upstream_index - 1]
        upstream_name = f"Agriculture {upstream_program} {upstream_focus}"
        upstream_output = f"[{input_offset}:{input_offset + 4}]"
    downstream_indices = [target for target, source in UPSTREAM_BY_INDEX.items() if source == index]
    downstream_names = [
        f"Agriculture {specs[target - 1][0]} {specs[target - 1][1]}"
        for target in downstream_indices
    ]

    risk_action = f"Dispatch {agent} to stabilize {focus.lower()} and record corrective action."
    optimize_action = f"Run AI optimization for {focus.lower()} using the latest operating window and production targets."
    maintenance_action = f"Create preventive-maintenance work for {focus.lower()} and verify completion telemetry."
    stable_action = f"Continue automated monitoring for {focus.lower()} while preserving current setpoints."

    return {
        "version": "1.0.0",
        "machine": {
            "name": name,
            "description": (
                f"Agriculture domain machine for {program.lower()} operations focused on {focus.lower()}. "
                f"It monitors {description} and emits AI-dispatchable outputs at "
                f"[{output_offset}:{output_offset + 4}] for automation, maintenance, and optimization workflows."
            ),
            "metadata": {
                "category": "agriculture",
                "domain": f"Agriculture - {program}",
                "author": "Reality Engine",
                "operationalFocus": focus,
                "focusDescription": description,
                "upstreamMachine": upstream_name,
                "upstreamOutputRegion": upstream_output,
                "predictiveManagementRole": (
                    f"Consumes {upstream_name} output to make {focus.lower()} predictive rather than purely reactive."
                    if upstream_name else
                    f"Primary source machine for {focus.lower()} predictive management signals."
                ),
                "aiTrigger": f"{topic_slug}-risk-maintenance-or-optimization",
                "dispatchableAgent": agent,
                "agentActions": [risk_action, optimize_action, maintenance_action, stable_action],
                "outputSpace": (
                    f"4D binary at [{output_offset}:{output_offset + 4}]: "
                    "[1,0,0,0]=URGENT_STABILIZE, [0,1,0,0]=OPTIMIZE_OPERATION, "
                    "[0,0,1,0]=PREVENTIVE_MAINTENANCE, [0,0,0,1]=OPERATING_WINDOW_OK"
                ),
                "tags": [
                    "agriculture",
                    slug(program),
                    slug(focus),
                    "ai-triggers",
                    "dispatchable-agents",
                    "operational-management",
                    "maintenance",
                ],
                "sequenceCount": 4,
                "sensorNormalization": {
                    "process_stability_norm": "0.0=unstable or outside safe operating band; 0.5=watch band; 1.0=stable in target band",
                    "resource_efficiency_norm": "0.0=wasteful or constrained; 0.5=acceptable; 1.0=efficient and available",
                    "biosecurity_or_ipm_norm": "0.0=active biological threat; 0.5=mitigated watch state; 1.0=controlled and documented",
                    "maintenance_readiness_norm": "0.0=overdue or faulted; 0.5=service due soon; 1.0=maintained and verified",
                },
                "inputSemantics": [
                    "process stability",
                    "resource efficiency",
                    "biosecurity or IPM status",
                    "maintenance readiness",
                ],
                "downstreamMachines": downstream_names,
                "downstreamPattern": (
                    f"Output region [{output_offset}:{output_offset + 4}] feeds "
                    f"{', '.join(downstream_names)} for predictive agriculture management."
                    if downstream_names else
                    f"Output region [{output_offset}:{output_offset + 4}] feeds agriculture automation and AI dispatch orchestration."
                ),
            },
            "arbiterRule": "PASSTHROUGH",
            "perceptualMapping": {
                "input": {"offset": input_offset, "length": 4},
                "output": {"offset": output_offset, "length": 4},
            },
            "sequences": [
                {
                    "id": f"{code}-urgent-stabilize",
                    "name": f"{focus}: NORMAL -> WATCH -> CRITICAL -> URGENT_STABILIZE",
                    "metadata": {
                        "description": "Escalates from stable operation to a critical process or welfare risk.",
                        "path": "NORMAL -> WATCH -> CRITICAL",
                        "output": "[1,0,0,0]",
                    },
                    "vectors": [
                        {
                            "id": f"{code}-normal",
                            "elements": vector_elements([1, 1, 1, 1]),
                            "isInitial": True,
                            "metadata": {"name": "NORMAL", "description": "Operating window is stable and maintenance is current."},
                            "nextVectorIds": [f"{code}-watch"],
                        },
                        {
                            "id": f"{code}-watch",
                            "elements": vector_elements([1, 0, 1, 0]),
                            "isInitial": False,
                            "metadata": {"name": "WATCH", "description": "Efficiency and maintenance signals are weakening."},
                            "nextVectorIds": [f"{code}-critical"],
                        },
                        {
                            "id": f"{code}-critical",
                            "elements": vector_elements([0, 0, 0, 0]),
                            "isInitial": False,
                            "metadata": {"name": "CRITICAL", "description": "Operation requires immediate stabilization and AI dispatch."},
                            "outputVectors": [
                                {
                                    "id": f"{code}-urgent-output",
                                    "vector": [1, 0, 0, 0],
                                    "metadata": {"description": "Urgent stabilization required.", "action": risk_action},
                                }
                            ],
                        },
                    ],
                },
                {
                    "id": f"{code}-optimize-operation",
                    "name": f"{focus}: OPTIMIZATION_WINDOW -> OPTIMIZE_OPERATION",
                    "metadata": {
                        "description": "Fires when the process is safe but AI can improve yield, welfare, resource use, or labor timing.",
                        "pattern": "OPTIMIZATION_WINDOW",
                        "output": "[0,1,0,0]",
                    },
                    "vectors": [
                        {
                            "id": f"{code}-optimize",
                            "elements": vector_elements([0, 1, 0, 1]),
                            "isInitial": True,
                            "metadata": {"name": "OPTIMIZATION_WINDOW", "description": "Optimization can improve the operating plan before risk accumulates."},
                            "outputVectors": [
                                {
                                    "id": f"{code}-optimize-output",
                                    "vector": [0, 1, 0, 0],
                                    "metadata": {"description": "Optimization workflow should run.", "action": optimize_action},
                                }
                            ],
                        }
                    ],
                },
                {
                    "id": f"{code}-preventive-maintenance",
                    "name": f"{focus}: SERVICE_DUE -> PREVENTIVE_MAINTENANCE",
                    "metadata": {
                        "description": "Fires when service should be scheduled before a fault or production loss.",
                        "pattern": "SERVICE_DUE",
                        "output": "[0,0,1,0]",
                    },
                    "vectors": [
                        {
                            "id": f"{code}-service-due",
                            "elements": vector_elements([1, 0, 0, 1]),
                            "isInitial": True,
                            "metadata": {"name": "SERVICE_DUE", "description": "Maintenance work should be created while the operation remains controllable."},
                            "outputVectors": [
                                {
                                    "id": f"{code}-maintenance-output",
                                    "vector": [0, 0, 1, 0],
                                    "metadata": {"description": "Preventive maintenance required.", "action": maintenance_action},
                                }
                            ],
                        }
                    ],
                },
                {
                    "id": f"{code}-operating-window-ok",
                    "name": f"{focus}: STABLE -> OPERATING_WINDOW_OK",
                    "metadata": {
                        "description": "Fires when the operation is stable and should continue under current automation settings.",
                        "pattern": "STABLE",
                        "output": "[0,0,0,1]",
                    },
                    "vectors": [
                        {
                            "id": f"{code}-stable",
                            "elements": vector_elements([1, 1, 0, 1]),
                            "isInitial": True,
                            "metadata": {"name": "STABLE", "description": "Current setpoints are acceptable and no intervention is required."},
                            "outputVectors": [
                                {
                                    "id": f"{code}-stable-output",
                                    "vector": [0, 0, 0, 1],
                                    "metadata": {"description": "Operating window is stable.", "action": stable_action},
                                }
                            ],
                        }
                    ],
                },
            ],
            "inputSequences": [
                {
                    "name": "Escalation to urgent stabilization",
                    "description": "A stable operation degrades through watch conditions and then reaches a critical state.",
                    "vectors": [[1, 1, 1, 1], [1, 0, 1, 0], [0, 0, 0, 0]],
                    "metadata": {
                        "expectedOutputCount": 1,
                        "expectedOutputVector": "[1,0,0,0]",
                        "scenario": "urgent-stabilize",
                    },
                },
                {
                    "name": "Optimization opportunity",
                    "description": "AI can improve production, welfare, efficiency, or labor timing before critical risk appears.",
                    "vectors": [[0, 1, 0, 1]],
                    "metadata": {
                        "expectedOutputCount": 1,
                        "expectedOutputVector": "[0,1,0,0]",
                        "scenario": "optimize-operation",
                    },
                },
                {
                    "name": "Preventive maintenance required",
                    "description": "Maintenance should be scheduled before a preventable failure occurs.",
                    "vectors": [[1, 0, 0, 1]],
                    "metadata": {
                        "expectedOutputCount": 1,
                        "expectedOutputVector": "[0,0,1,0]",
                        "scenario": "preventive-maintenance",
                    },
                },
                {
                    "name": "Stable operating window",
                    "description": "The process is inside the target operating band and should continue monitoring.",
                    "vectors": [[1, 1, 0, 1]],
                    "metadata": {
                        "expectedOutputCount": 1,
                        "expectedOutputVector": "[0,0,0,1]",
                        "scenario": "operating-window-ok",
                    },
                },
                {
                    "name": "Normal baseline without output",
                    "description": "A single normal signal arms the escalation path without dispatching an agent.",
                    "vectors": [[1, 1, 1, 1]],
                    "metadata": {
                        "expectedOutputCount": 0,
                        "scenario": "normal-baseline",
                    },
                },
            ],
        },
    }


def main() -> None:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    specs = [
        *[("Aquaculture", focus, desc) for focus, desc in AQUACULTURE_FOCUS_AREAS],
        *[("Indoor Grow House", focus, desc) for focus, desc in GROWHOUSE_FOCUS_AREAS],
    ]
    for index, (program, focus, description) in enumerate(specs, start=1):
        filename = f"AGX{index:03d}_{slug(program)}-{slug(focus)}.json"
        path = OUT_DIR / filename
        path.write_text(json.dumps(machine_payload(index, program, focus, description, specs), indent=2) + "\n")
    print(f"Generated {len(specs)} agriculture machines in {OUT_DIR}")


if __name__ == "__main__":
    main()
