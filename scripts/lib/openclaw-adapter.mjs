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
    timeoutMs = 30000
  } = options;
  const dispatchId = handoff.dispatchId || handoff.id;
  const targetAgent = handoff.targetAgent || handoff.agent || 'openclaw';
  const sourceMappingId = handoff.completionSourceMappingId
    || handoff.sourceMappingId
    || 'acp-openclaw-completion';
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
    const gatewayHeaders = apiKey ? { authorization: `Bearer ${apiKey}` } : {};
    const chatBody = buildChatBody(handoff, targetAgent, model);
    const gateway = await postJson(
      `${normalizedGatewayUrl}/v1/chat/completions`,
      chatBody,
      gatewayHeaders,
      { timeoutMs }
    );
    const content = firstText(gateway.body);
    const values = completionValues(content, fallbackValues, {
      requireResponseValues,
      expectedLength: expectedValuesLength
    });
    const completionBody = {
      provider: 'openclaw',
      agent: targetAgent,
      sourceMappingId,
      values,
      dispatchId: dispatchId || null,
      envelopeId: handoff.envelopeId || null,
      correlationId: handoff.correlationId || null,
      completionId: gateway.body?.id || `openclaw-completion-${Date.now()}`,
      metadata: {
        adapter: 'openclaw-acp-adapter',
        model,
        gatewayUrl: normalizedGatewayUrl,
        responseContent: content
      }
    };

    const completion = await postJson(completionEndpoint, completionBody, {}, { timeoutMs });
    const dispatchPatch = await patch({
      status: 'completed',
      adapter: 'openclaw-acp-adapter',
      provider: 'openclaw',
      externalRunId: gateway.body?.id || null,
      metadata: {
        completionId: completionBody.completionId,
        sourceMappingId,
        values
      }
    });

    return {
      ok: true,
      dispatchId,
      gateway: { status: gateway.status, id: gateway.body?.id || null },
      completion: { status: completion.status, body: completion.body },
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
