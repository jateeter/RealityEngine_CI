// The synthetic action answer in the OpenClaw ACP adapter.
//
// Selection, the admissible set and the override order are pinned to vectors
// computed by localOpenClawStack's machine-behaviors/synthetic_body.py
// (fixtures/synthetic-action-vectors.json), so the adapter and the Python
// action path choose the same answer for the same dispatch. The end-to-end
// cases drive executeOpenClawAdapter through a stubbed fetch: no server, no
// socket, no plaintext URL.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';

import {
  actionAnswerValues,
  admissibleActionAnswers,
  executeOpenClawAdapter,
  resolveSynthetic,
  selectActionAnswer
} from '../lib/openclaw-adapter.mjs';

const vectors = JSON.parse(readFileSync(new URL('./fixtures/synthetic-action-vectors.json', import.meta.url), 'utf8'));
const PE = 'https://pe.test';
const GATEWAY = 'https://gateway.test';

test('the admissible answers and lane values match the Python body for every mode and RAG status', () => {
  for (const [key, expected] of Object.entries(vectors.admissible)) {
    const [mode, rag, withControls] = key.split('|');
    const controls = withControls ? { blockedWhenRag: ['GREEN'] } : undefined;
    assert.deepEqual(admissibleActionAnswers(mode, rag, controls), expected, key);
  }
});

test('seeded-random selection matches the Python body', () => {
  const answers = admissibleActionAnswers('supervised-act', 'GREEN');
  for (const v of vectors.seeded) {
    const chosen = selectActionAnswer(answers, { agent: v.agent, strategy: 'seeded-random', seedKey: v.seedKey, step: v.step });
    assert.equal(chosen.provenance.answerIndex, v.index, `${v.agent}|${v.seedKey}`);
    assert.deepEqual(chosen.provenance, v.provenance);
  }
});

test('round-robin and a single admissible answer match the Python body', () => {
  const answers = admissibleActionAnswers('supervised-act', 'GREEN');
  for (const v of vectors.roundRobin) {
    assert.deepEqual(selectActionAnswer(answers, { agent: 'a', strategy: 'round-robin', step: v.step }).provenance, v.provenance);
  }
  assert.deepEqual(
    selectActionAnswer(answers.slice(0, 1), { agent: 'a', strategy: 'seeded-random', seedKey: 'x' }).provenance,
    vectors.single.provenance
  );
});

test('observe admits no answer, and selecting from none refuses', () => {
  assert.deepEqual(admissibleActionAnswers('observe', ''), []);
  assert.throws(() => selectActionAnswer([], { strategy: 'seeded-random' }), /observe mode writes no vector/);
});

test('mode and strategy resolve in the Python order: environment, domain, global', () => {
  for (const c of vectors.resolve) {
    assert.deepEqual(resolveSynthetic(c.config, c.domain, c.env), c.result, JSON.stringify(c));
  }
  assert.throws(() => resolveSynthetic({ syntheticBody: { mode: 'sometimes' } }, '', {}), /not one of off, fallback, always/);
});

test('a real action answer is read onto the lane; a blocked one posts actionClass 0', () => {
  assert.deepEqual(actionAnswerValues('{"verdict":"advised","completed":"yes","failed":"no","confidence":"moderate"}'), [1, 0, 0.6, 0.5]);
  assert.deepEqual(actionAnswerValues({ verdict: 'blocked', completed: 'no', failed: 'yes', confidence: 'high' }), [0, 1, 0.9, 0]);
  assert.equal(actionAnswerValues('I think it went fine.'), undefined);
  assert.equal(actionAnswerValues({ verdict: 'advised', completed: 'yes', confidence: 'high' }), undefined);
});

// ── End to end, through a stubbed fetch ──────────────────────────────────────

const envelope = {
  correlationId: 'corr-1',
  dispatch: { autonomyMode: 'supervised-act' },
  governance: { ragStatusCode: 'GREEN' },
  ces: { domain: 'health' }
};
const agent = 'home-chronic-pain-monitor.action';

function stubFetch({ gateway, record } = {}) {
  const calls = [];
  const original = globalThis.fetch;
  globalThis.fetch = async (url, init = {}) => {
    const method = init.method || 'GET';
    const body = init.body ? JSON.parse(init.body) : undefined;
    calls.push({ url: String(url), method, body });
    const json = (status, payload) => new Response(JSON.stringify(payload), { status, headers: { 'content-type': 'application/json' } });
    if (String(url).startsWith(GATEWAY)) {
      if (gateway instanceof Error) throw gateway;
      return json(200, { id: 'chatcmpl-1', choices: [{ message: { content: gateway } }] });
    }
    if (String(url) === `${PE}/api/integrations/completions`) return json(201, { accepted: true });
    if (String(url).startsWith(`${PE}/api/dispatch/records/`)) {
      if (method === 'GET') return record ? json(200, { record }) : json(404, { error: 'not found' });
      return json(200, { ok: true });
    }
    return json(404, { error: `unexpected ${method} ${url}` });
  };
  return { calls, restore: () => { globalThis.fetch = original; } };
}

const run = (handoff, synthetic) => executeOpenClawAdapter({
  handoff: { dispatchId: 'd-1', targetAgent: agent, correlationId: 'corr-1', ...handoff },
  peUrl: PE, gatewayUrl: GATEWAY, model: 'm', fallbackValues: [1, 0, 0.95, 0], timeoutMs: 1000, synthetic
});
const posted = (calls) => calls.find((c) => c.url === `${PE}/api/integrations/completions`)?.body;
const gatewayCalls = (calls) => calls.filter((c) => c.url.startsWith(GATEWAY)).length;
const expectedPick = () => {
  const v = vectors.seeded.find((s) => s.agent === agent && s.seedKey === 'corr-1');
  return vectors.admissible['supervised-act|GREEN'][v.index].values;
};

test('off: the adapter is unchanged — model values, the registered mapping, nothing synthetic', async () => {
  const { calls, restore } = stubFetch({ gateway: '[1, 0, 0.8, 0.5]' });
  try {
    const result = await run({ envelope }, { mode: 'off', strategy: 'seeded-random' });
    const body = posted(calls);
    assert.deepEqual(body.values, [1, 0, 0.8, 0.5]);
    assert.equal(body.sourceMappingId, 'acp-openclaw-completion');
    assert.equal(body.metadata.synthetic, undefined);
    assert.equal(result.synthetic, null);
  } finally { restore(); }
});

test('always: the model is never called, and the labelled answer is the Python pick', async () => {
  const { calls, restore } = stubFetch({ gateway: new Error('must not be called') });
  try {
    const result = await run({ envelope }, { mode: 'always', strategy: 'seeded-random' });
    assert.equal(gatewayCalls(calls), 0);
    const body = posted(calls);
    assert.deepEqual(body.values, expectedPick());
    assert.equal(body.sourceMappingId, 'acp-openclaw-completion');
    assert.equal(body.metadata.synthetic, true);
    assert.equal(body.metadata.model, null);
    assert.equal(body.metadata.syntheticBody.autonomyMode, 'supervised-act');
    assert.equal(body.metadata.syntheticBody.contextFrom, 'handoff');
    assert.equal(result.synthetic.mode, 'always');
    const done = calls.find((c) => c.method === 'PATCH' && c.body.status === 'completed');
    assert.equal(done.body.metadata.synthetic, true);
  } finally { restore(); }
});

test('fallback: an unreachable gateway is replaced, and says why', async () => {
  const { calls, restore } = stubFetch({ gateway: new TypeError('fetch failed') });
  try {
    const result = await run({ envelope }, { mode: 'fallback', strategy: 'seeded-random' });
    assert.deepEqual(posted(calls).values, expectedPick());
    assert.match(result.synthetic.replaced, /^model turn failed: fetch failed/);
  } finally { restore(); }
});

test('fallback: an answer that does not resolve is replaced', async () => {
  const { calls, restore } = stubFetch({ gateway: 'It probably worked.' });
  try {
    const result = await run({ envelope }, { mode: 'fallback', strategy: 'seeded-random' });
    assert.deepEqual(posted(calls).values, expectedPick());
    assert.equal(result.synthetic.replaced, 'model answer did not resolve to the completion lane');
  } finally { restore(); }
});

test('fallback: a resolving real answer is kept — values or the action contract form, blocked included', async () => {
  for (const [content, values] of [
    ['[1, 0, 0.7, 0.75]', [1, 0, 0.7, 0.75]],
    ['{"verdict":"staged","completed":"yes","failed":"no","confidence":"high","review_required":"yes"}', [1, 0, 0.9, 0.75]],
    ['{"verdict":"blocked","completed":"no","failed":"yes","confidence":"low"}', [0, 1, 0.3, 0]]
  ]) {
    const { calls, restore } = stubFetch({ gateway: content });
    try {
      const result = await run({ envelope }, { mode: 'fallback', strategy: 'seeded-random' });
      assert.deepEqual(posted(calls).values, values, content);
      assert.equal(posted(calls).metadata.synthetic, undefined);
      assert.equal(result.synthetic, null);
    } finally { restore(); }
  }
});

test('fallback: a resolving real answer needs no dispatch context', async () => {
  const { calls, restore } = stubFetch({ gateway: '[1, 0, 0.7, 0.75]' });
  try {
    await run({}, { mode: 'fallback', strategy: 'seeded-random' });
    assert.deepEqual(posted(calls).values, [1, 0, 0.7, 0.75]);
    assert.equal(calls.filter((c) => c.method === 'GET').length, 0);
  } finally { restore(); }
});

test('the context comes from the dispatch record when the handoff carries no envelope', async () => {
  const { calls, restore } = stubFetch({ gateway: new Error('unused'), record: { envelope } });
  try {
    const result = await run({}, { mode: 'always', strategy: 'seeded-random' });
    assert.equal(result.synthetic.contextFrom, 'dispatch-record');
    assert.deepEqual(posted(calls).values, expectedPick());
  } finally { restore(); }
});

test('no context: nothing is substituted, and the dispatch is patched failed', async () => {
  const { calls, restore } = stubFetch({ gateway: 'unresolvable' });
  try {
    await assert.rejects(run({}, { mode: 'fallback', strategy: 'seeded-random' }),
      /model answer did not resolve to the completion lane; synthetic body needs the dispatch autonomy mode/);
    assert.equal(posted(calls), undefined);
    assert.ok(calls.some((c) => c.method === 'PATCH' && c.body.status === 'failed'));
  } finally { restore(); }
});

test('an observe dispatch has no synthetic answer: the run fails rather than invent one', async () => {
  const observe = { ...envelope, dispatch: { autonomyMode: 'observe' } };
  const { calls, restore } = stubFetch({ gateway: new Error('unused') });
  try {
    await assert.rejects(run({ envelope: observe }, { mode: 'always', strategy: 'seeded-random' }), /observe mode writes no vector/);
    assert.equal(posted(calls), undefined);
  } finally { restore(); }
});
