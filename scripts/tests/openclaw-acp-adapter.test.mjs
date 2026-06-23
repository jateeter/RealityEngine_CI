import test from 'node:test';
import assert from 'node:assert/strict';

import {
  absoluteCompletionEndpoint,
  buildChatBody,
  completionValues,
  executeOpenClawAdapter,
  httpGatewayUrl,
  jsonValues,
  parseValues,
  tryParseJson
} from '../lib/openclaw-adapter.mjs';


const HANDOFF = {
  dispatchId: 'dispatch-test',
  envelopeId: 'envelope-test',
  correlationId: 'correlation-test',
  targetAgent: 'hello-world',
  completionEndpoint: '/api/integrations/completions',
  completionSourceMappingId: 'acp-openclaw-completion'
};

async function withFetch(mock, callback) {
  const original = globalThis.fetch;
  globalThis.fetch = mock;
  try {
    return await callback();
  } finally {
    globalThis.fetch = original;
  }
}

function jsonResponse(body, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'content-type': 'application/json' }
  });
}


test('normalizes ACP websocket gateway URLs for HTTP API calls', () => {
  assert.equal(httpGatewayUrl('ws://127.0.0.1:18789/'), 'http://127.0.0.1:18789');
  assert.equal(httpGatewayUrl('wss://gateway.example.test/'), 'https://gateway.example.test');
  assert.equal(httpGatewayUrl('http://localhost:18789'), 'http://localhost:18789');
});

test('resolves relative and absolute completion endpoints', () => {
  assert.equal(
    absoluteCompletionEndpoint('http://localhost:5300/', '/api/integrations/completions'),
    'http://localhost:5300/api/integrations/completions'
  );
  assert.equal(
    absoluteCompletionEndpoint('http://localhost:5300', 'https://pe.example.test/completions'),
    'https://pe.example.test/completions'
  );
});

test('parses finite CSV fallback values without dropping invalid entries', () => {
  assert.deepEqual(parseValues('1, 0, 0.95, 0'), [1, 0, 0.95, 0]);
  assert.throws(() => parseValues('1,bad,0,0'), /finite numbers/);
  assert.throws(() => parseValues(''), /non-empty CSV/);
});

test('extracts nested and fenced JSON values', () => {
  assert.deepEqual(tryParseJson('result: {"values":[1,0,0.95,0]}'), { values: [1, 0, 0.95, 0] });
  assert.deepEqual(jsonValues({ completion: { values: ['1', 0, 0.95, 0] } }), [1, 0, 0.95, 0]);
  assert.deepEqual(
    completionValues('{"result":{"values":[1,0,0.95,0]}}', [0, 0, 0, 0]),
    [1, 0, 0.95, 0]
  );
});

test('strict completion parsing rejects fallback and wrong dimensions', () => {
  assert.throws(
    () => completionValues('not json', [1, 0, 0.95, 0], { requireResponseValues: true, expectedLength: 4 }),
    /did not contain/
  );
  assert.throws(
    () => completionValues('{"values":[1,0]}', [], { requireResponseValues: true, expectedLength: 4 }),
    /does not match expected 4/
  );
});

test('chat request preserves handoff correlation fields', () => {
  const handoff = {
    dispatchId: 'dispatch-1',
    envelopeId: 'envelope-1',
    correlationId: 'correlation-1',
    sessionKey: 'agent:main:e2e',
    prompt: 'return values',
    envelope: { event: 'fixture' }
  };
  const body = buildChatBody(handoff, 'hello-world', 'mock-openclaw');
  assert.equal(body.model, 'mock-openclaw');
  assert.equal(body.temperature, 0);
  const userPayload = JSON.parse(body.messages[1].content);
  assert.deepEqual(userPayload, {
    targetAgent: 'hello-world',
    sessionKey: 'agent:main:e2e',
    dispatchId: 'dispatch-1',
    envelopeId: 'envelope-1',
    correlationId: 'correlation-1',
    prompt: 'return values',
    envelope: { event: 'fixture' }
  });
});

test('unauthorized gateway response patches the dispatch record failed', async () => {
  const patches = [];
  await assert.rejects(
    withFetch(async (url, options) => {
      if (options.method === 'PATCH') {
        patches.push(JSON.parse(options.body));
        return jsonResponse({ success: true });
      }
      return jsonResponse({ error: 'unauthorized' }, 401);
    }, () => executeOpenClawAdapter({
      handoff: HANDOFF,
      peUrl: 'http://pe.test',
      gatewayUrl: 'http://gateway.test',
      model: 'mock',
      fallbackValues: [1, 0, 0.95, 0],
      requireResponseValues: true,
      requireDispatchPatch: true
    })),
    /failed with 401/
  );
  assert.deepEqual(patches.map((item) => item.status), ['running', 'failed']);
});

test('malformed strict response cannot fall back to fixed values', async () => {
  const patches = [];
  await assert.rejects(
    withFetch(async (_url, options) => {
      if (options.method === 'PATCH') {
        patches.push(JSON.parse(options.body));
        return jsonResponse({ success: true });
      }
      return jsonResponse({ id: 'run-bad', choices: [{ message: { content: 'not-json' } }] });
    }, () => executeOpenClawAdapter({
      handoff: HANDOFF,
      peUrl: 'http://pe.test',
      gatewayUrl: 'http://gateway.test',
      model: 'mock',
      fallbackValues: [1, 0, 0.95, 0],
      requireResponseValues: true,
      requireDispatchPatch: true
    })),
    /did not contain a numeric values array/
  );
  assert.deepEqual(patches.map((item) => item.status), ['running', 'failed']);
});

test('completion callback failure patches the dispatch record failed', async () => {
  const patches = [];
  await assert.rejects(
    withFetch(async (url, options) => {
      if (options.method === 'PATCH') {
        patches.push(JSON.parse(options.body));
        return jsonResponse({ success: true });
      }
      if (String(url).includes('/v1/chat/completions')) {
        return jsonResponse({ id: 'run-1', choices: [{ message: { content: '{"values":[1,0,0.95,0]}' } }] });
      }
      return jsonResponse({ error: 'completion rejected' }, 500);
    }, () => executeOpenClawAdapter({
      handoff: HANDOFF,
      peUrl: 'http://pe.test',
      gatewayUrl: 'http://gateway.test',
      model: 'mock',
      fallbackValues: [],
      requireResponseValues: true,
      requireDispatchPatch: true
    })),
    /failed with 500/
  );
  assert.deepEqual(patches.map((item) => item.status), ['running', 'failed']);
});

test('required dispatch patch rejects a missing ledger record before gateway call', async () => {
  let calls = 0;
  await assert.rejects(
    withFetch(async () => {
      calls += 1;
      return jsonResponse({ error: 'missing' }, 404);
    }, () => executeOpenClawAdapter({
      handoff: HANDOFF,
      peUrl: 'http://pe.test',
      gatewayUrl: 'http://gateway.test',
      model: 'mock',
      fallbackValues: [1, 0, 0.95, 0],
      requireDispatchPatch: true
    })),
    /failed with 404/
  );
  assert.equal(calls, 1);
});

test('gateway timeout aborts the request and patches the dispatch record failed', async () => {
  const patches = [];
  await assert.rejects(
    withFetch(async (url, options) => {
      if (options.method === 'PATCH') {
        patches.push(JSON.parse(options.body));
        return jsonResponse({ success: true });
      }
      return new Promise((_resolve, reject) => {
        const keepAlive = setTimeout(() => {}, 1000);
        options.signal.addEventListener('abort', () => {
          clearTimeout(keepAlive);
          reject(options.signal.reason);
        }, { once: true });
      });
    }, () => executeOpenClawAdapter({
      handoff: HANDOFF,
      peUrl: 'http://pe.test',
      gatewayUrl: 'http://gateway.test',
      model: 'mock',
      fallbackValues: [1, 0, 0.95, 0],
      requireResponseValues: true,
      requireDispatchPatch: true,
      timeoutMs: 5
    })),
    /timed out|aborted/i
  );
  assert.deepEqual(patches.map((item) => item.status), ['running', 'failed']);
});
