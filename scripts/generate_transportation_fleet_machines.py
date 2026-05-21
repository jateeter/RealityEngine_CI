#!/usr/bin/env python3
"""
Generate 150 public transportation fleet machines for a 100-bus operation.

The generated machines cover rider experience, vehicle operations, maintenance,
cleaning, security, dispatch, charging/fueling, depots, workforce, compliance,
and predictive fleet-flow optimization. Each machine includes a critical event
input sequence of exactly 5 vectors so the corpus average critical sequence
length for this family is exactly 5.
"""

from __future__ import annotations

import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
OUT_DIR = ROOT / "examples" / "machines"


def existing_non_transportation_max_offset() -> int:
    max_offset = 0
    if not OUT_DIR.exists():
        return max_offset
    for path in OUT_DIR.glob("*.json"):
        if path.name.startswith("TFX"):
            continue
        try:
            document = json.loads(path.read_text())
        except json.JSONDecodeError:
            continue
        mapping = document.get("machine", {}).get("perceptualMapping", {})
        for side in ("input", "output"):
            region = mapping.get(side)
            if not region:
                continue
            max_offset = max(max_offset, int(region["offset"]) + int(region["length"]))
    return max_offset

WORKSTREAMS = [
    ("Rider Experience", [
        ("Stop Crowding Monitor", "platform load, shelter capacity, queue growth, and boarding friction"),
        ("On Time Arrival Experience", "headway adherence, rider wait time, transfer reliability, and crowd sentiment"),
        ("Accessibility Boarding Support", "ramp requests, kneeling events, securement dwell, and missed-assistance risk"),
        ("Real Time Information Accuracy", "arrival prediction drift, sign availability, app latency, and rider trust"),
        ("Fare Media Friction", "validator failures, tap retries, cashbox delays, and fare equity impact"),
        ("Passenger Comfort Climate", "cabin temperature, ventilation, humidity, and rider complaint trend"),
        ("Crowding Redistribution", "load imbalance, pass-up risk, trip spacing, and relief-bus opportunity"),
        ("Customer Incident Response", "complaint severity, operator report, location context, and response SLA"),
        ("Transfer Protection", "connecting route status, last-trip risk, mobility need, and hold decision margin"),
        ("Service Equity Watch", "underserved stop delay, cancelled trip concentration, ADA impact, and mitigation status"),
    ]),
    ("Vehicle Operations", [
        ("Bus Telematics Health", "CAN faults, GPS quality, speed profile, and telemetry freshness"),
        ("Route Adherence Controller", "schedule deviation, detour state, dwell variance, and control-center action"),
        ("Headway Balancer", "bunching risk, gap growth, short-turn feasibility, and route supervisor input"),
        ("Operator Behavior Safety", "harsh braking, overspeed, cornering, fatigue signal, and coaching queue"),
        ("Door Cycle Reliability", "door open/close cycle time, obstruction events, fault codes, and dwell impact"),
        ("Wheelchair Ramp Reliability", "ramp cycle outcome, fault trend, manual deployment, and repair priority"),
        ("HVAC In Service Reliability", "compressor status, cabin recovery, fan current, and seasonal rider exposure"),
        ("Engine Powertrain Monitor", "engine faults, coolant temperature, oil pressure, and derate risk"),
        ("Transmission Performance", "shift quality, temperature, slip events, and route terrain load"),
        ("Brake System Monitor", "air pressure, ABS faults, pad wear, and stopping performance"),
    ]),
    ("Predictive Maintenance", [
        ("PM Interval Optimizer", "mileage, engine hours, duty cycle, defect trend, and shop capacity"),
        ("Road Call Risk Predictor", "fault recurrence, route criticality, vehicle age, and rescue-bus proximity"),
        ("Tire Wear Forecast", "tread depth, pressure drift, alignment signal, and weather exposure"),
        ("Battery Health Monitor", "state of health, voltage sag, charge acceptance, and auxiliary load"),
        ("Fluid Leak Detection", "fluid level trend, depot inspection findings, sensor alarms, and spill risk"),
        ("Parts Inventory Readiness", "stockout risk, lead time, usage forecast, and deferred defect backlog"),
        ("Shop Bay Capacity Planner", "bay occupancy, technician skill mix, promised pullout, and repair duration"),
        ("Warranty Recovery Tracker", "covered component, failure evidence, claim deadline, and reimbursement status"),
        ("Defect Triage Board", "operator defects, inspection defects, safety criticality, and dispatch hold decision"),
        ("Lifecycle Replacement Planner", "age, reliability cost, emissions target, funding window, and retirement priority"),
    ]),
    ("Cleaning And Sanitation", [
        ("Interior Cleanliness Monitor", "litter score, surface condition, odor reports, and cleaning interval"),
        ("Biohazard Response", "spill type, vehicle location, PPE need, isolation status, and recovery ETA"),
        ("Graffiti Removal Queue", "tag severity, surface type, evidence capture, and service image impact"),
        ("Restroom Facility Cleaning", "terminal restroom usage, supplies, cleanliness score, and rider complaint trend"),
        ("High Touch Surface Sanitation", "ridership volume, event exposure, cleaning proof, and disinfectant stock"),
        ("Exterior Wash Scheduling", "weather, road grime, visibility, camera obstruction, and wash-bay availability"),
        ("Lost Item Handling", "item report, vehicle match, chain of custody, and customer retrieval workflow"),
        ("Depot Waste Removal", "waste container fill, hazardous separation, contractor schedule, and pest risk"),
        ("Cleaning Crew Dispatch", "crew availability, depot queue, vehicle priority, and turnaround time"),
        ("Clean Bus Release Gate", "cleaning proof, defect scan, operator acceptance, and pullout deadline"),
    ]),
    ("Security And Safety", [
        ("Onboard Security Alert", "panic alarm, operator report, passenger report, location, and police assist status"),
        ("Camera System Availability", "camera online state, recording health, storage age, and blind spot risk"),
        ("Fare Evasion Hotspot", "evasion count, route pattern, conflict risk, and ambassador deployment"),
        ("Stop Security Lighting", "lighting status, incident history, rider volume, and maintenance response"),
        ("Operator Assault Risk", "threat report, prior incident, crowding, late-night route, and shield status"),
        ("Suspicious Package Workflow", "object report, vehicle isolation, dispatch command, and emergency response"),
        ("Emergency Detour Safety", "road closure, safe stop availability, operator instruction, and rider messaging"),
        ("School Trip Safety Monitor", "student crowding, crossing risk, schedule adherence, and supervisor coverage"),
        ("Weather Hazard Safety", "ice, heat, smoke, flooding, wind, and route-specific hazard escalation"),
        ("Incident Evidence Archive", "video clip, operator statement, passenger report, and case retention deadline"),
    ]),
    ("Dispatch And Flow Control", [
        ("Fleet Pullout Readiness", "available buses, operators, defects, cleaning status, and depot departure margin"),
        ("Dynamic Dispatch Rebalancer", "route demand, bus location, relief availability, and headway risk"),
        ("Short Turn Decisioning", "gap recovery, passenger impact, operator rules, and terminal capacity"),
        ("Relief Bus Allocation", "standby location, road call risk, event demand, and route priority"),
        ("Service Disruption Command", "incident severity, affected trips, alternate service, and communications state"),
        ("Event Surge Management", "venue schedule, expected ridership, staging buses, and crowd release timing"),
        ("Detour Coordination", "road closure, temporary stops, operator instructions, and rider alerts"),
        ("Terminal Congestion Control", "bay occupancy, layover compliance, pull-through delay, and supervisor action"),
        ("Run Cut Adjustment", "operator availability, vehicle availability, route priority, and overtime exposure"),
        ("Predictive Flow Executive", "system demand, service reliability, fleet health, security risk, and rider impact"),
    ]),
    ("Charging And Fueling", [
        ("Diesel Fuel Inventory", "tank level, delivery schedule, consumption forecast, and contamination signal"),
        ("CNG Station Availability", "compressor health, storage pressure, dryer status, and queue length"),
        ("Electric Charger Uptime", "charger fault, connector availability, power limit, and repair ETA"),
        ("Battery Electric Range Forecast", "state of charge, route block energy, weather load, and layover charge"),
        ("Fueling Queue Optimizer", "vehicle return time, fuel need, fueling bay capacity, and pullout priority"),
        ("Energy Cost Optimizer", "tariff window, demand charge, route priority, and charger scheduling"),
        ("Charger Maintenance Planner", "fault history, connector wear, firmware status, and service contract SLA"),
        ("Hydrogen Fuel Cell Readiness", "hydrogen level, dispenser state, stack health, and safety interlock"),
        ("Low Emission Zone Compliance", "vehicle assignment, emissions class, zone rule, and dispatch constraint"),
        ("Energy Resilience Monitor", "utility outage risk, backup power, fuel reserve, and critical service plan"),
    ]),
    ("Depot Operations", [
        ("Yard Location Accuracy", "vehicle GPS/RFID, stall assignment, search time, and pullout sequence"),
        ("Depot Gate Throughput", "gate queue, inspection stop, operator check-in, and departure delay"),
        ("Pre Trip Inspection Monitor", "checklist completion, defect severity, operator acknowledgment, and hold state"),
        ("Post Trip Defect Capture", "operator notes, sensor faults, mileage, and shop triage routing"),
        ("Yard Safety Monitor", "pedestrian zones, speed compliance, backing events, and lighting status"),
        ("Snow Ice Depot Response", "plow status, salt level, ramp safety, and pullout lane clearance"),
        ("Depot Staffing Coverage", "dispatcher, cleaner, mechanic, supervisor coverage, and shift handoff"),
        ("Tool Equipment Readiness", "diagnostic tool availability, lift status, PPE stock, and calibration date"),
        ("Parking Assignment Optimizer", "vehicle block, maintenance need, charge/fuel need, and morning pullout order"),
        ("Depot Executive Readiness", "fleet availability, yard flow, shop backlog, cleaning queue, and staffing confidence"),
    ]),
    ("Workforce Operations", [
        ("Operator Availability", "absences, standby pool, overtime exposure, and route priority"),
        ("Fatigue Risk Monitor", "hours worked, split shifts, rest interval, and safety-sensitive assignment"),
        ("Training Certification Monitor", "license status, route qualification, safety training, and expiry date"),
        ("Mechanic Skill Routing", "defect type, certification, shift roster, and job priority"),
        ("Cleaning Crew Coverage", "crew count, vehicle queue, biohazard skill, and depot coverage"),
        ("Supervisor Field Coverage", "incident hotspots, route complexity, event demand, and response time"),
        ("Labor Rule Compliance", "contract limits, break timing, spread time, and assignment legality"),
        ("Operator Communications", "message delivery, acknowledgment, route instruction, and escalation state"),
        ("Shift Handoff Integrity", "open incidents, disabled vehicles, detours, and pending rider issues"),
        ("Workforce Executive Risk", "operator capacity, mechanic capacity, cleaning capacity, supervisor coverage, and fatigue trend"),
    ]),
    ("Compliance And Reporting", [
        ("ADA Service Compliance", "missed lift events, pass-ups, stop accessibility, and complaint resolution"),
        ("Safety Audit Evidence", "inspection proof, incident records, training proof, and corrective action"),
        ("Emissions Reporting", "fuel use, electric miles, idle time, and low-emission assignment"),
        ("Preventive Maintenance Compliance", "PM completion, overdue units, audit evidence, and exception approval"),
        ("Cleaning Standard Compliance", "cleaning proof, inspection scores, complaint trend, and corrective action"),
        ("Security Incident Reporting", "incident category, response time, evidence, and external notification"),
        ("Service Reliability KPI", "on-time performance, headway regularity, cancellations, and passenger impact"),
        ("Equity KPI Monitor", "route-level reliability, service gaps, accessibility impacts, and mitigation tracking"),
        ("Funding Grant Deliverable", "fleet uptime, emissions target, ridership metric, and reporting deadline"),
        ("Regulatory Executive Summary", "safety, ADA, emissions, PM, security, and service reliability compliance posture"),
    ]),
    ("Customer Communications", [
        ("Rider Alert Accuracy", "affected stops, route impact, alert latency, and correction queue"),
        ("Multilingual Message Routing", "language need, route geography, channel reach, and translation status"),
        ("Social Media Response", "complaint volume, misinformation risk, incident severity, and response SLA"),
        ("Call Center Load Monitor", "call volume, wait time, topic cluster, and staffing adjustment"),
        ("Lost Service Recovery Messaging", "missed trip, replacement service, fare credit, and rider notification"),
        ("Accessibility Communication", "elevator/ramp issue, accessible alternative, rider need, and confirmation"),
        ("Event Service Messaging", "venue coordination, crowd release, route overlay, and rider guidance"),
        ("Emergency Communication", "incident command, approved message, channel delivery, and update cadence"),
        ("Feedback Loop Analyzer", "complaint theme, operational root cause, action owner, and closure proof"),
        ("Communications Executive Pulse", "alert quality, rider sentiment, call center load, and open issues"),
    ]),
    ("Network Planning", [
        ("Stop Demand Forecast", "boardings, alightings, land use, weather, and event calendar"),
        ("Route Runtime Calibration", "segment travel time, dwell time, signal delay, and schedule padding"),
        ("Stop Spacing Review", "walk access, speed impact, ADA access, and consolidation candidate"),
        ("Service Span Optimization", "early/late demand, workforce cost, equity need, and connection value"),
        ("Frequency Optimization", "load factor, wait time, budget, and crowding risk"),
        ("Bus Priority Signal Monitor", "TSP calls, intersection delay, activation success, and schedule benefit"),
        ("Bus Lane Reliability", "lane blockage, enforcement signal, speed benefit, and hotspot escalation"),
        ("Construction Impact Planner", "project schedule, detour duration, stop access, and rider impact"),
        ("Ridership Recovery Monitor", "trend, corridor opportunity, service quality, and marketing trigger"),
        ("Planning Executive Scenario", "fleet capacity, rider demand, budget pressure, and reliability target"),
    ]),
    ("Asset Infrastructure", [
        ("Stop Shelter Condition", "shelter damage, cleanliness, lighting, seating, and repair priority"),
        ("Real Time Sign Health", "display online status, prediction feed, power, and vandalism state"),
        ("Bus Stop Accessibility", "curb condition, landing pad, obstruction, and ADA compliance risk"),
        ("Transit Center Escalator Elevator", "availability, inspection status, outage duration, and accessible route"),
        ("Radio Network Coverage", "dead zones, message retry, operator safety, and maintenance priority"),
        ("AVL Infrastructure Health", "GPS correction, cellular coverage, data latency, and device failure"),
        ("Fare Validator Asset Health", "device status, transaction errors, cashbox state, and field service queue"),
        ("Depot Fuel Island Asset", "pump status, leak detection, metering accuracy, and maintenance interval"),
        ("Charger Grid Infrastructure", "transformer load, switchgear status, charger utilization, and expansion need"),
        ("Infrastructure Executive Readiness", "stop assets, communications assets, depot assets, and grid assets"),
    ]),
    ("Finance And Cost", [
        ("Overtime Cost Monitor", "open work, absenteeism, extra board use, and budget threshold"),
        ("Fuel Cost Forecast", "fuel price, consumption trend, route assignment, and hedge exposure"),
        ("Maintenance Cost Driver", "component failures, labor hours, parts usage, and repeat defect"),
        ("Cleaning Cost Monitor", "cleaning frequency, biohazard events, staffing, and supplies"),
        ("Security Cost Monitor", "incident overtime, police assist, evidence handling, and hotspot deployment"),
        ("Warranty Claim Value", "eligible repairs, evidence quality, claim age, and recovery probability"),
        ("Service Change Cost", "platform hours, operator cost, fuel/energy cost, and ridership value"),
        ("Capital Replacement Budget", "vehicle age, infrastructure age, grant timing, and state-of-good-repair gap"),
        ("Fare Revenue Anomaly", "ridership, transactions, evasion, validator faults, and revenue leakage"),
        ("Finance Executive Optimization", "operating cost, capital risk, revenue signal, and service value"),
    ]),
    ("Executive Optimization", [
        ("Fleet Reliability Executive", "vehicle availability, road calls, maintenance backlog, and pullout risk"),
        ("Rider Experience Executive", "wait time, crowding, complaints, accessibility, and information accuracy"),
        ("Safety Security Executive", "incidents, evidence readiness, operator risk, and hotspot response"),
        ("Maintenance Cleaning Executive", "PM compliance, cleaning queue, shop capacity, and release readiness"),
        ("Service Flow Executive", "headways, disruptions, detours, surge demand, and terminal congestion"),
        ("Energy Infrastructure Executive", "fuel/charge readiness, emissions compliance, and resilience posture"),
        ("Workforce Executive Optimizer", "operator, mechanic, cleaner, supervisor capacity, and fatigue risk"),
        ("Compliance Executive Optimizer", "ADA, safety, emissions, PM, cleaning, and reporting posture"),
        ("Cost Service Tradeoff Optimizer", "cost pressure, service reliability, ridership value, and risk exposure"),
        ("100 Bus Fleet Command Center", "rider experience, fleet health, security, cleaning, maintenance, and predictive flow state"),
    ]),
]

AGENTS = [
    "transit_rider_experience_agent",
    "transit_dispatch_agent",
    "transit_vehicle_health_agent",
    "transit_maintenance_agent",
    "transit_cleaning_agent",
    "transit_security_agent",
    "transit_energy_agent",
    "transit_depot_agent",
    "transit_workforce_agent",
    "transit_compliance_agent",
    "transit_customer_comms_agent",
    "transit_planning_agent",
    "transit_asset_agent",
    "transit_finance_agent",
    "transit_command_center_agent",
]


def slug(value: str) -> str:
    result = "".join(ch.lower() if ch.isalnum() else "-" for ch in value).strip("-")
    while "--" in result:
        result = result.replace("--", "-")
    return result


def vector_elements(values: list[int]) -> list[dict[str, float]]:
    return [{"value": value, "threshold": 0.5} for value in values]


def build_specs() -> list[tuple[str, str, str]]:
    specs: list[tuple[str, str, str]] = []
    for workstream, items in WORKSTREAMS:
        for focus, description in items:
            specs.append((workstream, focus, description))
    if len(specs) != 150:
        raise RuntimeError(f"expected exactly 150 transportation specs, got {len(specs)}")
    return specs


def upstream_index_for(index: int) -> int | None:
    # First item in each 10-machine workstream is a source. Other machines consume
    # the prior machine output, creating predictive flow chains inside each lane.
    if (index - 1) % 10 != 0:
        return index - 1

    # Workstream executive/source machines also consume prior executive outputs
    # at the domain level to form whole-fleet predictive flow management.
    cross_workstream = {
        51: 10,    # dispatch consumes rider experience executive signal
        61: 60,    # charging/fueling consumes dispatch executive signal
        71: 60,    # depot consumes dispatch executive signal
        81: 80,    # workforce consumes depot executive signal
        91: 30,    # compliance consumes maintenance executive signal
        101: 8,    # customer comms consumes customer incident response
        111: 120,  # planning consumes planning scenario feedback once looped
        121: 110,  # infrastructure consumes comms executive pulse
        131: 30,   # finance consumes maintenance cost/defect stream
        141: 140,  # executive optimization consumes finance executive
    }
    return cross_workstream.get(index)


def machine_payload(index: int, specs: list[tuple[str, str, str]]) -> dict:
    base_offset = existing_non_transportation_max_offset()
    workstream, focus, description = specs[index - 1]
    base = base_offset + (index - 1) * 8
    output_offset = base + 4
    upstream_index = upstream_index_for(index)
    input_offset = (base_offset + (upstream_index - 1) * 8 + 4) if upstream_index else base
    downstream_indices = [target for target in range(1, len(specs) + 1) if upstream_index_for(target) == index]
    upstream_name = None
    if upstream_index:
        upstream_workstream, upstream_focus, _ = specs[upstream_index - 1]
        upstream_name = f"Transportation Fleet {upstream_workstream} {upstream_focus}"
    downstream_names = [
        f"Transportation Fleet {specs[target - 1][0]} {specs[target - 1][1]}"
        for target in downstream_indices
    ]

    code = f"tfx-{index:03d}"
    agent = AGENTS[(index - 1) % len(AGENTS)]
    critical_action = f"Dispatch {agent} for critical 100-bus fleet intervention on {focus.lower()}."
    flow_action = f"Trigger predictive flow management for {focus.lower()} using rider, vehicle, and route context."
    task_action = f"Create maintenance, cleaning, security, or service task for {focus.lower()}."
    nominal_action = f"Keep 24/7 monitoring active for {focus.lower()}."

    return {
        "version": "1.0.0",
        "machine": {
            "name": f"Transportation Fleet {workstream} {focus}",
            "description": (
                f"Public transportation fleet machine for {focus.lower()} in the {workstream.lower()} workstream. "
                f"It monitors {description} for a 100-bus 24/7 operation and emits AI-triggered outputs for "
                f"rider experience, operations, maintenance, cleaning, security, and predictive fleet-flow management."
            ),
            "metadata": {
                "category": "transportation",
                "domain": f"Transportation Fleet - {workstream}",
                "author": "Reality Engine",
                "fleetSize": 100,
                "operationalFocus": focus,
                "workstream": workstream,
                "focusDescription": description,
                "upstreamMachine": upstream_name,
                "upstreamOutputRegion": f"[{input_offset}:{input_offset + 4}]" if upstream_index else None,
                "downstreamMachines": downstream_names,
                "dispatchableAgent": agent,
                "aiTrigger": f"transportation-fleet-{slug(workstream)}-{slug(focus)}",
                "predictiveFlowTrigger": f"predictive-flow-{slug(workstream)}-{slug(focus)}",
                "agentActions": [critical_action, flow_action, task_action, nominal_action],
                "criticalEventSequenceLength": 5,
                "criticalEventSequenceLengthBasis": "Every TFX machine has one critical inputSequence containing exactly 5 vectors; the generated family average is 5.0.",
                "inputSpace": f"4D binary at [{input_offset}:{input_offset + 4}]",
                "outputSpace": (
                    f"4D binary at [{output_offset}:{output_offset + 4}]: "
                    "[1,0,0,0]=CRITICAL_EVENT, [0,1,0,0]=PREDICTIVE_FLOW_ADJUST, "
                    "[0,0,1,0]=OPS_TASK, [0,0,0,1]=SERVICE_NOMINAL"
                ),
                "inputSemantics": [
                    "service reliability",
                    "rider impact",
                    "asset readiness",
                    "safety/security risk",
                ],
                "tags": [
                    "transportation",
                    "public-transit",
                    "100-bus-fleet",
                    "24x7-operations",
                    "rider-experience",
                    "vehicle-monitoring",
                    "maintenance",
                    "cleaning",
                    "security",
                    "predictive-flow",
                    slug(workstream),
                    slug(focus),
                ],
                "sequenceCount": 4,
                "reuseGuideline": (
                    "Map AVL, APC, CAD/AVL, fare, work-order, cleaning, security, rider feedback, and depot signals "
                    "into the 4D input lane. Route outputs to dispatch, service control, maintenance, cleaning, "
                    "security, customer communications, or executive fleet optimization agents."
                ),
                "downstreamPattern": (
                    f"Output region [{output_offset}:{output_offset + 4}] feeds {', '.join(downstream_names)} for predictive fleet-flow management."
                    if downstream_names else
                    f"Output region [{output_offset}:{output_offset + 4}] is available for predictive fleet-flow management."
                ),
            },
            "arbiterRule": "PASSTHROUGH",
            "perceptualMapping": {
                "input": {"offset": input_offset, "length": 4},
                "output": {"offset": output_offset, "length": 4},
            },
            "sequences": [
                {
                    "id": f"{code}-critical-event",
                    "name": f"{focus}: OBSERVE -> WATCH -> DEGRADED -> ESCALATING -> CRITICAL_EVENT",
                    "metadata": {
                        "description": "Five-step critical event sequence for 24/7 transportation operations.",
                        "sequenceLength": 5,
                        "output": "[1,0,0,0]",
                    },
                    "vectors": [
                        {"id": f"{code}-observe", "elements": vector_elements([1, 1, 1, 0]), "isInitial": True, "metadata": {"stage": "observe"}, "nextVectorIds": [f"{code}-watch"]},
                        {"id": f"{code}-watch", "elements": vector_elements([1, 1, 0, 1]), "isInitial": False, "metadata": {"stage": "watch"}, "nextVectorIds": [f"{code}-degraded"]},
                        {"id": f"{code}-degraded", "elements": vector_elements([1, 0, 0, 1]), "isInitial": False, "metadata": {"stage": "degraded"}, "nextVectorIds": [f"{code}-escalating"]},
                        {"id": f"{code}-escalating", "elements": vector_elements([0, 0, 0, 1]), "isInitial": False, "metadata": {"stage": "escalating"}, "nextVectorIds": [f"{code}-critical"]},
                        {"id": f"{code}-critical", "elements": vector_elements([0, 0, 0, 0]), "isInitial": False, "metadata": {"stage": "critical"}, "outputVectors": [{"id": f"{code}-critical-output", "vector": [1, 0, 0, 0], "metadata": {"action": critical_action}}]},
                    ],
                },
                {
                    "id": f"{code}-predictive-flow",
                    "name": f"{focus}: FLOW_RISK -> PREDICTIVE_FLOW_ADJUST",
                    "metadata": {"description": "Triggers predictive flow management before rider impact becomes critical.", "output": "[0,1,0,0]"},
                    "vectors": [
                        {"id": f"{code}-flow-risk", "elements": vector_elements([0, 1, 1, 0]), "isInitial": True, "outputVectors": [{"id": f"{code}-flow-output", "vector": [0, 1, 0, 0], "metadata": {"action": flow_action}}]},
                    ],
                },
                {
                    "id": f"{code}-ops-task",
                    "name": f"{focus}: TASK_NEEDED -> OPS_TASK",
                    "metadata": {"description": "Creates maintenance, cleaning, security, or operations tasking.", "output": "[0,0,1,0]"},
                    "vectors": [
                        {"id": f"{code}-task-needed", "elements": vector_elements([1, 0, 1, 1]), "isInitial": True, "outputVectors": [{"id": f"{code}-task-output", "vector": [0, 0, 1, 0], "metadata": {"action": task_action}}]},
                    ],
                },
                {
                    "id": f"{code}-nominal",
                    "name": f"{focus}: NOMINAL -> SERVICE_NOMINAL",
                    "metadata": {"description": "Confirms service is in an acceptable 24/7 operating band.", "output": "[0,0,0,1]"},
                    "vectors": [
                        {"id": f"{code}-nominal-state", "elements": vector_elements([1, 1, 1, 1]), "isInitial": True, "outputVectors": [{"id": f"{code}-nominal-output", "vector": [0, 0, 0, 1], "metadata": {"action": nominal_action}}]},
                    ],
                },
            ],
            "inputSequences": [
                {"name": "Critical event sequence", "description": "Five-step degradation path ending in a critical event output.", "vectors": [[1, 1, 1, 0], [1, 1, 0, 1], [1, 0, 0, 1], [0, 0, 0, 1], [0, 0, 0, 0]], "metadata": {"expectedOutputCount": 1, "expectedOutputVector": "[1,0,0,0]", "scenario": "critical-event", "sequenceLength": 5}},
                {"name": "Predictive flow adjustment", "description": "Predicts service-flow pressure before a critical event.", "vectors": [[0, 1, 1, 0]], "metadata": {"expectedOutputCount": 1, "expectedOutputVector": "[0,1,0,0]", "scenario": "predictive-flow-adjust"}},
                {"name": "Operations task", "description": "Creates maintenance, cleaning, security, or operational tasking.", "vectors": [[1, 0, 1, 1]], "metadata": {"expectedOutputCount": 1, "expectedOutputVector": "[0,0,1,0]", "scenario": "ops-task"}},
                {"name": "Nominal service", "description": "Confirms stable transportation service.", "vectors": [[1, 1, 1, 1]], "metadata": {"expectedOutputCount": 1, "expectedOutputVector": "[0,0,0,1]", "scenario": "service-nominal"}},
                {"name": "Baseline without output", "description": "Initial critical-event observation arms the sequence without firing.", "vectors": [[1, 1, 1, 0]], "metadata": {"expectedOutputCount": 0, "scenario": "baseline-no-output"}},
            ],
        },
    }


def main() -> None:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    specs = build_specs()
    for index in range(1, len(specs) + 1):
        workstream, focus, _ = specs[index - 1]
        path = OUT_DIR / f"TFX{index:03d}_{slug(workstream)}-{slug(focus)}.json"
        path.write_text(json.dumps(machine_payload(index, specs), indent=2) + "\n")
    print(f"Generated {len(specs)} transportation fleet machines in {OUT_DIR}")
    print("Critical event sequence average length: 5.0")


if __name__ == "__main__":
    main()
