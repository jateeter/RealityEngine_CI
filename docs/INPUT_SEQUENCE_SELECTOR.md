# Input Sequence Selector - User Guide

**Date**: 2026-02-01
**Feature**: Input Sequence Selector Component
**Location**: Left sidebar of Machine Visualization
**Status**: ✅ Implemented and Available

---

## Overview

The **Input Sequence Selector** is a new UI component that allows you to select and load predefined input sequences from the machine's metadata. This is particularly useful for:

- **Testing** - Load comprehensive validation sequences
- **Demonstrations** - Show specific operational patterns
- **Debugging** - Reproduce specific state sequences
- **Education** - Step through well-documented examples

---

## Location

The Input Sequence Selector is located in the **left sidebar** (Input Stream panel) of the machine visualization interface, positioned between the header and the vector queue.

### How to Find It:

1. Navigate to a machine (e.g., RS Flip-Flop)
2. Look at the **left sidebar** labeled "INPUT STREAM"
3. You'll see a collapsible panel titled **"Input Sequence Selector"**
4. Click the arrow (▶) to expand the panel

---

## Using the Input Sequence Selector

### Step 1: Expand the Selector

Click on the **"Input Sequence Selector"** header to expand the panel. You'll see:
- A dropdown showing all available input sequences
- Details about the selected sequence
- A "Load Sequence" button

### Step 2: Select a Sequence

Use the dropdown menu to select from available input sequences. For the RS Flip-Flop example, you'll see:

- **SET Operation** - Simple SET transition
- **RESET Operation** - Simple RESET transition
- **SET then RESET** - Combined operations
- **Complete Test Sequence** - Full test pattern
- **COMPREHENSIVE VALIDATION SEQUENCE** - Complete validation (auto-selected)

### Step 3: Review Sequence Details

Once selected, you'll see:

- **Pattern**: The state transition pattern (e.g., `13-step validation`)
- **Description**: What the sequence validates or demonstrates
- **Vectors**: Number of input vectors in the sequence
- **Steps**: Total steps in the sequence
- **Expected Outputs**: Number of expected outputs

For comprehensive validation sequences, you'll also see validation badges:
- ✓ Event Activation
- ✓ Output Generation
- ✓ Visualization
- ✓ Repeated Ops
- ✓ State Transitions

### Step 4: Load the Sequence

Click the **"Load Sequence"** button to load the vectors into the simulator. The sequence will:
- Replace current input vectors
- Reset the simulation state
- Configure auto-play delay (1500ms by default)
- Prepare for step-through or auto-play

### Step 5: Run the Simulation

After loading, use the simulation controls:

- **▶ Start** - Auto-play through the sequence
- **⏸ Pause** - Pause auto-play
- **⏯ Step** - Manually step through one vector at a time
- **↻ Reset** - Reset to beginning of sequence

---

## RS Flip-Flop Comprehensive Validation Sequence

The **COMPREHENSIVE VALIDATION SEQUENCE** is a 13-step sequence that validates:

### What It Tests:

1. **Event Activation** ✓
   - All 4 events activate correctly (2x event 00, 1x event 10, 1x event 01)
   - Events stay active when appropriate
   - New events activate on transitions

2. **Output Generation** ✓
   - 6 total outputs generated
   - 3x SET operations output [1,0]
   - 3x RESET operations output [0,1]

3. **Repeated Operations** ✓
   - Same input produces same output
   - Events match multiple times correctly

4. **State Transitions** ✓
   - SET → HOLD transitions work
   - RESET → HOLD transitions work
   - SET ↔ RESET alternating works

5. **Visualization Correctness** ✓
   - wasJustMatched flag set correctly
   - lastOutputVector preserved
   - Active states displayed accurately

### Sequence Pattern:

```
Step 1:  [0,0] HOLD - Initial state
Step 2:  [1,0] SET - First SET → output [1,0]
Step 3:  [0,0] HOLD
Step 4:  [1,0] SET - Second SET → output [1,0]
Step 5:  [0,0] HOLD
Step 6:  [0,1] RESET - First RESET → output [0,1]
Step 7:  [0,0] HOLD
Step 8:  [0,1] RESET - Second RESET → output [0,1]
Step 9:  [0,0] HOLD
Step 10: [1,0] SET - SET after RESET → output [1,0]
Step 11: [0,0] HOLD
Step 12: [0,1] RESET - RESET after SET → output [0,1]
Step 13: [0,0] HOLD - Final state
```

### Expected Results:

- **Total Outputs**: 6 outputs
- **Output History** (newest first):
  1. [0,1] - RESET after SET (Step 12)
  2. [1,0] - SET after RESET (Step 10)
  3. [0,1] - Second RESET (Step 8)
  4. [0,1] - First RESET (Step 6)
  5. [1,0] - Second SET (Step 4)
  6. [1,0] - First SET (Step 2)

- **Active Events**: 4 events
  - 2x Event 00 (both sequences)
  - 1x Event 10 (SET sequence terminal)
  - 1x Event 01 (RESET sequence terminal)

---

## Other Examples

All machines with `inputSequences` metadata will show the selector. Current examples include:

### Multi-Step Machine
- Basic multi-step progression sequences

### Data Center Monitoring
- Normal operation sequences
- Alert sequences
- Emergency sequences

### Kleene Star
- Repetition pattern sequences
- Optional event sequences

---

## Creating Your Own Input Sequences

To add input sequences to a machine, include them in the machine's metadata:

```typescript
{
  name: 'My Custom Sequence',
  pattern: '00→10→00',
  description: 'A custom test pattern',
  vectors: [
    [0, 0],
    [1, 0],
    [0, 0]
  ],
  metadata: {
    totalSteps: 3,
    expectedOutputs: 1,
    validationType: 'custom',
    // ... other metadata
  }
}
```

See `src/examples/rs-flip-flop/rs-flip-flop-sequences.ts` for complete examples.

---

## Troubleshooting

### "No sequences available"

The selector won't appear if:
- The machine has no `inputSequences` in metadata
- The machine isn't fully loaded
- The metadata structure is incorrect

### "Simulation Running..."

You cannot load a new sequence while simulation is playing. Pause or reset first.

### Sequence doesn't auto-select validation

The selector auto-selects sequences with "validation" or "comprehensive" in the name. If not found, it selects the first sequence.

---

## Benefits

✅ **Quick Testing** - Load validation sequences with one click
✅ **Reproducible** - Same sequence every time
✅ **Well-Documented** - See what each sequence does
✅ **Educational** - Learn machine behavior through examples
✅ **Visual Feedback** - See validation badges for comprehensive sequences

---

## Files

**UI Component**:
- `visualizer/frontend/src/components/InputSequenceSelector.tsx` - Main selector component

**Integration**:
- `visualizer/frontend/src/components/InputStreamVisualization.tsx` - Left sidebar integration

**Backend Examples**:
- `src/examples/rs-flip-flop/rs-flip-flop-sequences.ts` - RS Flip-Flop sequences
- `src/examples/multi-step/multi-step-sequences.ts` - Multi-Step sequences
- `src/examples/data-center-monitoring/data-center-sequences.ts` - Data Center sequences

---

**Last Updated**: 2026-02-01
**Version**: 1.1.0
**Feature Status**: ✅ Production Ready
