# RS Flip Flop Example

**Date:** January 17, 2026
**Type:** Digital Logic Example
**Difficulty:** Beginner
**Category:** Bistable Memory Element

## Overview

The RS Flip Flop (Reset-Set Flip Flop) is a fundamental bistable memory element in digital electronics. This example demonstrates how critical event sequences can model binary state storage and transitions.

## What is an RS Flip Flop?

An RS Flip Flop is a **bistable multivibrator** - a circuit with two stable states that can store a single bit of information. The flip flop has:

- **Two inputs**: Set (S) and Reset (R)
- **One output**: Q (the stored state)
- **Two stable states**: Q=0 (RESET/LOW) and Q=1 (SET/HIGH)

### State Transitions

| S | R | Operation | Output Q |
|---|---|-----------|----------|
| 0 | 0 | Hold      | No change (maintains current state) |
| 0 | 1 | Reset     | 0 (LOW) |
| 1 | 0 | Set       | 1 (HIGH) |
| 1 | 1 | Invalid   | Undefined (forbidden state) |

## Critical Event Sequences

The RS Flip Flop is modeled using two critical event sequences:

### 1. SET Sequence: 00 → 10 → [1]

**Path:** Hold state (S=0, R=0) → Set state (S=1, R=0)
**Output:** `[1]` (HIGH/SET)

```
Event 00: Stable hold state (S=0, R=0)
   ↓
Event 10: Set input activated (S=1, R=0)
   ↓
OUTPUT: [1] - Flip flop SET to HIGH
```

**Meaning:** When starting from a stable hold state, activating the Set input (S=1) while keeping Reset low (R=0) sets the flip flop output to 1.

### 2. RESET Sequence: 00 → 01 → [0]

**Path:** Hold state (S=0, R=0) → Reset state (S=0, R=1)
**Output:** `[0]` (LOW/RESET)

```
Event 00: Stable hold state (S=0, R=0)
   ↓
Event 01: Reset input activated (S=0, R=1)
   ↓
OUTPUT: [0] - Flip flop RESET to LOW
```

**Meaning:** When starting from a stable hold state, activating the Reset input (R=1) while keeping Set low (S=0) resets the flip flop output to 0.

## Event Space

**Dimensions:** 2D binary vectors representing `[S, R]` inputs

**Valid Input States:**
- `[0, 0]` - Hold state (no change)
- `[0, 1]` - Reset state (output → 0)
- `[1, 0]` - Set state (output → 1)
- `[1, 1]` - Invalid/forbidden state (not used)

**Output Space:** 1D binary: `{0, 1}`
- `0` = RESET/LOW state
- `1` = SET/HIGH state

## Test Sequence Explanation

The example includes a 9-vector test sequence demonstrating typical flip flop operations:

```
Vector 1: [0, 0] - Hold state (initial)
Vector 2: [1, 0] - SET (00→10) → outputs [1]
Vector 3: [0, 0] - Hold state (maintains 1)
Vector 4: [0, 1] - RESET (00→01) → outputs [0]
Vector 5: [0, 0] - Hold state (maintains 0)
Vector 6: [0, 1] - RESET again → outputs [0]
Vector 7: [1, 0] - SET → outputs [1]
Vector 8: [0, 1] - RESET → outputs [0]
Vector 9: [0, 0] - Hold state (final)
```

### Expected Output Timeline

| Step | Input | Sequence Match | Output | Flip Flop State |
|------|-------|----------------|--------|-----------------|
| 1 | [0,0] | Initial state | - | Hold |
| 2 | [1,0] | SET (00→10) | [1] | HIGH |
| 3 | [0,0] | Hold | - | HIGH (maintained) |
| 4 | [0,1] | RESET (00→01) | [0] | LOW |
| 5 | [0,0] | Hold | - | LOW (maintained) |
| 6 | [0,1] | RESET (00→01) | [0] | LOW |
| 7 | [1,0] | SET (00→10) | [1] | HIGH |
| 8 | [0,1] | RESET (00→01) | [0] | LOW |
| 9 | [0,0] | Hold | - | LOW (maintained) |

**Total Expected Outputs:** 5 outputs (steps 2, 4, 6, 7, 8)

## Using the RS Flip Flop Example

### Loading the Example

1. **Via UI:**
   - Open the Reality Engine visualizer
   - Navigate to the machine library
   - Click on **"RS Flip Flop"** card
   - Click **"Load Example"** button

2. **Via API:**
   ```typescript
   import { api } from './api';

   const result = await api.loadRSFlipFlopExample();
   console.log('RS Flip Flop loaded:', result.metadata);
   ```

3. **Via Store:**
   ```typescript
   import { useVisualizerStore } from './store';

   const { loadRSFlipFlopExample } = useVisualizerStore();
   await loadRSFlipFlopExample();
   ```

### Viewing Sequences

After loading the example, you'll see two critical event sequences in the graph view:

1. **SET Sequence** - Shows the 00→10 transition with output [1]
2. **RESET Sequence** - Shows the 00→01 transition with output [0]

### Running Simulations

1. **Load Test Vectors:**
   - Click **"Load Input Vectors"** on the SIMULATION tab
   - Select one of the input sequences:
     - SET Operation (00→10)
     - RESET Operation (00→01)
     - SET then RESET (00→10→00→01)
     - Complete Test Sequence (9 vectors)

2. **Execute Step-by-Step:**
   - Click **"Step"** button to advance through each input
   - Watch for output generation in the OUTPUT STREAM panel
   - Active final events will show **⚡ OUTPUT** indicator

3. **Auto-Play:**
   - Click **"Start"** button to auto-play the sequence
   - Adjust playback speed with the speed slider
   - Watch outputs accumulate in real-time

4. **Random Input:**
   - Click **"Random Input"** to generate a random [S, R] vector
   - The engine will match it against sequences
   - Outputs appear when sequences complete

### Output Stream Visualization

The output stream shows a chronological history of flip flop outputs:

```
┌─────────────────────────┐
│ OUTPUT STREAM           │
├─────────────────────────┤
│ CURRENT                 │
│ ⚡ [0.00]              │  ← Most recent output
├─────────────────────────┤
│ HISTORY                 │
│ [1.00]                  │
│ [0.00]                  │
│ [0.00]                  │
│ [1.00]                  │  ← Oldest output
└─────────────────────────┘
```

**Reading the Output:**
- `[0.00]` = Flip flop in RESET/LOW state
- `[1.00]` = Flip flop in SET/HIGH state
- New outputs appear at the top (CURRENT)
- Older outputs scroll down (HISTORY)

### Resetting the Simulation

Click the **"Reset"** button to:
- Reset all sequence states to initial vectors
- Clear the output stream
- Reset the simulation index to 0
- Prepare for a new simulation run

## Integration Details

The RS Flip Flop machine is defined in `examples/machines/RSFlipFlop.json` and loaded automatically at engine startup via `scala/.../Routes.scala::loadDefaultMachines`. It appears in the machine library in the Visualizer — select it and click **Load** to view its CES graph and run simulations.

## Educational Use Cases

### 1. Learning Critical Event Sequences

The RS Flip Flop is an excellent **beginner-friendly example** for understanding:
- How critical event sequences work
- State transitions and pattern matching
- Output generation on sequence completion
- Binary state representation

### 2. Digital Logic Fundamentals

Demonstrates core digital logic concepts:
- Bistable circuits
- Memory elements
- State machines
- Binary inputs and outputs

### 3. Sequential Logic

Shows how sequences of events create state changes:
- Initial state → Transition event → Final state + Output
- State memory (hold state maintains current output)
- Conditional transitions based on input patterns

### 4. Debugging and Visualization

Perfect for learning the Reality Engine visualization tools:
- Graph view shows sequence topology
- Active state highlighting
- Output generation indicators (⚡ OUTPUT)
- Output stream tracking

## Comparison with Other Examples

| Example | Difficulty | Sequences | Input Dimensions | Use Case |
|---------|-----------|-----------|------------------|----------|
| **RS Flip Flop** | Beginner | 2 | 2D binary | Learning sequences, digital logic basics |
| Multi-Step State Machine | Intermediate | 2 | 3D binary | Multi-step workflows, cascading events |
| Kleene Star | Advanced | 1 | Variable | Pattern repetition, advanced regex-like patterns |
| Data Center Monitoring | Intermediate | 5 | Multi-dimensional | Real-world infrastructure scenarios |

**Why Start with RS Flip Flop?**
- Simple 2D binary input space (easy to understand)
- Only 2 sequences (not overwhelming)
- Clear cause-and-effect (input pattern → output)
- Familiar concept from digital electronics
- Fast execution (quick feedback loop)

## Implementation Files

- **Machine definition:** `examples/machines/RSFlipFlop.json` — loaded at startup
- **Related machines:** `examples/machines/RS2.json`, `examples/machines/RSFlipFlopTrigger.json`
- **Reference:** `docs/examples/RS_FLIPFLOP.md`, `docs/RS2_MACHINE.md`

## Testing

### Manual Testing

1. **Load the example and verify:**
   - 2 sequences appear in graph view
   - SET sequence shows 00→10 path
   - RESET sequence shows 00→01 path
   - Test vectors loaded (9 vectors)

2. **Execute the test sequence:**
   - Step through all 9 vectors
   - Verify 5 outputs generated
   - Check outputs match expected values: [1], [0], [0], [1], [0]

3. **Verify output highlighting:**
   - When vector 2 ([1,0]) matches, SET sequence's final event shows **⚡ OUTPUT**
   - When vector 4 ([0,1]) matches, RESET sequence's final event shows **⚡ OUTPUT**
   - Output stream updates in real-time

4. **Test reset functionality:**
   - Run simulation to completion
   - Click Reset button
   - Verify output stream clears
   - Verify sequences reset to initial state

### Automated Testing

Create an e2e test similar to `multi-step-output-workflow.spec.ts`:

```typescript
test('RS Flip Flop workflow', async ({ page }) => {
  // 1. Load RS Flip Flop machine
  // 2. Verify 2 sequences loaded
  // 3. Load test input vectors (9 vectors)
  // 4. Step through and verify outputs
  // 5. Check output stream shows [1], [0], [0], [1], [0]
  // 6. Verify active output highlighting
  // 7. Reset and verify clean state
});
```

## Troubleshooting

### Problem: No outputs appearing

**Possible Causes:**
- Input vectors don't match sequence patterns exactly
- Sequences not properly reset before starting
- Output stream showing wrong machine's outputs

**Solutions:**
1. Click Reset button before starting simulation
2. Verify you're using the exact test sequence
3. Check that RS Flip Flop machine is active
4. Clear output stream and try again

### Problem: Wrong output values

**Expected:** Binary values 0 or 1
**Actual:** Different values

**Solutions:**
1. Verify vector matching is working (check active states)
2. Ensure comparator threshold is correct (0.05)
3. Check that input vectors have exact values [0,0], [1,0], or [0,1]

### Problem: Sequences not matching

**Cause:** Input vector doesn't match expected pattern

**Explanation:**
- SET sequence requires 00→10 pattern
- RESET sequence requires 00→01 pattern
- Must start from hold state (00) to trigger either sequence

**Solution:** Ensure previous input was [0,0] before sending [1,0] or [0,1]

## Advanced Usage

### Creating Custom Flip Flop Variants

You can create variants of the RS Flip Flop:

1. **D Flip Flop** (Data Flip Flop)
   - Single data input + clock signal
   - Sequence: Clock edge → Output = Data input

2. **T Flip Flop** (Toggle Flip Flop)
   - Single toggle input
   - Sequence: Toggle → Output = !Output

3. **JK Flip Flop** (Jack-Kilby Flip Flop)
   - Extends RS with 11 state (toggle instead of invalid)
   - Sequences: 01→Reset, 10→Set, 11→Toggle

### Chaining Flip Flops

Create multi-bit storage by chaining multiple flip flops:
- 8 flip flops = 1 byte storage
- Input: 16D vector [S0,R0,S1,R1,...,S7,R7]
- Output: 8D vector [Q0,Q1,Q2,...,Q7]

## Related Examples

- Multi-Step State Machine (`examples/machines/MultiStep.json`)
- Kleene Star (`examples/machines/KleeneStar.json`)
- RS2 Variant (`examples/machines/RS2.json`)

## Version History

| Version | Date | Changes |
|---------|------|---------|
| 1.0.0 | 2026-01-17 | Initial RS Flip Flop example implementation |

---

**Ready to Use:** ✅ Fully integrated into deployed application
**Difficulty:** Beginner
**Recommended For:** Learning critical event sequences and digital logic fundamentals
