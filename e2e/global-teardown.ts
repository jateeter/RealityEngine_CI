import { FullConfig } from '@playwright/test';

/**
 * Global teardown runs once after all tests
 * Optionally stops Docker services
 */
async function globalTeardown(_config: FullConfig) {
  console.log('🧹 Running global E2E test teardown...');

  // If CI workflow started services, let workflow own shutdown to avoid duplicate stop.
  if (process.env.REUSE_SERVICES === 'true') {
    console.log('💡 Services managed externally (REUSE_SERVICES=true), skipping shutdown');
  } else if (process.env.CI) {
    // Only stop services in CI environments when Playwright started them.
    console.log('🛑 Stopping Docker services (CI mode)...');
    const { exec } = require('child_process');
    const { promisify } = require('util');
    const execAsync = promisify(exec);

    try {
      await execAsync('docker compose down');
      console.log('✅ Services stopped');
    } catch (error) {
      console.error('⚠️  Failed to stop services:', error);
    }
  } else {
    console.log('💡 Leaving services running for local development');
  }

  console.log('✅ Teardown complete');
}

export default globalTeardown;
