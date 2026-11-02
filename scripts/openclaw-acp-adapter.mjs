#!/usr/bin/env node

process.env.NODE_TLS_REJECT_UNAUTHORIZED = process.env.NODE_TLS_REJECT_UNAUTHORIZED || '0';

import {
  absoluteCompletionEndpoint,
  buildChatBody,
  actorRoute,
  executeOpenClawAdapter,
  httpGatewayUrl,
  loadAgentSpec,
  parseValues,
  resolveSynthetic
} from './lib/openclaw-adapter.mjs';

const args = process.argv.slice(2);

function arg(name, fallback = undefined) {
  const index = args.indexOf(name);
  if (index >= 0 && index + 1 < args.length) return args[index + 1];
  return fallback;
}

function flag(name) {
  return args.includes(name);
}

function usage() {
  console.error(`Usage:
  openclaw-acp-adapter.mjs --handoff-file handoff.json --pe-url URL [options]
  openclaw-acp-adapter.mjs --handoff-json JSON --pe-url URL [options]

Options:
  --gateway-url URL          OpenClaw gateway URL. Defaults to handoff.gatewayUrl,
                             OPENCLAW_GATEWAY_URL, ACP_GATEWAY_URL, then
                             http://127.0.0.1:18789.
  --api-key TOKEN            OpenClaw gateway token. Defaults to
                             OPENCLAW_GATEWAY_TOKEN.
  --model MODEL              Gateway model. Defaults to OPENCLAW_MODEL, then
                             openai-codex/gpt-5.5.
  --values CSV               Fallback completion values for non-strict runs.
  --strict-values            Require a numeric 4-value array from OpenClaw.
  --require-dispatch-patch   Fail if the dispatch ledger cannot be patched.
  --timeout-ms MS            Per-request timeout. Defaults to 30000.
  --dry-run                  Print planned gateway/completion calls only.
  --skip-dispatch-patch      Do not PATCH /api/dispatch/records/:id.
  --agents-dir DIR           Generated agent specs (one directory per domain).
                             Defaults to OPENCLAW_AGENTS_DIR, then the sibling
                             localOpenClawStack/machine-behaviors/agents.
  --synthetic-mode MODE      off | fallback | always. Overrides the agent's
                             syntheticBody (OC_SYNTHETIC_MODE overrides both).
  --synthetic-strategy NAME  seeded-random | round-robin | sequence-walk.
  --step N                   Turn counter for the algorithmic strategies.

When the handoff's target agent has a generated spec, the adapter acts as that
agent's output-actor: the completion carries the agent's own write-back (sensorId,
region, TTL) instead of a registered source mapping, and the agent's synthetic
body answers when its model does not (mode fallback) or instead of it (always).
Synthetic completions carry metadata.synthetic=true. Without a spec, the fixed
--values fallback and the registered mapping apply as before.

The adapter consumes the PE ACP handoff receipt returned by
POST /api/integrations/acp/dispatch, calls the local OpenClaw OpenAI-compatible
gateway, then posts normalized numeric values to /api/integrations/completions.`);
}

async function readStdin() {
  const chunks = [];
  for await (const chunk of process.stdin) chunks.push(chunk);
  return Buffer.concat(chunks).toString('utf8');
}

async function loadHandoff() {
  const jsonArg = arg('--handoff-json');
  if (jsonArg) return JSON.parse(jsonArg);

  const file = arg('--handoff-file');
  if (file) {
    const fs = await import('node:fs/promises');
    return JSON.parse(await fs.readFile(file, 'utf8'));
  }

  const stdin = (await readStdin()).trim();
  if (stdin) return JSON.parse(stdin);

  throw new Error('missing --handoff-file, --handoff-json, or JSON on stdin');
}

if (flag('--help')) {
  usage();
  process.exit(0);
}

const handoff = await loadHandoff();
const peUrl = arg('--pe-url', process.env.PE_URL);
if (!peUrl) {
  usage();
  throw new Error('missing --pe-url or PE_URL');
}

const gatewayUrl = httpGatewayUrl(arg(
  '--gateway-url',
  handoff.gatewayUrl || process.env.OPENCLAW_GATEWAY_URL || process.env.ACP_GATEWAY_URL
));
const apiKey = arg('--api-key', process.env.OPENCLAW_GATEWAY_TOKEN || process.env.OPENAI_API_KEY || '');
const model = arg('--model', process.env.OPENCLAW_MODEL || 'openai-codex/gpt-5.5');
const fallbackValues = parseValues(arg('--values', '1,0,0.95,0'));
const timeoutMs = Number(arg('--timeout-ms', process.env.OPENCLAW_ADAPTER_TIMEOUT_MS || '30000'));
if (!Number.isFinite(timeoutMs) || timeoutMs <= 0) throw new Error('--timeout-ms must be a positive number');
const targetAgent = handoff.targetAgent || handoff.agent || process.env.ACP_TARGET_AGENT || 'openclaw';
const sourceMappingId = handoff.completionSourceMappingId
  || handoff.sourceMappingId
  || process.env.ACP_COMPLETION_SOURCE_MAPPING_ID
  || 'acp-openclaw-completion';
const normalizedHandoff = { ...handoff, targetAgent, completionSourceMappingId: sourceMappingId };
const metricsLedger = process.env.BRIDGE_METRICS_LEDGER || '/tmp/realityengine-openclaw-adapter-metrics.jsonl';

const path = await import('node:path');
const { fileURLToPath } = await import('node:url');
const siblingAgents = path.resolve(path.dirname(fileURLToPath(import.meta.url)),
  '..', '..', 'localOpenClawStack', 'machine-behaviors', 'agents');
const agentsDir = arg('--agents-dir', process.env.OPENCLAW_AGENTS_DIR || siblingAgents);
const agentSpec = await loadAgentSpec(agentsDir, targetAgent);
const stepArg = arg('--step');
const step = stepArg === undefined ? undefined : Number(stepArg);
if (step !== undefined && !Number.isInteger(step)) throw new Error('--step must be an integer');
const synthetic = agentSpec
  ? resolveSynthetic(agentSpec, {
      syntheticBody: {
        ...(arg('--synthetic-mode') ? { mode: arg('--synthetic-mode') } : {}),
        ...(arg('--synthetic-strategy') ? { strategy: arg('--synthetic-strategy') } : {})
      }
    })
  : undefined;

async function appendMetricsEvent(event) {
  try {
    const fs = await import('node:fs/promises');
    await fs.appendFile(metricsLedger, `${JSON.stringify({
      type: 'openclaw_adapter_run',
      timestamp: new Date().toISOString(),
      provider: 'openclaw',
      agent: targetAgent,
      model,
      dispatchId: handoff.dispatchId || handoff.id || null,
      envelopeId: handoff.envelopeId || null,
      correlationId: handoff.correlationId || null,
      ...event
    })}\n`);
  } catch {
    // Metrics must never change adapter behavior.
  }
}

if (flag('--dry-run')) {
  console.log(JSON.stringify({
    gatewayEndpoint: `${gatewayUrl}/v1/chat/completions`,
    completionEndpoint: absoluteCompletionEndpoint(peUrl, handoff.completionEndpoint),
    dispatchId: handoff.dispatchId || handoff.id,
    chatRequest: buildChatBody(normalizedHandoff, targetAgent, model),
    actor: agentSpec
      ? { agentId: agentSpec.agentId, route: actorRoute(agentSpec), synthetic,
          ordinality: agentSpec.syntheticBody?.ordinality ?? 0 }
      : null,
    fallbackCompletion: agentSpec ? null : {
      provider: 'openclaw',
      agent: targetAgent,
      sourceMappingId,
      values: fallbackValues
    }
  }, null, 2));
  process.exit(0);
}

const startedAt = Date.now();
try {
  const result = await executeOpenClawAdapter({
    handoff: normalizedHandoff,
    peUrl,
    gatewayUrl,
    apiKey,
    model,
    fallbackValues,
    requireResponseValues: flag('--strict-values'),
    requireDispatchPatch: flag('--require-dispatch-patch'),
    skipDispatchPatch: flag('--skip-dispatch-patch'),
    timeoutMs,
    agentSpec,
    synthetic,
    ...(step !== undefined ? { step } : {})
  });

  await appendMetricsEvent({
    status: 'ok',
    durationMs: Date.now() - startedAt,
    completionStatus: result.completion?.status || null,
    gatewayStatus: result.gateway?.status || null,
    synthetic: Boolean(result.synthetic)
  });
  console.log(JSON.stringify(result, null, 2));
  process.exit(0);
} catch (error) {
  await appendMetricsEvent({
    status: 'error',
    durationMs: Date.now() - startedAt,
    error: error.message
  });
  throw error;
}
