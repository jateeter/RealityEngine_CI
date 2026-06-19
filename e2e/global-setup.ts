import { FullConfig } from '@playwright/test';
import { exec } from 'child_process';
import { promisify } from 'util';

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

async function waitForServices() {
  const multiEngine = process.env.MULTI_ENGINE_E2E === 'true';
  const visualizerUrl = process.env.PLAYWRIGHT_BASE_URL || 'https://localhost:5173';
  const services = multiEngine
    ? [
        { name: 'Visualizer Backend', url: 'http://localhost:3001/health' },
        { name: 'Visualizer Engines', url: 'http://localhost:3001/api/engines' },
        { name: 'Visualizer Frontend', url: `${visualizerUrl}/` },
      ]
    : [
        { name: 'Reality Engine', url: 'https://localhost:5001/api/health' },
        { name: 'Visualizer Backend', url: 'https://localhost:3001/health' },
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
      throw new Error(`❌ ${service.name} failed to become healthy`);
    }
  }
}

export default globalSetup;
