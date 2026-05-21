#!/usr/bin/env python3
"""
Generate data-center operations machines for 24/7 management.

The machines cover monitoring, maintenance, upgrade, capacity, compliance, and
incident-readiness concerns. Each machine emits a 4D action lane:
  [1,0,0,0] = URGENT_INTERVENTION
  [0,1,0,0] = SCHEDULE_MAINTENANCE
  [0,0,1,0] = PLAN_UPGRADE
  [0,0,0,1] = OPERATING_NOMINAL
"""

from __future__ import annotations

import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
OUT_DIR = ROOT / "examples" / "machines"

FOCUS_AREAS = [
    ("Power Utility Feed Monitor", "utility feed quality, brownout risk, ATS state, and event history"),
    ("UPS Battery Health Manager", "battery runtime, cell imbalance, bypass status, and replacement age"),
    ("Generator Readiness Controller", "fuel level, exercise result, start reliability, and load-test status"),
    ("PDU Load Balance Monitor", "phase balance, breaker margin, outlet telemetry, and rack load drift"),
    ("Rack Thermal Envelope Monitor", "inlet temperature, exhaust delta, hotspot trend, and airflow obstruction"),
    ("CRAC CRAH Maintenance Planner", "cooling unit health, filter pressure, compressor status, and service interval"),
    ("Chiller Plant Efficiency Optimizer", "supply temperature, approach temperature, pump energy, and free-cooling state"),
    ("Leak Detection Response", "water presence, sensor zone, containment state, and work-order readiness"),
    ("Fire Suppression Readiness", "pre-action pressure, detection loop health, bottle pressure, and inspection status"),
    ("Physical Access Control Monitor", "badge anomalies, door forced-open events, escort compliance, and audit trail"),
    ("Video Surveillance Coverage Monitor", "camera availability, recording health, blind spots, and retention coverage"),
    ("Network Core Redundancy Monitor", "core switch HA status, link aggregation health, route convergence, and optics errors"),
    ("WAN Provider Diversity Monitor", "provider reachability, BGP stability, latency, and failover proof"),
    ("Top Of Rack Switch Lifecycle", "port errors, firmware age, fan/PSU health, and capacity margin"),
    ("Fiber Plant Integrity Monitor", "light levels, patch changes, documentation drift, and bend/loss trend"),
    ("Server Fleet Health Monitor", "BMC alarms, fan/PSU faults, ECC trend, and thermal throttling"),
    ("Firmware Baseline Compliance", "BIOS/BMC/NIC firmware drift, advisory severity, and rollout readiness"),
    ("Patch Window Orchestrator", "change freeze, dependency graph, reboot queue, and approval state"),
    ("Cluster Capacity Forecast", "CPU, memory, accelerator, storage, and reservation growth trend"),
    ("Virtualization HA Readiness", "host admission control, datastore heartbeat, anti-affinity, and failover test"),
    ("Kubernetes Control Plane Guard", "API health, etcd quorum, node pressure, and certificate age"),
    ("Storage Array Health Monitor", "controller status, disk predictive failure, rebuild pressure, and cache battery"),
    ("Backup Completion Assurance", "backup SLA, failed jobs, restore-test freshness, and immutable copy health"),
    ("Disaster Recovery Drill Manager", "replication lag, runbook freshness, RTO proof, and RPO conformance"),
    ("Capacity Reservation Manager", "rack space, power budget, IP pools, VLANs, and procurement lead time"),
    ("Asset Lifecycle Tracker", "warranty state, depreciation age, support status, and refresh priority"),
    ("Spares Inventory Manager", "critical spare coverage, lead time, consumption rate, and shelf-life status"),
    ("Change Risk Gatekeeper", "blast radius, rollback plan, approval state, and maintenance-window fit"),
    ("Incident Command Readiness", "on-call coverage, escalation path, bridge readiness, and communication template"),
    ("Observability Pipeline Monitor", "metrics ingestion, log lag, trace sampling, and alert delivery health"),
    ("Alert Fatigue Suppressor", "duplicate alerts, flap rate, suppression rules, and actionable signal ratio"),
    ("SLO Error Budget Monitor", "availability, latency, saturation, and burn-rate trend"),
    ("Compliance Evidence Collector", "audit control evidence, retention age, access logs, and exception status"),
    ("Vulnerability Exposure Manager", "scanner coverage, critical CVEs, exploitability, and patch exception age"),
    ("Secrets Certificate Rotation", "certificate expiry, key age, rotation status, and dependent service count"),
    ("Identity Privilege Review", "privileged account age, access recertification, orphaned users, and break-glass state"),
    ("Configuration Drift Detector", "desired-state delta, unauthorized change, policy violation, and remediation state"),
    ("CMDB Accuracy Monitor", "asset inventory match, owner completeness, location accuracy, and dependency freshness"),
    ("Environmental Sensor Calibration", "temperature/humidity sensor drift, calibration age, and reference variance"),
    ("Energy Efficiency Optimizer", "PUE trend, server utilization, cooling efficiency, and demand-response signal"),
    ("Carbon Aware Workload Scheduler", "grid carbon signal, workload flexibility, SLA class, and power headroom"),
    ("Tenant Capacity Guard", "tenant quota use, noisy-neighbor trend, reservation overcommit, and fairness signal"),
    ("SRE Handoff Completeness", "shift notes, active incidents, pending changes, and unresolved alarms"),
    ("Maintenance Blackout Guard", "change calendar, business event, redundancy status, and staffing coverage"),
    ("Upgrade Wave Planner", "canary health, compatibility matrix, dependency order, and rollback capacity"),
    ("Firmware Rollback Readiness", "golden image availability, config backup, out-of-band access, and validation state"),
    ("Spine Leaf Expansion Planner", "port exhaustion, route scale, cabling readiness, and maintenance sequencing"),
    ("Storage Migration Coordinator", "replication health, cutover window, application dependency, and rollback point"),
    ("Decommission Safety Controller", "data wipe proof, dependency clearance, power/network removal, and asset disposal"),
    ("24x7 Operations Executive Summary", "cross-domain risk, maintenance backlog, upgrade readiness, and staffing confidence"),
]

AGENTS = [
    "dc_facilities_agent",
    "dc_power_agent",
    "dc_cooling_agent",
    "dc_network_agent",
    "dc_compute_agent",
    "dc_storage_agent",
    "dc_security_agent",
    "dc_sre_agent",
    "dc_change_manager_agent",
    "dc_capacity_planner_agent",
]

# Predictive/prescriptive operational dependencies. The target machine consumes
# the source machine's 4D output lane as its own 4D input lane.
UPSTREAM_BY_INDEX = {
    # Power/facilities/cooling dependency chain
    2: 1,
    3: 2,
    4: 1,
    5: 4,
    6: 5,
    7: 5,
    8: 5,
    9: 8,

    # Physical security and evidence chain
    11: 10,
    36: 10,

    # Network dependency chain
    13: 12,
    14: 12,
    15: 14,
    47: 12,

    # Compute/platform lifecycle chain
    17: 16,
    18: 17,
    19: 16,
    20: 19,
    21: 20,

    # Storage/backup/DR/migration chain
    23: 22,
    24: 23,
    48: 22,

    # Capacity/lifecycle/spares/change readiness
    26: 25,
    27: 26,
    28: 27,
    44: 28,
    45: 44,
    46: 45,
    49: 26,

    # Operations/SRE/compliance/security automation
    30: 29,
    31: 30,
    32: 31,
    33: 32,
    34: 33,
    35: 34,
    37: 38,
    38: 30,
    39: 5,
    40: 7,
    41: 40,
    42: 25,
    43: 29,

    # Executive rollup consumes decommission safety as the final lifecycle gate.
    50: 49,
}


def slug(value: str) -> str:
    result = "".join(ch.lower() if ch.isalnum() else "-" for ch in value).strip("-")
    while "--" in result:
        result = result.replace("--", "-")
    return result


def vector_elements(values: list[int]) -> list[dict[str, float]]:
    return [{"value": value, "threshold": 0.5} for value in values]


def machine_payload(index: int, focus: str, description: str, specs: list[tuple[str, str]]) -> dict:
    base = 1153 + (index - 1) * 8
    output_offset = base + 4
    upstream_index = UPSTREAM_BY_INDEX.get(index)
    input_offset = (1153 + (upstream_index - 1) * 8 + 4) if upstream_index else base
    code = f"dcx-{index:03d}"
    agent = AGENTS[(index - 1) % len(AGENTS)]
    upstream_name = f"Data Center {specs[upstream_index - 1][0]}" if upstream_index else None
    upstream_region = f"[{input_offset}:{input_offset + 4}]" if upstream_index else None
    downstream_indices = [target for target, source in UPSTREAM_BY_INDEX.items() if source == index]
    downstream_names = [f"Data Center {specs[target - 1][0]}" for target in downstream_indices]
    urgent_action = f"Dispatch {agent} for immediate stabilization of {focus.lower()}."
    maintenance_action = f"Schedule maintenance for {focus.lower()} with rollback and staffing checks."
    upgrade_action = f"Plan upgrade or lifecycle change for {focus.lower()} using risk-gated rollout."
    nominal_action = f"Keep 24/7 monitoring active for {focus.lower()}."
    projection_action = f"Project {focus.lower()} forward over the next 24 hours and prescribe maintenance or upgrade work before the risk window opens."

    return {
        "version": "1.0.0",
        "machine": {
            "name": f"Data Center {focus}",
            "description": (
                f"Data-center operations machine for {focus.lower()}. It monitors {description} "
                f"and emits operational outputs for 24/7 incident response, maintenance planning, "
                f"upgrade readiness, and steady-state assurance."
            ),
            "metadata": {
                "category": "data-center",
                "domain": "Data Center - 24x7 Operations",
                "author": "Reality Engine",
                "operationalFocus": focus,
                "focusDescription": description,
                "upstreamMachine": upstream_name,
                "upstreamOutputRegion": upstream_region,
                "downstreamMachines": downstream_names,
                "projectionHorizon": "24h",
                "projectionWindows": ["0-6h", "6-12h", "12-18h", "18-24h"],
                "prescriptiveMaintenanceRole": (
                    f"Consumes {upstream_name} output to convert upstream operational posture into prescriptive action for {focus.lower()}."
                    if upstream_name else
                    f"Primary telemetry/source machine for prescriptive action on {focus.lower()}."
                ),
                "dispatchableAgent": agent,
                "aiTrigger": f"data-center-{slug(focus)}-ops-maintenance-upgrade",
                "agentActions": [urgent_action, maintenance_action, upgrade_action, nominal_action, projection_action],
                "inputSpace": f"4D binary at [{input_offset}:{input_offset + 4}]",
                "outputSpace": (
                    f"4D binary at [{output_offset}:{output_offset + 4}]: "
                    "[1,0,0,0]=URGENT_INTERVENTION, [0,1,0,0]=SCHEDULE_MAINTENANCE, "
                    "[0,0,1,0]=PLAN_UPGRADE, [0,0,0,1]=OPERATING_NOMINAL"
                ),
                "inputSemantics": [
                    "availability margin",
                    "maintenance readiness",
                    "upgrade/lifecycle pressure",
                    "operational confidence",
                ],
                "tags": [
                    "data-center",
                    "24x7-operations",
                    "maintenance",
                    "upgrade-cycle",
                    "incident-response",
                    slug(focus),
                ],
                "sequenceCount": 5,
                "reuseGuideline": (
                    "Use as a 24/7 operational guardrail. Map telemetry, CMDB, change, or AI-dispatch signals "
                    "into the 4D input lane; map outputs to incident, maintenance, upgrade, or executive-summary machines."
                ),
                "downstreamPattern": (
                    f"Output region [{output_offset}:{output_offset + 4}] feeds {', '.join(downstream_names)} for prescriptive 24/7 operations."
                    if downstream_names else
                    f"Output region [{output_offset}:{output_offset + 4}] is available to incident, maintenance, upgrade, and executive-summary automation."
                ),
            },
            "arbiterRule": "PASSTHROUGH",
            "perceptualMapping": {
                "input": {"offset": input_offset, "length": 4},
                "output": {"offset": output_offset, "length": 4},
            },
            "sequences": [
                {
                    "id": f"{code}-urgent",
                    "name": f"{focus}: DEGRADED -> CRITICAL -> URGENT_INTERVENTION",
                    "metadata": {"description": "Escalates when availability and operational confidence collapse.", "output": "[1,0,0,0]"},
                    "vectors": [
                        {"id": f"{code}-degraded", "elements": vector_elements([1, 0, 1, 0]), "isInitial": True, "nextVectorIds": [f"{code}-critical"]},
                        {"id": f"{code}-critical", "elements": vector_elements([0, 0, 1, 0]), "isInitial": False, "outputVectors": [{"id": f"{code}-urgent-output", "vector": [1, 0, 0, 0], "metadata": {"action": urgent_action}}]},
                    ],
                },
                {
                    "id": f"{code}-maintenance",
                    "name": f"{focus}: SERVICE_DUE -> SCHEDULE_MAINTENANCE",
                    "metadata": {"description": "Schedules maintenance before service quality degrades.", "output": "[0,1,0,0]"},
                    "vectors": [
                        {"id": f"{code}-service-due", "elements": vector_elements([1, 0, 0, 1]), "isInitial": True, "outputVectors": [{"id": f"{code}-maintenance-output", "vector": [0, 1, 0, 0], "metadata": {"action": maintenance_action}}]},
                    ],
                },
                {
                    "id": f"{code}-upgrade",
                    "name": f"{focus}: LIFECYCLE_PRESSURE -> PLAN_UPGRADE",
                    "metadata": {"description": "Plans an upgrade, refresh, or lifecycle action under controlled change management.", "output": "[0,0,1,0]"},
                    "vectors": [
                        {"id": f"{code}-upgrade-needed", "elements": vector_elements([1, 1, 1, 0]), "isInitial": True, "outputVectors": [{"id": f"{code}-upgrade-output", "vector": [0, 0, 1, 0], "metadata": {"action": upgrade_action}}]},
                    ],
                },
                {
                    "id": f"{code}-nominal",
                    "name": f"{focus}: HEALTHY -> OPERATING_NOMINAL",
                    "metadata": {"description": "Confirms stable 24/7 operational posture.", "output": "[0,0,0,1]"},
                    "vectors": [
                        {"id": f"{code}-healthy", "elements": vector_elements([1, 1, 0, 1]), "isInitial": True, "outputVectors": [{"id": f"{code}-nominal-output", "vector": [0, 0, 0, 1], "metadata": {"action": nominal_action}}]},
                    ],
                },
                {
                    "id": f"{code}-24h-projection",
                    "name": f"{focus}: 0-6H -> 6-12H -> 12-18H -> 18-24H -> PRESCRIPTIVE_ACTION",
                    "metadata": {
                        "description": "Projects operational posture across a 24/7 horizon and prescribes work before the forecasted risk window opens.",
                        "projectionHorizon": "24h",
                        "projectionWindows": ["0-6h", "6-12h", "12-18h", "18-24h"],
                        "output": "[0,1,0,0]",
                    },
                    "vectors": [
                        {"id": f"{code}-projection-0-6h", "elements": vector_elements([0, 1, 1, 1]), "isInitial": True, "metadata": {"window": "0-6h", "description": "Current posture is stable but lifecycle pressure is visible."}, "nextVectorIds": [f"{code}-projection-6-12h"]},
                        {"id": f"{code}-projection-6-12h", "elements": vector_elements([0, 1, 1, 0]), "isInitial": False, "metadata": {"window": "6-12h", "description": "Operational confidence begins to degrade."}, "nextVectorIds": [f"{code}-projection-12-18h"]},
                        {"id": f"{code}-projection-12-18h", "elements": vector_elements([0, 0, 1, 1]), "isInitial": False, "metadata": {"window": "12-18h", "description": "Maintenance readiness is no longer sufficient for the forecasted load."}, "nextVectorIds": [f"{code}-projection-18-24h"]},
                        {"id": f"{code}-projection-18-24h", "elements": vector_elements([0, 0, 1, 0]), "isInitial": False, "metadata": {"window": "18-24h", "description": "Forecast crosses the prescriptive maintenance threshold."}, "outputVectors": [{"id": f"{code}-projection-output", "vector": [0, 1, 0, 0], "metadata": {"action": projection_action, "projectionHorizon": "24h"}}]},
                    ],
                },
            ],
            "inputSequences": [
                {"name": "Urgent intervention", "description": "Availability and confidence collapse after degraded operation.", "vectors": [[1, 0, 1, 0], [0, 0, 1, 0]], "metadata": {"expectedOutputCount": 1, "expectedOutputVector": "[1,0,0,0]", "scenario": "urgent-intervention"}},
                {"name": "Maintenance due", "description": "Maintenance should be scheduled before degradation.", "vectors": [[1, 0, 0, 1]], "metadata": {"expectedOutputCount": 1, "expectedOutputVector": "[0,1,0,0]", "scenario": "schedule-maintenance"}},
                {"name": "Upgrade planning", "description": "Lifecycle pressure requires upgrade planning.", "vectors": [[1, 1, 1, 0]], "metadata": {"expectedOutputCount": 1, "expectedOutputVector": "[0,0,1,0]", "scenario": "plan-upgrade"}},
                {"name": "Nominal operations", "description": "The machine reports stable 24/7 operation.", "vectors": [[1, 1, 0, 1]], "metadata": {"expectedOutputCount": 1, "expectedOutputVector": "[0,0,0,1]", "scenario": "operating-nominal"}},
                {"name": "24-hour prescriptive projection", "description": "Projects operations across four 6-hour windows and prescribes maintenance before the 24-hour risk window opens.", "vectors": [[0, 1, 1, 1], [0, 1, 1, 0], [0, 0, 1, 1], [0, 0, 1, 0]], "metadata": {"expectedOutputCount": 1, "expectedOutputVector": "[0,1,0,0]", "scenario": "24h-prescriptive-projection"}},
                {"name": "Baseline without output", "description": "A single degraded baseline arms the urgent path without firing.", "vectors": [[1, 0, 1, 0]], "metadata": {"expectedOutputCount": 0, "scenario": "baseline-no-output"}},
            ],
        },
    }


def main() -> None:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    for index, (focus, description) in enumerate(FOCUS_AREAS, start=1):
        path = OUT_DIR / f"DCX{index:03d}_{slug(focus)}.json"
        path.write_text(json.dumps(machine_payload(index, focus, description, FOCUS_AREAS), indent=2) + "\n")
    print(f"Generated {len(FOCUS_AREAS)} data-center operations machines in {OUT_DIR}")


if __name__ == "__main__":
    main()
