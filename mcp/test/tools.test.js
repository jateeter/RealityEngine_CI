import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { test } from 'node:test';

import { describeTools, TOOLS, toolByName } from '../src/server.js';

function withEnv(patch, fn) {
  const previous = {};
  for (const key of Object.keys(patch)) {
    previous[key] = process.env[key];
    if (patch[key] === undefined) delete process.env[key];
    else process.env[key] = patch[key];
  }
  try {
    return fn();
  } finally {
    for (const key of Object.keys(patch)) {
      if (previous[key] === undefined) delete process.env[key];
      else process.env[key] = previous[key];
    }
  }
}

test('manifest tool list matches the live tool catalogue', () => {
  const manifest = JSON.parse(readFileSync(new URL('../manifest.json', import.meta.url), 'utf8'));
  assert.deepEqual(
    manifest.tools,
    TOOLS.map((tool) => ({ name: tool.name, target: tool.target, mutating: tool.mutating }))
  );
});

test('canonical RE and PE read tools build the expected requests', () => {
  // The RE and PE do not share a state path. /api/state is the PE's; the RE
  // serves /api/perceptual-simulation/state. This assertion previously
  // claimed both were /api/state, so it agreed with the bug instead of
  // catching it — see the live-route coverage in mcp-e2e.test.js.
  assert.deepEqual(toolByName('re.read_state').build({}), {
    method: 'GET',
    path: '/api/perceptual-simulation/state',
  });
  assert.deepEqual(toolByName('pe.read_state').build({}), { method: 'GET', path: '/api/state' });
  assert.deepEqual(toolByName('re.read_machine').build({ id: 'machine/a' }), {
    method: 'GET',
    path: '/api/machines/machine%2Fa',
  });
});

test('provider dispatch tools build canonical OpenAI/Ollama requests', () => {
  assert.deepEqual(toolByName('integrations.dispatch_openai').build({ dispatchId: 'd/1' }), {
    method: 'POST',
    path: '/api/integrations/openai/dispatch',
    body: { dispatchId: 'd/1', provider: 'openai' },
  });
  assert.deepEqual(toolByName('integrations.dispatch_ollama').build({ dispatch_id: 'd/2', model: 'gpt-oss:20b' }), {
    method: 'POST',
    path: '/api/integrations/ollama/dispatch',
    body: { dispatchId: 'd/2', model: 'gpt-oss:20b', provider: 'ollama' },
  });
  assert.throws(() => toolByName('integrations.dispatch_provider').build({ provider: 'openai' }), /dispatchId is required/);
});

test('mutating tools are disabled by default in the tool description', () => withEnv({
  RE_MCP_ALLOW_MUTATION: undefined,
  RE_MCP_ALLOWED_TOOLS: undefined,
}, () => {
  const tools = describeTools();
  assert.equal(tools.find((tool) => tool.name === 're.read_state')?.enabled, true);
  assert.equal(tools.find((tool) => tool.name === 'pe.push_signal')?.enabled, false);
}));

test('mutation allowlist enables only the named mutating tool', () => withEnv({
  RE_MCP_ALLOW_MUTATION: undefined,
  RE_MCP_ALLOWED_TOOLS: 'pe.push_signal',
}, () => {
  const tools = describeTools();
  assert.equal(tools.find((tool) => tool.name === 'pe.push_signal')?.enabled, true);
  assert.equal(tools.find((tool) => tool.name === 'pe.enqueue_push')?.enabled, false);
}));

test('OpenAI MCP profile pins mutating tools behind approval policy', () => {
  const profile = JSON.parse(readFileSync(new URL('../openai-mcp-profile.json', import.meta.url), 'utf8'));
  const manifest = JSON.parse(readFileSync(new URL('../manifest.json', import.meta.url), 'utf8'));
  const toolNames = new Set(manifest.tools.map((tool) => tool.name));
  const mutatingToolNames = manifest.tools.filter((tool) => tool.mutating).map((tool) => tool.name).sort();
  const localTool = profile.profiles.local.tools[0];
  assert.equal(localTool.type, 'mcp');
  assert.deepEqual(localTool.allowed_tools, [...localTool.allowed_tools].sort());
  assert.deepEqual(localTool.allowed_tools.filter((name) => !toolNames.has(name)), []);
  assert.deepEqual(localTool.require_approval.always.tool_names, mutatingToolNames);
  assert.equal(localTool.defer_loading, true);
});

test('OpenAI MCP profile generation rejects stale or unsafe inputs', () => {
  const script = new URL('../scripts/gen-openai-profile.mjs', import.meta.url);
  const badTool = spawnSync(process.execPath, [
    script.pathname,
    '--allowed-tools',
    'missing.tool',
    '--out',
    '/tmp/realityengine-bad-openai-profile.json',
  ], { encoding: 'utf8' });
  assert.notEqual(badTool.status, 0);
  assert.match(badTool.stderr, /unknown MCP tool/);

  const unsafeNever = spawnSync(process.execPath, [
    script.pathname,
    '--require-approval',
    'never',
    '--allowed-tools',
    're.read_state,integrations.completion',
    '--out',
    '/tmp/realityengine-unsafe-openai-profile.json',
  ], { encoding: 'utf8' });
  assert.notEqual(unsafeNever.status, 0);
  assert.match(unsafeNever.stderr, /refusing require_approval=never/);
});
