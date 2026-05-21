#!/usr/bin/env python3
"""
Generate life-balance domain machines.

The domain models lifestyle-psychiatry operations inspired by publicly
described Ann Childers, MD practice themes: mainstream psychiatric care,
nutrition, sleep, metabolic monitoring, genetics/temperament testing, and
whole-health behavior support. The machines are examples only and do not provide
medical diagnosis or treatment advice.
"""

from __future__ import annotations

import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
OUT_DIR = ROOT / "examples" / "machines"


WORKSTREAMS = [
    ("Whole Person Intake And Goals", [
        ("Psychiatric History Intake", "diagnosis history, current symptoms, risk screen, medication history, and patient goals"),
        ("Lifestyle Baseline Interview", "food pattern, sleep timing, movement, stress, relationships, and substance exposure"),
        ("Readiness Motivation Assessment", "readiness to change, confidence, barriers, preferred pace, and support needs"),
        ("Care Preference Alignment", "patient priorities, medication preference, therapy goals, lifestyle focus, and family context"),
        ("Risk Safety Review", "self-harm screen, safety planning needs, crisis contacts, and escalation threshold"),
        ("Adolescent Guardian Alignment", "youth goals, guardian concerns, school schedule, consent, and privacy boundaries"),
        ("Functional Impairment Map", "school, work, family, social, sleep, and daily living impact"),
        ("Medication Lifestyle Interaction Intake", "medication effects, appetite, sleep, weight, activation, and adherence concerns"),
        ("Initial Goal Contract", "short-term goals, measurable habits, care-team owner, and review cadence"),
        ("Intake Executive Summary", "symptoms, lifestyle baseline, risks, care preferences, and first-plan readiness"),
    ]),
    ("Nutrition And Metabolic Health", [
        ("Meal Pattern Stability", "meal timing, protein adequacy, ultra-processed exposure, glycemic load, and energy swings"),
        ("Carbohydrate Tolerance Watch", "post-meal symptoms, CGM excursions, hunger rebound, and mood variability"),
        ("Protein Sufficiency Monitor", "protein distribution, satiety, growth needs, recovery, and appetite regulation"),
        ("Food Mood Journal Review", "food intake, mood rating, anxiety, attention, and sleep-next-day effect"),
        ("Hydration Electrolyte Monitor", "fluid intake, sodium/potassium context, headache, fatigue, and activity level"),
        ("Weight Metabolic Trend", "weight trend, waist signal, medication effects, insulin-resistance risk, and patient goals"),
        ("Micronutrient Risk Screen", "diet pattern, restriction, GI symptoms, fatigue, and lab-follow-up need"),
        ("Family Food Environment", "shopping pattern, meal prep capacity, school meals, budget, and family support"),
        ("Nutrition Plan Adherence", "plan clarity, adherence, barriers, adverse effects, and preference fit"),
        ("Metabolic Nutrition Executive", "glycemic stability, nourishment adequacy, adherence, barriers, and mood response"),
    ]),
    ("Sleep And Circadian Rhythm", [
        ("Sleep Schedule Regularity", "bedtime, wake time, weekend shift, naps, and school/work alignment"),
        ("Insomnia Trigger Review", "rumination, screens, caffeine, late meals, medication timing, and environment"),
        ("Restorative Sleep Quality", "sleep duration, awakenings, morning energy, nightmares, and daytime impairment"),
        ("Sleep Apnea Risk Screen", "snoring, witnessed apnea, morning headache, sleepiness, and metabolic risk"),
        ("Light Exposure Timing", "morning light, evening light, screen timing, and circadian phase support"),
        ("Caffeine Stimulant Timing", "caffeine dose, stimulant medication timing, anxiety, and sleep onset"),
        ("Adolescent Sleep School Fit", "school start, homework load, device use, sports, and family routines"),
        ("Shift Work Sleep Protection", "rotating schedule, anchor sleep, light control, meals, and recovery days"),
        ("Sleep Plan Adherence", "sleep-window target, wind-down routine, barrier notes, and next-day mood"),
        ("Sleep Executive Stabilizer", "duration, regularity, restorative quality, circadian fit, and symptom response"),
    ]),
    ("Movement And Physical Health", [
        ("Movement Baseline", "steps, sedentary time, exercise preference, limitations, and energy response"),
        ("Strength Training Routine", "weekly sessions, progression, soreness, confidence, and safety constraints"),
        ("Zone Two Activity Plan", "aerobic minutes, intensity tolerance, schedule fit, and recovery"),
        ("Outdoor Activity Exposure", "daylight, walking, nature contact, weather barrier, and mood response"),
        ("Mobility Pain Constraint", "pain, injury risk, mobility limit, clinician referral, and adaptation need"),
        ("Adolescent Sports Balance", "practice load, sleep tradeoff, nutrition support, stress, and injury risk"),
        ("Medication Movement Effects", "akathisia, fatigue, sedation, appetite, and activity tolerance"),
        ("Exercise Anxiety Depression Response", "mood before/after, anxiety sensitivity, motivation, and avoidance"),
        ("Movement Habit Adherence", "planned movement, completed movement, barrier, and reward feedback"),
        ("Movement Executive Optimizer", "activity dose, recovery, symptoms, confidence, and adherence"),
    ]),
    ("Stress Resilience And Psychotherapy", [
        ("Stress Load Inventory", "life stressors, perceived control, burnout risk, trauma triggers, and supports"),
        ("Breathing Regulation Practice", "practice frequency, panic symptoms, somatic cues, and effectiveness"),
        ("Cognitive Pattern Review", "automatic thoughts, avoidance, rumination, shame, and reframe progress"),
        ("Emotion Regulation Skills", "distress tolerance, anger, sadness, impulsivity, and coping selection"),
        ("Mindfulness Attention Practice", "practice minutes, attention drift, agitation, and calm response"),
        ("Therapy Homework Completion", "assignment clarity, completion, barrier, and symptom learning"),
        ("Resilience Protective Factors", "meaning, mastery, gratitude, routines, and connection"),
        ("Trauma Sensitive Pacing", "trigger load, window of tolerance, grounding skill, and safety plan fit"),
        ("Stress Recovery Rhythm", "recovery blocks, recreation, sleep protection, and demand pacing"),
        ("Resilience Executive Summary", "stress load, coping skills, therapy engagement, recovery, and relapse risk"),
    ]),
    ("Medication And Psychiatric Care", [
        ("Medication Response Tracker", "target symptoms, side effects, adherence, dose timing, and benefit signal"),
        ("Adverse Effect Watch", "sleep, appetite, activation, sedation, metabolic effects, and movement symptoms"),
        ("Medication Nutrition Interaction", "meal timing, nausea, appetite, glucose signal, and nutrient risk"),
        ("Medication Sleep Interaction", "insomnia, sedation, nightmares, timing, and next-day function"),
        ("Stimulant Appetite Sleep Balance", "attention benefit, appetite, rebound, sleep onset, and growth context"),
        ("Mood Stabilization Monitor", "mood variability, irritability, sleep shift, activation, and safety signals"),
        ("Anxiety Treatment Response", "panic, avoidance, somatic tension, medication response, and therapy progress"),
        ("Depression Recovery Response", "mood, anhedonia, energy, sleep, appetite, and functional activation"),
        ("Care Visit Preparation", "questions, symptom scores, lifestyle data, medication log, and decisions needed"),
        ("Psychiatric Care Executive", "response, side effects, safety, lifestyle interaction, and next visit priorities"),
    ]),
    ("Adolescent Family And School", [
        ("School Function Monitor", "attendance, attention, homework, grades, social stress, and sleep impact"),
        ("Family Routine Alignment", "meals, bedtime, devices, transport, appointments, and guardian support"),
        ("Device Use Boundary", "screen timing, social media load, gaming, sleep disruption, and family agreement"),
        ("Peer Connection Monitor", "friend support, isolation, bullying, belonging, and activity participation"),
        ("Growth Development Watch", "nutrition, sleep, activity, medication effects, and clinician follow-up needs"),
        ("Parent Coaching Plan", "communication style, reinforcement, conflict pattern, and consistency"),
        ("School Accommodation Tracker", "504/IEP needs, teacher feedback, assignment load, and implementation"),
        ("Sports Performance Balance", "training load, nutrition, injury, sleep, and emotional pressure"),
        ("Adolescent Safety Signal", "risk disclosure, self-harm concern, substance exposure, and crisis plan"),
        ("Youth Family Executive", "school, family routines, peer connection, sleep, safety, and care coordination"),
    ]),
    ("Testing Personalization And Monitoring", [
        ("CGM Data Intake", "wear time, post-meal excursions, overnight trend, symptoms, and data quality"),
        ("CGM Mood Correlation", "glucose variability, anxiety, irritability, attention, and food timing"),
        ("Genetics Result Intake", "pharmacogenomic flags, family history, patient questions, and care-team review"),
        ("Temperament Profile Review", "novelty seeking, harm avoidance, persistence, reward dependence, and coaching style"),
        ("Lab Follow Up Queue", "ordered labs, completed labs, abnormal flags, and clinician review deadline"),
        ("Wearable Sleep Activity Intake", "sleep estimate, activity minutes, heart rate trend, and data reliability"),
        ("Patient Reported Outcome Scores", "mood, anxiety, sleep, energy, function, and trend direction"),
        ("Data Consent Privacy Check", "consent scope, guardian access, data source, retention, and sharing boundary"),
        ("Monitoring Data Quality", "missing data, device issues, inconsistent logging, and confidence rating"),
        ("Personalization Executive", "CGM, genetics, temperament, labs, wearables, and outcome-score synthesis"),
    ]),
    ("Social Connection And Harm Reduction", [
        ("Connection Baseline", "support network, loneliness, family conflict, community, and belonging"),
        ("Relationship Stress Monitor", "conflict, attachment stress, communication, boundaries, and repair attempts"),
        ("Substance Exposure Screen", "alcohol, cannabis, nicotine, stimulants, caffeine, and medication interactions"),
        ("Harm Reduction Plan", "trigger contexts, safer alternatives, accountability, support, and escalation threshold"),
        ("Community Activity Engagement", "group activity, volunteering, school club, faith/community, and enjoyment"),
        ("Digital Social Load", "online comparison, conflict, news stress, sleep impact, and boundary plan"),
        ("Care Team Communication", "patient, family, therapist, prescriber, school, and primary care handoffs"),
        ("Social Rhythm Stabilizer", "regular meals, sleep, movement, social contact, and routine anchors"),
        ("Relapse Prevention Support", "warning signs, support contacts, coping menu, and care escalation"),
        ("Connection Executive", "support strength, harmful exposure, social rhythm, communication, and prevention plan"),
    ]),
    ("Projection Automation And Outcomes", [
        ("Weekly Balance Projection", "sleep, nutrition, movement, stress, medication, and support forecast"),
        ("Risk Drift Forecaster", "symptom drift, sleep debt, glycemic instability, missed meds, and isolation"),
        ("Plan Adjustment Dispatcher", "barriers, preferences, clinical constraints, and next best lifestyle step"),
        ("Care Team Escalation Router", "safety signal, adverse effect, metabolic concern, and clinician urgency"),
        ("Habit Automation Scheduler", "reminders, habit stacking, appointment prep, and recovery windows"),
        ("Metabolic Mood Scenario E2E", "CGM trend, food-mood journal, sleep effect, and nutrition plan change"),
        ("Adolescent Sleep School E2E", "sleep schedule, device boundary, school impairment, and family plan"),
        ("Medication Lifestyle E2E", "side effects, appetite, sleep, activity, and prescriber review"),
        ("Stress Connection E2E", "stress load, isolation, coping skills, and support activation"),
        ("Life Balance Command Center", "all pillars, psychiatric response, personalization data, projected risk, and automation readiness"),
    ]),
]

AGENTS = [
    "life_balance_intake_agent",
    "nutrition_metabolic_agent",
    "sleep_circadian_agent",
    "movement_health_agent",
    "stress_resilience_agent",
    "psychiatric_care_agent",
    "adolescent_family_agent",
    "testing_personalization_agent",
    "connection_harm_reduction_agent",
    "life_balance_command_agent",
]


def slug(value: str) -> str:
    result = "".join(ch.lower() if ch.isalnum() else "-" for ch in value).strip("-")
    while "--" in result:
        result = result.replace("--", "-")
    return result


def vector_elements(values: list[int]) -> list[dict]:
    return [{"value": value} for value in values]


def existing_non_life_balance_max_offset() -> int:
    max_offset = 0
    if not OUT_DIR.exists():
        return max_offset
    for path in OUT_DIR.glob("*.json"):
        if path.name.startswith("LBL"):
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
    matches = sorted(OUT_DIR.glob(f"{prefix}{index:03d}_*.json"))
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
    if len(specs) != 100:
        raise RuntimeError(f"expected exactly 100 life-balance specs, got {len(specs)}")
    return specs


def upstream_index_for(index: int) -> int | None:
    if (index - 1) % 10 != 0:
        return index - 1
    cross_workstream = {
        11: 10,
        21: 20,
        31: 30,
        41: 40,
        51: 50,
        61: 60,
        71: 70,
        81: 80,
        91: 90,
    }
    return cross_workstream.get(index)


def external_input_override(index: int) -> tuple[str, int, int, str] | None:
    health_links = {
        24: (142, "behavioral-health resource-routing signal for sleep and shelter-sensitive mood risk"),
        46: (131, "care-coordination signal for trauma-sensitive pacing"),
        74: (101, "community-health outcomes signal for growth and family context"),
        91: (191, "learning-health signal for weekly projection"),
    }
    healthcare_links = {
        56: ("MedicationAdherenceMonitor", "medication-adherence signal for psychiatric care response"),
        84: ("PatientWellness", "patient-wellness signal for outcome-score synthesis"),
    }
    if index in health_links:
        machine_index, purpose = health_links[index]
        offset, length = region_for("HSPH", machine_index, "output")
        return ("health-services", offset, length, purpose)
    if index in healthcare_links:
        machine_name, purpose = healthcare_links[index]
        matches = sorted(OUT_DIR.glob(f"{machine_name}.json"))
        if matches:
            document = json.loads(matches[0].read_text())
            region = document["machine"]["perceptualMapping"]["output"]
            return ("healthcare", int(region["offset"]), int(region["length"]), purpose)
    return None


def external_output_override(index: int) -> tuple[str, int, int, str] | None:
    health_targets = {
        94: (145, "care-team escalation into behavioral-health referral optimization"),
        100: (197, "life-balance command signal into health learning-system dispatcher"),
    }
    healthcare_targets = {
        93: ("WellnessAnalytics", "plan-adjustment signal into wellness analytics"),
        98: ("CareTransitionWorkflow", "stress-connection e2e signal into care transition workflow"),
    }
    if index in health_targets:
        machine_index, purpose = health_targets[index]
        offset, length = region_for("HSPH", machine_index, "input")
        return ("health-services", offset, length, purpose)
    if index in healthcare_targets:
        machine_name, purpose = healthcare_targets[index]
        matches = sorted(OUT_DIR.glob(f"{machine_name}.json"))
        if matches:
            document = json.loads(matches[0].read_text())
            region = document["machine"]["perceptualMapping"]["input"]
            return ("healthcare", int(region["offset"]), int(region["length"]), purpose)
    return None


def standard_sequences(code: str, focus: str, actions: list[str]) -> list[dict]:
    return [
        {
            "id": f"{code}-care-team-review",
            "name": f"{focus}: WATCH -> CARE_TEAM_REVIEW",
            "metadata": {"description": "Escalates clinical or safety concern for care-team review.", "output": "[1,0,0,0]"},
            "vectors": [
                {"id": f"{code}-watch", "elements": vector_elements([1, 0, 1, 1]), "isInitial": True, "nextVectorIds": [f"{code}-review"]},
                {"id": f"{code}-review", "elements": vector_elements([0, 0, 1, 1]), "isInitial": False, "outputVectors": [{"id": f"{code}-review-output", "vector": [1, 0, 0, 0], "metadata": {"action": actions[0]}}]},
            ],
        },
        {
            "id": f"{code}-plan-adjust",
            "name": f"{focus}: BARRIER -> LIFESTYLE_PLAN_ADJUST",
            "metadata": {"description": "Adjusts lifestyle plan based on barriers and preferences.", "output": "[0,1,0,0]"},
            "vectors": [
                {"id": f"{code}-barrier", "elements": vector_elements([0, 1, 1, 0]), "isInitial": True, "outputVectors": [{"id": f"{code}-plan-output", "vector": [0, 1, 0, 0], "metadata": {"action": actions[1]}}]},
            ],
        },
        {
            "id": f"{code}-monitoring-task",
            "name": f"{focus}: DATA_GAP -> MONITORING_TASK",
            "metadata": {"description": "Creates monitoring, journaling, lab, CGM, wearable, or follow-up task.", "output": "[0,0,1,0]"},
            "vectors": [
                {"id": f"{code}-data-gap", "elements": vector_elements([1, 0, 0, 1]), "isInitial": True, "outputVectors": [{"id": f"{code}-monitor-output", "vector": [0, 0, 1, 0], "metadata": {"action": actions[2]}}]},
            ],
        },
        {
            "id": f"{code}-stable-balance",
            "name": f"{focus}: STABLE -> STABLE_BALANCE",
            "metadata": {"description": "Confirms stable life-balance plan state.", "output": "[0,0,0,1]"},
            "vectors": [
                {"id": f"{code}-stable", "elements": vector_elements([1, 1, 0, 0]), "isInitial": True, "outputVectors": [{"id": f"{code}-stable-output", "vector": [0, 0, 0, 1], "metadata": {"action": actions[3]}}]},
            ],
        },
    ]


def standard_input_sequences(domain_e2e: list[dict] | None = None) -> list[dict]:
    sequences = [
        {"name": "Care team review", "description": "Two-step concern escalation ending in care-team review.", "vectors": [[1, 0, 1, 1], [0, 0, 1, 1]], "metadata": {"expectedOutputCount": 1, "expectedOutputVector": "[1,0,0,0]", "scenario": "care-team-review", "sequenceLength": 2}},
        {"name": "Lifestyle plan adjustment", "description": "Barrier or preference signal adjusts the lifestyle plan.", "vectors": [[0, 1, 1, 0]], "metadata": {"expectedOutputCount": 1, "expectedOutputVector": "[0,1,0,0]", "scenario": "lifestyle-plan-adjust"}},
        {"name": "Monitoring task", "description": "Data gap creates a monitoring or follow-up task.", "vectors": [[1, 0, 0, 1]], "metadata": {"expectedOutputCount": 1, "expectedOutputVector": "[0,0,1,0]", "scenario": "monitoring-task"}},
        {"name": "Stable balance", "description": "Stable state confirms the plan remains in range.", "vectors": [[1, 1, 0, 0]], "metadata": {"expectedOutputCount": 1, "expectedOutputVector": "[0,0,0,1]", "scenario": "stable-balance"}},
        {"name": "Baseline without output", "description": "Initial observation arms the review path without firing.", "vectors": [[1, 0, 1, 1]], "metadata": {"expectedOutputCount": 0, "scenario": "baseline-no-output"}},
    ]
    if domain_e2e:
        sequences.extend(domain_e2e)
    return sequences


def domain_e2e_sequences(index: int) -> list[dict]:
    scenarios = {
        96: ("Domain E2E metabolic mood projection", "CGM and food-mood signals lead to plan adjustment.", "[0,1,0,0]", [[1, 1, 1, 0], [0, 1, 1, 0]]),
        97: ("Domain E2E adolescent sleep school projection", "Sleep and school-function signals lead to monitoring task.", "[0,0,1,0]", [[1, 1, 0, 1], [1, 0, 0, 1]]),
        98: ("Domain E2E medication lifestyle projection", "Side effect and lifestyle interaction signals lead to care-team review.", "[1,0,0,0]", [[1, 0, 1, 1], [0, 0, 1, 1]]),
        99: ("Domain E2E stress connection projection", "Stress and connection signals lead to plan adjustment.", "[0,1,0,0]", [[1, 0, 1, 0], [0, 1, 1, 0]]),
        100: ("Domain E2E command center projection", "Whole-domain stable projection confirms monitored balance.", "[0,0,0,1]", [[1, 1, 1, 1], [1, 1, 0, 0]]),
    }
    if index not in scenarios:
        return []
    name, description, expected, vectors = scenarios[index]
    return [{
        "name": name,
        "description": description,
        "vectors": vectors,
        "metadata": {
            "expectedOutputCount": 1,
            "expectedOutputVector": expected,
            "scenario": slug(name),
            "domainEndToEnd": True,
            "domain": "life-balance",
            "sequenceLength": len(vectors),
        },
    }]


def machine_payload(index: int, specs: list[tuple[str, str, str]]) -> dict:
    base_offset = existing_non_life_balance_max_offset()
    workstream, focus, description = specs[index - 1]
    base = base_offset + (index - 1) * 8
    input_offset = base
    output_offset = base + 4
    upstream_index = upstream_index_for(index)
    upstream_name = None
    upstream_domain = "life-balance"
    upstream_purpose = None

    if upstream_index:
        input_offset = base_offset + (upstream_index - 1) * 8 + 4
        upstream_workstream, upstream_focus, _ = specs[upstream_index - 1]
        upstream_name = f"Life Balance {upstream_workstream} {upstream_focus}"

    input_override = external_input_override(index)
    if input_override:
        upstream_domain, input_offset, _, upstream_purpose = input_override
        upstream_name = f"{upstream_domain} mapped output"

    output_override = external_output_override(index)
    if output_override:
        _, output_offset, _, _ = output_override

    downstream_indices = [target for target in range(1, len(specs) + 1) if upstream_index_for(target) == index]
    downstream_names = [
        f"Life Balance {specs[target - 1][0]} {specs[target - 1][1]}"
        for target in downstream_indices
    ]

    code = f"lbl-{index:03d}"
    agent = AGENTS[(index - 1) % len(AGENTS)]
    actions = [
        f"Route {focus.lower()} concern to licensed care-team review.",
        f"Adjust the life-balance plan for {focus.lower()} using patient goals, barriers, and preferences.",
        f"Create monitoring or follow-up task for {focus.lower()}.",
        f"Continue stable life-balance monitoring for {focus.lower()}.",
    ]

    return {
        "version": "1.0.0",
        "machine": {
            "name": f"Life Balance {workstream} {focus}",
            "description": (
                f"Life-balance machine for {focus.lower()} in the {workstream.lower()} workstream. "
                f"It monitors {description} to support lifestyle-psychiatry workflows spanning psychiatric care, "
                f"nutrition, sleep, movement, stress resilience, monitoring, and projection. Example only; not medical advice."
            ),
            "metadata": {
                "category": "life-balance",
                "domain": f"Life Balance - {workstream}",
                "author": "Reality Engine",
                "workstream": workstream,
                "operationalFocus": focus,
                "focusDescription": description,
                "sourceContext": [
                    "Ann Childers, MD public lifestyle-psychiatry biography emphasizing mainstream psychiatry, nutrition, sleep, general health, CGM, genetics, and temperament testing.",
                    "Lifestyle psychiatry six-pillar framing: nutrition, sleep, movement, stress management, relationships, and harm reduction.",
                ],
                "clinicalSafety": "Example workflow automation only; outputs route to review, plan adjustment, monitoring, or stable status and are not diagnosis or treatment.",
                "upstreamMachine": upstream_name,
                "upstreamDomain": upstream_domain if (upstream_index or input_override) else None,
                "upstreamOutputRegion": f"[{input_offset}:{input_offset + 4}]" if (upstream_index or input_override) else None,
                "upstreamPurpose": upstream_purpose,
                "downstreamMachines": downstream_names,
                "crossDomainInterconnect": bool(input_override or output_override),
                "crossDomainOutputTarget": output_override[0] if output_override else None,
                "crossDomainOutputPurpose": output_override[3] if output_override else None,
                "dispatchableAgent": agent,
                "aiTrigger": f"life-balance-{slug(workstream)}-{slug(focus)}",
                "predictiveProjectionTrigger": f"life-balance-projection-{slug(workstream)}-{slug(focus)}",
                "agentActions": actions,
                "inputSpace": f"4D binary at [{input_offset}:{input_offset + 4}]",
                "outputSpace": (
                    f"4D binary at [{output_offset}:{output_offset + 4}]: "
                    "[1,0,0,0]=CARE_TEAM_REVIEW, [0,1,0,0]=LIFESTYLE_PLAN_ADJUST, "
                    "[0,0,1,0]=MONITORING_TASK, [0,0,0,1]=STABLE_BALANCE"
                ),
                "inputSemantics": [
                    "symptom or functional concern",
                    "lifestyle barrier or preference",
                    "monitoring data quality or readiness",
                    "risk, safety, or care-team urgency",
                ],
                "tags": [
                    "life-balance",
                    "lifestyle-psychiatry",
                    "nutrition",
                    "sleep",
                    "metabolic-health",
                    "cgm",
                    "temperament-testing",
                    "adolescent-psychiatry",
                    "projection",
                    "automation",
                    slug(workstream),
                    slug(focus),
                ],
                "sequenceCount": 4,
                "reuseGuideline": (
                    "Map patient-reported outcomes, sleep logs, nutrition journals, CGM summaries, activity data, "
                    "medication observations, temperament/genetics notes, and care-team review status into the 4D input lane. "
                    "Route outputs to licensed clinician review, plan adjustment, monitoring tasks, or stable follow-up."
                ),
                "domainEndToEndSequenceCount": len(domain_e2e_sequences(index)),
            },
            "arbiterRule": "PASSTHROUGH",
            "perceptualMapping": {
                "input": {"offset": input_offset, "length": 4},
                "output": {"offset": output_offset, "length": 4},
            },
            "sequences": standard_sequences(code, focus, actions),
            "inputSequences": standard_input_sequences(domain_e2e_sequences(index)),
        },
    }


def main() -> None:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    specs = build_specs()
    for index in range(1, len(specs) + 1):
        workstream, focus, _ = specs[index - 1]
        path = OUT_DIR / f"LBL{index:03d}_{slug(workstream)}-{slug(focus)}.json"
        path.write_text(json.dumps(machine_payload(index, specs), indent=2) + "\n")
    print(f"Generated {len(specs)} life-balance machines in {OUT_DIR}")
    print("Domain end-to-end sequences: 5")


if __name__ == "__main__":
    main()
