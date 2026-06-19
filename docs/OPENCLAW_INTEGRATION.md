# OpenClaw Integration Analysis

Scope: `RealityEngine_CPP`, `RealityEngine_Scala`, and `RealityEngine_LSP`. `RealityEngine_AI` is intentionally out of scope. The integration owner for cross-engine orchestration and examples is `RealityEngine_CI`.

## Current State

`RealityEngine_CI` has the most complete OpenClaw bootstrap. `startUniverse.sh --openclaw` detects `../localOpenClawStack`, requires a configured `OPENCLAW_GATEWAY_TOKEN`, normalizes `openclaw/openclaw.json` to local LAN gateway mode, starts the compose stack, and waits for `/healthz` plus Open WebUI readiness. `stopUniverse.sh` also tears the stack down and can restore a previously unloaded native launchd gateway.

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

The current integration is a PE boundary contract, not a full OpenClaw agent runtime loop. ACP dispatch records the handoff and returns immediately. The missing piece is an external adapter that consumes the handoff receipt, activates a real OpenClaw agent/session through the gateway, and posts the finished result to `/api/integrations/completions`.

CPP and LSP require ACP dispatch to reference an existing dispatch ledger record. Scala accepts an arbitrary ACP handoff body. The shared CI e2e now tries to reuse an existing ledger record or create one with a real PE source + push before invoking ACP, while still treating completion-as-source as the portable contract across all three engines.

## Roadmap

1. Standardize environment and registry defaults across all engines.
   - Use `ACP_ENABLED=true`, `ACP_GATEWAY_URL` or `OPENCLAW_GATEWAY_URL`, `ACP_SESSION_KEY`, `ACP_TARGET_AGENT`, and `ACP_COMPLETION_SOURCE_MAPPING_ID=acp-openclaw-completion`.
   - Ensure the CI-generated `config/integrations.json` is passed to each PE through `INTEGRATIONS_CONFIG`.

2. Make dispatch IDs portable.
   - Add a shared trigger fixture that creates a real dispatch record before invoking ACP.
   - Keep the CPP/LSP behavior as the stricter contract: ACP dispatch should update an existing trigger dispatch record.

3. Build the OpenClaw adapter.
   - Input: PE ACP handoff receipt with `gatewayUrl`, `sessionKey`, `targetAgent`, `prompt`, `dispatchId`, `envelopeId`, `correlationId`, and `completionEndpoint`.
   - Work: connect to the local OpenClaw OpenAI-compatible gateway, activate or resume the target agent context through the prompt/envelope, collect the result.
   - Output: `POST /api/integrations/completions` with numeric `values`, `provider: "openclaw"`, `agent`, `sourceMappingId`, `correlationId`, `envelopeId`, and `completionId`.

4. Promote completion source mapping to a strict cross-engine contract.
   - CPP and LSP already support `acp-openclaw-completion`.
   - Scala resolves `sourceMappingId` to `sensorIdTemplate`, region, and TTL for OpenClaw completions.

5. Add live OpenClaw e2e.
   - Phase 1: deterministic hello-world agent fixture, no external gateway dependency.
   - Phase 2: same test with a local OpenClaw gateway running and a real target agent.
   - Phase 3: trigger a real machine terminal event, dispatch to OpenClaw, commit completion, and verify the PE source influences the next PE push.

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
  --api-key "$OPENCLAW_GATEWAY_TOKEN"
```

The adapter consumes the PE ACP handoff receipt returned from `POST /api/integrations/acp/dispatch`, calls the local OpenClaw gateway at `/v1/chat/completions`, extracts a numeric `values` array from the agent response, posts the completion to the PE, and patches `/api/dispatch/records/{dispatchId}` to `running` and then `completed` when that route is available.

For local validation without a live gateway:

```bash
npm run openclaw:adapter -- \
  --handoff-json '{"dispatchId":"dispatch-test","targetAgent":"openclaw","gatewayUrl":"ws://127.0.0.1:18789","completionEndpoint":"/api/integrations/completions","completionSourceMappingId":"acp-openclaw-completion","prompt":"hello"}' \
  --pe-url https://localhost:3004 \
  --dry-run
```

## E2E Testing

Run the PE-boundary OpenClaw e2e against the active PE:

```bash
PE_URL=https://localhost:3004 ./scripts/test-openclaw-integration.sh
```

Run it as part of the broader e2e suite:

```bash
npm run test:e2e
```

The test validates:

- `GET /api/integrations/acp/status`
- `POST /api/integrations/acp/dispatch` after reusing or creating a real dispatch ledger record where supported
- hello-world agent callback to `POST /api/integrations/completions`
- `GET /api/sources` contains `acp.openclaw.hello-world.completion`

For CPP/LSP, a `404` from ACP dispatch is treated as an expected compatibility limit only when no dispatch ledger record could be created. If the fixture finds or creates a dispatch record, ACP dispatch must accept it. The completion callback must always pass.
