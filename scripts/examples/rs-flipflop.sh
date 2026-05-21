#!/bin/bash

# RS Flip-Flop Example
# Creates a complete RS (Reset-Set) flip-flop using Critical Event Sequences
#
# An RS flip-flop is a bistable multivibrator with two inputs:
# - S (Set): When high (1), sets Q to 1
# - R (Reset): When high (1), resets Q to 0
# - Both low (0,0): Holds current state
# - Both high (1,1): Invalid/undefined state
#
# States:
# - SET: Q=1, Q'=0 (when S=1, R=0)
# - RESET: Q=0, Q'=1 (when R=1, S=0)
# - HOLD: Maintains previous state (when S=0, R=0)
# - INVALID: Undefined (when S=1, R=1)

PORT=${PORT:-3000}
API_URL="http://localhost:$PORT/api"

echo "=================================================="
echo "RS Flip-Flop Example"
echo "=================================================="
echo ""
echo "Creating an RS flip-flop using Critical Event Sequences"
echo ""

# Color codes
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_success() {
    echo -e "${GREEN}✓${NC} $1"
}

print_info() {
    echo -e "${BLUE}ℹ${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}⚠${NC} $1"
}

# Create RS Flip-Flop Sequence
print_info "Creating RS Flip-Flop sequence..."
echo ""

SEQUENCE_RESPONSE=$(curl -s -X POST $API_URL/sequences \
  -H "Content-Type: application/json" \
  -d '{
    "name": "RS Flip-Flop",
    "metadata": {
      "type": "sequential-logic",
      "component": "rs-flipflop",
      "description": "Reset-Set flip-flop with Q and Q-bar outputs",
      "inputs": ["S", "R"],
      "outputs": ["Q", "Q_bar"],
      "states": ["SET", "RESET", "HOLD", "INVALID"]
    },
    "vectors": [
      {
        "id": "reset-state",
        "elements": [
          {"value": 0.0, "comparatorType": "equals", "name": "S"},
          {"value": 1.0, "comparatorType": "equals", "name": "R"}
        ],
        "isInitial": true,
        "isActive": false,
        "nextVectorIds": ["reset-state", "set-state", "hold-from-reset", "invalid-state"],
        "outputVectors": [
          {
            "id": "reset-output",
            "vector": [0.0, 1.0],
            "timestamp": '$(date +%s000)',
            "metadata": {
              "description": "RESET state: Q=0, Q_bar=1",
              "state": "RESET",
              "Q": 0,
              "Q_bar": 1
            }
          }
        ],
        "metadata": {
          "name": "RESET State",
          "description": "R=1, S=0: Output Q=0, Q_bar=1",
          "stateName": "RESET",
          "color": "#ef4444"
        }
      },
      {
        "id": "set-state",
        "elements": [
          {"value": 1.0, "comparatorType": "equals", "name": "S"},
          {"value": 0.0, "comparatorType": "equals", "name": "R"}
        ],
        "isInitial": true,
        "isActive": false,
        "nextVectorIds": ["reset-state", "set-state", "hold-from-set", "invalid-state"],
        "outputVectors": [
          {
            "id": "set-output",
            "vector": [1.0, 0.0],
            "timestamp": '$(date +%s000)',
            "metadata": {
              "description": "SET state: Q=1, Q_bar=0",
              "state": "SET",
              "Q": 1,
              "Q_bar": 0
            }
          }
        ],
        "metadata": {
          "name": "SET State",
          "description": "S=1, R=0: Output Q=1, Q_bar=0",
          "stateName": "SET",
          "color": "#22c55e"
        }
      },
      {
        "id": "hold-from-reset",
        "elements": [
          {"value": 0.0, "comparatorType": "equals", "name": "S"},
          {"value": 0.0, "comparatorType": "equals", "name": "R"}
        ],
        "isInitial": false,
        "isActive": false,
        "nextVectorIds": ["reset-state", "set-state", "hold-from-reset", "invalid-state"],
        "outputVectors": [
          {
            "id": "hold-reset-output",
            "vector": [0.0, 1.0],
            "timestamp": '$(date +%s000)',
            "metadata": {
              "description": "HOLD from RESET: Q=0, Q_bar=1",
              "state": "HOLD_RESET",
              "Q": 0,
              "Q_bar": 1,
              "previousState": "RESET"
            }
          }
        ],
        "metadata": {
          "name": "HOLD from RESET",
          "description": "S=0, R=0: Maintain RESET state (Q=0, Q_bar=1)",
          "stateName": "HOLD",
          "previousState": "RESET",
          "color": "#3b82f6"
        }
      },
      {
        "id": "hold-from-set",
        "elements": [
          {"value": 0.0, "comparatorType": "equals", "name": "S"},
          {"value": 0.0, "comparatorType": "equals", "name": "R"}
        ],
        "isInitial": false,
        "isActive": false,
        "nextVectorIds": ["reset-state", "set-state", "hold-from-set", "invalid-state"],
        "outputVectors": [
          {
            "id": "hold-set-output",
            "vector": [1.0, 0.0],
            "timestamp": '$(date +%s000)',
            "metadata": {
              "description": "HOLD from SET: Q=1, Q_bar=0",
              "state": "HOLD_SET",
              "Q": 1,
              "Q_bar": 0,
              "previousState": "SET"
            }
          }
        ],
        "metadata": {
          "name": "HOLD from SET",
          "description": "S=0, R=0: Maintain SET state (Q=1, Q_bar=0)",
          "stateName": "HOLD",
          "previousState": "SET",
          "color": "#3b82f6"
        }
      },
      {
        "id": "invalid-state",
        "elements": [
          {"value": 1.0, "comparatorType": "equals", "name": "S"},
          {"value": 1.0, "comparatorType": "equals", "name": "R"}
        ],
        "isInitial": false,
        "isActive": false,
        "nextVectorIds": ["reset-state", "set-state", "invalid-state"],
        "outputVectors": [
          {
            "id": "invalid-output",
            "vector": [1.0, 1.0],
            "timestamp": '$(date +%s000)',
            "metadata": {
              "description": "INVALID state: S=1, R=1 (undefined behavior)",
              "state": "INVALID",
              "Q": 1,
              "Q_bar": 1,
              "error": "Both S and R are high - invalid state"
            }
          }
        ],
        "metadata": {
          "name": "INVALID State",
          "description": "S=1, R=1: Invalid/undefined state",
          "stateName": "INVALID",
          "color": "#f59e0b",
          "warning": "This state should be avoided in practice"
        }
      }
    ]
  }')

if [ $? -eq 0 ]; then
    SEQUENCE_ID=$(echo $SEQUENCE_RESPONSE | grep -o '"sequenceId":"[^"]*"' | cut -d'"' -f4)
    print_success "RS Flip-Flop sequence created successfully"
    echo "  Sequence ID: $SEQUENCE_ID"
    echo ""
else
    print_warning "Failed to create sequence"
    exit 1
fi

# Create a machine that uses the RS flip-flop
print_info "Creating RS Flip-Flop Machine..."
echo ""

MACHINE_RESPONSE=$(curl -s -X POST $API_URL/machines \
  -H "Content-Type: application/json" \
  -d '{
    "name": "RS Flip-Flop Circuit",
    "description": "A single RS flip-flop implementation demonstrating bistable memory",
    "sequenceIds": ["'$SEQUENCE_ID'"],
    "metadata": {
      "type": "digital-logic",
      "component": "flip-flop",
      "variant": "RS",
      "inputDimension": 2,
      "outputDimension": 2,
      "truthTable": {
        "SR_00": "HOLD (maintain previous state)",
        "SR_01": "RESET (Q=0, Q_bar=1)",
        "SR_10": "SET (Q=1, Q_bar=0)",
        "SR_11": "INVALID (undefined)"
      }
    }
  }')

if [ $? -eq 0 ]; then
    MACHINE_ID=$(echo $MACHINE_RESPONSE | grep -o '"id":"[^"]*"' | cut -d'"' -f4)
    print_success "RS Flip-Flop machine created successfully"
    echo "  Machine ID: $MACHINE_ID"
    echo ""
else
    print_warning "Failed to create machine"
fi

echo ""
echo "=================================================="
echo "RS Flip-Flop Setup Complete!"
echo "=================================================="
echo ""
echo "Test the flip-flop with these input vectors:"
echo ""
echo "  RESET:   [0, 1]  # S=0, R=1 → Q=0, Q'=1"
echo "  SET:     [1, 0]  # S=1, R=0 → Q=1, Q'=0"
echo "  HOLD:    [0, 0]  # S=0, R=0 → Maintains state"
echo "  INVALID: [1, 1]  # S=1, R=1 → Undefined"
echo ""
echo "Example sequence:"
echo "  1. Start with RESET: [0, 1] → Output: [0, 1]"
echo "  2. HOLD:            [0, 0] → Output: [0, 1] (maintains RESET)"
echo "  3. SET:             [1, 0] → Output: [1, 0]"
echo "  4. HOLD:            [0, 0] → Output: [1, 0] (maintains SET)"
echo "  5. RESET:           [0, 1] → Output: [0, 1]"
echo ""
echo "Test with:"
echo "  curl -X POST $API_URL/sequences/$SEQUENCE_ID/transition \\"
echo "    -H 'Content-Type: application/json' \\"
echo "    -d '{\"vector\": [0, 1]}'"
echo ""
echo "View in visualizer:"
echo "  http://localhost:5173"
echo ""
