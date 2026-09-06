import { FullConfig } from '@playwright/test';
import { exec } from 'child_process';
import { promisify } from 'util';
import { instanceIds, loadRegistry, reEndpoint, serviceEndpoint } from './lib/registry';

const execAsync = promisify(exec);

/**
 * Global setup runs once before all tests.
 * Services are started by Playwright webServer or by CI workflow.
 * This setup only waits for those services to become reachable.
 */
async function globalSetup(_config: FullConfig) {
  console.log('🚀 Starting global E2E test setup...');
  await waitForServices();
  console.log('✅ All services are ready!');
}

/**
 * Endpoint resolution, registry first (RealityEngine_CI#278).
 *
 * Every spec passes through this file, so its hardcoded ports were the real
 * blocker rather than the ones in the specs: `https://localhost:5001` is the
 * Scala RE under deterministic single-engine allocation and does not exist in a
 * multi-engine universe, so the setup failed before any spec ran.
 *
 * Falls back to the previous literals when no registry is present, which is
 * what makes this conversion behaviour-preserving: while allocation stays
 * deterministic the registry returns the same numbers that were hardcoded, and
 * where there is no registry at all nothing changes.
 */
function resolve(service: string, fallback: string): string {
  try {
    return serviceEndpoint(service);
  } catch {
    return fallback;
  }
}

/**
 * The RE to wait on in single-engine mode.
 *
 * By name, never by position — #274 is the standing example of `instances[0]`
 * passing while pointing at something other than what the test claimed. An
 * explicit RE_E2E_INSTANCE wins; a registry holding exactly one instance is
 * unambiguous and is used; anything else is asked for rather than guessed.
 */
function singleEngineRe(fallback: string): string {
  const named = process.env.RE_E2E_INSTANCE;
  if (named) {
    return reEndpoint(named);
  }
  try {
    const ids = instanceIds();
    if (ids.length === 1) {
      return reEndpoint(ids[0]);
    }
    if (ids.length > 1) {
      throw new Error(
        `registry lists ${ids.length} instances (${ids.join(', ')}); ` +
          'set RE_E2E_INSTANCE to name the one these specs address, ' +
          'or run with MULTI_ENGINE_E2E=true',
      );
    }
  } catch (err) {
    if (err instanceof Error && err.message.startsWith('registry lists')) throw err;
  }
  return fallback;
}

async function waitForServices() {
  const multiEngine = process.env.MULTI_ENGINE_E2E === 'true';
  const backend = resolve('manager_backend', 'http://localhost:3001');
  const visualizerUrl =
    process.env.PLAYWRIGHT_BASE_URL ||
    resolve('manager_frontend', 'https://localhost:5173');

  try {
    const registry = loadRegistry();
    const alloc = (registry as { allocation?: { mode?: string; shifted?: string[] } }).allocation;
    if (alloc?.mode) {
      const shifted = alloc.shifted?.length ? ` (shifted: ${alloc.shifted.join(', ')})` : '';
      console.log(`  ℹ️  registry: ${instanceIds().length} instance(s), allocation ${alloc.mode}${shifted}`);
    }
  } catch {
    console.log('  ℹ️  no registry; using built-in endpoints');
  }

  const services = multiEngine
    ? [
        { name: 'Visualizer Backend', url: `${backend}/health` },
        { name: 'Visualizer Engines', url: `${backend}/api/engines` },
        { name: 'Visualizer Frontend', url: `${visualizerUrl}/` },
      ]
    : [
        { name: 'Reality Engine', url: `${singleEngineRe('https://localhost:5001')}/api/health` },
        { name: 'Visualizer Backend', url: `${backend}/health` },
        { name: 'Visualizer Frontend', url: `${visualizerUrl}/` },
      ];

  const maxRetries = 60;
  const delayMs = 2000;

  for (const service of services) {
    let healthy = false;

    for (let retries = 0; retries < maxRetries; retries++) {
      try {
        await execAsync(`curl -kfsS "${service.url}" > /dev/null`);
        console.log(`  ✅ ${service.name} is healthy`);
        healthy = true;
        break;
      } catch {
        if (retries === 0 || (retries + 1) % 10 === 0) {
          console.log(`  ⏳ Waiting for ${service.name} (${retries + 1}/${maxRetries})`);
        }
        await new Promise(resolve => setTimeout(resolve, delayMs));
      }
    }

    if (!healthy) {
      throw new Error(`❌ ${service.name} failed to become healthy at ${service.url}`);
    }
  }
}

export default globalSetup;
