// scripts/bridge-metrics-exporter.mjs against stub upstreams: no universe.
//
// Two defects it pins, both of which left AI Bridge Operations panels wrong:
//   - the OpenClaw token is read from OPENCLAW_ENV_FILE at scrape time, because
//     startUniverse.sh starts the exporter before it has read the token, and an
//     unauthenticated /v1/models answers 401, so the model count read 0;
//   - localAIStack /health reports pe/re as {status:'ok'} and embedding as
//     {ok:true}; only the string 'ok' counted as up, so three healthy services
//     read down.
import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import { spawn } from 'node:child_process';
import { mkdtemp, writeFile, rm } from 'node:fs/promises';
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

async function scrape(env) {
  const port = await freePort();
  const child = spawn(process.execPath, [EXPORTER], {
    env: { PATH: process.env.PATH, BRIDGE_METRICS_HOST: '127.0.0.1', BRIDGE_METRICS_PORT: String(port), ...env },
    stdio: 'ignore'
  });
  try {
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
});
