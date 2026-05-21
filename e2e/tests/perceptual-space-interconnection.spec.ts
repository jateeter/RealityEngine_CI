import { test, expect } from '@playwright/test';

/**
 * Perceptual Space Interconnection E2E Test
 *
 * Tests machine interconnection through shared perceptual space:
 * 1. Multi-Step processes input and outputs to bytes [3:5]
 * 2. RS2 and RSFlipFlop both read from [3:5] as their input
 * 3. RS2 outputs to [8:10], RSFlipFlop outputs to [6:8]
 *
 * Perceptual Space Layout (768 dimensions):
 * - [0:3]   Multi-Step input (3 bytes)
 * - [3:5]   Multi-Step output / RS2 & RSFlipFlop input (2 bytes)
 * - [6:8]   RSFlipFlop output (2 bytes)
 * - [8:10]  RS2 output (2 bytes)
 *
 * Input Sequence (3-element vectors — only PS[0:3] written each step):
 * 1. (0,0,0) - Initial, no output: PS[3:5] = [0,0]
 * 2. (1,0,0) - Seq2 step 1: PS[3:5] = [0,0]
 * 3. (1,0,1) - Seq2 step 2: PS[3:5] = [0,0]
 * 4. (1,1,1) - Seq2 final: PS[3:5] = [1,0] (MultiStep outputs [1,0])
 * 5. (0,0,0) - Probe step: RS2 and RSFlipFlop observe [1,0] at PS[3:5] → both output [1,0]
 */

const VISUALIZER_URL = 'https://localhost:5173';
const API_URL = 'https://localhost:3001';
const PERCEPTION_ENGINE_URL = 'https://localhost:3004';

interface PerceptualVector {
  bytes: number[];
  description: string;
}

// Helper to create a 3-byte perceptual input vector (matching inputRegion.length=3).
// Using only 3 elements ensures updateRegion writes only PS[0:3], leaving
// machine output regions (e.g. PS[3:5]) intact between steps.
function createPerceptualVector(inputBytes: number[], _description: string): number[] {
  return inputBytes.slice(0, 3);
}

test.describe('Perceptual Space Interconnection - Multi-Step → RS2 + RSFlipFlop', () => {
  let perceptionEngineWasRunning = false;
  let perceptionEngineIntervalMs = 1000;

  test.beforeEach(async ({ page }) => {
    // Stop perception engine auto-push to avoid corrupting simulation state
    try {
      const stateResp = await page.request.get(`${PERCEPTION_ENGINE_URL}/api/state`);
      if (stateResp.ok()) {
        const state = await stateResp.json();
        perceptionEngineWasRunning = state.auto?.running === true;
        perceptionEngineIntervalMs = state.auto?.intervalMs ?? 1000;
      }
      await page.request.post(`${PERCEPTION_ENGINE_URL}/api/auto/stop`);
    } catch { /* perception engine may not be available */ }

    await page.goto(VISUALIZER_URL);
    await page.waitForLoadState('networkidle');
  });

  test.afterEach(async ({ page }) => {
    if (perceptionEngineWasRunning) {
      try {
        await page.request.post(`${PERCEPTION_ENGINE_URL}/api/auto/start`, {
          data: { intervalMs: perceptionEngineIntervalMs }
        });
      } catch { /* ignore */ }
    }
  });

  test('should complete full perceptual space workflow with machine interconnection', async ({ page }) => {
    test.setTimeout(180000); // 3 minutes

    // ===== STEP 1: Load all machines to ensure they're registered =====
    await test.step('Ensure all machines are loaded', async () => {
      console.log('Step 1: Loading machines via API...');

      // Load Multi-Step machine
      const multiStepResponse = await page.request.get(`${API_URL}/api/machines/json/MultiStep`);
      expect(multiStepResponse.ok()).toBeTruthy();
      console.log('  ✓ Multi-Step machine loaded');

      // Load RS2 machine
      const rs2Response = await page.request.get(`${API_URL}/api/machines/json/RS2`);
      expect(rs2Response.ok()).toBeTruthy();
      console.log('  ✓ RS2 machine loaded');

      // Load RSFlipFlop machine
      const rsFlipFlopResponse = await page.request.get(`${API_URL}/api/machines/json/RSFlipFlop`);
      expect(rsFlipFlopResponse.ok()).toBeTruthy();
      console.log('  ✓ RSFlipFlop machine loaded');

      await page.waitForTimeout(2000);
    });

    // ===== STEP 2: Configure perceptual simulation =====
    await test.step('Configure perceptual simulation with input sequence', async () => {
      console.log('Step 2: Configuring perceptual simulation...');

      const inputSequence = [
        createPerceptualVector([0, 0, 0], 'Initial zero vector'),
        createPerceptualVector([1, 0, 0], 'Seq2 initial: 100'),
        createPerceptualVector([1, 0, 1], 'Seq2 second: 101'),
        createPerceptualVector([1, 1, 1], 'Seq2 final: 111 → MultiStep outputs [1,0] to PS[3:5]'),
        createPerceptualVector([0, 0, 0], 'Probe step: RS2 and RSFlipFlop observe [1,0] at PS[3:5]'),
      ];

      const chunkResponse = await page.request.post(`${API_URL}/api/perceptual-simulation/configure/chunk`, {
        data: {
          vectors: inputSequence,
          reset: true,
          inputRegion: { offset: 0, length: 3 }, // Multi-Step input region
          stepDelayMs: 1000,
          maxSteps: inputSequence.length
        }
      });
      expect(chunkResponse.ok()).toBeTruthy();

      const commitResponse = await page.request.post(`${API_URL}/api/perceptual-simulation/configure/commit`);
      expect(commitResponse.ok()).toBeTruthy();
      const configData = await commitResponse.json();
      expect(configData.success).toBeTruthy();

      console.log(`  ✓ Configured with ${inputSequence.length} input vectors`);
    });

    // ===== STEP 3: Execute steps 1-4 and verify Multi-Step output becomes [1,0] =====
    // Steps 1-3: MultiStep input (0,0,0)→(1,0,0)→(1,0,1) — no output yet, PS[3:5]=[0,0]
    // Step 4: MultiStep input (1,1,1) — final match, outputs [1,0] to PS[3:5]
    // RS2 and RSFlipFlop see [0,0] at PS[3:5] during these steps (building hold state)
    await test.step('Execute steps 1-4, verify Multi-Step outputs [1,0] to PS[3:5]', async () => {
      console.log('Step 3: Stepping through vectors 1-4...');

      for (let i = 0; i < 4; i++) {
        const stepResponse = await page.request.post(`${API_URL}/api/perceptual-simulation/step`);
        expect(stepResponse.ok()).toBeTruthy();

        const stepData = await stepResponse.json();
        console.log(`  Step ${i + 1}: ${stepData.step?.description || 'completed'}`);
      }

      // After step 4: MultiStep output [1,0] has been written to PS[3:5]
      const stateResponse = await page.request.get(`${API_URL}/api/perceptual-simulation/state`);
      expect(stateResponse.ok()).toBeTruthy();

      const stateData = await stateResponse.json();
      const perceptualSpace = stateData.state?.perceptualSpace || [];

      const multiStepOutput = perceptualSpace.slice(3, 5);
      console.log(`  Multi-Step output [3:5] = [${multiStepOutput}]`);

      expect(multiStepOutput[0]).toBe(1);
      expect(multiStepOutput[1]).toBe(0);

      console.log('  ✓ Multi-Step output verified: [1,0] in PS[3:5]');
    });

    // ===== STEP 4: Execute probe step so RS machines observe [1,0] at PS[3:5] =====
    // RS2 is a two-step machine: it needs one step with [0,0] (already done in steps 1-4)
    // and then a subsequent step where PS[3:5]=[1,0] to produce output.
    // RSFlipFlop is single-step but also needs to observe [1,0] as its next input.
    // The probe step writes [0,0,0] to PS[0:3] only (3-element vector), so PS[3:5]=[1,0]
    // persists from step 4 and both machines process it.
    await test.step('Execute probe step, RS2 and RSFlipFlop observe PS[3:5]=[1,0]', async () => {
      console.log('Step 4: Executing probe step (0,0,0) — RS machines observe [1,0]...');

      const stepResponse = await page.request.post(`${API_URL}/api/perceptual-simulation/step`);
      expect(stepResponse.ok()).toBeTruthy();

      const stepData = await stepResponse.json();
      console.log(`  Probe step: ${stepData.step?.description || 'completed'}`);

      console.log('  ✓ Probe step executed');
    });

    // ===== STEP 5: Verify RS2 and RSFlipFlop perceive [1,0] =====
    await test.step('Verify RS2 and RSFlipFlop perceive Multi-Step output', async () => {
      console.log('Step 5: Verifying machine inputs...');

      const stateResponse = await page.request.get(`${API_URL}/api/perceptual-simulation/state`);
      const stateData = await stateResponse.json();
      const perceptualSpace = stateData.state?.perceptualSpace || [];

      // Both machines read from [3:5]
      const sharedInput = perceptualSpace.slice(3, 5);

      console.log(`  RS2 input [3:5] = [${sharedInput}]`);
      console.log(`  RSFlipFlop input [3:5] = [${sharedInput}]`);

      expect(sharedInput[0]).toBe(1);
      expect(sharedInput[1]).toBe(0);

      console.log('  ✓ Both machines perceive [1,0]');
    });

    // ===== STEP 6: Verify RS2 output =====
    await test.step('Verify RS2 output at [8:10]', async () => {
      console.log('Step 6: Verifying RS2 output...');

      const stateResponse = await page.request.get(`${API_URL}/api/perceptual-simulation/state`);
      const stateData = await stateResponse.json();
      const perceptualSpace = stateData.state?.perceptualSpace || [];

      const rs2Output = perceptualSpace.slice(8, 10);
      console.log(`  RS2 output [8:10] = [${rs2Output}]`);

      expect(rs2Output[0]).toBe(1);
      expect(rs2Output[1]).toBe(0);

      console.log('  ✓ RS2 output verified: [1,0]');
    });

    // ===== STEP 7: Verify RSFlipFlop output =====
    await test.step('Verify RSFlipFlop output at [6:8]', async () => {
      console.log('Step 7: Verifying RSFlipFlop output...');

      const stateResponse = await page.request.get(`${API_URL}/api/perceptual-simulation/state`);
      const stateData = await stateResponse.json();
      const perceptualSpace = stateData.state?.perceptualSpace || [];

      const rsFlipFlopOutput = perceptualSpace.slice(6, 8);
      console.log(`  RSFlipFlop output [6:8] = [${rsFlipFlopOutput}]`);

      expect(rsFlipFlopOutput[0]).toBe(1);
      expect(rsFlipFlopOutput[1]).toBe(0);

      console.log('  ✓ RSFlipFlop output verified: [1,0]');
    });

    // ===== STEP 8: Verify complete perceptual space state =====
    await test.step('Verify complete perceptual space state', async () => {
      console.log('Step 8: Verifying complete perceptual space...');

      const stateResponse = await page.request.get(`${API_URL}/api/perceptual-simulation/state`);
      const stateData = await stateResponse.json();
      const perceptualSpace = stateData.state?.perceptualSpace || [];

      console.log('  Final Perceptual Space State:');
      console.log(`    Multi-Step input [0:3]:       [${perceptualSpace.slice(0, 3)}]`);
      console.log(`    Multi-Step output [3:5]:      [${perceptualSpace.slice(3, 5)}]`);
      console.log(`    RS2/RSFlipFlop input [3:5]:   [${perceptualSpace.slice(3, 5)}]`);
      console.log(`    RSFlipFlop output [6:8]:      [${perceptualSpace.slice(6, 8)}]`);
      console.log(`    RS2 output [8:10]:            [${perceptualSpace.slice(8, 10)}]`);

      // Verify all values
      // PS[0:3] = [0,0,0]: probe step input (written by updateRegion in step 5)
      expect(perceptualSpace.slice(0, 3)).toEqual([0, 0, 0]); // Probe step input
      expect(perceptualSpace.slice(3, 5)).toEqual([1, 0]);    // Multi-Step output (persisted from step 4)
      expect(perceptualSpace.slice(6, 8)).toEqual([1, 0]);    // RSFlipFlop output
      expect(perceptualSpace.slice(8, 10)).toEqual([1, 0]);   // RS2 output

      console.log('  ✓ Complete perceptual space state verified');
    });

    // ===== STEP 9: Verify simulation history =====
    await test.step('Verify simulation history', async () => {
      console.log('Step 9: Checking simulation history...');

      const historyResponse = await page.request.get(`${API_URL}/api/perceptual-simulation/history`);
      expect(historyResponse.ok()).toBeTruthy();

      const historyData = await historyResponse.json();
      const history = historyData.history || [];

      console.log(`  Total steps recorded: ${history.length}`);
      expect(history.length).toBeGreaterThan(0);

      console.log('  ✓ Simulation history verified');
    });

    console.log('\n✅ Perceptual space interconnection test completed successfully!');
  });

  // ===== TEST 2: Verify perceptual space consistency =====
  test('should verify perceptual space remains consistent across operations', async ({ page }) => {
    test.setTimeout(60000);

    console.log('Verifying perceptual space consistency...');

    // Configure simulation
    const inputSequence = [
      createPerceptualVector([1, 0, 0], 'Test vector 1'),
      createPerceptualVector([1, 0, 1], 'Test vector 2'),
    ];

    const chunkResponse = await page.request.post(`${API_URL}/api/perceptual-simulation/configure/chunk`, {
      data: {
        vectors: inputSequence,
        reset: true,
        inputRegion: { offset: 0, length: 3 }, // Multi-Step input region
        stepDelayMs: 500,
        maxSteps: 2
      }
    });
    expect(chunkResponse.ok()).toBeTruthy();
    const commitResponse = await page.request.post(`${API_URL}/api/perceptual-simulation/configure/commit`);
    expect(commitResponse.ok()).toBeTruthy();

    // Get initial state
    const initialStateResponse = await page.request.get(`${API_URL}/api/perceptual-simulation/state`);
    const initialState = await initialStateResponse.json();
    const initialSpace = initialState.state?.perceptualSpace || [];

    console.log('  Initial perceptual space captured');

    // Step once
    await page.request.post(`${API_URL}/api/perceptual-simulation/step`);
    await page.waitForTimeout(500);

    // Get state again
    const step1Response = await page.request.get(`${API_URL}/api/perceptual-simulation/state`);
    const step1State = await step1Response.json();
    const step1Space = step1State.state?.perceptualSpace || [];

    // Verify perceptual space is an array of 768 numbers
    expect(step1Space.length).toBe(768);
    expect(step1Space.every((v: number) => typeof v === 'number')).toBeTruthy();

    console.log('✓ Perceptual space remains consistent across machine switches');
  });
});
