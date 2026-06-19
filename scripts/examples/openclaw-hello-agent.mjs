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
  openclaw-hello-agent.mjs --pe-url URL [--agent ID] [--values CSV]
    [--source-mapping-id ID] [--correlation-id ID] [--envelope-id ID]
    [--completion-id ID] [--trigger-push] [--dry-run]

This is a deterministic hello-world OpenClaw agent fixture. It simulates the
agent completion callback by posting values to the PE completion endpoint.`);
}

const peUrl = arg('--pe-url', process.env.PE_URL || 'https://localhost:3004').replace(/\/+$/, '');
const agent = arg('--agent', process.env.OPENCLAW_AGENT_ID || 'hello-world');
const provider = arg('--provider', 'openclaw');
const sourceMappingId = arg('--source-mapping-id', process.env.ACP_COMPLETION_SOURCE_MAPPING_ID || 'acp-openclaw-completion');
const values = parseValues(arg('--values', '1,0,0.95,0'));

if (flag('--help') || values.length === 0) {
  usage();
  process.exit(flag('--help') ? 0 : 2);
}

const body = {
  provider,
  agent,
  sourceMappingId,
  sensorId: arg('--sensor-id', `acp.openclaw.${agent.replace(/[^A-Za-z0-9_.-]+/g, '-').toLowerCase()}.completion`),
  values,
  correlationId: arg('--correlation-id', `hello-openclaw-${Date.now()}`),
  envelopeId: arg('--envelope-id', 'hello-openclaw-envelope'),
  completionId: arg('--completion-id', `hello-openclaw-completion-${Date.now()}`),
  name: arg('--name', `agent:openclaw/${agent}/completion`),
  triggerPush: flag('--trigger-push'),
  metadata: {
    fixture: 'openclaw-hello-agent',
    message: 'hello world from OpenClaw'
  }
};

if (flag('--dry-run')) {
  console.log(JSON.stringify({ endpoint: `${peUrl}/api/integrations/completions`, body }, null, 2));
  process.exit(0);
}

const response = await fetch(`${peUrl}/api/integrations/completions`, {
  method: 'POST',
  headers: { 'content-type': 'application/json' },
  body: JSON.stringify(body)
});

const text = await response.text();
let parsed = text;
try {
  parsed = JSON.parse(text);
} catch {
  // Keep non-JSON responses intact for diagnostics.
}

console.log(JSON.stringify({
  ok: response.ok,
  status: response.status,
  endpoint: `${peUrl}/api/integrations/completions`,
  request: body,
  response: parsed
}, null, 2));

if (!response.ok) process.exit(1);
