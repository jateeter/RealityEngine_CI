#!/usr/bin/env python3
"""
Generate health-services public-health transformation example machines.

The generated machines are grounded in the 2026 PHAB practical guide concepts:
assess evaluability, define ideal state, build logic models, identify evaluation
questions, select indicators/measures, and use evaluation findings to improve
public-health system transformation.
"""

from __future__ import annotations

import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
OUT_DIR = ROOT / "examples" / "machines"

GUIDE_SOURCE = "Practical Guide for Building an Eval Plan for PH System Transformation, PHAB, February 2026"
GUIDE_STEPS = [
    "assess evaluability",
    "select a topic and define the ideal state",
    "build a logic model",
    "combine topic-specific logic models",
    "identify evaluation questions",
    "select measures and draft an evaluation plan matrix",
]

FOCUS_AREAS = [
    ("Evaluability Readiness", "evaluation capacity, interest-holder support, feasibility, and right-sized scope"),
    ("Interest Holder Alignment", "community, partner, and governance participation in transformation evaluation"),
    ("Evaluation Capacity", "staffing, analytic support, evaluator access, and sustainable measurement capability"),
    ("Public Health Financing", "per-capita funding, non-categorical funding, FPHS investment, and fiscal flexibility"),
    ("Governance Modernization", "decision rights, accountability, cross-jurisdiction coordination, and stewardship"),
    ("Policy Implementation", "policy adoption, enforcement readiness, waiver navigation, and implementation fidelity"),
    ("Workforce Development", "workforce capacity, skills, retention, role clarity, and surge readiness"),
    ("Service Delivery Models", "integrated care delivery, referral coordination, field operations, and access pathways"),
    ("Performance Standards", "standards adoption, quality improvement, service-level targets, and reliability"),
    ("Data Systems Interoperability", "shared data, common identifiers, reporting quality, and exchange timeliness"),
    ("Community Health Outcomes", "equity-sensitive outcome tracking, population impact, and community feedback"),
    ("Foundational Public Health Services", "FPHS coverage, capability maturity, and service availability"),
    ("Equity and Access", "barrier detection, culturally responsive service, language access, and reach"),
    ("Care Coordination", "closed-loop referrals, warm handoffs, care-team synchronization, and follow-up"),
    ("Behavioral Health Integration", "screening, crisis routing, integrated supports, and stabilization"),
    ("Maternal Child Family Health", "prenatal, pediatric, family support, and home-visiting coordination"),
    ("Chronic Disease Prevention", "risk stratification, self-management support, prevention programs, and follow-up"),
    ("Environmental Health Response", "exposure detection, inspection routing, remediation, and partner notification"),
    ("Emergency Preparedness", "incident readiness, resource staging, surge staffing, and continuity of operations"),
    ("Learning Health System", "measure review, feedback loops, adaptation, and sustained improvement"),
]

FUNCTIONS = [
    ("Signal Monitor", "detects early warning signals and initiates AI triage"),
    ("Resource Router", "routes scarce resources to the highest-priority population need"),
    ("Equity Guardrail", "flags inequitable reach, service gaps, or disproportionate burden"),
    ("Capacity Balancer", "balances workforce, partner, and program capacity against demand"),
    ("Referral Optimizer", "optimizes warm handoffs and closed-loop referral completion"),
    ("Measure Tracker", "tracks indicators, measures, data quality, and evaluation readiness"),
    ("Agent Dispatcher", "dispatches AI agents for documentation, outreach, or partner coordination"),
    ("Governance Escalator", "escalates unresolved barriers to accountable decision makers"),
    ("Learning Loop", "turns evaluation findings into adaptation and quality improvement"),
    ("Outcome Stabilizer", "monitors whether optimized delivery is producing sustained outcomes"),
]

AGENTS = [
    "community_health_worker_agent",
    "care_coordinator_agent",
    "benefits_navigation_agent",
    "public_health_nurse_agent",
    "behavioral_health_crisis_agent",
    "evaluation_analyst_agent",
    "partner_coordination_agent",
    "resource_dispatch_agent",
    "equity_review_agent",
    "quality_improvement_agent",
]


def slug(value: str) -> str:
    return "".join(ch.lower() if ch.isalnum() else "-" for ch in value).strip("-").replace("--", "-")


def vector_elements(values: list[float]) -> list[dict[str, float]]:
    return [{"value": value, "threshold": 0.5} for value in values]


def machine_payload(index: int, focus_index: int, function_index: int) -> dict:
    focus, focus_desc = FOCUS_AREAS[focus_index]
    function, function_desc = FUNCTIONS[function_index]
    agent = AGENTS[(focus_index + function_index) % len(AGENTS)]
    base = 397 + focus_index * 12
    input_offset = base + (function_index % 3) * 4
    output_offset = base + ((function_index + 1) % 3) * 4
    code = f"hsph-{index:03d}"
    name = f"Health Services {focus} {function}"
    topic_slug = slug(f"{focus}-{function}")

    critical_action = f"Dispatch {agent} to resolve {focus.lower()} delivery risk and update the evaluation plan matrix."
    optimize_action = f"Trigger optimization agent workflow for {focus.lower()} using current logic-model outputs and measures."
    stable_action = f"Record sustained progress toward the ideal state for {focus.lower()} and keep monitoring."

    return {
        "version": "1.0.0",
        "machine": {
            "name": name,
            "description": (
                f"Health Services domain machine for {focus.lower()} that {function_desc}. "
                f"It operationalizes the PH system transformation evaluation-plan workflow by "
                f"watching evaluability, logic-model outputs, evaluation questions, selected measures, "
                f"and AI-dispatchable intervention status. Output at [{output_offset}:{output_offset + 4}] "
                f"can trigger downstream agents or peer machines in the {focus} pathway."
            ),
            "metadata": {
                "category": "health-services",
                "domain": f"Health Services - {focus}",
                "author": "Reality Engine",
                "sourceGuide": GUIDE_SOURCE,
                "guideConcepts": GUIDE_STEPS,
                "transformationFocus": focus,
                "focusDescription": focus_desc,
                "function": function,
                "aiTrigger": f"{topic_slug}-risk-or-optimization-signal",
                "dispatchableAgent": agent,
                "agentActions": [critical_action, optimize_action, stable_action],
                "outputSpace": (
                    f"4D binary at [{output_offset}:{output_offset + 4}]: "
                    "[1,0,0,0]=URGENT_AGENT_DISPATCH, [0,1,0,0]=OPTIMIZE_DELIVERY, "
                    "[0,0,1,0]=HUMAN_REVIEW, [0,0,0,1]=IDEAL_STATE_STABLE"
                ),
                "tags": [
                    "health-services",
                    "community-health-care-delivery",
                    "public-health-system-transformation",
                    "evaluation-plan",
                    "logic-model",
                    "ai-triggers",
                    "dispatchable-agents",
                    slug(focus),
                    slug(function),
                ],
                "sequenceCount": 3,
                "populationFocus": "Community health service recipients, public health agencies, care partners, and cross-sector service networks",
                "sensorNormalization": {
                    "evaluability_readiness_norm": "0.0=no usable data, support, or capacity; 0.5=partial evaluability; 1.0=clear scope, data, resources, and interest-holder support",
                    "service_delivery_pressure_norm": "0.0=acute unmet demand or failed handoffs; 0.5=manageable pressure; 1.0=stable delivery capacity",
                    "equity_signal_norm": "0.0=large disparity or excluded population; 0.5=known gap under mitigation; 1.0=equitable reach and experience",
                    "measure_confidence_norm": "0.0=missing/low-quality measures; 0.5=partial indicator confidence; 1.0=timely, actionable, trusted measures",
                },
                "inputSemantics": [
                    "evaluability readiness",
                    "service delivery pressure",
                    "equity signal",
                    "measure confidence",
                ],
                "downstreamPattern": f"Output region [{output_offset}:{output_offset + 4}] feeds peer health-services machines and AI dispatch orchestration.",
            },
            "arbiterRule": "PASSTHROUGH",
            "perceptualMapping": {
                "input": {"offset": input_offset, "length": 4},
                "output": {"offset": output_offset, "length": 4},
            },
            "sequences": [
                {
                    "id": f"{code}-urgent-dispatch",
                    "name": f"{focus} {function}: READY -> GAP -> CRITICAL -> URGENT_AGENT_DISPATCH",
                    "metadata": {
                        "description": "Escalates when an initially evaluable transformation area develops delivery pressure, equity risk, and weak measure confidence.",
                        "path": "READY -> GAP -> CRITICAL",
                        "output": "[1,0,0,0]",
                    },
                    "vectors": [
                        {
                            "id": f"{code}-ready",
                            "elements": vector_elements([1, 1, 1, 1]),
                            "isInitial": True,
                            "metadata": {"name": "READY", "description": "Evaluable, resourced, equitable, and measurable baseline."},
                            "nextVectorIds": [f"{code}-gap"],
                        },
                        {
                            "id": f"{code}-gap",
                            "elements": vector_elements([1, 0, 1, 0]),
                            "isInitial": False,
                            "metadata": {"name": "GAP", "description": "Delivery pressure and weak measurement appear while evaluability and equity signals remain visible."},
                            "nextVectorIds": [f"{code}-critical"],
                        },
                        {
                            "id": f"{code}-critical",
                            "elements": vector_elements([0, 0, 0, 0]),
                            "isInitial": False,
                            "metadata": {"name": "CRITICAL", "description": "Transformation signal requires urgent AI dispatch and accountable follow-up."},
                            "outputVectors": [
                                {
                                    "id": f"{code}-urgent-output",
                                    "vector": [1, 0, 0, 0],
                                    "metadata": {"description": "Urgent AI dispatch required.", "action": critical_action},
                                }
                            ],
                        },
                    ],
                },
                {
                    "id": f"{code}-optimize-delivery",
                    "name": f"{focus} {function}: OPTIMIZATION_OPPORTUNITY -> OPTIMIZE_DELIVERY",
                    "metadata": {
                        "description": "Fires when measures show a feasible optimization opportunity without acute crisis.",
                        "pattern": "OPTIMIZATION_OPPORTUNITY",
                        "output": "[0,1,0,0]",
                    },
                    "vectors": [
                        {
                            "id": f"{code}-optimize",
                            "elements": vector_elements([0, 1, 0, 1]),
                            "isInitial": True,
                            "metadata": {"name": "OPTIMIZATION_OPPORTUNITY", "description": "Service delivery is functioning but AI optimization can improve outcomes, equity, or efficiency."},
                            "outputVectors": [
                                {
                                    "id": f"{code}-optimize-output",
                                    "vector": [0, 1, 0, 0],
                                    "metadata": {"description": "Optimization agent workflow should run.", "action": optimize_action},
                                }
                            ],
                        }
                    ],
                },
                {
                    "id": f"{code}-stable-ideal-state",
                    "name": f"{focus} {function}: IDEAL_STATE_SIGNAL -> IDEAL_STATE_STABLE",
                    "metadata": {
                        "description": "Fires when the focus area shows sustained, measured progress toward the ideal state.",
                        "pattern": "IDEAL_STATE_SIGNAL",
                        "output": "[0,0,0,1]",
                    },
                    "vectors": [
                        {
                            "id": f"{code}-stable",
                            "elements": vector_elements([1, 1, 0, 1]),
                            "isInitial": True,
                            "metadata": {"name": "IDEAL_STATE_SIGNAL", "description": "Delivery is stable, measures are trusted, and the transformation area is on track."},
                            "outputVectors": [
                                {
                                    "id": f"{code}-stable-output",
                                    "vector": [0, 0, 0, 1],
                                    "metadata": {"description": "Ideal-state progress is stable.", "action": stable_action},
                                }
                            ],
                        }
                    ],
                },
            ],
            "inputSequences": [
                {
                    "name": "Escalation to urgent agent dispatch",
                    "description": "Evaluability starts strong, then delivery and measurement gaps emerge, then the focus area reaches crisis.",
                    "vectors": [[1, 1, 1, 1], [1, 0, 1, 0], [0, 0, 0, 0]],
                    "metadata": {
                        "expectedOutputCount": 1,
                        "expectedOutputVector": "[1,0,0,0]",
                        "scenario": "urgent-agent-dispatch",
                    },
                },
                {
                    "name": "Optimization opportunity",
                    "description": "AI optimization can improve delivery before crisis conditions appear.",
                    "vectors": [[0, 1, 0, 1]],
                    "metadata": {
                        "expectedOutputCount": 1,
                        "expectedOutputVector": "[0,1,0,0]",
                        "scenario": "optimize-delivery",
                    },
                },
                {
                    "name": "Stable ideal-state progress",
                    "description": "The focus area is progressing toward the transformed ideal state.",
                    "vectors": [[1, 1, 0, 1]],
                    "metadata": {
                        "expectedOutputCount": 1,
                        "expectedOutputVector": "[0,0,0,1]",
                        "scenario": "ideal-state-stable",
                    },
                },
                {
                    "name": "Ready baseline without output",
                    "description": "A single ready signal arms the escalation path but does not dispatch an agent.",
                    "vectors": [[1, 1, 1, 1]],
                    "metadata": {
                        "expectedOutputCount": 0,
                        "scenario": "ready-baseline",
                    },
                },
            ],
        },
    }


def main() -> None:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    for index in range(1, 201):
        focus_index = (index - 1) // len(FUNCTIONS)
        function_index = (index - 1) % len(FUNCTIONS)
        payload = machine_payload(index, focus_index, function_index)
        filename = f"HSPH{index:03d}_{slug(payload['machine']['name']).replace('health-services-', '')}.json"
        (OUT_DIR / filename).write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    print(f"Generated 200 health-services machines in {OUT_DIR}")


if __name__ == "__main__":
    main()
