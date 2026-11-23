# OWASP Agent Control Standard (ACS): summary

Summary of ACS v0.1.0 as of 2026-10-19, the source `docs/OWASP_ACS_ROADMAP.md` works from. Upstream has moved since (v0.1.3 and v0.1.4; see `docs/AGENT_GOVERNANCE_REVIEW.md` §2). Roadmap task B1 re-pins.

## 1. Purpose
To make AI agents **instrumentable, traceable, and inspectable**, with hard runtime controls rather than soft guardrails. It's an open standard that works across frameworks, licensed Apache 2.0 for code and schemas and CC BY-SA 4.0 for docs.

## 2. Model
- **Observed Agent:** the LLM-backed system being governed.
- **Guardian Agent:** a separate process that gets a hook call before the agent acts and returns a decision.
- **Wire:** JSON-RPC 2.0, starting with a `handshake/hello`. Every request carries `acs_version`, `request_id`, `timestamp`, metadata (agent, session, and turn IDs), a payload, and an optional signature. 44 published JSON Schemas define it.

## 3. Hooks (22 methods)
- **Lifecycle:** sessionStart, agentTrigger, turnStart, turnEnd, sessionEnd
- **Messages:** userMessage, agentResponse
- **Knowledge and memory:** knowledgeRetrieval, memoryContextRetrieval, memoryStore
- **Tools:** toolCallRequest (the central enforcement point) and toolCallResult (checked before the result reaches the agent's context)
- **Compaction:** preCompact, postCompact (keeps provenance from being laundered when context is summarized)
- **Delegation:** subagentStart, subagentStop
- **Skills:** skillRegister, skillLoad, skillUnload (bound to an approved digest)
- **Inspect:** agbom/snapshot, agbom/changed
- **Other:** system/ping (liveness, never audited) and protocols/MCP/* (wrapped MCP traffic). A2A wrapping is reserved for v0.2.

Any action that leaves the agent's reasoning context, including shell commands, file I/O, and network calls, **must** fire toolCallRequest.

## 4. Decisions
There are five dispositions: **allow, deny, modify, ask** (route to a human, agent, or service approver), and **defer**. Not every hook can take all five; the after-the-fact hooks are audit-only.

## 5. Guardian layers
A **deterministic layer** (OPA/Rego, Cedar, or similar) always runs first. An LLM layer is optional: it never sees the policy source, and its answer has to pass back through the deterministic layer. A deterministic-only deployment is fully conformant.

## 6. Provenance and audit
Arguments can carry provenance (origin and what they were derived from). Each session keeps a hash-chained audit log, rooted at sessionStart and sealed at sessionEnd, with replay protection. The baseline calls for HMAC-SHA256 envelope signatures.

## 7. Pillars and conformance
- **ACS-Core (mandatory):** Instrument hooks, the wire format, and the audit chain
- **Optional profiles, declared at the handshake:** Trace (OpenTelemetry spans, OCSF events), Inspect (an agent bill of materials, or AgBOM, in CycloneDX, SPDX, or SWID), Inspect-Dynamic, Provenance, and Signing
- In v0.1.0, conformance is **self-declared and unchecked**

## 8. Out of scope by design
The policy engine, signature algorithm, transport, authentication mechanism, and policy content.

## 9. Where it stands
- The reference Guardian is TypeScript on Bun, wrapping Microsoft's Agent Governance Toolkit, with shims for Claude Code and OpenCode.
- Only toolCallRequest and toolCallResult are evaluated live.
- Known gaps: the wire is unauthenticated (issue #70), and it **fails open** by default (issues #32 and #37).
- The project's one committed goal is a runnable Guardian, benchmarked against Microsoft's toolkit, in outside evaluators' hands within 90 days of the September 10, 2026 kickoff.

## 10. Deferred to v0.2.0
Async and composition, streaming, batching semantics, recursive ask, quorum, multi-tenant isolation, the Cedar binding, AgBOM federation, and negative conformance vectors.

## 11. How work gets in
Issues are opened through forms, and maintainers triage them; only issues marked `status:accepted` enter the backlog. Spec changes start as a GitHub Discussion. PRs go against the `integration` branch, and every commit needs a human DCO sign-off. AI-assisted commits are fine. The contribution valued most right now is a conformance report showing where ACS breaks in practice.
