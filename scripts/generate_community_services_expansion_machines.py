#!/usr/bin/env python3
"""
Generate expanded community-services machines.

The generated family covers city health and human services, public safety and
law-enforcement coordination, and homelessness response. Selected machines are
intentionally connected to health-services and transportation vector regions so
community operations can exchange escalation, referral, mobility, and public
health signals across domain boundaries.
"""

from __future__ import annotations

import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
OUT_DIR = ROOT / "examples" / "machines"


WORKSTREAMS = [
    ("Health And Human Services Intake", [
        ("Resident Intake Triage", "walk-in, call-center, and digital intake severity with consent and identity readiness"),
        ("Case Routing Coordinator", "resident needs, program fit, staff capacity, and response SLA"),
        ("Multilingual Access Monitor", "language need, interpreter availability, translated material readiness, and appointment risk"),
        ("Disability Accommodation Router", "ADA accommodation request, service barriers, provider readiness, and follow-up needs"),
        ("Family Stabilization Intake", "household instability, child needs, income pressure, and urgent resource gaps"),
        ("Aging Services Intake", "older adult isolation, nutrition, mobility, caregiver support, and wellness risk"),
        ("Veterans Services Intake", "veteran status, benefit eligibility, housing risk, and behavioral health referral need"),
        ("Immigrant Refugee Navigation", "documentation, legal-service referral, language access, and family support needs"),
        ("Crisis Benefit Intake", "utility shutoff, food insecurity, eviction risk, and immediate relief eligibility"),
        ("Human Services Intake Executive", "intake backlog, urgent cases, staff capacity, equity impact, and service stability"),
    ]),
    ("Benefits And Eligibility", [
        ("Medicaid Renewal Watch", "renewal deadline, documentation readiness, coverage loss risk, and outreach status"),
        ("SNAP Eligibility Monitor", "household income, food insecurity, documents, and recertification risk"),
        ("TANF Case Pathway", "family composition, work requirements, support services, and compliance risk"),
        ("WIC Referral Coordinator", "pregnancy, infant nutrition, appointment availability, and clinic routing"),
        ("Utility Assistance Queue", "arrears, shutoff notice, weather exposure, and funding availability"),
        ("Rental Assistance Triage", "eviction status, income shock, landlord coordination, and fund eligibility"),
        ("Document Readiness Monitor", "identity proof, residency proof, income proof, and missing evidence"),
        ("Benefits Fraud Integrity", "duplicate signals, anomaly flags, resident burden, and investigation threshold"),
        ("Enrollment Completion Monitor", "application status, staff handoff, resident follow-up, and closure risk"),
        ("Benefits Executive Optimizer", "benefit demand, eligibility bottlenecks, equity gaps, and funding pressure"),
    ]),
    ("Behavioral Health And Crisis", [
        ("988 Warm Handoff Router", "crisis-line referral, consent, acuity, and mobile-response readiness"),
        ("Mobile Crisis Co Response", "behavioral acuity, field safety, clinician availability, and law-enforcement support"),
        ("Substance Use Outreach", "overdose risk, harm-reduction need, treatment readiness, and peer-support capacity"),
        ("Mental Health Shelter Referral", "unsheltered distress, shelter fit, clinical follow-up, and transport need"),
        ("Youth Crisis Pathway", "minor safety, family contact, school partner, and mandated reporting threshold"),
        ("Post Crisis Follow Up", "discharge plan, appointment adherence, medication access, and relapse risk"),
        ("Naloxone Supply Monitor", "distribution rate, hotspot demand, stock levels, and outreach deployment"),
        ("Community Violence Trauma Support", "incident exposure, victim service need, counseling capacity, and safety plan"),
        ("Behavioral Health Data Sharing", "consent, privacy constraint, referral status, and care-team visibility"),
        ("Behavioral Crisis Executive", "crisis volume, field capacity, public safety load, and stabilization outcome trend"),
    ]),
    ("Law Enforcement And Public Safety", [
        ("Non Emergency Call Triage", "311/dispatch call type, urgency, safety risk, and alternate service path"),
        ("Community Policing Beat Monitor", "beat activity, resident concerns, repeat calls, and trust-building opportunity"),
        ("Public Safety Hotspot Watch", "incident clustering, event context, lighting/transit access, and patrol readiness"),
        ("Domestic Violence Response", "victim safety, lethality risk, advocate availability, and protective-order support"),
        ("Missing Vulnerable Person Coordination", "age, cognitive risk, last location, transit linkage, and search coordination"),
        ("Traffic Safety Enforcement", "collision risk, pedestrian exposure, complaint trend, and engineering referral"),
        ("Body Camera Evidence Workflow", "incident priority, retention deadline, redaction load, and prosecutor request"),
        ("Public Event Safety Planner", "crowd forecast, transit demand, weather, and staffing posture"),
        ("Code Enforcement Referral", "property hazard, resident vulnerability, repeat violation, and remediation path"),
        ("Public Safety Executive", "call load, hotspot risk, field staffing, community impact, and prevention opportunity"),
    ]),
    ("Courts Diversion And Victim Services", [
        ("Pre Arrest Diversion Router", "eligible offense, behavioral need, victim impact, and service slot availability"),
        ("Citation Court Reminder", "court date, contactability, transport barrier, and failure-to-appear risk"),
        ("Community Service Placement", "court requirement, worksite capacity, resident constraints, and completion proof"),
        ("Restorative Justice Referral", "case eligibility, participant consent, facilitator capacity, and safety screen"),
        ("Victim Advocate Assignment", "case severity, language access, trauma support, and legal-service referral"),
        ("Protection Order Support", "order status, service completion, safety planning, and violation risk"),
        ("Reentry Services Coordinator", "release timing, housing need, ID documents, and employment support"),
        ("Juvenile Diversion Monitor", "school connection, family support, court status, and service adherence"),
        ("Fine Fee Relief Triage", "ability to pay, court balance, hardship proof, and relief pathway"),
        ("Diversion Victim Services Executive", "diversion capacity, victim needs, court deadlines, and recidivism risk"),
    ]),
    ("Homelessness Outreach", [
        ("Street Outreach Triage", "encounter acuity, consent, location risk, and immediate service match"),
        ("Encampment Risk Assessment", "fire risk, sanitation, resident vulnerability, and outreach engagement history"),
        ("Unsheltered Health Referral", "medical need, behavioral health need, mobile clinic availability, and transport barrier"),
        ("Cold Weather Outreach", "temperature forecast, exposed residents, warming center capacity, and transport readiness"),
        ("Heat Smoke Outreach", "heat index, smoke exposure, hydration access, and cooling center activation"),
        ("Hygiene Service Access", "shower, laundry, restroom availability, ID requirements, and transit proximity"),
        ("Meal Outreach Routing", "food-service schedule, dietary need, location cluster, and volunteer capacity"),
        ("Pet Companion Accommodation", "pet presence, shelter barrier, veterinary need, and placement option"),
        ("Outreach Safety Monitor", "field-team safety, conflict signal, backup availability, and time-of-day risk"),
        ("Homeless Outreach Executive", "outreach coverage, urgent risk, engagement progress, and service saturation"),
    ]),
    ("Shelter Housing And Supportive Services", [
        ("Shelter Bed Availability", "bed inventory, demographic fit, accessibility needs, and intake cutoff"),
        ("Coordinated Entry Queue", "vulnerability score, document readiness, referral priority, and match status"),
        ("Housing Voucher Navigation", "voucher status, unit search, landlord acceptance, and inspection timing"),
        ("Rapid Rehousing Progress", "rental assistance, case contact, lease-up milestone, and stabilization risk"),
        ("Permanent Supportive Housing Match", "chronic status, service need, unit availability, and clinical partner readiness"),
        ("Shelter Incident Response", "resident safety, staff capacity, conflict level, and external assist need"),
        ("Shelter Health Isolation", "infectious symptom signal, room capacity, public health referral, and care plan"),
        ("Eviction Prevention Bridge", "court date, arrears, mediation option, and homelessness prevention priority"),
        ("Housing Retention Monitor", "rent payment, lease compliance, service engagement, and recertification risk"),
        ("Housing Services Executive", "bed pressure, housing placements, retention risk, and supportive-service capacity"),
    ]),
    ("City Service Operations", [
        ("311 Service Request Router", "request type, resident vulnerability, field crew capacity, and response deadline"),
        ("Sanitation Hazard Dispatch", "illegal dumping, biohazard risk, encampment proximity, and crew readiness"),
        ("Streetlight Safety Repair", "lighting outage, safety hotspot, transit stop proximity, and repair priority"),
        ("Sidewalk Accessibility Work Order", "obstruction, curb condition, ADA impact, and repair scheduling"),
        ("Public Restroom Operations", "facility availability, cleaning state, supply status, and security concern"),
        ("Cooling Warming Center Activation", "weather trigger, building capacity, staff readiness, and transportation link"),
        ("Library Social Service Hub", "patron need, staff escalation, partner availability, and safety support"),
        ("Park Outreach Coordination", "park use, unsheltered presence, sanitation need, and public safety concern"),
        ("Volunteer Donation Logistics", "donation supply, volunteer roster, service demand, and distribution control"),
        ("City Services Executive", "311 backlog, field capacity, service equity, and operational risk"),
    ]),
    ("Community Executive Optimization", [
        ("Community Need Forecast", "seasonality, event signals, service demand, and neighborhood vulnerability"),
        ("Cross Agency Case Graph", "case touchpoints, consent state, duplicate services, and unresolved dependencies"),
        ("Equity Service Gap Monitor", "neighborhood service rate, demographic need, language access, and outcome disparity"),
        ("Funding Capacity Optimizer", "grant restrictions, program demand, staff capacity, and fiscal runway"),
        ("Interagency Dispatch Board", "health, transit, police, shelter, and public works action readiness"),
        ("Privacy Consent Governance", "data sharing purpose, consent scope, retention rule, and audit status"),
        ("Predictive Prevention Planner", "early warning signals, upstream intervention option, and avoided crisis value"),
        ("Community Operations Digital Twin", "current load, forecast risk, resource allocation, and cross-domain throughput"),
        ("Public Trust Feedback Loop", "resident sentiment, complaint closure, outreach quality, and transparency readiness"),
        ("Community Services Command Center", "health and human services, public safety, homelessness, transit access, and city operations posture"),
    ]),
]

AGENTS = [
    "community_intake_agent",
    "benefits_navigation_agent",
    "behavioral_crisis_agent",
    "public_safety_agent",
    "victim_services_agent",
    "homeless_outreach_agent",
    "housing_services_agent",
    "city_operations_agent",
    "community_command_agent",
]


def slug(value: str) -> str:
    result = "".join(ch.lower() if ch.isalnum() else "-" for ch in value).strip("-")
    while "--" in result:
        result = result.replace("--", "-")
    return result


def vector_elements(values: list[int]) -> list[dict]:
    return [{"value": value} for value in values]


def existing_non_community_max_offset() -> int:
    max_offset = 0
    if not OUT_DIR.exists():
        return max_offset
    for path in OUT_DIR.glob("*.json"):
        if path.name.startswith("CSX"):
            continue
        try:
            document = json.loads(path.read_text())
        except json.JSONDecodeError:
            continue
        mapping = document.get("machine", {}).get("perceptualMapping", {})
        for side in ("input", "output"):
            region = mapping.get(side)
            if region:
                max_offset = max(max_offset, int(region["offset"]) + int(region["length"]))
    return max_offset


def region_for(prefix: str, index: int, side: str) -> tuple[int, int]:
    pattern = f"{prefix}{index:03d}_*.json"
    matches = sorted(OUT_DIR.glob(pattern))
    if not matches:
        raise RuntimeError(f"missing machine for {prefix}{index:03d}")
    document = json.loads(matches[0].read_text())
    region = document["machine"]["perceptualMapping"][side]
    return int(region["offset"]), int(region["length"])


def build_specs() -> list[tuple[str, str, str]]:
    specs: list[tuple[str, str, str]] = []
    for workstream, items in WORKSTREAMS:
        for focus, description in items:
            specs.append((workstream, focus, description))
    if len(specs) != 90:
        raise RuntimeError(f"expected exactly 90 community-services specs, got {len(specs)}")
    return specs


def upstream_index_for(index: int) -> int | None:
    if (index - 1) % 10 != 0:
        return index - 1
    cross_workstream = {
        11: 10,
        21: 20,
        31: 30,
        41: 40,
        51: 30,
        61: 60,
        71: 70,
        81: 80,
    }
    return cross_workstream.get(index)


def external_input_override(index: int) -> tuple[str, int, int, str] | None:
    health_links = {
        23: (141, "behavioral health crisis signal"),
        24: (142, "behavioral health resource routing"),
        33: (181, "emergency preparedness signal"),
        53: (131, "care coordination signal"),
        63: (101, "community health outcomes signal"),
        67: (171, "environmental health response signal"),
        75: (111, "foundational public health signal"),
        85: (191, "learning health system signal"),
    }
    transit_links = {
        35: (41, "onboard public safety alert"),
        56: (108, "emergency communication signal"),
        65: (54, "relief bus allocation signal"),
        66: (49, "weather hazard safety signal"),
        76: (51, "fleet pullout readiness signal"),
        83: (121, "stop shelter condition signal"),
        86: (57, "detour coordination signal"),
        90: (150, "fleet command center signal"),
    }
    if index in health_links:
        machine_index, purpose = health_links[index]
        offset, length = region_for("HSPH", machine_index, "output")
        return ("health-services", offset, length, purpose)
    if index in transit_links:
        machine_index, purpose = transit_links[index]
        offset, length = region_for("TFX", machine_index, "output")
        return ("transportation", offset, length, purpose)
    return None


def external_output_override(index: int) -> tuple[str, int, int, str] | None:
    health_targets = {
        21: (145, "community crisis referral into behavioral health referral optimization"),
        25: (137, "post-crisis casework into health-services agent dispatch"),
        57: (185, "unsheltered medical outreach into emergency preparedness referral"),
        73: (135, "housing case progression into care coordination referral"),
        88: (197, "community digital twin into health learning-system dispatcher"),
    }
    transit_targets = {
        32: (43, "public safety hotspot into transit fare-evasion/security triage"),
        45: (108, "victim-service communication into emergency rider communication"),
        52: (9, "court appointment reminders into transfer protection"),
        64: (70, "weather outreach into transit energy resilience"),
        75: (51, "center activation into fleet pullout readiness"),
        89: (109, "resident feedback into transit feedback analysis"),
    }
    if index in health_targets:
        machine_index, purpose = health_targets[index]
        offset, length = region_for("HSPH", machine_index, "input")
        return ("health-services", offset, length, purpose)
    if index in transit_targets:
        machine_index, purpose = transit_targets[index]
        offset, length = region_for("TFX", machine_index, "input")
        return ("transportation", offset, length, purpose)
    return None


def machine_payload(index: int, specs: list[tuple[str, str, str]]) -> dict:
    base_offset = existing_non_community_max_offset()
    workstream, focus, description = specs[index - 1]
    base = base_offset + (index - 1) * 8
    upstream_index = upstream_index_for(index)
    input_override = external_input_override(index)
    output_override = external_output_override(index)
    input_offset = base
    output_offset = base + 4
    upstream_name = None
    upstream_domain = "community-services"
    upstream_purpose = None

    if upstream_index:
        input_offset = base_offset + (upstream_index - 1) * 8 + 4
        upstream_workstream, upstream_focus, _ = specs[upstream_index - 1]
        upstream_name = f"Community Services {upstream_workstream} {upstream_focus}"

    if input_override:
        upstream_domain, input_offset, _, upstream_purpose = input_override
        upstream_name = f"{upstream_domain} mapped output"

    if output_override:
        _, output_offset, _, _ = output_override

    downstream_indices = [target for target in range(1, len(specs) + 1) if upstream_index_for(target) == index]
    downstream_names = [
        f"Community Services {specs[target - 1][0]} {specs[target - 1][1]}"
        for target in downstream_indices
    ]

    code = f"csx-{index:03d}"
    agent = AGENTS[(index - 1) % len(AGENTS)]
    urgent_action = f"Dispatch {agent} for urgent community-services intervention on {focus.lower()}."
    coordinate_action = f"Coordinate health, housing, public safety, transportation, or city service partners for {focus.lower()}."
    field_action = f"Create field work order or mobile team task for {focus.lower()}."
    stable_action = f"Maintain monitored service path for {focus.lower()}."
    cross_output = output_override

    return {
        "version": "1.0.0",
        "machine": {
            "name": f"Community Services {workstream} {focus}",
            "description": (
                f"Community-services machine for {focus.lower()} in the {workstream.lower()} workstream. "
                f"It monitors {description} and emits AI-triggered actions for health and human services, "
                f"law enforcement/public safety coordination, homelessness response, and city operations."
            ),
            "metadata": {
                "category": "community-services",
                "domain": f"Community Services - {workstream}",
                "author": "Reality Engine",
                "workstream": workstream,
                "operationalFocus": focus,
                "focusDescription": description,
                "upstreamMachine": upstream_name,
                "upstreamDomain": upstream_domain if (upstream_index or input_override) else None,
                "upstreamOutputRegion": f"[{input_offset}:{input_offset + 4}]" if (upstream_index or input_override) else None,
                "upstreamPurpose": upstream_purpose,
                "downstreamMachines": downstream_names,
                "crossDomainInterconnect": bool(input_override or output_override),
                "crossDomainOutputTarget": cross_output[0] if cross_output else None,
                "crossDomainOutputPurpose": cross_output[3] if cross_output else None,
                "dispatchableAgent": agent,
                "aiTrigger": f"community-services-{slug(workstream)}-{slug(focus)}",
                "predictiveFlowTrigger": f"community-services-predictive-{slug(workstream)}-{slug(focus)}",
                "agentActions": [urgent_action, coordinate_action, field_action, stable_action],
                "inputSpace": f"4D binary at [{input_offset}:{input_offset + 4}]",
                "outputSpace": (
                    f"4D binary at [{output_offset}:{output_offset + 4}]: "
                    "[1,0,0,0]=URGENT_RESPONSE, [0,1,0,0]=COORDINATE_SERVICES, "
                    "[0,0,1,0]=FIELD_WORK_ORDER, [0,0,0,1]=STABLE_SERVICE_PATH"
                ),
                "inputSemantics": [
                    "resident need severity",
                    "eligibility and documentation readiness",
                    "field capacity or operational readiness",
                    "safety, mobility, and health risk",
                ],
                "tags": [
                    "community-services",
                    "health-and-human-services",
                    "law-enforcement",
                    "public-safety",
                    "homelessness",
                    "city-services",
                    "ai-triggers",
                    "dispatchable-agents",
                    "cross-domain",
                    slug(workstream),
                    slug(focus),
                ],
                "sequenceCount": 5,
                "reuseGuideline": (
                    "Map 311, case-management, CAD/RMS, shelter HMIS, benefit enrollment, outreach, public health, "
                    "and transit-access signals into the 4D input lane. Route outputs to case workers, mobile crisis, "
                    "public safety, housing navigators, field crews, transportation dispatch, or health-service agents."
                ),
                "downstreamPattern": (
                    f"Output region [{output_offset}:{output_offset + 4}] feeds {', '.join(downstream_names)}."
                    if downstream_names else
                    f"Output region [{output_offset}:{output_offset + 4}] is available for community-services optimization."
                ),
            },
            "arbiterRule": "PASSTHROUGH",
            "perceptualMapping": {
                "input": {"offset": input_offset, "length": 4},
                "output": {"offset": output_offset, "length": 4},
            },
            "sequences": [
                {
                    "id": f"{code}-urgent-response",
                    "name": f"{focus}: WATCH -> URGENT_RESPONSE",
                    "metadata": {"description": "Escalates resident or field risk into urgent response.", "output": "[1,0,0,0]"},
                    "vectors": [
                        {"id": f"{code}-watch", "elements": vector_elements([1, 0, 1, 1]), "isInitial": True, "nextVectorIds": [f"{code}-urgent"]},
                        {"id": f"{code}-urgent", "elements": vector_elements([0, 0, 1, 1]), "isInitial": False, "outputVectors": [{"id": f"{code}-urgent-output", "vector": [1, 0, 0, 0], "metadata": {"action": urgent_action}}]},
                    ],
                },
                {
                    "id": f"{code}-coordinate-services",
                    "name": f"{focus}: COORDINATION_NEEDED -> COORDINATE_SERVICES",
                    "metadata": {"description": "Triggers cross-agency coordination.", "output": "[0,1,0,0]"},
                    "vectors": [
                        {"id": f"{code}-coordinate", "elements": vector_elements([0, 1, 1, 0]), "isInitial": True, "outputVectors": [{"id": f"{code}-coordinate-output", "vector": [0, 1, 0, 0], "metadata": {"action": coordinate_action}}]},
                    ],
                },
                {
                    "id": f"{code}-field-work-order",
                    "name": f"{focus}: FIELD_TASK_NEEDED -> FIELD_WORK_ORDER",
                    "metadata": {"description": "Creates a field crew, outreach, or mobile response task.", "output": "[0,0,1,0]"},
                    "vectors": [
                        {"id": f"{code}-field-task", "elements": vector_elements([1, 0, 0, 1]), "isInitial": True, "outputVectors": [{"id": f"{code}-field-output", "vector": [0, 0, 1, 0], "metadata": {"action": field_action}}]},
                    ],
                },
                {
                    "id": f"{code}-stable-service-path",
                    "name": f"{focus}: STABLE_PATH -> STABLE_SERVICE_PATH",
                    "metadata": {"description": "Confirms resident service path is stable and monitored.", "output": "[0,0,0,1]"},
                    "vectors": [
                        {"id": f"{code}-stable", "elements": vector_elements([1, 1, 0, 0]), "isInitial": True, "outputVectors": [{"id": f"{code}-stable-output", "vector": [0, 0, 0, 1], "metadata": {"action": stable_action}}]},
                    ],
                },
            ],
            "inputSequences": [
                {"name": "Urgent response sequence", "description": "Two-step community risk escalation ending in urgent response.", "vectors": [[1, 0, 1, 1], [0, 0, 1, 1]], "metadata": {"expectedOutputCount": 1, "expectedOutputVector": "[1,0,0,0]", "scenario": "urgent-response", "sequenceLength": 2}},
                {"name": "Coordinate services", "description": "Coordinates health, public safety, housing, transit, or city service partners.", "vectors": [[0, 1, 1, 0]], "metadata": {"expectedOutputCount": 1, "expectedOutputVector": "[0,1,0,0]", "scenario": "coordinate-services"}},
                {"name": "Field work order", "description": "Creates a field response or outreach task.", "vectors": [[1, 0, 0, 1]], "metadata": {"expectedOutputCount": 1, "expectedOutputVector": "[0,0,1,0]", "scenario": "field-work-order"}},
                {"name": "Stable service path", "description": "Confirms the resident or city service path is stable.", "vectors": [[1, 1, 0, 0]], "metadata": {"expectedOutputCount": 1, "expectedOutputVector": "[0,0,0,1]", "scenario": "stable-service-path"}},
                {"name": "Baseline without output", "description": "Initial observation arms the urgent path without firing.", "vectors": [[1, 0, 1, 1]], "metadata": {"expectedOutputCount": 0, "scenario": "baseline-no-output"}},
            ],
        },
    }


def main() -> None:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    specs = build_specs()
    for index in range(1, len(specs) + 1):
        workstream, focus, _ = specs[index - 1]
        path = OUT_DIR / f"CSX{index:03d}_{slug(workstream)}-{slug(focus)}.json"
        path.write_text(json.dumps(machine_payload(index, specs), indent=2) + "\n")
    print(f"Generated {len(specs)} community-services machines in {OUT_DIR}")
    print("Cross-domain links: health-services inputs/outputs and transportation inputs/outputs")


if __name__ == "__main__":
    main()
