#!/usr/bin/env node
// Regression smoke checks for the RealityEngine MCP Streamable HTTP endpoint.

import { readFile, writeFile, mkdir } from 'node:fs/promises';
import { dirname } from 'node:path';

const DEFAULT_MANIFEST = 'mcp/manifest.json';
const DEFAULT_OPENAI_PROFILE = 'mcp/openai-mcp-profile.json';
const READ_ONLY_SMOKE_TOOLS = [
  're.read_state',
  're.list_machines',
  'pe.read_state',
  'dispatch.read_ledger'
];
const REQUIRED_PROVIDER_TOOLS = [
  'integrations.completion',
  'integrations.dispatch_provider',
  'integrations.dispatch_openai',
  'integrations.dispatch_ollama'
];
const PROVIDER_STATUS_PATHS = [
  '/api/integrations/status',
  '/api/integrations/openai/status',
  '/api/integrations/ollama/status',
  '/api/dispatch/ledger'
];

function usage() {
  console.log(`regression-mcp-smoke.mjs

Usage:
  node scripts/regression-mcp-smoke.mjs --mcp-url URL --out PATH [options]

Options:
  --mcp-url URL       MCP HTTP base URL. Default: http://127.0.0.1:7331
  --registry PATH     Runtime registry JSON. Default: /tmp/re-registry/re-registry.json
  --manifest PATH     MCP manifest JSON. Default: mcp/manifest.json
  --profile PATH      OpenAI MCP profile JSON. Default: mcp/openai-mcp-profile.json
  --out PATH          Report path. Required.
  --timeout-ms N      Request timeout. Default: 15000
  --tool NAME         Read-only tool smoke to run. Repeatable.
  --skip-completion-ingest
                      Skip the provider-neutral completion ingest fixture.
  --help              Show this help.
`);
}

function parseArgs(argv) {
  const args = {
    mcpUrl: 'http://127.0.0.1:7331',
    registry: '/tmp/re-registry/re-registry.json',
    manifest: DEFAULT_MANIFEST,
    profile: DEFAULT_OPENAI_PROFILE,
    out: '',
    timeoutMs: 15000,
    tools: [],
    completionIngest: true
  };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    const next = () => {
      i += 1;
      if (i >= argv.length) throw new Error(`missing value for ${arg}`);
      return argv[i];
    };
    if (arg === '--help' || arg === '-h') {
      usage();
      process.exit(0);
    } else if (arg === '--mcp-url') {
      args.mcpUrl = next();
    } else if (arg.startsWith('--mcp-url=')) {
      args.mcpUrl = arg.slice('--mcp-url='.length);
    } else if (arg === '--registry') {
      args.registry = next();
    } else if (arg.startsWith('--registry=')) {
      args.registry = arg.slice('--registry='.length);
    } else if (arg === '--manifest') {
      args.manifest = next();
    } else if (arg.startsWith('--manifest=')) {
      args.manifest = arg.slice('--manifest='.length);
    } else if (arg === '--profile') {
      args.profile = next();
    } else if (arg.startsWith('--profile=')) {
      args.profile = arg.slice('--profile='.length);
    } else if (arg === '--out') {
      args.out = next();
    } else if (arg.startsWith('--out=')) {
      args.out = arg.slice('--out='.length);
    } else if (arg === '--timeout-ms') {
      args.timeoutMs = Number(next());
    } else if (arg.startsWith('--timeout-ms=')) {
      args.timeoutMs = Number(arg.slice('--timeout-ms='.length));
    } else if (arg === '--tool') {
      args.tools.push(next());
    } else if (arg.startsWith('--tool=')) {
      args.tools.push(arg.slice('--tool='.length));
    } else if (arg === '--skip-completion-ingest') {
      args.completionIngest = false;
    } else {
      throw new Error(`unknown argument: ${arg}`);
    }
  }
  if (!args.out) throw new Error('missing --out');
  if (!Number.isFinite(args.timeoutMs) || args.timeoutMs <= 0) throw new Error('invalid --timeout-ms');
  // Tool selection is resolved after the manifest loads — see
  // readOnlyToolsFrom(). An explicit --tool still wins.
  return args;
}

/**
 * Every non-mutating tool the manifest declares, so the smoke covers the whole
 * read surface instead of a hand-picked few.
 *
 * The hardcoded list exercised 4 of 21 tools, which is how re.read_state
 * shipped pointing at a Reality Engine path no runtime serves. A tool absent
 * from the smoke is a tool nothing proves against a live engine.
 */
function readOnlyToolsFrom(manifest) {
  const tools = Array.isArray(manifest?.tools) ? manifest.tools : [];
  const readOnly = tools.filter((t) => t && t.mutating === false).map((t) => t.name);
  return readOnly.length ? readOnly.sort() : [...READ_ONLY_SMOKE_TOOLS];
}

async function readRegistry(path) {
  try {
    const payload = JSON.parse(await readFile(path, 'utf8'));
    return (payload.instances || [])
      .filter((item) => item?.status !== 'stopped' && item?.id)
      .map((item) => ({ id: item.id, runtime: item.runtime, reUrl: item.re_url, peUrl: item.pe_url }));
  } catch (err) {
    return { error: err.message, instances: [] };
  }
}

async function readJson(path) {
  try {
    return { ok: true, path, body: JSON.parse(await readFile(path, 'utf8')) };
  } catch (err) {
    return { ok: false, path, error: err.message, body: null };
  }
}

async function fetchWithTimeout(url, options, timeoutMs) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const response = await fetch(url, { ...options, signal: controller.signal });
    const text = await response.text();
    return {
      ok: response.ok,
      status: response.status,
      headers: Object.fromEntries(response.headers.entries()),
      bodyText: text,
      body: parseBody(text)
    };
  } catch (err) {
    return {
      ok: false,
      status: null,
      headers: {},
      error: err.message,
      bodyText: '',
      body: null
    };
  } finally {
    clearTimeout(timer);
  }
}

function parseBody(text) {
  if (!text) return null;
  try {
    return JSON.parse(text);
  } catch {
    const dataLines = text
      .split(/\r?\n/)
      .filter((line) => line.startsWith('data:'))
      .map((line) => line.slice(5).trim())
      .filter(Boolean);
    if (dataLines.length) {
      try {
        return JSON.parse(dataLines[dataLines.length - 1]);
      } catch {
        return { raw: text.slice(0, 2048) };
      }
    }
    return { raw: text.slice(0, 2048) };
  }
}

function jsonRpc(id, method, params = undefined) {
  const payload = { jsonrpc: '2.0', id, method };
  if (params !== undefined) payload.params = params;
  return payload;
}

async function postMcp(baseUrl, payload, sessionId, timeoutMs) {
  const headers = {
    accept: 'application/json, text/event-stream',
    'content-type': 'application/json'
  };
  if (sessionId) headers['mcp-session-id'] = sessionId;
  return fetchWithTimeout(`${baseUrl.replace(/\/$/, '')}/mcp`, {
    method: 'POST',
    headers,
    body: JSON.stringify(payload)
  }, timeoutMs);
}

function bodyError(result) {
  if (result?.body?.error) return result.body.error.message || JSON.stringify(result.body.error);
  if (result?.body?.result?.isError) return 'tool returned isError=true';
  return '';
}

function toolCallIsError(result) {
  return Boolean(result?.body?.result?.isError);
}

function toolListFromResponse(result) {
  const tools = result?.body?.result?.tools;
  return Array.isArray(tools) ? tools : [];
}

function sorted(values) {
  return [...values].sort((a, b) => a.localeCompare(b));
}

function diffSets(expected, actual) {
  const actualSet = new Set(actual);
  const expectedSet = new Set(expected);
  return {
    missing: expected.filter((item) => !actualSet.has(item)),
    unexpected: actual.filter((item) => !expectedSet.has(item))
  };
}

function approvalRequiresMutatingTools(requireApproval, mutatingAllowed) {
  if (mutatingAllowed.length === 0) return { ok: true, mode: 'none-mutating' };
  if (requireApproval === 'always') return { ok: true, mode: 'always' };
  if (requireApproval === 'never') return { ok: false, mode: 'never' };
  const always = requireApproval?.always;
  const alwaysNames = new Set(always?.tool_names || []);
  const missing = mutatingAllowed.filter((name) => !alwaysNames.has(name));
  return { ok: missing.length === 0, mode: 'policy', missing };
}

function validateManifestAndProfile({ manifest, profile, advertisedToolNames, failures, report }) {
  report.manifest = {
    path: manifest.path,
    ok: manifest.ok,
    toolCount: manifest.body?.tools?.length || 0,
    error: manifest.error || ''
  };
  report.openaiProfile = {
    path: profile.path,
    ok: profile.ok,
    profiles: {},
    error: profile.error || ''
  };
  if (!manifest.ok) {
    failures.push(`MCP manifest unreadable: ${manifest.error}`);
    return;
  }
  if (!profile.ok) {
    failures.push(`OpenAI MCP profile unreadable: ${profile.error}`);
    return;
  }

  const manifestTools = manifest.body.tools || [];
  const manifestToolNames = sorted(manifestTools.map((tool) => tool.name));
  const manifestMutating = new Set(manifestTools.filter((tool) => tool.mutating).map((tool) => tool.name));
  const catalogueDiff = diffSets(manifestToolNames, advertisedToolNames);
  report.manifest.catalogueDiff = catalogueDiff;
  if (catalogueDiff.missing.length || catalogueDiff.unexpected.length) {
    failures.push(
      `MCP tool catalogue differs from manifest: missing=${catalogueDiff.missing.join(',') || '-'} ` +
        `unexpected=${catalogueDiff.unexpected.join(',') || '-'}`
    );
  }

  if (profile.body.manifest?.toolCount !== manifestTools.length || profile.body.manifest?.version !== manifest.body.version) {
    failures.push('OpenAI MCP profile manifest metadata is stale');
  }

  for (const required of REQUIRED_PROVIDER_TOOLS) {
    if (!manifestToolNames.includes(required)) failures.push(`MCP manifest missing provider tool: ${required}`);
    if (!advertisedToolNames.includes(required)) failures.push(`MCP catalogue missing provider tool: ${required}`);
  }

  for (const [profileName, profileConfig] of Object.entries(profile.body.profiles || {})) {
    const toolBlocks = Array.isArray(profileConfig.tools) ? profileConfig.tools : [];
    const block = toolBlocks[0] || {};
    const allowedTools = sorted(block.allowed_tools || []);
    const allowedDiff = diffSets(manifestToolNames, allowedTools);
    const mutatingAllowed = allowedTools.filter((name) => manifestMutating.has(name));
    const approval = approvalRequiresMutatingTools(block.require_approval, mutatingAllowed);
    report.openaiProfile.profiles[profileName] = {
      serverLabel: block.server_label || '',
      serverUrl: block.server_url || '',
      allowedToolCount: allowedTools.length,
      allowedDiff,
      mutatingAllowedCount: mutatingAllowed.length,
      approval
    };
    if (block.type !== 'mcp') failures.push(`OpenAI MCP profile ${profileName} tool type is not mcp`);
    if (!block.server_label || !block.server_url) failures.push(`OpenAI MCP profile ${profileName} missing server_label/server_url`);
    if (allowedDiff.missing.length || allowedDiff.unexpected.length) {
      failures.push(
        `OpenAI MCP profile ${profileName} allowed_tools differs from manifest: ` +
          `missing=${allowedDiff.missing.join(',') || '-'} unexpected=${allowedDiff.unexpected.join(',') || '-'}`
      );
    }
    if (!approval.ok) {
      failures.push(`OpenAI MCP profile ${profileName} does not require approval for mutating tools`);
    }
  }
}

function providerStatusClassification(path, result) {
  if (!result.ok) return { status: 'failed', reason: result.error || `HTTP ${result.status}` };
  const body = result.body || {};
  if (path.includes('/openai/status')) {
    const keyFlag = body.apiKeyConfigured ?? body.hasApiKey ?? body.api_key_configured ?? body.apiKeyPresent;
    if (keyFlag === false) return { status: 'no-api-key', reason: 'OpenAI API key not configured' };
  }
  return { status: 'passed', reason: '' };
}

async function probeProviderSurfaces(instances, timeoutMs) {
  const results = [];
  for (const instance of instances) {
    if (!instance.peUrl) {
      results.push({ instance: instance.id || 'default', runtime: instance.runtime, status: 'failed', error: 'missing peUrl' });
      continue;
    }
    for (const path of PROVIDER_STATUS_PATHS) {
      const url = `${instance.peUrl.replace(/\/$/, '')}${path}`;
      const result = await fetchWithTimeout(url, { method: 'GET', headers: { accept: 'application/json' } }, timeoutMs);
      const classification = providerStatusClassification(path, result);
      results.push({
        instance: instance.id || 'default',
        runtime: instance.runtime,
        path,
        status: classification.status,
        reason: classification.reason,
        httpStatus: result.status,
        bodyPreview: result.bodyText.slice(0, 1024)
      });
    }
  }
  return results;
}

async function probeCompletionIngest(instances, timeoutMs) {
  const results = [];
  for (const instance of instances) {
    if (!instance.peUrl) {
      results.push({ instance: instance.id || 'default', runtime: instance.runtime, status: 'failed', error: 'missing peUrl' });
      continue;
    }
    const url = `${instance.peUrl.replace(/\/$/, '')}/api/integrations/completions`;
    const body = {
      provider: 'mcp-smoke',
      agent: 'deployment-smoke',
      correlationId: `mcp-smoke-${Date.now()}`,
      sensorId: 'mcp.smoke.provider.completion',
      region: { offset: 4200, length: 4 },
      values: [1, 0, 0.75, 0],
      ttlMs: 60000,
      triggerPush: false
    };
    const result = await fetchWithTimeout(url, {
      method: 'POST',
      headers: { accept: 'application/json', 'content-type': 'application/json' },
      body: JSON.stringify(body)
    }, timeoutMs);
    results.push({
      instance: instance.id || 'default',
      runtime: instance.runtime,
      status: result.ok ? 'passed' : 'failed',
      httpStatus: result.status,
      error: result.ok ? '' : result.error || result.bodyText.slice(0, 512),
      bodyPreview: result.bodyText.slice(0, 1024)
    });
  }
  return results;
}

async function writeReport(path, report) {
  await mkdir(dirname(path), { recursive: true });
  await writeFile(path, `${JSON.stringify(report, null, 2)}\n`, 'utf8');
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const failures = [];
  const report = {
    status: 'planned',
    mcpUrl: args.mcpUrl,
    registryPath: args.registry,
    manifestPath: args.manifest,
    openaiProfilePath: args.profile,
    health: null,
    initialize: null,
    toolCatalogue: null,
    smokeTools: [],
    toolCoverage: { exercised: [], advertised: [], unexercised: [] },
    mutationPolicy: null,
    providerSurfaces: [],
    completionIngest: [],
    failures,
    warnings: []
  };

  const registry = await readRegistry(args.registry);
  if (Array.isArray(registry)) {
    report.instances = registry;
  } else {
    report.instances = [];
    report.warnings.push(`could not read registry ${args.registry}: ${registry.error}`);
  }

  report.health = await fetchWithTimeout(`${args.mcpUrl.replace(/\/$/, '')}/healthz`, {
    method: 'GET',
    headers: { accept: 'application/json' }
  }, args.timeoutMs);
  if (!report.health.ok) failures.push(`MCP /healthz failed: ${report.health.error || report.health.status}`);

  const initPayload = jsonRpc(1, 'initialize', {
    protocolVersion: '2025-03-26',
    capabilities: {},
    clientInfo: { name: 'realityengine-regression', version: '1.0.0' }
  });
  report.initialize = await postMcp(args.mcpUrl, initPayload, '', args.timeoutMs);
  const sessionId = report.initialize.headers['mcp-session-id'] || '';
  report.initialize.sessionId = sessionId;
  if (!report.initialize.ok || bodyError(report.initialize)) {
    failures.push(`MCP initialize failed: ${bodyError(report.initialize) || report.initialize.error || report.initialize.status}`);
  }

  if (sessionId) {
    await postMcp(args.mcpUrl, { jsonrpc: '2.0', method: 'notifications/initialized' }, sessionId, args.timeoutMs);
  }

  report.toolCatalogue = await postMcp(args.mcpUrl, jsonRpc(2, 'tools/list'), sessionId, args.timeoutMs);
  const tools = toolListFromResponse(report.toolCatalogue);
  report.toolCatalogue.toolCount = tools.length;
  report.toolCatalogue.toolNames = tools.map((tool) => tool.name).sort();
  if (!report.toolCatalogue.ok || bodyError(report.toolCatalogue) || tools.length === 0) {
    failures.push(`MCP tools/list failed: ${bodyError(report.toolCatalogue) || report.toolCatalogue.error || report.toolCatalogue.status || 'empty tool catalogue'}`);
  }

  const available = new Set(report.toolCatalogue.toolNames || []);
  const manifest = await readJson(args.manifest);
  const profile = await readJson(args.profile);

  // Default to the whole read surface. An explicit --tool overrides.
  if (args.tools.length === 0) args.tools = readOnlyToolsFrom(manifest.body);
  report.toolCoverage = {
    exercised: [...args.tools],
    advertised: [...available].sort(),
    unexercised: [...available].filter((name) => !args.tools.includes(name)).sort()
  };

  validateManifestAndProfile({
    manifest,
    profile,
    advertisedToolNames: report.toolCatalogue.toolNames || [],
    failures,
    report
  });

  if (available.has('integrations.completion')) {
    const mutationResult = await postMcp(args.mcpUrl, jsonRpc(3, 'tools/call', {
      name: 'integrations.completion',
      arguments: {
        provider: 'mcp-smoke',
        agent: 'policy-check',
        values: [0, 0, 0, 0],
        sensorId: 'mcp.smoke.policy',
        region: { offset: 4200, length: 4 },
        triggerPush: false
      }
    }), sessionId, args.timeoutMs);
    report.mutationPolicy = {
      tool: 'integrations.completion',
      status: toolCallIsError(mutationResult) ? 'default-denied' : 'failed',
      httpStatus: mutationResult.status,
      error: bodyError(mutationResult) || mutationResult.error || ''
    };
    if (!toolCallIsError(mutationResult)) {
      failures.push('MCP mutating completion tool was not default-denied by policy');
    }
  } else {
    report.mutationPolicy = { status: 'failed', error: 'integrations.completion not advertised' };
    failures.push('MCP mutating completion tool not advertised for policy check');
  }

  const instances = report.instances.length ? report.instances : [{ id: '', runtime: 'default' }];
  let nextId = 10;

  // Some read tools address a specific entity. Discover a real id per instance
  // rather than probing with a synthetic one, which would report a genuine
  // 404 as a tool defect.
  const callTool = async (toolName, toolArgs) => {
    const res = await postMcp(
      args.mcpUrl,
      jsonRpc(nextId++, 'tools/call', { name: toolName, arguments: toolArgs }),
      sessionId,
      args.timeoutMs
    );
    return res;
  };

  const firstIdFrom = (result, ...keys) => {
    const text = result?.body?.result?.content?.map((c) => c.text).join('') ?? '';
    let parsed;
    try {
      parsed = JSON.parse(text);
    } catch {
      return '';
    }
    // Tool results wrap the engine payload as
    // { instance, target, request, result: <engine body> }.
    const payload = parsed?.result ?? parsed;
    for (const key of keys) {
      const list = Array.isArray(payload) ? payload : payload?.[key];
      if (Array.isArray(list) && list.length) {
        const entry = list[0];
        const id = typeof entry === 'string' ? entry : entry?.id ?? entry?.dispatchId;
        if (id) return String(id);
      }
    }
    return '';
  };

  const probeArgsFor = async (toolName, instance) => {
    const base = instance.id ? { instance: instance.id } : {};
    if (toolName === 're.read_machine') {
      const listed = await callTool('re.list_machines', base);
      const id = firstIdFrom(listed, 'machines');
      return id ? { ...base, id } : null;
    }
    if (toolName === 'dispatch.read_record') {
      const ledger = await callTool('dispatch.read_ledger', base);
      const id = firstIdFrom(ledger, 'records', 'ledger', 'dispatches');
      return id ? { ...base, id } : null;
    }
    return base;
  };

  for (const toolName of args.tools) {
    if (!available.has(toolName)) {
      report.smokeTools.push({ tool: toolName, status: 'skipped', reason: 'tool not advertised' });
      continue;
    }
    for (const instance of instances) {
      const toolArgs = await probeArgsFor(toolName, instance);
      if (!toolArgs) {
        // Nothing of this kind exists yet on a cold universe. Not a defect,
        // but recorded so an empty run cannot masquerade as coverage.
        report.smokeTools.push({
          tool: toolName,
          instance: instance.id || 'default',
          runtime: instance.runtime,
          status: 'skipped',
          reason: 'no entity available to address on this instance'
        });
        continue;
      }
      const result = await callTool(toolName, toolArgs);
      const error = bodyError(result);
      const status = result.ok && !error ? 'passed' : 'failed';
      report.smokeTools.push({
        tool: toolName,
        instance: instance.id || 'default',
        runtime: instance.runtime,
        status,
        httpStatus: result.status,
        error: error || result.error || '',
        resultPreview: result.bodyText.slice(0, 1024)
      });
      if (status === 'failed') {
        failures.push(`MCP ${toolName} failed for ${instance.id || 'default'}: ${error || result.error || result.status}`);
      }
    }
  }

  const providerInstances = report.instances.length ? report.instances : [];
  if (providerInstances.length) {
    report.providerSurfaces = await probeProviderSurfaces(providerInstances, args.timeoutMs);
    for (const probe of report.providerSurfaces) {
      if (probe.status === 'failed') {
        failures.push(`PE provider surface ${probe.path} failed for ${probe.instance}: ${probe.reason || probe.error || probe.httpStatus}`);
      }
    }
    if (args.completionIngest) {
      report.completionIngest = await probeCompletionIngest(providerInstances, args.timeoutMs);
      for (const probe of report.completionIngest) {
        if (probe.status === 'failed') {
          failures.push(`PE completion ingest failed for ${probe.instance}: ${probe.error || probe.httpStatus}`);
        }
      }
    } else {
      report.completionIngest = [{ status: 'skipped', reason: '--skip-completion-ingest' }];
    }
  } else {
    report.warnings.push('skipped PE provider surface probes because no running registry instances were available');
  }

  report.status = failures.length ? 'failed' : 'passed';
  await writeReport(args.out, report);
  if (failures.length) {
    console.error('MCP smoke failed:');
    for (const failure of failures) console.error(`- ${failure}`);
    console.error(args.out);
    process.exit(1);
  }
  console.log(`PASS MCP smoke: ${tools.length} tool(s), ${report.smokeTools.length} read-only call(s)`);
  console.log(args.out);
}

main().catch(async (err) => {
  console.error(err.stack || err.message);
  process.exit(1);
});
