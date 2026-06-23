import test from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';

import { executeOpenClawAdapter } from '../lib/openclaw-adapter.mjs';


async function bodyJson(request) {
  const chunks = [];
  for await (const chunk of request) chunks.push(chunk);
  return JSON.parse(Buffer.concat(chunks).toString('utf8') || '{}');
}

async function listen(server) {
  await new Promise((resolveReady, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', resolveReady);
  });
  return server.address().port;
}

async function close(server) {
  server.closeIdleConnections?.();
  server.closeAllConnections?.();
  server.close();
}

test('real adapter carries a handoff through mock OpenClaw and PE', { timeout: 15000 }, async () => {
  const gatewayRequests = [];
  const dispatchPatches = [];
  const completions = [];

  const gateway = createServer(async (request, response) => {
    if (request.method !== 'POST' || request.url !== '/v1/chat/completions') {
      response.writeHead(404).end();
      return;
    }
    gatewayRequests.push({
      authorization: request.headers.authorization,
      body: await bodyJson(request)
    });
    response.writeHead(200, { 'content-type': 'application/json' });
    response.end(JSON.stringify({
      id: 'openclaw-run-e2e-1',
      choices: [{ message: { content: '{"values":[1,0,0.95,0]}' } }]
    }));
  });

  const pe = createServer(async (request, response) => {
    if (request.method === 'PATCH' && request.url === '/api/dispatch/records/dispatch-openclaw-e2e') {
      const body = await bodyJson(request);
      dispatchPatches.push(body);
      response.writeHead(200, { 'content-type': 'application/json' });
      response.end(JSON.stringify({ success: true, record: { id: 'dispatch-openclaw-e2e', ...body } }));
      return;
    }
    if (request.method === 'POST' && request.url === '/api/integrations/completions') {
      const body = await bodyJson(request);
      completions.push(body);
      response.writeHead(201, { 'content-type': 'application/json' });
      response.end(JSON.stringify({ success: true, sensorId: 'acp.openclaw.hello-world.completion' }));
      return;
    }
    response.writeHead(404).end();
  });

  const gatewayPort = await listen(gateway);
  const pePort = await listen(pe);
  try {
    const handoff = {
      protocol: 'ACP',
      surface: 'xACP',
      platform: 'OpenClaw',
      dispatchId: 'dispatch-openclaw-e2e',
      envelopeId: 'envelope-openclaw-e2e',
      correlationId: 'correlation-openclaw-e2e',
      sessionKey: 'agent:main:e2e',
      targetAgent: 'hello-world',
      completionEndpoint: '/api/integrations/completions',
      completionSourceMappingId: 'acp-openclaw-completion',
      prompt: 'Return the deterministic completion vector.',
      envelope: { fixture: 'OpenClawCompletionE2E' }
    };
    const result = await executeOpenClawAdapter({
      handoff,
      peUrl: `http://127.0.0.1:${pePort}`,
      gatewayUrl: `ws://127.0.0.1:${gatewayPort}`,
      apiKey: 'openclaw-e2e-token',
      model: 'mock-openclaw',
      fallbackValues: [0, 0, 0, 0],
      requireResponseValues: true,
      requireDispatchPatch: true
    });
    assert.equal(result.ok, true);
    assert.deepEqual(dispatchPatches.map((item) => item.status), ['running', 'completed']);
    assert.equal(gatewayRequests.length, 1);
    assert.equal(gatewayRequests[0].authorization, 'Bearer openclaw-e2e-token');
    assert.equal(gatewayRequests[0].body.model, 'mock-openclaw');

    const gatewayPayload = JSON.parse(gatewayRequests[0].body.messages[1].content);
    assert.equal(gatewayPayload.dispatchId, handoff.dispatchId);
    assert.equal(gatewayPayload.envelopeId, handoff.envelopeId);
    assert.equal(gatewayPayload.correlationId, handoff.correlationId);

    assert.equal(completions.length, 1);
    assert.deepEqual(completions[0].values, [1, 0, 0.95, 0]);
    assert.equal(completions[0].sourceMappingId, 'acp-openclaw-completion');
    assert.equal(completions[0].dispatchId, handoff.dispatchId);
    assert.equal(completions[0].envelopeId, handoff.envelopeId);
    assert.equal(completions[0].correlationId, handoff.correlationId);
    assert.equal(completions[0].completionId, 'openclaw-run-e2e-1');
  } finally {
    await Promise.all([close(gateway), close(pe)]);
  }
});
