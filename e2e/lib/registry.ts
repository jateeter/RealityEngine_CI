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
