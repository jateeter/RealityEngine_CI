# Multi-Engine Roadmap — Simultaneous RE Instances on a Single Host

Enables spawning multiple RealityEngine runtimes (Scala, C++, LSP) simultaneously
on the same machine, each bound to the host's LAN IP, with `RealityEngine_Manager`
able to dynamically connect to any running instance.

---

## Status: All Phases Delivered ✓

Verified 2026-09-10 against a live `--engines=cpp:1,lsp:1,scala:1` universe, by
checking the shipped artifact for each phase rather than by reading the plan.

| Phase | Delivered as | Evidence |
|---|---|---|
| 1 · Host IP detection | `scripts/detect-host-ip.sh` | registry publishes `192.168.1.194`, not `localhost` |
| 2 · Instance registry | `scripts/registry.sh` + REST shim | `GET :5999/re-registry.json` → 200, three instances |
| 3 · Port allocation | `scripts/allocate-ports.sh` | `allocate_ports <runtime> <index>`, base + (index−1)×100 |
| 4 · Multi-instance flags | `startUniverse.sh --engines=SPEC` | the canonical launch in the workspace `CLAUDE.md` |
| 5a · Manager registry polling | `GET /api/engines`, `POST /api/engines/active` | live on `:3001`, returns all three instances |
| 5b · Engine switcher UI | `visualizer/frontend/src/components/EngineSwitcher.tsx` | present |
| 5c · Backward compatibility | `RE_BASE_URL` / `PE_BASE_URL` fallback | the fallback every spec in `RealityEngine_Machines` uses |
| 6 · Nginx dynamic upstreams | `scripts/gen-nginx-upstreams.sh` | generates `nginx/conf.d/multi-engine-upstreams.conf` |
| 7 · Per-instance teardown | `stopUniverse.sh --instance=`, `--engines-only` | both flags present |
| 8 · Test suite adaptation | `RealityEngine_Machines/tests/integration/multi-instance.spec.ts` | present; registry-backed specs are now the norm |
| 9 · CI multi-engine job | `multi-engine-and-parity-tests` in `.github/workflows/e2e-tests.yml` | the job that gates every PR |

**This file is planning history.** It records what was intended; the sections
below are preserved as written, including sketch code that differs from what
shipped. For current behaviour read `startUniverse.sh --help`, the live
registry, and `docs/BUILD_CONTROL_CONTRACT.md`.

### What shipped differently

Worth stating, because the plan's literals are the kind a reader copies:

- **Registry path.** `RE_REGISTRY_FILE` defaults to
  `/tmp/re-registry/re-registry.json`, not `/tmp/re-registry.json` as sketched
  below. The URL is unchanged.
- **Scala's ports.** The table below says Scala RE :5001 / PE :5000. Native
  multi-engine mode runs `SCALA_PE_BASE=5100`, so `scala-1` is RE :5101 /
  PE :5100 — the Docker footprint holds 5000/5001. **The registry is the source
  of truth for what any instance is actually listening on**; a document that
  restates a port is a second copy that can go stale, which is what happened
  here.
- **Deterministic vs free ports.** `--free-ports` claims ports the OS reports
  free instead of computing them from a base (#278). Deterministic is the
  default; the hosted lane uses `--free-ports`, which is why workflow endpoint
  literals were removed in favour of registry resolution.
- **Beyond the plan.** Engine selection grew corpus, machine-load, PE-bootstrap
  and provenance controls the plan never anticipated — `--machine-load`,
  `--machine-corpus`, `--pe-source-bootstrap`, and the build-provenance gate
  that refuses to launch stale artifacts.

---

## Target State

```
Host LAN IP: 192.168.1.42 (auto-detected)

Instance 1 — scala-1   RE :5001  PE :5000
Instance 2 — cpp-1     RE :5101  PE :5100
Instance 3 — cpp-2     RE :5201  PE :5200
Instance 4 — lsp-1     RE :5301  PE :5300

Registry (JSON file + REST shim): /tmp/re-registry.json
Manager: switchable via UI dropdown — active instance = one RE+PE URL pair
```

---

## Phase 1 · Host IP Detection Utility  ✓ Delivered

Extract the host's primary LAN IP once at startup and export it for all
downstream consumers. All URLs emitted hereafter use this IP, not `localhost`.

**`scripts/detect-host-ip.sh`** (new):
```bash
#!/bin/bash
# Returns primary non-loopback IPv4 address
if command -v ip >/dev/null 2>&1; then
    ip route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if ($i=="src") print $(i+1); exit}'
else
    # macOS
    ipconfig getifaddr "$(route get 1.1.1.1 2>/dev/null | awk '/interface:/{print $2}')" 2>/dev/null || \
    ifconfig | awk '/inet /{if($2!="127.0.0.1") {print $2; exit}}'
fi
```

**`startUniverse.sh` change:**
```bash
HOST_IP="$(bash "$SCRIPT_DIR/scripts/detect-host-ip.sh")"
export HOST_IP
info "Host LAN IP: $HOST_IP"
```

All `localhost` references in seed URLs, health-check polls, and Manager startup
arguments replaced with `$HOST_IP`.

---

## Phase 2 · Instance Registry  ✓ Delivered

A lightweight JSON file at `/tmp/re-registry.json` tracks every spawned instance.
A minimal HTTP shim (one `python3 -m http.server` or `socat` invocation) exposes
it as a REST endpoint so Manager and tests can discover instances without
reading the filesystem directly.

**Registry schema (`/tmp/re-registry.json`):**
```json
{
  "host": "192.168.1.42",
  "instances": [
    {
      "id": "scala-1",
      "runtime": "scala",
      "re_url": "http://192.168.1.42:5001",
      "pe_url": "http://192.168.1.42:5000",
      "re_port": 5001,
      "pe_port": 5000,
      "pid_re": 12345,
      "pid_pe": 12346,
      "started_at": "2026-05-24T10:00:00Z",
      "status": "running"
    }
  ]
}
```

**`scripts/registry.sh`** (new) — CRUD helpers:
```bash
registry_add   <id> <runtime> <re_url> <pe_url> <pid_re> <pid_pe>
registry_remove <id>
registry_list   # prints JSON to stdout
registry_get    <id>  # single entry
```

Uses `python3 -c "import json, sys; ..."` for in-place JSON editing; no
external dependencies.

**Registry REST shim** (started in `startUniverse.sh`):
```bash
# Serves GET http://$HOST_IP:5999/registry → /tmp/re-registry.json
python3 -m http.server 5999 --directory /tmp &
echo $! > /tmp/re-registry-server.pid
```

Port `5999` added to Port Reference table in ROADMAP.md.

---

## Phase 3 · Port Allocation Strategy  ✓ Delivered

Each instance receives a unique `(RE_PORT, PE_PORT)` pair. Allocation is
deterministic: base port + (instance_index × 100).

| Runtime | Base RE port | Base PE port | Instance slots |
|---|---|---|---|
| scala | 5001 | 5000 | 5001/5000, 5101/5100, 5201/5200 … |
| cpp   | 5301 | 5300 | 5301/5300, 5401/5400 … |
| lsp   | 5601 | 5600 | 5601/5600, 5701/5700 … |

Collision detection in `scripts/allocate-ports.sh`:
```bash
allocate_ports() {
    local runtime=$1
    local index=$2   # 1-based
    local base_re base_pe
    case $runtime in
        scala) base_re=5001; base_pe=5000 ;;
        cpp)   base_re=5301; base_pe=5300 ;;
        lsp)   base_re=5601; base_pe=5600 ;;
    esac
    local re_port=$(( base_re + (index-1)*100 ))
    local pe_port=$(( base_pe + (index-1)*100 ))
    # Verify ports are not in use
    lsof -i ":$re_port" >/dev/null 2>&1 && { echo "Port $re_port in use"; return 1; }
    lsof -i ":$pe_port" >/dev/null 2>&1 && { echo "Port $pe_port in use"; return 1; }
    echo "$re_port $pe_port"
}
```

---

## Phase 4 · `startUniverse.sh` Multi-Instance Flags  ✓ Delivered

New CLI syntax:
```bash
# Single engine (backward-compatible — same as today)
./startUniverse.sh

# Named instances
./startUniverse.sh --engines=scala:1,cpp:1
./startUniverse.sh --engines=scala:2,cpp:1,lsp:1

# Explicit per-instance port override (optional)
./startUniverse.sh --engines=scala:1:re=5001:pe=5000
```

**Parsing:**
```bash
ENGINES="scala:1"  # default
for arg in "$@"; do
    case $arg in
        --engines=*) ENGINES="${arg#--engines=}" ;;
    esac
done
```

**Spawn loop:**
```bash
IFS=',' read -ra ENGINE_SPECS <<< "$ENGINES"
INSTANCE_IDX_SCALA=0; INSTANCE_IDX_CPP=0; INSTANCE_IDX_LSP=0

for spec in "${ENGINE_SPECS[@]}"; do
    runtime=$(echo "$spec" | cut -d: -f1)
    count=$(echo "$spec" | cut -d: -f2)
    for ((i=1; i<=count; i++)); do
        case $runtime in
            scala) INSTANCE_IDX_SCALA=$((INSTANCE_IDX_SCALA+1))
                   spawn_scala_instance "scala-$INSTANCE_IDX_SCALA" "$INSTANCE_IDX_SCALA" ;;
            cpp)   INSTANCE_IDX_CPP=$((INSTANCE_IDX_CPP+1))
                   spawn_cpp_instance   "cpp-$INSTANCE_IDX_CPP"   "$INSTANCE_IDX_CPP"   ;;
            lsp)   INSTANCE_IDX_LSP=$((INSTANCE_IDX_LSP+1))
                   spawn_lsp_instance   "lsp-$INSTANCE_IDX_LSP"   "$INSTANCE_IDX_LSP"   ;;
        esac
    done
done
```

**`spawn_scala_instance` skeleton:**
```bash
spawn_scala_instance() {
    local id=$1 idx=$2
    read -r re_port pe_port <<< "$(allocate_ports scala $idx)"
    info "Spawning $id: RE=$HOST_IP:$re_port  PE=$HOST_IP:$pe_port"

    HOST="$HOST_IP" PORT="$re_port" \
        nohup bash "$SCALA_DIR/start.sh" > "/tmp/re-${id}.log" 2>&1 &
    local pid_re=$!

    HOST="$HOST_IP" PORT="$pe_port" \
        nohup bash "$MGR_DIR/perception-engine/start.sh" > "/tmp/pe-${id}.log" 2>&1 &
    local pid_pe=$!

    poll_health "http://$HOST_IP:$re_port/api/health" "$id RE"
    poll_health "http://$HOST_IP:$pe_port/api/health" "$id PE"

    registry_add "$id" "scala" \
        "http://$HOST_IP:$re_port" \
        "http://$HOST_IP:$pe_port" \
        "$pid_re" "$pid_pe"
}
```

Analogous `spawn_cpp_instance` / `spawn_lsp_instance` functions set
`REALITY_ENGINE_PORT`, `PERCEPTION_ENGINE_PORT`, and `REALITY_ENGINE_HOST`
env vars and exec the appropriate native binary.

---

## Phase 5 · `RealityEngine_Manager` Dynamic Connection  ✓ Delivered

Manager currently supports one fixed `RE_RUNTIME_URL` / `PE_RUNTIME_URL` pair.
Changes needed:

### 5a · Registry Polling (backend)

`visualizer/backend/src/server.ts` additions:
```typescript
interface EngineInstance {
  id: string;
  runtime: string;
  re_url: string;
  pe_url: string;
  status: string;
}

let instances: EngineInstance[] = [];
let activeId: string | null = null;

async function syncRegistry() {
  const registryUrl = process.env.RE_REGISTRY_URL ?? 'http://localhost:5999/re-registry.json';
  try {
    const res = await fetch(registryUrl);
    const data = await res.json();
    instances = data.instances ?? [];
    if (!activeId && instances.length > 0) activeId = instances[0].id;
  } catch { /* registry offline — keep last known list */ }
}

setInterval(syncRegistry, 5000);  // poll every 5 s
```

New REST endpoints in `server.ts`:
```
GET  /api/engines          → { instances, activeId }
POST /api/engines/active   → { id }  — switch active target
```

The existing RE/PE proxy routes (`/api/re/*`, `/api/pe/*`) forward to the
**active** instance's URLs rather than static env vars.

### 5b · Manager UI — Engine Switcher

`visualizer/frontend/src/` — new `EngineSwitcher` component:
- Dropdown listing all `instances` from `GET /api/engines`
- Each entry shows `id`, `runtime` badge, RE+PE URLs
- Selecting an entry calls `POST /api/engines/active`
- Status dot: green = healthy (polled `/api/health`), red = unreachable
- Refreshes list every 10 s

Placement: header bar, right of the existing breadcrumb.

### 5c · Backward Compatibility

If `RE_REGISTRY_URL` is unset and the legacy `RE_RUNTIME_URL` env var is set,
Manager synthesizes a single-entry registry from those values. No behavior
change for existing single-engine deployments.

---

## Phase 6 · Nginx / TLS Dynamic Upstreams  ✓ Delivered

Nginx currently has hardcoded upstream blocks for Docker service names.
For multi-instance native mode, generate `nginx/conf.d/upstreams.conf`
from the registry at startup.

**`scripts/gen-nginx-upstreams.sh`** (new):
```bash
#!/bin/bash
# Reads /tmp/re-registry.json, writes nginx/conf.d/multi-engine-upstreams.conf
REGISTRY=/tmp/re-registry.json
OUTFILE="$CI_DIR/nginx/conf.d/multi-engine-upstreams.conf"

python3 - <<'EOF'
import json, sys
reg = json.load(open('/tmp/re-registry.json'))
lines = []
for inst in reg.get('instances', []):
    iid = inst['id']
    re_host, re_port = inst['re_url'].split('://',1)[1].rsplit(':',1)
    pe_host, pe_port = inst['pe_url'].split('://',1)[1].rsplit(':',1)
    lines.append(f"upstream re_{iid} {{ server {re_host}:{re_port}; }}")
    lines.append(f"upstream pe_{iid} {{ server {pe_host}:{pe_port}; }}")
print('\n'.join(lines))
EOF
```

This file is included by `nginx/nginx.conf` via `include conf.d/*.conf;`.
Nginx is reloaded (`nginx -s reload`) after generation — zero-downtime.

For Docker-compose deployments, the existing hardcoded service-name upstreams
remain unchanged; this file is only generated in native/multi-instance mode.

---

## Phase 7 · `stopUniverse.sh` Per-Instance Teardown  ✓ Delivered

New flags:
```bash
./stopUniverse.sh                    # stop all instances + docker
./stopUniverse.sh --instance=cpp-1   # stop one instance by registry id
./stopUniverse.sh --engines-only     # stop native engines; leave docker up
```

**`stop_instance` function:**
```bash
stop_instance() {
    local id=$1
    local entry; entry=$(registry_get "$id") || { warn "$id not in registry"; return; }
    local pid_re pid_pe
    pid_re=$(echo "$entry" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('pid_re',''))")
    pid_pe=$(echo "$entry" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('pid_pe',''))")
    [ -n "$pid_re" ] && kill -TERM "$pid_re" 2>/dev/null || true
    [ -n "$pid_pe" ] && kill -TERM "$pid_pe" 2>/dev/null || true
    registry_remove "$id"
    ok "Stopped $id"
}
```

`stop_all_engines()` iterates `registry_list` and calls `stop_instance` for each.
Registry server PID killed last; `/tmp/re-registry.json` removed on full stop.

---

## Phase 8 · Test Suite Adaptation  ✓ Delivered

`RealityEngine_Machines/tests/` changes:

- **`smoke/services-up.spec.ts`** — read instance list from `RE_REGISTRY_URL`;
  assert each instance's `/api/health` returns 200. Falls back to single
  `RE_BASE_URL` env var for backward compatibility.

- **`integration/multi-instance.spec.ts`** (new) — launches two RE instances
  via `startUniverse.sh --engines=scala:1,cpp:1`; verifies they return
  different `/api/stats` (distinct in-memory state); verifies Manager
  `POST /api/engines/active` switches correctly.

- **`e2e/engine-switcher.spec.ts`** (new) — Playwright test: open Visualizer,
  open EngineSwitcher dropdown, select second instance, verify machine list
  updates to reflect that engine's corpus.

- **`playwright.config.ts`** — `RE_REGISTRY_URL` added to env pass-through.

---

## Phase 9 · GitHub Actions Multi-Engine CI Job  ✓ Delivered

`.github/workflows/e2e-tests.yml` additions:

```yaml
multi-engine-tests:
  needs: smoke-tests
  runs-on: ubuntu-latest
  steps:
    - name: Start two-engine universe
      run: bash startUniverse.sh --engines=scala:1,cpp:1 --no-openclaw --skip-seed
      working-directory: RealityEngine_CI

    - name: Run multi-instance integration tests
      run: npx playwright test tests/integration/multi-instance.spec.ts
      working-directory: RealityEngine_Machines
      env:
        RE_REGISTRY_URL: http://localhost:5999/re-registry.json

    - name: Stop universe
      if: always()
      run: bash stopUniverse.sh --engines-only
      working-directory: RealityEngine_CI
```

---

## Implementation Order

Historical estimates, kept as written. Every row is delivered.

| Phase | Description | Effort | Blocking |
|---|---|---|---|
| 1 | Host IP detection | S | — |
| 2 | Instance registry + REST shim | M | Phase 1 |
| 3 | Port allocation | S | Phase 2 |
| 4 | `startUniverse.sh` multi-instance flags | L | Phase 3 |
| 5a | Manager backend registry polling + active endpoint | M | Phase 2 |
| 5b | Manager UI engine-switcher component | M | Phase 5a |
| 5c | Manager backward-compat shim | S | Phase 5a |
| 6 | Nginx dynamic upstreams | M | Phase 4 |
| 7 | `stopUniverse.sh` per-instance teardown | M | Phase 4 |
| 8 | Test suite adaptation | M | Phase 5 |
| 9 | CI multi-engine job | S | Phase 8 |

S = ~1 hour, M = ~2–4 hours, L = ~4–8 hours

---

## Port Reference (Extended)

Appended to the main ROADMAP.md port table:

| Service | Host Port | Notes |
|---|---|---|
| Instance Registry REST | 5999 | `/re-registry.json` — JSON file served by python3 |
| Scala RE instance 1 | 5001 | default; +100 per additional instance |
| Scala PE instance 1 | 5000 | default; +100 per additional instance |
| CPP RE instance 1 | 5301 | +100 per additional instance |
| CPP PE instance 1 | 5300 | +100 per additional instance |
| LSP RE instance 1 | 5601 | +100 per additional instance |
| LSP PE instance 1 | 5600 | +100 per additional instance |
