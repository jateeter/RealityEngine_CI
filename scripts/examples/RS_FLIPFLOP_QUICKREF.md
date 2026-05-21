# RS Flip-Flop Quick Reference

## Setup

```bash
# 1. Start Reality Engine
./scripts/start.sh

# 2. Create RS Flip-Flop
./scripts/examples/rs-flipflop.sh

# 3. Test it
./scripts/examples/test-rs-flipflop.sh
```

## Truth Table

| S | R | Q | Q' | State | Behavior |
|---|---|---|-------|---------|----------|
| 0 | 0 | * | *' | HOLD | Maintains previous state |
| 0 | 1 | 0 | 1 | RESET | Resets to 0 |
| 1 | 0 | 1 | 0 | SET | Sets to 1 |
| 1 | 1 | 1 | 1 | INVALID | Undefined (avoid!) |

*Note: * means previous state value*

## Input Vectors

```bash
RESET:   [0, 1]  # Q=0, Q'=1
SET:     [1, 0]  # Q=1, Q'=0
HOLD:    [0, 0]  # Maintains state
INVALID: [1, 1]  # Undefined
```

## API Usage

```bash
# Set the sequence ID
SEQUENCE_ID="<your-sequence-id>"
API_URL="http://localhost:3000/api"

# RESET
curl -X POST $API_URL/sequences/$SEQUENCE_ID/transition \
  -H 'Content-Type: application/json' \
  -d '{"vector": [0, 1]}'

# SET
curl -X POST $API_URL/sequences/$SEQUENCE_ID/transition \
  -H 'Content-Type: application/json' \
  -d '{"vector": [1, 0]}'

# HOLD
curl -X POST $API_URL/sequences/$SEQUENCE_ID/transition \
  -H 'Content-Type: application/json' \
  -d '{"vector": [0, 0]}'
```

## Example Sequence

```
1. [0, 1] → RESET    Q=0, Q'=1
2. [0, 0] → HOLD     Q=0, Q'=1 (maintains)
3. [1, 0] → SET      Q=1, Q'=0
4. [0, 0] → HOLD     Q=1, Q'=0 (maintains)
5. [0, 1] → RESET    Q=0, Q'=1
```

## States

### 🔴 RESET State
- **Input**: S=0, R=1
- **Output**: Q=0, Q'=1
- **Description**: Output is reset to 0

### 🟢 SET State
- **Input**: S=1, R=0
- **Output**: Q=1, Q'=0
- **Description**: Output is set to 1

### 🔵 HOLD State
- **Input**: S=0, R=0
- **Output**: Previous Q, Previous Q'
- **Description**: Maintains the last state (memory)

### 🟠 INVALID State
- **Input**: S=1, R=1
- **Output**: Undefined (typically 1, 1)
- **Description**: Avoid this state in practice

## Visualizer

View in the visualizer at: http://localhost:5173

You'll see:
- 5 event nodes (RESET, SET, HOLD×2, INVALID)
- State transitions as edges
- Color-coded states
- Hover tooltips with details

## Key Concepts

1. **Bistable**: Two stable states (SET and RESET)
2. **Memory**: Holds state until changed
3. **Sequential**: Output depends on history
4. **Asynchronous**: Changes immediately with inputs

## Files

- Script: `/scripts/examples/rs-flipflop.sh`
- Test: `/scripts/examples/test-rs-flipflop.sh`
- Docs: `/docs/examples/RS_FLIPFLOP.md`
- Data: `/data/rs-flipflop.json`

## Next Steps

Try these variations:
1. Create a D flip-flop (add clock)
2. Create a JK flip-flop (fix invalid state)
3. Chain multiple flip-flops (shift register)
4. Add asynchronous set/reset
5. Implement edge-triggered behavior
