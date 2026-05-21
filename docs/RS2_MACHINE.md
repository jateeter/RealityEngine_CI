# RS2 Machine - Two-Step RS Flip-Flop

**Date**: 2026-02-02
**Type**: Digital Logic Example
**Status**: ✅ Implemented and Validated
**Category**: Two-Step Sequence Pattern

---

## Overview

The **RS2** machine is a two-step RS flip-flop that demonstrates 2-event sequences with a hold state. Unlike the simple RS flip-flop (which responds immediately to inputs), the RS2 machine requires a specific sequence of inputs to generate outputs.

### Key Characteristics:

- **Two-Step Sequences**: Requires hold state [0,0] followed by SET [1,0] or RESET [0,1]
- **Perceptual Mapping**: Reads from En[4:6], writes to En[8:10]
- **Stateful Behavior**: Terminal events stay active after activation
- **Universal Reality Integration**: Connected to shared perceptual space

---

## Machine Structure

### Critical Event Sequences

#### SET Sequence: (0,0) → (1,0)
```
Event 1: [0,0] (HOLD)  - Initial state, always active
  ↓
Event 2: [1,0] (SET)   - Activated when Event 1 matches, outputs [1,0]
```

**Behavior**:
1. Machine starts with Event 1 active (hold state)
2. When input [0,0] arrives, Event 1 matches
3. Event 1 activates Event 2 (SET event)
4. Event 2 waits for next input
5. When input [1,0] arrives, Event 2 matches and outputs [1,0]

#### RESET Sequence: (0,0) → (0,1)
```
Event 1: [0,0] (HOLD)  - Initial state, always active
  ↓
Event 2: [0,1] (RESET) - Activated when Event 1 matches, outputs [0,1]
```

**Behavior**:
1. Machine starts with Event 1 active (hold state)
2. When input [0,0] arrives, Event 1 matches
3. Event 1 activates Event 2 (RESET event)
4. Event 2 waits for next input
5. When input [0,1] arrives, Event 2 matches and outputs [0,1]

---

## Perceptual Mapping

### Input Mapping
- **Offset**: 4
- **Length**: 2
- **Region**: En[4:6]
- **Description**: Reads 2D input vector from universal reality space

### Output Mapping
- **Offset**: 8
- **Length**: 2
- **Region**: En[8:10]
- **Description**: Writes 2D output vector back to universal reality space

### Universal Reality Integration
```
En (dynamic perceptual space; 768-element compatibility floor)
│
├─ En[0:4]   - Reserved for other machines
├─ En[4:6]   - RS2 INPUT  ← Machine reads here
├─ En[6:8]   - Reserved for other machines
├─ En[8:10]  - RS2 OUTPUT ← Machine writes here
└─ En[10:256] - Reserved for other machines
```

---

## Input/Output Behavior

### Input Space
| Input [S,R] | Name    | Description |
|-------------|---------|-------------|
| [0,0]       | HOLD    | Hold/Initial state - primes sequences |
| [1,0]       | SET     | Set input - triggers SET output if primed |
| [0,1]       | RESET   | Reset input - triggers RESET output if primed |
| [1,1]       | INVALID | Invalid state - no output |

### Output Space
| Output [Q,Q̄] | Name    | Description |
|---------------|---------|-------------|
| [1,0]         | SET     | HIGH/SET state |
| [0,1]         | RESET   | LOW/RESET state |
| [0,0]         | SPECIAL | Special state (rarely used) |

### Sequence Requirements

**To Generate SET Output [1,0]**:
- Previous input MUST be [0,0] (HOLD)
- Current input MUST be [1,0] (SET)
- Pattern: [0,0] followed by [1,0]

**To Generate RESET Output [0,1]**:
- Previous input MUST be [0,0] (HOLD)
- Current input MUST be [0,1] (RESET)
- Pattern: [0,0] followed by [0,1]

---

## Test Sequence Analysis

### Test Input Sequence
```
Input: [(0,0), (1,0), (0,0), (0,1), (0,0), (1,0), (1,1), (0,1)]
```

### Expected Behavior

| Step | Input | Sequence State | Output | Explanation |
|------|-------|----------------|--------|-------------|
| 1 | [0,0] | Both Event 1s match | None | Activates both Event 2s (SET and RESET) |
| 2 | [1,0] | SET Event 2 matches | **[1,0]** | Completes SET sequence |
| 3 | [0,0] | Both Event 1s match | None | Re-primes sequences |
| 4 | [0,1] | RESET Event 2 matches | **[0,1]** | Completes RESET sequence |
| 5 | [0,0] | Both Event 1s match | None | Re-primes sequences |
| 6 | [1,0] | SET Event 2 matches | **[1,0]** | Completes SET sequence again |
| 7 | [1,1] | No match | None | Invalid state, no sequence completion |
| 8 | [0,1] | No valid sequence | None | RESET input but not primed (no [0,0] before) |

### Actual Output Sequence
```
Output: [None, [1,0], None, [0,1], None, [1,0], None, None]
```

**Total Outputs**: 3 outputs generated
- 2x SET outputs [1,0] at steps 2 and 6
- 1x RESET output [0,1] at step 4

---

## Key Differences from RS Flip-Flop

### Simple RS Flip-Flop (Immediate Response)
```
Input [1,0] → Immediate output [1,0]
Input [0,1] → Immediate output [0,1]
```

### RS2 (Two-Step Sequence)
```
Input [0,0] → Primes the machine
Input [1,0] → Output [1,0] (only if primed)
```

**Why the difference?**
- RS Flip-Flop: Single-event sequences, always active
- RS2: Two-event sequences, requires priming with [0,0]

---

## Implementation Details

### Sequence Design

**SET Sequence**:
```typescript
// Event 00 (Initial - Hold state)
const event00 = createRS2Vector(0, 0, true);  // isInitial=true (always active)
event00.addNextVector(event10.id);

// Event 10 (Set - Output [1,0])
const event10 = createRS2Vector(1, 0, false);  // Not initial
event10.addOutputVector(createOutput([1, 0], 'RS2 SET to HIGH (1,0)'));
```

**Activation Flow**:
1. event00 is initial, starts active
2. When event00 matches [0,0], it activates event10
3. event10 becomes active and waits
4. When input [1,0] arrives, event10 matches and outputs
5. event10 stays active (final events with outputs don't deactivate)

### Critical Event Sequence Logic

The RS2 machine uses the standard CriticalEventSequence transition logic:
- Initial events are always active
- When an event matches, it activates its next events
- Newly activated events are NOT processed in the same input cycle
- Newly activated events wait for the NEXT input to match
- Final events (with outputs) stay active after matching

---

## Usage

### Creating the RS2 Machine

```typescript
import { createRS2Machine } from './examples/rs2';

const machine = createRS2Machine();

// Machine has perceptual mapping
console.log(machine.perceptualMapping);
// {
//   input: { offset: 4, length: 2 },
//   output: { offset: 8, length: 2 }
// }
```

### Processing Inputs

```typescript
// Process a sequence
const inputs = [
  [0, 0],  // Prime
  [1, 0]   // SET
];

inputs.forEach(input => {
  const result = machine.processInput(input);
  if (result.machineOutput) {
    console.log('Output:', result.machineOutput.vector);
  }
});

// Output at step 2: [1, 0]
```

### Using with Perceptual Space

```typescript
import { PerceptualSpace } from './models/PerceptualSpace';

const perceptualSpace = new PerceptualSpace(768);

// Write input to En[4:6]
perceptualSpace.updateRegion(4, [0, 0]);

// Process through machine
const result = machine.processInputFromPerceptualSpace(perceptualSpace);

// Output written to En[8:10]
const output = perceptualSpace.getRegion(8, 2);
```

---

## Validation

### Validation Checklist

- [x] Machine created with correct sequences
- [x] Perceptual mappings set correctly (En[4:6] → En[8:10])
- [x] SET sequence works (00→10 outputs [1,0])
- [x] RESET sequence works (00→01 outputs [0,1])
- [x] Terminal events activate correctly
- [x] Terminal events stay active after activation
- [x] Outputs generated at correct times
- [x] Invalid states produce no output
- [x] Repeated operations work correctly

### Test Results

**Test Sequence**: 8 steps
**Expected Outputs**: 3 outputs
**Actual Outputs**: 3 outputs ✓

- Step 2: [1,0] ✓
- Step 4: [0,1] ✓
- Step 6: [1,0] ✓

**Status**: ✅ All validations pass

---

## Files

### Implementation
- `src/examples/rs2/rs2-sequences.ts` - Sequence and machine definitions
- `src/examples/rs2/index.ts` - Module exports

### Documentation
- `docs/RS2_MACHINE.md` - This file
- `rs2_example.txt` - Original specification

### Testing
- `test-rs2.js` - Comprehensive test script

---

## Related Examples

- **RS Flip-Flop** (`src/examples/rs-flip-flop`) - Simple single-event RS flip-flop
- **Multi-Step Sequences** (`src/examples/multi-step-sequences`) - Multi-step sequence patterns
- **Data Center Monitoring** (`src/examples/data-center-monitoring`) - Complex multi-event sequences

---

## Technical Notes

### Why Two-Step Sequences?

Two-step sequences demonstrate:
1. **State Priming**: The hold state [0,0] acts as a "prime" or "enable" signal
2. **Sequential Logic**: Output depends on sequence of inputs, not just current input
3. **Temporal Patterns**: The machine "remembers" the previous state (hold)

### Event Activation Timing

**Critical**: Newly activated events are NOT processed in the same input cycle. They wait for the next input. This is essential for two-step sequences to work correctly.

```
Input Cycle 1: [0,0]
  - event00 matches
  - event10 ACTIVATED
  - event10 NOT PROCESSED (waits for next input)

Input Cycle 2: [1,0]
  - event10 is NOW ACTIVE
  - event10 matches [1,0]
  - Output [1,0] generated
```

---

**Status**: ✅ Complete and Validated
**Build**: ✅ Compiles successfully
**Tests**: ✅ All validations pass
**Integration**: ✅ Ready for use in simulations
