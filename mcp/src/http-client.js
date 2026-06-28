// Thin HTTP client for RE/PE endpoints. Uses the global fetch (Node >= 18).
//
// The Docker/CI deployments front the engines with a self-signed TLS proxy.
// For local/dev convenience, set RE_MCP_INSECURE_TLS=1 to accept those certs
// (handled in the entrypoints by toggling NODE_TLS_REJECT_UNAUTHORIZED).

import { settings } from './config.js';

export async function httpRequest(baseUrl, method, path, body) {
  const url = `${baseUrl}${path}`;
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), settings.requestTimeoutMs);
  let res;
  try {
    res = await fetch(url, {
      method,
      headers: {
        accept: 'application/json',
        ...(body !== undefined ? { 'content-type': 'application/json' } : {}),
      },
      body: body !== undefined ? JSON.stringify(body) : undefined,
      signal: controller.signal,
    });
  } catch (err) {
    clearTimeout(timer);
    throw new Error(`${method} ${url} failed: ${err.message}`);
  }
  clearTimeout(timer);

  const text = await res.text();
  let parsed;
  try {
    parsed = text ? JSON.parse(text) : null;
  } catch {
    parsed = text;
  }
  if (!res.ok) {
    const detail = typeof parsed === 'string' ? parsed : JSON.stringify(parsed);
    throw new Error(`${method} ${url} -> HTTP ${res.status}: ${detail}`);
  }
  return parsed;
}
