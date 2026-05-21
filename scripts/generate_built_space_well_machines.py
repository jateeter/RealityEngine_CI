#!/usr/bin/env python3
"""
Generate Built-Space machines for WELL-oriented building operations.

The machine set models operational tracking, verification, and predictive
optimization for buildings adhering to WELL-aligned practices. It uses the
provided WELL operations PDF as source guidance and complements it with common
WELL concepts such as air, water, nourishment, light, movement/fitness, thermal
comfort, sound, materials, mind, community, and ongoing performance verification.
"""

from __future__ import annotations

import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
OUT_DIR = ROOT / "examples" / "machines"

SOURCE_GUIDANCE = [
    "Integrative design: stakeholder charrette, values assessment, health mission, WELL concept alignment, and O&M planning",
    "Implementation verification: letters of assurance from designers, engineers, and contractors",
    "Performance testing: on-site water, acoustic, thermal, and environmental verification",
    "Water O&M: daily dispenser cleaning, quarterly aerator/filter work, quarterly metals testing, annual reporting, and three-year records",
    "Legionella control: dedicated team, flow diagrams, hazard analysis, and critical control points",
    "Nourishment operations: cold storage ranges, allergen labeling, fryer oil controls, safe food-contact materials, and portion/sugar controls",
    "Occupant feedback: annual IEQ surveys to at least 30% of occupants and report results within 30 days",
    "Organizational wellness: health benefits, family support, sleep/travel policies, EAP/stress support, altruism, and fitness opportunities",
]

WORKSTREAMS = [
    ("Integrative Planning", [
        ("Stakeholder Charrette Tracker", "values assessment, occupant needs, owner priorities, design intent, and facility-manager participation"),
        ("Health Mission Plan Monitor", "written health mission, WELL concept coverage, scope boundaries, and O&M owner assignment"),
        ("Operations Maintenance Plan", "preventive maintenance tasks, verification cadence, responsible teams, and escalation rules"),
        ("Occupant Needs Register", "occupant demographics, accessibility needs, work patterns, wellness goals, and feedback channels"),
        ("WELL Concept Coverage Gate", "Air, Water, Nourishment, Light, Fitness, Comfort, Mind, and expanded concept coverage"),
        ("Stakeholder Decision Log", "decisions, tradeoffs, approvals, open risks, and accountable owner"),
        ("Facility Manager Onboarding", "handover sessions, system training, O&M routines, and evidence collection"),
        ("Design Operations Alignment", "design assumptions, controls strategy, operating schedule, and commissioning readiness"),
        ("WELL Governance Calendar", "annual reviews, quarterly tests, reporting deadlines, survey windows, and recertification tasks"),
        ("Integrative Executive Readiness", "planning completeness, stakeholder alignment, O&M readiness, and health-performance risk"),
    ]),
    ("Design And Biophilia", [
        ("Biophilic Area Coverage", "potted plant floor-area coverage, plant-wall coverage, maintenance health, and occupant access"),
        ("Ceiling Height Proportion", "minimum room height, room width relationship, spatial comfort, and exception tracking"),
        ("Educational Space Allocation", "classroom area per student, room utilization, flexibility, and crowding risk"),
        ("Nature View Quality", "view access, natural features, workstation coverage, and obstruction trend"),
        ("Restorative Space Operations", "quiet rooms, wellness rooms, booking pressure, cleanliness, and occupant availability"),
        ("Art Culture Integration", "art presence, local culture representation, rotation cadence, and occupant feedback"),
        ("Wayfinding Wellness", "clear signage, stair visibility, accessible paths, and cognitive-load complaints"),
        ("Outdoor Access Readiness", "terrace/courtyard availability, safety, weather readiness, and maintenance state"),
        ("Design Feature Evidence", "drawings, photos, maintenance proof, occupant feedback, and WELL feature evidence"),
        ("Design Biophilia Executive", "biophilia, spatial comfort, restorative spaces, wayfinding, and evidence readiness"),
    ]),
    ("Air Quality", [
        ("Ventilation Performance", "outdoor air delivery, occupancy load, CO2 trend, and ventilation schedule"),
        ("Filtration Maintenance", "filter MERV target, pressure drop, replacement interval, and maintenance proof"),
        ("VOC Particulate Monitoring", "TVOC, PM2.5, PM10, source events, and trend stability"),
        ("Combustion Pollutant Guard", "CO, NO2, combustion appliance status, and garage/loading dock influence"),
        ("Humidity Mold Risk", "relative humidity, dew point, condensation risk, and moisture event history"),
        ("Outdoor Air Intake Protection", "intake location, pollutant source proximity, damper status, and weather exposure"),
        ("Flush Out Purge Scheduling", "post-cleaning purge, high-occupancy purge, IAQ complaints, and recovery time"),
        ("Air Quality Incident Response", "sensor exceedance, occupant report, source isolation, and corrective action"),
        ("IAQ Evidence Archive", "sensor records, maintenance logs, work orders, and performance-test evidence"),
        ("Air Executive Optimization", "ventilation, filtration, pollutant trend, humidity risk, and occupant impact"),
    ]),
    ("Water Quality", [
        ("Dispenser Daily Cleaning", "mouthpiece cleaning, guard cleaning, lime/calcium buildup, and completion proof"),
        ("Aerator Quarterly Maintenance", "outlet screens, aerator debris, replacement need, and quarterly task completion"),
        ("Metals Quarterly Testing", "lead, arsenic, mercury, copper, sample points, and lab report status"),
        ("Turbidity Coliform Testing", "turbidity, total coliforms, sample integrity, and retest need"),
        ("Filter UVGI Maintenance", "activated carbon, sediment filters, UVGI lamp age, and sanitation performance"),
        ("Legionella Management Plan", "team assignment, flow diagram, hazard analysis, and critical control points"),
        ("Water Record Retention", "three-year record retention, annual report readiness, and evidence completeness"),
        ("Water Quality Incident Response", "failed test, point-of-use restriction, retest, remediation, and communications"),
        ("Hydration Access Monitor", "drinking water access, dispenser uptime, refill demand, and occupant availability"),
        ("Water Executive Compliance", "cleaning, testing, filtration, Legionella, records, and reporting posture"),
    ]),
    ("Nourishment", [
        ("Cold Storage Compliance", "1-4C storage, 6-12C storage, temperature excursions, and corrective action"),
        ("Raw Food Separation", "raw meat drawer location, cleanable surfaces, separation proof, and cross-contamination risk"),
        ("Cutting Board Wear Monitor", "raw/ready board separation, groove severity, replacement need, and sanitation proof"),
        ("Food Contact Materials", "polystyrene avoidance, safe cookware materials, and procurement checks"),
        ("Fryer Oil Quality", "total polar materials, discard threshold, testing log, and replacement action"),
        ("Allergen Ingredient Labeling", "11 allergen flags, artificial ingredients, label accuracy, and menu change control"),
        ("Sugar Portion Control", "dishware size, beverage sugar, non-beverage sugar, and menu compliance"),
        ("Special Diet Availability", "gluten-free, lactose-free, vegan options, demand signal, and stocking readiness"),
        ("Food Safety Audit Archive", "temperature logs, labels, material checks, corrective actions, and inspection evidence"),
        ("Nourishment Executive Assurance", "storage, preparation, labeling, portioning, diet access, and evidence posture"),
    ]),
    ("Light And Circadian", [
        ("Daylight Access Monitor", "daylight availability, glare risk, window shading, and occupied-zone coverage"),
        ("Circadian Lighting Schedule", "time-of-day spectrum, intensity, control schedule, and occupant exposure"),
        ("Glare Control Response", "luminance contrast, screen complaints, shade automation, and task-light adjustment"),
        ("Electric Light Quality", "flicker, color rendering, dimming stability, and fixture maintenance"),
        ("Lighting Controls Usability", "occupant override, scene schedule, sensor status, and control complaints"),
        ("Night Shift Light Policy", "late-work exposure, low-glare settings, circadian disruption, and policy adherence"),
        ("Light Commissioning Evidence", "measurement points, calibration, test results, and corrective actions"),
        ("Daylight Energy Optimization", "daylight harvesting, shade state, HVAC solar load, and energy/comfort balance"),
        ("Lighting Maintenance Planner", "lamp/driver faults, cleaning, calibration, and replacement priority"),
        ("Light Executive Optimization", "circadian support, glare, controls, maintenance, and occupant feedback"),
    ]),
    ("Thermal Comfort", [
        ("ASHRAE 55 Comfort Monitor", "air temperature, radiant temperature, humidity, air speed, clothing, and metabolic assumptions"),
        ("Radiant System Coverage", "radiant heating/cooling coverage, hydronic/electric status, and occupied-zone effectiveness"),
        ("Thermal Complaint Triage", "hot/cold complaints, zone trend, occupancy pattern, and response SLA"),
        ("Seasonal Setpoint Optimization", "weather forecast, occupancy schedule, energy target, and comfort drift"),
        ("Humidity Comfort Balance", "relative humidity, dry-air complaints, mold risk, and humidification/dehumidification action"),
        ("Thermal Sensor Calibration", "sensor drift, calibration age, reference check, and BAS reliability"),
        ("Envelope Thermal Resilience", "solar gain, infiltration, insulation issue, and weather event exposure"),
        ("Personal Comfort Support", "local fans, task heating, flexible seating, and occupant choice"),
        ("Thermal Performance Testing", "test points, occupied periods, acceptance criteria, and evidence archive"),
        ("Thermal Executive Optimization", "comfort, energy, humidity, complaints, sensor health, and weather forecast"),
    ]),
    ("Sound And Acoustics", [
        ("HVAC Noise Criteria", "NC targets, equipment noise, duct noise, and occupied workspace readings"),
        ("Sound Masking Level", "45-48 dBA masking target, open-workspace coverage, and tuning status"),
        ("Partition STC Verification", "STC 40 office targets, STC 53 conference targets, penetrations, and field issues"),
        ("Acoustic Seal Integrity", "top/bottom tracks, gypsum seams, wall penetrations, and construction punchlist"),
        ("Background Noise Complaints", "distraction reports, source classification, time pattern, and mitigation plan"),
        ("Meeting Privacy Monitor", "speech privacy, conference-room leakage, masking balance, and confidentiality risk"),
        ("Acoustic Performance Testing", "measurement plan, assessor results, corrective action, and evidence archive"),
        ("Vibration Disturbance Monitor", "mechanical vibration, structural transmission, occupant reports, and isolation status"),
        ("Quiet Zone Operations", "focus spaces, quiet hours, signage, and compliance trend"),
        ("Sound Executive Optimization", "noise criteria, masking, partitions, complaints, privacy, and verification readiness"),
    ]),
    ("Materials And Cleaning", [
        ("Material Transparency Register", "Declare labels, HPDs, equivalent reporting, cost share, and product documentation"),
        ("Interior Finish Compliance", "finish inventory, reporting coverage, replacement planning, and procurement rule"),
        ("Cleaning Product Safety", "product ingredients, fragrance policy, dilution controls, and staff training"),
        ("Cleaning Schedule Assurance", "cleaning frequency, high-touch surfaces, restrooms, and completion proof"),
        ("Pest Management Safety", "least-toxic controls, treatment records, occupant notices, and trigger thresholds"),
        ("Waste Recycling Operations", "waste streams, contamination rate, pickup schedule, and occupant signage"),
        ("Moisture Materials Risk", "wet materials, drying time, mold-prone assemblies, and remediation status"),
        ("Construction Dust Control", "dust isolation, walk-off mats, cleaning proof, and post-work purge"),
        ("Materials Evidence Archive", "labels, SDS, procurement records, cleaning logs, and audit readiness"),
        ("Materials Executive Assurance", "transparency, cleaning, waste, pest control, moisture, and evidence posture"),
    ]),
    ("Movement And Fitness", [
        ("Active Stair Promotion", "stair visibility, signage, lighting, cleanliness, and use trend"),
        ("Fitness Program Cadence", "monthly fitness training, quarterly education, participation, and instructor schedule"),
        ("Active Transportation Support", "bike storage, shower access, payroll deductions, and commuting uptake"),
        ("Ergonomic Workstation Monitor", "chair fit, desk height, monitor position, and ergonomic assessment queue"),
        ("Sedentary Behavior Prompting", "occupancy pattern, break reminders, meeting length, and movement opportunity"),
        ("Gym Reimbursement Eligibility", "50-visit minimum, reimbursement status, employee participation, and policy evidence"),
        ("Accessible Movement Paths", "clear routes, ramps, elevators, door forces, and obstruction reports"),
        ("Outdoor Movement Connection", "walking route access, weather readiness, safety, and biophilic route quality"),
        ("Movement Feedback Archive", "program attendance, workstation issues, occupant feedback, and corrective action"),
        ("Movement Executive Optimization", "fitness programming, ergonomics, active transport, accessibility, and engagement"),
    ]),
    ("Mind And Wellness Policy", [
        ("EAP Counselor Access", "EAP availability, counselor coverage, referral path, and utilization trend"),
        ("Stress Addiction Support", "stress, anxiety, addiction support access, confidentiality, and response capacity"),
        ("Late Night Communication Cap", "midnight work-communication cap, exception tracking, and manager compliance"),
        ("Sleep Support Program", "sleep software subsidy, uptake, education, and fatigue risk"),
        ("Travel Wellness Policy", "red-eye avoidance, total travel cap, hotel fitness access, and policy exceptions"),
        ("Volunteer Time Program", "8-hour volunteer allowance, twice-yearly availability, participation, and manager approval"),
        ("Charitable Match Program", "match eligibility, budget, participation, and reporting evidence"),
        ("Mental Health Resource Awareness", "communications cadence, stigma reduction, resource visibility, and feedback"),
        ("Mind Policy Evidence Archive", "policy documents, participation records, exceptions, and review cadence"),
        ("Mind Executive Support", "EAP, sleep, travel, volunteerism, charitable match, and stress-support posture"),
    ]),
    ("Community And HR", [
        ("Health Benefits Coverage", "health insurance, FSA, HSA, immunization access, sick-stay-home policy, and communication"),
        ("Paid Family Leave", "six-week paid leave, twelve-week unpaid leave, eligibility, and case tracking"),
        ("Childcare Support", "subsidy, on-site center access, capacity, and employee need"),
        ("Nursing Mother Breaks", "15-minute breaks every 3 hours, lactation space, scheduling, and privacy"),
        ("Occupant Transparency Reporting", "JUST, GRI, public disclosure, update cadence, and stakeholder access"),
        ("Equity Accessibility Governance", "inclusive policies, accommodation requests, accessibility issues, and response SLA"),
        ("Community Engagement Calendar", "community events, stakeholder feedback, service opportunities, and partnership health"),
        ("Emergency Preparedness Wellness", "emergency plans, vulnerable occupants, air/water contingencies, and communications"),
        ("Community Evidence Archive", "benefit records, leave records, transparency reports, and policy review"),
        ("Community Executive Assurance", "benefits, family support, transparency, equity, emergency wellness, and evidence posture"),
    ]),
    ("Occupant Feedback", [
        ("Annual IEQ Survey Launch", "CBE survey timing, occupant list, communication plan, and launch readiness"),
        ("Thirty Percent Response Monitor", "response rate, representativeness, reminders, and participation risk"),
        ("Acoustics Feedback Analyzer", "noise, privacy, distraction, zone, and corrective-action clustering"),
        ("Thermal Feedback Analyzer", "hot/cold reports, humidity comments, seasonal pattern, and BAS correlation"),
        ("Lighting Feedback Analyzer", "glare, dimness, flicker, control usability, and zone issues"),
        ("Odor Cleanliness Feedback", "odor reports, cleaning perception, restroom comments, and source tracing"),
        ("Furnishings Feedback Analyzer", "comfort, ergonomics, adjustability, and procurement implications"),
        ("Survey Reporting Deadline", "30-day owner/manager/occupant/IWBI reporting deadline and evidence package"),
        ("Feedback Corrective Action Loop", "issue owner, work order, occupant communication, and closure verification"),
        ("Feedback Executive Pulse", "response rate, key risks, corrective-action backlog, and occupant satisfaction trend"),
    ]),
    ("Performance Verification", [
        ("Letters Assurance Tracker", "architect, engineer, contractor, and owner letters of assurance status"),
        ("On Site Testing Schedule", "assessor visit, testing scope, access coordination, and readiness checklist"),
        ("Water Performance Evidence", "turbidity, coliforms, organic/inorganic contaminants, metals, and retest status"),
        ("Acoustic Thermal Evidence", "sound readings, thermal readings, test conditions, and acceptance status"),
        ("Air Light Evidence", "air sensor logs, lighting measurements, calibration records, and corrective action"),
        ("WELL Documentation Completeness", "feature documentation, policies, logs, drawings, and responsible owner"),
        ("Annual IWBI Reporting", "annual submissions, due dates, report completeness, and acknowledgment tracking"),
        ("Recertification Readiness", "feature drift, evidence age, performance gaps, and renewal planning"),
        ("Verification Exception Triage", "failed test, missing evidence, waiver/escalation path, and owner decision"),
        ("Verification Executive Dashboard", "assurance, testing, documentation, reporting, exceptions, and recertification readiness"),
    ]),
    ("Predictive Operations", [
        ("Health Performance Forecast", "sensor trends, survey trends, work orders, policy compliance, and certification risk"),
        ("IAQ Energy Tradeoff Optimizer", "ventilation, filtration, energy use, occupancy forecast, and pollutant risk"),
        ("Water Risk Predictor", "maintenance age, test trend, stagnation risk, Legionella controls, and complaint signal"),
        ("Nourishment Risk Predictor", "temperature excursions, labeling changes, menu updates, and audit findings"),
        ("Comfort Demand Predictor", "weather, occupancy, thermal complaints, acoustic issues, and lighting complaints"),
        ("Maintenance Backlog Optimizer", "criticality, occupant impact, evidence deadline, technician capacity, and cost"),
        ("Policy Compliance Predictor", "benefits, leave, sleep, travel, volunteer, and fitness program adherence"),
        ("Occupant Satisfaction Predictor", "survey trend, complaints, work-order closure, and zone-level health signal"),
        ("WELL Drift Early Warning", "feature drift, failed checks, missing records, occupant impact, and reporting deadline"),
        ("Built Space Command Center", "all WELL concepts, predictive risks, evidence readiness, occupant health, and operational optimization"),
    ]),
]

AGENTS = [
    "well_integrative_agent",
    "well_air_quality_agent",
    "well_water_quality_agent",
    "well_nourishment_agent",
    "well_light_agent",
    "well_thermal_agent",
    "well_acoustic_agent",
    "well_materials_cleaning_agent",
    "well_movement_agent",
    "well_mind_policy_agent",
    "well_community_hr_agent",
    "well_feedback_agent",
    "well_verification_agent",
    "well_predictive_ops_agent",
    "built_space_command_agent",
]


def slug(value: str) -> str:
    result = "".join(ch.lower() if ch.isalnum() else "-" for ch in value).strip("-")
    while "--" in result:
        result = result.replace("--", "-")
    return result


def vector_elements(values: list[int]) -> list[dict[str, float]]:
    return [{"value": value, "threshold": 0.5} for value in values]


def existing_non_built_space_max_offset() -> int:
    max_offset = 0
    if not OUT_DIR.exists():
        return max_offset
    for path in OUT_DIR.glob("*.json"):
        if path.name.startswith("BSX"):
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


def build_specs() -> list[tuple[str, str, str]]:
    specs: list[tuple[str, str, str]] = []
    for workstream, items in WORKSTREAMS:
        for focus, description in items:
            specs.append((workstream, focus, description))
    if len(specs) != 150:
        raise RuntimeError(f"expected exactly 150 built-space specs, got {len(specs)}")
    return specs


def upstream_index_for(index: int) -> int | None:
    if (index - 1) % 10 != 0:
        return index - 1
    cross_workstream = {
        11: 10,
        21: 20,
        31: 30,
        41: 10,
        51: 20,
        61: 20,
        71: 40,
        81: 10,
        91: 10,
        101: 10,
        111: 100,
        121: 10,
        131: 120,
        141: 130,
    }
    return cross_workstream.get(index)


def machine_payload(index: int, specs: list[tuple[str, str, str]], base_offset: int) -> dict:
    workstream, focus, description = specs[index - 1]
    base = base_offset + (index - 1) * 8
    output_offset = base + 4
    upstream_index = upstream_index_for(index)
    input_offset = (base_offset + (upstream_index - 1) * 8 + 4) if upstream_index else base
    downstream_indices = [target for target in range(1, len(specs) + 1) if upstream_index_for(target) == index]
    upstream_name = None
    if upstream_index:
        upstream_workstream, upstream_focus, _ = specs[upstream_index - 1]
        upstream_name = f"Built Space WELL {upstream_workstream} {upstream_focus}"
    downstream_names = [
        f"Built Space WELL {specs[target - 1][0]} {specs[target - 1][1]}"
        for target in downstream_indices
    ]

    code = f"bsx-{index:03d}"
    agent = AGENTS[(index - 1) % len(AGENTS)]
    verify_action = f"Dispatch {agent} to verify WELL operational conformance for {focus.lower()}."
    optimize_action = f"Run predictive optimization for {focus.lower()} using occupant, system, and evidence trends."
    work_order_action = f"Create an operations, maintenance, policy, or evidence work order for {focus.lower()}."
    compliant_action = f"Mark {focus.lower()} in the current compliant operating window."

    return {
        "version": "1.0.0",
        "machine": {
            "name": f"Built Space WELL {workstream} {focus}",
            "description": (
                f"Built-Space domain machine for WELL-oriented {focus.lower()} in the {workstream.lower()} workstream. "
                f"It monitors {description} and emits AI-triggered outputs for verification, predictive optimization, "
                f"operations work, and sustained compliant operation."
            ),
            "metadata": {
                "category": "built-space",
                "domain": f"Built Space - WELL {workstream}",
                "author": "Reality Engine",
                "standardFocus": "WELL Building Standard operations",
                "workstream": workstream,
                "operationalFocus": focus,
                "focusDescription": description,
                "sourceGuidance": SOURCE_GUIDANCE,
                "upstreamMachine": upstream_name,
                "upstreamOutputRegion": f"[{input_offset}:{input_offset + 4}]" if upstream_index else None,
                "downstreamMachines": downstream_names,
                "dispatchableAgent": agent,
                "aiTrigger": f"built-space-well-{slug(workstream)}-{slug(focus)}",
                "predictiveOptimizationTrigger": f"well-predictive-optimization-{slug(workstream)}-{slug(focus)}",
                "agentActions": [verify_action, optimize_action, work_order_action, compliant_action],
                "inputSpace": f"4D binary at [{input_offset}:{input_offset + 4}]",
                "outputSpace": (
                    f"4D binary at [{output_offset}:{output_offset + 4}]: "
                    "[1,0,0,0]=VERIFY_WELL_CONFORMANCE, [0,1,0,0]=PREDICTIVE_OPTIMIZE, "
                    "[0,0,1,0]=OPS_WORK_ORDER, [0,0,0,1]=COMPLIANT_WINDOW"
                ),
                "inputSemantics": [
                    "health-performance signal stable",
                    "evidence or policy current",
                    "maintenance or operational drift pressure",
                    "occupant impact or wellness risk",
                ],
                "tags": [
                    "built-space",
                    "well-building-standard",
                    "well-operations",
                    "predictive-optimization",
                    "verification",
                    "occupant-health",
                    slug(workstream),
                    slug(focus),
                ],
                "sequenceCount": 5,
                "reuseGuideline": (
                    "Map BAS, IAQ, water, food-service, cleaning, HR policy, survey, maintenance, and verification evidence "
                    "signals into the 4D input lane. Route outputs to verification queues, predictive optimizers, work-order "
                    "systems, occupant communications, and WELL evidence dashboards."
                ),
                "downstreamPattern": (
                    f"Output region [{output_offset}:{output_offset + 4}] feeds {', '.join(downstream_names)} for WELL operations optimization."
                    if downstream_names else
                    f"Output region [{output_offset}:{output_offset + 4}] is available to WELL operations and predictive optimization workflows."
                ),
            },
            "arbiterRule": "PASSTHROUGH",
            "perceptualMapping": {
                "input": {"offset": input_offset, "length": 4},
                "output": {"offset": output_offset, "length": 4},
            },
            "sequences": [
                {
                    "id": f"{code}-verify",
                    "name": f"{focus}: WATCH -> EVIDENCE_GAP -> VERIFY_WELL_CONFORMANCE",
                    "metadata": {"description": "Escalates when operational or evidence drift requires WELL conformance verification.", "output": "[1,0,0,0]"},
                    "vectors": [
                        {"id": f"{code}-watch", "elements": vector_elements([1, 0, 1, 1]), "isInitial": True, "nextVectorIds": [f"{code}-evidence-gap"]},
                        {"id": f"{code}-evidence-gap", "elements": vector_elements([0, 0, 1, 1]), "isInitial": False, "outputVectors": [{"id": f"{code}-verify-output", "vector": [1, 0, 0, 0], "metadata": {"action": verify_action}}]},
                    ],
                },
                {
                    "id": f"{code}-optimize",
                    "name": f"{focus}: FORECAST_DRIFT -> PREDICTIVE_OPTIMIZE",
                    "metadata": {"description": "Triggers predictive building optimization before occupant wellness degrades.", "output": "[0,1,0,0]"},
                    "vectors": [
                        {"id": f"{code}-forecast-drift", "elements": vector_elements([0, 1, 0, 1]), "isInitial": True, "outputVectors": [{"id": f"{code}-optimize-output", "vector": [0, 1, 0, 0], "metadata": {"action": optimize_action}}]},
                    ],
                },
                {
                    "id": f"{code}-work-order",
                    "name": f"{focus}: ACTION_NEEDED -> OPS_WORK_ORDER",
                    "metadata": {"description": "Creates an operations, maintenance, policy, or evidence task.", "output": "[0,0,1,0]"},
                    "vectors": [
                        {"id": f"{code}-action-needed", "elements": vector_elements([1, 0, 0, 1]), "isInitial": True, "outputVectors": [{"id": f"{code}-work-order-output", "vector": [0, 0, 1, 0], "metadata": {"action": work_order_action}}]},
                    ],
                },
                {
                    "id": f"{code}-compliant",
                    "name": f"{focus}: CURRENT -> COMPLIANT_WINDOW",
                    "metadata": {"description": "Confirms current WELL-aligned operational posture.", "output": "[0,0,0,1]"},
                    "vectors": [
                        {"id": f"{code}-current", "elements": vector_elements([1, 1, 0, 0]), "isInitial": True, "outputVectors": [{"id": f"{code}-compliant-output", "vector": [0, 0, 0, 1], "metadata": {"action": compliant_action}}]},
                    ],
                },
                {
                    "id": f"{code}-predictive-24h",
                    "name": f"{focus}: 0-6H -> 6-12H -> 12-18H -> 18-24H -> PREDICTIVE_OPTIMIZE",
                    "metadata": {"description": "Projects WELL operations forward over 24 hours and optimizes before health-performance drift.", "projectionHorizon": "24h", "output": "[0,1,0,0]"},
                    "vectors": [
                        {"id": f"{code}-0-6h", "elements": vector_elements([1, 1, 1, 0]), "isInitial": True, "nextVectorIds": [f"{code}-6-12h"]},
                        {"id": f"{code}-6-12h", "elements": vector_elements([1, 0, 1, 0]), "isInitial": False, "nextVectorIds": [f"{code}-12-18h"]},
                        {"id": f"{code}-12-18h", "elements": vector_elements([0, 0, 1, 0]), "isInitial": False, "nextVectorIds": [f"{code}-18-24h"]},
                        {"id": f"{code}-18-24h", "elements": vector_elements([0, 1, 1, 0]), "isInitial": False, "outputVectors": [{"id": f"{code}-projection-output", "vector": [0, 1, 0, 0], "metadata": {"action": optimize_action, "projectionHorizon": "24h"}}]},
                    ],
                },
            ],
            "inputSequences": [
                {"name": "Verify WELL conformance", "description": "Evidence or operational drift requires verification.", "vectors": [[1, 0, 1, 1], [0, 0, 1, 1]], "metadata": {"expectedOutputCount": 1, "expectedOutputVector": "[1,0,0,0]", "scenario": "verify-well-conformance"}},
                {"name": "Predictive optimization", "description": "Forecasted drift should be optimized before occupant impact.", "vectors": [[0, 1, 0, 1]], "metadata": {"expectedOutputCount": 1, "expectedOutputVector": "[0,1,0,0]", "scenario": "predictive-optimize"}},
                {"name": "Operations work order", "description": "Operations, maintenance, policy, or evidence action is needed.", "vectors": [[1, 0, 0, 1]], "metadata": {"expectedOutputCount": 1, "expectedOutputVector": "[0,0,1,0]", "scenario": "ops-work-order"}},
                {"name": "Compliant operating window", "description": "Current operating posture is compliant.", "vectors": [[1, 1, 0, 0]], "metadata": {"expectedOutputCount": 1, "expectedOutputVector": "[0,0,0,1]", "scenario": "compliant-window"}},
                {"name": "24-hour predictive optimization", "description": "Forecasts 24-hour WELL performance drift and emits optimization.", "vectors": [[1, 1, 1, 0], [1, 0, 1, 0], [0, 0, 1, 0], [0, 1, 1, 0]], "metadata": {"expectedOutputCount": 1, "expectedOutputVector": "[0,1,0,0]", "scenario": "24h-predictive-optimize"}},
                {"name": "Baseline without output", "description": "Initial watch state arms verification without firing.", "vectors": [[1, 0, 1, 1]], "metadata": {"expectedOutputCount": 0, "scenario": "baseline-no-output"}},
            ],
        },
    }


def main() -> None:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    specs = build_specs()
    base_offset = existing_non_built_space_max_offset()
    for index in range(1, len(specs) + 1):
        workstream, focus, _ = specs[index - 1]
        path = OUT_DIR / f"BSX{index:03d}_{slug(workstream)}-{slug(focus)}.json"
        path.write_text(json.dumps(machine_payload(index, specs, base_offset), indent=2) + "\n")
    print(f"Generated {len(specs)} Built-Space WELL machines in {OUT_DIR}")


if __name__ == "__main__":
    main()
