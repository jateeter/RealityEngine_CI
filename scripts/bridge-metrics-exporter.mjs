#!/usr/bin/env node

import http from 'node:http';
import { readFile } from 'node:fs/promises';

const port = Number(process.env.BRIDGE_METRICS_PORT || '7342');
const host = process.env.BRIDGE_METRICS_HOST || '127.0.0.1';
const timeoutMs = Number(process.env.BRIDGE_METRICS_TIMEOUT_MS || '2500');
const ledgerPath = process.env.BRIDGE_METRICS_LEDGER || '/tmp/realityengine-openclaw-adapter-metrics.jsonl';

const openclawUrl = trim(process.env.OPENCLAW_GATEWAY_URL || process.env.ACP_GATEWAY_URL || 'http://127.0.0.1:18789');
const openclawToken = process.env.OPENCLAW_GATEWAY_TOKEN || '';
const localAiUrl = trim(process.env.LOCALAI_API_URL || process.env.LOCAL_AI_BASE_URL || 'http://127.0.0.1:4000');
const qdrantUrl = trim(process.env.QDRANT_URL || 'http://127.0.0.1:4333');
const ollamaUrl = trim(process.env.OLLAMA_BASE_URL || 'http://127.0.0.1:11434');

function trim(value) {
  return String(value || '').replace(/\/+$/, '').replace(/^ws:\/\//, 'http://').replace(/^wss:\/\//, 'https://');
}

function esc(value) {
  return String(value ?? '').replace(/\\/g, '\\\\').replace(/"/g, '\\"').replace(/\n/g, ' ');
}

function labels(items) {
  const parts = Object.entries(items)
    .filter(([, value]) => value !== undefined && value !== null && value !== '')
    .sort(([a], [b]) => a.localeCompare(b))
    .map(([key, value]) => `${key}="${esc(value)}"`);
  return parts.length ? `{${parts.join(',')}}` : '';
}

async function fetchJson(url, options = {}) {
  const headers = options.headers || {};
  const response = await fetch(url, {
    headers,
    signal: AbortSignal.timeout(timeoutMs)
  });
  const text = await response.text();
  let body = text;
  try {
    body = JSON.parse(text);
  } catch {
    // Keep text payloads for health endpoints.
  }
  if (!response.ok) {
    const error = new Error(`${url} returned ${response.status}`);
    error.status = response.status;
    error.body = body;
    throw error;
  }
  return body;
}

async function readLedger() {
  let text = '';
  try {
    text = await readFile(ledgerPath, 'utf8');
  } catch {
    return [];
  }
  return text.split(/\r?\n/)
    .filter(Boolean)
    .map((line) => {
      try {
        return JSON.parse(line);
      } catch {
        return undefined;
      }
    })
    .filter(Boolean);
}

function summarizeLedger(events) {
  const runs = new Map();
  for (const event of events) {
    if (event.type !== 'openclaw_adapter_run') continue;
    const key = JSON.stringify({
      status: event.status || 'unknown',
      provider: event.provider || 'openclaw',
      agent: event.agent || 'unknown',
      model: event.model || 'unknown'
    });
    const prev = runs.get(key) || { count: 0, durationMs: 0 };
    prev.count += 1;
    prev.durationMs += Number(event.durationMs || 0);
    runs.set(key, prev);
  }
  return { runs };
}

function emit(lines, name, help, type) {
  lines.push(`# HELP ${name} ${help}`);
  lines.push(`# TYPE ${name} ${type}`);
}

async function collectMetrics() {
  const started = Date.now();
  const lines = [];

  emit(lines, 're_ai_bridge_target_info', 'Configured AI bridge endpoint metadata.', 'gauge');
  lines.push(`re_ai_bridge_target_info${labels({ provider: 'openclaw', endpoint: openclawUrl })} 1`);
  lines.push(`re_ai_bridge_target_info${labels({ provider: 'localaistack', endpoint: localAiUrl })} 1`);
  lines.push(`re_ai_bridge_target_info${labels({ provider: 'qdrant', endpoint: qdrantUrl })} 1`);
  lines.push(`re_ai_bridge_target_info${labels({ provider: 'ollama', endpoint: ollamaUrl })} 1`);

  emit(lines, 're_openclaw_gateway_up', 'OpenClaw gateway health probe result.', 'gauge');
  let openclawUp = 0;
  try {
    await fetchJson(`${openclawUrl}/healthz`);
    openclawUp = 1;
  } catch {
    openclawUp = 0;
  }
  lines.push(`re_openclaw_gateway_up${labels({ provider: 'openclaw' })} ${openclawUp}`);

  emit(lines, 're_openclaw_models_total', 'Models visible through the OpenClaw OpenAI-compatible gateway.', 'gauge');
  let openclawModels = 0;
  try {
    const headers = openclawToken ? { authorization: `Bearer ${openclawToken}` } : {};
    const data = await fetchJson(`${openclawUrl}/v1/models`, { headers });
    openclawModels = Array.isArray(data?.data) ? data.data.length : 0;
  } catch {
    openclawModels = 0;
  }
  lines.push(`re_openclaw_models_total${labels({ provider: 'openclaw' })} ${openclawModels}`);

  emit(lines, 're_localaistack_service_up', 'localAIStack service health from /health.', 'gauge');
  try {
    const health = await fetchJson(`${localAiUrl}/health`);
    const services = health?.services && typeof health.services === 'object' ? health.services : {};
    for (const [service, value] of Object.entries(services)) {
      if (Array.isArray(value)) continue;
      lines.push(`re_localaistack_service_up${labels({ service })} ${value === 'ok' ? 1 : 0}`);
    }
    lines.push(`re_localaistack_api_up${labels({ service: 'api' })} 1`);
    if (Array.isArray(services.ollama_models)) {
      lines.push('# HELP re_localaistack_ollama_models_total Ollama models reported through localAIStack health.');
      lines.push('# TYPE re_localaistack_ollama_models_total gauge');
      lines.push(`re_localaistack_ollama_models_total${labels({ service: 'ollama' })} ${services.ollama_models.length}`);
    }
  } catch {
    lines.push(`re_localaistack_api_up${labels({ service: 'api' })} 0`);
  }

  emit(lines, 're_qdrant_collections_total', 'Qdrant collection count from /collections.', 'gauge');
  try {
    const data = await fetchJson(`${qdrantUrl}/collections`);
    const collections = data?.result?.collections;
    lines.push(`re_qdrant_collections_total${labels({ service: 'qdrant' })} ${Array.isArray(collections) ? collections.length : 0}`);
  } catch {
    lines.push(`re_qdrant_collections_total${labels({ service: 'qdrant' })} 0`);
  }

  emit(lines, 're_ollama_models_total', 'Native Ollama model count from /api/tags.', 'gauge');
  try {
    const data = await fetchJson(`${ollamaUrl}/api/tags`);
    lines.push(`re_ollama_models_total${labels({ service: 'ollama' })} ${Array.isArray(data?.models) ? data.models.length : 0}`);
  } catch {
    lines.push(`re_ollama_models_total${labels({ service: 'ollama' })} 0`);
  }

  const { runs } = summarizeLedger(await readLedger());
  emit(lines, 're_openclaw_adapter_runs_total', 'OpenClaw ACP adapter executions by result status.', 'counter');
  emit(lines, 're_openclaw_adapter_duration_seconds_count', 'OpenClaw ACP adapter duration count.', 'counter');
  emit(lines, 're_openclaw_adapter_duration_seconds_sum', 'OpenClaw ACP adapter duration sum in seconds.', 'counter');
  for (const [key, value] of runs.entries()) {
    const item = JSON.parse(key);
    lines.push(`re_openclaw_adapter_runs_total${labels(item)} ${value.count}`);
    lines.push(`re_openclaw_adapter_duration_seconds_count${labels(item)} ${value.count}`);
    lines.push(`re_openclaw_adapter_duration_seconds_sum${labels(item)} ${(value.durationMs / 1000).toFixed(6)}`);
  }

  emit(lines, 're_ai_bridge_metrics_scrape_duration_seconds', 'AI bridge metrics exporter scrape duration.', 'gauge');
  lines.push(`re_ai_bridge_metrics_scrape_duration_seconds ${(Date.now() - started) / 1000}`);
  lines.push('');
  return lines.join('\n');
}

const server = http.createServer(async (request, response) => {
  if (request.url === '/healthz') {
    response.writeHead(200, { 'content-type': 'application/json' });
    response.end(JSON.stringify({ ok: true, service: 're-ai-bridge-metrics' }));
    return;
  }
  if (request.url !== '/metrics') {
    response.writeHead(404, { 'content-type': 'application/json' });
    response.end(JSON.stringify({ error: 'not_found' }));
    return;
  }
  try {
    response.writeHead(200, { 'content-type': 'text/plain; version=0.0.4; charset=utf-8' });
    response.end(await collectMetrics());
  } catch (error) {
    response.writeHead(500, { 'content-type': 'text/plain; charset=utf-8' });
    response.end(`# bridge metrics collection failed: ${error.message}\n`);
  }
});

server.listen(port, host, () => {
  console.log(`AI bridge metrics exporter listening on http://${host}:${port}/metrics`);
});
