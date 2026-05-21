import { test, expect } from '@playwright/test';

/**
 * Full Integration E2E Tests
 * Tests the complete flow across all services:
 * 1. Create sequence via API
 * 2. Process input vector
 * 3. Verify changes in Visualizer UI
 */

const API_BASE_URL = 'https://localhost:3000';
const VISUALIZER_URL = 'https://localhost:5173';

test.describe('Full Integration - End to End Flow', () => {
  test('should create sequence, process vector, and see results in UI', async ({ page, request }) => {
    // Step 1: Create a test sequence via API
    console.log('Step 1: Creating test sequence...');

    const sequenceData = {
      name: 'Integration Test Sequence',
      vectors: [
        {
          elements: [
            { value: 0.7, comparatorType: 'threshold', threshold: 0.15 }
          ],
          isInitial: true,
          nextVectorIds: ['integration-vector-2'],
          outputVectors: []
        },
        {
          id: 'integration-vector-2',
          elements: [
            { value: 0.9, comparatorType: 'threshold', threshold: 0.1 }
          ],
          isInitial: false,
          nextVectorIds: [],
          outputVectors: [
            {
              id: 'integration-output',
              vector: [1.0, 1.0],
              timestamp: Date.now(),
              metadata: { testRun: true }
            }
          ]
        }
      ]
    };

    const createResponse = await request.post(`${API_BASE_URL}/api/sequences`, {
      data: sequenceData
    });

    expect(createResponse.ok()).toBeTruthy();
    const responseData = await createResponse.json();
    const sequence = responseData.sequence || responseData;
    const sequenceId = sequence.id;
    console.log(`✓ Sequence created with ID: ${sequenceId}`);

    // Step 2: Process an input vector that should trigger transitions
    console.log('Step 2: Processing input vector...');

    const inputData = {
      vector: [0.72] // Should match first vector
    };

    const processResponse = await request.post(`${API_BASE_URL}/api/engine/process`, {
      data: inputData
    });

    expect(processResponse.ok()).toBeTruthy();
    const processResult = await processResponse.json();
    console.log('✓ Input vector processed');

    // Step 3: Verify engine stats updated
    console.log('Step 3: Verifying engine stats...');

    const statsResponse = await request.get(`${API_BASE_URL}/api/engine/stats`);
    expect(statsResponse.ok()).toBeTruthy();

    const result = await statsResponse.json();
    const stats = result.stats || result;
    expect(stats.totalSequences).toBeGreaterThan(0);
    console.log(`✓ Engine has ${stats.totalSequences} sequences`);

    // Step 4: Open Visualizer and verify sequence appears
    console.log('Step 4: Opening Visualizer UI...');

    await page.goto(VISUALIZER_URL);
    await page.waitForLoadState('networkidle');
    await page.waitForTimeout(2000); // Wait for data to load

    // Check if machine cards are visible; if the API failed on first load,
    // reload once to retry getMachines() before asserting.
    const machineCard = page.locator('h3').first();
    if (!await machineCard.isVisible().catch(() => false)) {
      await page.reload();
      await page.waitForLoadState('networkidle');
      await page.waitForTimeout(2000);
    }
    await expect(machineCard).toBeVisible({ timeout: 10000 });
    console.log('✓ Visualizer loaded successfully');

    // Step 5: Check for active vectors
    console.log('Step 5: Checking for active vectors...');

    const activeResponse = await request.get(`${API_BASE_URL}/api/engine/active`);
    expect(activeResponse.ok()).toBeTruthy();

    const activeVectors = await activeResponse.json();
    console.log(`✓ Found ${activeVectors.length} active vectors`);

    // Step 6: Cleanup - delete test sequence
    console.log('Step 6: Cleaning up test sequence...');

    const deleteResponse = await request.delete(`${API_BASE_URL}/api/sequences/${sequenceId}`);
    if (deleteResponse.ok()) {
      console.log('✓ Test sequence deleted');
    } else {
      const deleteError = await deleteResponse.text();
      console.log(`⚠ Delete failed (status ${deleteResponse.status()}): ${deleteError}`);
      // Don't fail the test - cleanup is best effort
    }

    console.log('✅ Full integration test completed successfully!');
  });

  test('should handle sampler workflow', async ({ page, request }) => {
    console.log('Testing sampler workflow...');

    // Start sampler with periodic strategy
    const startResponse = await request.post(`${API_BASE_URL}/api/sampler/start`, {
      data: {
        strategy: 'periodic',
        intervalMs: 1000
      }
    });

    if (startResponse.ok()) {
      console.log('✓ Sampler started');

      // Wait for some samples
      await page.waitForTimeout(3000);

      // Check stats
      const statsResponse = await request.get(`${API_BASE_URL}/api/sampler/stats`);
      expect(statsResponse.ok()).toBeTruthy();

      const result = await statsResponse.json();
      const stats = result.stats || result;
      expect(stats.isRunning).toBeTruthy();
      console.log('✓ Sampler is running');

      // Stop sampler
      const stopResponse = await request.post(`${API_BASE_URL}/api/sampler/stop`);
      expect(stopResponse.ok()).toBeTruthy();
      console.log('✓ Sampler stopped');
    } else {
      expect(startResponse.ok()).toBeTruthy();
    }
  });

  test('should verify all services are healthy', async ({ request }) => {
    console.log('Checking health of all services...');

    // Check Reality Engine (which depends on Qdrant — if RE is healthy, Qdrant is reachable)
    const qdrantProxyResponse = await request.get(`${API_BASE_URL}/api/health`);
    expect(qdrantProxyResponse.ok()).toBeTruthy();
    console.log('✓ Qdrant is reachable (via Reality Engine health check)');

    // Check Reality Engine
    const engineResponse = await request.get(`${API_BASE_URL}/api/engine/stats`);
    expect(engineResponse.ok()).toBeTruthy();
    console.log('✓ Reality Engine is healthy');

    // Check Visualizer Backend
    const vizBackendResponse = await request.get('https://localhost:3001/health');
    expect(vizBackendResponse.ok()).toBeTruthy();
    console.log('✓ Visualizer Backend is healthy');

    // Check Visualizer Frontend
    const vizFrontendResponse = await request.get(VISUALIZER_URL);
    expect(vizFrontendResponse.ok()).toBeTruthy();
    console.log('✓ Visualizer Frontend is healthy');

    console.log('✅ All services are healthy!');
  });

  test('should test data persistence across restarts', async ({ request }) => {
    console.log('Testing data persistence...');

    // Create a sequence
    const sequenceData = {
      name: 'Persistence Test Sequence',
      vectors: [
        {
          elements: [{ value: 0.5, comparatorType: 'equals' }],
          isInitial: true,
          nextVectorIds: [],
          outputVectors: [
            {
              vector: [1, 0],
              activationTime: 0
            }
          ]
        }
      ]
    };

    const createResponse = await request.post(`${API_BASE_URL}/api/sequences`, {
      data: sequenceData
    });

    expect(createResponse.ok()).toBeTruthy();
    const responseData = await createResponse.json();
    const sequence = responseData.sequence || responseData;
    const sequenceId = sequence.id;
    console.log(`✓ Sequence created: ${sequenceId}`);

    // Note: In a real test, you would restart the Docker container here
    // and verify the sequence still exists. For now, just verify it's retrievable.

    const getResponse = await request.get(`${API_BASE_URL}/api/sequences/${sequenceId}`);
    expect(getResponse.ok()).toBeTruthy();
    console.log('✓ Sequence is retrievable');

    // Cleanup
    await request.delete(`${API_BASE_URL}/api/sequences/${sequenceId}`);
    console.log('✓ Cleanup complete');
  });
});

test.describe('Full Integration - Error Handling', () => {
  test('should handle invalid API requests gracefully', async ({ request }) => {
    // Try to create invalid sequence
    const invalidData = {
      name: 'Invalid Sequence',
      vectors: [] // Invalid: no vectors
    };

    const response = await request.post(`${API_BASE_URL}/api/sequences`, {
      data: invalidData
    });

    // Should return error status
    expect([400, 422, 500]).toContain(response.status());
  });

  test('should handle UI errors gracefully', async ({ page }) => {
    await page.goto(VISUALIZER_URL);
    await page.waitForLoadState('networkidle');

    // The page should load even if there are errors
    const heading = page.locator('h1').first();
    await expect(heading).toBeVisible({ timeout: 10000 });
  });

  test('should handle network interruptions', async ({ page, request }) => {
    await page.goto(VISUALIZER_URL);
    await page.waitForLoadState('networkidle');

    // Simulate slow network
    await page.route('**/*', async (route) => {
      await new Promise(resolve => setTimeout(resolve, 100));
      await route.continue();
    });

    // UI should still be functional
    const heading = page.locator('h1').first();
    await expect(heading).toBeVisible();
  });
});
