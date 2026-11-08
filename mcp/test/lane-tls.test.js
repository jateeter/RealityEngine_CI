// The MCP gateway on the lane's TLS (RealityEngine_CI#730, #668).
//
// A throwaway CA from the openssl CLI in a temp dir; a stub engine that serves
// TLS 1.3 and requires a client certificate, as the engines do on the lane;
// the gateway as its own process with RE_TLS_*. It checks that the gateway's
// listener is held to the profile and requires a certificate, that its calls to
// an engine present its lane certificate, that RE_MCP_INSECURE_TLS cannot turn
// verification off on the lane, and that a plaintext engine URL is refused.
// Everything listens on 127.0.0.1 ephemeral ports and is stopped at the end.

import { test, before, after } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync, spawn } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import * as https from 'node:https';
import * as net from 'node:net';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import * as tls from 'node:tls';
import { fileURLToPath } from 'node:url';

import { isInternalHost } from '../src/lane-tls.js';

const here = dirname(fileURLToPath(import.meta.url));
const gatewayEntry = resolve(here, '../src/http-server.js');
const dir = mkdtempSync(join(tmpdir(), 'mcp-lane-'));
const ossl = (...args) => execFileSync('openssl', args, { cwd: dir, stdio: 'ignore' });
const file = (name) => join(dir, name);

function issue(name, ca = 'ca') {
  ossl('ecparam', '-name', 'secp384r1', '-genkey', '-noout', '-out', `${name}.key`);
  ossl('req', '-new', '-key', `${name}.key`, '-subj', `/CN=${name}`, '-out', `${name}.csr`);
  writeFileSync(file(`${name}.ext`), 'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\n' +
    'extendedKeyUsage=serverAuth,clientAuth\nsubjectAltName=DNS:localhost,IP:127.0.0.1\n');
  ossl('x509', '-req', '-in', `${name}.csr`, '-CA', `${ca}.crt`, '-CAkey', `${ca}.key`, '-CAcreateserial',
    '-sha384', '-days', '2', '-extfile', `${name}.ext`, '-out', `${name}.crt`);
  writeFileSync(file(`${name}.chain`), readFileSync(file(`${name}.crt`)) + readFileSync(file(`${ca}.crt`)));
}

function makeCa(name) {
  ossl('ecparam', '-name', 'secp384r1', '-genkey', '-noout', '-out', `${name}.key`);
  ossl('req', '-x509', '-new', '-key', `${name}.key`, '-sha384', '-days', '2', '-subj', `/CN=${name}`,
    '-addext', 'basicConstraints=critical,CA:TRUE', '-addext', 'keyUsage=critical,keyCertSign,cRLSign', '-out', `${name}.crt`);
}

const listenOn = (server) => new Promise((r) => server.listen(0, '127.0.0.1', () => r(server.address().port)));

function stubEngine(certName, caName = 'ca') {
  const seen = [];
  const server = https.createServer({
    cert: readFileSync(file(`${certName}.chain`)), key: readFileSync(file(`${certName}.key`)),
    ca: readFileSync(file(`${caName}.crt`)), requestCert: true, rejectUnauthorized: true, minVersion: 'TLSv1.3',
  }, (req, res) => {
    seen.push({ path: req.url, client: req.socket.getPeerCertificate()?.subject?.CN });
    req.resume();
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ ok: true, path: req.url }));
  });
  return { server, seen };
}

/** An MCP client over https with a client certificate (fetch cannot present one). */
class LaneMcpClient {
  constructor(port, cert = 'harness') {
    this.port = port; this.cert = cert; this.sessionId = ''; this.nextId = 1;
  }
  post(body) {
    const headers = { accept: 'application/json, text/event-stream', 'content-type': 'application/json' };
    if (this.sessionId) headers['mcp-session-id'] = this.sessionId;
    return new Promise((resolve, reject) => {
      const req = https.request({
        host: '127.0.0.1', port: this.port, path: '/mcp', method: 'POST', headers, servername: 'localhost',
        ca: readFileSync(file('ca.crt')), cert: readFileSync(file(`${this.cert}.chain`)), key: readFileSync(file(`${this.cert}.key`)),
      }, (res) => {
        const sid = res.headers['mcp-session-id'];
        if (sid) this.sessionId = sid;
        let text = '';
        res.on('data', (c) => (text += c));
        res.on('end', () => {
          const line = text.split('\n').find((l) => l.startsWith('data:'));
          try { resolve(JSON.parse(line ? line.slice(5) : text)); } catch { resolve({ raw: text }); }
        });
      });
      req.on('error', reject);
      req.end(JSON.stringify(body));
    });
  }
  async send(method, params) { return this.post({ jsonrpc: '2.0', id: this.nextId++, method, params }); }
  async initialize() {
    await this.send('initialize', { protocolVersion: '2024-11-05', capabilities: {}, clientInfo: { name: 'lane', version: '1' } });
    await this.post({ jsonrpc: '2.0', method: 'notifications/initialized' });
  }
  call(name, args) { return this.send('tools/call', { name, arguments: args }); }
}

function handshake(port, options) {
  return new Promise((resolve) => {
    const s = tls.connect({ host: '127.0.0.1', port, servername: 'localhost', ca: readFileSync(file('ca.crt')), ...options }, () => {
      s.write('GET /healthz HTTP/1.1\r\nHost: localhost\r\n\r\n');
    });
    let got = '';
    s.on('data', (d) => { got += d; s.end(); });
    s.on('close', () => resolve(got.startsWith('HTTP/1.1 200') ? 'ok' : 'refused'));
    s.on('error', () => resolve('refused'));
  });
}

async function startGateway(env) {
  const probe = net.createServer();
  const port = await listenOn(probe);
  await new Promise((r) => probe.close(r));
  const child = spawn(process.execPath, [gatewayEntry], {
    env: {
      ...process.env, RE_REGISTRY_URL: '', RE_MCP_HTTP_PORT: String(port), RE_MCP_HTTP_HOST: '127.0.0.1',
      RE_MCP_TIMEOUT_MS: '5000', RE_TLS_CERT: file('gateway.chain'), RE_TLS_KEY: file('gateway.key'), RE_TLS_CA: file('ca.crt'), ...env,
    },
    stdio: ['ignore', 'ignore', 'pipe'],
  });
  let log = '';
  child.stderr.on('data', (d) => (log += d));
  const deadline = Date.now() + 15000;
  while (Date.now() < deadline && !log.includes('listening on')) await new Promise((r) => setTimeout(r, 100));
  assert.ok(log.includes('listening on https://'), `gateway did not start on https: ${log}`);
  return { child, port, log: () => log };
}

const text = (res) => (res.result?.content ?? []).map((c) => c.text).join('');

let engine;
let other;
let enginePort;
let otherPort;
const gateways = [];

before(async () => {
  makeCa('ca');
  makeCa('rogue');
  issue('engine'); issue('gateway'); issue('harness'); issue('impostor', 'rogue');
  engine = stubEngine('engine');
  enginePort = await listenOn(engine.server);
  other = stubEngine('impostor', 'ca'); // a server whose certificate the lane CA did not issue
  otherPort = await listenOn(other.server);
});

after(() => {
  for (const g of gateways) g.child.kill();
  engine.server.close();
  other.server.close();
  rmSync(dir, { recursive: true, force: true });
});

test('the internal-peer rule', () => {
  for (const h of ['127.0.0.1', 'localhost', '::1', '192.168.1.194', 'host.docker.internal', 'api']) assert.ok(isInternalHost(h), h);
  for (const h of ['8.8.8.8', 'api.openai.com', '2001:db8::1']) assert.ok(!isInternalHost(h), h);
});

test('the listener holds the profile and requires a lane client certificate', async () => {
  const g = await startGateway({ RE_URL: `https://127.0.0.1:${enginePort}`, PE_URL: `https://127.0.0.1:${enginePort}` });
  gateways.push(g);
  const cert = { cert: readFileSync(file('harness.chain')), key: readFileSync(file('harness.key')) };
  assert.equal(await handshake(g.port, cert), 'ok', 'TLS 1.3 with a lane certificate');
  assert.equal(await handshake(g.port, {}), 'refused', 'no client certificate');
  assert.equal(await handshake(g.port, { ...cert, maxVersion: 'TLSv1.2' }), 'refused', 'TLS 1.2');
  assert.equal(await handshake(g.port, { ...cert, ciphers: 'TLS_AES_128_GCM_SHA256' }), 'refused', 'AES-128');
  assert.equal(await handshake(g.port, { ...cert, ecdhCurve: 'prime256v1' }), 'refused', 'P-256');
});

test('a tool call reaches the engine over mTLS with the gateway certificate', async () => {
  const g = gateways[0];
  const client = new LaneMcpClient(g.port);
  await client.initialize();
  const res = await client.call('re.read_machine', { id: 'probe' });
  assert.ok(!res.result?.isError, `tool failed: ${text(res)}`);
  const hit = engine.seen.find((s) => s.path === '/api/machines/probe');
  assert.ok(hit, 'the engine saw the call');
  assert.equal(hit.client, 'gateway', 'the gateway presented its lane certificate');
});

test('RE_MCP_INSECURE_TLS cannot turn verification off on the lane', async () => {
  const g = await startGateway({ RE_MCP_INSECURE_TLS: '1', RE_URL: `https://127.0.0.1:${otherPort}`, PE_URL: `https://127.0.0.1:${otherPort}` });
  gateways.push(g);
  const client = new LaneMcpClient(g.port);
  await client.initialize();
  const res = await client.call('re.read_machine', { id: 'probe' });
  assert.ok(res.result?.isError || res.error, `an engine outside the lane CA was trusted: ${text(res)}`);
  assert.equal(other.seen.length, 0, 'no request reached the untrusted server');
});

// The engine's https URL with its scheme downgraded: the URL the gateway must
// refuse to dial on the lane (no connection is ever made to it).
const downgraded = (port) => Object.assign(new URL(`https://127.0.0.1:${port}`), { protocol: 'http:' }).href.replace(/\/$/, '');

test('a plaintext engine URL is refused on the lane', async () => {
  const g = await startGateway({ RE_URL: downgraded(enginePort), PE_URL: downgraded(enginePort) });
  gateways.push(g);
  const client = new LaneMcpClient(g.port);
  await client.initialize();
  const res = await client.call('re.read_machine', { id: 'probe' });
  assert.ok(res.result?.isError || res.error, 'a plaintext call was made');
  assert.match(text(res) || JSON.stringify(res.error), /refusing plaintext/);
});
