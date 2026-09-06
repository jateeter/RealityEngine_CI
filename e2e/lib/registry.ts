/**
 * Endpoint resolution from the instance registry — RealityEngine_CI#278.
 *
 * The TypeScript half of the pair; `scripts/lib/resolve-endpoint.sh` is the
 * shell half. One resolver per language, so six specs cannot each parse the
 * registry slightly differently.
 *
 * Every lookup is BY NAME. There is deliberately no positional accessor:
 * RealityEngine_CI#274 is the standing example of `instances[0]` continuing to
 * pass while silently comparing a different pair than the test claimed. If a
 * spec wants "the cpp one", it asks for `cpp-1`.
 *
 * Reads RE_REGISTRY_FILE, defaulting to the path startUniverse.sh writes.
 */
import { readFileSync } from 'node:fs';

export interface RegistryInstance {
  id: string;
  runtime: string;
  re_url: string;
  pe_url: string;
  status?: string;
}

export interface RegistryService {
  url: string;
  port: number;
}

export interface Registry {
  host?: string;
  instances: RegistryInstance[];
  services?: Record<string, RegistryService>;
}

export const REGISTRY_FILE =
  process.env.RE_REGISTRY_FILE ?? '/tmp/re-registry/re-registry.json';

export function loadRegistry(path: string = REGISTRY_FILE): Registry {
  const raw = readFileSync(path, 'utf8');
  const parsed = JSON.parse(raw) as Partial<Registry>;
  return {
    host: parsed.host,
    instances: parsed.instances ?? [],
    // A registry written before the services block existed must resolve to
    // "not found" rather than throwing — that is the upgrade path this supports.
    services: parsed.services ?? {},
  };
}

function requireInstance(id: string, path?: string): RegistryInstance {
  const found = loadRegistry(path).instances.find((i) => i.id === id);
  if (!found) {
    throw new Error(
      `registry: no instance '${id}'. Present: ${instanceIds(path).join(', ') || '(none)'}`,
    );
  }
  return found;
}

/** RE base URL for an instance, by id. */
export function reEndpoint(id: string, path?: string): string {
  return requireInstance(id, path).re_url;
}

/** PE base URL for an instance, by id. */
export function peEndpoint(id: string, path?: string): string {
  return requireInstance(id, path).pe_url;
}

/** Non-instance endpoint: manager_backend, manager_frontend, registry, mcp, swagger, mqtt. */
export function serviceEndpoint(name: string, path?: string): string {
  const svc = loadRegistry(path).services?.[name];
  if (!svc?.url) {
    const known = Object.keys(loadRegistry(path).services ?? {});
    throw new Error(
      `registry: no service '${name}'. Present: ${known.join(', ') || '(none)'}`,
    );
  }
  return svc.url;
}

/** Instance ids in registry order. For iteration — not for indexing into. */
export function instanceIds(path?: string): string[] {
  return loadRegistry(path).instances.map((i) => i.id);
}

/**
 * Resolve a service, falling back to a literal when the registry cannot answer.
 *
 * The fallback is what makes a conversion safe to land: with no registry — or a
 * registry from before the services block existed — the caller gets exactly the
 * endpoint it used before, so the change is inert where there is nothing to
 * resolve from.
 *
 * Where the registry *can* answer, it wins, and that is a real change rather
 * than a cosmetic one. The literals in these specs encode a deployment: they
 * point at the nginx TLS proxy of the Docker stack (`https://localhost:5001`),
 * which does not exist in a native multi-engine universe, where the same engine
 * is at `http://<host>:5101`. That is why five of six specs were single-engine
 * only — not because their assertions were engine-specific, but because their
 * constants named a deployment (RealityEngine_CI#278).
 */
export function endpointOr(service: string, fallback: string, path?: string): string {
  try {
    return serviceEndpoint(service, path);
  } catch {
    return fallback;
  }
}

/**
 * Resolve an RE endpoint, by instance name, falling back to a literal.
 *
 * `RE_E2E_INSTANCE` names the instance when several are registered. A registry
 * holding exactly one is unambiguous and used without asking. Never positional:
 * #274 is the standing example of `instances[0]` passing while addressing
 * something other than what the test claimed.
 */
export function reEndpointOr(fallback: string, path?: string): string {
  try {
    const named = process.env.RE_E2E_INSTANCE;
    if (named) return reEndpoint(named, path);
    const ids = instanceIds(path);
    if (ids.length === 1) return reEndpoint(ids[0], path);
    return fallback;
  } catch {
    return fallback;
  }
}

/**
 * Resolve a PE endpoint, by instance name, falling back to a literal.
 *
 * The fallback `https://localhost:3004` is the Docker stack's Perception
 * Engine. In a native multi-engine universe there is no PE on 3004 at all —
 * each instance carries its own (5300, 5600, 5100) — which is the specific
 * reason the specs naming it could not run multi-engine.
 */
export function peEndpointOr(fallback: string, path?: string): string {
  try {
    const named = process.env.RE_E2E_INSTANCE;
    if (named) return peEndpoint(named, path);
    const ids = instanceIds(path);
    if (ids.length === 1) return peEndpoint(ids[0], path);
    return fallback;
  } catch {
    return fallback;
  }
}
