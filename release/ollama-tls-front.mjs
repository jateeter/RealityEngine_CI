#!/usr/bin/env node
// Ollama's TLS front for a release install (owner, 2026-11-12; RealityEngine_CI#729).
//
// Ollama serves no TLS. On the development lanes localAIStack's
// scripts/ollama_tls_front.py fronts it; a release Mac has no Python with
// OpenSSL 3.5, but it has the Node the suite installs for OpenClaw, whose
// OpenSSL does. This is the same front in Node: TLS 1.3 only with the
// transport profile's suites and groups, a client certificate from the install
// CA required (checked against its CRL), and a byte relay to Ollama on the
// Mac's loopback. That last hop is the owner-accepted ollama-front-to-ollama
// deficiency; the front refuses any upstream that is not a loopback address.
//
// Run by the realityengine CLI as the LaunchAgent org.realityengine.ollama-tls-front.
//
//   node ollama-tls-front.mjs [--bind 127.0.0.1] [--port 11443] [--upstream 127.0.0.1:11434]
//
// Certificates from the runtime contract: RE_TLS_CERT, RE_TLS_KEY, RE_TLS_CA,
// RE_TLS_CRL (all required; the front has no plaintext mode). The profile comes
// from RE_TLS_SUITES and RE_TLS_GROUPS, which the CLI sets from the install's
// transport profile.
import fs from 'node:fs';
import net from 'node:net';
import tls from 'node:tls';

const arg = (name, fallback) => {
  const i = process.argv.indexOf(`--${name}`);
  return i > 0 && process.argv[i + 1] ? process.argv[i + 1] : fallback;
};
const bind = arg('bind', '127.0.0.1');
const port = Number(arg('port', '11443'));
const [upHost, upPort] = arg('upstream', '127.0.0.1:11434').split(':');
if (!['127.0.0.1', '::1', 'localhost'].includes(upHost)) {
  console.error(`ollama-tls-front: the upstream must be on the loopback, not ${upHost}`);
  process.exit(2);
}
const need = (name) => {
  const v = process.env[name];
  if (!v) { console.error(`ollama-tls-front: ${name} is required`); process.exit(2); }
  return fs.readFileSync(v);
};

const server = tls.createServer({
  cert: need('RE_TLS_CERT'),
  key: need('RE_TLS_KEY'),
  ca: need('RE_TLS_CA'),
  crl: need('RE_TLS_CRL'),
  requestCert: true,
  rejectUnauthorized: true,
  minVersion: 'TLSv1.3',
  maxVersion: 'TLSv1.3',
  ciphers: process.env.RE_TLS_SUITES || 'TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256',
  ecdhCurve: process.env.RE_TLS_GROUPS || 'X25519MLKEM768:X25519:secp384r1',
}, (client) => {
  const upstream = net.connect(Number(upPort), upHost);
  client.pipe(upstream);
  upstream.pipe(client);
  const close = () => { client.destroy(); upstream.destroy(); };
  client.on('error', close);
  upstream.on('error', close);
});
server.on('tlsClientError', () => {}); // a refused handshake is the point, not an incident
server.listen(port, bind, () => {
  console.log(`ollama-tls-front: https://${bind}:${port} -> ${upHost}:${upPort} (TLS 1.3, mTLS)`);
});
