#!/usr/bin/env python3
"""
Generate individual/corporate legal-services example machines focused on
provisional patents, trademarks, copyrights, and productization IP workflows.

These are workflow optimization examples, not legal advice.
"""

from __future__ import annotations

import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
OUT_DIR = ROOT / "examples" / "machines"

SOURCE_GUIDANCE = [
    "USPTO provisional patent applications: complete written description, inventor naming, filing fee/cover sheet, 12-month nonprovisional benefit window",
    "USPTO Patent Center: electronic filing and application management for patent submissions",
    "USPTO trademark process and Trademark Center: mark/goods-services review, account identity verification, filing and docket tracking",
    "U.S. Copyright Office eCO registration: application, fee, deposit copy/copies, work-type/form selection",
    "U.S. Copyright Office preregistration: limited-use preregistration for eligible unpublished works likely to face prerelease infringement",
]

WORKSTREAMS = [
    (
        "Provisional Patent Filing",
        [
            ("Invention Intake", "capture invention summary, contributors, dates, product context, and disclosure completeness"),
            ("Inventor Contribution Review", "map each inventor to claimed technical contribution and resolve contributor ambiguity"),
            ("Ownership And Assignment Readiness", "confirm individual or corporate ownership posture, employment obligations, and assignment packet status"),
            ("Public Disclosure Bar Check", "identify publications, offers for sale, demonstrations, releases, and grace-period concerns"),
            ("Prior Art Search Triage", "route preliminary patent/non-patent literature search tasks and novelty risk review"),
            ("Specification Support Builder", "verify written description, enablement details, alternatives, and implementation examples"),
            ("Drawing And Figure Readiness", "track diagrams, flowcharts, screenshots, reference numerals, and explanatory captions"),
            ("Claim Strategy Placeholder", "capture claim themes for later nonprovisional drafting without requiring formal provisional claims"),
            ("Filing Package Assembly", "confirm specification, drawings, cover sheet data, entity status, and fee readiness"),
            ("Twelve Month Conversion Docket", "monitor nonprovisional/PCT/foreign conversion deadline and owner decision gates"),
        ],
    ),
    (
        "Trademark Workflow",
        [
            ("Brand Clearance Intake", "capture candidate marks, products/services, jurisdictions, launch dates, and risk tolerance"),
            ("Distinctiveness Screening", "classify generic, descriptive, suggestive, arbitrary, or fanciful mark risk"),
            ("Knockout Search Review", "review exact and near-match search results across USPTO, web, app stores, and domains"),
            ("Goods Services Classification", "map offerings to classes and acceptable identification language"),
            ("Specimen Evidence Readiness", "verify use evidence for goods, services, screenshots, labels, packaging, and dates"),
            ("Filing Basis Selection", "route use-in-commerce, intent-to-use, foreign, or Madrid basis decision support"),
            ("Owner Identity Verification", "confirm applicant identity, entity name, address, citizenship/state, and signer authority"),
            ("Trademark Center Filing Packet", "prepare mark drawing, owner, classes, basis, specimens, fees, and declarations"),
            ("Office Action Response Docket", "track refusals, evidence, arguments, amendments, deadlines, and escalation"),
            ("Post Registration Maintenance", "monitor declarations, renewals, specimens, ownership changes, and policing tasks"),
        ],
    ),
    (
        "Copyright Workflow",
        [
            ("Work Type Classification", "classify software, text, visual art, audiovisual, sound recording, database, or marketing asset"),
            ("Authorship And Work Made For Hire", "identify authors, employment/contract status, corporate claimant, and transfer evidence"),
            ("Publication Status Review", "distinguish unpublished, published, first-publication date, and publication country"),
            ("Deposit Material Preparation", "prepare required copy/deposit materials and redaction/identifying material where applicable"),
            ("Software Source Code Deposit", "coordinate source/object code deposit choices, trade secret redaction, and version labeling"),
            ("Group Registration Eligibility", "evaluate group unpublished works, photographs, updates, and other group application options"),
            ("Preregistration Eligibility", "route limited preregistration decisions for eligible works facing prerelease infringement risk"),
            ("eCO Application Assembly", "prepare title, authorship, claimant, limitation of claim, rights, correspondence, fee, and deposit"),
            ("Certificate And Record Docket", "track registration status, correspondence, certificate receipt, and public-record metadata"),
            ("Recordation And Transfer", "manage copyright assignments, licenses, security interests, and recordation packet readiness"),
        ],
    ),
    (
        "Productization IP Governance",
        [
            ("Product IP Map", "link product features, patents, trademarks, copyrights, trade secrets, and open-source dependencies"),
            ("Launch Clearance Gate", "coordinate patent disclosure, brand clearance, copyright registration, domain names, and release approvals"),
            ("Contractor Contributor Controls", "verify invention assignment, work-made-for-hire terms, license grants, and confidentiality"),
            ("Open Source Compliance", "detect inbound OSS license obligations, notices, copyleft risk, and source disclosure triggers"),
            ("Trade Secret Boundary", "classify know-how, access controls, publication risk, and patent/trade-secret election points"),
            ("Patent Marking Readiness", "coordinate issued-patent/virtual-marking readiness and product-label implementation"),
            ("Brand Usage Governance", "track trademark use guidelines, approved logo files, attribution, and partner usage"),
            ("Marketing Claims Review", "align patent-pending, trademark, copyright, comparative, and performance claims"),
            ("Licensing Monetization Intake", "route licensing candidates, field-of-use terms, exclusivity, royalties, and enforcement posture"),
            ("Enforcement Watchlist", "monitor competitor products, marketplaces, app stores, domain misuse, and evidence preservation"),
        ],
    ),
    (
        "Portfolio Operations",
        [
            ("Matter Intake Triage", "classify individual/corporate matter type, urgency, conflicts, and responsible attorney/agent"),
            ("Conflict Check Gate", "track party names, affiliates, inventors, assignees, licensees, and adverse-party screening"),
            ("Engagement Scope Control", "capture representation limits, fee model, jurisdiction, and approval state"),
            ("Docket Integrity Monitor", "track due dates, statutory deadlines, office actions, renewals, and responsible owner"),
            ("Document Version Control", "govern drafts, exhibits, signed forms, figures, claims, specimens, and filing receipts"),
            ("Client Decision Packet", "assemble decision options, cost, deadline, risk, and recommended next action"),
            ("Fee Budget Forecast", "forecast filing fees, attorney effort, search costs, maintenance fees, and renewal costs"),
            ("Foreign Rights Coordination", "coordinate Paris/PCT/Madrid/local counsel deadlines and foreign filing decisions"),
            ("Evidence Preservation Vault", "store dated invention records, use evidence, deposits, assignments, and correspondence"),
            ("Portfolio Executive Summary", "summarize patent, trademark, copyright, productization, risk, and next-action health"),
        ],
    ),
    (
        "AI Assisted Legal Operations",
        [
            ("Disclosure Completeness Scorer", "score invention or copyright disclosure completeness and route missing facts"),
            ("Prior Art Search Agent Dispatcher", "dispatch AI-assisted search tasks and human review queues"),
            ("Drafting Checklist Agent", "generate drafting checklists for specification, figures, mark IDs, specimens, and deposits"),
            ("Risk Memo Synthesizer", "summarize risk signals, deadlines, missing artifacts, and recommended attorney review"),
            ("Deadline Projection Agent", "project 30/60/90/365-day deadlines and escalation windows"),
            ("Client Intake Chat Guardrail", "separate educational intake from legal advice and route attorney review"),
            ("Artifact Classification Agent", "classify product artifacts into patent, trademark, copyright, trade-secret, or OSS buckets"),
            ("Filing Portal Readiness Agent", "validate portal account, identity verification, forms, attachments, and fee readiness"),
            ("Office Action Triage Agent", "classify USPTO/Copyright Office correspondence and draft response task plans"),
            ("Portfolio Learning Loop", "use outcomes to improve intake prompts, checklists, search scope, and docket templates"),
        ],
    ),
    (
        "Individual Creator Services",
        [
            ("Solo Inventor Intake", "capture individual inventor goals, disclosure status, budget, and ownership expectations"),
            ("Startup Founder IP Split", "map founder contributions, company assignment, investor diligence, and cap-table implications"),
            ("Creator Copyright Bundle", "coordinate registration for software, visual assets, text, videos, photos, and marketing copy"),
            ("Small Business Brand Launch", "coordinate trademark, domain, social handles, logo files, and product category readiness"),
            ("Independent Contractor Cleanup", "identify missing IP assignments, license gaps, and authorship ambiguity"),
            ("Prototype Disclosure Guard", "assess demo, beta, conference, crowdfunding, and sales disclosure risk"),
            ("Low Budget Filing Plan", "sequence search, provisional, trademark, copyright, and deferrable work by budget priority"),
            ("Founder Evidence Timeline", "preserve conception, reduction to practice, first use, publication, and release evidence"),
            ("Creator Licensing Intake", "route content licensing, brand licensing, software licensing, and attribution obligations"),
            ("Individual Portfolio Dashboard", "summarize individual matters, deadlines, missing documents, and next approvals"),
        ],
    ),
    (
        "Corporate Legal Services",
        [
            ("Corporate IP Intake Board", "route invention disclosures, brand requests, copyright assets, and product launches"),
            ("R And D Harvesting Cadence", "schedule invention mining sessions, technical reviews, and filing decisions"),
            ("M And A IP Diligence", "collect patents, applications, marks, copyrights, assignments, OSS, and encumbrances"),
            ("Vendor IP Risk Review", "review supplier deliverables, indemnities, ownership, escrow, and license scope"),
            ("Employee Innovation Program", "track invention submissions, rewards, review committees, and assignment confirmation"),
            ("Product Counsel Launch Review", "coordinate privacy, regulatory, IP, marketing, support, and sales readiness"),
            ("Portfolio Cost Optimization", "rank filings, continuations, renewals, and maintenance decisions by business value"),
            ("Standards Open Innovation Review", "route standards participation, defensive publication, open innovation, and patent pledge issues"),
            ("Global Brand Governance", "coordinate house marks, product marks, local counsel, watch notices, and renewal budgets"),
            ("Board Level IP Report", "summarize portfolio value, risks, filings, enforcement, product coverage, and budget forecast"),
        ],
    ),
    (
        "Filing And Portal Operations",
        [
            ("USPTO Patent Center Readiness", "verify account, customer number, entity status, PDF compatibility, forms, and payment path"),
            ("Provisional Cover Sheet Gate", "validate title, inventors, correspondence, entity status, and attorney docket data"),
            ("Fee Payment Verification", "route fee authorization, entity status, receipt capture, and accounting reconciliation"),
            ("Filing Receipt Audit", "review filing date, application number, inventors, title, and document list"),
            ("Trademark Account Identity Gate", "confirm USPTO.gov account, multifactor authentication, identity verification, and signer status"),
            ("Trademark Drawing Asset Gate", "validate standard character or design mark drawing, color claim, and image file readiness"),
            ("Copyright eCO Account Gate", "verify eCO account access, application type, deposit upload path, and fee authorization"),
            ("Copyright Deposit File Gate", "validate file format, separate-work rules, redactions, and upload completeness"),
            ("Portal Outage Contingency", "monitor portal status, planned maintenance, backup filing routes, and deadline risk"),
            ("Receipt And Certificate Archive", "archive filing receipts, serial numbers, certificates, correspondence, and docket updates"),
        ],
    ),
    (
        "Commercialization And Enforcement",
        [
            ("Freedom To Operate Intake", "route product features, competitor patents, claim charts, and attorney review"),
            ("Competitive Watch Search", "monitor patent publications, marks, marketplace listings, and copyright-copy signals"),
            ("Notice Letter Evidence Gate", "assemble ownership, registrations, specimens, claim charts, screenshots, and chain of title"),
            ("DMCA Takedown Workflow", "route copyright ownership, registration/preregistration, URL evidence, and platform requirements"),
            ("Trademark Marketplace Takedown", "assemble mark registration/use evidence, counterfeit indicators, and platform forms"),
            ("Patent Licensing Outreach", "prepare target lists, claim coverage, valuation model, and communication approvals"),
            ("Joint Development IP Gate", "coordinate background IP, foreground IP, publication review, and filing responsibilities"),
            ("Product Release IP Checklist", "verify patent-pending status, brand use, copyright notices, OSS notices, and evidence capture"),
            ("Post Launch IP Review", "collect sales/use evidence, new features, customer materials, and next filing candidates"),
            ("IP Metrics Optimization", "track cycle time, filing conversion, abandonment, renewal ROI, and product coverage"),
        ],
    ),
]

AGENTS = [
    "patent_workflow_agent",
    "trademark_workflow_agent",
    "copyright_workflow_agent",
    "product_counsel_agent",
    "docketing_agent",
    "filing_portal_agent",
    "ip_portfolio_agent",
    "legal_ops_agent",
    "evidence_preservation_agent",
    "attorney_review_agent",
]


def slug(value: str) -> str:
    result = "".join(ch.lower() if ch.isalnum() else "-" for ch in value).strip("-")
    while "--" in result:
        result = result.replace("--", "-")
    return result


def vector_elements(values: list[int]) -> list[dict[str, float]]:
    return [{"value": value, "threshold": 0.5} for value in values]


def machine_payload(index: int, workstream: str, focus: str, description: str) -> dict:
    base = 1341 + (index - 1) * 8
    input_offset = base
    output_offset = base + 4
    code = f"lsx-{index:03d}"
    agent = AGENTS[(index - 1) % len(AGENTS)]
    urgent_action = f"Route {focus.lower()} to attorney review for deadline, ownership, or rights-risk triage."
    optimize_action = f"Dispatch {agent} to optimize the next workstep for {focus.lower()}."
    docket_action = f"Create or update docket/checklist tasks for {focus.lower()}."
    ready_action = f"Mark {focus.lower()} ready for the next controlled workflow step."

    return {
        "version": "1.0.0",
        "machine": {
            "name": f"Legal Services {workstream} {focus}",
            "description": (
                f"Legal services workflow machine for {focus.lower()} in the {workstream.lower()} workstream. "
                f"It monitors {description}. This is an operational workflow example for individual and corporate "
                f"legal services, not legal advice."
            ),
            "metadata": {
                "category": "legal-services",
                "domain": f"Legal Services - {workstream}",
                "author": "Reality Engine",
                "workstream": workstream,
                "operationalFocus": focus,
                "focusDescription": description,
                "sourceGuidance": SOURCE_GUIDANCE,
                "legalDisclaimer": "Workflow automation example only; attorney review is required for legal advice, filing decisions, and jurisdiction-specific analysis.",
                "dispatchableAgent": agent,
                "aiTrigger": f"legal-services-{slug(workstream)}-{slug(focus)}",
                "agentActions": [urgent_action, optimize_action, docket_action, ready_action],
                "inputSpace": f"4D binary at [{input_offset}:{input_offset + 4}]",
                "outputSpace": (
                    f"4D binary at [{output_offset}:{output_offset + 4}]: "
                    "[1,0,0,0]=ATTORNEY_REVIEW, [0,1,0,0]=OPTIMIZE_WORKSTEP, "
                    "[0,0,1,0]=DOCKET_ACTION, [0,0,0,1]=READY_FOR_NEXT_STEP"
                ),
                "inputSemantics": [
                    "facts complete",
                    "rights/ownership clear",
                    "deadline or filing pressure",
                    "commercialization readiness",
                ],
                "tags": [
                    "legal-services",
                    "intellectual-property",
                    "provisional-patent",
                    "trademark",
                    "copyright",
                    "productization",
                    slug(workstream),
                    slug(focus),
                ],
                "sequenceCount": 4,
                "reuseGuideline": (
                    "Map legal intake, docket, evidence, filing-portal, and AI review signals into the 4D input lane. "
                    "Route outputs to attorney review, workstep optimization, docket updates, or product launch gates."
                ),
            },
            "arbiterRule": "PASSTHROUGH",
            "perceptualMapping": {
                "input": {"offset": input_offset, "length": 4},
                "output": {"offset": output_offset, "length": 4},
            },
            "sequences": [
                {
                    "id": f"{code}-attorney-review",
                    "name": f"{focus}: INCOMPLETE_OR_RISK -> ATTORNEY_REVIEW",
                    "metadata": {"description": "Escalates when facts, rights, or deadline pressure require attorney review.", "output": "[1,0,0,0]"},
                    "vectors": [
                        {"id": f"{code}-risk-watch", "elements": vector_elements([1, 0, 1, 0]), "isInitial": True, "nextVectorIds": [f"{code}-review-needed"]},
                        {"id": f"{code}-review-needed", "elements": vector_elements([0, 0, 1, 0]), "isInitial": False, "outputVectors": [{"id": f"{code}-review-output", "vector": [1, 0, 0, 0], "metadata": {"action": urgent_action}}]},
                    ],
                },
                {
                    "id": f"{code}-optimize",
                    "name": f"{focus}: OPTIMIZATION_WINDOW -> OPTIMIZE_WORKSTEP",
                    "metadata": {"description": "Fires when the matter can proceed more efficiently through AI-assisted workflow optimization.", "output": "[0,1,0,0]"},
                    "vectors": [
                        {"id": f"{code}-optimization", "elements": vector_elements([1, 1, 0, 0]), "isInitial": True, "outputVectors": [{"id": f"{code}-optimize-output", "vector": [0, 1, 0, 0], "metadata": {"action": optimize_action}}]},
                    ],
                },
                {
                    "id": f"{code}-docket",
                    "name": f"{focus}: DOCKET_PRESSURE -> DOCKET_ACTION",
                    "metadata": {"description": "Creates a docket update or checklist task for the next controlled step.", "output": "[0,0,1,0]"},
                    "vectors": [
                        {"id": f"{code}-docket-needed", "elements": vector_elements([1, 0, 1, 1]), "isInitial": True, "outputVectors": [{"id": f"{code}-docket-output", "vector": [0, 0, 1, 0], "metadata": {"action": docket_action}}]},
                    ],
                },
                {
                    "id": f"{code}-ready",
                    "name": f"{focus}: READY -> READY_FOR_NEXT_STEP",
                    "metadata": {"description": "Signals that facts, rights posture, timing, and commercialization readiness are aligned.", "output": "[0,0,0,1]"},
                    "vectors": [
                        {"id": f"{code}-ready-state", "elements": vector_elements([1, 1, 0, 1]), "isInitial": True, "outputVectors": [{"id": f"{code}-ready-output", "vector": [0, 0, 0, 1], "metadata": {"action": ready_action}}]},
                    ],
                },
            ],
            "inputSequences": [
                {"name": "Attorney review escalation", "description": "Risk or missing rights facts require attorney review.", "vectors": [[1, 0, 1, 0], [0, 0, 1, 0]], "metadata": {"expectedOutputCount": 1, "expectedOutputVector": "[1,0,0,0]", "scenario": "attorney-review"}},
                {"name": "Optimize workstep", "description": "Matter is suitable for AI-assisted workflow optimization.", "vectors": [[1, 1, 0, 0]], "metadata": {"expectedOutputCount": 1, "expectedOutputVector": "[0,1,0,0]", "scenario": "optimize-workstep"}},
                {"name": "Docket action", "description": "Deadline or filing pressure requires docket/checklist action.", "vectors": [[1, 0, 1, 1]], "metadata": {"expectedOutputCount": 1, "expectedOutputVector": "[0,0,1,0]", "scenario": "docket-action"}},
                {"name": "Ready for next step", "description": "Matter is ready to advance to the next controlled step.", "vectors": [[1, 1, 0, 1]], "metadata": {"expectedOutputCount": 1, "expectedOutputVector": "[0,0,0,1]", "scenario": "ready-for-next-step"}},
                {"name": "Baseline without output", "description": "Initial risk-watch state arms escalation without completing the sequence.", "vectors": [[1, 0, 1, 0]], "metadata": {"expectedOutputCount": 0, "scenario": "baseline-no-output"}},
            ],
        },
    }


def main() -> None:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    specs = []
    for workstream, items in WORKSTREAMS:
        for focus, description in items:
            specs.append((workstream, focus, description))
    for index, (workstream, focus, description) in enumerate(specs, start=1):
        path = OUT_DIR / f"LSX{index:03d}_{slug(workstream)}-{slug(focus)}.json"
        path.write_text(json.dumps(machine_payload(index, workstream, focus, description), indent=2) + "\n")
    print(f"Generated {len(specs)} legal-services IP machines in {OUT_DIR}")


if __name__ == "__main__":
    main()
