# Reality Engine Output Arbiter Architecture

> **Implementation note:** The arbiter described here was originally designed in TypeScript (`src/models/OutputArbiter.ts`). The production Docker container runs the Scala implementation in `scala/src/main/scala/com/realityengine/`. The arbiter semantics (AND/OR/PASSTHROUGH) are equivalent in both, but the file paths and class names differ.

## Overview

The Reality Engine uses a 3-phase processing workflow with an Output Arbiter that manages output assertion. The arbiter uses combinatorial logic (AND/OR/PASSTHROUGH) to resolve the final machine output from sequence outputs.

---

## Architecture Overview

### Before: Sequence-Level Processing
```
Input → Process All Sequences → Collect All Outputs → Return Combined Outputs
```

### After: Machine-Level Processing with Arbiter
```
Phase 1: Resolve Input Reality Vector
         ↓
Phase 2: Apply Input to All Active Events (Sequences)
         ↓ (collect sequence outputs)
Phase 3: Resolve Output Reality Vector via Arbiter
         ↓
        Machine Output
```

---

## Core Components

### 1. OutputArbiter

**Location**: `/src/models/OutputArbiter.ts`

**Purpose**: Manages the output stream generation flow when final events match.

**Combinatorial Rules**:
- **AND**: Machine outputs only if ALL sequences produce output
- **OR**: Machine outputs if AT LEAST ONE sequence produces output
- **PASSTHROUGH** (default): Machine outputs whenever any outputs exist

**Key Methods**:
```typescript
class OutputArbiter {
  arbitrate(
    sequenceOutputs: Map<string, OutputVector[]>,
    totalSequences: number
  ): ArbiterResult

  setRule(rule: ArbiterRule): void
  getRule(): ArbiterRule
}
```

**Arbitration Logic**:
1. Collect all outputs from all sequences
2. Count sequences that produced outputs
3. Apply combinatorial rule (AND/OR/PASSTHROUGH)
4. If conditions met, combine outputs into single machine output
5. Return ArbiterResult with decision

**Output Combination Strategy**:
Currently uses simple concatenation:
- Concatenates all output vectors
- Aggregates metadata
- Tracks source output IDs

Future strategies could include:
- Bitwise AND/OR for binary vectors
- Weighted averaging
- Custom combinatorial functions

---

### 2. Machine.processInput()

**Location**: `/src/models/Machine.ts`

**Purpose**: Implements the 3-phase workflow for processing inputs through a machine.

**3-Phase Workflow**:

#### Phase 1: Resolve New Input Reality Vector
```typescript
const result: MachineTransitionResult = {
  inputVector,
  timestamp: Date.now(),
  sequenceResults: new Map(),
  machineOutput: null,
  arbiterMetadata: { ... }
};
```
- Receive and validate input vector
- Initialize result structure

#### Phase 2: Apply Input to All Active Events
```typescript
for (const [sequenceId, sequence] of this.sequences) {
  const transitionResult = sequence.transition(inputVector);

  result.sequenceResults.set(sequenceId, {
    matchedVectors: transitionResult.matchedVectors,
    activatedVectors: transitionResult.activatedVectors,
    assertedOutputs: transitionResult.assertedOutputs
  });

  sequenceOutputs.set(sequenceId, transitionResult.assertedOutputs);
}
```
- Process input through each sequence
- Collect sequence results
- Collect sequence outputs for arbitration

#### Phase 3: Resolve Output Reality Vector via Arbiter
```typescript
const arbiterResult = this.arbiter.arbitrate(
  sequenceOutputs,
  this.sequences.size
);

result.machineOutput = arbiterResult.machineOutput;
result.arbiterMetadata = arbiterResult.metadata;
```
- Use arbiter to determine if machine should output
- Combine sequence outputs if conditions met
- Set final machine output

---

### 3. RealityEngine.processMachineInput()

**Location**: `/src/engine/RealityEngine.ts`

**Purpose**: New entry point for processing inputs through machines.

**Method Signature**:
```typescript
processMachineInput(
  machineId: string,
  inputVector: number[]
): MachineTransitionResult
```

**Processing Flow**:
```typescript
processMachineInput(machineId, inputVector) {
  // 1. Get machine
  const machine = this.machines.get(machineId);

  // 2. Process through machine (3-phase workflow)
  const result = machine.processInput(inputVector);

  // 3. Tag machine output with machine metadata
  if (result.machineOutput) {
    result.machineOutput.metadata = {
      ...result.machineOutput.metadata,
      machineId,
      machineName: machine.name
    };
  }

  return result;
}
```

**Legacy Support**:
- Old `processInput()` method still exists for backward compatibility
- Processes through sequences directly without arbiter
- Will be deprecated in future versions

---

### 4. API Endpoint

**Location**: `/src/api/routes.ts`

**Endpoint**: `POST /api/machines/:id/process`

**Request Body**:
```json
{
  "vector": [1.0, 0.0, 1.0]
}
```

**Response**:
```json
{
  "result": {
    "inputVector": [1.0, 0.0, 1.0],
    "timestamp": 1738209600000,
    "sequenceResults": {
      "seq-id-1": {
        "matchedVectors": ["vec-id-1"],
        "activatedVectors": ["vec-id-2"],
        "assertedOutputs": [...]
      },
      "seq-id-2": { ... }
    },
    "machineOutput": {
      "id": "machine-output-123",
      "vector": [1.0],
      "timestamp": 1738209600000,
      "metadata": {
        "arbiter": true,
        "combinedFrom": 2,
        "sources": ["output-1", "output-2"],
        "machineId": "machine-123",
        "machineName": "NAND Gate"
      }
    },
    "arbiterMetadata": {
      "rule": "passthrough",
      "totalInputs": 2,
      "sequencesWithOutput": 2,
      "shouldOutput": true
    }
  }
}
```

---

## Type Definitions

### MachineTransitionResult

```typescript
export interface MachineTransitionResult {
  inputVector: number[];
  timestamp: number;
  sequenceResults: Map<string, {
    matchedVectors: string[];
    activatedVectors: string[];
    assertedOutputs: OutputVector[];
  }>;
  machineOutput: OutputVector | null;
  arbiterMetadata: {
    rule: string;
    totalInputs: number;
    sequencesWithOutput: number;
    shouldOutput: boolean;
  };
}
```

### ArbiterResult

```typescript
export interface ArbiterResult {
  shouldOutput: boolean;
  machineOutput: OutputVector | null;
  metadata: {
    rule: ArbiterRule;
    totalInputs: number;
    sequencesWithOutput: number;
    combinedOutputs: OutputVector[];
  };
}
```

### ArbiterRule

```typescript
export enum ArbiterRule {
  AND = 'and',              // All sequences must produce output
  OR = 'or',                // At least one sequence must produce output
  PASSTHROUGH = 'passthrough' // Pass all outputs through
}
```

---

## Workflow Examples

### Example 1: NAND Gate Machine with PASSTHROUGH Rule

**Machine Setup**:
- 4 sequences (one for each truth table row)
- Default arbiter rule: PASSTHROUGH

**Input: [0, 0]**

**Phase 1**: Input received `[0, 0]`

**Phase 2**: Apply to sequences
- Sequence "NAND(0,0)" matches → outputs `[1.0]`
- Sequence "NAND(0,1)" inactive
- Sequence "NAND(1,0)" inactive
- Sequence "NAND(1,1)" inactive

**Phase 3**: Arbiter processes
- Rule: PASSTHROUGH
- Sequences with output: 1
- Decision: `shouldOutput = true` (at least one output exists)
- Machine output: `[1.0]` with metadata

**Result**:
```json
{
  "machineOutput": {
    "id": "machine-output-...",
    "vector": [1.0],
    "metadata": {
      "arbiter": true,
      "combinedFrom": 1,
      "sources": ["nand-output-00"],
      "machineId": "nand-gate-example",
      "machineName": "NAND Gate Logic"
    }
  },
  "arbiterMetadata": {
    "rule": "passthrough",
    "total Inputs": 4,
    "sequencesWithOutput": 1,
    "shouldOutput": true
  }
}
```

---

### Example 2: Multi-Sequence Machine with AND Rule

**Machine Setup**:
- 3 sequences that must all complete for valid output
- Arbiter rule: AND

**Input: [1, 0, 1]**

**Phase 2**: Apply to sequences
- Sequence A matches → outputs `[0.5]`
- Sequence B matches → outputs `[0.3]`
- Sequence C does NOT match → no output

**Phase 3**: Arbiter processes
- Rule: AND
- Sequences with output: 2 out of 3
- Decision: `shouldOutput = false` (not all sequences produced output)
- Machine output: `null`

**Result**:
```json
{
  "machineOutput": null,
  "arbiterMetadata": {
    "rule": "and",
    "totalInputs": 3,
    "sequencesWithOutput": 2,
    "shouldOutput": false
  }
}
```

**Next Input: [1, 1, 1]**

**Phase 2**: All three sequences match and produce outputs

**Phase 3**: Arbiter processes
- Rule: AND
- Sequences with output: 3 out of 3
- Decision: `shouldOutput = true` (all sequences produced output)
- Machine output: Combined vector `[0.5, 0.3, 0.7]`

---

## Benefits

### 1. Clear Separation of Concerns
- **Sequences**: Handle pattern matching and transitions
- **Arbiter**: Handles output combination logic
- **Machine**: Coordinates workflow

### 2. Flexible Combinatorial Logic
- AND: Require all sequences to agree
- OR: Accept any sequence output
- PASSTHROUGH: Collect all outputs
- Extensible for future rules (XOR, majority vote, etc.)

### 3. Machine-Level Abstraction
- Machines now have well-defined input/output behavior
- Easier to compose machines into larger systems
- Clear contract for machine consumers

### 4. Temporal Consistency
- Outputs are only from the SAME input processing cycle
- No mixing of outputs from different time steps
- Enforced by the 3-phase workflow

### 5. Metadata Tracking
- Full traceability of output sources
- Arbiter decision metadata
- Machine and sequence identification

---

## Comparison: Old vs New

| Aspect | Old Architecture | New Architecture |
|--------|------------------|------------------|
| **Entry Point** | `engine.processInput(vector)` | `engine.processMachineInput(machineId, vector)` |
| **Processing Unit** | Individual sequences | Complete machine |
| **Output Logic** | Collect all outputs | Arbiter resolves machine output |
| **Output Metadata** | Only sequenceId | machineId, arbiter info, sources |
| **Workflow** | 1-phase (process sequences) | 3-phase (resolve, apply, arbitrate) |
| **Combination** | Implicit concatenation | Explicit arbiter rules |
| **Machine Contract** | Undefined | Well-defined MachineTransitionResult |

---

## Usage

### Creating a Machine with Arbiter

```typescript
import { Machine } from './models/Machine.js';
import { ArbiterRule } from './models/OutputArbiter.js';
import { CriticalEventSequence } from './models/CriticalEventSequence.js';

// Create machine with AND arbiter rule
const machine = new Machine(
  'Logic Validator',
  'Validates logic gates',
  {},
  ArbiterRule.AND  // All sequences must output
);

// Add sequences
machine.addSequence(sequenceA);
machine.addSequence(sequenceB);
machine.addSequence(sequenceC);

// Process input
const result = machine.processInput([1, 0, 1]);

if (result.machineOutput) {
  console.log('Machine produced output:', result.machineOutput.vector);
} else {
  console.log('Machine did not produce output');
  console.log('Reason:', result.arbiterMetadata);
}
```

### Using the API

```bash
# Process input through a machine
curl -k -X POST https://localhost:3000/api/machines/nand-gate-example/process \
  -H "Content-Type: application/json" \
  -d '{"vector": [1, 0]}'
```

### Changing Arbiter Rule

```typescript
const machine = engine.getMachine('machine-id');
machine.setArbiterRule(ArbiterRule.OR);  // Change to OR logic
```

---

## File Structure

```
src/
├── models/
│   ├── OutputArbiter.ts          ← NEW: Arbiter implementation
│   ├── Machine.ts                 ← UPDATED: Added processInput() method
│   ├── types.ts                   ← UPDATED: Added MachineTransitionResult
│   ├── CriticalEventSequence.ts   (unchanged)
│   └── RealityVector.ts           (unchanged)
├── engine/
│   └── RealityEngine.ts           ← UPDATED: Added processMachineInput()
└── api/
    └── routes.ts                  ← UPDATED: Added POST /machines/:id/process
```

---

## Future Enhancements

### 1. Advanced Combination Strategies

```typescript
// Bitwise AND for binary vectors
combineStrategyAND(outputs: OutputVector[]): OutputVector {
  // Perform element-wise AND operation
  const result = outputs[0].vector.map((val, idx) => {
    return outputs.every(out => out.vector[idx] === 1) ? 1 : 0;
  });
  return { vector: result, ... };
}

// Weighted averaging
combineStrategyWeighted(outputs: OutputVector[], weights: number[]): OutputVector {
  // Weight each output and average
  const result = outputs[0].vector.map((_, idx) => {
    return outputs.reduce((sum, out, i) =>
      sum + out.vector[idx] * weights[i], 0
    ) / weights.reduce((a, b) => a + b);
  });
  return { vector: result, ... };
}
```

### 2. Conditional Arbiter Rules

```typescript
// Different rules based on context
class ConditionalArbiter extends OutputArbiter {
  selectRule(context: any): ArbiterRule {
    if (context.criticalPath) return ArbiterRule.AND;
    if (context.opportunistic) return ArbiterRule.OR;
    return ArbiterRule.PASSTHROUGH;
  }
}
```

### 3. Arbiter Chaining

```typescript
// Compose multiple arbiters
class ChainedArbiter {
  constructor(
    private primary: OutputArbiter,
    private fallback: OutputArbiter
  ) {}

  arbitrate(outputs, total) {
    const result = this.primary.arbitrate(outputs, total);
    if (!result.shouldOutput) {
      return this.fallback.arbitrate(outputs, total);
    }
    return result;
  }
}
```

### 4. Machine Composition

```typescript
// Machines as building blocks for larger systems
class MachinePipeline {
  constructor(private machines: Machine[]) {}

  process(input: number[]): OutputVector {
    let current = input;
    for (const machine of this.machines) {
      const result = machine.processInput(current);
      if (!result.machineOutput) break;
      current = result.machineOutput.vector;
    }
    return current;
  }
}
```

---

## Testing

### Unit Tests

```typescript
describe('OutputArbiter', () => {
  it('should use AND logic correctly', () => {
    const arbiter = new OutputArbiter(ArbiterRule.AND);
    const outputs = new Map([
      ['seq1', [output1]],
      ['seq2', [output2]]
    ]);

    const result = arbiter.arbitrate(outputs, 2);
    expect(result.shouldOutput).toBe(true);
  });

  it('should not output with AND if one sequence missing', () => {
    const arbiter = new OutputArbiter(ArbiterRule.AND);
    const outputs = new Map([
      ['seq1', [output1]],
      ['seq2', []]  // No output
    ]);

    const result = arbiter.arbitrate(outputs, 2);
    expect(result.shouldOutput).toBe(false);
  });
});

describe('Machine.processInput', () => {
  it('should execute 3-phase workflow', () => {
    const machine = new Machine('Test', '');
    machine.addSequence(sequence1);
    machine.addSequence(sequence2);

    const result = machine.processInput([1, 0]);

    expect(result.inputVector).toEqual([1, 0]);
    expect(result.sequenceResults.size).toBe(2);
    expect(result.machineOutput).toBeDefined();
    expect(result.arbiterMetadata.rule).toBe('passthrough');
  });
});
```

---

## Deployment

### Backend
- **Image**: `realityengine_ai-reality-engine`
- **Status**: Healthy ✅
- **New Components**:
  - OutputArbiter class
  - Machine.processInput() method
  - RealityEngine.processMachineInput() method
  - POST /api/machines/:id/process endpoint

### API Endpoints
- **Legacy**: `POST /api/engine/process` (still available)
- **New**: `POST /api/machines/:id/process` (preferred)

### Breaking Changes
- None - fully backward compatible
- Old sequence-level processing still works
- New machine-level processing is opt-in

---

## Summary

✅ **Reality Engine Output Arbiter Architecture successfully implemented**

**Components Added**:
- OutputArbiter class with AND/OR/PASSTHROUGH rules
- Machine.processInput() with 3-phase workflow
- RealityEngine.processMachineInput() method
- POST /machines/:id/process API endpoint
- MachineTransitionResult type

**Workflow**:
1. Resolve new input reality vector
2. Apply input to all active events (sequences)
3. Resolve output reality vector via arbiter

**Benefits**:
- Clear separation of concerns
- Flexible combinatorial logic
- Machine-level abstraction
- Temporal consistency
- Full traceability

**Status**: Production ready and deployed

---

**Change Date**: January 30, 2026
**Deployed**: ✅ Complete
**Tested**: ✅ Compiled and services healthy
**Architecture**: 3-Phase Workflow with Output Arbiter
**Breaking Changes**: None (backward compatible)
