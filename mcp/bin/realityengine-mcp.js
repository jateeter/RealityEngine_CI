#!/usr/bin/env node
// RealityEngine MCP gateway — stdio entrypoint.
//
// This is the binary referenced by MCP clients (Claude Code/Desktop, etc.):
//   { "command": "node", "args": ["mcp/bin/realityengine-mcp.js"] }
//
// Flags:
//   --list-tools   Print the tool catalogue (name, target, mutating, enabled) and exit.
//   --version      Print version and exit.
//
// Discovery + policy are env-driven; see mcp/README.md.

import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import { createServer, describeTools } from '../src/server.js';
import { settings } from '../src/config.js';
import { insecureTlsAllowed } from '../src/lane-tls.js';

// Accept self-signed TLS proxy certs when explicitly opted in, off the lane only.
if (insecureTlsAllowed()) {
  process.env.NODE_TLS_REJECT_UNAUTHORIZED = '0';
}

const argv = process.argv.slice(2);

if (argv.includes('--version')) {
  console.log(settings.serverVersion);
  process.exit(0);
}

if (argv.includes('--list-tools')) {
  // eslint-disable-next-line no-console
  console.log(JSON.stringify(describeTools(), null, 2));
  process.exit(0);
}

async function main() {
  const server = createServer();
  const transport = new StdioServerTransport();
  await server.connect(transport);
  // Logging must go to stderr — stdout is the MCP transport.
  process.stderr.write(`[realityengine-mcp] stdio transport ready (server=${settings.serverName})\n`);
}

main().catch((err) => {
  process.stderr.write(`[realityengine-mcp] fatal: ${err.stack || err.message}\n`);
  process.exit(1);
});
