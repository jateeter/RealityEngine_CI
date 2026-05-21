# Legal Services IP Machines

The `LSX001`-`LSX100` machines add an example legal-services domain for
individual and corporate intellectual-property workflows. They focus on
provisional patent filing, trademark filing and maintenance, copyright
registration, productization gates, portfolio operations, portal readiness,
commercialization, and enforcement preparation.

These machines are operational workflow examples. They are not legal advice and
do not replace attorney review, patent-agent review, jurisdiction-specific
analysis, or filing-owner decisions.

## Source Guidance

The examples are aligned to public workflow concepts from official U.S. filing
resources:

- USPTO provisional patent application guidance, including written disclosure,
  filing requirements, and the 12-month nonprovisional benefit window.
- USPTO Patent Center as the electronic filing and application management route
  for patent submissions.
- USPTO trademark application and Trademark Center process guidance for owner
  identity, mark/goods-services review, basis, specimens, filing, and docketing.
- U.S. Copyright Office registration guidance for application, fee, deposit
  materials, work type, authorship, claimant, and public record handling.
- U.S. Copyright Office preregistration guidance for limited eligible
  unpublished works at risk of prerelease infringement.

## Contract

Each `LSX` machine uses:

- Category: `legal-services`
- Domain: `Legal Services - <workstream>`
- Input: 4D binary lane
  - facts complete
  - rights/ownership clear
  - deadline or filing pressure
  - commercialization readiness
- Output: 4D binary lane
  - `[1,0,0,0]` = `ATTORNEY_REVIEW`
  - `[0,1,0,0]` = `OPTIMIZE_WORKSTEP`
  - `[0,0,1,0]` = `DOCKET_ACTION`
  - `[0,0,0,1]` = `READY_FOR_NEXT_STEP`

Every machine includes e2e `inputSequences` for attorney-review escalation,
AI-assisted workstep optimization, docket/checklist action, ready-to-advance
signaling, and a no-output baseline.

## Workstreams

The 100 machines are organized as 10 machines in each workstream:

- Provisional Patent Filing
- Trademark Workflow
- Copyright Workflow
- Productization IP Governance
- Portfolio Operations
- AI Assisted Legal Operations
- Individual Creator Services
- Corporate Legal Services
- Filing And Portal Operations
- Commercialization And Enforcement

## AI Triggers And Dispatch

Each machine carries:

- `aiTrigger`: a stable trigger key scoped by workstream and focus area.
- `dispatchableAgent`: one of the legal, docketing, filing, portfolio, product
  counsel, or evidence-preservation agents.
- `agentActions`: four action templates corresponding to attorney review,
  workstep optimization, docket action, and ready-for-next-step outcomes.

Use these fields to connect the machines to AI dispatchable agents without
hard-coding domain behavior into the engine runtime.

## Reuse Guidelines

Use `LSX` machines as connective tissue for IP workflows:

- Feed intake, docket, evidence, portal, product-release, and portfolio state
  into the 4D input lane.
- Route `ATTORNEY_REVIEW` outputs to attorney or patent-agent review queues.
- Route `OPTIMIZE_WORKSTEP` outputs to AI planning agents that can prepare
  checklists, collect missing artifacts, or summarize next actions.
- Route `DOCKET_ACTION` outputs to matter-management, calendar, reminder, or
  task systems.
- Route `READY_FOR_NEXT_STEP` outputs to controlled gates such as filing packet
  assembly, launch clearance, registration monitoring, or portfolio reporting.

For productized services, pair the legal-services outputs with product,
marketing, engineering, sales, and customer-success workflow machines so patent,
trademark, copyright, open-source, contractor, and trade-secret signals are
visible before launch.

## Regeneration

Run:

```bash
python3 scripts/generate_legal_services_ip_machines.py
node scripts/repack_machine_connection_matrix.mjs
```

The repack step keeps the global example-machine vector matrix compact after
adding, removing, or regenerating machines.
