// Configuration + runtime discovery for the RealityEngine MCP gateway.
//
// Resolution order for finding RE/PE base URLs:
//   1. RE_REGISTRY_URL  — the instance registry served by RealityEngine_CI
//      (scripts/registry.sh, default :5999). Shape:
//        { "host": "127.0.0.1",
//          "instances": [ { "id", "runtime", "re_url", "pe_url", ... } ] }
//      Multiple engines (cpp/lsp/scala) can be live at once; tools accept an
//      optional `instance` argument (an id or a runtime name) to pick one.
//   2. RE_URL / PE_URL  — explicit single-instance fallback.
//
// A registry is cached briefly so a burst of tool calls does not hammer it.

const REGISTRY_TTL_MS = Number(process.env.RE_MCP_REGISTRY_TTL_MS ?? 5000);

let _registryCache = { at: 0, data: null };

function envInstance() {
  const reUrl = process.env.RE_URL || process.env.REALITY_ENGINE_URL;
  const peUrl = process.env.PE_URL || process.env.PERCEPTION_ENGINE_URL;
  if (!reUrl && !peUrl) return null;
  return {
    id: process.env.RE_INSTANCE_ID || 'env',
    runtime: process.env.RE_RUNTIME || 'env',
    re_url: reUrl || peUrl,
    pe_url: peUrl || reUrl,
    source: 'env',
  };
}

async function fetchRegistry() {
  const url = process.env.RE_REGISTRY_URL;
  if (!url) return null;
  const now = Date.now();
  if (_registryCache.data && now - _registryCache.at < REGISTRY_TTL_MS) {
    return _registryCache.data;
  }
  const res = await fetch(url, { headers: { accept: 'application/json' } });
  if (!res.ok) throw new Error(`registry ${url} -> HTTP ${res.status}`);
  const reg = await res.json();
  const instances = (reg.instances || []).map((i) => ({
    id: i.id,
    runtime: i.runtime,
    re_url: i.re_url,
    pe_url: i.pe_url,
    status: i.status,
    source: 'registry',
  }));
  _registryCache = { at: now, data: instances };
  return instances;
}

// Returns the full list of known instances (registry first, env fallback).
export async function listInstances() {
  const fromRegistry = await fetchRegistry();
  if (fromRegistry && fromRegistry.length) return fromRegistry;
  const env = envInstance();
  return env ? [env] : [];
}

// Resolve a base URL for a target service ('re' | 'pe').
// `selector` may be an instance id, a runtime name, or undefined (first match).
export async function resolveBaseUrl(target, selector) {
  const instances = await listInstances();
  if (!instances.length) {
    throw new Error(
      'No RealityEngine instances available. Set RE_REGISTRY_URL, or RE_URL/PE_URL.'
    );
  }
  let chosen;
  if (selector) {
    chosen = instances.find(
      (i) => i.id === selector || i.runtime === selector
    );
    if (!chosen) {
      const known = instances.map((i) => `${i.id}(${i.runtime})`).join(', ');
      throw new Error(`Unknown instance "${selector}". Known: ${known}`);
    }
  } else {
    chosen = instances.find((i) => i.status !== 'stopped') || instances[0];
  }
  const url = target === 'pe' ? chosen.pe_url : chosen.re_url;
  if (!url) throw new Error(`Instance ${chosen.id} has no ${target}_url`);
  return { baseUrl: url.replace(/\/$/, ''), instance: chosen };
}

// Mutation policy. Read-only tools always run. Mutating tools require an
// explicit opt-in so a default deployment is safe to expose broadly.
//   RE_MCP_ALLOW_MUTATION=true            -> allow all mutating tools
//   RE_MCP_ALLOWED_TOOLS=a,b,c            -> allow only these (read or write)
export function mutationPolicy() {
  const allowAll = /^(1|true|yes)$/i.test(process.env.RE_MCP_ALLOW_MUTATION ?? '');
  const allowlist = (process.env.RE_MCP_ALLOWED_TOOLS ?? '')
    .split(',')
    .map((s) => s.trim())
    .filter(Boolean);
  return {
    allowAll,
    allowlist,
    isAllowed(toolName, mutating) {
      if (allowlist.length) return allowlist.includes(toolName);
      if (!mutating) return true;
      return allowAll;
    },
  };
}

export const settings = {
  serverName: process.env.RE_MCP_SERVER_NAME || 'realityengine',
  serverVersion: '1.1.0',
  httpPort: Number(process.env.RE_MCP_HTTP_PORT ?? 7331),
  httpHost: process.env.RE_MCP_HTTP_HOST || '127.0.0.1',
  requestTimeoutMs: Number(process.env.RE_MCP_TIMEOUT_MS ?? 15000),
};
