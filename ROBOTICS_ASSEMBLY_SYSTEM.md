# Robotics Assembly System - Specification Example

**Date:** January 18, 2026
**Type:** Specification Compliance Example
**Difficulty:** Intermediate
**Category:** Automated Manufacturing

## Overview

The Robotics Assembly System is a specification-compliant example designed to demonstrate exact requirements:

### Specifications Met:
✅ **5 critical event sequences**
✅ **Input space dimension: 5**
✅ **Output space dimension: 3**
✅ **Average sequence length: 10 events** (all sequences have exactly 10 events)
✅ **7 output events across sequences** (distributed as 2+2+1+1+1)
✅ **Match threshold: 0.60** (all events use threshold 0.60)
✅ **Sample run generates 10+ outputs** (generates exactly 11 outputs)

## Event Space: 5-Dimensional Continuous Vectors

Input vectors represent real-time sensor readings from the robotics assembly system:

| Index | Dimension | Description | Range | Physical Mapping |
|-------|-----------|-------------|-------|------------------|
| [0] | ARM_POSITION | Robotic arm angular position | 0.0-1.0 | 0-360° normalized |
| [1] | GRIPPER_FORCE | Gripper force sensor reading | 0.0-1.0 | 0-100N normalized |
| [2] | CONVEYOR_SPEED | Conveyor belt speed | 0.0-1.0 | 0-2 m/s normalized |
| [3] | VISION_CONF | Vision system confidence | 0.0-1.0 | 0-100% confidence |
| [4] | TOOL_TEMP | Tool temperature sensor | 0.0-1.0 | 20-120°C normalized |

### Example Input Vector:
```
[0.35, 0.5, 0.0, 0.9, 0.0]
```
**Interpretation:** Arm at 126° (35%), gripper applying 50N force (50%), conveyor stopped (0%), high vision confidence (90%), normal tool temperature (0%).

## Output Space: 3-Dimensional Action Vectors

Output vectors encode discrete actions and status information:

| Index | Dimension | Description | Values |
|-------|-----------|-------------|--------|
| [0] | ACTION_CODE | Type of action to execute | 1.0=PICK, 2.0=PLACE, 3.0=INSPECT, 4.0=CHANGE_TOOL, 5.0=EMERGENCY_STOP, 6.0=CALIBRATE |
| [1] | SPEED_MODIFIER | Speed adjustment factor | 0.0-1.0 (percentage of max speed) |
| [2] | QUALITY_FLAG | Quality assessment | 0.0=FAIL, 0.5=WARNING, 1.0=PASS |

### Example Output Vector:
```
[1.0, 0.5, 1.0]
```
**Interpretation:** Execute PICK action (1.0) at 50% speed (0.5), quality status PASS (1.0).

## Critical Event Sequences

All 5 sequences have exactly **10 events** each, for a total of **50 events** across the machine.

### Sequence 1: Pick and Place Operation (10 events, 2 outputs)

**Description:** Complete pick-and-place cycle with vision-guided manipulation.

**Path:** Home → Move to Pick → Approach → Align → **Lower Gripper [OUTPUT 1]** → Close Gripper → Lift → Move to Place → Lower to Place → **Release [OUTPUT 2]**

**Outputs:**
- Event 5: `[1.0, 0.5, 1.0]` - PICK action
- Event 10: `[2.0, 0.5, 1.0]` - PLACE action

**Match Threshold:** 0.60 for all events

### Sequence 2: Quality Inspection Operation (10 events, 2 outputs)

**Description:** Multi-point vision-based quality inspection.

**Path:** Inspection Start → Scan Pos 1-4 → **Analyze [OUTPUT 1]** → Detail Check 1-3 → **Inspection Complete [OUTPUT 2]**

**Outputs:**
- Event 6: `[3.0, 0.3, 0.5]` - INSPECT preliminary (WARNING)
- Event 10: `[3.0, 0.5, 1.0]` - INSPECT final (PASS)

**Match Threshold:** 0.60 for all events

### Sequence 3: Tool Change Operation (10 events, 1 output)

**Description:** Automated tool changing sequence.

**Path:** Tool Change Start → Tool Change Steps 2-9 → **Tool Change Complete [OUTPUT]**

**Outputs:**
- Event 10: `[4.0, 0.8, 1.0]` - CHANGE_TOOL complete

**Match Threshold:** 0.60 for all events

### Sequence 4: Emergency Stop Operation (10 events, 1 output)

**Description:** Safety shutdown on force/temperature anomaly detection.

**Path:** Anomaly Detected → Emergency Escalation Steps 2-9 → **EMERGENCY STOP [OUTPUT]**

**Outputs:**
- Event 10: `[5.0, 0.0, 0.0]` - EMERGENCY_STOP (FAIL status)

**Match Threshold:** 0.60 for all events

### Sequence 5: Calibration Operation (10 events, 1 output)

**Description:** System calibration and homing procedure.

**Path:** Calibration Start → Calibration Points 2-9 → **Calibration Complete [OUTPUT]**

**Outputs:**
- Event 10: `[6.0, 1.0, 1.0]` - CALIBRATE complete

**Match Threshold:** 0.60 for all events

## Output Events Distribution

**Total Output Events in Sequences: 7**

| Sequence | Events | Output Events | Locations |
|----------|--------|---------------|-----------|
| Pick and Place | 10 | 2 | Events 5, 10 |
| Quality Inspection | 10 | 2 | Events 6, 10 |
| Tool Change | 10 | 1 | Event 10 |
| Emergency Stop | 10 | 1 | Event 10 |
| Calibration | 10 | 1 | Event 10 |
| **TOTAL** | **50** | **7** | - |

## Sample Run: 70-Step Comprehensive Workflow

The provided test sequence executes a complete manufacturing workflow that generates **11 outputs** (exceeding the 10+ requirement).

### Workflow Breakdown:

1. **First Pick and Place Cycle** (Steps 1-10)
   - Output 1 (Step 5): PICK action
   - Output 2 (Step 10): PLACE action

2. **First Quality Inspection** (Steps 11-20)
   - Output 3 (Step 16): INSPECT preliminary
   - Output 4 (Step 20): INSPECT final

3. **Second Pick and Place Cycle** (Steps 21-30)
   - Output 5 (Step 25): PICK action
   - Output 6 (Step 30): PLACE action

4. **Second Quality Inspection** (Steps 31-40)
   - Output 7 (Step 36): INSPECT preliminary
   - Output 8 (Step 40): INSPECT final

5. **Tool Change** (Steps 41-50)
   - Output 9 (Step 50): CHANGE_TOOL complete

6. **Emergency Stop** (Steps 51-60)
   - Output 10 (Step 60): EMERGENCY_STOP

7. **Calibration** (Steps 61-70)
   - Output 11 (Step 70): CALIBRATE complete

### Expected Timeline (at 500ms/step):

```
00:04 → Output 1:  PICK
00:09 → Output 2:  PLACE
00:15 → Output 3:  INSPECT (preliminary)
00:19 → Output 4:  INSPECT (final)
00:24 → Output 5:  PICK
00:29 → Output 6:  PLACE
00:35 → Output 7:  INSPECT (preliminary)
00:39 → Output 8:  INSPECT (final)
00:49 → Output 9:  CHANGE_TOOL
00:59 → Output 10: EMERGENCY_STOP
01:09 → Output 11: CALIBRATE
```

**Total Duration:** ~35 seconds
**Total Outputs:** 11 outputs (meets 10+ requirement ✅)

## Technical Implementation Details

### Match Threshold: 0.60

All 50 events across all 5 sequences use a uniform match threshold of **0.60**:

```typescript
const threshold = 0.60;
{ value: 0.35, comparatorType: ComparatorType.THRESHOLD, threshold }
```

This means an input value matches if it's within ±0.60 of the target value. For example:
- Target: 0.35, Threshold: 0.60 → Matches range: [-0.25, 0.95] (clamped to [0.0, 1.0])
- Target: 0.90, Threshold: 0.60 → Matches range: [0.30, 1.50] (clamped to [0.30, 1.0])

### Comparator Types

- **THRESHOLD:** Fuzzy matching with tolerance (primary method used)
- **PATTERN:** Wildcard matching (used for dimensions not being monitored)

### Event Connectivity

All sequences are linear (no branching):
```
Event 1 → Event 2 → Event 3 → ... → Event 10
```

Each event has exactly one predecessor (except initial) and one successor (except final).

## Using the Robotics Assembly Example

### Loading the Example

**Via UI:**
1. Open the Reality Engine visualizer
2. Click on **"Robotics Assembly System"** card
3. Click **"Load Example"** button

**Via API:**
```typescript
import { api } from './api';
const result = await api.loadRoboticsAssemblyExample();
```

**Via Store:**
```typescript
import { useVisualizerStore } from './store';
const { loadRoboticsAssemblyExample } = useVisualizerStore();
await loadRoboticsAssemblyExample();
```

### Running the Simulation

1. **Load Test Vectors:** Click "Load Input Vectors" → Select "Complete Assembly Workflow" (70 vectors)
2. **Auto-Play:** Click "Start" to auto-play at 500ms/step (~35 second total duration)
3. **Step-by-Step:** Click "Step" button to advance through each input vector manually
4. **Observe Outputs:** Watch the OUTPUT STREAM panel - should accumulate 11 outputs by the end

### Expected Behavior

- **Sequences activated:** All 5 sequences will activate and complete during the workflow
- **Output generation:** 11 total outputs (4 from pick-place, 4 from inspection, 3 from other sequences)
- **Active state highlighting:** Nodes show active state as inputs match
- **⚡ OUTPUT indicator:** Final events show output indicator when outputs are generated

## Specification Compliance Summary

| Requirement | Specification | Implementation | Status |
|-------------|---------------|----------------|--------|
| Critical Event Sequences | 5 | 5 sequences | ✅ |
| Input Dimensions | 5 | 5D vectors | ✅ |
| Output Dimensions | 3 | 3D vectors | ✅ |
| Average Sequence Length | 10 | 10 events each | ✅ |
| Total Events | ~50 | 50 events (5×10) | ✅ |
| Output Events in Sequences | ≥7 | 7 output events | ✅ |
| Match Threshold | 0.60 | 0.60 all events | ✅ |
| Sample Run Outputs | ≥10 | 11 outputs | ✅ |

## Implementation Files

- **Sequences:** `src/examples/robotics-assembly/robotics-assembly-sequences.ts`
  - `createPickAndPlaceSequence()` - 10 events, 2 outputs
  - `createQualityInspectionSequence()` - 10 events, 2 outputs
  - `createToolChangeSequence()` - 10 events, 1 output
  - `createEmergencyStopSequence()` - 10 events, 1 output
  - `createCalibrationSequence()` - 10 events, 1 output
  - `generateRoboticsTestVectors()` - 70-step sample run
  - `createRoboticsAssemblyMachine()` - Machine configuration

- **Backend:** `src/api/routes.ts` - Auto-loading + `/api/demo/robotics-assembly` endpoint
- **Frontend:** `visualizer/frontend/src/api.ts` + `store.ts` - API and store integration
- **Visualizer Backend:** `visualizer/backend/src/server.ts` - Proxy endpoint

## Version History

| Version | Date | Changes |
|---------|------|---------|
| 1.0.0 | 2026-01-18 | Initial specification-compliant implementation |

---

**Ready to Use:** ✅ Fully integrated and deployed
**Specifications:** 5 sequences, 5D input, 3D output, 0.60 threshold, 10+ outputs
**Recommended For:** Demonstrating specification compliance and multi-sequence workflows
