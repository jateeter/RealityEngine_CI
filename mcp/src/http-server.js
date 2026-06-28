// RealityEngine MCP gateway — Streamable HTTP entrypoint.
//
// Exposes the MCP server over Streamable HTTP at POST/GET/DELETE /mcp for
// ecosystem integration (remote MCP clients, gateways, other services).
// Sessions are tracked by the `mcp-session-id` response/request header.
//
//   RE_MCP_HTTP_HOST (default 127.0.0.1)
//   RE_MCP_HTTP_PORT (default 7331)
//
// A plain GET /healthz is provided for liveness checks.

import { createServer as createHttpServer } from 'node:http';
import { randomUUID } from 'node:crypto';

import { StreamableHTTPServerTransport } from '@modelcontextprotocol/sdk/server/streamableHttp.js';
import { createServer as createMcpServer } from './server.js';
import { settings } from './config.js';

if (/^(1|true|yes)$/i.test(process.env.RE_MCP_INSECURE_TLS ?? '')) {
  process.env.NODE_TLS_REJECT_UNAUTHORIZED = '0';
}

// Active transports keyed by session id.
const transports = new Map();

async function readBody(req) {
  const chunks = [];
  for await (const chunk of req) chunks.push(chunk);
  if (!chunks.length) return undefined;
  const raw = Buffer.concat(chunks).toString('utf8');
  try {
    return JSON.parse(raw);
  } catch {
    return raw;
  }
}

function sendJson(res, status, obj) {
  const body = JSON.stringify(obj);
  res.writeHead(status, { 'content-type': 'application/json' });
  res.end(body);
}

const httpServer = createHttpServer(async (req, res) => {
  const url = new URL(req.url, `http://${req.headers.host}`);

  if (url.pathname === '/healthz') {
    return sendJson(res, 200, { status: 'ok', server: settings.serverName, version: settings.serverVersion });
  }

  if (url.pathname !== '/mcp') {
    return sendJson(res, 404, { error: 'not found', hint: 'MCP endpoint is /mcp' });
  }

  const sessionId = req.headers['mcp-session-id'];
  let transport = sessionId ? transports.get(sessionId) : undefined;

  try {
    if (req.method === 'POST') {
      const body = await readBody(req);
      const isInit =
        body && typeof body === 'object' && !Array.isArray(body) && body.method === 'initialize';

      if (!transport && isInit) {
        // New session: spin up a fresh server + transport pair.
        transport = new StreamableHTTPServerTransport({
          sessionIdGenerator: () => randomUUID(),
          onsessioninitialized: (id) => transports.set(id, transport),
        });
        transport.onclose = () => {
          if (transport.sessionId) transports.delete(transport.sessionId);
        };
        const mcp = createMcpServer();
        await mcp.connect(transport);
      } else if (!transport) {
        return sendJson(res, 400, {
          jsonrpc: '2.0',
          error: { code: -32000, message: 'No valid session. Send an initialize request first.' },
          id: null,
        });
      }
      return transport.handleRequest(req, res, body);
    }

    if (req.method === 'GET' || req.method === 'DELETE') {
      if (!transport) {
        return sendJson(res, 400, { error: 'Unknown or missing mcp-session-id' });
      }
      return transport.handleRequest(req, res);
    }

    res.writeHead(405, { allow: 'GET, POST, DELETE' });
    res.end();
  } catch (err) {
    process.stderr.write(`[realityengine-mcp:http] error: ${err.stack || err.message}\n`);
    if (!res.headersSent) sendJson(res, 500, { error: err.message });
  }
});

httpServer.listen(settings.httpPort, settings.httpHost, () => {
  process.stderr.write(
    `[realityengine-mcp:http] listening on http://${settings.httpHost}:${settings.httpPort}/mcp ` +
      `(health: /healthz)\n`
  );
});
