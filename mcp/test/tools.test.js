import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
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
  assert.deepEqual(toolByName('re.read_state').build({}), { method: 'GET', path: '/api/state' });
  assert.deepEqual(toolByName('pe.read_state').build({}), { method: 'GET', path: '/api/state' });
  assert.deepEqual(toolByName('re.read_machine').build({ id: 'machine/a' }), {
    method: 'GET',
    path: '/api/machines/machine%2Fa',
  });
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
