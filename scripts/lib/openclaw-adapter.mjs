import { createHash, randomUUID } from 'node:crypto';

// ── The synthetic action answer ──────────────────────────────────────────────
//
// An action agent reports on the shared completion lane
// (acp-openclaw-completion, [4210:4214]) as [completed, failed, confidence,
// actionClass]. When its real turn cannot report, the synthetic body answers on
// that same lane with an answer the action contract admits for the dispatch's
// autonomy mode and RAG status, labelled synthetic. This mirrors
// localOpenClawStack machine-behaviors/synthetic_body.py; the tests pin the
// selection to vectors that implementation computed.

export const SYNTHETIC_MODES = ['off', 'fallback', 'always'];
export const SYNTHETIC_STRATEGIES = ['seeded-random', 'round-robin'];
// The action contract (localOpenClawStack derive_agents.py): each mode's verdict
// and its action class, the confidence anchors, and the default RAG blocking.
const VERDICT_BY_MODE = { advise: 'advised', 'supervised-act': 'staged', 'automated-act': 'executed' };
const ACTION_CLASS = { observed: 0.25, advised: 0.5, staged: 0.75, executed: 1.0 };
const CONFIDENCE_ANCHORS = [['low', 0.3], ['moderate', 0.6], ['high', 0.9]];
const DEFAULT_BLOCKED_WHEN_RAG = { advise: [], 'supervised-act': ['RED'], 'automated-act': ['AMBER', 'RED'] };

// Every answer the action contract admits, with the lane values it posts.
export function admissibleActionAnswers(mode, rag = '', riskControls = undefined) {
  const verdict = VERDICT_BY_MODE[mode];
  if (!verdict) return []; // observe writes no vector; an unknown mode admits nothing
  const blockedWhen = Array.isArray(riskControls?.blockedWhenRag)
    ? riskControls.blockedWhenRag.map(String)
    : DEFAULT_BLOCKED_WHEN_RAG[mode];
  const blocked = Boolean(rag) && blockedWhen.includes(rag);
  return CONFIDENCE_ANCHORS.map(([anchor, confidence]) => {
    const answer = blocked
      ? { verdict: 'blocked', completed: 'no', failed: 'yes', confidence: anchor,
          ...(mode !== 'advise' ? { review_required: 'yes' } : {}) }
      : { verdict, completed: 'yes', failed: 'no', confidence: anchor,
          ...(mode === 'supervised-act' ? { review_required: 'yes' } : {}),
          ...(mode === 'automated-act' ? { executed: 'yes', rollback_ok: 'yes' } : {}) };
    // A blocked answer has no action class; it is posted as 0, as a real one is.
    const values = blocked ? [0, 1, confidence, 0] : [1, 0, confidence, ACTION_CLASS[verdict]];
    return { answer, values };
  });
}

export function selectActionAnswer(answers, { agent = '', strategy, seedKey, step = 0 } = {}) {
  if (!answers.length) throw new Error('no admissible synthetic answer (observe mode writes no vector)');
  const n = answers.length;
  const key = seedKey === undefined || seedKey === null || seedKey === '' ? String(step) : String(seedKey);
  let index = 0;
  if (n > 1) {
    if (strategy === 'seeded-random') {
      const digest = createHash('sha256').update(`${agent}|${key}`, 'utf8').digest('hex');
      index = Number(BigInt(`0x${digest.slice(0, 16)}`) % BigInt(n));
    } else if (strategy === 'round-robin') {
      index = step % n;
    } else {
      throw new Error(`unknown strategy "${strategy}"`);
    }
  }
  return {
    ...answers[index],
    provenance: {
      synthetic: true, agent, strategy: n > 1 ? strategy : 'only-admissible', ordinality: n,
      answerIndex: index, seedKey: strategy === 'seeded-random' ? key : null, step, source: 'action-contract'
    }
  };
}

// Effective {mode, strategy}; first match wins: environment, the domain's
// config, the global config.
export function resolveSynthetic(config = {}, domain = '', env = process.env) {
  const global = config?.syntheticBody || {};
  const layers = [{ mode: env.OC_SYNTHETIC_MODE, strategy: env.OC_SYNTHETIC_STRATEGY },
    global.domains?.[domain] || {}, global];
  const pick = (key, allowed, fallback) => {
    const found = layers.map((layer) => layer?.[key]).find((v) => typeof v === 'string' && v.length > 0);
    const chosen = found ?? fallback;
    if (!allowed.includes(chosen)) throw new Error(`syntheticBody ${key} "${chosen}" is not one of ${allowed.join(', ')}`);
    return chosen;
  };
  return { mode: pick('mode', SYNTHETIC_MODES, 'off'), strategy: pick('strategy', SYNTHETIC_STRATEGIES, 'seeded-random') };
}

// What the synthetic answer depends on: the dispatch's autonomy mode, RAG
// status and risk controls. From the handoff's envelope when it carries one,
// else from the dispatch record (GET /api/dispatch/records/:id, on every PE).
export async function dispatchContext(handoff, peUrl, options = {}) {
  let envelope = handoff.envelope || handoff.body?.envelope;
  let record;
  if (!envelope && (handoff.dispatchId || handoff.id)) {
    const url = `${String(peUrl).replace(/\/+$/, '')}/api/dispatch/records/${encodeURIComponent(handoff.dispatchId || handoff.id)}`;
    try {
      const response = await fetch(url, { signal: options.timeoutMs ? AbortSignal.timeout(options.timeoutMs) : undefined });
      if (response.ok) {
        const body = await response.json();
        record = body?.record || body;
        envelope = record?.envelope;
      }
    } catch {
      // Unavailable context is reported by the caller, never guessed.
    }
  }
  const mode = envelope?.dispatch?.autonomyMode;
  if (!mode) return undefined;
  return {
    mode,
    rag: envelope?.governance?.ragStatusCode || record?.ragStatusCode || '',
    riskControls: envelope?.dispatch?.riskControls,
    domain: envelope?.ces?.domain || '',
    from: handoff.envelope || handoff.body?.envelope ? 'handoff' : 'dispatch-record'
  };
}

// A real action answer in the contract's form ({completed, failed, confidence,
// verdict}) read into lane values; undefined when it does not resolve.
export function actionAnswerValues(content) {
  const parsed = typeof content === 'string' ? tryParseJson(content) : content;
  if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) return undefined;
  const yesNo = (v) => {
    if (v === true || v === 1 || v === '1') return 1;
    if (v === false || v === 0 || v === '0') return 0;
    const t = String(v ?? '').toLowerCase();
    if (['yes', 'true', 'y'].includes(t)) return 1;
    if (['no', 'false', 'n'].includes(t)) return 0;
    return undefined;
  };
  const completed = yesNo(parsed.completed);
  const failed = yesNo(parsed.failed);
  const anchor = Object.fromEntries(CONFIDENCE_ANCHORS);
  const c = parsed.confidence;
  const confidence = Number.isFinite(Number(c)) && c !== '' && c !== null
    ? Math.min(1, Math.max(0, Number(c) > 1 ? Number(c) / 100 : Number(c)))
    : anchor[String(c ?? '').toLowerCase()];
  const verdict = String(parsed.verdict ?? '').toLowerCase();
  const actionClass = ACTION_CLASS[verdict] ?? (failed === 1 ? 0 : undefined);
  if ([completed, failed, confidence, actionClass].some((v) => v === undefined)) return undefined;
  return [completed, failed, confidence, actionClass];
}

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
    timeoutMs = 30000,
    // The synthetic action answer: {mode, strategy}. off (default) keeps the
    // adapter exactly as it was; fallback answers when the model fails or does
    // not resolve; always never calls the model.
    synthetic = { mode: 'off', strategy: 'seeded-random' },
    step = Number.isInteger(handoff.step) ? handoff.step : 0
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
    let gateway = null;
    let content = null;
    let values;
    let provenance = { synthetic: false };

    const callGateway = async () => {
      const gatewayHeaders = apiKey ? { authorization: `Bearer ${apiKey}` } : {};
      const chatBody = buildChatBody(handoff, targetAgent, model);
      gateway = await postJson(
        `${normalizedGatewayUrl}/v1/chat/completions`,
        chatBody,
        gatewayHeaders,
        { timeoutMs }
      );
      content = firstText(gateway.body);
    };

    if (synthetic.mode === 'off') {
      await callGateway();
      values = completionValues(content, fallbackValues, {
        requireResponseValues,
        expectedLength: expectedValuesLength
      });
    } else {
      let failure;
      if (synthetic.mode === 'fallback') {
        try {
          await callGateway();
          const array = jsonValues(tryParseJson(content));
          values = array && array.length === expectedValuesLength && array.every((v) => v >= 0 && v <= 1)
            ? array
            : actionAnswerValues(content);
          if (!values) failure = 'model answer did not resolve to the completion lane';
        } catch (error) {
          failure = `model turn failed: ${error.message}`;
        }
      }
      if (!values) {
        // Only a synthetic answer needs the dispatch's context; a real answer
        // that resolves is posted without it.
        const context = await dispatchContext(handoff, peUrl, { timeoutMs });
        if (!context) {
          throw new Error(`${failure ? `${failure}; ` : ''}synthetic body needs the dispatch autonomy mode: none in the handoff envelope or the dispatch record`);
        }
        const chosen = selectActionAnswer(
          admissibleActionAnswers(context.mode, context.rag, context.riskControls),
          { agent: targetAgent, strategy: synthetic.strategy, seedKey: handoff.correlationId || dispatchId, step }
        );
        values = chosen.values;
        provenance = {
          ...chosen.provenance, mode: synthetic.mode, autonomyMode: context.mode,
          ragStatusCode: context.rag || null, blocked: chosen.answer.verdict === 'blocked',
          contextFrom: context.from, answer: chosen.answer, ...(failure ? { replaced: failure } : {})
        };
      }
    }

    const { synthetic: isSynthetic, ...selection } = provenance;
    const completionBody = {
      provider: 'openclaw',
      agent: targetAgent,
      sourceMappingId,
      values,
      dispatchId: dispatchId || null,
      envelopeId: handoff.envelopeId || null,
      correlationId: handoff.correlationId || null,
      // Unique per completion, as the Python action path mints it (uuid4).
      completionId: gateway?.body?.id || `openclaw-${isSynthetic ? 'synthetic' : 'completion'}-${randomUUID()}`,
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
        sourceMappingId,
        values,
        ...(isSynthetic ? { synthetic: true } : {})
      }
    });

    return {
      ok: true,
      synthetic: isSynthetic ? selection : null,
      dispatchId,
      gateway: gateway ? { status: gateway.status, id: gateway.body?.id || null } : null,
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
