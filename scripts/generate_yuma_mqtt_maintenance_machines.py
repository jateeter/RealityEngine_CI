#!/usr/bin/env python3
"""
Generate the AGX051-AGX055 "Yuma MQTT maintenance" machines.

These five machines pair directly with the mappings declared in
RealityEngine_CPP/config/mqtt-mappings.yuma-agriculture.json:

    AGX001 sensors at [40:44)  → AGX051 maintenance forecast at [256:260)
    AGX005 sensors at [84:88)  → AGX052 DO-probe reliability   at [260:264)
    AGX026 sensors at [184:188) → AGX053 HVAC service plan      at [264:268)
    AGX032 sensors at [228:232) → AGX054 CO2 safety compliance  at [268:272)
                                  AGX055 facility AI bridge
                                    in  [256:272)  → out [3959:3971)
                                    feeds AgYieldOptimizationAI

AGX051-054 read the SAME MQTT-driven sensor cells as AGX001/005/026/032
but apply a maintenance lens (URGENT_MAINT / FORECAST_MAINT / CALIBRATE /
NORMAL) instead of the operational-stability lens.  Multiple machines
sharing an input region is normal — perceptual space is a read-shared
resource.

AGX055 sits between the four new machines and AgYieldOptimizationAI: it
projects the 16 maintenance bits into the 12-cell vector that the AI
consumes at offsets [3959:3971], so live MQTT data drives the cross-
domain yield AI without any glue code outside the machine corpus.

Run from repo root:
    python3 scripts/generate_yuma_mqtt_maintenance_machines.py
"""

from __future__ import annotations
import json
import os
from pathlib import Path
from typing import Any

OUT_DIR = Path(__file__).resolve().parent.parent / "examples" / "machines"

# ── Shared output semantics (4-cell tier-1 maintenance machines) ────────────
# Pattern parallels AGX001/005/026/032 but the labels reflect a maintenance
# rather than operational lens so the downstream agent dispatch differs.
OUTPUT_LABELS = [
    ("URGENT_MAINT",     [1, 0, 0, 0], "RED",   "error", "Dispatch maintenance immediately — sensor data shows a fault condition."),
    ("FORECAST_MAINT",   [0, 1, 0, 0], "AMBER", "info",  "Schedule maintenance in the upcoming service window."),
    ("CALIBRATE",        [0, 0, 1, 0], "AMBER", "info",  "Sensor drift suspected — run calibration."),
    ("NORMAL",           [0, 0, 0, 1], "GREEN", "info",  "Equipment is healthy — continue automated monitoring."),
]

# Input patterns the 4-cell machines match.  Each row corresponds to one of
# the 4 sequences/output labels above.
INPUT_PATTERNS = {
    "URGENT_MAINT":   [
        # Escalation: NORMAL → WATCH → CRITICAL.  Two of the four cells go
        # to 0 in WATCH; all four fall to 0 in CRITICAL.
        [1, 1, 1, 1],
        [1, 0, 1, 0],
        [0, 0, 0, 0],
    ],
    "FORECAST_MAINT": [
        # Pattern: two cells low (the ones the maintenance forecast is built
        # around) — same as the "OPTIMIZE" shape on the operational machine.
        [0, 1, 0, 1],
    ],
    "CALIBRATE":      [
        # Pattern: outer cells healthy but inner cells flapping — a typical
        # signature of a drifting probe.
        [1, 0, 0, 1],
    ],
    "NORMAL":         [
        # Stable band: 3 of 4 cells in nominal range.
        [1, 1, 0, 1],
    ],
}


def make_tier1_machine(spec: dict[str, Any]) -> dict[str, Any]:
    """Build the AGX051-054 machine JSON dict from a compact spec."""
    code        = spec["code"]              # e.g. "AGX051"
    code_lower  = code.lower()              # "agx051"
    seq_prefix  = f"agx-{code_lower[3:]}"   # "agx-051"
    in_off      = spec["input_offset"]
    out_off     = spec["output_offset"]
    name        = spec["name"]
    description = spec["description"]
    agent       = spec["agent"]
    focus_short = spec["focus_short"]       # e.g. "Aqua Maintenance Forecast"
    sensors     = spec["sensors"]
    subdomain   = spec["subdomain"]
    mqtt_topic  = spec["mqtt_topic"]
    upstream    = spec.get("upstream_machine")
    severity    = spec.get("severity")
    downstream  = spec.get("downstream", [])

    sequences = []
    for label, output_vec, rag, status, desc in OUTPUT_LABELS:
        if label == "URGENT_MAINT":
            sequences.append({
                "id":   f"{seq_prefix}-urgent-maint",
                "name": f"{focus_short}: NORMAL -> WATCH -> CRITICAL -> URGENT_MAINT",
                "metadata": {
                    "description": "Two-step escalation from stable readings into a fault state.",
                    "path":        "NORMAL -> WATCH -> CRITICAL",
                    "output":      "[1,0,0,0]",
                },
                "vectors": [
                    {
                        "id": f"{seq_prefix}-normal",
                        "elements": [{"value": v, "threshold": 0.5} for v in [1,1,1,1]],
                        "isInitial": True,
                        "metadata": {"name": "NORMAL", "description": "All four sensor cells in nominal range."},
                        "nextVectorIds": [f"{seq_prefix}-watch"],
                    },
                    {
                        "id": f"{seq_prefix}-watch",
                        "elements": [{"value": v, "threshold": 0.5} for v in [1,0,1,0]],
                        "isInitial": False,
                        "metadata": {"name": "WATCH", "description": "Two sensor cells leaving the nominal band."},
                        "nextVectorIds": [f"{seq_prefix}-critical"],
                    },
                    {
                        "id": f"{seq_prefix}-critical",
                        "elements": [{"value": v, "threshold": 0.5} for v in [0,0,0,0]],
                        "isInitial": False,
                        "metadata": {"name": "CRITICAL", "description": "All four sensor cells outside nominal — fault state."},
                        "outputVectors": [{
                            "id": f"{seq_prefix}-urgent-output",
                            "vector": output_vec,
                            "metadata": {"description": desc, "action": f"Dispatch {agent} for urgent maintenance and record corrective action."},
                        }],
                    },
                ],
            })
        else:
            # Single-vector "fast" sequence — initial event fires the output directly.
            pattern_vec = INPUT_PATTERNS[label][0]
            sequences.append({
                "id":   f"{seq_prefix}-{label.lower().replace('_', '-')}",
                "name": f"{focus_short}: {label} input pattern -> {label}",
                "metadata": {
                    "description": desc,
                    "pattern":     label,
                    "output":      "[" + ",".join(str(x) for x in output_vec) + "]",
                },
                "vectors": [{
                    "id": f"{seq_prefix}-{label.lower().replace('_', '-')}-event",
                    "elements": [{"value": v, "threshold": 0.5} for v in pattern_vec],
                    "isInitial": True,
                    "metadata": {"name": label, "description": desc},
                    "outputVectors": [{
                        "id": f"{seq_prefix}-{label.lower().replace('_', '-')}-output",
                        "vector": output_vec,
                        "metadata": {
                            "description": desc,
                            "action": ({
                                "FORECAST_MAINT": f"Schedule preventive maintenance via {agent} and verify completion telemetry.",
                                "CALIBRATE":      f"Run sensor-calibration workflow via {agent} for the {focus_short.lower()} stream.",
                                "NORMAL":         f"Continue automated monitoring for {focus_short.lower()} while preserving current setpoints.",
                            })[label],
                        },
                    }],
                }],
            })

    # Input sequences (validation examples).  Mirrors AGX001 shape.
    input_sequences = [
        {
            "name": "Escalation to urgent maintenance",
            "description": "A stable sensor stream degrades through watch conditions and then reaches a fault state.",
            "vectors": INPUT_PATTERNS["URGENT_MAINT"],
            "metadata": {"expectedOutputCount": 1, "expectedOutputVector": "[1,0,0,0]", "scenario": "urgent-maint"},
        },
        {
            "name": "Maintenance forecast",
            "description": "Inner sensor cells degrade — the forecast model flags scheduled service.",
            "vectors": [INPUT_PATTERNS["FORECAST_MAINT"][0]],
            "metadata": {"expectedOutputCount": 1, "expectedOutputVector": "[0,1,0,0]", "scenario": "forecast-maint"},
        },
        {
            "name": "Sensor calibration required",
            "description": "Inner cells flap while outer cells stay healthy — a drift pattern that calls for calibration.",
            "vectors": [INPUT_PATTERNS["CALIBRATE"][0]],
            "metadata": {"expectedOutputCount": 1, "expectedOutputVector": "[0,0,1,0]", "scenario": "calibrate"},
        },
        {
            "name": "Normal operating window",
            "description": "Three of four sensor cells healthy — equipment in good working order.",
            "vectors": [INPUT_PATTERNS["NORMAL"][0]],
            "metadata": {"expectedOutputCount": 1, "expectedOutputVector": "[0,0,0,1]", "scenario": "normal"},
        },
        {
            "name": "Baseline normal",
            "description": "A single all-1 sensor reading arms the escalation path without dispatching maintenance.",
            "vectors": [[1, 1, 1, 1]],
            "metadata": {"expectedOutputCount": 0, "scenario": "baseline"},
        },
    ]

    metadata: dict[str, Any] = {
        "category":        "agriculture",
        "domain":          subdomain,
        "author":          "Reality Engine",
        "operationalFocus": focus_short,
        "focusDescription": f"Live MQTT sensor stream from {mqtt_topic}",
        "mqttIntegration": {
            "configFile":   "RealityEngine_CPP/config/mqtt-mappings.yuma-agriculture.json",
            "topicFilter":  mqtt_topic,
            "inputRegion":  {"offset": in_off, "length": 4},
            "drivenBy":     spec["topic_owner_code"],
            "sensorBands":  sensors,
            "rationale":    f"Same MQTT region as {spec['topic_owner_code']} but a maintenance lens — distinct outputs.",
        },
        "upstreamMachine":      upstream,
        "upstreamOutputRegion": None,
        "predictiveManagementRole": f"Maintenance-focused machine driven by live yuma.lateraledge.cloud MQTT data via {spec['topic_owner_code']} sensor region.",
        "aiTrigger":          f"{name.lower().replace(' ', '-')}-maintenance",
        "dispatchableAgent":  agent,
        "agentActions": [
            f"Dispatch {agent} for urgent maintenance and record corrective action.",
            f"Schedule preventive maintenance via {agent} and verify completion telemetry.",
            f"Run sensor-calibration workflow via {agent} for the {focus_short.lower()} stream.",
            f"Continue automated monitoring for {focus_short.lower()} while preserving current setpoints.",
        ],
        "outputSpace": (f"4D binary at [{out_off}:{out_off+4}]: "
                        f"[1,0,0,0]=URGENT_MAINT, [0,1,0,0]=FORECAST_MAINT, "
                        f"[0,0,1,0]=CALIBRATE, [0,0,0,1]=NORMAL"),
        "tags": sorted(set([
            "agriculture", "agriculture-mqtt", "agriculture-yuma",
            f"agriculture-yuma-{spec['topic_owner_code'].lower()}",
            "agriculture-generated",
            code_lower, "ai-trigger", "ai-triggers",
            "ces-sequences", "ces-sequences-4",
            "dispatchable-agent", "dispatchable-agents",
            "input-sequences", "input-sequences-5",
            "machine-interconnect", "maintenance",
            "operational-management", "predictive-maintenance",
            "startup-loadable", "yuma-mqtt-driven", agent,
        ])),
        "sequenceCount": 4,
        "sensorNormalization": {
            "process_stability_norm":     "0.0=outside MQTT band; 0.5=watch; 1.0=in MQTT-defined nominal band",
            "resource_efficiency_norm":   "0.0=wasteful; 0.5=acceptable; 1.0=efficient",
            "biosecurity_or_ipm_norm":    "0.0=biohazard; 0.5=mitigated; 1.0=controlled",
            "maintenance_readiness_norm": "0.0=overdue; 0.5=service due; 1.0=verified",
        },
        "inputSemantics": sensors,
        "downstreamMachines": downstream,
        "downstreamPattern": (
            f"Output region [{out_off}:{out_off+4}] feeds the Agriculture Yuma "
            f"Facility AI Synthesis Bridge (AGX055) which projects all four "
            f"Yuma maintenance machines into the AgYieldOptimizationAI input "
            f"window at [3959:3971]."
        ),
        "tagging": {
            "schemaVersion": "1.0.0",
            "managedBy":     "scripts/generate_yuma_mqtt_maintenance_machines.py",
            "primaryDomain": "agriculture",
            "domainTags":    ["agriculture", "agriculture-yuma"],
            "family":        "agriculture-yuma-mqtt",
            "machineCode":   code_lower,
            "capabilityTags": ["ai-triggers", "dispatchable-agents", "maintenance",
                               "predictive-maintenance", "yuma-mqtt-driven"],
            "workflowTags":   ["agriculture-yuma", "ai-trigger", "dispatchable-agent",
                               "operational-management"],
            "integrationTags":["ai-trigger", "dispatchable-agent",
                               "machine-interconnect", "mqtt-bridge"],
            "validationTags": ["ces-sequences", "ces-sequences-4",
                               "input-sequences", "input-sequences-5",
                               "startup-loadable"],
        },
        "governance": {
            "schemaVersion":    "1.0.0",
            "ownerTeam":        "agriculture-operations",
            "runbook":          f"https://runbooks.example.org/agriculture/{code_lower}_{spec['slug']}",
            "escalationPolicy": "pagerduty:ag-ops" if severity != "life-safety" else "pagerduty:ag-life-safety",
            "contact": {
                "primary":   "agriculture-operations-primary@example.org",
                "secondary": "agriculture-operations-secondary@example.org",
            },
            "sla": {"ok": None, "info": None,
                    "warning": 1800 if severity == "life-safety" else 3600,
                    "error":   300  if severity == "life-safety" else 900},
            "notes": (f"Yuma MQTT-driven {code} — auto-generated from "
                      f"scripts/generate_yuma_mqtt_maintenance_machines.py."
                      f"  MQTT topic: {mqtt_topic}."),
        },
        "triggerConfig": {
            "processId":   f"{code}_{spec['slug'].upper().replace('-', '_')}",
            "processName": name,
            "rules": [
                {
                    "sequenceId":    f"{seq_prefix}-urgent-maint",
                    "outputMatches": [1, 0, 0, 0],
                    "ragStatusCode": "RED",
                    "processStatus": "error",
                    "description":   "Urgent maintenance dispatch required.",
                },
                {
                    "sequenceId":    f"{seq_prefix}-forecast-maint",
                    "outputMatches": [0, 1, 0, 0],
                    "ragStatusCode": "AMBER",
                    "processStatus": "info",
                    "description":   "Preventive maintenance should be scheduled.",
                },
                {
                    "sequenceId":    f"{seq_prefix}-calibrate",
                    "outputMatches": [0, 0, 1, 0],
                    "ragStatusCode": "AMBER",
                    "processStatus": "info",
                    "description":   "Sensor calibration required.",
                },
                {
                    "sequenceId":    f"{seq_prefix}-normal",
                    "outputMatches": [0, 0, 0, 1],
                    "ragStatusCode": "GREEN",
                    "processStatus": "info",
                    "description":   "Equipment in normal operating window.",
                },
            ],
        },
    }
    if severity:
        metadata["severity"] = severity

    return {
        "version": "1.0.0",
        "machine": {
            "name":        name,
            "description": description,
            "metadata":    metadata,
            "arbiterRule": "PASSTHROUGH",
            "perceptualMapping": {
                "input":  {"offset": in_off,  "length": 4},
                "output": {"offset": out_off, "length": 4},
                "bitsPerElement": 1,
            },
            "sequences":      sequences,
            "inputSequences": input_sequences,
        },
    }


def make_bridge_machine() -> dict[str, Any]:
    """AGX055 — 16-cell input → 12-cell output that lands on AgYieldOptimizationAI."""
    code        = "AGX055"
    code_lower  = code.lower()
    seq_prefix  = "agx-055"
    name        = "Agriculture Yuma Facility AI Synthesis Bridge"
    in_off, in_len   = 256, 16
    out_off, out_len = 3959, 12

    # Each match pattern is a 16-element vector.  Cells are grouped 4-per-source:
    #   [0:4)  = AGX051 outputs (aqua maint)
    #   [4:8)  = AGX052 outputs (DO probe reliability)
    #   [8:12) = AGX053 outputs (HVAC service)
    #   [12:16)= AGX054 outputs (CO2 safety)
    # Each source uses [URGENT, FORECAST, CALIBRATE, NORMAL] one-hot.

    def mk_input(active_source: int | None, urgent: bool) -> list[int]:
        """Build a 16-cell match pattern. active_source 0..3 → that source URGENT
        (or FORECAST when urgent=False); None → all four NORMAL."""
        v = [0] * 16
        if active_source is None:
            for s in range(4):
                v[s*4 + 3] = 1   # NORMAL bit on every source
        else:
            v[active_source*4 + (0 if urgent else 1)] = 1
            for s in range(4):
                if s != active_source:
                    v[s*4 + 3] = 1
        return v

    def mk_output(label_index: int) -> list[int]:
        """label_index in [0,11] → one-hot 12-cell output."""
        v = [0] * 12
        v[label_index] = 1
        return v

    # 5 sequences covering the dominant facility states.  Numbering on output:
    #   0 AQUA_URGENT      1 AQUA_FORECAST     2 (reserved)
    #   3 DO_URGENT        4 DO_FORECAST       5 (reserved)
    #   6 CLIMATE_URGENT   7 CLIMATE_FORECAST  8 (reserved)
    #   9 SAFETY_URGENT   10 SAFETY_FORECAST  11 FACILITY_STABLE
    bridge_rules: list[tuple[str, list[int], list[int], str, str, str, str]] = [
        ("aqua-urgent",     mk_input(0, True),  mk_output(0),  "RED",   "error", "Aqua maintenance is critical — escalate via AgYieldOptimizationAI.", "AQUA_URGENT"),
        ("do-urgent",       mk_input(1, True),  mk_output(3),  "RED",   "error", "DO probe fault — escalate via AgYieldOptimizationAI.",              "DO_URGENT"),
        ("climate-urgent",  mk_input(2, True),  mk_output(6),  "RED",   "error", "HVAC service required urgently — escalate via AgYieldOptimizationAI.","CLIMATE_URGENT"),
        ("safety-urgent",   mk_input(3, True),  mk_output(9),  "RED",   "error", "CO2 safety breach — escalate via AgYieldOptimizationAI.",            "SAFETY_URGENT"),
        ("facility-stable", mk_input(None, False), mk_output(11), "GREEN", "info", "All four Yuma sources stable — AI may run optimization passes.",     "FACILITY_STABLE"),
    ]

    sequences = []
    for slug, in_vec, out_vec, rag, status, desc, label in bridge_rules:
        sequences.append({
            "id":   f"{seq_prefix}-{slug}",
            "name": f"Facility Bridge: {label}",
            "metadata": {"description": desc, "pattern": label,
                         "output": "[" + ",".join(str(x) for x in out_vec) + "]"},
            "vectors": [{
                "id": f"{seq_prefix}-{slug}-event",
                "elements": [{"value": v, "threshold": 0.5} for v in in_vec],
                "isInitial": True,
                "metadata": {"name": label, "description": desc},
                "outputVectors": [{
                    "id": f"{seq_prefix}-{slug}-output",
                    "vector": out_vec,
                    "metadata": {
                        "description": desc,
                        "action": "Project synthesis vector onto AgYieldOptimizationAI input window at [3959:3971]; AI dispatches cross-domain optimization.",
                    },
                }],
            }],
        })

    input_sequences = [
        {"name": label, "description": desc,
         "vectors": [in_vec],
         "metadata": {"expectedOutputCount": 1,
                      "expectedOutputVector": "[" + ",".join(str(x) for x in out_vec) + "]",
                      "scenario": slug}}
        for slug, in_vec, out_vec, _rag, _status, desc, label in bridge_rules
    ]

    metadata: dict[str, Any] = {
        "category":        "agriculture",
        "domain":          "Agriculture - Facility AI",
        "author":          "Reality Engine",
        "operationalFocus": "Yuma MQTT → AI Synthesis Bridge",
        "focusDescription": "Aggregates the four Yuma MQTT-driven maintenance machines and projects them onto AgYieldOptimizationAI.",
        "mqttIntegration": {
            "configFile":   "RealityEngine_CPP/config/mqtt-mappings.yuma-agriculture.json",
            "drivenBy":     ["AGX051", "AGX052", "AGX053", "AGX054"],
            "inputRegion":  {"offset": in_off, "length": in_len},
            "rationale":    "Aggregator only; reads downstream outputs of the four MQTT-direct machines.",
        },
        "upstreamMachine":      "AGX051 / AGX052 / AGX053 / AGX054",
        "upstreamOutputRegion": {"offset": in_off, "length": in_len},
        "predictiveManagementRole": "Cross-cluster synthesis. Projects Yuma MQTT maintenance state into the AgYieldOptimizationAI input window for cross-domain AI dispatch.",
        "aiTrigger":          "ag-yield-optimization-ai-yuma-facility-bridge",
        "dispatchableAgent":  "agriculture_yield_optimization_ai",
        "agentActions": [
            "Project synthesis vector onto AgYieldOptimizationAI input window at [3959:3971]; AI dispatches cross-domain optimization.",
            "Run facility-wide AI optimization when all sources stable.",
            "Escalate to ag-emergency-response when any source is URGENT.",
        ],
        "outputSpace": (f"12D one-hot at [{out_off}:{out_off+out_len}] — three cells per Yuma source: "
                        "[AQUA, DO, CLIMATE, SAFETY] × [URGENT, FORECAST, STABLE]"),
        "tags": sorted(set([
            "agriculture", "agriculture-ai-bridge", "agriculture-mqtt",
            "agriculture-yuma", "agriculture-generated",
            code_lower, "ai-bridge", "ai-trigger", "ai-triggers",
            "ces-sequences", "ces-sequences-5",
            "cross-domain-bridge", "dispatchable-agent", "dispatchable-agents",
            "input-sequences", "input-sequences-5",
            "machine-interconnect", "operational-management",
            "startup-loadable", "yuma-mqtt-driven",
            "agriculture_yield_optimization_ai",
        ])),
        "sequenceCount": len(bridge_rules),
        "sensorNormalization": {
            "process_stability_norm":     "1.0=source NORMAL bit set; 0.0=any URGENT bit set",
            "resource_efficiency_norm":   "1.0=source FORECAST bit set",
            "biosecurity_or_ipm_norm":    "1.0=source CALIBRATE bit set",
            "maintenance_readiness_norm": "1.0=source URGENT bit set",
        },
        "inputSemantics": [
            "AGX051 outputs [256:260) — aquaculture maintenance forecast bits",
            "AGX052 outputs [260:264) — DO probe reliability bits",
            "AGX053 outputs [264:268) — HVAC service-plan bits",
            "AGX054 outputs [268:272) — CO2 safety-compliance bits",
        ],
        "downstreamMachines": ["Ag Yield Optimization AI"],
        "downstreamPattern": ("Output region [3959:3971] lands directly on the "
                              "AgYieldOptimizationAI input window — completing the "
                              "yuma.lateraledge.cloud → maintenance machines → "
                              "yield AI chain."),
        "tagging": {
            "schemaVersion": "1.0.0",
            "managedBy":     "scripts/generate_yuma_mqtt_maintenance_machines.py",
            "primaryDomain": "agriculture",
            "domainTags":    ["agriculture", "agriculture-yuma"],
            "family":        "agriculture-ai-bridge",
            "machineCode":   code_lower,
            "capabilityTags": ["ai-bridge", "ai-triggers", "cross-domain-bridge",
                               "dispatchable-agents"],
            "workflowTags":   ["agriculture-yuma", "ai-trigger", "dispatchable-agent",
                               "operational-management"],
            "integrationTags":["ai-trigger", "dispatchable-agent",
                               "machine-interconnect", "mqtt-bridge",
                               "ai-input-projection"],
            "validationTags": ["ces-sequences", "ces-sequences-5",
                               "input-sequences", "input-sequences-5",
                               "startup-loadable"],
        },
        "governance": {
            "schemaVersion":    "1.0.0",
            "ownerTeam":        "agriculture-operations",
            "runbook":          "https://runbooks.example.org/agriculture/agx055_yuma-facility-ai-synthesis-bridge",
            "escalationPolicy": "pagerduty:ag-ops",
            "contact": {
                "primary":   "agriculture-operations-primary@example.org",
                "secondary": "agriculture-operations-secondary@example.org",
            },
            "sla": {"ok": None, "info": None, "warning": 1800, "error": 600},
            "notes": "Yuma MQTT → AI bridge.  Auto-generated; do not hand-edit — re-run scripts/generate_yuma_mqtt_maintenance_machines.py instead.",
        },
        "triggerConfig": {
            "processId":   "AGX055_YUMA_FACILITY_AI_SYNTHESIS_BRIDGE",
            "processName": name,
            "rules": [
                {"sequenceId": f"{seq_prefix}-{slug}",
                 "outputMatches": out_vec,
                 "ragStatusCode": rag,
                 "processStatus": status,
                 "description":   desc}
                for slug, _in, out_vec, rag, status, desc, _label in bridge_rules
            ],
        },
    }

    return {
        "version": "1.0.0",
        "machine": {
            "name":        name,
            "description": ("Yuma MQTT → AI Synthesis Bridge. Aggregates the four "
                            "Yuma MQTT-driven maintenance machines (AGX051-054) at "
                            "offsets [256:272) and projects a 12-cell synthesis "
                            "vector onto AgYieldOptimizationAI's input window at "
                            "offsets [3959:3971], completing the path from live "
                            "broker sensors through domain-specific maintenance "
                            "machines into the cross-domain yield AI."),
            "metadata":    metadata,
            "arbiterRule": "PASSTHROUGH",
            "perceptualMapping": {
                "input":  {"offset": in_off,  "length": in_len},
                "output": {"offset": out_off, "length": out_len},
                "bitsPerElement": 1,
            },
            "sequences":      sequences,
            "inputSequences": input_sequences,
        },
    }


TIER1_SPECS = [
    {
        "code":        "AGX051",
        "slug":        "yuma-aqua-maintenance-forecaster",
        "name":        "Agriculture Yuma Aqua Maintenance Forecaster",
        "focus_short": "Yuma Aqua Maintenance Forecast",
        "subdomain":   "Agriculture - Aquaculture",
        "topic_owner_code": "AGX001",
        "upstream_machine": "Agriculture Aquaculture Water Quality Stability",
        "mqtt_topic":  "LATERAL/WaterSuite/DEV0000001/SensorReadings/v1",
        "sensors":     ["water pH in band", "water EC in band",
                        "water ORP in band", "water turbidity in band"],
        "input_offset":  40,
        "output_offset": 256,
        "agent":         "aquaculture_predictive_maintenance_agent",
        "downstream":    ["Agriculture Yuma Facility AI Synthesis Bridge"],
        "description":   ("Yuma MQTT-driven predictive-maintenance machine. "
                          "Reads the four water-quality cells at offsets "
                          "[40:44) populated by the live "
                          "LATERAL/WaterSuite/DEV0000001/SensorReadings/v1 "
                          "MQTT stream (pH/EC/ORP/turbidity) and produces a "
                          "4-cell maintenance signal at offsets [256:260): "
                          "URGENT_MAINT, FORECAST_MAINT, CALIBRATE, NORMAL. "
                          "Same input region as AGX001 but a maintenance "
                          "lens — perceptual space is a read-shared resource."),
    },
    {
        "code":        "AGX052",
        "slug":        "yuma-do-probe-reliability-tracker",
        "name":        "Agriculture Yuma DO Probe Reliability Tracker",
        "focus_short": "Yuma DO Probe Reliability",
        "subdomain":   "Agriculture - Aquaculture",
        "topic_owner_code": "AGX005",
        "upstream_machine": "Agriculture Aquaculture Dissolved Oxygen Control",
        "mqtt_topic":  "LATERAL/DOSuite/DEV0000017/SensorReadings/v1",
        "sensors":     ["DO level in nominal band", "DO temp in nominal band",
                        "low-DO watch band", "high-DO-temp watch band"],
        "input_offset":  84,
        "output_offset": 260,
        "agent":         "aquaculture_do_probe_reliability_agent",
        "downstream":    ["Agriculture Yuma Facility AI Synthesis Bridge"],
        "description":   ("Yuma MQTT-driven DO-probe reliability machine. "
                          "Reads the four DO sensor cells at offsets [84:88) "
                          "populated by the live "
                          "LATERAL/DOSuite/DEV0000017/SensorReadings/v1 MQTT "
                          "stream (DO level + DO temp + their watch bands) "
                          "and produces a 4-cell probe-reliability signal at "
                          "offsets [260:264): URGENT_MAINT, FORECAST_MAINT, "
                          "CALIBRATE, NORMAL. Complements AGX005 (operational "
                          "DO control) by surfacing probe-health concerns "
                          "such as drift or sensor failure."),
    },
    {
        "code":        "AGX053",
        "slug":        "yuma-vpd-hvac-service-planner",
        "name":        "Agriculture Yuma VPD HVAC Service Planner",
        "focus_short": "Yuma VPD HVAC Service Plan",
        "subdomain":   "Agriculture - Indoor Grow House",
        "topic_owner_code": "AGX026",
        "upstream_machine": "Agriculture Indoor Grow House VPD Climate Management",
        "mqtt_topic":  "LATERAL/AmbientSuite/DEV0000009/SensorReadings/v1",
        "sensors":     ["ambient temp in band", "ambient humidity in band",
                        "ambient temp high watch", "ambient humidity low watch"],
        "input_offset":  184,
        "output_offset": 264,
        "agent":         "growhouse_hvac_service_agent",
        "downstream":    ["Agriculture Yuma Facility AI Synthesis Bridge"],
        "description":   ("Yuma MQTT-driven HVAC-service-plan machine. Reads "
                          "the four VPD climate cells at offsets [184:188) "
                          "populated by the live "
                          "LATERAL/AmbientSuite/DEV0000009/SensorReadings/v1 "
                          "MQTT stream (temp + humidity + their watch bands) "
                          "and produces a 4-cell HVAC service plan at offsets "
                          "[264:268): URGENT_MAINT, FORECAST_MAINT, "
                          "CALIBRATE, NORMAL. Pairs with AGX026 (operational "
                          "VPD climate management) to drive proactive "
                          "dehumidifier and cooling service work."),
    },
    {
        "code":        "AGX054",
        "slug":        "yuma-co2-safety-compliance-officer",
        "name":        "Agriculture Yuma CO2 Safety Compliance Officer",
        "focus_short": "Yuma CO2 Safety Compliance",
        "subdomain":   "Agriculture - Indoor Grow House",
        "topic_owner_code": "AGX032",
        "upstream_machine": "Agriculture Indoor Grow House CO2 Enrichment Safety",
        "mqtt_topic":  "LATERAL/AmbientSuite/DEV0000009/SensorReadings/v1",
        "sensors":     ["CO2 in enrichment band (600-1500 ppm)",
                        "CO2 in watch band (1500-3000 ppm)",
                        "CO2 in danger band (3000-5000 ppm)",
                        "ambient temp in band"],
        "input_offset":  228,
        "output_offset": 268,
        "agent":         "growhouse_safety_compliance_agent",
        "severity":      "life-safety",
        "downstream":    ["Agriculture Yuma Facility AI Synthesis Bridge"],
        "description":   ("Yuma MQTT-driven life-safety CO2 compliance "
                          "machine. Reads the four CO2 safety cells at "
                          "offsets [228:232) populated by the live "
                          "LATERAL/AmbientSuite/DEV0000009/SensorReadings/v1 "
                          "MQTT stream (CO2 enrichment/watch/danger bands "
                          "plus ambient temp) and produces a 4-cell compliance "
                          "signal at offsets [268:272): URGENT_MAINT, "
                          "FORECAST_MAINT, CALIBRATE, NORMAL. Tier-1 to "
                          "AGX032 (which gates evacuation logic) — drives "
                          "compliance reporting, calibration, and exhaust "
                          "verification ahead of any threshold breach."),
    },
]


def write_machine(out_dir: Path, code: str, slug: str, payload: dict[str, Any]) -> Path:
    path = out_dir / f"{code}_{slug}.json"
    path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    return path


def main() -> None:
    if not OUT_DIR.exists():
        raise SystemExit(f"Output directory missing: {OUT_DIR}")

    written: list[Path] = []
    for spec in TIER1_SPECS:
        payload = make_tier1_machine(spec)
        written.append(write_machine(OUT_DIR, spec["code"], spec["slug"], payload))

    bridge = make_bridge_machine()
    written.append(write_machine(OUT_DIR, "AGX055",
                                 "yuma-facility-ai-synthesis-bridge", bridge))

    print(f"Wrote {len(written)} machine JSON files to {OUT_DIR}:")
    for p in written:
        print(f"  ✓ {p.name}")


if __name__ == "__main__":
    main()
