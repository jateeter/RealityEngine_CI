// scripts/bridge-metrics-exporter.mjs against stub upstreams: no universe.
//
// Two defects it pins, both of which left AI Bridge Operations panels wrong:
//   - the OpenClaw token is read from OPENCLAW_ENV_FILE at scrape time, because
//     startUniverse.sh starts the exporter before it has read the token, and an
//     unauthenticated /v1/models answers 401, so the model count read 0;
//   - localAIStack /health reports pe/re as {status:'ok'} and embedding as
//     {ok:true}; only the string 'ok' counted as up, so three healthy services
//     read down.
// And the agent-turn series (RealityEngine_CI#785), read from the gateway log
// because the adapter ledger is written by nothing a regression runs.
import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { spawn } from 'node:child_process';
import { appendFile, mkdtemp, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const EXPORTER = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', 'bridge-metrics-exporter.mjs');
const TOKEN = 'stub-token';

function listen(handler) {
  return new Promise((resolve) => {
    const server = http.createServer(handler);
    server.listen(0, '127.0.0.1', () => resolve(server));
  });
}

const url = (server) => `http://127.0.0.1:${server.address().port}`;

function json(res, status, body) {
  res.writeHead(status, { 'content-type': 'application/json' });
  res.end(JSON.stringify(body));
}

async function freePort() {
  const s = await listen(() => {});
  const port = s.address().port;
  await new Promise((r) => s.close(r));
  return port;
}

function startExporter(env) {
  return freePort().then((port) => ({
    port,
    child: spawn(process.execPath, [EXPORTER], {
      env: { PATH: process.env.PATH, BRIDGE_METRICS_HOST: '127.0.0.1', BRIDGE_METRICS_PORT: String(port), ...env },
      stdio: 'ignore'
    })
  }));
}

async function poll(port) {
  for (let i = 0; i < 50; i++) {
    try {
      const r = await fetch(`http://127.0.0.1:${port}/metrics`);
      if (r.ok) return await r.text();
    } catch {
      // not listening yet
    }
    await new Promise((r) => setTimeout(r, 100));
  }
  throw new Error('exporter never answered /metrics');
}

async function scrape(env) {
  const { port, child } = await startExporter(env);
  try {
    return await poll(port);
  } finally {
    child.kill();
  }
}

const sample = (text, name) => {
  const line = text.split('\n').find((l) => l.startsWith(name));
  return line === undefined ? undefined : Number(line.split(' ').pop());
};

test('bridge metrics exporter', async (t) => {
  const openclaw = await listen((req, res) => {
    if (req.url === '/healthz') return json(res, 200, { ok: true });
    if (req.url === '/v1/models') {
      if (req.headers.authorization !== `Bearer ${TOKEN}`) return json(res, 401, { error: 'unauthorized' });
      return json(res, 200, { data: [{ id: 'a' }, { id: 'b' }, { id: 'c' }] });
    }
    json(res, 404, {});
  });
  const localai = await listen((req, res) => {
    if (req.url !== '/health') return json(res, 404, {});
    json(res, 200, {
      services: {
        api: 'ok',
        redis: 'down',
        pe: { status: 'ok', sensor_count: 73 },
        re: { status: 'degraded' },
        embedding: { model: 'm', ok: true },
        qdrant_collections: ['a', 'b'],
        ollama_models: ['x']
      }
    });
  });
  const dir = await mkdtemp(path.join(tmpdir(), 'bridge-metrics-'));
  const envFile = path.join(dir, '.env');
  await writeFile(envFile, `OTHER=1\nOPENCLAW_GATEWAY_TOKEN="${TOKEN}"\n`, { mode: 0o600 });
  const base = {
    OPENCLAW_GATEWAY_URL: url(openclaw),
    LOCALAI_API_URL: url(localai),
    QDRANT_URL: 'http://127.0.0.1:9',
    OLLAMA_BASE_URL: 'http://127.0.0.1:9',
    BRIDGE_METRICS_LEDGER: path.join(dir, 'ledger.jsonl'),
    BRIDGE_METRICS_GATEWAY_LOG: path.join(dir, 'gateway.log'),
    BRIDGE_METRICS_TIMEOUT_MS: '2000'
  };

  t.after(async () => {
    openclaw.close();
    localai.close();
    await rm(dir, { recursive: true, force: true });
  });

  await t.test('reads the OpenClaw token from OPENCLAW_ENV_FILE', async () => {
    const text = await scrape({ ...base, OPENCLAW_ENV_FILE: envFile });
    assert.equal(sample(text, 're_openclaw_gateway_up{'), 1);
    assert.equal(sample(text, 're_openclaw_models_total{'), 3);
  });

  await t.test('an explicit OPENCLAW_GATEWAY_TOKEN still wins', async () => {
    const text = await scrape({ ...base, OPENCLAW_GATEWAY_TOKEN: TOKEN, OPENCLAW_ENV_FILE: path.join(dir, 'absent') });
    assert.equal(sample(text, 're_openclaw_models_total{'), 3);
  });

  await t.test('no token: the gateway is up and the model count is 0', async () => {
    const text = await scrape(base);
    assert.equal(sample(text, 're_openclaw_gateway_up{'), 1);
    assert.equal(sample(text, 're_openclaw_models_total{'), 0);
  });

  await t.test('localAIStack object-form health counts as up', async () => {
    const text = await scrape(base);
    const up = (service) => sample(text, `re_localaistack_service_up{service="${service}"}`);
    assert.equal(up('api'), 1);
    assert.equal(up('redis'), 0);
    assert.equal(up('pe'), 1, 'pe {status:"ok"}');
    assert.equal(up('re'), 0, 're {status:"degraded"}');
    assert.equal(up('embedding'), 1, 'embedding {ok:true}');
    assert.equal(up('qdrant_collections'), undefined, 'lists are not services');
    assert.equal(sample(text, 're_localaistack_ollama_models_total{'), 1);
  });

  await t.test('agent turns and fallback decisions come from the gateway log', async () => {
    const absent = await scrape(base);
    assert.equal(sample(absent, 're_openclaw_gateway_log_readable{'), 0);
    assert.equal(sample(absent, 're_openclaw_agent_turns_total{'), undefined);

    const log = base.BRIDGE_METRICS_GATEWAY_LOG;
    await writeFile(log, [
      '[gateway] startup phase: cli.main.gateway-run-imports starting total=1.0ms',
      '2026-11-14T14:57:07.012-08:00 [agents/agent-command] [agent] run chatcmpl_a ended with stopReason=stop',
      '2026-11-14T14:57:40.420-08:00 [agents/agent-command] [agent] run chatcmpl_b ended with stopReason=stop',
      '2026-11-14T14:58:25.039-08:00 [model-fallback/decision] model fallback decision: decision=candidate_failed requested=ollama/m candidate=ollama/m reason=format next=none detail=ollama/m ended without a visible assistant reply',
      '2026-11-14T14:58:25.260-08:00 [openai-compat] chat completion failed: FailoverError: ollama/m ended without a visible assistant reply',
      '2026-11-14T08:16:50.525-08:00 [model-fallback/decision] model fallback chain stopped: reason=caller_signal_aborted candidate=ollama/m errorName=ClientDisconnectError',
      // a partial last line is not counted
      '2026-11-14T14:59:00.000-08:00 [agents/agent-command] [agent] run chatcmpl_c ended with stopRea'
    ].join('\n'));
    const text = await scrape(base);
    assert.equal(sample(text, 're_openclaw_gateway_log_readable{'), 1);
    assert.equal(sample(text, 're_openclaw_agent_turns_total{outcome="stop",provider="openclaw"}'), 2);
    assert.equal(sample(text, 're_openclaw_agent_turns_total{error="FailoverError",outcome="failed",provider="openclaw"}'), 1);
    assert.equal(sample(text, 're_openclaw_model_fallback_decisions_total{decision="candidate_failed",provider="openclaw",reason="format"}'), 1);
    assert.equal(sample(text, 're_openclaw_model_fallback_decisions_total{decision="chain_stopped",provider="openclaw",reason="caller_signal_aborted"}'), 1);
    assert.equal(sample(text, 're_openclaw_last_agent_turn_timestamp_seconds{'), Date.parse('2026-11-14T14:58:25.260-08:00') / 1000);
  });

  await t.test('the gateway log is read incrementally across scrapes', async () => {
    const log = path.join(dir, 'incremental.log');
    await writeFile(log, '2026-11-14T14:57:07.012-08:00 [agents/agent-command] [agent] run chatcmpl_a ended with stopReason=stop\n2026-11-14T14:57:08.000-08:00 [agents/agent-command] [agent] run chatcmpl_b ended with stop');
    const { port, child } = await startExporter({ ...base, BRIDGE_METRICS_GATEWAY_LOG: log });
    const get = () => poll(port);
    const stop = 're_openclaw_agent_turns_total{outcome="stop",provider="openclaw"}';
    try {
      assert.equal(sample(await get(), stop), 1);
      await appendFile(log, 'Reason=stop\n');
      assert.equal(sample(await get(), stop), 2, 'the completed partial line counts once');
      assert.equal(sample(await get(), stop), 2, 'nothing is counted twice');
    } finally {
      child.kill();
    }
  });
});
