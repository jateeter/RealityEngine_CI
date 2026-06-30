#!/usr/bin/env node
// Regression smoke checks for the RealityEngine MCP Streamable HTTP endpoint.

import { readFile, writeFile, mkdir } from 'node:fs/promises';
import { dirname } from 'node:path';

const READ_ONLY_SMOKE_TOOLS = [
  're.read_state',
  're.list_machines',
  'pe.read_state',
  'dispatch.read_ledger'
];

function usage() {
  console.log(`regression-mcp-smoke.mjs

Usage:
  node scripts/regression-mcp-smoke.mjs --mcp-url URL --out PATH [options]

Options:
  --mcp-url URL       MCP HTTP base URL. Default: http://127.0.0.1:7331
  --registry PATH     Runtime registry JSON. Default: /tmp/re-registry/re-registry.json
  --out PATH          Report path. Required.
  --timeout-ms N      Request timeout. Default: 15000
  --tool NAME         Read-only tool smoke to run. Repeatable.
  --help              Show this help.
`);
}

function parseArgs(argv) {
  const args = {
    mcpUrl: 'http://127.0.0.1:7331',
    registry: '/tmp/re-registry/re-registry.json',
    out: '',
    timeoutMs: 15000,
    tools: []
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
    } else {
      throw new Error(`unknown argument: ${arg}`);
    }
  }
  if (!args.out) throw new Error('missing --out');
  if (!Number.isFinite(args.timeoutMs) || args.timeoutMs <= 0) throw new Error('invalid --timeout-ms');
  if (args.tools.length === 0) args.tools = [...READ_ONLY_SMOKE_TOOLS];
  return args;
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

function toolListFromResponse(result) {
  const tools = result?.body?.result?.tools;
  return Array.isArray(tools) ? tools : [];
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
    health: null,
    initialize: null,
    toolCatalogue: null,
    smokeTools: [],
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
  const instances = report.instances.length ? report.instances : [{ id: '', runtime: 'default' }];
  let nextId = 10;
  for (const toolName of args.tools) {
    if (!available.has(toolName)) {
      report.smokeTools.push({ tool: toolName, status: 'skipped', reason: 'tool not advertised' });
      continue;
    }
    for (const instance of instances) {
      const toolArgs = instance.id ? { instance: instance.id } : {};
      const result = await postMcp(args.mcpUrl, jsonRpc(nextId, 'tools/call', { name: toolName, arguments: toolArgs }), sessionId, args.timeoutMs);
      nextId += 1;
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
