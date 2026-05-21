# Reality Engine Visualizer — User Guide

## Overview

The Visualizer provides a web interface for running, observing, and managing CriticalEventSequence machines. It consists of four views accessible from **https://localhost:5173**.

---

## Views

### 1. Machine Selection (default)

The machine library. Lists all registered machines with their sequence count and metadata.

**Actions:**
- **Search** — filter by name in real time
- **Filter tabs** — All / Examples / Custom
- **+ New Machine** — opens the create dialog
- **Machine card** — click to open Administration view; use the ⋯ menu for Edit / Delete / Export
- **Load from JSON** — appears in the toolbar; loads a machine definition from `examples/machines/`
- **🔮 Tobias** button — switches to the Tobias canvas view

### 2. Machine Administration

Full-screen CES graph for a single machine. Connected to the visualizer backend WebSocket so node activation state updates in real time as simulation steps arrive.

**Graph elements:**
- **Blue node** — `isInitial` vector (always active, permanent entry point)
- **Amber node** — vector that fired (`wasJustMatched`) on the last step
- **Cyan node** — vector currently active / pending activation
- **Dark node** — intermediate / inactive vector
- **Ring outline** — terminal vector (has `outputVectors`)

**Header controls:**
- ← Back — return to Machine Selection
- Slide-out legend — hover the right edge

### 3. Machine Interconnection

Directed graph showing all machines and the perceptual space region edges between them. An edge from machine A → machine B indicates that A's output region overlaps B's input region, meaning A's output is visible to B on the next step.

### 4. Tobias (Canvas 2D)

Primary simulation control view. Shows all registered machines as a force-directed canvas graph. Each machine card contains a miniature rendering of its CES sequences with live node activation colouring.

**Layout:**
```
┌──────────────────────────────────────────────────────────────────┐
│ ← Back   🔮 Tobias   step N      [⏭ Step]   M/N machines        │  ← Header
├────────┬─┬─────────────────────────────────────────────────────────┤
│Sidebar │g│  PerceptualSpaceBar (dynamic perceptual-space heatmap)   │  ← Input bar
│        │u│─────────────────────────────────────────────────────────│
│▶ ⏭ ↺  │t│  TobiasCanvas (force-directed machine cards)            │  ← Canvas
│⏭ Single│t│                                                          │
│  Step  │e│─────────────────────────────────────────────────────────│
│📑 Seqs │r│  OutputHistoryBar (▲ expand for step history table)     │  ← Output bar
│↻ Refresh│ │                                                          │
│Filter  │ │                                                          │
└────────┴─┴──────────────────────────────────────────────────────────┘
```

#### Simulation Controls (sidebar)

| Control | Action |
|---|---|
| **▶ Play** | Start Perception Engine auto-push (600 ms interval) |
| **⏸ Pause** | Stop auto-push |
| **⏭** (icon) | Push one vector |
| **↺** | Reset Perception Engine step counter and Reality Engine simulation state |
| **⏭ Single Step** | Full-width labeled button; push one vector immediately |

#### Perceptual Engine section (sidebar)

- **📑 Sequences** — opens the Sequences panel (input sequence builder + output history table)
- **↻ Refresh Machines** — re-fetches machine list from the Reality Engine

#### Machine Filter (sidebar)

Toggle between **All / Idle / Processing / Active** to reduce canvas clutter.

#### PerceptualSpaceBar

Heatmap strip at the top of the canvas area. Each perceptual position is rendered as a compact cell; brightness shows the current value. Color-coded by machine input region. Region boundaries are marked with faint white lines.

#### OutputHistoryBar

Collapsed (default): one row per machine showing the latest output as coloured dots.
Expanded (click ▲): scrolling step-history table — machines as rows, steps as columns.

---

## Sequences Panel

Opened via **📑 Sequences** in the Tobias sidebar.

### Input Stream tab

Build and commit an input vector sequence to the Reality Engine's configured simulator:

1. Choose a **source machine** (determines the input region offset and length)
2. Set **step count** and **pattern** (sine-wave, square-wave, random, etc.)
3. Click **Generate & Configure** — sends the sequence to the RE and sets up a 3-byte input region for the selected machine
4. Step through manually or use Play in the main sidebar

### Output Streams tab

Table of every step in the `useMachineSimulation` hook's history (max 24 steps), showing each machine's output vector as coloured dots.

---

## Perception Engine UI (https://localhost:3005)

Separate frontend for managing Perception Engine sources. Use this to:
- Add / edit / remove sources (test sequences, simulated waveforms, sensors)
- Monitor the assembled perceptual vector preview in real time
- Start / stop / step the auto-push from the PE's own controls

Changes to sources are persisted to disk and survive container restarts.

---

## Keyboard Shortcuts

No keyboard shortcuts are currently defined. All controls are mouse/pointer driven.

---

## WebSocket Updates

The Tobias view maintains a WebSocket connection to `wss://localhost:3001/ws`. Steps pushed by the Perception Engine (auto or manual) arrive as `perceptual-simulation-stepped` messages and are applied to the canvas immediately without polling.

The Administration view also connects to this WebSocket so that node activation highlights update in real time during a running simulation.
