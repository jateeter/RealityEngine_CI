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
  const services = [
    { name: 'Reality Engine', url: 'https://localhost:3000/api/health' },
    { name: 'Visualizer Backend', url: 'https://localhost:3001/health' },
    { name: 'Visualizer Frontend', url: 'https://localhost:5173/' },
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
