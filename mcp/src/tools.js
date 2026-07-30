// Tool catalogue for the RealityEngine MCP gateway.
//
// Every tool maps 1:1 onto a route from the canonical surface
// (RealityEngine_CPP/SURFACE_SPEC.md) and the PE integration contract
// (RealityEngine_CI/docs/INTEGRATION_ARCHITECTURE.md). `target` selects the
// RE or PE base URL for the chosen instance. `mutating` tools are gated by the
// mutation policy in config.js.
//
// Each tool is a plain object:
//   { name, title, description, target, mutating, input, build }
// where `input` is a zod raw shape and `build(args)` returns
//   { method, path, body? }.

import { z } from 'zod';

const instance = z
  .string()
  .optional()
  .describe('Instance id or runtime name (cpp|lsp|scala). Defaults to the first live instance.');

const region = z
  .object({ offset: z.number().int().nonnegative(), length: z.number().int().positive() })
  .describe('Perceptual-space slice { offset, length }.');

const providerDispatchInput = {
  instance,
  dispatchId: z.string().optional().describe('Recorded dispatch id.'),
  dispatch_id: z.string().optional().describe('Recorded dispatch id (snake_case alias).'),
  prompt: z.string().optional().describe('Optional provider prompt override.'),
  model: z.string().optional().describe('Optional provider model override.'),
  options: z.record(z.any()).optional().describe('Optional provider-specific adapter options.'),
};

function dispatchIdFromArgs(args) {
  return args.dispatchId || args.dispatch_id;
}

function providerDispatchBody(args, provider = undefined) {
  const dispatchId = dispatchIdFromArgs(args);
  if (!dispatchId) throw new Error('dispatchId is required');
  return {
    dispatchId,
    ...(args.prompt ? { prompt: args.prompt } : {}),
    ...(args.model ? { model: args.model } : {}),
    ...(provider ? { provider } : {}),
    ...(args.options ? { options: args.options } : {}),
  };
}

export const TOOLS = [
  // ---- Reality Engine: read ----
  {
    name: 're.read_state',
    title: 'RE: read engine state',
    description: 'Read the Reality Engine current state (perceptual space, config, last step).',
    target: 're',
    mutating: false,
    input: { instance },
    build: () => ({ method: 'GET', path: '/api/state' }),
  },
  {
    name: 're.list_machines',
    title: 'RE: list machines',
    description: 'List all machines registered in the Reality Engine.',
    target: 're',
    mutating: false,
    input: { instance },
    build: () => ({ method: 'GET', path: '/api/machines' }),
  },
  {
    name: 're.read_machine',
    title: 'RE: read machine',
    description: 'Read one machine definition + live activation state by id.',
    target: 're',
    mutating: false,
    input: { instance, id: z.string().describe('Machine id.') },
    build: (a) => ({ method: 'GET', path: `/api/machines/${encodeURIComponent(a.id)}` }),
  },
  {
    name: 're.machine_graph',
    title: 'RE: machine interconnection graph',
    description: 'Read the machine interconnection graph (nodes, edges, perceptualSpaceDimension).',
    target: 're',
    mutating: false,
    input: { instance },
    build: () => ({ method: 'GET', path: '/api/machine-graph' }),
  },
  {
    name: 're.list_sequences',
    title: 'RE: list sequences',
    description: 'List sequence graphs with live activation state.',
    target: 're',
    mutating: false,
    input: { instance },
    build: () => ({ method: 'GET', path: '/api/sequences' }),
  },

  // ---- Reality Engine: mutating ----
  {
    name: 're.perceive',
    title: 'RE: perceive (process a vector)',
    description:
      'Run processImmediate against a perceptual vector and return the full SimulationStep. Deterministic; does not push through PE.',
    target: 're',
    mutating: true,
    input: {
      instance,
      vector: z.array(z.number()).describe('Perceptual input vector.'),
      matchAlgorithm: z.enum(['gte', 'equals']).optional(),
    },
    build: (a) => ({
      method: 'POST',
      path: '/api/perceive',
      body: { vector: a.vector, ...(a.matchAlgorithm ? { matchAlgorithm: a.matchAlgorithm } : {}) },
    }),
  },

  // ---- Perception Engine: read ----
  {
    name: 'pe.read_state',
    title: 'PE: read engine state',
    description: 'Read the Perception Engine state (sources, assembled vector, globalStep, auto, matchAlgorithm).',
    target: 'pe',
    mutating: false,
    input: { instance },
    build: () => ({ method: 'GET', path: '/api/state' }),
  },
  {
    name: 'pe.list_sources',
    title: 'PE: list sources',
    description: 'List configured PE sensor/test/simulated sources.',
    target: 'pe',
    mutating: false,
    input: { instance },
    build: () => ({ method: 'GET', path: '/api/sources' }),
  },
  {
    name: 'pe.triggers_status',
    title: 'PE: trigger dispatcher status',
    description: 'Read trigger dispatcher counters and configuration.',
    target: 'pe',
    mutating: false,
    input: { instance },
    build: () => ({ method: 'GET', path: '/api/triggers/status' }),
  },
  {
    name: 'pe.integrations_status',
    title: 'PE: integration registry status',
    description: 'Report startup-loaded integration providers and source mappings.',
    target: 'pe',
    mutating: false,
    input: { instance },
    build: () => ({ method: 'GET', path: '/api/integrations/status' }),
  },
  {
    name: 'dispatch.read_ledger',
    title: 'PE: read dispatch ledger',
    description: 'Read recent recorded trigger-dispatch envelopes (audit/outbox).',
    target: 'pe',
    mutating: false,
    input: { instance },
    build: () => ({ method: 'GET', path: '/api/dispatch/ledger' }),
  },
  {
    name: 'dispatch.read_record',
    title: 'PE: read dispatch record',
    description: 'Read one recorded dispatch envelope by id.',
    target: 'pe',
    mutating: false,
    input: { instance, id: z.string().describe('dispatchId') },
    build: (a) => ({ method: 'GET', path: `/api/dispatch/records/${encodeURIComponent(a.id)}` }),
  },

  // ---- Perception Engine: mutating ----
  {
    name: 'pe.push_signal',
    title: 'PE: commit a signal to a source',
    description:
      'Commit a numeric result into a PE sensor source (the /api/signals path). Commit-only by default; this is the provider-neutral completion ingress.',
    target: 'pe',
    mutating: true,
    input: {
      instance,
      sensorId: z.string().describe('Target sensor source id.'),
      values: z.array(z.number()).describe('Numeric values to commit.'),
      region: region.optional(),
      ttlMs: z.number().int().positive().optional(),
      triggerPush: z.boolean().optional().describe('If true, run the PE push path instead of commit-only.'),
    },
    build: (a) => ({
      method: 'POST',
      path: '/api/signals',
      body: {
        sensorId: a.sensorId,
        values: a.values,
        ...(a.region ? { region: a.region } : {}),
        ...(a.ttlMs ? { ttlMs: a.ttlMs } : {}),
        ...(a.triggerPush !== undefined ? { triggerPush: a.triggerPush } : {}),
      },
    }),
  },
  {
    name: 'pe.enqueue_push',
    title: 'PE: enqueue a push cycle',
    description: 'Assemble the current sources into a vector, push to RE, and return the resulting step.',
    target: 'pe',
    mutating: true,
    input: { instance },
    build: () => ({ method: 'POST', path: '/api/push', body: {} }),
  },
  {
    name: 'pe.sensor_push',
    title: 'PE: push raw sensor values',
    description: 'Push raw values to a sensor source by sensorId.',
    target: 'pe',
    mutating: true,
    input: {
      instance,
      sensorId: z.string(),
      values: z.array(z.number()),
    },
    build: (a) => ({
      method: 'POST',
      path: `/api/sensors/${encodeURIComponent(a.sensorId)}`,
      body: { values: a.values },
    }),
  },
  {
    name: 'trigger.replay',
    title: 'PE: replay a trigger envelope',
    description: 'Re-dispatch a recorded trigger envelope by dispatchId (audit replay; does not drive RE state).',
    target: 'pe',
    mutating: true,
    input: { instance, dispatchId: z.string() },
    build: (a) => ({
      method: 'POST',
      path: `/api/triggers/replay/${encodeURIComponent(a.dispatchId)}`,
      body: {},
    }),
  },
  {
    name: 'dispatch.update_record',
    title: 'PE: annotate dispatch delivery metadata',
    description:
      'Annotate a dispatch record with delivery metadata only (status, attempts, adapter, external run id, receipt, error). Does not complete an agent result or drive PE/RE state.',
    target: 'pe',
    mutating: true,
    input: {
      instance,
      id: z.string().describe('dispatchId'),
      status: z.enum(['pending', 'delivering', 'delivered', 'failed']).optional(),
      adapter: z.string().optional(),
      externalRunId: z.string().optional(),
      incrementAttempts: z.boolean().optional(),
      receipt: z.record(z.any()).optional(),
      error: z.string().optional(),
    },
    build: (a) => ({
      method: 'PATCH',
      path: `/api/dispatch/records/${encodeURIComponent(a.id)}`,
      body: {
        ...(a.status ? { status: a.status } : {}),
        ...(a.adapter ? { adapter: a.adapter } : {}),
        ...(a.externalRunId ? { externalRunId: a.externalRunId } : {}),
        ...(a.incrementAttempts ? { incrementAttempts: true } : {}),
        ...(a.receipt ? { receipt: a.receipt } : {}),
        ...(a.error ? { error: a.error } : {}),
      },
    }),
  },
  {
    name: 'integrations.completion',
    title: 'PE: post a provider/agent completion',
    description:
      'Map a provider/agent result into a PE source through the same path as /api/signals, using a configured sourceMappingId or a direct source target.',
    target: 'pe',
    mutating: true,
    input: {
      instance,
      provider: z.string().describe('Provider id, e.g. openai|ollama|acp|mcp|manual.'),
      values: z.array(z.number()),
      agent: z.string().optional(),
      correlationId: z.string().optional(),
      envelopeId: z.string().optional(),
      sourceMappingId: z.string().optional(),
      sensorId: z.string().optional(),
      region: region.optional(),
      ttlMs: z.number().int().positive().optional(),
      triggerPush: z.boolean().optional(),
    },
    build: (a) => ({
      method: 'POST',
      path: '/api/integrations/completions',
      body: {
        provider: a.provider,
        values: a.values,
        ...(a.agent ? { agent: a.agent } : {}),
        ...(a.correlationId ? { correlationId: a.correlationId } : {}),
        ...(a.envelopeId ? { envelopeId: a.envelopeId } : {}),
        ...(a.sourceMappingId ? { sourceMappingId: a.sourceMappingId } : {}),
        ...(a.sensorId ? { sensorId: a.sensorId } : {}),
        ...(a.region ? { region: a.region } : {}),
        ...(a.ttlMs ? { ttlMs: a.ttlMs } : {}),
        ...(a.triggerPush !== undefined ? { triggerPush: a.triggerPush } : {}),
      },
    }),
  },
  {
    name: 'integrations.dispatch_provider',
    title: 'PE: dispatch a recorded envelope to a provider',
    description:
      'Dispatch a recorded trigger envelope to a configured provider adapter. The provider result must still return through integrations.completion.',
    target: 'pe',
    mutating: true,
    input: {
      provider: z.enum(['openai', 'ollama']).describe('Provider adapter id.'),
      ...providerDispatchInput,
    },
    build: (a) => ({
      method: 'POST',
      path: `/api/integrations/${encodeURIComponent(a.provider)}/dispatch`,
      body: providerDispatchBody(a, a.provider),
    }),
  },
  {
    name: 'integrations.dispatch_openai',
    title: 'PE: dispatch a recorded envelope to OpenAI',
    description:
      'Dispatch a recorded trigger envelope through the OpenAI-compatible adapter. The provider result must still return through integrations.completion.',
    target: 'pe',
    mutating: true,
    input: providerDispatchInput,
    build: (a) => ({
      method: 'POST',
      path: '/api/integrations/openai/dispatch',
      body: providerDispatchBody(a, 'openai'),
    }),
  },
  {
    name: 'integrations.dispatch_ollama',
    title: 'PE: dispatch a recorded envelope to Ollama',
    description:
      'Dispatch a recorded trigger envelope through the Ollama adapter. The provider result must still return through integrations.completion.',
    target: 'pe',
    mutating: true,
    input: providerDispatchInput,
    build: (a) => ({
      method: 'POST',
      path: '/api/integrations/ollama/dispatch',
      body: providerDispatchBody(a, 'ollama'),
    }),
  },
];

export function toolByName(name) {
  return TOOLS.find((t) => t.name === name);
}
