import { defineConfig, devices } from '@playwright/test';

/**
 * Playwright Configuration for Reality Engine E2E Tests
 *
 * Tests the full Docker deployment stack:
 * - Reality Engine API
 * - Visualizer Backend
 * - Visualizer Frontend
 * - Qdrant Vector Database
 */

const reuseServices = process.env.REUSE_SERVICES === 'true';
const isCI = !!process.env.CI;
const dockerStartCommand = "bash -c '[ -f certs/server.crt ] && [ -f certs/server.key ] && [ -f certs/keystore.p12 ] || bash certs/generate-dev-certs.sh; docker compose up -d loki grafana reality-engine visualizer-backend visualizer-frontend tls-proxy && sleep 10'";

export default defineConfig({
  testDir: './e2e',

  // Maximum time one test can run
  timeout: 60 * 1000,

  // Test execution settings
  fullyParallel: false, // Run sequentially to avoid resource contention
  forbidOnly: !!process.env.CI,
  retries: isCI ? 2 : 0,
  workers: 1, // Single worker to ensure tests don't interfere

  // Reporter configuration
  reporter: [
    ['html', { outputFolder: 'e2e-report' }],
    ['list'],
    ['json', { outputFile: 'e2e-results.json' }]
  ],

  // Shared settings for all tests
  use: {
    // Base URL for the application
    baseURL: 'https://localhost:5173',

    // Accept self-signed dev certificates
    ignoreHTTPSErrors: true,

    // Collect trace on first retry
    trace: 'on-first-retry',

    // Screenshot on failure
    screenshot: 'only-on-failure',

    // Video on failure
    video: 'retain-on-failure',

    // Timeout for each action
    actionTimeout: 15000,

    // Navigation timeout
    navigationTimeout: 30000,
  },

  // Configure projects for different browsers
  projects: isCI
    ? [
        {
          name: 'chromium',
          use: { ...devices['Desktop Chrome'] },
        }
      ]
    : [
        {
          name: 'chromium',
          use: { ...devices['Desktop Chrome'] },
        },
        {
          name: 'firefox',
          use: { ...devices['Desktop Firefox'] },
        },
        {
          name: 'webkit',
          use: { ...devices['Desktop Safari'] },
        },
        // Mobile viewports
        {
          name: 'Mobile Chrome',
          use: { ...devices['Pixel 5'] },
        },
      ],

  // Web server configuration
  // Automatically start services if not running
  webServer: reuseServices
    ? undefined
    : {
        command: dockerStartCommand,
        url: 'https://localhost:5173',
        ignoreHTTPSErrors: true,
        timeout: 120 * 1000,
        reuseExistingServer: !isCI,
      },

  // Global setup/teardown
  globalSetup: './e2e/global-setup.ts',
  globalTeardown: './e2e/global-teardown.ts',
});
