#!/usr/bin/env node

process.env.NODE_TLS_REJECT_UNAUTHORIZED = process.env.NODE_TLS_REJECT_UNAUTHORIZED || '0';

const args = process.argv.slice(2);

function arg(name, fallback = undefined) {
  const index = args.indexOf(name);
  if (index >= 0 && index + 1 < args.length) return args[index + 1];
  return fallback;
}

function flag(name) {
  return args.includes(name);
}

function parseValues(value) {
  return String(value)
    .split(',')
    .map((part) => Number(part.trim()))
    .filter((value) => Number.isFinite(value));
}

function usage() {
  console.error(`Usage:
  openclaw-acp-adapter.mjs --handoff-file handoff.json --pe-url URL [options]
  openclaw-acp-adapter.mjs --handoff-json JSON --pe-url URL [options]

Options:
  --gateway-url URL       OpenClaw gateway URL. Defaults to handoff.gatewayUrl,
                          OPENCLAW_GATEWAY_URL, ACP_GATEWAY_URL, then
                          http://127.0.0.1:18789.
  --api-key TOKEN         OpenClaw gateway token. Defaults to
                          OPENCLAW_GATEWAY_TOKEN.
  --model MODEL           Gateway model. Defaults to OPENCLAW_MODEL, then
                          openai-codex/gpt-5.5.
  --values CSV            Fallback completion values if the agent response does
                          not contain JSON values.
  --dry-run               Print planned gateway/completion calls only.
  --skip-dispatch-patch   Do not PATCH /api/dispatch/records/:id.

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

function httpGatewayUrl(url) {
  const raw = String(url || 'http://127.0.0.1:18789').replace(/\/+$/, '');
  if (raw.startsWith('ws://')) return `http://${raw.slice(5)}`;
  if (raw.startsWith('wss://')) return `https://${raw.slice(6)}`;
  return raw;
}

function absoluteCompletionEndpoint(peUrl, endpoint) {
  if (/^https?:\/\//i.test(String(endpoint || ''))) return endpoint;
  const base = String(peUrl || '').replace(/\/+$/, '');
  const path = String(endpoint || '/api/integrations/completions');
  return `${base}${path.startsWith('/') ? path : `/${path}`}`;
}

function firstText(response) {
  return response?.choices?.[0]?.message?.content
    ?? response?.choices?.[0]?.text
    ?? response?.output_text
    ?? '';
}

function tryParseJson(text) {
  if (!text || typeof text !== 'string') return undefined;
  try {
    return JSON.parse(text);
  } catch {
    const match = text.match(/\{[\s\S]*\}/);
    if (!match) return undefined;
    try {
      return JSON.parse(match[0]);
    } catch {
      return undefined;
    }
  }
}

function jsonValues(value) {
  if (!value) return undefined;
  if (Array.isArray(value) && value.every((item) => Number.isFinite(Number(item)))) {
    return value.map(Number);
  }
  if (Array.isArray(value?.values)) return jsonValues(value.values);
  if (Array.isArray(value?.completion?.values)) return jsonValues(value.completion.values);
  if (Array.isArray(value?.result?.values)) return jsonValues(value.result.values);
  return undefined;
}

function completionValues(content, fallbackValues) {
  const parsed = typeof content === 'string' ? tryParseJson(content) : content;
  return jsonValues(parsed) || fallbackValues;
}

async function postJson(url, body, headers = {}) {
  const response = await fetch(url, {
    method: 'POST',
    headers: { 'content-type': 'application/json', ...headers },
    body: JSON.stringify(body)
  });
  const text = await response.text();
  let parsed = text;
  try {
    parsed = JSON.parse(text);
  } catch {
    // Preserve non-JSON diagnostics.
  }
  if (!response.ok) {
    const error = new Error(`POST ${url} failed with ${response.status}`);
    error.status = response.status;
    error.response = parsed;
    throw error;
  }
  return { status: response.status, body: parsed };
}

async function patchDispatchRecord(peUrl, dispatchId, body) {
  if (!dispatchId || flag('--skip-dispatch-patch')) return undefined;
  const url = `${String(peUrl).replace(/\/+$/, '')}/api/dispatch/records/${encodeURIComponent(dispatchId)}`;
  const response = await fetch(url, {
    method: 'PATCH',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(body)
  });
  if (response.status === 404) return undefined;
  const text = await response.text();
  let parsed = text;
  try {
    parsed = JSON.parse(text);
  } catch {
    // Keep raw text.
  }
  return { status: response.status, body: parsed };
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
const targetAgent = handoff.targetAgent || handoff.agent || process.env.ACP_TARGET_AGENT || 'openclaw';
const sourceMappingId = handoff.completionSourceMappingId
  || handoff.sourceMappingId
  || process.env.ACP_COMPLETION_SOURCE_MAPPING_ID
  || 'acp-openclaw-completion';
const completionEndpoint = absoluteCompletionEndpoint(peUrl, handoff.completionEndpoint);
const dispatchId = handoff.dispatchId || handoff.id;

const prompt = handoff.prompt
  || 'Handle this RealityEngine trigger envelope and return JSON with numeric values.';
const envelope = handoff.envelope || handoff.body?.envelope || handoff.body || {};
const chatBody = {
  model,
  messages: [
    {
      role: 'system',
      content: 'You are an OpenClaw ACP adapter. Return compact JSON containing a numeric values array for RealityEngine PE completion ingestion.'
    },
    {
      role: 'user',
      content: JSON.stringify({
        targetAgent,
        sessionKey: handoff.sessionKey || null,
        dispatchId: dispatchId || null,
        envelopeId: handoff.envelopeId || null,
        correlationId: handoff.correlationId || null,
        prompt,
        envelope
      })
    }
  ],
  temperature: 0
};

if (flag('--dry-run')) {
  console.log(JSON.stringify({
    gatewayEndpoint: `${gatewayUrl}/v1/chat/completions`,
    completionEndpoint,
    dispatchId,
    chatRequest: chatBody,
    fallbackCompletion: {
      provider: 'openclaw',
      agent: targetAgent,
      sourceMappingId,
      values: fallbackValues
    }
  }, null, 2));
  process.exit(0);
}

await patchDispatchRecord(peUrl, dispatchId, {
  status: 'running',
  adapter: 'openclaw-acp-adapter',
  provider: 'openclaw',
  incrementAttempts: true
});

const gatewayHeaders = apiKey ? { authorization: `Bearer ${apiKey}` } : {};
const gateway = await postJson(`${gatewayUrl}/v1/chat/completions`, chatBody, gatewayHeaders);
const content = firstText(gateway.body);
const values = completionValues(content, fallbackValues);
const completionBody = {
  provider: 'openclaw',
  agent: targetAgent,
  sourceMappingId,
  values,
  dispatchId: dispatchId || null,
  envelopeId: handoff.envelopeId || null,
  correlationId: handoff.correlationId || null,
  completionId: gateway.body?.id || `openclaw-completion-${Date.now()}`,
  metadata: {
    adapter: 'openclaw-acp-adapter',
    model,
    gatewayUrl,
    responseContent: content
  }
};

const completion = await postJson(completionEndpoint, completionBody);
const dispatchPatch = await patchDispatchRecord(peUrl, dispatchId, {
  status: 'completed',
  adapter: 'openclaw-acp-adapter',
  provider: 'openclaw',
  externalRunId: gateway.body?.id || null,
  metadata: {
    completionId: completionBody.completionId,
    sourceMappingId,
    values
  }
});

console.log(JSON.stringify({
  ok: true,
  dispatchId,
  gateway: { status: gateway.status, id: gateway.body?.id || null },
  completion: { status: completion.status, body: completion.body },
  dispatchPatch
}, null, 2));
