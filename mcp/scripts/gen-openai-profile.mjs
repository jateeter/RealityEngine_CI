#!/usr/bin/env node
// Generate an OpenAI Responses API MCP tool profile from the checked
// RealityEngine MCP manifest and integration registry hints.

import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, join, relative } from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const MCP_DIR = join(__dirname, '..');
const REPO_DIR = join(MCP_DIR, '..');
const DEFAULT_MANIFEST = join(MCP_DIR, 'manifest.json');
const DEFAULT_REGISTRY = join(REPO_DIR, 'config', 'integrations.example.json');
const DEFAULT_SCHEMA = './schemas/openai-mcp-profile.schema.json';
const DEFAULT_OUT = join(MCP_DIR, 'openai-mcp-profile.json');
const UNSAFE_FLAG = '--allow-unsafe-never-approval';

function usage() {
  console.log(`gen-openai-profile.mjs

Usage:
  node scripts/gen-openai-profile.mjs [options]

Options:
  --manifest PATH              MCP manifest. Default: mcp/manifest.json
  --registry PATH              Integration registry hints. Default: config/integrations.example.json
  --out PATH                   Output profile. Default: mcp/openai-mcp-profile.json
  --check                      Fail if the output file is stale
  --allowed-tools a,b,c        Override the allowed_tools list
  --server-url URL             Override local profile server_url
  --server-label LABEL         Override local profile server_label
  --require-approval MODE      always|never|policy. Default: policy
  ${UNSAFE_FLAG}  Permit require_approval=never with mutating tools
`);
}

function parseArgs(argv) {
  const args = {
    manifest: DEFAULT_MANIFEST,
    registry: DEFAULT_REGISTRY,
    out: DEFAULT_OUT,
    check: false,
    allowedTools: null,
    serverUrl: '',
    serverLabel: '',
    requireApproval: 'policy',
    allowUnsafeNeverApproval: false,
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
    } else if (arg === '--manifest') {
      args.manifest = next();
    } else if (arg.startsWith('--manifest=')) {
      args.manifest = arg.slice('--manifest='.length);
    } else if (arg === '--registry') {
      args.registry = next();
    } else if (arg.startsWith('--registry=')) {
      args.registry = arg.slice('--registry='.length);
    } else if (arg === '--out') {
      args.out = next();
    } else if (arg.startsWith('--out=')) {
      args.out = arg.slice('--out='.length);
    } else if (arg === '--check') {
      args.check = true;
    } else if (arg === '--allowed-tools') {
      args.allowedTools = splitList(next());
    } else if (arg.startsWith('--allowed-tools=')) {
      args.allowedTools = splitList(arg.slice('--allowed-tools='.length));
    } else if (arg === '--server-url') {
      args.serverUrl = next();
    } else if (arg.startsWith('--server-url=')) {
      args.serverUrl = arg.slice('--server-url='.length);
    } else if (arg === '--server-label') {
      args.serverLabel = next();
    } else if (arg.startsWith('--server-label=')) {
      args.serverLabel = arg.slice('--server-label='.length);
    } else if (arg === '--require-approval') {
      args.requireApproval = next();
    } else if (arg.startsWith('--require-approval=')) {
      args.requireApproval = arg.slice('--require-approval='.length);
    } else if (arg === UNSAFE_FLAG) {
      args.allowUnsafeNeverApproval = true;
    } else {
      throw new Error(`unknown argument: ${arg}`);
    }
  }
  if (!['always', 'never', 'policy'].includes(args.requireApproval)) {
    throw new Error('--require-approval must be one of: always, never, policy');
  }
  return args;
}

function splitList(value) {
  return String(value || '')
    .split(',')
    .map((item) => item.trim())
    .filter(Boolean);
}

function readJson(path, fallback = null) {
  try {
    return JSON.parse(readFileSync(path, 'utf8'));
  } catch (err) {
    if (fallback !== null) return fallback;
    throw new Error(`failed to read ${path}: ${err.message}`);
  }
}

function registryMcpConfig(registry) {
  return (registry.integrations || []).find((item) => item?.kind === 'mcp') || {};
}

function sortedUnique(values) {
  return [...new Set(values)].sort((a, b) => a.localeCompare(b));
}

function validateAllowedTools(allowedTools, toolsByName) {
  const unknown = allowedTools.filter((name) => !toolsByName.has(name));
  if (unknown.length) {
    throw new Error(`allowed_tools contains unknown MCP tool(s): ${unknown.join(', ')}`);
  }
}

function approvalPolicy(allowedTools, toolsByName, mode, allowUnsafeNeverApproval) {
  const mutating = allowedTools.filter((name) => toolsByName.get(name)?.mutating);
  const readOnly = allowedTools.filter((name) => !toolsByName.get(name)?.mutating);
  if (mode === 'always') return 'always';
  if (mode === 'never') {
    if (mutating.length && !allowUnsafeNeverApproval) {
      throw new Error(
        `refusing require_approval=never for mutating tool(s): ${mutating.join(', ')}. ` +
          `Pass ${UNSAFE_FLAG} only for an intentionally unsafe local fixture.`
      );
    }
    return 'never';
  }
  return {
    always: { tool_names: sortedUnique(mutating) },
    never: { tool_names: sortedUnique(readOnly) },
  };
}

function buildProfile(args) {
  const manifest = readJson(args.manifest);
  const registry = readJson(args.registry, {});
  const mcpRegistry = registryMcpConfig(registry);
  const tools = manifest.tools || [];
  const toolsByName = new Map(tools.map((tool) => [tool.name, tool]));
  const allowedTools = sortedUnique(args.allowedTools?.length ? args.allowedTools : tools.map((tool) => tool.name));
  validateAllowedTools(allowedTools, toolsByName);
  const requireApproval = approvalPolicy(allowedTools, toolsByName, args.requireApproval, args.allowUnsafeNeverApproval);
  const localServerUrl = args.serverUrl || mcpRegistry.serverUrl || 'http://127.0.0.1:7331/mcp';
  const localServerLabel = args.serverLabel || mcpRegistry.serverLabel || 'realityengine-local';
  const serverDescription =
    'RealityEngine MCP gateway exposing RE/PE read tools and policy-gated provider completion/dispatch tools.';

  return {
    $schema: DEFAULT_SCHEMA,
    _generated: 'Generated by scripts/gen-openai-profile.mjs from manifest.json and config/integrations.example.json -- do not edit by hand.',
    name: 'realityengine-openai-mcp-profile',
    version: manifest.version,
    manifest: {
      name: manifest.name,
      version: manifest.version,
      toolCount: tools.length,
    },
    profiles: {
      local: {
        description: 'Local OpenAI Responses API MCP profile for the RealityEngine Streamable HTTP gateway.',
        environment: {
          RE_MCP_ALLOW_MUTATION: 'false',
          RE_MCP_ALLOWED_TOOLS: '',
          RE_MCP_HTTP_HOST: '127.0.0.1',
          RE_MCP_HTTP_PORT: '7331',
        },
        tools: [
          {
            type: 'mcp',
            server_label: localServerLabel,
            server_description: serverDescription,
            server_url: localServerUrl,
            allowed_tools: allowedTools,
            require_approval: requireApproval,
            defer_loading: true,
          },
        ],
      },
      secureTunnel: {
        description: 'Remote OpenAI Responses API MCP profile for a secured tunnel in front of the same gateway.',
        environment: {
          RE_MCP_HTTP_HOST: '127.0.0.1',
          RE_MCP_HTTP_PORT: '7331',
          RE_MCP_BEARER_TOKEN: '${RE_MCP_BEARER_TOKEN}',
        },
        tools: [
          {
            type: 'mcp',
            server_label: 'realityengine-secure-tunnel',
            server_description: serverDescription,
            server_url: 'https://REPLACE_WITH_SECURE_MCP_TUNNEL_HOST/mcp',
            allowed_tools: allowedTools,
            require_approval: requireApproval,
            defer_loading: true,
            headers: {
              Authorization: 'Bearer ${RE_MCP_BEARER_TOKEN}',
            },
          },
        ],
      },
    },
  };
}

function assertProfileShape(profile) {
  for (const profileName of ['local', 'secureTunnel']) {
    const item = profile.profiles?.[profileName];
    if (!item || !Array.isArray(item.tools) || item.tools.length !== 1) {
      throw new Error(`profile ${profileName} must contain exactly one OpenAI MCP tool block`);
    }
    const tool = item.tools[0];
    for (const key of ['type', 'server_label', 'server_description', 'server_url', 'allowed_tools', 'require_approval']) {
      if (tool[key] === undefined) throw new Error(`profile ${profileName} missing ${key}`);
    }
    if (tool.type !== 'mcp') throw new Error(`profile ${profileName} type must be "mcp"`);
    if (!/^https?:\/\//.test(tool.server_url)) throw new Error(`profile ${profileName} server_url must be http(s)`);
    if (!Array.isArray(tool.allowed_tools) || tool.allowed_tools.length === 0) {
      throw new Error(`profile ${profileName} allowed_tools must be a non-empty array`);
    }
  }
}

const args = parseArgs(process.argv.slice(2));
const profile = buildProfile(args);
assertProfileShape(profile);
const next = `${JSON.stringify(profile, null, 2)}\n`;

if (args.check) {
  let current = '';
  try {
    current = readFileSync(args.out, 'utf8');
  } catch {
    /* missing -> stale */
  }
  if (current !== next) {
    const relOut = relative(process.cwd(), args.out);
    process.stderr.write(`${relOut} is stale. Run: npm run openai-profile:gen\n`);
    process.exit(1);
  }
  process.stdout.write('openai-mcp-profile.json is up to date.\n');
} else {
  writeFileSync(args.out, next);
  process.stdout.write(`wrote ${args.out}\n`);
}
