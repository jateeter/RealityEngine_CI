#!/usr/bin/env node

import { open, readFile } from 'node:fs/promises';
import { homedir } from 'node:os';
import path from 'node:path';

// The lane's TLS (RealityEngine_CI#730): with RE_TLS_CERT set the exporter
// serves /metrics over TLS 1.3 requiring a lane client certificate (Prometheus
// presents its own), and its calls to the gateway, localAI, Qdrant and the
// Ollama front present this certificate and trust the lane CA alone. The same
// module the MCP gateway uses; off the lane both are what they were.
import { createListener, laneFetch } from '../mcp/src/lane-tls.js';

const port = Number(process.env.BRIDGE_METRICS_PORT || '7342');
const host = process.env.BRIDGE_METRICS_HOST || '127.0.0.1';
// localAIStack /health waits on its engine fan-out and can take ~10s; a
// shorter timeout reported a healthy API as down.
const timeoutMs = Number(process.env.BRIDGE_METRICS_TIMEOUT_MS || '10000');
const ledgerPath = process.env.BRIDGE_METRICS_LEDGER || '/tmp/realityengine-openclaw-adapter-metrics.jsonl';

// The native OpenClaw gateway's log (RealityEngine_CI#785): the only record of
// the agent turns a regression runs (the asset workflow's clone agents, PE ACP
// completions). The ledger above is written only by
// scripts/openclaw-acp-adapter.mjs, which no regression runs.
const gatewayLogPath = process.env.BRIDGE_METRICS_GATEWAY_LOG
  || path.join(process.env.OPENCLAW_HOME || path.join(homedir(), '.realityengine', 'openclaw'), 'logs', 'gateway.log');

const openclawUrl = trim(process.env.OPENCLAW_GATEWAY_URL || process.env.ACP_GATEWAY_URL || 'http://127.0.0.1:18789');
const openclawToken = process.env.OPENCLAW_GATEWAY_TOKEN || '';
// startUniverse.sh starts this exporter before it reads the OpenClaw token, so
// it passes the env file instead and the token is read at scrape time. That
// also keeps the token out of this process's environment and follows a rotated
// token without a restart. Without a token /v1/models answers 401 and the model
// count reads 0.
const openclawEnvFile = process.env.OPENCLAW_ENV_FILE || '';
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
  const response = await laneFetch(url, {
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

async function resolveOpenclawToken() {
  if (openclawToken || !openclawEnvFile) return openclawToken;
  let text = '';
  try {
    text = await readFile(openclawEnvFile, 'utf8');
  } catch {
    return '';
  }
  const line = text.split(/\r?\n/).filter((l) => l.startsWith('OPENCLAW_GATEWAY_TOKEN=')).pop();
  return line ? line.slice('OPENCLAW_GATEWAY_TOKEN='.length).trim().replace(/^(['"])(.*)\1$/, '$2') : '';
}

// localAIStack /health reports a service as the string 'ok', or as an object
// carrying `status: 'ok'` (pe, re) or `ok: true` (embedding). Reading only the
// string reported three healthy services as down.
function serviceUp(value) {
  if (value === 'ok') return true;
  if (value && typeof value === 'object') return value.status === 'ok' || value.ok === true;
  return false;
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

// Agent turns and model fallback decisions, read incrementally from the
// gateway log. The counts live in this process and only grow: a rotated or
// truncated log is read again from its start, and on start the whole log is
// read once, so a counter's rate is the activity and its value is the total
// since the log began. A partial last line waits for the next scrape.
const gatewayLog = { offset: 0, ino: undefined, rest: '', turns: new Map(), fallbacks: new Map(), lastTurn: 0 };
const TURN = /\[agent\] run \S+ ended with stopReason=(\w+)/;
const FAILED = /\[openai-compat\] chat completion failed: (\w+)/;
const FALLBACK = /\[model-fallback\/decision\] model fallback (?:decision: decision=(\w+)|chain (stopped):).*? reason=(\w+)/;

function bump(map, key) {
  map.set(key, (map.get(key) || 0) + 1);
}

function stampOf(line) {
  const t = Date.parse(line.slice(0, 29));
  return Number.isFinite(t) ? t / 1000 : 0;
}

function readGatewayLine(state, line) {
  let m = TURN.exec(line);
  if (m) {
    bump(state.turns, JSON.stringify({ outcome: m[1], error: '' }));
    state.lastTurn = Math.max(state.lastTurn, stampOf(line));
    return;
  }
  if ((m = FAILED.exec(line))) {
    bump(state.turns, JSON.stringify({ outcome: 'failed', error: m[1] }));
    state.lastTurn = Math.max(state.lastTurn, stampOf(line));
    return;
  }
  if ((m = FALLBACK.exec(line))) {
    bump(state.fallbacks, JSON.stringify({ decision: m[1] || 'chain_stopped', reason: m[3] }));
  }
}

async function readGatewayLog(state = gatewayLog) {
  let handle;
  try {
    handle = await open(gatewayLogPath, 'r');
  } catch {
    return false;
  }
  try {
    const st = await handle.stat();
    if (st.ino !== state.ino || st.size < state.offset) {
      state.ino = st.ino;
      state.offset = 0;
      state.rest = '';
    }
    while (state.offset < st.size) {
      const length = Math.min(1 << 20, st.size - state.offset);
      const buf = Buffer.alloc(length);
      const { bytesRead } = await handle.read(buf, 0, length, state.offset);
      if (!bytesRead) break;
      state.offset += bytesRead;
      const lines = (state.rest + buf.toString('utf8', 0, bytesRead)).split('\n');
      state.rest = lines.pop();
      for (const line of lines) readGatewayLine(state, line);
    }
    return true;
  } finally {
    await handle.close();
  }
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

  // Probe every target at once: sequential probes summed their timeouts.
  const settle = (promise) => promise.then((value) => ({ value }), (error) => ({ error }));
  const token = await resolveOpenclawToken();
  const openclawHeaders = token ? { authorization: `Bearer ${token}` } : {};
  const [openclawHealth, openclawModelList, localAiHealth, qdrantCollections, ollamaTags, ollamaVersion, ollamaPs, ledger, gatewayLogRead] = await Promise.all([
    settle(fetchJson(`${openclawUrl}/healthz`)),
    settle(fetchJson(`${openclawUrl}/v1/models`, { headers: openclawHeaders })),
    settle(fetchJson(`${localAiUrl}/health`)),
    settle(fetchJson(`${qdrantUrl}/collections`)),
    settle(fetchJson(`${ollamaUrl}/api/tags`)),
    settle(fetchJson(`${ollamaUrl}/api/version`)),
    settle(fetchJson(`${ollamaUrl}/api/ps`)),
    readLedger(),
    readGatewayLog()
  ]);

  emit(lines, 're_openclaw_gateway_up', 'OpenClaw gateway health probe result.', 'gauge');
  const openclawUp = openclawHealth.error ? 0 : 1;
  lines.push(`re_openclaw_gateway_up${labels({ provider: 'openclaw' })} ${openclawUp}`);

  emit(lines, 're_openclaw_models_total', 'Models visible through the OpenClaw OpenAI-compatible gateway.', 'gauge');
  const openclawModels = Array.isArray(openclawModelList.value?.data) ? openclawModelList.value.data.length : 0;
  lines.push(`re_openclaw_models_total${labels({ provider: 'openclaw' })} ${openclawModels}`);

  emit(lines, 're_localaistack_service_up', 'localAIStack service health from /health.', 'gauge');
  if (!localAiHealth.error) {
    const health = localAiHealth.value;
    const services = health?.services && typeof health.services === 'object' ? health.services : {};
    for (const [service, value] of Object.entries(services)) {
      if (Array.isArray(value)) continue;
      lines.push(`re_localaistack_service_up${labels({ service })} ${serviceUp(value) ? 1 : 0}`);
    }
    lines.push(`re_localaistack_api_up${labels({ service: 'api' })} 1`);
    if (Array.isArray(services.ollama_models)) {
      lines.push('# HELP re_localaistack_ollama_models_total Ollama models reported through localAIStack health.');
      lines.push('# TYPE re_localaistack_ollama_models_total gauge');
      lines.push(`re_localaistack_ollama_models_total${labels({ service: 'ollama' })} ${services.ollama_models.length}`);
    }
  } else {
    lines.push(`re_localaistack_api_up${labels({ service: 'api' })} 0`);
  }

  emit(lines, 're_qdrant_collections_total', 'Qdrant collection count from /collections.', 'gauge');
  const collections = qdrantCollections.value?.result?.collections;
  lines.push(`re_qdrant_collections_total${labels({ service: 'qdrant' })} ${Array.isArray(collections) ? collections.length : 0}`);

  // Ollama serves no Prometheus metrics of its own, so its up target is this
  // probe (RealityEngine_CI#592 §6). The runner per loaded model is the MLX
  // report of §2: Ollama names it "mlx" or the fallback ("llamacpp").
  emit(lines, 're_ollama_up', 'Native Ollama answers /api/version.', 'gauge');
  lines.push(`re_ollama_up${labels({ service: 'ollama' })} ${ollamaVersion.error ? 0 : 1}`);
  emit(lines, 're_ollama_version_info', 'Native Ollama version.', 'gauge');
  if (ollamaVersion.value?.version) {
    lines.push(`re_ollama_version_info${labels({ service: 'ollama', version: ollamaVersion.value.version })} 1`);
  }
  emit(lines, 're_ollama_model_loaded_info', 'A model Ollama has loaded, with the runner it runs on (mlx or the fallback).', 'gauge');
  for (const m of Array.isArray(ollamaPs.value?.models) ? ollamaPs.value.models : []) {
    lines.push(`re_ollama_model_loaded_info${labels({
      service: 'ollama', model: m.name, runner: m.runner || 'unknown',
      format: m.details?.format, context: m.context_length
    })} 1`);
  }

  emit(lines, 're_ollama_models_total', 'Native Ollama model count from /api/tags.', 'gauge');
  const models = ollamaTags.value?.models;
  lines.push(`re_ollama_models_total${labels({ service: 'ollama' })} ${Array.isArray(models) ? models.length : 0}`);

  const { runs } = summarizeLedger(ledger);
  emit(lines, 're_openclaw_adapter_runs_total', 'OpenClaw ACP adapter executions by result status.', 'counter');
  emit(lines, 're_openclaw_adapter_duration_seconds_count', 'OpenClaw ACP adapter duration count.', 'counter');
  emit(lines, 're_openclaw_adapter_duration_seconds_sum', 'OpenClaw ACP adapter duration sum in seconds.', 'counter');
  for (const [key, value] of runs.entries()) {
    const item = JSON.parse(key);
    lines.push(`re_openclaw_adapter_runs_total${labels(item)} ${value.count}`);
    lines.push(`re_openclaw_adapter_duration_seconds_count${labels(item)} ${value.count}`);
    lines.push(`re_openclaw_adapter_duration_seconds_sum${labels(item)} ${(value.durationMs / 1000).toFixed(6)}`);
  }

  emit(lines, 're_openclaw_gateway_log_readable', 'The exporter can read the OpenClaw gateway log the agent-turn series come from.', 'gauge');
  lines.push(`re_openclaw_gateway_log_readable${labels({ provider: 'openclaw' })} ${gatewayLogRead ? 1 : 0}`);
  emit(lines, 're_openclaw_agent_turns_total', 'OpenClaw agent turns from the gateway log, by stop reason, or failed with the error name.', 'counter');
  for (const [key, count] of gatewayLog.turns.entries()) {
    lines.push(`re_openclaw_agent_turns_total${labels({ provider: 'openclaw', ...JSON.parse(key) })} ${count}`);
  }
  emit(lines, 're_openclaw_model_fallback_decisions_total', 'OpenClaw model fallback decisions from the gateway log, by decision and reason.', 'counter');
  for (const [key, count] of gatewayLog.fallbacks.entries()) {
    lines.push(`re_openclaw_model_fallback_decisions_total${labels({ provider: 'openclaw', ...JSON.parse(key) })} ${count}`);
  }
  emit(lines, 're_openclaw_last_agent_turn_timestamp_seconds', 'Time of the last agent turn the gateway log records.', 'gauge');
  lines.push(`re_openclaw_last_agent_turn_timestamp_seconds${labels({ provider: 'openclaw' })} ${gatewayLog.lastTurn}`);

  emit(lines, 're_ai_bridge_metrics_scrape_duration_seconds', 'AI bridge metrics exporter scrape duration.', 'gauge');
  lines.push(`re_ai_bridge_metrics_scrape_duration_seconds ${(Date.now() - started) / 1000}`);
  lines.push('');
  return lines.join('\n');
}

const { server, scheme, note } = createListener(async (request, response) => {
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
  console.log(`AI bridge metrics exporter listening on ${scheme}://${host}:${port}/metrics${note}`);
});
