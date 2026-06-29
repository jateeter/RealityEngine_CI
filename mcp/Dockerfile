# RealityEngine MCP Gateway — Streamable HTTP image.
#
# Build (from RealityEngine_CI root):
#   docker build -t realityengine-mcp -f mcp/Dockerfile mcp
#
# Run (registry-aware; reach the host registry/engines):
#   docker run --rm -p 7331:7331 \
#     -e RE_REGISTRY_URL=http://host.docker.internal:5999 \
#     -e RE_MCP_HTTP_HOST=0.0.0.0 \
#     realityengine-mcp
#
# The OpenAPI specs in ../docs/openapi are NOT copied into this image; the
# `realityengine://openapi/*` resources are only served when the gateway runs
# from a full RealityEngine_CI checkout. Tool endpoints work regardless.

FROM node:22-alpine

WORKDIR /app

# Install dependencies first for layer caching.
COPY package.json ./
RUN npm install --omit=dev --no-audit --no-fund

COPY bin ./bin
COPY src ./src
COPY manifest.json ./

ENV RE_MCP_HTTP_HOST=0.0.0.0 \
    RE_MCP_HTTP_PORT=7331

EXPOSE 7331

USER node

# Default to the HTTP transport for container/ecosystem use.
# Override the entrypoint to `node bin/realityengine-mcp.js` for stdio.
CMD ["node", "src/http-server.js"]

HEALTHCHECK --interval=30s --timeout=4s --start-period=5s --retries=3 \
  CMD wget -qO- http://127.0.0.1:7331/healthz || exit 1
