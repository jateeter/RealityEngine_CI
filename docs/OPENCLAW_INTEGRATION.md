# OpenClaw Integration Analysis

Scope: `RealityEngine_CPP`, `RealityEngine_Scala`, and `RealityEngine_LSP`. The deprecated TypeScript prototype is intentionally out of scope. The integration owner for cross-engine orchestration and examples is `RealityEngine_CI`.

## Current State

`RealityEngine_CI` has the most complete OpenClaw bootstrap. `startUniverse.sh --openclaw` detects `../localOpenClawStack`, requires a configured `OPENCLAW_GATEWAY_TOKEN`, and delegates startup to `localOpenClawStack/scripts/start.sh`. That native entrypoint requires immutable image pins, hardens the persisted gateway configuration, starts Compose, synchronizes the configured WebUI administrator, and verifies image identity, health, and authentication. `stopUniverse.sh` tears the stack down and can restore a previously unloaded native launchd gateway.

The normalized integration registry already declares `openclaw-xacp`:

- `kind: "acp"`
- `platform: "OpenClaw"`
- `surface: "xACP"`
- `gatewayUrl: "ws://127.0.0.1:18789"`
- `targetAgent: "openclaw"`
- `completionSourceMappingId: "acp-openclaw-completion"`
- `completionMode: "pe-source-mapping"`

`RealityEngine_CPP` implements the strongest PE-side contract. It loads `kind: "acp"` registry entries, exposes `GET /api/integrations/acp/status`, accepts no-wait handoff receipts at `POST /api/integrations/acp/dispatch`, and commits agent results through `POST /api/integrations/completions`. Completion ingest resolves a source mapping, creates or updates a PE sensor source, and broadcasts `agent.completion.received`.

`RealityEngine_LSP` mirrors the CPP shape closely. It has built-in `agent-completion-risk` and `acp-openclaw-completion` mappings, the same ACP status and dispatch endpoints, and the same completion callback endpoint. Its CLI exposes `pe acp-status`, `pe acp-dispatch`, and `pe completion`.

`RealityEngine_Scala` has a compatibility layer for the same PE boundary. The Scala PE exposes ACP status and dispatch, records accepted handoffs in its dispatch ledger, supports completion ingestion, and resolves `sourceMappingId` to the configured completion sensor mapping.

## Main Gap

The PE contract, one-shot external adapter, deterministic machine fixture, mock-gateway adapter test, completion source assertion, final PE push assertion, and JSON e2e report are implemented. The remaining production gap is durable handoff transport: a runner or queue consumer must receive accepted PE handoffs and invoke the adapter without a human passing JSON between commands. The remaining deployment gap is live regression coverage against a running OpenClaw gateway and target agent.

CPP and LSP require ACP dispatch to reference an existing dispatch ledger record. The shared CI e2e now enforces that stricter contract on every runtime by driving `OpenClawCompletionE2E.json` with its authored dispatch seed. Missing fixture machines, disabled triggers, absent dispatch records, and ACP `404` responses are failures rather than compatibility skips.

## Roadmap

1. Standardize environment and registry defaults across all engines.
   - Use `ACP_ENABLED=true`, `ACP_GATEWAY_URL` or `OPENCLAW_GATEWAY_URL`, `ACP_SESSION_KEY`, `ACP_TARGET_AGENT`, and `ACP_COMPLETION_SOURCE_MAPPING_ID=acp-openclaw-completion`.
   - Ensure the CI-generated `config/integrations.json` is passed to each PE through `INTEGRATIONS_CONFIG`.

2. Make dispatch IDs portable. **Implemented.**
   - `RealityEngine_Machines/machines/OpenClawCompletionE2E.json` creates the real dispatch record before ACP invocation.
   - The strict CI test requires ACP dispatch to update that existing trigger record.

3. Build the OpenClaw adapter. **Implemented.**
   - Input: PE ACP handoff receipt with `gatewayUrl`, `sessionKey`, `targetAgent`, `prompt`, `dispatchId`, `envelopeId`, `correlationId`, and `completionEndpoint`.
   - Work: connect to the local OpenClaw OpenAI-compatible gateway, activate or resume the target agent context through the prompt/envelope, collect the result.
   - Output: `POST /api/integrations/completions` with numeric `values`, `provider: "openclaw"`, `agent`, `sourceMappingId`, `correlationId`, `envelopeId`, and `completionId`.

4. Promote completion source mapping to a strict cross-engine contract.
   - CPP and LSP already support `acp-openclaw-completion`.
   - Scala resolves `sourceMappingId` to `sensorIdTemplate`, region, and TTL for OpenClaw completions.

5. Add live OpenClaw e2e.
   - Phase 1: deterministic hello-world agent fixture, no external gateway dependency. **Implemented.**
   - Phase 1b: real adapter against deterministic mock OpenClaw and PE HTTP services. **Implemented.**
   - Phase 2: trigger a real machine terminal event, dispatch to OpenClaw, commit completion, verify the PE source mapping, verify the next PE push, and write a JSON report. **Implemented in `scripts/test-openclaw-integration.sh`; requires a running PE.**
   - Phase 3: run the same contract with a local OpenClaw gateway and real target agent under live regression.

## Hello World Agent

The deterministic fixture is:

```bash
node scripts/examples/openclaw-hello-agent.mjs \
  --pe-url https://localhost:3004 \
  --agent hello-world \
  --source-mapping-id acp-openclaw-completion \
  --values 1,0,0.95,0
```

It simulates a completed OpenClaw agent by posting:

```json
{
  "provider": "openclaw",
  "agent": "hello-world",
  "sourceMappingId": "acp-openclaw-completion",
  "sensorId": "acp.openclaw.hello-world.completion",
  "values": [1, 0, 0.95, 0],
  "metadata": {
    "fixture": "openclaw-hello-agent",
    "message": "hello world from OpenClaw"
  }
}
```

## OpenClaw Adapter

The external adapter is:

```bash
npm run openclaw:adapter -- \
  --handoff-file handoff.json \
  --pe-url https://localhost:3004 \
  --api-key "$OPENCLAW_GATEWAY_TOKEN" \
  --strict-values \
  --require-dispatch-patch
```

The adapter consumes the PE ACP handoff receipt returned from `POST /api/integrations/acp/dispatch`, calls the local OpenClaw gateway at `/v1/chat/completions`, extracts a numeric `values` array from the agent response, posts the completion to the PE, and patches `/api/dispatch/records/{dispatchId}` to `running` and then `completed` when that route is available.

## Operational Metrics

`startUniverse.sh` starts the CI-owned bridge metrics exporter at:

```bash
http://localhost:7342/metrics
```

Prometheus scrapes that endpoint through the `ai-bridge-operations` job, and Grafana provisions the `AI Bridge Operations` dashboard. The exporter reports OpenClaw gateway health, OpenClaw model inventory, localAIStack service health, Qdrant collection count, Ollama model count, and OpenClaw adapter execution counters.

The OpenClaw adapter appends execution events to `/tmp/realityengine-openclaw-adapter-metrics.jsonl` by default. Set `BRIDGE_METRICS_LEDGER` to use a different ledger path.

For local validation without a live gateway:

```bash
npm run openclaw:adapter -- \
  --handoff-json '{"dispatchId":"dispatch-test","targetAgent":"openclaw","gatewayUrl":"ws://127.0.0.1:18789","completionEndpoint":"/api/integrations/completions","completionSourceMappingId":"acp-openclaw-completion","prompt":"hello"}' \
  --pe-url https://localhost:3004 \
  --dry-run
```

## E2E Testing

Run the adapter unit and deterministic mock-service tests without a RealityEngine stack:

```bash
npm run test:openclaw-adapter
```

Run the PE-boundary OpenClaw e2e against the active PE:

```bash
PE_URL=https://localhost:3004 ./scripts/test-openclaw-integration.sh
```

Run it as part of the broader e2e suite:

```bash
npm run test:e2e
```

The test validates:

- exact ACP status metadata and normalized source mapping
- a unique fixture-driven dispatch record that did not exist before the test
- exact `202 Accepted` no-wait handoff semantics
- dispatch, envelope, and correlation IDs in both receipt and ledger
- correlated hello-world callback to `POST /api/integrations/completions`
- `acp.openclaw.hello-world.completion` at region `4210:4`

The adapter mock e2e additionally proves authenticated gateway request construction, strict extraction of response values, `running -> completed` ledger patches, and the exact PE completion payload. It does not permit fallback values or optional dispatch patching.
