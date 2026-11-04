import { createHash } from 'node:crypto';

export function parseValues(value) {
  const parts = String(value).split(',').map((part) => part.trim());
  if (parts.length === 0 || parts.some((part) => part.length === 0)) {
    throw new Error('completion values must be a non-empty CSV list');
  }
  const values = parts.map(Number);
  if (values.some((item) => !Number.isFinite(item))) {
    throw new Error('completion values must all be finite numbers');
  }
  return values;
}

export function httpGatewayUrl(url) {
  const raw = String(url || 'http://127.0.0.1:18789').replace(/\/+$/, '');
  if (raw.startsWith('ws://')) return `http://${raw.slice(5)}`;
  if (raw.startsWith('wss://')) return `https://${raw.slice(6)}`;
  return raw;
}

export function absoluteCompletionEndpoint(peUrl, endpoint) {
  if (/^https?:\/\//i.test(String(endpoint || ''))) return endpoint;
  const base = String(peUrl || '').replace(/\/+$/, '');
  const path = String(endpoint || '/api/integrations/completions');
  return `${base}${path.startsWith('/') ? path : `/${path}`}`;
}

export function firstText(response) {
  return response?.choices?.[0]?.message?.content
    ?? response?.choices?.[0]?.text
    ?? response?.output_text
    ?? '';
}

export function tryParseJson(text) {
  if (!text || typeof text !== 'string') return undefined;
  try {
    return JSON.parse(text);
  } catch {
    const match = text.match(/\{[\s\S]*\}/);
    if (!match) return undefined;
    try {
      return JSON.parse(match[0]);
    } catch {
      return undefined;
    }
  }
}

export function jsonValues(value) {
  if (!value) return undefined;
  if (Array.isArray(value) && value.every((item) => Number.isFinite(Number(item)))) {
    return value.map(Number);
  }
  if (Array.isArray(value?.values)) return jsonValues(value.values);
  if (Array.isArray(value?.completion?.values)) return jsonValues(value.completion.values);
  if (Array.isArray(value?.result?.values)) return jsonValues(value.result.values);
  return undefined;
}

export function completionValues(content, fallbackValues, options = {}) {
  const parsed = typeof content === 'string' ? tryParseJson(content) : content;
  const responseValues = jsonValues(parsed);
  if (!responseValues && options.requireResponseValues) {
    throw new Error('OpenClaw response did not contain a numeric values array');
  }
  const values = responseValues || fallbackValues;
  if (!Array.isArray(values) || values.length === 0) {
    throw new Error('no completion values are available');
  }
  if (options.expectedLength && values.length !== options.expectedLength) {
    throw new Error(`completion values length ${values.length} does not match expected ${options.expectedLength}`);
  }
  return values;
}

// ── The synthetic agent body (localOpenClawStack machine-behaviors/synthetic_body.py)
//
// Every generated agent declares `syntheticBody`: the admissible answers it may
// give in place of its model, taken from its machine's corpus inputSequences.
// The selection below mirrors synthetic_body.select exactly — the tests pin it
// to vectors computed by the Python body — so an answer chosen here is the one
// the generator's tests vouch for, and every engine receives the same value.

export const SYNTHETIC_MODES = ['off', 'fallback', 'always'];
export const SYNTHETIC_STRATEGIES = ['seeded-random', 'round-robin', 'sequence-walk'];

// The generated agent spec for `agentId`, searched under `agentsDir` (one
// directory per domain). Returns undefined when there is none.
export async function loadAgentSpec(agentsDir, agentId) {
  if (!agentsDir || !agentId) return undefined;
  const fs = await import('node:fs/promises');
  const path = await import('node:path');
  let domains;
  try {
    domains = await fs.readdir(agentsDir, { withFileTypes: true });
  } catch {
    return undefined;
  }
  for (const entry of domains) {
    if (!entry.isDirectory()) continue;
    const file = path.join(agentsDir, entry.name, `${agentId}.oc-agent.json`);
    try {
      return JSON.parse(await fs.readFile(file, 'utf8'));
    } catch (error) {
      if (error.code !== 'ENOENT') throw error;
    }
  }
  return undefined;
}

// Effective {mode, strategy}; first match wins: environment, the domain's
// config, the global config, the agent's own declaration.
export function resolveSynthetic(spec, config = {}, env = process.env) {
  const body = spec?.syntheticBody || {};
  const global = config?.syntheticBody || {};
  const domain = global.domains?.[spec?.machine?.domain] || {};
  const layers = [
    { mode: env.OC_SYNTHETIC_MODE, strategy: env.OC_SYNTHETIC_STRATEGY },
    domain, global, body
  ];
  const pick = (key, allowed, fallback) => {
    const found = layers.map((layer) => layer?.[key]).find((v) => typeof v === 'string' && v.length > 0);
    const chosen = found ?? fallback;
    if (!allowed.includes(chosen)) {
      throw new Error(`syntheticBody ${key} "${chosen}" is not one of ${allowed.join(', ')}`);
    }
    return chosen;
  };
  return {
    mode: pick('mode', SYNTHETIC_MODES, 'off'),
    strategy: pick('strategy', SYNTHETIC_STRATEGIES, 'seeded-random')
  };
}

export function selectSynthetic(spec, { strategy, step = 0, seedKey } = {}) {
  const body = spec?.syntheticBody || {};
  const responses = Array.isArray(body.responses) ? body.responses : [];
  if (responses.length === 0) {
    throw new Error(body.unavailable || 'agent declares no synthetic responses');
  }
  const agentId = String(spec?.agentId || '');
  const key = seedKey === undefined || seedKey === null || seedKey === '' ? String(step) : String(seedKey);
  const n = responses.length;
  let index = 0;
  if (n > 1) {
    if (strategy === 'seeded-random') {
      const digest = createHash('sha256').update(`${agentId}|${key}`, 'utf8').digest('hex');
      index = Number(BigInt(`0x${digest.slice(0, 16)}`) % BigInt(n));
    } else if (strategy === 'round-robin') {
      const ids = responses.map((r) => r.id);
      const cycle = (body.roundRobin || []).map((id) => ids.indexOf(id)).filter((i) => i >= 0);
      const order = cycle.length > 0 ? cycle : responses.map((_, i) => i);
      index = order[step % order.length];
    } else if (strategy === 'sequence-walk') {
      index = step % n;
    } else {
      throw new Error(`unknown strategy "${strategy}"`);
    }
  }
  const chosen = responses[index];
  return {
    values: [...chosen.values],
    provenance: {
      synthetic: true,
      agentId,
      strategy: n > 1 ? strategy : 'only-admissible',
      ordinality: n,
      responseId: chosen.id,
      expectedSequenceId: chosen.expectedSequenceId ?? null,
      seedKey: strategy === 'seeded-random' ? key : null,
      step,
      source: body.source ?? null,
      ...(chosen.normalizationShift ? { normalizationShift: chosen.normalizationShift } : {})
    }
  };
}

// The actor's own route back into the perceptual space: the agent's declared
// write-back. A completion carrying it needs no registered source mapping —
// every PE takes an envelope's own sensorId and region over a mapping's.
export function actorRoute(spec) {
  const wb = spec?.agentBinding?.writeBack;
  if (!wb || !wb.sensorId || !wb.region) return undefined;
  return {
    sensorId: wb.sensorId,
    name: wb.name || wb.sensorId,
    region: { offset: wb.region.offset, length: wb.region.length },
    ttlMs: wb.ttlMs,
    triggerPush: wb.ingest?.triggerPush ?? false,
    compactPush: wb.ingest?.compactPush ?? true
  };
}

// A model answer keyed by the agent's response fields ({"<field key>": number}),
// read into the write-back vector by each field's target index. Only numeric
// values in [0, 1] under single-key JSON pointers are read here; anything else
// (prose, phrases) is left unresolved, which `fallback` mode answers for.
export function responseFieldValues(content, spec) {
  const fields = spec?.responseMapping?.fields;
  const parsed = typeof content === 'string' ? tryParseJson(content) : content;
  if (!Array.isArray(fields) || !parsed || typeof parsed !== 'object' || Array.isArray(parsed)) return undefined;
  const length = actorRoute(spec)?.region.length;
  if (!length) return undefined;
  const values = new Array(length).fill(undefined);
  for (const field of fields) {
    const pointer = String(field?.extract?.jsonPointer || '');
    const index = field?.target?.index;
    if (!pointer.startsWith('/') || pointer.slice(1).includes('/') || !Number.isInteger(index)) return undefined;
    const value = Number(parsed[pointer.slice(1)]);
    if (!Number.isFinite(value) || value < 0 || value > 1) return undefined;
    values[index] = value;
  }
  return values.every((v) => v !== undefined) ? values : undefined;
}

export async function postJson(url, body, headers = {}, options = {}) {
  const response = await fetch(url, {
    method: 'POST',
    headers: { 'content-type': 'application/json', ...headers },
    body: JSON.stringify(body),
    signal: options.timeoutMs ? AbortSignal.timeout(options.timeoutMs) : undefined
  });
  const text = await response.text();
  let parsed = text;
  try {
    parsed = JSON.parse(text);
  } catch {
    // Preserve non-JSON diagnostics.
  }
  if (!response.ok) {
    const error = new Error(`POST ${url} failed with ${response.status}`);
    error.status = response.status;
    error.response = parsed;
    throw error;
  }
  return { status: response.status, body: parsed };
}

export async function patchDispatchRecord(peUrl, dispatchId, body, options = {}) {
  if (!dispatchId) {
    if (options.required) throw new Error('dispatchId is required for dispatch ledger patching');
    return undefined;
  }
  const url = `${String(peUrl).replace(/\/+$/, '')}/api/dispatch/records/${encodeURIComponent(dispatchId)}`;
  const response = await fetch(url, {
    method: 'PATCH',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(body),
    signal: options.timeoutMs ? AbortSignal.timeout(options.timeoutMs) : undefined
  });
  const text = await response.text();
  let parsed = text;
  try {
    parsed = JSON.parse(text);
  } catch {
    // Preserve non-JSON diagnostics.
  }
  if (response.status === 404 && !options.required) return undefined;
  if (!response.ok) {
    const error = new Error(`PATCH ${url} failed with ${response.status}`);
    error.status = response.status;
    error.response = parsed;
    throw error;
  }
  return { status: response.status, body: parsed };
}

export function buildChatBody(handoff, targetAgent, model) {
  const dispatchId = handoff.dispatchId || handoff.id || null;
  const prompt = handoff.prompt
    || 'Handle this RealityEngine trigger envelope and return JSON with numeric values.';
  const envelope = handoff.envelope || handoff.body?.envelope || handoff.body || {};
  return {
    model,
    messages: [
      {
        role: 'system',
        content: 'You are an OpenClaw ACP adapter. Return compact JSON containing a numeric values array for RealityEngine PE completion ingestion.'
      },
      {
        role: 'user',
        content: JSON.stringify({
          targetAgent,
          sessionKey: handoff.sessionKey || null,
          dispatchId,
          envelopeId: handoff.envelopeId || null,
          correlationId: handoff.correlationId || null,
          prompt,
          envelope
        })
      }
    ],
    temperature: 0
  };
}

export async function executeOpenClawAdapter(options) {
  const {
    handoff,
    peUrl,
    gatewayUrl,
    apiKey = '',
    model,
    fallbackValues,
    requireResponseValues = false,
    requireDispatchPatch = false,
    skipDispatchPatch = false,
    expectedValuesLength = 4,
    timeoutMs = 30000,
    // The generated agent spec for the handoff's target agent, when there is
    // one. With it, the adapter is that agent's output-actor: the completion
    // travels the agent's own write-back route, and its synthetic body answers
    // when the model does not (per `synthetic`, else resolveSynthetic(spec)).
    agentSpec,
    synthetic,
    step = Number.isInteger(handoff.step) ? handoff.step : 0
  } = options;
  const dispatchId = handoff.dispatchId || handoff.id;
  const targetAgent = handoff.targetAgent || handoff.agent || 'openclaw';
  const sourceMappingId = handoff.completionSourceMappingId
    || handoff.sourceMappingId
    || 'acp-openclaw-completion';
  const route = actorRoute(agentSpec);
  const effective = route ? (synthetic || resolveSynthetic(agentSpec)) : { mode: 'off' };
  const seedKey = handoff.correlationId || dispatchId || handoff.envelopeId || undefined;
  const completionEndpoint = absoluteCompletionEndpoint(peUrl, handoff.completionEndpoint);
  const normalizedGatewayUrl = httpGatewayUrl(gatewayUrl);
  const patchOptions = { required: requireDispatchPatch, timeoutMs };
  const patch = async (body) => {
    if (skipDispatchPatch) return undefined;
    return patchDispatchRecord(peUrl, dispatchId, body, patchOptions);
  };

  await patch({
    status: 'running',
    adapter: 'openclaw-acp-adapter',
    provider: 'openclaw',
    incrementAttempts: true
  });

  try {
    let gateway = null;
    let content = null;
    let values;
    let provenance = { synthetic: false };
    let failure;

    if (effective.mode !== 'always') {
      try {
        const gatewayHeaders = apiKey ? { authorization: `Bearer ${apiKey}` } : {};
        const chatBody = buildChatBody(handoff, targetAgent, model);
        gateway = await postJson(
          `${normalizedGatewayUrl}/v1/chat/completions`,
          chatBody,
          gatewayHeaders,
          { timeoutMs }
        );
        content = firstText(gateway.body);
        if (route) {
          // The actor's answer must fill its write-back exactly: a values array
          // of the region's length, or an object keyed by its response fields.
          const array = jsonValues(typeof content === 'string' ? tryParseJson(content) : content);
          values = array && array.length === route.region.length && array.every((v) => v >= 0 && v <= 1)
            ? array
            : responseFieldValues(content, agentSpec);
          if (!values) failure = `model answer did not resolve to the ${route.region.length}-value write-back`;
        } else {
          values = completionValues(content, fallbackValues, {
            requireResponseValues,
            expectedLength: expectedValuesLength
          });
        }
      } catch (error) {
        if (!(route && effective.mode === 'fallback')) throw error;
        failure = `model turn failed: ${error.message}`;
      }
      if (route && !values && effective.mode === 'off') {
        // No substitution with the body off: the fixed --values vector is not
        // an answer for this agent (wrong length, wrong meaning, unlabelled).
        throw new Error(`${failure}; synthetic body is off`);
      }
    }

    if (route && !values) {
      const chosen = selectSynthetic(agentSpec, { strategy: effective.strategy, step, seedKey });
      values = chosen.values;
      provenance = { ...chosen.provenance, mode: effective.mode, ...(failure ? { replaced: failure } : {}) };
    }

    const { synthetic: isSynthetic, ...selection } = provenance;
    const completionBody = {
      provider: 'openclaw',
      agent: targetAgent,
      // The actor carries its own route; a registered mapping is used only for
      // a handoff whose agent has no generated spec.
      ...(route
        ? {
            sensorId: route.sensorId,
            name: route.name,
            region: route.region,
            ...(Number.isFinite(route.ttlMs) ? { ttlMs: route.ttlMs } : {}),
            triggerPush: route.triggerPush,
            compactPush: route.compactPush
          }
        : { sourceMappingId }),
      values,
      dispatchId: dispatchId || null,
      envelopeId: handoff.envelopeId || null,
      correlationId: handoff.correlationId || null,
      completionId: gateway?.body?.id || `openclaw-${isSynthetic ? 'synthetic' : 'completion'}-${Date.now()}`,
      metadata: {
        adapter: 'openclaw-acp-adapter',
        model: isSynthetic ? null : model,
        gatewayUrl: normalizedGatewayUrl,
        responseContent: content,
        ...(isSynthetic ? { synthetic: true, syntheticBody: selection } : {})
      }
    };

    const completion = await postJson(completionEndpoint, completionBody, {}, { timeoutMs });
    const dispatchPatch = await patch({
      status: 'completed',
      adapter: 'openclaw-acp-adapter',
      provider: 'openclaw',
      externalRunId: gateway?.body?.id || null,
      metadata: {
        completionId: completionBody.completionId,
        ...(route ? { sensorId: route.sensorId, region: route.region } : { sourceMappingId }),
        values,
        synthetic: Boolean(isSynthetic)
      }
    });

    return {
      ok: true,
      dispatchId,
      gateway: gateway ? { status: gateway.status, id: gateway.body?.id || null } : null,
      completion: { status: completion.status, body: completion.body },
      synthetic: isSynthetic ? selection : null,
      dispatchPatch
    };
  } catch (error) {
    try {
      await patch({
        status: 'failed',
        adapter: 'openclaw-acp-adapter',
        provider: 'openclaw',
        error: error.message
      });
    } catch {
      // Preserve the original gateway or completion error.
    }
    throw error;
  }
}
