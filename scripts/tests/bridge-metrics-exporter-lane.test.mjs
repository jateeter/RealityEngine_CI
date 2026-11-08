// The AI bridge metrics exporter on the lane's TLS (RealityEngine_CI#730).
//
// A throwaway CA from the openssl CLI; a stub localAI that serves TLS 1.3 and
// requires a lane client certificate, as localai-api does on the lane; the
// exporter as its own process with RE_TLS_*. It checks that /metrics is served
// over TLS 1.3 to a client with a lane certificate and refused without one, and
// that the exporter reaches an mTLS upstream with its own certificate (the
// localAIStack health gauge reads up). Loopback, ephemeral ports, stopped at the end.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync, spawn } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import https from 'node:https';
import net from 'node:net';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const EXPORTER = resolve(dirname(fileURLToPath(import.meta.url)), '..', 'bridge-metrics-exporter.mjs');
const dir = mkdtempSync(join(tmpdir(), 'bridge-lane-'));
const file = (n) => join(dir, n);
const ossl = (...a) => execFileSync('openssl', a, { cwd: dir, stdio: 'ignore' });

function issue(name) {
  ossl('ecparam', '-name', 'secp384r1', '-genkey', '-noout', '-out', `${name}.key`);
  ossl('req', '-new', '-key', `${name}.key`, '-subj', `/CN=${name}`, '-out', `${name}.csr`);
  writeFileSync(file(`${name}.ext`), 'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\n' +
    'extendedKeyUsage=serverAuth,clientAuth\nsubjectAltName=DNS:localhost,IP:127.0.0.1\n');
  ossl('x509', '-req', '-in', `${name}.csr`, '-CA', 'ca.crt', '-CAkey', 'ca.key', '-CAcreateserial', '-sha384',
    '-days', '2', '-extfile', `${name}.ext`, '-out', `${name}.crt`);
  writeFileSync(file(`${name}.chain`), readFileSync(file(`${name}.crt`)) + readFileSync(file('ca.crt')));
}

const tlsOf = (name) => ({ cert: readFileSync(file(`${name}.chain`)), key: readFileSync(file(`${name}.key`)), ca: readFileSync(file('ca.crt')) });
const listenOn = (s) => new Promise((r) => s.listen(0, '127.0.0.1', () => r(s.address().port)));

function get(port, path, client) {
  return new Promise((resolve) => {
    const req = https.request({ host: '127.0.0.1', port, path, servername: 'localhost', ca: readFileSync(file('ca.crt')),
      ...(client ? { cert: readFileSync(file(`${client}.chain`)), key: readFileSync(file(`${client}.key`)) } : {}) }, (res) => {
      let t = '';
      res.on('data', (c) => (t += c));
      res.on('end', () => resolve({ status: res.statusCode, text: t }));
    });
    req.on('error', (e) => resolve({ error: e.code || e.message }));
    req.end();
  });
}

test('the exporter on the lane', async () => {
  ossl('ecparam', '-name', 'secp384r1', '-genkey', '-noout', '-out', 'ca.key');
  ossl('req', '-x509', '-new', '-key', 'ca.key', '-sha384', '-days', '2', '-subj', '/CN=test lane CA',
    '-addext', 'basicConstraints=critical,CA:TRUE', '-addext', 'keyUsage=critical,keyCertSign,cRLSign', '-out', 'ca.crt');
  issue('exporter'); issue('localai'); issue('prometheus');

  const seen = [];
  const localai = https.createServer({ ...tlsOf('localai'), requestCert: true, rejectUnauthorized: true, minVersion: 'TLSv1.3' }, (req, res) => {
    seen.push(req.socket.getPeerCertificate()?.subject?.CN);
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ status: 'ok', services: { api: 'ok' } }));
  });
  const localaiPort = await listenOn(localai);
  const probe = net.createServer();
  const port = await listenOn(probe);
  await new Promise((r) => probe.close(r));

  const child = spawn(process.execPath, [EXPORTER], {
    env: {
      PATH: process.env.PATH, BRIDGE_METRICS_HOST: '127.0.0.1', BRIDGE_METRICS_PORT: String(port), BRIDGE_METRICS_TIMEOUT_MS: '3000',
      RE_TLS_CERT: file('exporter.chain'), RE_TLS_KEY: file('exporter.key'), RE_TLS_CA: file('ca.crt'),
      LOCALAI_API_URL: `https://127.0.0.1:${localaiPort}`,
      // The other upstreams are absent: their gauges read down, which is not under test.
      OPENCLAW_GATEWAY_URL: 'https://127.0.0.1:9', QDRANT_URL: 'https://127.0.0.1:9', OLLAMA_BASE_URL: 'https://127.0.0.1:9',
    },
    stdio: 'ignore',
  });
  try {
    let metrics;
    for (let i = 0; i < 80 && !metrics; i++) {
      const r = await get(port, '/metrics', 'prometheus');
      if (r.status === 200) metrics = r.text;
      else await new Promise((res) => setTimeout(res, 100));
    }
    assert.ok(metrics, 'the exporter never served /metrics over TLS to a lane client');
    const anon = await get(port, '/healthz');
    assert.ok(anon.error, `a client without a certificate was answered: ${JSON.stringify(anon)}`);
    assert.ok(seen.includes('exporter'), 'the exporter did not present its certificate to the mTLS upstream');
    assert.match(metrics, /localai/i, 'no localAIStack sample in the scrape');
  } finally {
    child.kill();
    localai.close();
    rmSync(dir, { recursive: true, force: true });
  }
});
