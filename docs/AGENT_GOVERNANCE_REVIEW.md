# Agent governance review: OpenClaw, OWASP ACS and Microsoft AGT

Last reviewed: 2026-11-11

This review is for the owner's decision, which RealityEngine_CI#714 asked for:
"mark this as a deficiency and while testing share the MCP servers. This may
preclude using openclaw, so also review the OWASP ACS and the Agentic Security
Initiative with respect to integrations with ACS compliant frameworks, such as
MS AGT, as an alternative." It records the deficiency, what the sources say
today, how the current design fares against the OWASP Agentic Top 10, and the
options, with a recommendation.

## Owner decision (2026-11-11)

The owner did not take the §5 recommendation:

> I don't think the manager is the right place for the ATG/ACS. The manager is
> responsible for observation and configuration and, although it has a PE, it
> is used as a manual testing and validation. the agent dispatch is currently in
> the right position. I think we will sunset openclaw on v0.0.3, so the solution
> we have in place now, with the known deficiencies, is correct for V0.0.2.

So:

- **No AGT/ACS host in Manager.** Option B as written (§4) is rejected. Manager
  stays observation and configuration; its PE is for manual testing and
  validation.
- **Agent dispatch stays where it is:** Manager's instantiation component
  dispatches per-clone OpenClaw agents (lass ROADMAP phase 8).
- **release-v0.0.2 ships the current design with its recorded deficiencies,**
  including §1 (gateway-wide MCP servers, RealityEngine_CI#714).
- **OpenClaw is to be sunset in v0.0.3.** Where governance (AGT, ACS) and its
  replacement attach is a v0.0.3 question; §2–§4 remain the input to it.

## 1. The deficiency (accepted while testing)

**OpenClaw's MCP servers are gateway-wide.**
- `mcp.servers` is one list for the whole gateway (OpenClaw 2026.10.8,
  `docs/tools/mcp.md`). There is no per-agent server and no per-agent header.
- A frame-scoped `re-mcp` server therefore can't be private to the clone agent
  of one workflow step. Every agent on the gateway sees its tools.
- If it carried a frame's capability (the lifecycle's EdDSA step token), any
  agent could use it.

**Owner decision, 2026-11-11:** while testing, MCP servers are shared. This is
an accepted deficiency, not the design.
- **How it shows:** frame isolation would rest on policy, not construction, in
  any setup that adds `re-mcp` frame tools to OpenClaw.
- **Today:** clone agents have no MCP tools. Their only tool is
  `session_status` (localOpenClawStack#94). The driver reads documents with the
  capability and passes them in the turn (RealityEngine_Manager#338). So the
  deficiency doesn't exist until frame tools are added.
- **What it costs:** an OWASP ACS obligation. Since ACS 0.1.3, a deployment
  whose sessions involve MCP at all MUST implement wrapped MCP
  (`protocols/MCP/*`). Owner decision A8 (2026-10-19, `docs/OWASP_ACS_ROADMAP.md`)
  put MCP wrapping out of scope. Sharing MCP servers brings it back in.

## 2. What the sources say today

### OWASP GenAI Security Project: Agentic Security Initiative
Page: https://genai.owasp.org/initiatives/agentic-security-initiative/, read
2026-11-11. It lists these deliverables:
- **Agent Control Standard (ACS)**,
  https://github.com/GenAI-Security-Project/agent-control-standard;
- **Securing Agentic Applications V2: A Builder & Defender's Guide** (2026-11);
- **A Practical Guide for Secure MCP Server Development** (2026-02);
- **State of Agentic AI Security and Governance 2.01** (2026-06);
- **AIUC-1: Crosswalks OWASP Top 10 For Agentic Applications**;
- **AI Security Solutions Landscape for Agentic AI Q2 2026**.

The page names no vendor framework as compliant or aligned. It does not list
the ASI01–ASI10 risks itself. The IDs below are as AGT's compliance mapping
quotes them.

### OWASP Agent Control Standard (ACS)
`GenAI-Security-Project/agent-control-standard`, Apache-2.0.
- **Release:** **v0.1.4** (2026-10-16). The wire is still v0.1.0, and
  `docs/OWASP_ACS_ROADMAP.md` targets v0.1.0.
- **Model:** an Observed Agent calls a separate **Guardian** over JSON-RPC 2.0,
  through 22 hook methods, and gets one of five dispositions. ACS-Core is
  mandatory; Trace, Inspect, Provenance and Signing are optional profiles.
- **Conformance:** self-declared and unchecked in v0.1.
- **Since v0.1.0:**
  - 0.1.3 made `MODIFY` a SHOULD;
  - 0.1.3 made wrapped MCP mandatory whenever MCP is involved (§1);
  - 0.1.4 broke ACS-Trace (`acs.request_id` and `acs.session.id` are now
    required on every span; the OCSF decision class changed).
- **Known gaps:**
  - #70 (open): the reference Guardian doesn't implement the required HMAC
    signature, so the wire is unauthenticated;
  - #32 (open): Guardian refusals should fail closed;
  - #37 is closed.
- **Implementations:** the reference Guardian (TypeScript on Bun) **wraps
  Microsoft's Agent Governance Toolkit**. Shims exist for Claude Code and
  OpenCode. There is **no OpenClaw shim**: that is this roadmap's own task O2.

### Microsoft Agent Governance Toolkit (AGT)
`microsoft/agent-governance-toolkit`, MIT, v4.1.0 released, v5 on main.
- **Naming trap.** AGT's policy engine is the **Agent Control Specification**
  (`responsibleai/agent-control-spec`, on the `responsibleai/agent-hooks`
  contract), also abbreviated ACS. It is **not** OWASP's Agent Control Standard.
  - It is an in-process, stateless, fail-closed decision runtime (Rust core).
  - It has eight intervention points: startup, input, pre- and post-model,
    pre- and post-tool, output, shutdown.
  - Its verdicts are allow, deny and transform; policies are YAML, OPA or Cedar.
- **Compliance claims (self-assessed):** OWASP Agentic Top 10 (2026), full on 7
  and partial on ASI04, ASI06 and ASI09; NIST AI RMF; EU AI Act; SOC 2; ATF;
  AARM.
- **Frameworks:**
  - native middleware or adapters for Microsoft Agent Framework, Semantic
    Kernel, OpenAI Agents SDK, LangGraph/LangChain, CrewAI, Google ADK,
    LlamaIndex, Haystack, Mastra, Dify and AutoGen;
  - plugins for Claude Code and the Copilot CLI;
  - a framework-neutral host API (`AgentControl.run`, `protectTool`;
    `examples/acs-email-tool`).
- **OpenClaw:**
  - `createOpenClawAdapter` in the Node SDK registers an OpenClaw plugin on
    `session_start`, `before_agent_run`, `llm_input`, `llm_output`,
    `before_tool_call`, `after_tool_call` and `before_agent_finalize`;
  - OpenClaw 2026.10.8 documents those hooks, and `before_tool_call` returning
    `{ block: true }` is terminal;
  - **but** since 2026-06-02 AGT tests the adapter only against an in-memory
    plugin shape. AGT removed the npm package `openclaw@2026.5.27` after
    Microsoft's scanning flagged it as malware;
  - AGT's OpenClaw sidecar guide says OpenClaw "does not natively call the
    governance sidecar". The integration must be explicit.
- **Node SDK:** npm `agent-control-specification` **0.3.1-beta.0** (beta), with
  native binaries for darwin-arm64 and linux, and no published release since
  2026-06-04. Python is the primary distribution
  (`agent-governance-toolkit[full]`).
- **MCP:** an MCP Security Gateway spec (tool poisoning, drift, hidden
  instructions), a `createMcpToolProviderAdapter`, and .NET/Rust MCP packages.

## 3. The current design against the Agentic Top 10

The design is phase 8 as merged: per-clone OpenClaw agents (localOpenClawStack#94,
RealityEngine_Manager#338).

| Risk | Current design | Gap |
|---|---|---|
| ASI01 Agent Goal Hijack | Documents reach the agent as data in one turn. Its output is stored as `return` and never executed. Workflow transitions come from the corpus and people, not the agent. | Document text can steer what the agent *writes*. Nothing scans inputs for injection. |
| ASI02 Tool Misuse | The only tool is `session_status`, and the dangerous groups are denied too. | Adding shared `re-mcp` frame tools (§1) opens this, unless a policy hook binds each call to the agent's frame. |
| ASI03 Identity and Privilege | The capability stays with the driver. The agent has no lifecycle credential, and the lifecycle enforces frame scope. | Gateway-wide MCP plus a capability in config would break this. |
| ASI04 Supply Chain | OpenClaw is installed from npm (global). The models are pinned through Ollama. | The npm channel had a malware-flagged OpenClaw release. Nothing pins or verifies the OpenClaw package. |
| ASI05 Unexpected Code Execution | No exec tool. Sandbox mode `all`. | — |
| ASI06 Memory and Context Poisoning | Agents are per clone and purged after each step (entry, workspace, state, sandboxes). Nothing carries over. | The template agent's own workspace is shared input to every clone. |
| ASI07 Insecure Inter-Agent Communication | No agent-to-agent paths. Session tools are denied. | — |
| ASI08 Cascading Failures | A FIFO queue. A failed turn unloads and writes nothing. The pool limit holds. | No circuit breaker on a failing gateway. |
| ASI09 Human-Agent Trust Exploitation | An agent never approves. Inbox findings never approve. Review is an API resume with Solid-OIDC. | The agent's recommendation is shown to reviewers unlabelled as machine output. |
| ASI10 Rogue Agents | An agent lives one step and is removed with its clone. | No behaviour monitoring. |

## 4. Options

**A. Keep OpenClaw; add AGT's OpenClaw plugin as the policy point.**
- **How:** load AGT's hook plugin into the gateway, with a fail-closed policy.
  `before_tool_call` would allow a frame tool only when its `assetId` is the
  calling agent's frame, and deny everything else. Shared `re-mcp` servers then
  become policy-enforced.
- **For:** smallest change; keeps OpenClaw for the PE ACP dispatch path too
  (roadmap tasks O1–O3).
- **Against:**
  - AGT's adapter is tested only against an in-memory stand-in since June;
  - its Node SDK is a beta not republished since June;
  - isolation stays policy-based;
  - it is AGT's specification, not OWASP ACS conformance;
  - the npm supply-chain exposure of OpenClaw remains.

**B. Workflow steps without OpenClaw: an AGT host in Manager.**
- **How:** Manager's driver calls the universe model (Ollama) directly through
  AGT's framework-neutral host. AGT mediates input, model and output. Frame
  tools are in-process functions bound to that step's capability. There is no
  gateway, no shared MCP server, and no config editing.
- **For:**
  - **isolation by construction**: a step's tools exist only in its own call;
  - removes the §1 deficiency, the load/unload queue, the sandbox purge and the
    OpenClaw supply chain from the workflow path;
  - a step needs no more than this today (one turn, documents in, JSON out).
- **Against:**
  - Node SDK maturity (beta) as for A, or a Python sidecar;
  - loses OpenClaw features steps don't use yet (skills, sessions);
  - replaces the just-merged per-clone agents for workflow steps.

**C. Move agents to an AGT-native framework** (OpenAI Agents SDK, Mastra
(TypeScript), Microsoft Agent Framework or Semantic Kernel).
- **For:** first-class middleware and conformance tests.
- **Against:** a larger change than B, for the same isolation.
- Worth it only if steps grow into multi-tool, multi-turn agents.

**D. OWASP ACS conformance proper.**
- **How:** a Guardian per engine instance (decision A1) on the ACS v0.1 wire,
  using the reference Guardian, which wraps AGT, with an ACS client in front of
  whichever runtime is chosen. With OpenClaw, that client is our O2 hook pack,
  because no OpenClaw shim exists.
- **Note:** this is orthogonal to A–C. It is the certification layer, and its
  wire is unauthenticated until upstream #70 is fixed.

## 5. Recommendation

1. **Workflow steps: option B.** It turns the frame boundary back into a property
   of construction. It needs no shared MCP server, so the §1 deficiency never
   materializes on this path. It also drops the OpenClaw-specific machinery the
   live runs exposed: the clobber guard, the sandbox ACLs, and refused tool-less
   turns.
   - Start with a Node prototype on `agent-control-specification`.
   - Fall back to a Python sidecar if the beta SDK doesn't hold up.
2. **Keep OpenClaw for the PE ACP dispatch path,** and govern it with AGT's
   OpenClaw plugin (option A) as the concrete form of roadmap tasks O2–O3.
   - First re-verify the adapter against the real OpenClaw 2026.10.8.
   - Pin and verify the OpenClaw package (ASI04).
3. **Keep the §1 deficiency recorded** until frame tools exist only behind
   option B, or behind option A's enforced policy.
4. **Revisit `docs/OWASP_ACS_ROADMAP.md`:**
   - retarget it to ACS v0.1.4 (Trace changes);
   - record that wrapped MCP is mandatory if MCP is used (reopens A8);
   - note that the reference Guardian is AGT-based, so option D builds on B or A.

**Owner decision:** see "Owner decision (2026-11-11)" above. This recommendation
is kept as the review's record; it is not the plan.

## 6. Not verified here

- No AGT code was run. Its claims, coverage table and adapter are as documented
  upstream on 2026-11-11.
- "Securing Agentic Applications V2" and the secure-MCP guide were not read in
  full.
- Whether OpenClaw's `before_tool_call` fires for MCP (`bundle-mcp`) tools as it
  does for built-in tools: OpenClaw's docs imply it, but it isn't tested here.
