# Data Center Monitoring - Advanced Example

**Date:** January 17, 2026
**Type:** Complex Critical Event Sequences
**Difficulty:** Advanced
**Category:** Multi-Dimensional Infrastructure Monitoring

## Overview

The Data Center Monitoring example demonstrates **advanced critical event sequence relationships** with:
- **Non-binary input vectors** (continuous sensor readings)
- **Variable threshold matching functions** (adaptive tolerance based on criticality)
- **Multi-dimensional dependencies** (temperature correlates with CPU load)
- **Complex pattern detection** (power efficiency = power/load ratio)
- **Correlated failure sequences** (cascading failures across subsystems)
- **Multiple outputs per critical event** (emergency triggers coordinated actions)

This example showcases the full power of the Reality Engine for real-world infrastructure monitoring scenarios.

## Event Space: 8-Dimensional Continuous Vectors

Input vectors represent simultaneous sensor readings from multiple data center subsystems:

| Dimension | Name | Description | Range | Units |
|-----------|------|-------------|-------|-------|
| [0] | CPU_TEMP | CPU temperature | 0.0-1.0 | Normalized (20°C-100°C) |
| [1] | CPU_LOAD | CPU utilization | 0.0-1.0 | Percentage (0%-100%) |
| [2] | NETWORK_BWTH | Network bandwidth | 0.0-1.0 | Normalized (0-10 Gbps) |
| [3] | POWER_WATTS | Power consumption | 0.0-1.0 | Normalized (0-10000W) |
| [4] | STORAGE_USED | Storage capacity used | 0.0-1.0 | Percentage (0%-100%) |
| [5] | MEMORY_USED | Memory utilization | 0.0-1.0 | Percentage (0%-100%) |
| [6] | DISK_IO | Disk I/O operations | 0.0-1.0 | Normalized ops/sec |
| [7] | SECURITY_SCORE | Security threat level | 0.0-1.0 | 0=secure, 1=breach |

### Example Input Vector:

```
[0.78, 0.88, 0.75, 0.85, 0.75, 0.82, 0.78, 0.28]
```

**Interpretation:**
- CPU Temperature: 78% of range ≈ 82.4°C (high)
- CPU Load: 88% utilization (very high)
- Network: 75% bandwidth ≈ 7.5 Gbps (congested)
- Power: 85% capacity ≈ 8500W (high)
- Storage: 75% used (approaching full)
- Memory: 82% used (high)
- Disk I/O: 78% of max (heavy activity)
- Security: 28% threat level (elevated)

## Output Space: 12-Dimensional One-Hot Encoded Actions

Output vectors represent discrete actions triggered by critical events:

| Position | Action | Description |
|----------|--------|-------------|
| [0] | NORMAL | All systems operating normally |
| [1] | WARNING | Warning condition - monitoring required |
| [2] | CRITICAL | Critical condition - intervention needed |
| [3] | EMERGENCY | Emergency - immediate action required |
| [4] | COOLING_ACTIVATE | Activate emergency cooling systems |
| [5] | LOAD_BALANCER | Activate network load balancer |
| [6] | BACKUP_POWER | Switch to backup power systems |
| [7] | CLEANUP_STORAGE | Initiate storage cleanup procedures |
| [8] | SECURITY_LOCKDOWN | Initiate security lockdown |
| [9] | THROTTLE_CPU | Throttle CPU to reduce load/heat |
| [10] | DEDUP_STORAGE | Run storage deduplication |
| [11] | CACHE_FLUSH | Flush non-critical caches |

## Critical Event Sequences

### 1. Thermal Overload with Load Correlation

**Path:** Normal → Warm → Hot → Critical → Thermal Emergency

**Key Feature:** Multi-dimensional dependency between CPU temperature and CPU load.

**Sequence States:**

1. **Normal** (20-40°C, <50% load)
   - CPU_TEMP: 0.25 ±0.15 (loose threshold)
   - CPU_LOAD: 0.30 ±0.25 (very loose threshold)
   - Output: `[NORMAL]` - "Thermal status: Normal"

2. **Warm** (40-60°C, 50-70% load)
   - CPU_TEMP: 0.50 ±0.12 (tighter threshold)
   - CPU_LOAD: 0.60 ±0.15
   - Output: `[WARNING]` - "Temperature rising with load"

3. **Hot** (60-75°C, 70-85% load)
   - CPU_TEMP: 0.69 ±0.10 (even tighter)
   - CPU_LOAD: 0.78 ±0.12
   - Output: `[WARNING]` - "High temperature under load"

4. **Critical** (75-85°C, 85-95% load)
   - CPU_TEMP: 0.81 ±0.07 (very tight threshold)
   - CPU_LOAD: 0.88 ±0.08
   - Outputs:
     - `[CRITICAL]` - "Temperature approaching thermal limit"
     - `[THROTTLE_CPU]` - "Throttle CPU to reduce heat"

5. **Thermal Emergency** (>85°C, >90% load)
   - CPU_TEMP: 0.91 ±0.05 (extremely tight)
   - CPU_LOAD: 0.94 ±0.04
   - Outputs:
     - `[EMERGENCY]` - "Immediate action required"
     - `[COOLING_ACTIVATE]` - "Activate emergency cooling"
     - `[THROTTLE_CPU]` - "Force CPU throttling"

**Why This is Complex:**
- Thresholds become **progressively tighter** as criticality increases
- **Both dimensions must match** (temp AND load correlated)
- Multiple outputs at critical stages
- Demonstrates realistic thermal management under load

### 2. Network Traffic Surge Detection

**Path:** Baseline → Elevated → Surge → Congestion → Overflow

**Key Feature:** Pattern-based anomaly detection with tight thresholds for surge detection.

**Sequence States:**

1. **Baseline** (<3 Gbps)
   - NETWORK: 0.28 ±0.15
   - Output: `[NORMAL]`

2. **Elevated** (3-5 Gbps)
   - NETWORK: 0.48 ±0.12
   - Output: `[WARNING]` - "Traffic elevated - monitoring"

3. **Surge** (5-7 Gbps)
   - NETWORK: 0.65 ±0.10
   - Output: `[WARNING]` - "Surge detected - preparing load balancer"

4. **Congestion** (7-9 Gbps)
   - NETWORK: 0.82 ±0.08
   - Output: `[CRITICAL]` - "Congestion detected"

5. **Overflow** (>9 Gbps)
   - NETWORK: 0.93 ±0.05
   - Outputs:
     - `[EMERGENCY]` - "Capacity exceeded"
     - `[LOAD_BALANCER]` - "Activate load balancer NOW"

**Why This is Complex:**
- Detects **sudden spikes** using progressively tighter thresholds
- Uses PATTERN matching for dimensions not being monitored
- Demonstrates single-dimension monitoring with high precision

### 3. Power Efficiency Monitoring (Power/Load Ratio)

**Path:** Efficient → Moderate → Inefficient → Wasteful → Power Crisis

**Key Feature:** Monitors power consumption **relative to** CPU load to detect inefficiency.

**Sequence States:**

1. **Efficient** (Power ≈ Load)
   - CPU_LOAD: 0.35 ±0.20
   - POWER: 0.38 ±0.18 (closely matches load)
   - Output: `[NORMAL]` - "Optimal efficiency"

2. **Moderate** (Power > Load)
   - CPU_LOAD: 0.45 ±0.15
   - POWER: 0.58 ±0.12 (13% higher than load)
   - Output: `[WARNING]` - "Slightly elevated"

3. **Inefficient** (Power >> Load)
   - CPU_LOAD: 0.52 ±0.12
   - POWER: 0.75 ±0.10 (23% higher than load)
   - Output: `[WARNING]` - "Poor efficiency - investigate"

4. **Wasteful** (Major inefficiency)
   - CPU_LOAD: 0.58 ±0.10
   - POWER: 0.87 ±0.07 (29% higher than load)
   - Output: `[CRITICAL]` - "Wasteful operation"

5. **Power Crisis** (Near capacity despite low load)
   - CPU_LOAD: 0.62 ±0.08
   - POWER: 0.96 ±0.04 (34% higher than load)
   - Outputs:
     - `[EMERGENCY]` - "Approaching capacity limit"
     - `[BACKUP_POWER]` - "Prepare backup power"

**Why This is Complex:**
- Monitors **relationship between two dimensions** (ratio detection)
- Detects inefficiency (high power, moderate load = problem)
- Demonstrates multi-dimensional pattern analysis

### 4. Storage Deduplication Detection

**Path:** Healthy → Growing → High → Critical → Dedup Opportunity

**Key Feature:** Correlates storage usage with disk I/O to detect deduplication opportunities.

**Sequence States:**

1. **Healthy** (<50% used, normal I/O)
   - STORAGE: 0.35 ±0.18
   - DISK_IO: 0.28 ±0.15
   - Output: `[NORMAL]`

2. **Growing** (50-70% used, elevated I/O)
   - STORAGE: 0.62 ±0.12
   - DISK_IO: 0.48 ±0.12
   - Output: `[WARNING]` - "Storage growing"

3. **High** (70-85% used, high I/O)
   - STORAGE: 0.78 ±0.09
   - DISK_IO: 0.72 ±0.10
   - Output: `[WARNING]` - "Analyzing for duplicates"

4. **Critical** (85-92% used, very high I/O)
   - STORAGE: 0.88 ±0.06
   - DISK_IO: 0.85 ±0.07
   - Output: `[CRITICAL]` - "High usage detected"

5. **Dedup Opportunity** (>92% used, sustained high I/O)
   - STORAGE: 0.95 ±0.04
   - DISK_IO: 0.92 ±0.05
   - Outputs:
     - `[EMERGENCY]` - "Nearly full"
     - `[DEDUP_STORAGE]` - "Run deduplication"
     - `[CLEANUP_STORAGE]` - "Initiate cleanup"

**Why This is Complex:**
- High storage + High I/O = Opportunity for deduplication
- Demonstrates **correlated metrics analysis**
- Multiple remediation actions at final stage

### 5. Memory-Cache Cascading Failure

**Path:** Normal → Pressure → Thrashing → Cascading → System Failure

**Key Feature:** Detects correlated memory/cache pressure leading to cascading system failures.

**Sequence States:**

1. **Normal Operation** (<60% memory)
   - CPU_LOAD: 0.40 ±0.20
   - MEMORY: 0.45 ±0.18
   - DISK_IO: 0.38 ±0.15
   - Output: `[NORMAL]`

2. **Memory Pressure** (60-80% memory, paging begins)
   - CPU_LOAD: 0.65 ±0.12
   - MEMORY: 0.72 ±0.10
   - DISK_IO: 0.58 ±0.12 (elevated due to paging)
   - Output: `[WARNING]` - "Cache misses rising"

3. **Thrashing** (80-92% memory, heavy paging)
   - CPU_LOAD: 0.82 ±0.08
   - MEMORY: 0.88 ±0.06
   - DISK_IO: 0.82 ±0.08 (heavy paging)
   - Outputs:
     - `[WARNING]` - "Performance severely degraded"
     - `[CACHE_FLUSH]` - "Flush non-critical caches"

4. **Cascading Failure** (>92% memory, system degrading)
   - CPU_LOAD: 0.92 ±0.05 (wait states)
   - MEMORY: 0.95 ±0.03
   - DISK_IO: 0.94 ±0.04 (maxed out)
   - Output: `[CRITICAL]` - "Cascading failure detected"

5. **System Failure** (>95% memory, OOM imminent)
   - CPU_LOAD: 0.97 ±0.03
   - MEMORY: 0.98 ±0.02
   - DISK_IO: 0.97 ±0.03
   - Outputs:
     - `[EMERGENCY]` - "System failure imminent"
     - `[CACHE_FLUSH]` - "Emergency cache flush"
     - `[THROTTLE_CPU]` - "Throttle workload immediately"

**Why This is Complex:**
- Monitors **three correlated dimensions** (CPU, Memory, Disk I/O)
- Memory pressure → Disk paging → CPU wait states (cascading effect)
- Demonstrates realistic cascading failure detection
- Multiple emergency actions to prevent total failure

## Sample Input Stream: Gradual Degradation Scenario

A 12-step test scenario demonstrating a data center experiencing gradual degradation leading to multiple critical events:

### Complete Timeline:

```
Step 1 (00:00:00): Normal baseline - all systems healthy
Vector: [0.25, 0.30, 0.28, 0.38, 0.35, 0.45, 0.38, 0.05]
Expected: All sequences at initial state

Step 2 (00:05:00): Slight increase across all metrics
Vector: [0.32, 0.38, 0.32, 0.42, 0.38, 0.48, 0.42, 0.08]
Expected: No sequence transitions yet

Step 3 (00:10:00): Load increasing - temp rising with load
Vector: [0.48, 0.58, 0.45, 0.55, 0.45, 0.52, 0.48, 0.12]
Expected: Thermal: Normal→Warm, Power: Efficient→Moderate

Step 4 (00:15:00): Moderate stress - efficiency degrading
Vector: [0.52, 0.65, 0.52, 0.62, 0.52, 0.58, 0.52, 0.15]
Expected: Continued degradation

Step 5 (00:20:00): High load with elevated temperature
Vector: [0.68, 0.75, 0.62, 0.72, 0.58, 0.65, 0.68, 0.18]
Expected: Thermal: Warm→Hot, Storage: Healthy→Growing

Step 6 (00:25:00): Sustained high load - storage growing
Vector: [0.72, 0.82, 0.68, 0.78, 0.68, 0.75, 0.72, 0.22]
Expected: Network: Baseline→Elevated→Surge, Power: Moderate→Inefficient

Step 7 (00:30:00): Critical thermal levels - network surge detected
Vector: [0.78, 0.88, 0.75, 0.85, 0.75, 0.82, 0.78, 0.28]
Expected: Thermal: Hot→Critical, Storage: Growing→High, Memory: Normal→Pressure

Step 8 (00:35:00): Multiple systems approaching critical
Vector: [0.82, 0.90, 0.82, 0.88, 0.82, 0.88, 0.82, 0.32]
Expected: Network: Surge→Congestion, Power: Inefficient→Wasteful

Step 9 (00:40:00): Cascading failures beginning - memory thrashing
Vector: [0.88, 0.94, 0.88, 0.92, 0.88, 0.92, 0.88, 0.38]
Expected: Storage: High→Critical, Memory: Pressure→Thrashing

Step 10 (00:45:00): EMERGENCY - Thermal emergency + Network overflow
Vector: [0.91, 0.96, 0.92, 0.95, 0.92, 0.95, 0.92, 0.42]
Expected:
  - Thermal: Critical→Emergency (COOLING + THROTTLE)
  - Network: Congestion→Overflow (LOAD_BALANCER)

Step 11 (00:50:00): CRITICAL - Power crisis + Storage dedup needed
Vector: [0.94, 0.98, 0.95, 0.97, 0.95, 0.96, 0.95, 0.45]
Expected:
  - Power: Wasteful→Crisis (BACKUP_POWER)
  - Storage: Critical→Dedup (DEDUP + CLEANUP)

Step 12 (00:55:00): TOTAL FAILURE - Memory exhausted, cascading failure
Vector: [0.96, 0.99, 0.97, 0.98, 0.97, 0.98, 0.97, 0.48]
Expected:
  - Memory: Thrashing→Cascading→Failure (CACHE_FLUSH + THROTTLE)
```

### Expected Output Stream (Chronological):

Over the course of the 12-step scenario, the output stream will accumulate approximately **25-30 outputs** from various sequences as they transition through states. Critical events will generate multiple simultaneous outputs.

**Example Output Accumulation:**

```
1. [NORMAL] - Thermal status: Normal
2. [NORMAL] - Network traffic: Normal
3. [NORMAL] - Power efficiency: Optimal
4. [NORMAL] - Storage status: Healthy
5. [NORMAL] - Memory/Cache status: Normal
... (baseline outputs from all sequences)
6. [WARNING] - Temperature rising with load
7. [WARNING] - Power efficiency: Moderate
... (warnings as systems stress)
18. [CRITICAL] - Temperature approaching thermal limit
19. [THROTTLE_CPU] - Throttle CPU to reduce heat
20. [CRITICAL] - Network congestion detected
21. [CRITICAL] - Power efficiency: Wasteful
... (critical conditions escalating)
25. [EMERGENCY] - Thermal emergency
26. [COOLING_ACTIVATE] - Activate emergency cooling
27. [THROTTLE_CPU] - Force CPU throttling
28. [EMERGENCY] - Network capacity exceeded
29. [LOAD_BALANCER] - Activate load balancer
30. [EMERGENCY] - System failure imminent
31. [CACHE_FLUSH] - Emergency cache flush
32. [THROTTLE_CPU] - Throttle workload immediately
```

## Variable Threshold Matching

The example demonstrates **adaptive threshold precision** based on criticality:

| State | Criticality | Typical Threshold | Precision |
|-------|-------------|-------------------|-----------|
| Initial/Normal | Low | ±0.15 to ±0.25 | Loose (wide tolerance) |
| Warning | Medium | ±0.10 to ±0.15 | Moderate |
| Critical | High | ±0.06 to ±0.08 | Tight (narrow tolerance) |
| Emergency | Extreme | ±0.02 to ±0.05 | Very tight (precise) |

**Rationale:**
- **Normal states** use loose thresholds → tolerate normal fluctuations
- **Critical states** use tight thresholds → detect precise conditions
- **Emergency states** use very tight thresholds → trigger only on exact conditions

## Advanced Features Demonstrated

### 1. Non-Binary Continuous Input Vectors

Unlike binary examples (RS Flip Flop: [0,0], [1,0], [0,1]), this example uses:
- Continuous sensor readings (0.25, 0.48, 0.72, etc.)
- Realistic data center metrics
- Normalized values representing physical measurements

### 2. Variable Threshold Matching

Thresholds adapt based on state:
- Wide tolerance for normal operations
- Narrow tolerance for critical detection
- Prevents false positives at low criticality
- Ensures precision at high criticality

### 3. Multi-Dimensional Dependencies

**Temperature correlates with Load:**
- Both must increase together for thermal sequence
- High temp alone ≠ thermal emergency
- High load alone ≠ thermal emergency
- High temp + High load = thermal emergency

**Storage correlates with Disk I/O:**
- High storage + High I/O = Deduplication opportunity
- High storage + Low I/O = Normal growth
- Low storage + High I/O = Active workload

**Memory correlates with CPU and Disk I/O:**
- High memory + High disk I/O = Paging/thrashing
- High memory + Low disk I/O = Cached workload
- Demonstrates three-way correlation

### 4. Complex Pattern Detection

**Power Efficiency = Power / Load Ratio:**
- Monitors relationship between two dimensions
- Detects inefficiency (power doesn't match load)
- Not a simple threshold—requires ratio analysis

### 5. Correlated Failure Sequences

**Cascading Memory Failure:**
- Memory pressure → Cache misses → Disk paging → CPU wait states
- One failure triggers subsequent failures
- Demonstrates realistic infrastructure cascading failures

### 6. Multiple Outputs Per Critical Event

**Thermal Emergency generates 3 outputs:**
1. `[EMERGENCY]` - Alert
2. `[COOLING_ACTIVATE]` - Physical action
3. `[THROTTLE_CPU]` - Software action

Demonstrates coordinated multi-system response to critical events.

## Using the Data Center Monitoring Example

### Loading the Example

1. **Via UI:**
   - Open the Reality Engine visualizer
   - Click on **"Data Center Monitoring"** card
   - Click **"Load Example"** button

2. **Via API:**
   ```typescript
   import { api } from './api';

   const result = await api.loadDataCenterExample();
   console.log('Data Center loaded:', result.metadata);
   ```

3. **Via Store:**
   ```typescript
   import { useVisualizerStore } from './store';

   const { loadDataCenterExample } = useVisualizerStore();
   await loadDataCenterExample();
   ```

### Running the Gradual Degradation Scenario

1. Load the Data Center Monitoring machine
2. Click **"Load Input Vectors"** on the SIMULATION tab
3. Select **"Gradual Degradation Scenario"** (12 vectors)
4. Click **"Start"** to auto-play or **"Step"** to advance manually
5. Watch the output stream accumulate as multiple sequences trigger

### Interpreting the Visualization

**Graph View:**
- 5 separate sequence graphs (one per monitoring system)
- Each sequence has 5 states (initial → emergency)
- Active states highlighted as inputs match
- ⚡ OUTPUT indicator when final events reached

**Output Stream:**
- Multiple outputs appear simultaneously during critical events
- Outputs from different sequences interleaved
- Timestamp shows when each output was generated
- Newest outputs at top (CURRENT), older ones scroll down (HISTORY)

### Random Input Testing

Click **"Random Input"** to generate a random 8D sensor vector:
- Each dimension randomly selected within operating ranges
- May trigger multiple sequences if values correlated
- Demonstrates real-time monitoring behavior

## Educational Value

### Why This Example is Important

1. **Real-World Applicability:**
   - Models actual data center monitoring scenarios
   - Uses realistic sensor data and failure patterns
   - Demonstrates practical infrastructure monitoring

2. **Advanced Concepts:**
   - Multi-dimensional pattern matching
   - Correlated event detection
   - Cascading failure analysis
   - Adaptive threshold precision

3. **Complexity Without Confusion:**
   - 8D input space (realistic but manageable)
   - 5 sequences (complex but not overwhelming)
   - Clear progression from normal to emergency
   - Intuitive physical interpretations

4. **Demonstrates Full Engine Capabilities:**
   - Non-binary continuous vectors
   - Variable threshold matching
   - Multi-dimensional dependencies
   - Complex pattern detection
   - Correlated sequences
   - Multiple simultaneous outputs

## Comparison with Other Examples

| Example | Input Dims | Sequences | Complexity | Use Case |
|---------|-----------|-----------|------------|----------|
| RS Flip Flop | 2D binary | 2 | Beginner | Learning basics |
| Multi-Step | 3D binary | 2 | Intermediate | Multi-step workflows |
| Kleene Star | Variable | 1 | Advanced | Pattern repetition |
| **Data Center** | **8D continuous** | **5** | **Advanced** | **Real-world monitoring** |

**Why Data Center is Most Advanced:**
- Highest dimensional input space (8D vs 2-3D)
- Non-binary continuous values (vs binary 0/1)
- Most sequences running simultaneously (5 vs 1-2)
- Multi-dimensional correlations
- Variable threshold precision
- Correlated cascading failures

## Implementation Files

### Core Implementation
- **Sequences:** `src/examples/data-center-monitoring/data-center-sequences.ts`
  - `createThermalOverloadSequence()` - Temp/load correlation
  - `createNetworkSurgeSequence()` - Traffic surge detection
  - `createPowerEfficiencySequence()` - Power/load ratio monitoring
  - `createStorageDedupSequence()` - Storage/IO correlation
  - `createMemoryCacheFailureSequence()` - Cascading memory failure
  - `generateComplexTestVectors()` - 12-step gradual degradation scenario
  - `createDataCenterMachine()` - Machine configuration

### Backend Integration
- **API Routes:** `src/api/routes.ts`
  - Auto-loads Data Center machine on startup
  - Endpoint: `/api/demo/data-center`

### Frontend Integration
- **API Client:** `visualizer/frontend/src/api.ts`
  - `loadDataCenterExample()` method

- **State Management:** `visualizer/frontend/src/store.ts`
  - `loadDataCenterExample()` action

### Visualizer Backend
- **Proxy Server:** `visualizer/backend/src/server.ts`
  - Proxy endpoint: `/api/demo/data-center`
  - Mock machine entry: `data-center-example`

## Technical Specifications

### ComparatorType Usage

| Type | Usage | Example |
|------|-------|---------|
| THRESHOLD | Fuzzy matching with tolerance | CPU_TEMP: 0.81 ±0.07 |
| PATTERN | Wildcard (match any value) | Dimensions not being monitored |
| EQUALS | Exact matching | (Not used in this example) |
| CUSTOM | Custom comparator logic | (Not used in this example) |

### Threshold Precision Strategy

```typescript
// Normal state: Wide tolerance
{ value: 0.25, threshold: 0.15 }  // Matches 0.10-0.40

// Warning state: Moderate tolerance
{ value: 0.50, threshold: 0.12 }  // Matches 0.38-0.62

// Critical state: Tight tolerance
{ value: 0.81, threshold: 0.07 }  // Matches 0.74-0.88

// Emergency state: Very tight tolerance
{ value: 0.91, threshold: 0.05 }  // Matches 0.86-0.96
```

## Version History

| Version | Date | Changes |
|---------|------|---------|
| 2.0.0 | 2026-01-17 | Complete rewrite with complex relationships, multi-dimensional dependencies, variable thresholds |
| 1.0.0 | Previous | Original simple 5-sequence implementation |

---

**Ready to Use:** ✅ Fully integrated into deployed application
**Difficulty:** Advanced
**Recommended For:** Understanding complex critical event sequences, multi-dimensional pattern matching, and real-world infrastructure monitoring

This example represents the **most sophisticated demonstration** of the Reality Engine's capabilities for handling complex, real-world critical event sequence detection with correlated multi-dimensional sensor data.
