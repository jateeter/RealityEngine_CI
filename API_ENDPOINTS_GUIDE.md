# Reality Engine — API Reference

All services run behind the TLS proxy. Use `https://` for REST and `wss://` for WebSocket.

---

## Reality Engine (port 3000)

### Health
```
GET  /api/health            → { status, timestamp }
```

### Machines
```
GET  /api/machines                       → { machines: [...] }
GET  /api/machines/:id                   → { machine }
POST /api/machines                       → { machine }       create
PUT  /api/machines/:id                   → { machine }       full replace
DELETE /api/machines/:id                 → { success }

GET  /api/machines/json/list             → { machines: [{ filename, name, description, version, sequenceCount }] }
GET  /api/machines/json/:name            → { success, machine, message }   load & register from JSON file
GET  /api/machines/:id/export?pretty=true → raw JSON string
```

### Sequences
```
GET  /api/sequences                      → { sequences: [...] }
GET  /api/sequences/:id                  → sequence graph with nodes/edges and live activation state
```

### Perceptual Space Simulator

The simulator accepts a pre-configured input sequence and steps through it. Used by e2e tests; day-to-day operation uses the Perception Engine push path instead.

```
POST /api/perceptual-simulation/configure/chunk   body: { vectors, reset?, inputRegion?, stepDelayMs?, maxSteps? }
POST /api/perceptual-simulation/configure/commit  → { success, committed, config }
POST /api/perceptual-simulation/step              → { success, step: SimulationStep, isComplete }
POST /api/perceptual-simulation/reset             → { success }
GET  /api/perceptual-simulation/state             → { isRunning, currentStep, config, perceptualSpaceDimension }
GET  /api/perceptual-simulation/history           → { history: SimulationStep[] }
```

### Perception Engine push endpoint
```
POST /api/perceive    body: { vector: number[], matchAlgorithm?: "gte"|"equals" }
                      → SimulationStep  (runs processImmediate, returns full step result)
```

### Machine interconnection graph
```
GET  /api/machine-graph   → { nodes, edges, perceptualSpaceDimension }
```

### Demos
```
GET  /api/demo/data-center   → { success, metadata }
GET  /api/demo/multi-step    → { success, machine, metadata }
GET  /api/demo/kleene-star   → { success, machine, metadata }
```

---

## SimulationStep shape

```json
{
  "stepNumber": 0,
  "timestamp": 1234567890,
  "perceptualSpace": [/* 256 numbers */],
  "machineResults": {
    "<machineId>": {
      "machineId": "...",
      "machineName": "...",
      "inputVector": [/* numbers */],
      "outputVector": [/* numbers */ ] | null,
      "inputRegion":  { "offset": 0, "length": 3 },
      "outputRegion": { "offset": 3, "length": 2 } | null,
      "transitionResult": { ... }
    }
  },
  "activeRegions": [{ "offset", "length", "machineId", "role" }]
}
```

---

## Visualizer Backend (port 3001)

Proxies all Reality Engine endpoints listed above. Additional:

### WebSocket
```
wss://localhost:3001/ws
```

Message types broadcast to clients:

| Type | Payload | Trigger |
|---|---|---|
| `perceptual-simulation-stepped` | `{ step: SimulationStep }` | Any push or manual step |
| `perceptual-simulation-reset` | `{ timestamp }` | `POST /api/perceptual-simulation/reset` |
| `demo-loaded` | `{ metadata, machine? }` | Any demo endpoint |
| `machine-loaded` | `{ machine }` | `GET /api/machines/json/:name` |

---

## Perception Engine Backend (port 3004)

### Core
```
GET  /api/health            → { status, timestamp }
GET  /api/state             → EngineState
POST /api/push              → { success, step: SimulationStep, globalStep, timestamp }
POST /api/reset             → { success }
PATCH /api/config           body: { matchAlgorithm: "gte"|"equals" }  → { success, matchAlgorithm }
```

### Auto-push
```
POST /api/auto/start        body: { intervalMs: number }  → { success, intervalMs }
POST /api/auto/stop         → { success }
```

### Sources
```
GET  /api/sources           → { sources: SourceConfig[] }
POST /api/sources           body: { type, name, region, ...typeFields }  → { source }
PATCH /api/sources/:id      body: Partial<SourceConfig>                  → { source }
DELETE /api/sources/:id     → { success }
```

Source shapes by type:

**test**
```json
{ "type": "test", "name": "...", "region": { "offset": 0, "length": 3 },
  "inputs": [[0,0,0],[1,0,0],[1,1,1]], "loop": true, "active": true }
```

**simulated**
```json
{ "type": "simulated", "name": "...", "region": { "offset": 10, "length": 2 },
  "pattern": "sine", "frequency": 0.1, "amplitude": 0.5, "dcOffset": 0.5, "active": true }
```
Patterns: `sine` | `sawtooth` | `square` | `linear-ramp` | `constant` | `random-walk` | `gaussian-noise` | `binary`

**sensor**
```json
{ "type": "sensor", "name": "...", "region": { "offset": 20, "length": 4 },
  "sensorId": "my-sensor", "ttlMs": 5000, "active": true }
```

### Sensor push
```
POST /api/sensors/:sensorId   body: { values: number[] }   → { success, sensorId, timestamp }
```

### WebSocket
```
wss://localhost:3004/ws
```

Message types broadcast to clients:

| Type | Payload | Trigger |
|---|---|---|
| `state-update` | `EngineState` | Any state change (push, source CRUD, config) |
| `push-result` | `{ success, step, globalStep, timestamp }` | After every push |

### EngineState shape
```json
{
  "sources": [/* SourceConfig[] */],
  "assembledVector": [/* number[] — current pre-push preview */],
  "globalStep": 42,
  "auto": { "running": true, "intervalMs": 600 },
  "lastPush": 1234567890,
  "matchAlgorithm": "gte"
}
```

---

## Visualizer Frontend nginx proxy (port 5173)

The visualizer frontend nginx adds two proxy paths so the browser can reach other services without hard-coded ports:

| Path prefix | Routes to |
|---|---|
| `/api/perception/*` | `perception-engine-backend:3004/api/*` |
| `/api/*` | `visualizer-backend:3001/*` |
| `/ws` | `visualizer-backend:3001/ws` (WebSocket) |
