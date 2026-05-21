# Machine JSON Format Specification

**Version**: 1.0.0
**Date**: 2026-02-02
**Purpose**: Standardized format for machine definitions enabling sharing, editing, and persistence

---

## Overview

The Machine JSON format provides a complete, serializable representation of a Reality Engine machine. This format enables:

- **Shareability**: Machines can be exported and imported between different Reality Engine instances
- **Editability**: JSON files can be manually edited to modify machine behavior
- **Persistence**: Machines are stored as files and loaded on initialization
- **Version Control**: Machine definitions can be tracked in git
- **Portability**: Universal format independent of implementation

---

## JSON Schema

```json
{
  "version": "1.0.0",
  "machine": {
    "name": "Machine Name",
    "description": "Machine description",
    "metadata": {
      "category": "digital-logic",
      "author": "Author Name",
      "created": "2026-02-02T00:00:00Z",
      "modified": "2026-02-02T00:00:00Z",
      "tags": ["digital-logic", "flip-flop", "startup-loadable"],
      "tagging": {
        "schemaVersion": "1.0.0",
        "managedBy": "scripts/manage_machine_tags.mjs",
        "primaryDomain": "digital-logic",
        "domainTags": ["digital-logic"],
        "family": "rs2",
        "machineCode": "rs2",
        "capabilityTags": [],
        "workflowTags": ["flip-flop"],
        "integrationTags": [],
        "validationTags": ["startup-loadable"],
        "allTags": ["digital-logic", "flip-flop", "rs2", "startup-loadable"]
      },
      "eventSpace": "Description of event space",
      "outputSpace": "Description of output space",
      "customField": "Any custom metadata"
    },
    "arbiterRule": "PASSTHROUGH",
    "perceptualMapping": {
      "input": {
        "offset": 0,
        "length": 2
      },
      "output": {
        "offset": 2,
        "length": 2
      }
    },
    "sequences": [
      {
        "id": "seq-uuid",
        "name": "Sequence Name",
        "metadata": {
          "description": "Sequence description",
          "customField": "Any custom metadata"
        },
        "vectors": [
          {
            "id": "vec-uuid",
            "elements": [
              {
                "value": 0.0,
                "comparatorType": "equals",
                "threshold": 0.05
              }
            ],
            "isInitial": true,
            "metadata": {
              "name": "00",
              "description": "Vector description",
              "state": "HOLD"
            },
            "nextVectorIds": ["vec-uuid-2"],
            "outputVectors": [
              {
                "id": "output-uuid",
                "vector": [1, 0],
                "metadata": {
                  "description": "Output description",
                  "state": "SET"
                }
              }
            ]
          }
        ]
      }
    ],
    "inputSequences": [
      {
        "name": "Test Sequence",
        "pattern": "00→10→01",
        "description": "Description of what this sequence tests",
        "vectors": [
          [0, 0],
          [1, 0],
          [0, 1]
        ],
        "metadata": {
          "expectedOutputs": 2,
          "validationType": "comprehensive"
        }
      }
    ]
  }
}
```

---

## Field Descriptions

### Root Level

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `version` | string | Yes | Format version (semver) |
| `machine` | object | Yes | Machine definition |

### Machine Object

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `name` | string | Yes | Machine name |
| `description` | string | Yes | Brief description |
| `metadata` | object | No | Custom metadata |
| `arbiterRule` | string | Yes | Output arbiter rule (PASSTHROUGH, FIRST, LAST, MAJORITY) |
| `perceptualMapping` | object | No | Perceptual space mappings |
| `sequences` | array | Yes | Critical event sequences |
| `inputSequences` | array | No | Test input sequences |

### Metadata Object

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `category` | string | No | Machine category |
| `author` | string | No | Author name |
| `created` | string | No | ISO 8601 timestamp |
| `modified` | string | No | ISO 8601 timestamp |
| `tags` | array | No | Backwards-compatible flattened tag search index |
| `tagging` | object | No | Managed structured tag groups; see `MACHINE_TAGGING.md` |
| `eventSpace` | string | No | Event space description |
| `outputSpace` | string | No | Output space description |

### Perceptual Mapping Object

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `input` | object | Yes | Input mapping |
| `input.offset` | number | Yes | Offset in En |
| `input.length` | number | Yes | Length of input |
| `output` | object | Yes | Output mapping |
| `output.offset` | number | Yes | Offset in En |
| `output.length` | number | Yes | Length of output |

### Sequence Object

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `id` | string | No | Unique identifier (auto-generated if missing) |
| `name` | string | Yes | Sequence name |
| `metadata` | object | No | Custom metadata |
| `vectors` | array | Yes | Reality vectors in sequence |

### Vector Object

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `id` | string | No | Unique identifier (auto-generated if missing) |
| `elements` | array | Yes | Vector elements |
| `isInitial` | boolean | Yes | Is this an initial vector? |
| `metadata` | object | No | Custom metadata |
| `nextVectorIds` | array | No | IDs of successor vectors |
| `outputVectors` | array | No | Output vectors to assert |

### Element Object

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `value` | number | Yes | Element value |
| `comparatorType` | string | Yes | Comparator type (equals, threshold, pattern, custom) |
| `threshold` | number | No | Threshold for comparator |

### Output Vector Object

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `id` | string | No | Unique identifier |
| `vector` | array | Yes | Output vector values |
| `metadata` | object | No | Custom metadata |

### Input Sequence Object

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `name` | string | Yes | Sequence name |
| `pattern` | string | No | Pattern description |
| `description` | string | Yes | What this sequence tests |
| `vectors` | array | Yes | Array of input vectors |
| `metadata` | object | No | Custom metadata |

---

## Comparator Types

| Type | Description | Parameters |
|------|-------------|------------|
| `equals` | Exact equality | threshold (tolerance) |
| `threshold` | Within threshold | threshold (required) |
| `pattern` | Pattern matching | threshold (similarity) |
| `custom` | Custom comparator | Implementation-specific |

---

## Arbiter Rules

| Rule | Description |
|------|-------------|
| `PASSTHROUGH` | Pass through all outputs (default) |
| `AND` | Output only if ALL sequences produce output |
| `OR` | Output if at least ONE sequence produces output |

---

## Example: RS2 Machine

```json
{
  "version": "1.0.0",
  "machine": {
    "name": "RS2",
    "description": "Two-step RS flip-flop with hold state",
    "metadata": {
      "category": "digital-logic",
      "author": "Reality Engine",
      "created": "2026-02-02T00:00:00Z",
      "eventSpace": "2D binary vectors: [S, R] inputs",
      "outputSpace": "2D binary: {[1,0]=SET, [0,1]=RESET}",
      "tags": ["flip-flop", "digital-logic", "two-step"]
    },
    "arbiterRule": "PASSTHROUGH",
    "perceptualMapping": {
      "input": { "offset": 4, "length": 2 },
      "output": { "offset": 8, "length": 2 }
    },
    "sequences": [
      {
        "name": "SET Sequence",
        "metadata": {
          "description": "Hold state followed by SET input"
        },
        "vectors": [
          {
            "elements": [
              { "value": 0, "comparatorType": "equals", "threshold": 0.05 },
              { "value": 0, "comparatorType": "equals", "threshold": 0.05 }
            ],
            "isInitial": true,
            "metadata": { "name": "00", "state": "HOLD" },
            "nextVectorIds": ["set-10"]
          },
          {
            "id": "set-10",
            "elements": [
              { "value": 1, "comparatorType": "equals", "threshold": 0.05 },
              { "value": 0, "comparatorType": "equals", "threshold": 0.05 }
            ],
            "isInitial": false,
            "metadata": { "name": "10", "state": "SET" },
            "outputVectors": [
              {
                "vector": [1, 0],
                "metadata": {
                  "description": "RS2 SET to HIGH",
                  "state": "SET"
                }
              }
            ]
          }
        ]
      }
    ],
    "inputSequences": [
      {
        "name": "Complete Test Sequence",
        "pattern": "(0,0)→(1,0)→(0,0)→(0,1)",
        "description": "Tests SET and RESET operations",
        "vectors": [
          [0, 0],
          [1, 0],
          [0, 0],
          [0, 1]
        ],
        "metadata": {
          "expectedOutputs": 2
        }
      }
    ]
  }
}
```

---

## Usage

### Loading a Machine

```typescript
import { loadMachineFromJSON } from './services/MachineLoader';

const machineJson = await readFile('examples/RS2.json', 'utf8');
const machine = loadMachineFromJSON(machineJson);
```

### Saving a Machine

```typescript
import { saveMachineToJSON } from './services/MachineLoader';

const json = saveMachineToJSON(machine);
await writeFile('examples/MyMachine.json', json, 'utf8');
```

### Editing a Machine

1. Export machine to JSON file
2. Edit JSON file in text editor
3. Validate JSON against schema
4. Import modified JSON
5. Test machine behavior

---

## Validation Rules

1. **Version**: Must be valid semver string
2. **IDs**: Auto-generated if not provided, must be unique within machine
3. **References**: nextVectorIds must reference valid vector IDs in same sequence
4. **Dimensions**: All vectors in a sequence must have same dimension
5. **Comparators**: comparatorType must be valid enum value
6. **Arbiter**: arbiterRule must be valid enum value

---

## File Naming Convention

- Format: `<MachineName>.json`
- Location: `examples/<machine-name>/<MachineName>.json`
- Example: `examples/rs2/RS2.json`
- Lowercase folder names, PascalCase file names

---

## Backwards Compatibility

When the JSON format version changes:
- Major version: Breaking changes, may require manual migration
- Minor version: New fields added, backwards compatible
- Patch version: Bug fixes, fully compatible

The loader should support all minor versions within the same major version.

---

**Status**: ✅ Specification Complete
**Version**: 1.0.0
**Last Updated**: 2026-02-02
