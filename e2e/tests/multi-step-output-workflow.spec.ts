import { test, expect } from '@playwright/test';

/**
 * Multi-Step State Machine E2E Test
 *
 * Verifies the complete perceptual workflow for the Multi-Step State Machine:
 *
 * Perceptual Space Layout (256 bytes):
 *   [0:3]   Multi-Step input  (3 bytes)
 *   [3:5]   Multi-Step output / RS2 & RSFlipFlop input  (2 bytes)
 *   [6:8]   RSFlipFlop output (2 bytes)
 *   [8:10]  RS2 output        (2 bytes)
 *
 * Multi-Step Sequences:
 *   Sequence 1: 000→001→011 → outputs [0,1]  (RESET signal to RS flip-flops)
 *   Sequence 2: 100→101→111 → outputs [1,0]  (SET signal to RS flip-flops)
 *
 * Architecture note:
 *   Input vectors are 3-element arrays (matching inputRegion.length=3).
 *   This ensures updateRegion() only writes bytes [0:2], leaving the RS output
 *   region [3:5] intact across steps so RS machines can observe Multi-Step's
 *   output on the cycle immediately following completion.  A single "probe" step
 *   after the terminal match allows RS2 and RSFlipFlop to latch their response.
 */

const VISUALIZER_URL = 'https://localhost:5173';
const PERCEPTUAL_API_URL = 'https://localhost:3001';  // Visualizer backend (perceptual simulation)
const API_URL = 'https://localhost:3000';              // Reality Engine direct (legacy API)
const PERCEPTION_ENGINE_URL = 'https://localhost:3004'; // Perception Engine backend

/** Load all three machines required for the interconnection test. */
async function loadMachines(page: Parameters<Parameters<typeof test>[1]>[0]['page']) {
  const multiStep = await page.request.get(`${PERCEPTUAL_API_URL}/api/machines/json/MultiStep`);
  expect(multiStep.ok()).toBeTruthy();

  const rs2 = await page.request.get(`${PERCEPTUAL_API_URL}/api/machines/json/RS2`);
  expect(rs2.ok()).toBeTruthy();

  const rsFF = await page.request.get(`${PERCEPTUAL_API_URL}/api/machines/json/RSFlipFlop`);
  expect(rsFF.ok()).toBeTruthy();
}

/** Configure the perceptual simulation with a 3-element-per-step input sequence. */
async function configureSim(
  page: Parameters<Parameters<typeof test>[1]>[0]['page'],
  inputSequence: number[][],
  stepDelayMs = 500
) {
  // Send all vectors in a single chunk with reset:true to initialise the buffer
  const chunkResp = await page.request.post(`${PERCEPTUAL_API_URL}/api/perceptual-simulation/configure/chunk`, {
    data: {
      vectors: inputSequence,
      reset: true,
      inputRegion: { offset: 0, length: 3 },
      stepDelayMs,
      maxSteps: inputSequence.length
    }
  });
  expect(chunkResp.ok()).toBeTruthy();

  // Commit the staged buffer to activate the configuration
  const commitResp = await page.request.post(`${PERCEPTUAL_API_URL}/api/perceptual-simulation/configure/commit`);
  expect(commitResp.ok()).toBeTruthy();
  const body = await commitResp.json();
  expect(body.success).toBeTruthy();
  return body;
}

/** Execute one manual step and return the step result. */
async function stepSim(page: Parameters<Parameters<typeof test>[1]>[0]['page']) {
  const resp = await page.request.post(`${PERCEPTUAL_API_URL}/api/perceptual-simulation/step`);
  expect(resp.ok()).toBeTruthy();
  const body = await resp.json();
  expect(body.success).toBeTruthy();
  return body;
}

/**
 * Poll until isRunning=false (or timeout), then return the perceptual space.
 * Reads state immediately after completion to avoid interference from external
 * perceivers (e.g. Perception Engine auto-push).
 */
async function waitForCompletion(
  page: Parameters<Parameters<typeof test>[1]>[0]['page'],
  expectedSteps: number,
  timeoutMs = 5000
): Promise<void> {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const resp = await page.request.get(`${PERCEPTUAL_API_URL}/api/perceptual-simulation/state`);
    if (resp.ok()) {
      const body = await resp.json();
      const running: boolean = body.state?.isRunning ?? true;
      const step: number = body.state?.currentStep ?? 0;
      if (!running && step >= expectedSteps) return;
    }
    await page.waitForTimeout(100);
  }
}

/** Fetch the current perceptual space vector. */
async function getPerceptualSpace(page: Parameters<Parameters<typeof test>[1]>[0]['page']): Promise<number[]> {
  const resp = await page.request.get(`${PERCEPTUAL_API_URL}/api/perceptual-simulation/state`);
  expect(resp.ok()).toBeTruthy();
  const body = await resp.json();
  return body.state?.perceptualSpace ?? [];
}

// ---------------------------------------------------------------------------

test.describe('Multi-Step State Machine - Output Workflow', () => {
  let perceptionEngineWasRunning = false;
  let perceptionEngineIntervalMs = 1000;

  test.beforeEach(async ({ page }) => {
    // Stop perception engine auto-push so it cannot corrupt perceptual space
    // during simulation steps. Capture current state so we can restore it.
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
    // Restore perception engine auto-push state
    if (perceptionEngineWasRunning) {
      try {
        await page.request.post(`${PERCEPTION_ENGINE_URL}/api/auto/start`, {
          data: { intervalMs: perceptionEngineIntervalMs }
        });
      } catch { /* ignore */ }
    }
  });

  // =========================================================================
  // Test 1: Full output workflow — both sequences → RS flip-flop RESET and SET
  // =========================================================================
  test('should complete full output workflow: Seq1→RESET and Seq2→SET via RS flip-flops', async ({ page }) => {
    test.setTimeout(120000);

    // ── Load machines ──────────────────────────────────────────────────────
    await test.step('Load Multi-Step, RS2, and RSFlipFlop machines', async () => {
      console.log('Step 1: Loading machines via API...');
      await loadMachines(page);
      await page.waitForTimeout(1000);
      console.log('  ✓ All three machines loaded');
    });

    // ── Sequence 1 (000→001→011 → [0,1]) — RESET ──────────────────────────
    await test.step('Run Sequence 1 (000→001→011) and verify RESET state in RS flip-flops', async () => {
      console.log('Step 2: Configuring Sequence 1 (RESET path)...');

      //  3 sequence steps + 1 probe step so RS machines can observe output.
      //  Probe input [0,0,0] does not advance Seq1 again (ms-seq1-001 is not
      //  yet active on a fresh run so the probe's re-match of ms-seq1-000 is
      //  harmless — it only re-activates the first transition step).
      const seq1Inputs: number[][] = [
        [0, 0, 0],   // ms-seq1-000 matches → ms-seq1-001 activated
        [0, 0, 1],   // ms-seq1-001 matches → ms-seq1-011 activated
        [0, 1, 1],   // ms-seq1-011 matches → Multi-Step outputs [0,1] to [3:5]
        [0, 0, 0],   // probe: RS2 and RSFlipFlop observe [3:5]=[0,1] and latch
      ];

      await configureSim(page, seq1Inputs);

      // Steps 1–3: progress through the sequence
      for (let i = 1; i <= 3; i++) {
        await stepSim(page);
        console.log(`  Step ${i}: completed`);
      }

      // After step 3 Multi-Step has merged [0,1] into [3:5]
      const afterSeq1Complete = await getPerceptualSpace(page);
      const multiStepOut1 = afterSeq1Complete.slice(3, 5);
      console.log(`  Multi-Step output [3:5] after Seq1 match = [${multiStepOut1}]`);
      expect(multiStepOut1).toEqual([0, 1]);
      console.log('  ✓ Multi-Step Sequence 1 output verified: [0,1]');

      // Step 4: probe — RS machines observe [0,1] and produce RESET output
      const probeResp = await page.request.post(`${PERCEPTUAL_API_URL}/api/perceptual-simulation/step`);
      const probeBody = await probeResp.json();
      console.log('  Step 4 (probe): completed');

      // Debug: show which machines are in the simulator and their outputs
      const stateForDebug = await (await page.request.get(`${PERCEPTUAL_API_URL}/api/perceptual-simulation/state`)).json();
      const machinesDebug = stateForDebug.state?.machines ?? [];
      console.log(`  Machines in simulator (${machinesDebug.length}):`);
      machinesDebug.forEach((m: any) => console.log(`    [${m.name}] in:[${m.perceptualMapping?.input.offset}:${m.perceptualMapping?.input.offset + m.perceptualMapping?.input.length}] out:[${m.perceptualMapping?.output.offset}:${m.perceptualMapping?.output.offset + m.perceptualMapping?.output.length}]`));

      // Debug: show each RS2 machine's output in the probe step
      const probeResults = probeBody.step?.machineResults ?? {};
      let loggedRS2 = 0;
      Object.entries(probeResults).forEach(([id, r]: [string, any]) => {
        if (r.machineName.includes('RS2') && loggedRS2++ < 3) {
          const shouldOut = r.transitionResult?.arbiterMetadata?.shouldOutput;
          const outVec = r.outputVector;
          const inputVec = r.inputVector;
          console.log(`  RS2 (${id.slice(0,8)}): input=[${inputVec}] shouldOutput=${shouldOut}, outputVector=[${outVec}]`);
        }
      });

      const afterProbe1 = stateForDebug.state?.perceptualSpace ?? [];
      const rsFlipFlopOut1 = afterProbe1.slice(6, 8);
      const rs2Out1        = afterProbe1.slice(8, 10);

      console.log(`  RSFlipFlop output [6:8]  = [${rsFlipFlopOut1}]`);
      console.log(`  RS2       output [8:10]  = [${rs2Out1}]`);

      expect(rsFlipFlopOut1).toEqual([0, 1]);
      expect(rs2Out1).toEqual([0, 1]);
      console.log('  ✓ RS flip-flops verified in RESET state: Q=0, Q̄=1');
    });

    // ── Sequence 2 (100→101→111 → [1,0]) — SET ────────────────────────────
    await test.step('Run Sequence 2 (100→101→111) and verify SET state in RS flip-flops', async () => {
      console.log('Step 3: Configuring Sequence 2 (SET path)...');

      // No neutral step: Seq2 starts directly with [1,0,0].
      // RS2 sees [3:5]=[0,0] for exactly 3 steps (odd) before the probe,
      // so rs2-set-10 is ACTIVE when the probe arrives with [3:5]=[1,0].
      const seq2Inputs: number[][] = [
        [1, 0, 0],   // ms-seq2-100 matches → ms-seq2-101 activated
        [1, 0, 1],   // ms-seq2-101 matches → ms-seq2-111 activated
        [1, 1, 1],   // ms-seq2-111 matches → Multi-Step outputs [1,0] to [3:5]
        [0, 0, 0],   // probe: RS2 and RSFlipFlop observe [3:5]=[1,0] and latch
      ];

      await configureSim(page, seq2Inputs);

      // Steps 1–3: progress through the MultiStep sequence
      for (let i = 1; i <= 3; i++) {
        await stepSim(page);
        console.log(`  Step ${i}: completed`);
      }

      // After step 3 Multi-Step has merged [1,0] into [3:5]
      const afterSeq2Complete = await getPerceptualSpace(page);
      const multiStepOut2 = afterSeq2Complete.slice(3, 5);
      console.log(`  Multi-Step output [3:5] after Seq2 match = [${multiStepOut2}]`);
      expect(multiStepOut2).toEqual([1, 0]);
      console.log('  ✓ Multi-Step Sequence 2 output verified: [1,0]');

      // Step 4: probe
      await stepSim(page);
      console.log('  Step 4 (probe): completed');

      const afterProbe2 = await getPerceptualSpace(page);
      const rsFlipFlopOut2 = afterProbe2.slice(6, 8);
      const rs2Out2        = afterProbe2.slice(8, 10);

      console.log(`  RSFlipFlop output [6:8]  = [${rsFlipFlopOut2}]`);
      console.log(`  RS2       output [8:10]  = [${rs2Out2}]`);

      expect(rsFlipFlopOut2).toEqual([1, 0]);
      expect(rs2Out2).toEqual([1, 0]);
      console.log('  ✓ RS flip-flops verified in SET state: Q=1, Q̄=0');
    });

    // ── Verify complete perceptual space ───────────────────────────────────
    await test.step('Verify complete perceptual space layout after SET', async () => {
      console.log('Step 4: Verifying complete perceptual space layout...');

      const space = await getPerceptualSpace(page);

      console.log('  Final Perceptual Space State (after Seq2 SET):');
      console.log(`    Multi-Step input  [0:3]:   [${space.slice(0, 3)}]`);
      console.log(`    Multi-Step output [3:5]:   [${space.slice(3, 5)}]`);
      console.log(`    RSFlipFlop output [6:8]:   [${space.slice(6, 8)}]`);
      console.log(`    RS2       output  [8:10]:  [${space.slice(8, 10)}]`);

      // After probe step the input region holds the probe vector [0,0,0]
      expect(space.slice(3, 5)).toEqual([1, 0]);   // Multi-Step output persists
      expect(space.slice(6, 8)).toEqual([1, 0]);   // RSFlipFlop SET
      expect(space.slice(8, 10)).toEqual([1, 0]);  // RS2 SET

      console.log('  ✓ Complete perceptual space layout verified');
    });

    console.log('\n✅ Full output workflow test completed successfully!');
  });

  // =========================================================================
  // Test 2: Output metadata and formatting
  // =========================================================================
  test('should verify output vector metadata and formatting from each Multi-Step sequence', async ({ page }) => {
    test.setTimeout(60000);

    await test.step('Load machines', async () => {
      await loadMachines(page);
      await page.waitForTimeout(1000);
    });

    // ── Sequence 1 metadata ────────────────────────────────────────────────
    await test.step('Verify output metadata for Sequence 1 (000→001→011→[0,1])', async () => {
      console.log('Verifying Sequence 1 metadata...');

      await configureSim(page, [
        [0, 0, 0],
        [0, 0, 1],
        [0, 1, 1],  // terminal — step response includes machineOutput with metadata
      ]);

      await stepSim(page);  // step 1
      await stepSim(page);  // step 2

      // Step 3 is the terminal match — check the full step response
      const terminalResp = await page.request.post(`${PERCEPTUAL_API_URL}/api/perceptual-simulation/step`);
      expect(terminalResp.ok()).toBeTruthy();
      const terminalBody = await terminalResp.json();

      expect(terminalBody.success).toBeTruthy();
      expect(terminalBody.step).toBeDefined();

      // Find the Multi-Step machine in machineResults (keyed by machine ID)
      const machineResults = terminalBody.step.machineResults;
      const multiStepEntry = Object.values(machineResults).find(
        (entry: any) => entry.machineName === 'Multi-Step State Machine'
      ) as any;

      expect(multiStepEntry).toBeDefined();
      console.log(`  Multi-Step machineName: ${multiStepEntry.machineName}`);

      // The representative output vector (from machineResults entry) should be [0,1]
      expect(multiStepEntry.outputVector).toEqual([0, 1]);
      console.log(`  ✓ Output vector format: [${multiStepEntry.outputVector}]`);

      // The arbiter's combined machineOutput is a plain OutputVector — serialises correctly.
      // (sequenceResults is a Map and becomes {} in JSON; use machineOutput instead.)
      const machineOutput = multiStepEntry.transitionResult?.machineOutput;
      expect(machineOutput).toBeDefined();
      expect(machineOutput.vector).toEqual([0, 1]);

      // machineOutput.metadata.descriptions collects the description from each
      // contributing OutputVector (here: "Sequence 1 complete: output [0,1]").
      const descriptions: string[] = machineOutput.metadata?.descriptions ?? [];
      console.log(`  ✓ machineOutput descriptions: ${JSON.stringify(descriptions)}`);
      expect(descriptions.length).toBeGreaterThan(0);

      const foundSeq1Desc = descriptions.some(
        (d: string) => d.includes('Sequence 1') && d.includes('[0,1]')
      );
      expect(foundSeq1Desc).toBeTruthy();
      console.log('  ✓ Sequence 1 description verified: contains "Sequence 1" and "[0,1]"');

      // Verify the arbiter metadata
      const arbiterMeta = multiStepEntry.transitionResult?.arbiterMetadata;
      expect(arbiterMeta?.shouldOutput).toBe(true);
      expect(arbiterMeta?.sequencesWithOutput).toBeGreaterThan(0);
      console.log(`  ✓ Arbiter: shouldOutput=${arbiterMeta?.shouldOutput}, sequencesWithOutput=${arbiterMeta?.sequencesWithOutput}`);

      console.log('  ✓ Sequence 1 output metadata verified');
    });

    // ── Sequence 2 metadata ────────────────────────────────────────────────
    await test.step('Verify output metadata for Sequence 2 (100→101→111→[1,0])', async () => {
      console.log('Verifying Sequence 2 metadata...');

      await configureSim(page, [
        [0, 0, 0],
        [1, 0, 0],
        [1, 0, 1],
        [1, 1, 1],  // terminal — step response includes machineOutput with metadata
      ]);

      await stepSim(page);  // step 1
      await stepSim(page);  // step 2
      await stepSim(page);  // step 3

      // Step 4 is the terminal match
      const terminalResp = await page.request.post(`${PERCEPTUAL_API_URL}/api/perceptual-simulation/step`);
      expect(terminalResp.ok()).toBeTruthy();
      const terminalBody = await terminalResp.json();

      const machineResults = terminalBody.step.machineResults;
      const multiStepEntry = Object.values(machineResults).find(
        (entry: any) => entry.machineName === 'Multi-Step State Machine'
      ) as any;

      expect(multiStepEntry).toBeDefined();

      expect(multiStepEntry.outputVector).toEqual([1, 0]);
      console.log(`  ✓ Output vector format: [${multiStepEntry.outputVector}]`);

      const machineOutput = multiStepEntry.transitionResult?.machineOutput;
      expect(machineOutput).toBeDefined();
      expect(machineOutput.vector).toEqual([1, 0]);

      const descriptions: string[] = machineOutput.metadata?.descriptions ?? [];
      console.log(`  ✓ machineOutput descriptions: ${JSON.stringify(descriptions)}`);
      expect(descriptions.length).toBeGreaterThan(0);

      const foundSeq2Desc = descriptions.some(
        (d: string) => d.includes('Sequence 2') && d.includes('[1,0]')
      );
      expect(foundSeq2Desc).toBeTruthy();
      console.log('  ✓ Sequence 2 description verified: contains "Sequence 2" and "[1,0]"');

      const arbiterMeta = multiStepEntry.transitionResult?.arbiterMetadata;
      expect(arbiterMeta?.shouldOutput).toBe(true);
      console.log(`  ✓ Arbiter: shouldOutput=${arbiterMeta?.shouldOutput}`);

      console.log('  ✓ Sequence 2 output metadata verified');
    });

    console.log('\n✅ Output metadata test completed successfully!');
  });

  // =========================================================================
  // Test 3: Auto-play through both sequences (two separate configure+run cycles)
  // =========================================================================
  /**
   * RS2 is a two-step machine: its non-initial vectors (rs2-set-10, rs2-reset-01)
   * must be activated by the hold state [0,0] in one cycle before they can match
   * [1,0] or [0,1] in the next.  After Multi-Step writes [0,1] to [3:5] during
   * Seq1, [3:5] remains [0,1] until either a fresh configure() or another
   * Multi-Step terminal output — there is no intermediate [0,0] for RS2 to
   * re-arm on the SET path within a single run.
   *
   * Therefore we use two separate configure+auto-play cycles (identical to the
   * manual-step approach in Test 1).  This correctly exercises auto-play
   * functionality while respecting RS2's timing requirement.
   */
  test('should execute both sequences via auto-play and verify RS flip-flop state', async ({ page }) => {
    test.setTimeout(60000);

    await test.step('Load machines', async () => {
      await loadMachines(page);
      await page.waitForTimeout(1000);
    });

    // ── Auto-play Seq1 (RESET path) ────────────────────────────────────────
    await test.step('Auto-play Sequence 1 (000→001→011) and verify RESET state', async () => {
      console.log('Configuring auto-play for Sequence 1 (RESET)...');

      const seq1Inputs: number[][] = [
        [0, 0, 0],   // ms-seq1-000 matches → ms-seq1-001 activated
        [0, 0, 1],   // ms-seq1-001 matches → ms-seq1-011 activated
        [0, 1, 1],   // ms-seq1-011 matches → [3:5]=[0,1]
        [0, 0, 0],   // probe: RS machines observe [0,1] → RESET
      ];

      // 200 ms/step; maxSteps=4 ensures simulation stops after probe
      await configureSim(page, seq1Inputs, 200);
      console.log(`  ✓ Configured with ${seq1Inputs.length} steps at 200 ms/step`);

      // Start auto-play
      const startResp = await page.request.post(`${PERCEPTUAL_API_URL}/api/perceptual-simulation/start`);
      expect(startResp.ok()).toBeTruthy();
      expect((await startResp.json()).success).toBeTruthy();
      console.log('  ✓ Auto-play started');

      // Poll until complete (4 steps × 200 ms = 800 ms minimum)
      await waitForCompletion(page, 4, 5000);

      // Verify completion
      const stateBody = await (await page.request.get(`${PERCEPTUAL_API_URL}/api/perceptual-simulation/state`)).json();
      const step1: number = stateBody.state?.currentStep ?? -1;
      const running1: boolean = stateBody.state?.isRunning ?? true;
      console.log(`  Current step: ${step1}, isRunning: ${running1}`);
      expect(running1).toBe(false);
      expect(step1).toBe(4);
      console.log('  ✓ Auto-play completed all 4 steps');

      // Verify RESET state
      const space1 = await getPerceptualSpace(page);
      console.log('  Perceptual Space after Seq1 auto-play:');
      console.log(`    Multi-Step output [3:5]:   [${space1.slice(3, 5)}]`);
      console.log(`    RSFlipFlop output [6:8]:   [${space1.slice(6, 8)}]`);
      console.log(`    RS2       output  [8:10]:  [${space1.slice(8, 10)}]`);

      expect(space1.slice(3, 5)).toEqual([0, 1]);   // Multi-Step output [0,1]
      expect(space1.slice(6, 8)).toEqual([0, 1]);   // RSFlipFlop RESET
      expect(space1.slice(8, 10)).toEqual([0, 1]);  // RS2 RESET
      console.log('  ✓ RS flip-flops verified in RESET state');
    });

    // ── Auto-play Seq2 (SET path) ──────────────────────────────────────────
    await test.step('Auto-play Sequence 2 (100→101→111) and verify SET state', async () => {
      console.log('Configuring auto-play for Sequence 2 (SET)...');

      // configure() resets perceptual space and all machines to initial state.
      // No neutral step: Seq2 starts directly with [1,0,0] so RS2 sees [0,0]
      // exactly 3 times (odd) before the probe, keeping rs2-set-10 ACTIVE.
      const seq2Inputs: number[][] = [
        [1, 0, 0],   // ms-seq2-100 matches → ms-seq2-101 activated
        [1, 0, 1],   // ms-seq2-101 matches → ms-seq2-111 activated
        [1, 1, 1],   // ms-seq2-111 matches → [3:5]=[1,0]
        [0, 0, 0],   // probe: RS machines observe [1,0] → SET
      ];

      await configureSim(page, seq2Inputs, 200);
      console.log(`  ✓ Configured with ${seq2Inputs.length} steps at 200 ms/step`);

      // Start auto-play
      const startResp = await page.request.post(`${PERCEPTUAL_API_URL}/api/perceptual-simulation/start`);
      expect(startResp.ok()).toBeTruthy();
      expect((await startResp.json()).success).toBeTruthy();
      console.log('  ✓ Auto-play started');

      // Poll until complete (4 steps × 200 ms = 800 ms minimum)
      await waitForCompletion(page, 4, 5000);

      // Verify completion
      const stateBody = await (await page.request.get(`${PERCEPTUAL_API_URL}/api/perceptual-simulation/state`)).json();
      const step2: number = stateBody.state?.currentStep ?? -1;
      const running2: boolean = stateBody.state?.isRunning ?? true;
      console.log(`  Current step: ${step2}, isRunning: ${running2}`);
      expect(running2).toBe(false);
      expect(step2).toBe(4);
      console.log('  ✓ Auto-play completed all 4 steps');

      // Verify SET state
      const space2 = await getPerceptualSpace(page);
      console.log('  Final Perceptual Space State after Seq2 auto-play:');
      console.log(`    Multi-Step input  [0:3]:   [${space2.slice(0, 3)}]`);
      console.log(`    Multi-Step output [3:5]:   [${space2.slice(3, 5)}]`);
      console.log(`    RSFlipFlop output [6:8]:   [${space2.slice(6, 8)}]`);
      console.log(`    RS2       output  [8:10]:  [${space2.slice(8, 10)}]`);

      expect(space2.slice(3, 5)).toEqual([1, 0]);   // Multi-Step output persists
      expect(space2.slice(6, 8)).toEqual([1, 0]);   // RSFlipFlop SET
      expect(space2.slice(8, 10)).toEqual([1, 0]);  // RS2 SET
      console.log('  ✓ RS flip-flops verified in SET state');
    });

    // ── Verify simulation history ──────────────────────────────────────────
    await test.step('Verify simulation history records the 4 Seq2 steps', async () => {
      console.log('Checking simulation history...');

      const histResp = await page.request.get(`${PERCEPTUAL_API_URL}/api/perceptual-simulation/history`);
      expect(histResp.ok()).toBeTruthy();
      const history: any[] = (await histResp.json()).history ?? [];

      // configure() resets history; only the last (Seq2) run contributes
      console.log(`  Steps in history: ${history.length}`);
      expect(history.length).toBe(4);
      console.log('  ✓ Simulation history complete (4 steps for Seq2 auto-play)');
    });

    console.log('\n✅ Auto-play two-cycle test completed successfully!');
  });
});

// ===========================================================================
// API Verification — legacy sequence structure (unchanged)
// ===========================================================================
test.describe('Multi-Step State Machine - API Verification', () => {
  test('should verify sequences are correctly loaded via API', async ({ request }) => {
    console.log('Verifying Multi-Step sequences via API...');

    const sequencesResponse = await request.get(`${API_URL}/api/sequences`);
    expect(sequencesResponse.ok()).toBeTruthy();

    const sequencesData = await sequencesResponse.json();
    const sequences = sequencesData.sequences || [];

    const multiStepSequences = sequences.filter((seq: any) =>
      seq.name &&
      (seq.name.includes('Sequence 1') || seq.name.includes('Sequence 2'))
    );

    expect(multiStepSequences.length).toBeGreaterThanOrEqual(2);

    const seq1 = multiStepSequences.find((s: any) => s.name.includes('Sequence 1'));
    expect(seq1).toBeDefined();
    expect(seq1.name).toContain('Sequence 1');
    expect(seq1.vectors).toBeDefined();
    console.log('✓ Sequence 1 verified:', seq1.name);

    const seq2 = multiStepSequences.find((s: any) => s.name.includes('Sequence 2'));
    expect(seq2).toBeDefined();
    expect(seq2.name).toContain('Sequence 2');
    expect(seq2.vectors).toBeDefined();
    console.log('✓ Sequence 2 verified:', seq2.name);

    console.log('✅ API verification complete');
  });
});
