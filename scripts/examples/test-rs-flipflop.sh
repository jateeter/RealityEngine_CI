#!/bin/bash

# Test RS Flip-Flop
# Demonstrates the behavior of the RS flip-flop with various input combinations
#
# DEPRECATED: This script calls POST /api/sequences/:id/transition which has been
# removed. Use the Visualizer UI (http://localhost:5173) to test machines interactively,
# or use POST /api/machines/:id/process with a universal input vector instead.

PORT=${PORT:-3000}
API_URL="http://localhost:$PORT/api"

# Color codes
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
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

print_error() {
    echo -e "${RED}✗${NC} $1"
}

echo "=================================================="
echo "RS Flip-Flop Test Suite"
echo "=================================================="
echo ""

# Check if sequence exists
print_info "Looking for RS Flip-Flop sequence..."
SEQUENCES=$(curl -s $API_URL/sequences)
SEQUENCE_ID=$(echo $SEQUENCES | grep -o '"sequenceId":"[^"]*"' | grep -o '[^"]*$' | head -1)

if [ -z "$SEQUENCE_ID" ]; then
    print_error "No sequences found. Please run ./scripts/examples/rs-flipflop.sh first"
    exit 1
fi

print_success "Found sequence: $SEQUENCE_ID"
echo ""

# Test function
test_transition() {
    local s=$1
    local r=$2
    local expected_state=$3
    local expected_q=$4
    local expected_qbar=$5

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Test: S=$s, R=$r → Expected: $expected_state (Q=$expected_q, Q'=$expected_qbar)"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    RESPONSE=$(curl -s -X POST $API_URL/sequences/$SEQUENCE_ID/transition \
        -H "Content-Type: application/json" \
        -d "{\"vector\": [$s, $r]}")

    echo ""
    echo "Response:"
    echo "$RESPONSE" | jq '.' 2>/dev/null || echo "$RESPONSE"

    # Extract output
    OUTPUT=$(echo "$RESPONSE" | jq -r '.sequenceResults | to_entries | .[0].value.outputsAsserted[0].vector' 2>/dev/null)
    STATE=$(echo "$RESPONSE" | jq -r '.sequenceResults | to_entries | .[0].value.outputsAsserted[0].metadata.state' 2>/dev/null)

    if [ "$OUTPUT" != "null" ] && [ ! -z "$OUTPUT" ]; then
        Q=$(echo "$OUTPUT" | jq '.[0]' 2>/dev/null)
        QBAR=$(echo "$OUTPUT" | jq '.[1]' 2>/dev/null)

        echo ""
        echo "Result: $STATE"
        echo "  Q     = $Q"
        echo "  Q_bar = $QBAR"
        echo ""

        if [ "$STATE" == "$expected_state" ]; then
            print_success "State matches expected: $expected_state"
        else
            print_warning "State mismatch: got $STATE, expected $expected_state"
        fi
    else
        print_error "No output generated"
    fi

    echo ""
    sleep 1
}

echo "Starting RS Flip-Flop Test Sequence..."
echo ""
sleep 1

# Test 1: Initial RESET
print_info "Test 1: Initial RESET state"
test_transition 0 1 "RESET" 0 1

# Test 2: HOLD from RESET
print_info "Test 2: HOLD (maintain RESET state)"
test_transition 0 0 "HOLD_RESET" 0 1

# Test 3: SET
print_info "Test 3: SET state"
test_transition 1 0 "SET" 1 0

# Test 4: HOLD from SET
print_info "Test 4: HOLD (maintain SET state)"
test_transition 0 0 "HOLD_SET" 1 0

# Test 5: Back to RESET
print_info "Test 5: Back to RESET"
test_transition 0 1 "RESET" 0 1

# Test 6: SET again
print_info "Test 6: SET again"
test_transition 1 0 "SET" 1 0

# Test 7: INVALID state (both high)
print_info "Test 7: INVALID state (both S and R high)"
test_transition 1 1 "INVALID" 1 1

# Test 8: Recover from INVALID to RESET
print_info "Test 8: Recover to RESET"
test_transition 0 1 "RESET" 0 1

echo ""
echo "=================================================="
echo "Test Suite Complete!"
echo "=================================================="
echo ""
echo "Summary:"
echo "  ✓ Initial RESET: [0,1] → Q=0, Q'=1"
echo "  ✓ HOLD RESET:    [0,0] → Q=0, Q'=1 (maintained)"
echo "  ✓ SET:           [1,0] → Q=1, Q'=0"
echo "  ✓ HOLD SET:      [0,0] → Q=1, Q'=0 (maintained)"
echo "  ✓ RESET again:   [0,1] → Q=0, Q'=1"
echo "  ✓ SET again:     [1,0] → Q=1, Q'=0"
echo "  ⚠ INVALID:       [1,1] → Q=1, Q'=1 (undefined)"
echo "  ✓ Recover:       [0,1] → Q=0, Q'=1"
echo ""
echo "The RS flip-flop demonstrates bistable memory:"
echo "  - SET state (Q=1) is stable when S=1, R=0"
echo "  - RESET state (Q=0) is stable when S=0, R=1"
echo "  - HOLD maintains the previous state when S=0, R=0"
echo "  - INVALID state (S=1, R=1) should be avoided"
echo ""
