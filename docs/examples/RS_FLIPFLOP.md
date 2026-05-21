# RS Flip-Flop Example

## Overview

The RS (Reset-Set) flip-flop is a fundamental digital logic component that demonstrates **bistable memory**. It's one of the simplest sequential logic circuits and forms the basis for more complex memory elements like registers and RAM.

This example shows how to implement an RS flip-flop using the Reality Engine's Critical Event Sequences.

## What is an RS Flip-Flop?

An RS flip-flop is a 1-bit memory cell with:

### Inputs
- **S (Set)**: When high (1), sets the output Q to 1
- **R (Reset)**: When high (1), resets the output Q to 0

### Outputs
- **Q**: The primary output (the stored bit)
- **Q' (Q-bar)**: The complementary output (NOT Q)

### States

| S | R | Q | Q' | State | Description |
|---|---|---|-------|-------|-------------|
| 0 | 1 | 0 | 1 | **RESET** | Output is reset to 0 |
| 1 | 0 | 1 | 0 | **SET** | Output is set to 1 |
| 0 | 0 | Q | Q' | **HOLD** | Maintains previous state |
| 1 | 1 | 1 | 1 | **INVALID** | Undefined (avoid this) |

## Implementation in Reality Engine

The RS flip-flop is implemented using **5 critical event vectors**:

### 1. RESET State
```json
{
  "id": "reset-state",
  "elements": [
    {"value": 0.0, "comparatorType": "equals", "name": "S"},
    {"value": 1.0, "comparatorType": "equals", "name": "R"}
  ],
  "isInitial": true,
  "outputVectors": [
    {
      "vector": [0.0, 1.0],  // Q=0, Q'=1
      "metadata": {"state": "RESET"}
    }
  ]
}
```

### 2. SET State
```json
{
  "id": "set-state",
  "elements": [
    {"value": 1.0, "comparatorType": "equals", "name": "S"},
    {"value": 0.0, "comparatorType": "equals", "name": "R"}
  ],
  "isInitial": true,
  "outputVectors": [
    {
      "vector": [1.0, 0.0],  // Q=1, Q'=0
      "metadata": {"state": "SET"}
    }
  ]
}
```

### 3. HOLD from RESET
```json
{
  "id": "hold-from-reset",
  "elements": [
    {"value": 0.0, "comparatorType": "equals", "name": "S"},
    {"value": 0.0, "comparatorType": "equals", "name": "R"}
  ],
  "outputVectors": [
    {
      "vector": [0.0, 1.0],  // Maintains Q=0, Q'=1
      "metadata": {"state": "HOLD_RESET"}
    }
  ]
}
```

### 4. HOLD from SET
```json
{
  "id": "hold-from-set",
  "elements": [
    {"value": 0.0, "comparatorType": "equals", "name": "S"},
    {"value": 0.0, "comparatorType": "equals", "name": "R"}
  ],
  "outputVectors": [
    {
      "vector": [1.0, 0.0],  // Maintains Q=1, Q'=0
      "metadata": {"state": "HOLD_SET"}
    }
  ]
}
```

### 5. INVALID State
```json
{
  "id": "invalid-state",
  "elements": [
    {"value": 1.0, "comparatorType": "equals", "name": "S"},
    {"value": 1.0, "comparatorType": "equals", "name": "R"}
  ],
  "outputVectors": [
    {
      "vector": [1.0, 1.0],  // Undefined
      "metadata": {
        "state": "INVALID",
        "error": "Both S and R are high"
      }
    }
  ]
}
```

## State Transition Diagram

```
                    S=0, R=0 (HOLD)
                   ┌─────────────┐
                   │             │
                   ▼             │
      S=1, R=0  ┌──────┐         │      S=0, R=1
      ┌────────▶│ SET  │◀────────┼─────────┐
      │         │ Q=1  │         │         │
      │         │ Q'=0 │         │         │
      │         └──────┘         │         │
      │            │             │         │
      │            │S=0, R=1     │         │
      │            │             │         │
      │            ▼             │         │
      │         ┌──────┐         │         │
      └─────────│RESET │─────────┘         │
        S=1,R=0 │ Q=0  │ S=0, R=0 (HOLD)   │
                │ Q'=1 │◀──────────────────┘
                └──────┘

            (S=1, R=1 leads to INVALID state)
```

## Usage

### 1. Create the RS Flip-Flop

```bash
cd /Users/johnt/workspace/GitHub/RealityEngine_AI
./scripts/examples/rs-flipflop.sh
```

This creates:
- A Critical Event Sequence representing the RS flip-flop
- A Machine containing the flip-flop

### 2. Test the Flip-Flop

```bash
./scripts/examples/test-rs-flipflop.sh
```

This runs a comprehensive test suite demonstrating:
- Initial RESET
- Maintaining RESET state (HOLD)
- Setting to SET state
- Maintaining SET state (HOLD)
- Transitioning between states
- Invalid state handling

### 3. Manual Testing via API

```bash
PORT=3000
API_URL="http://localhost:$PORT/api"
SEQUENCE_ID="<your-sequence-id>"

# RESET: S=0, R=1 → Q=0, Q'=1
curl -X POST $API_URL/sequences/$SEQUENCE_ID/transition \
  -H 'Content-Type: application/json' \
  -d '{"vector": [0, 1]}'

# SET: S=1, R=0 → Q=1, Q'=0
curl -X POST $API_URL/sequences/$SEQUENCE_ID/transition \
  -H 'Content-Type: application/json' \
  -d '{"vector": [1, 0]}'

# HOLD: S=0, R=0 → Maintains previous state
curl -X POST $API_URL/sequences/$SEQUENCE_ID/transition \
  -H 'Content-Type: application/json' \
  -d '{"vector": [0, 0]}'
```

## Example Sequence

Here's a typical sequence showing the bistable memory behavior:

```
Step 1: RESET    [S=0, R=1] → Q=0, Q'=1  ✓
Step 2: HOLD     [S=0, R=0] → Q=0, Q'=1  ✓ (maintains RESET)
Step 3: SET      [S=1, R=0] → Q=1, Q'=0  ✓
Step 4: HOLD     [S=0, R=0] → Q=1, Q'=0  ✓ (maintains SET)
Step 5: HOLD     [S=0, R=0] → Q=1, Q'=0  ✓ (still maintains SET)
Step 6: RESET    [S=0, R=1] → Q=0, Q'=1  ✓
Step 7: SET      [S=1, R=0] → Q=1, Q'=0  ✓
Step 8: INVALID  [S=1, R=1] → Q=1, Q'=1  ⚠ (undefined)
```

## Visualization

The RS flip-flop can be visualized in the Reality Engine Visualizer:

1. Start the services:
   ```bash
   ./scripts/start.sh
   ```

2. Open the visualizer:
   ```
   http://localhost:5173
   ```

3. Load the RS Flip-Flop machine

4. Use the simulation controls to step through input vectors

### What You'll See

- **5 event nodes** representing the 5 states
- **Color coding**:
  - 🔵 Blue: INITIAL states (RESET, SET)
  - 🟢 Green: ACTIVE state (currently matched)
  - 🟠 Orange: OUTPUT events (with output vectors)
- **Transitions** showing state changes
- **Hover tooltips** displaying:
  - Input values (S, R)
  - Output values (Q, Q')
  - State metadata

## Why This Matters

The RS flip-flop demonstrates several key concepts:

### 1. **Bistable Memory**
- Two stable states (SET and RESET)
- Can hold one bit of information indefinitely
- Foundation of all digital memory

### 2. **Sequential Logic**
- Output depends on previous state (history)
- Not just a combinational function of current inputs
- Introduces the concept of "memory" in digital circuits

### 3. **State Machines**
- Transitions between discrete states
- State-dependent behavior
- Event-driven state changes

### 4. **Critical Event Sequences**
Shows how Reality Engine models:
- Multiple stable states as separate events
- State transitions as event sequences
- Conditional outputs based on state

## Applications

RS flip-flops are used in:
- **Memory cells** (building block of RAM)
- **Debouncing circuits** (eliminating switch bounce)
- **Control systems** (maintaining on/off states)
- **Synchronization** (clock edge detection)
- **Latches** (transparent when enabled)

## Advanced Variations

### D Flip-Flop
Add a clock signal and simplify to single D input:
- D=1 → SET on clock edge
- D=0 → RESET on clock edge

### JK Flip-Flop
Fix the invalid state problem:
- J=1, K=1 → TOGGLE (Q becomes NOT Q)

### T Flip-Flop
Single toggle input:
- T=1 → Toggle state
- T=0 → Hold

## Files

- **Script**: `/scripts/examples/rs-flipflop.sh`
- **Test**: `/scripts/examples/test-rs-flipflop.sh`
- **Docs**: `/docs/examples/RS_FLIPFLOP.md` (this file)

## References

- [RS Flip-Flop - Wikipedia](https://en.wikipedia.org/wiki/Flip-flop_(electronics)#RS_flip-flop)
- Digital Logic Design textbooks
- Sequential Circuit Theory

## Try It Now

```bash
# 1. Start Reality Engine
./scripts/start.sh

# 2. Create the flip-flop
./scripts/examples/rs-flipflop.sh

# 3. Test it
./scripts/examples/test-rs-flipflop.sh

# 4. View in visualizer
open http://localhost:5173
```

Enjoy exploring bistable memory with the RS flip-flop! 🎛️
