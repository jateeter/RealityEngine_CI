// Lane TLS for the MCP gateway (RealityEngine_CI#730, #668).
//
// The runtime contract is docs/TRANSPORT_SECURITY.md: RE_TLS_CERT, RE_TLS_KEY,
// RE_TLS_CA, RE_TLS_CRL. With RE_TLS_CERT set:
//   - the Streamable HTTP endpoint serves TLS 1.3 at the transport profile and
//     requires a client certificate from the lane CA (a service port);
//   - its calls to the engines and the instance registry trust the lane CA
//     alone, present this gateway's certificate, and are held to the profile;
//   - RE_MCP_INSECURE_TLS is ignored: verification is never turned off on the lane.
// With it unset nothing here runs, and the gateway is what it was.
//
// The choices are the engines' and Manager's (RealityEngine_Manager
// src/laneTls.ts): the same suites and groups, and the lane certificate offered
// only to internal peers (loopback, RFC1918, link-local, ULA, single-label
// names, .localhost/.internal/.local; RealityEngine_CI#739).

import { readFileSync } from 'node:fs';
import * as http from 'node:http';
import * as https from 'node:https';
import { isIP } from 'node:net';
import * as tls from 'node:tls';

export const PROFILE_SUITES = 'TLS_AES_256_GCM_SHA384:TLS_CHACHA20_POLY1305_SHA256';
export const GROUPS_PQ = 'X25519MLKEM768:X25519:secp384r1';
export const GROUPS_FALLBACK = 'X25519:secp384r1';

const env = (name) => {
  const v = (process.env[name] ?? '').trim();
  return v === '' ? undefined : v;
};

/** RE_TLS_CERT set: the lane is on. A partial configuration is an error, never a plaintext start. */
export function laneSettings() {
  const cert = env('RE_TLS_CERT');
  if (!cert) return undefined;
  const key = env('RE_TLS_KEY');
  const ca = env('RE_TLS_CA');
  if (!key || !ca) throw new Error('TLS: RE_TLS_CERT is set, so RE_TLS_KEY and RE_TLS_CA must be too');
  return { cert, key, ca, crl: env('RE_TLS_CRL') };
}

let groupsInForce;
/** The profile's groups this Node's OpenSSL accepts: the PQ hybrid first. */
export function profileGroups() {
  if (groupsInForce) return groupsInForce;
  try {
    tls.createSecureContext({ ecdhCurve: GROUPS_PQ });
    groupsInForce = GROUPS_PQ;
  } catch {
    groupsInForce = GROUPS_FALLBACK;
  }
  return groupsInForce;
}

function read(path, what) {
  try {
    return readFileSync(path);
  } catch (e) {
    throw new Error(`TLS: cannot load ${what} ${path}: ${e.message}`);
  }
}

function material(s) {
  return {
    minVersion: 'TLSv1.3',
    maxVersion: 'TLSv1.3',
    ciphers: PROFILE_SUITES,
    ecdhCurve: profileGroups(),
    cert: read(s.cert, 'RE_TLS_CERT'),
    key: read(s.key, 'RE_TLS_KEY'),
    ca: read(s.ca, 'RE_TLS_CA'),
    ...(s.crl ? { crl: read(s.crl, 'RE_TLS_CRL') } : {}),
  };
}

/** The listener: TLS 1.3, a client certificate from the lane CA required. */
export function serverOptions(s) {
  return { ...material(s), requestCert: true, rejectUnauthorized: true };
}

/** An internal peer, by the shared rule (RealityEngine_CI#739). */
export function isInternalHost(raw) {
  const h = (raw ?? '').replace(/^\[|\]$/g, '').toLowerCase();
  if (h === '') return false;
  if (h === 'localhost' || h.endsWith('.localhost') || h.endsWith('.internal') || h.endsWith('.local')) return true;
  const kind = isIP(h);
  if (kind === 4) {
    const [a, b] = h.split('.').map(Number);
    return a === 127 || a === 10 || (a === 172 && b >= 16 && b <= 31) || (a === 192 && b === 168) || (a === 169 && b === 254);
  }
  if (kind === 6) {
    if (h === '::1') return true;
    const first = parseInt(h.split(':')[0] || '0', 16);
    return (first & 0xfe00) === 0xfc00 || (first & 0xffc0) === 0xfe80;
  }
  return !h.includes('.');
}

let internalAgent;
/** The agent for an https call to an internal peer with the lane on. */
function laneAgent(s) {
  if (!internalAgent) internalAgent = new https.Agent({ ...material(s), keepAlive: true });
  return internalAgent;
}

/**
 * fetch-shaped request: { status, ok, headers, text(), json() }. With the lane on an
 * https URL to an internal peer goes over the lane's mTLS; anything else is
 * the global fetch, as before. Plain http to an internal peer is refused on the
 * lane: the lane has no plaintext links.
 */
export async function laneFetch(url, { method = 'GET', headers = {}, body, signal } = {}) {
  const s = laneSettings();
  const u = new URL(url);
  if (!s) return fetch(url, { method, headers, body, signal });
  if (u.protocol === 'http:' && isInternalHost(u.hostname)) {
    throw new Error(`refusing plaintext ${url}: the lane is on (RE_TLS_CERT), so every internal link is https`);
  }
  if (u.protocol !== 'https:' || !isInternalHost(u.hostname)) return fetch(url, { method, headers, body, signal });
  return new Promise((resolve, reject) => {
    const req = https.request(u, { method, headers, agent: laneAgent(s), signal }, (res) => {
      const chunks = [];
      res.on('data', (c) => chunks.push(c));
      res.on('end', () => {
        const text = Buffer.concat(chunks).toString('utf8');
        const headers = new Headers();
        for (const [k, v] of Object.entries(res.headers)) {
          for (const one of Array.isArray(v) ? v : [v]) if (one !== undefined) headers.append(k, String(one));
        }
        resolve({
          status: res.statusCode,
          ok: res.statusCode >= 200 && res.statusCode < 300,
          headers,
          text: async () => text,
          json: async () => JSON.parse(text),
        });
      });
      res.on('error', reject);
    });
    req.on('error', reject);
    if (body !== undefined) req.write(body);
    req.end();
  });
}

/** The HTTP listener for http-server.js: https with mTLS on the lane, http otherwise. */
export function createListener(handler) {
  const s = laneSettings();
  if (!s) return { server: http.createServer(handler), scheme: 'http', note: '' };
  const server = https.createServer(serverOptions(s), handler);
  return { server, scheme: 'https', note: ` (TLS 1.3, client certificate required, groups ${profileGroups()})` };
}

/** RE_MCP_INSECURE_TLS applies off the lane only. */
export function insecureTlsAllowed() {
  return !laneSettings() && /^(1|true|yes)$/i.test(process.env.RE_MCP_INSECURE_TLS ?? '');
}
