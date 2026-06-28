// Builds the RealityEngine MCP server: registers RE/PE tools and resources.
// Shared by the stdio entrypoint (bin/realityengine-mcp.js) and the
// Streamable HTTP entrypoint (src/http-server.js).

import { readFileSync, readdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

import { McpServer, ResourceTemplate } from '@modelcontextprotocol/sdk/server/mcp.js';

import { settings, mutationPolicy, listInstances, resolveBaseUrl } from './config.js';
import { httpRequest } from './http-client.js';
import { TOOLS, toolByName } from './tools.js';

const __dirname = dirname(fileURLToPath(import.meta.url));
const OPENAPI_DIR = join(__dirname, '..', '..', 'docs', 'openapi');

function jsonText(value) {
  return { content: [{ type: 'text', text: JSON.stringify(value, null, 2) }] };
}

function errText(message) {
  return { isError: true, content: [{ type: 'text', text: message }] };
}

export function createServer() {
  const policy = mutationPolicy();
  const server = new McpServer({
    name: settings.serverName,
    version: settings.serverVersion,
  });

  // ---- Tools ----
  for (const tool of TOOLS) {
    server.registerTool(
      tool.name,
      {
        title: tool.title,
        description:
          tool.description +
          (tool.mutating ? ' [mutating — gated by RE_MCP_ALLOW_MUTATION / RE_MCP_ALLOWED_TOOLS]' : ''),
        inputSchema: tool.input,
      },
      async (args = {}) => {
        if (!policy.isAllowed(tool.name, tool.mutating)) {
          return errText(
            `Tool "${tool.name}" is disabled by policy. Enable with RE_MCP_ALLOW_MUTATION=true ` +
              `or add it to RE_MCP_ALLOWED_TOOLS.`
          );
        }
        try {
          const { baseUrl, instance } = await resolveBaseUrl(tool.target, args.instance);
          const { method, path, body } = tool.build(args);
          const result = await httpRequest(baseUrl, method, path, body);
          return jsonText({
            instance: { id: instance.id, runtime: instance.runtime },
            target: tool.target,
            request: { method, path },
            result,
          });
        } catch (err) {
          return errText(err.message);
        }
      }
    );
  }

  // ---- Resource: live instance registry ----
  server.registerResource(
    'instances',
    'realityengine://instances',
    {
      title: 'RealityEngine instances',
      description: 'Live RE/PE instances discovered from the registry or env config.',
      mimeType: 'application/json',
    },
    async (uri) => {
      const instances = await listInstances();
      return {
        contents: [{ uri: uri.href, mimeType: 'application/json', text: JSON.stringify(instances, null, 2) }],
      };
    }
  );

  // ---- Resources: the generated OpenAPI specs ----
  let specFiles = [];
  try {
    specFiles = readdirSync(OPENAPI_DIR).filter((f) => /-(re|pe)\.yaml$/.test(f));
  } catch {
    /* specs not present at runtime (e.g. packaged separately) — skip */
  }
  if (specFiles.length) {
    server.registerResource(
      'openapi',
      new ResourceTemplate('realityengine://openapi/{file}', {
        list: async () => ({
          resources: specFiles.map((f) => ({
            uri: `realityengine://openapi/${f}`,
            name: f,
            mimeType: 'application/yaml',
          })),
        }),
      }),
      {
        title: 'RealityEngine OpenAPI specs',
        description: 'Generated OpenAPI 3.1 contracts for each runtime/service (cpp|lsp|scala × re|pe).',
        mimeType: 'application/yaml',
      },
      async (uri, { file }) => {
        if (!specFiles.includes(file)) throw new Error(`Unknown spec: ${file}`);
        const text = readFileSync(join(OPENAPI_DIR, file), 'utf8');
        return { contents: [{ uri: uri.href, mimeType: 'application/yaml', text }] };
      }
    );
  }

  return server;
}

// Used by `--list-tools` and the manifest cross-check.
export function describeTools() {
  const policy = mutationPolicy();
  return TOOLS.map((t) => ({
    name: t.name,
    title: t.title,
    target: t.target,
    mutating: t.mutating,
    enabled: policy.isAllowed(t.name, t.mutating),
  }));
}

export { TOOLS, toolByName };
