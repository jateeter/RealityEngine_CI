# Reality Engine — Example Scripts

Shell scripts that call the Reality Engine REST API to demonstrate machine and sequence operations.

## Prerequisites

Start the stack before running any script:

```bash
./startUniverse.sh
```

All scripts default to `https://localhost:3000`. Pass `PORT=<n>` to override:

```bash
PORT=3001 ./rs-flipflop.sh
```

## Available Scripts

| Script | Description |
|---|---|
| `rs-flipflop.sh` | Create and exercise an RS flip-flop via the API |
| `test-rs-flipflop.sh` | Verify RS flip-flop outputs |
| `create-sequence.sh` | Minimal 2-state CES creation |
| `process-input.sh` | Push an input vector and show results |
| `multi-zone-8d.sh` | Multi-zone 8-dimensional monitoring example |
| `pattern-recognition.sh` | Pattern-matching sequence demo |
| `sampler-demo.sh` | Algorithmic waveform source demo |

## Quick Start

```bash
cd scripts/examples
chmod +x *.sh

# Create an RS flip-flop machine and verify it
./rs-flipflop.sh
./test-rs-flipflop.sh

# View the machine in the visualizer
open https://localhost:5173
```

## Documentation

- **Machine format:** `docs/MACHINE_JSON_FORMAT.md`
- **API reference:** `API_ENDPOINTS_GUIDE.md`
- **RS flip-flop detail:** `docs/examples/RS_FLIPFLOP.md`, `RS_FLIP_FLOP.md`
