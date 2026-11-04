// The output-actor and its synthetic body (scripts/lib/openclaw-adapter.mjs).
//
// When a handoff's target agent has a generated spec, the adapter is that
// agent's output-actor: its completion travels the agent's own write-back route
// back into the perceptual space, carrying the model's answer or, per the
// agent's syntheticBody, a synthetic one. The selection must agree exactly with
// localOpenClawStack's synthetic_body.py, so the vectors below were computed by
// that implementation and are pinned here.
import test from 'node:test';
import assert from 'node:assert/strict';

import {
  actorRoute,
  executeOpenClawAdapter,
  resolveSynthetic,
  responseFieldValues,
  selectSynthetic
} from '../lib/openclaw-adapter.mjs';

// ── a generated-agent-shaped spec ────────────────────────────────────────────
const RESPONSES = [
  { id: 's0#0', values: [0.0, 1.0], expectedSequenceId: 'ces0', inputSequence: 's0', step: 0 },
  { id: 's0#1', values: [0.1, 0.9], expectedSequenceId: null, inputSequence: 's0', step: 1 },
  { id: 's1#0', values: [0.2, 0.8], expectedSequenceId: 'ces1', inputSequence: 's1', step: 0 },
  { id: 's1#1', values: [0.3, 0.7], expectedSequenceId: null, inputSequence: 's1', step: 1 },
  { id: 's2#0', values: [0.4, 0.6], expectedSequenceId: 'ces2', inputSequence: 's2', step: 0 }
];
const field = (key, index) => ({
  semantic: key, valueType: 'scalar', normalization: 'scalar-0-1',
  extract: { jsonPointer: `/${key}`, responseKey: key },
  target: { sensorId: 'acp.openclaw.vector.input-analyst.assessment', region: { offset: 900, length: 2 }, index }
});
const SPEC = {
  agentId: 'vector-agent',
  machine: { domain: 'test-domain' },
  agentBinding: {
    writeBack: {
      type: 'pe-sensor', provider: 'acp', sensorId: 'acp.openclaw.vector.input-analyst.assessment',
      name: 'vector assessment', region: { offset: 900, length: 2 }, ttlMs: 120000,
      ingest: { triggerPush: false, compactPush: true }
    }
  },
  responseMapping: { fields: [field('axis_a', 0), field('axis_b', 1)] },
  syntheticBody: {
    mode: 'off', strategy: 'seeded-random', source: 'corpus-inputSequences',
    ordinality: RESPONSES.length, responses: RESPONSES, roundRobin: ['s0#0', 's1#0', 's2#0']
  }
};

// Computed by synthetic_body.select on the same spec.
const PY_SEEDED = {
  'corr-0': 's1#0', 'corr-1': 's0#1', 'corr-2': 's1#1', 'dispatch-abc': 's1#1', 7: 's0#1',
  '': 's1#1', ['x'.repeat(40)]: 's0#0', 'ünïcode': 's0#0'
};
const PY_ROUND_ROBIN = ['s0#0', 's1#0', 's2#0', 's0#0', 's1#0', 's2#0', 's0#0'];
const PY_WALK = ['s0#0', 's0#1', 's1#0', 's1#1', 's2#0', 's0#0', 's0#1'];

test('seeded-random picks exactly what synthetic_body.py picks', () => {
  for (const [key, expected] of Object.entries(PY_SEEDED)) {
    assert.equal(selectSynthetic(SPEC, { strategy: 'seeded-random', seedKey: key, step: 0 }).provenance.responseId,
      expected, `seed key ${JSON.stringify(key)}`);
  }
});

test('round-robin and sequence-walk follow synthetic_body.py step for step', () => {
  assert.deepEqual(PY_ROUND_ROBIN.map((_, step) => selectSynthetic(SPEC, { strategy: 'round-robin', step }).provenance.responseId), PY_ROUND_ROBIN);
  assert.deepEqual(PY_WALK.map((_, step) => selectSynthetic(SPEC, { strategy: 'sequence-walk', step }).provenance.responseId), PY_WALK);
});

test('ordinality 1 gives the only admissible answer under every strategy', () => {
  const one = { ...SPEC, syntheticBody: { ...SPEC.syntheticBody, responses: [RESPONSES[2]], ordinality: 1 } };
  for (const strategy of ['seeded-random', 'round-robin', 'sequence-walk']) {
    const pick = selectSynthetic(one, { strategy, step: 3, seedKey: 'k' });
    assert.equal(pick.provenance.responseId, 's1#0');
    assert.equal(pick.provenance.strategy, 'only-admissible');
  }
});

test('mode and strategy resolve env > domain > global > agent, and refuse unknowns', () => {
  const config = { syntheticBody: { mode: 'fallback', strategy: 'round-robin', domains: { 'test-domain': { mode: 'always' } } } };
  assert.deepEqual(resolveSynthetic(SPEC, config, {}), { mode: 'always', strategy: 'round-robin' });
  assert.deepEqual(resolveSynthetic(SPEC, config, { OC_SYNTHETIC_MODE: 'off', OC_SYNTHETIC_STRATEGY: 'sequence-walk' }),
    { mode: 'off', strategy: 'sequence-walk' });
  assert.deepEqual(resolveSynthetic(SPEC, {}, {}), { mode: 'off', strategy: 'seeded-random' });
  assert.throws(() => resolveSynthetic(SPEC, { syntheticBody: { mode: 'sometimes' } }, {}), /not one of/);
});

test('the actor route is the agent write-back, and field-keyed answers fill it by index', () => {
  assert.deepEqual(actorRoute(SPEC), {
    sensorId: 'acp.openclaw.vector.input-analyst.assessment', name: 'vector assessment',
    region: { offset: 900, length: 2 }, ttlMs: 120000, triggerPush: false, compactPush: true
  });
  assert.deepEqual(responseFieldValues('{"axis_b": 0.25, "axis_a": 0.75}', SPEC), [0.75, 0.25]);
  assert.equal(responseFieldValues('{"axis_a": 0.75}', SPEC), undefined, 'a missing field leaves it unresolved');
  assert.equal(responseFieldValues('{"axis_a": 3, "axis_b": 0}', SPEC), undefined, 'out of range is unresolved');
  assert.equal(responseFieldValues('pain is moderate', SPEC), undefined, 'prose is unresolved');
});

// ── end to end against a mocked gateway and PE ──────────────────────────────
const HANDOFF = { dispatchId: 'd-1', correlationId: 'corr-0', envelopeId: 'e-1', targetAgent: 'vector-agent',
  completionEndpoint: '/api/integrations/completions', completionSourceMappingId: 'acp-vector-input-assessment' };

function jsonResponse(body, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } });
}

async function run({ synthetic, gateway }) {
  const calls = { gateway: 0, completions: [], patches: [] };
  const original = globalThis.fetch;
  globalThis.fetch = async (url, options) => {
    if (options.method === 'PATCH') { calls.patches.push(JSON.parse(options.body)); return jsonResponse({ ok: true }); }
    if (String(url).endsWith('/v1/chat/completions')) { calls.gateway += 1; return gateway(); }
    calls.completions.push(JSON.parse(options.body));
    return jsonResponse({ success: true });
  };
  try {
    const result = await executeOpenClawAdapter({
      handoff: HANDOFF, peUrl: 'http://pe.test', gatewayUrl: 'http://gateway.test', model: 'mock',
      fallbackValues: [1, 0, 0.95, 0], agentSpec: SPEC, synthetic
    });
    return { result, calls };
  } catch (error) {
    error.calls = calls;
    throw error;
  } finally {
    globalThis.fetch = original;
  }
}
const answer = (content) => () => jsonResponse({ id: 'run-1', choices: [{ message: { content } }] });

test('always: the model is never called; the synthetic answer travels the actor route, labelled', async () => {
  const { result, calls } = await run({ synthetic: { mode: 'always', strategy: 'seeded-random' }, gateway: answer('{}') });
  assert.equal(calls.gateway, 0);
  const body = calls.completions[0];
  assert.equal(body.sourceMappingId, undefined, 'no registered mapping: the actor carries its route');
  assert.equal(body.sensorId, 'acp.openclaw.vector.input-analyst.assessment');
  assert.deepEqual(body.region, { offset: 900, length: 2 });
  assert.equal(body.ttlMs, 120000);
  assert.deepEqual(body.values, [0.2, 0.8], 'corr-0 seeds s1#0, as synthetic_body.py picks');
  assert.equal(body.metadata.synthetic, true);
  assert.equal(body.metadata.syntheticBody.responseId, 's1#0');
  assert.equal(body.metadata.model, null);
  assert.equal(result.synthetic.mode, 'always');
  assert.deepEqual(calls.patches.map((p) => p.status), ['running', 'completed']);
  assert.equal(calls.patches[1].metadata.synthetic, true);
});

test('fallback: an unreachable gateway is answered synthetically, and says what it replaced', async () => {
  const { calls } = await run({ synthetic: { mode: 'fallback', strategy: 'seeded-random' },
    gateway: () => { throw new TypeError('fetch failed'); } });
  const body = calls.completions[0];
  assert.equal(body.metadata.synthetic, true);
  assert.match(body.metadata.syntheticBody.replaced, /model turn failed/);
  assert.deepEqual(body.region, { offset: 900, length: 2 });
});

test('fallback: an unmappable answer is replaced; a mappable one is delivered as the model gave it', async () => {
  const replaced = await run({ synthetic: { mode: 'fallback', strategy: 'round-robin' }, gateway: answer('it looks moderate') });
  assert.equal(replaced.calls.completions[0].metadata.synthetic, true);
  assert.match(replaced.calls.completions[0].metadata.syntheticBody.replaced, /did not resolve/);

  const real = await run({ synthetic: { mode: 'fallback', strategy: 'round-robin' }, gateway: answer('{"axis_a": 0.6, "axis_b": 0.1}') });
  const body = real.calls.completions[0];
  assert.deepEqual(body.values, [0.6, 0.1]);
  assert.equal(body.metadata.synthetic, undefined);
  assert.equal(body.metadata.model, 'mock');
  assert.equal(body.sensorId, 'acp.openclaw.vector.input-analyst.assessment', 'a real answer travels the same route');
  assert.equal(real.result.synthetic, null);
});

test('a values array of the write-back length is a real answer too', async () => {
  const { calls } = await run({ synthetic: { mode: 'fallback', strategy: 'seeded-random' }, gateway: answer('{"values": [0.9, 0.05]}') });
  assert.deepEqual(calls.completions[0].values, [0.9, 0.05]);
  assert.equal(calls.completions[0].metadata.synthetic, undefined);
});

test('off: an unmappable answer is not substituted — no completion, dispatch failed', async () => {
  await assert.rejects(
    run({ synthetic: { mode: 'off', strategy: 'seeded-random' }, gateway: answer('{"values": [1, 0, 0.95, 0]}') }),
    (error) => {
      assert.match(error.message, /synthetic body is off/);
      assert.equal(error.calls.completions.length, 0, 'the fixed 4-value fallback is not written for this agent');
      assert.deepEqual(error.calls.patches.map((p) => p.status), ['running', 'failed']);
      return true;
    }
  );
});
