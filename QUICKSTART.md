# Reality Engine — Quick Start

Get the full Reality Engine universe running in one command.

## Prerequisites

- Docker Desktop installed and running
- 4 GB+ RAM available
- Ports 3000–3005, 5173, 6333, 3100 free

## First-Time Setup

```bash
# Generate dev TLS certificates (once per machine)
bash certs/generate-dev-certs.sh
```

This creates `certs/server.crt` and `certs/server.key` used by the nginx TLS proxy.

## Start the Universe

```bash
# Start localAIStack (Qdrant + Redis + API) + all Reality Engine services
./startUniverse.sh

# First run or after schema changes — wipe perception sources + rebuild with --no-cache
./startUniverse.sh --fresh
```

`startUniverse.sh` brings up the full stack and verifies machine/sensor/Qdrant integration before returning.

If localAIStack is already running and you only need to (re)start Reality Engine services:

```bash
./scripts/start.sh
```

## Service URLs

| Service | URL |
|---|---|
| Visualizer Frontend | https://localhost:5173 |
| Perception Engine UI | https://localhost:3005 |
| Grafana Logs | https://localhost:3002 (admin / admin) |
| Reality Engine API | https://localhost:3000 |
| Visualizer Backend | https://localhost:3001 |
| Perception Engine API | https://localhost:3004 |
| Qdrant Dashboard | http://localhost:6333/dashboard |

Browsers will warn about the self-signed certificate — add an exception or use `--ignore-certificate-errors` in Playwright.

## Common Commands

```bash
./startUniverse.sh              # start full universe (cached build)
./startUniverse.sh --fresh      # wipe perception data + rebuild RE with --no-cache
./scripts/start.sh              # Reality Engine only (localAIStack must be running)
./scripts/stop.sh               # stop all Reality Engine services
./scripts/restart.sh            # stop + start
./scripts/status.sh             # health summary
./scripts/logs.sh               # tail logs for all services
docker compose ps               # container status and health checks
docker compose logs -f <svc>    # stream logs for one service
```

## Try the API

```bash
# Health check
curl -k https://localhost:3000/api/health

# List registered machines
curl -k https://localhost:3000/api/machines

# Engine statistics
curl -k https://localhost:3000/api/engine/stats
```

## Next Steps

- **[README.md](README.md)** — full architecture and core concepts
- **[ARCHITECTURE.md](ARCHITECTURE.md)** — service design and data flow
- **[API_ENDPOINTS_GUIDE.md](API_ENDPOINTS_GUIDE.md)** — complete API reference
- **[VISUALIZER_USER_GUIDE.md](VISUALIZER_USER_GUIDE.md)** — Tobias canvas walkthrough
- **[E2E_TESTING.md](E2E_TESTING.md)** — Playwright e2e test guide
