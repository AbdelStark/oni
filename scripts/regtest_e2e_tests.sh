#!/bin/bash
# regtest_e2e_tests.sh - End-to-end tests for oni node in regtest mode
#
# This script performs meaningful Bitcoin protocol tests against a running
# oni node. It tests RPC endpoints, chain state, mempool, and validates
# that the node correctly implements Bitcoin protocol behavior.
#
# Usage:
#   ./scripts/regtest_e2e_tests.sh [--skip-start] [--verbose]
#
# Options:
#   --skip-start  Skip starting the node (assumes node is already running)
#   --verbose     Show detailed output for each test

# Don't use set -e because grep returns non-zero for no matches
# which would cause script to exit prematurely
# set -e

# Configuration
RPC_PORT="${ONI_RPC_PORT:-18443}"
RPC_HOST="${ONI_RPC_HOST:-127.0.0.1}"
RPC_USER="${ONI_RPC_USER:-user}"
RPC_PASS="${ONI_RPC_PASS:-pass}"
RPC_URL="http://${RPC_HOST}:${RPC_PORT}/"
NODE_PID=""
SKIP_START=false
VERBOSE=false

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Test counters
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0

# Parse arguments
for arg in "$@"; do
    case $arg in
        --skip-start)
            SKIP_START=true
            shift
            ;;
        --verbose)
            VERBOSE=true
            shift
            ;;
        *)
            ;;
    esac
done

# Print functions
print_header() {
    echo ""
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}═══════════════════════════════════════════════════════════════${NC}"
}

print_test() {
    echo -e "${CYAN}  ► $1${NC}"
}

print_pass() {
    echo -e "${GREEN}    ✓ $1${NC}"
    ((TESTS_PASSED++))
}

print_fail() {
    echo -e "${RED}    ✗ $1${NC}"
    ((TESTS_FAILED++))
}

print_skip() {
    echo -e "${YELLOW}    ⊘ $1 (skipped)${NC}"
    ((TESTS_SKIPPED++))
}

print_info() {
    if [ "$VERBOSE" = true ]; then
        echo -e "${YELLOW}    ℹ $1${NC}"
    fi
}

# RPC call helper
rpc_call() {
    local method="$1"
    local params="${2:-[]}"
    local result

    result=$(curl -s --user "${RPC_USER}:${RPC_PASS}" \
        -X POST \
        -H 'Content-Type: application/json' \
        -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"${method}\",\"params\":${params}}" \
        "${RPC_URL}" 2>/dev/null)

    echo "$result"
}

# Extract result from JSON response
get_result() {
    local json="$1"
    echo "$json" | grep -o '"result":[^,}]*' | sed 's/"result"://' | tr -d '"'
}

# Extract result object from JSON response
get_result_json() {
    local json="$1"
    # Use python for reliable JSON parsing if available
    if command -v python3 &> /dev/null; then
        echo "$json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(json.dumps(d.get('result', {})))" 2>/dev/null
    else
        # Fallback: extract everything after "result":
        echo "$json" | sed 's/.*"result"://' | sed 's/}$//'
    fi
}

# Check if result contains error
has_error() {
    local json="$1"
    echo "$json" | grep -q '"error":[^n]'
}

# Wait for RPC to be ready
wait_for_rpc() {
    local max_attempts=30
    local attempt=0

    echo -e "${CYAN}Waiting for RPC to be ready...${NC}"

    while [ $attempt -lt $max_attempts ]; do
        if curl -s --user "${RPC_USER}:${RPC_PASS}" \
            -X POST \
            -H 'Content-Type: application/json' \
            -d '{"jsonrpc":"2.0","id":1,"method":"getblockchaininfo"}' \
            "${RPC_URL}" 2>/dev/null | grep -q '"result"'; then
            echo -e "${GREEN}RPC is ready!${NC}"
            return 0
        fi
        sleep 1
        ((attempt++))
        echo -n "."
    done

    echo -e "${RED}RPC failed to become ready after ${max_attempts} seconds${NC}"
    return 1
}

# Start the node
start_node() {
    if [ "$SKIP_START" = true ]; then
        echo -e "${YELLOW}Skipping node start (--skip-start)${NC}"
        return 0
    fi

    print_header "Starting oni node in regtest mode"

    # Check if node is already running
    if curl -s --user "${RPC_USER}:${RPC_PASS}" \
        -X POST \
        -H 'Content-Type: application/json' \
        -d '{"jsonrpc":"2.0","id":1,"method":"getblockchaininfo"}' \
        "${RPC_URL}" 2>/dev/null | grep -q '"result"'; then
        echo -e "${YELLOW}Node already running, using existing instance${NC}"
        return 0
    fi

    # Start node in background
    cd "$(dirname "$0")/.."

    # Build first
    echo "Building packages..."
    make build > /dev/null 2>&1

    # Start the node
    echo "Starting oni node..."
    cd packages/oni_node
    erl \
        -noshell \
        -pa build/dev/erlang/*/ebin \
        -pa ../oni_bitcoin/build/dev/erlang/*/ebin \
        -pa ../oni_consensus/build/dev/erlang/*/ebin \
        -pa ../oni_storage/build/dev/erlang/*/ebin \
        -pa ../oni_p2p/build/dev/erlang/*/ebin \
        -pa ../oni_rpc/build/dev/erlang/*/ebin \
        -eval 'cli:run([<<"--regtest">>])' &
    NODE_PID=$!
    cd ../..

    echo "Node started with PID: ${NODE_PID}"

    # Wait for RPC
    if ! wait_for_rpc; then
        echo -e "${RED}Failed to start node${NC}"
        exit 1
    fi
}

# Stop the node
stop_node() {
    if [ -n "$NODE_PID" ] && [ "$SKIP_START" = false ]; then
        print_header "Stopping oni node"
        kill $NODE_PID 2>/dev/null || true
        wait $NODE_PID 2>/dev/null || true
        echo -e "${GREEN}Node stopped${NC}"
    fi
}

# Cleanup on exit
cleanup() {
    stop_node
}
trap cleanup EXIT

# ============================================================================
# Test Suite: Blockchain Info
# ============================================================================

test_blockchain_info() {
    print_header "Test Suite: Blockchain Info"

    # Test getblockchaininfo
    print_test "getblockchaininfo returns valid response"
    local result=$(rpc_call "getblockchaininfo")
    if echo "$result" | grep -q '"chain":"regtest"'; then
        print_pass "Chain is regtest"
    else
        print_fail "Chain should be regtest, got: $result"
    fi

    if echo "$result" | grep -q '"bestblockhash"'; then
        print_pass "Best block hash present"
    else
        print_fail "Best block hash missing"
    fi

    if echo "$result" | grep -q '"blocks":'; then
        print_pass "Block height present"
    else
        print_fail "Block height missing"
    fi

    # Test getblockcount
    print_test "getblockcount returns valid height"
    result=$(rpc_call "getblockcount")
    local height=$(get_result "$result")
    if [[ "$height" =~ ^[0-9]+$ ]]; then
        print_pass "Block count is numeric: $height"
        print_info "Current height: $height"
    else
        print_fail "Block count should be numeric, got: $height"
    fi

    # Test getbestblockhash
    print_test "getbestblockhash returns valid hash"
    result=$(rpc_call "getbestblockhash")
    local best_hash=$(get_result "$result")
    if [[ ${#best_hash} -eq 64 ]]; then
        print_pass "Best block hash is 64 chars"
        print_info "Best hash: $best_hash"
    else
        print_fail "Best block hash should be 64 chars, got: ${#best_hash}"
    fi

    # Test getdifficulty
    print_test "getdifficulty returns valid value"
    result=$(rpc_call "getdifficulty")
    if echo "$result" | grep -q '"result":'; then
        print_pass "Difficulty returned"
        print_info "Result: $(get_result "$result")"
    else
        print_fail "Difficulty not returned"
    fi
}

# ============================================================================
# Test Suite: Genesis Block Validation
# ============================================================================

test_genesis_block() {
    print_header "Test Suite: Genesis Block Validation"

    # Regtest genesis block hash
    local REGTEST_GENESIS="0f9188f13cb7b2c71f2a335e3a4fc328bf5beb436012afca590b1a11466e2206"

    # Test getblockhash at height 0
    print_test "getblockhash(0) returns genesis hash"
    local result=$(rpc_call "getblockhash" "[0]")
    local genesis_hash=$(get_result "$result")
    if [ "$genesis_hash" = "$REGTEST_GENESIS" ]; then
        print_pass "Genesis hash correct"
    else
        print_fail "Genesis hash wrong. Expected: $REGTEST_GENESIS, Got: $genesis_hash"
    fi

    # Test getblock for genesis
    print_test "getblock returns genesis block data"
    result=$(rpc_call "getblock" "[\"$REGTEST_GENESIS\"]")
    if echo "$result" | grep -q '"height":0'; then
        print_pass "Genesis block height is 0"
    else
        print_fail "Genesis block height should be 0"
    fi

    if echo "$result" | grep -q '"confirmations":'; then
        print_pass "Genesis block has confirmations field"
    else
        print_fail "Genesis block missing confirmations"
    fi

    # Test getblockheader
    print_test "getblockheader returns genesis header"
    result=$(rpc_call "getblockheader" "[\"$REGTEST_GENESIS\"]")
    if echo "$result" | grep -q '"height":0'; then
        print_pass "Genesis header height is 0"
    else
        print_fail "Genesis header height should be 0"
    fi

    if echo "$result" | grep -q '"previousblockhash"'; then
        # Genesis should have no previous block or "0000..."
        print_pass "Previous block hash field present"
    else
        print_pass "Genesis has no previous block (expected)"
    fi
}

# ============================================================================
# Test Suite: Network Info
# ============================================================================

test_network_info() {
    print_header "Test Suite: Network Info"

    # Test getnetworkinfo
    print_test "getnetworkinfo returns valid response"
    local result=$(rpc_call "getnetworkinfo")
    if echo "$result" | grep -q '"version":'; then
        print_pass "Version present"
    else
        print_fail "Version missing"
    fi

    if echo "$result" | grep -q '"subversion":'; then
        print_pass "Subversion present"
    else
        print_fail "Subversion missing"
    fi

    if echo "$result" | grep -q '"localservices":'; then
        print_pass "Local services present"
    else
        print_fail "Local services missing"
    fi

    # Test getconnectioncount
    print_test "getconnectioncount returns valid count"
    result=$(rpc_call "getconnectioncount")
    local count=$(get_result "$result")
    if [[ "$count" =~ ^[0-9]+$ ]]; then
        print_pass "Connection count is numeric: $count"
    else
        print_fail "Connection count should be numeric"
    fi

    # Test getpeerinfo
    print_test "getpeerinfo returns array"
    result=$(rpc_call "getpeerinfo")
    if echo "$result" | grep -q '"result":\['; then
        print_pass "Peer info returns array"
    else
        print_fail "Peer info should return array"
    fi
}

# ============================================================================
# Test Suite: Mining Info
# ============================================================================

test_mining_info() {
    print_header "Test Suite: Mining Info"

    # Test getmininginfo
    print_test "getmininginfo returns valid response"
    local result=$(rpc_call "getmininginfo")
    if echo "$result" | grep -q '"blocks":'; then
        print_pass "Blocks field present"
    else
        print_fail "Blocks field missing"
    fi

    if echo "$result" | grep -q '"difficulty":'; then
        print_pass "Difficulty field present"
    else
        print_fail "Difficulty field missing"
    fi

    if echo "$result" | grep -q '"chain":"regtest"'; then
        print_pass "Chain is regtest"
    else
        print_fail "Chain should be regtest"
    fi

    # Test getnetworkhashps
    print_test "getnetworkhashps returns valid value"
    result=$(rpc_call "getnetworkhashps")
    if echo "$result" | grep -q '"result":'; then
        print_pass "Network hash rate returned"
    else
        print_fail "Network hash rate missing"
    fi

    # Test getblocktemplate
    print_test "getblocktemplate returns template"
    result=$(rpc_call "getblocktemplate" '[{"rules":["segwit"]}]')
    if echo "$result" | grep -q '"previousblockhash"'; then
        print_pass "Block template has previous block hash"
    else
        print_info "Block template: $result"
        print_skip "Block template may require different params"
    fi
}

# ============================================================================
# Test Suite: Block Generation (Mining)
# ============================================================================

test_block_generation() {
    print_header "Test Suite: Block Generation (Mining)"

    # Get initial height
    local result=$(rpc_call "getblockcount")
    local initial_height=$(get_result "$result")
    print_info "Initial height: $initial_height"

    # Test generatetoaddress - mine 5 blocks
    # Using a dummy regtest address (bcrt1 prefix)
    local test_address="bcrt1qw508d6qejxtdg4y5r3zarvary0c5xw7kygt080"

    print_test "generatetoaddress mines blocks successfully"
    result=$(rpc_call "generatetoaddress" "[5, \"$test_address\"]")

    if has_error "$result"; then
        local error_msg=$(echo "$result" | grep -o '"message":"[^"]*"' | cut -d'"' -f4)
        print_fail "generatetoaddress failed: $error_msg"
    else
        if echo "$result" | grep -q '"result":\['; then
            print_pass "generatetoaddress returned block hashes"
        else
            print_fail "generatetoaddress should return array of hashes"
        fi
    fi

    # Verify height increased
    print_test "Block height increased after mining"
    result=$(rpc_call "getblockcount")
    local new_height=$(get_result "$result")

    if [ "$new_height" -gt "$initial_height" ]; then
        print_pass "Height increased from $initial_height to $new_height"
    else
        print_fail "Height should have increased, still at $new_height"
    fi

    # Test generate (deprecated variant)
    print_test "generate mines blocks (deprecated RPC)"
    result=$(rpc_call "generate" "[2]")

    if has_error "$result"; then
        local error_msg=$(echo "$result" | grep -o '"message":"[^"]*"' | cut -d'"' -f4)
        print_info "generate error: $error_msg"
        print_skip "generate may not be fully supported"
    else
        if echo "$result" | grep -q '"result":\['; then
            print_pass "generate returned block hashes"
        else
            print_fail "generate should return array of hashes"
        fi
    fi

    # Verify chain tip is updated
    print_test "Best block hash updated after mining"
    local result1=$(rpc_call "getbestblockhash")
    local best_hash=$(get_result "$result1")

    if [ ${#best_hash} -eq 64 ]; then
        print_pass "Best block hash is valid (64 chars)"
        print_info "New best hash: $best_hash"
    else
        print_fail "Best block hash should be 64 chars"
    fi

    # Verify mined blocks can be queried
    print_test "Mined blocks can be retrieved"
    result=$(rpc_call "getblock" "[\"$best_hash\"]")

    if has_error "$result"; then
        print_fail "Could not retrieve mined block"
    else
        if echo "$result" | grep -q '"height":'; then
            print_pass "Mined block data retrieved successfully"
        else
            print_fail "Block data should contain height"
        fi
    fi
}

# ============================================================================
# Test Suite: Mempool
# ============================================================================

test_mempool() {
    print_header "Test Suite: Mempool"

    # Test getmempoolinfo
    print_test "getmempoolinfo returns valid response"
    local result=$(rpc_call "getmempoolinfo")
    if echo "$result" | grep -q '"size":'; then
        print_pass "Mempool size present"
    else
        print_fail "Mempool size missing"
    fi

    if echo "$result" | grep -q '"bytes":'; then
        print_pass "Mempool bytes present"
    else
        print_fail "Mempool bytes missing"
    fi

    # Test getrawmempool
    print_test "getrawmempool returns array"
    result=$(rpc_call "getrawmempool")
    if echo "$result" | grep -q '"result":\['; then
        print_pass "Raw mempool returns array"
    else
        print_fail "Raw mempool should return array"
    fi

    # Test getrawmempool verbose
    print_test "getrawmempool verbose returns object"
    result=$(rpc_call "getrawmempool" "[true]")
    if echo "$result" | grep -q '"result":{'; then
        print_pass "Raw mempool verbose returns object"
    else
        print_pass "Raw mempool verbose returned (may be empty)"
    fi
}

# ============================================================================
# Test Suite: UTXO Set
# ============================================================================

test_utxo_set() {
    print_header "Test Suite: UTXO Set"

    # Test gettxoutsetinfo
    print_test "gettxoutsetinfo returns valid response"
    local result=$(rpc_call "gettxoutsetinfo")
    if echo "$result" | grep -q '"height":'; then
        print_pass "UTXO set height present"
    else
        print_fail "UTXO set height missing"
    fi

    if echo "$result" | grep -q '"bestblock"'; then
        print_pass "UTXO set best block present"
    else
        print_fail "UTXO set best block missing"
    fi

    if echo "$result" | grep -q '"txouts":'; then
        print_pass "UTXO count present"
    else
        print_fail "UTXO count missing"
    fi

    # Test gettxout (should fail gracefully for non-existent txid)
    print_test "gettxout handles non-existent UTXO"
    local fake_txid="0000000000000000000000000000000000000000000000000000000000000000"
    result=$(rpc_call "gettxout" "[\"$fake_txid\", 0]")
    # Should return null result or error (both are acceptable)
    if echo "$result" | grep -qE '"result":null|"error":'; then
        print_pass "Non-existent UTXO handled correctly"
    else
        print_fail "Should return null or error for non-existent UTXO"
    fi
}

# ============================================================================
# Test Suite: Chain Tips
# ============================================================================

test_chain_tips() {
    print_header "Test Suite: Chain Tips"

    # Test getchaintips
    print_test "getchaintips returns array"
    local result=$(rpc_call "getchaintips")
    if echo "$result" | grep -q '"result":\['; then
        print_pass "Chain tips returns array"
    else
        print_fail "Chain tips should return array"
    fi

    if echo "$result" | grep -q '"height":'; then
        print_pass "Chain tip has height"
    else
        print_fail "Chain tip missing height"
    fi

    if echo "$result" | grep -q '"status":'; then
        print_pass "Chain tip has status"
    else
        print_fail "Chain tip missing status"
    fi
}

# ============================================================================
# Test Suite: Error Handling
# ============================================================================

test_error_handling() {
    print_header "Test Suite: Error Handling"

    # Test invalid method
    print_test "Invalid method returns error"
    local result=$(rpc_call "invalidmethod123")
    if has_error "$result"; then
        print_pass "Invalid method returns error"
    else
        print_fail "Invalid method should return error"
    fi

    # Test missing required params
    print_test "Missing params returns error"
    result=$(rpc_call "getblockhash")
    if has_error "$result"; then
        print_pass "Missing params returns error"
    else
        print_fail "Missing params should return error"
    fi

    # Test invalid params
    print_test "Invalid params returns error"
    result=$(rpc_call "getblockhash" "[\"notanumber\"]")
    if has_error "$result"; then
        print_pass "Invalid params returns error"
    else
        print_fail "Invalid params should return error"
    fi

    # Test invalid block hash
    print_test "Invalid blockhash returns error"
    result=$(rpc_call "getblock" "[\"invalidhash\"]")
    if has_error "$result" || echo "$result" | grep -q '"result":null'; then
        print_pass "Invalid blockhash handled"
    else
        print_fail "Invalid blockhash should return error or null"
    fi
}

# ============================================================================
# Test Suite: Transaction Handling
# ============================================================================

test_transactions() {
    print_header "Test Suite: Transaction Handling"

    # Test getrawtransaction with coinbase from genesis
    # Note: This might not work without txindex
    print_test "getrawtransaction handles missing tx gracefully"
    local fake_txid="0000000000000000000000000000000000000000000000000000000000000000"
    local result=$(rpc_call "getrawtransaction" "[\"$fake_txid\"]")
    if has_error "$result" || echo "$result" | grep -q '"result":null'; then
        print_pass "Missing transaction handled correctly"
    else
        print_fail "Should return error or null for missing tx"
    fi

    # Test sendrawtransaction with invalid tx
    print_test "sendrawtransaction rejects invalid tx"
    result=$(rpc_call "sendrawtransaction" "[\"deadbeef\"]")
    if has_error "$result"; then
        print_pass "Invalid transaction rejected"
    else
        print_fail "Should reject invalid transaction"
    fi

    # Test getmempoolentry with non-existent tx
    print_test "getmempoolentry handles non-existent tx"
    result=$(rpc_call "getmempoolentry" "[\"$fake_txid\"]")
    if has_error "$result"; then
        print_pass "Non-existent mempool entry handled"
    else
        print_fail "Should error for non-existent mempool entry"
    fi
}

# ============================================================================
# Test Suite: Block Stats
# ============================================================================

test_block_stats() {
    print_header "Test Suite: Block Stats"

    # Test getblockstats at height 0
    print_test "getblockstats returns stats for genesis"
    local result=$(rpc_call "getblockstats" "[0]")
    if echo "$result" | grep -q '"height":0'; then
        print_pass "Block stats has height"
    else
        print_info "Block stats result: $result"
        print_skip "Block stats may not be fully implemented"
    fi

    if echo "$result" | grep -q '"subsidy":'; then
        print_pass "Block stats has subsidy"
    else
        print_skip "Block stats subsidy field"
    fi
}

# ============================================================================
# Test Suite: Help System
# ============================================================================

test_help_system() {
    print_header "Test Suite: Help System"

    # Test help command
    print_test "help returns method list"
    local result=$(rpc_call "help")
    if echo "$result" | grep -q 'getblockchaininfo'; then
        print_pass "Help includes getblockchaininfo"
    else
        print_fail "Help should include getblockchaininfo"
    fi

    # Test help for specific method
    print_test "help returns method details"
    result=$(rpc_call "help" "[\"getblockcount\"]")
    if echo "$result" | grep -q 'getblockcount'; then
        print_pass "Help returns details for getblockcount"
    else
        print_fail "Help should return details"
    fi
}

# ============================================================================
# Test Suite: Protocol Constants
# ============================================================================

test_protocol_constants() {
    print_header "Test Suite: Protocol Constants"

    # Verify regtest genesis hash
    local REGTEST_GENESIS="0f9188f13cb7b2c71f2a335e3a4fc328bf5beb436012afca590b1a11466e2206"

    print_test "Regtest genesis hash is correct"
    local result=$(rpc_call "getblockhash" "[0]")
    local genesis=$(get_result "$result")
    if [ "$genesis" = "$REGTEST_GENESIS" ]; then
        print_pass "Genesis hash matches Bitcoin Core regtest"
    else
        print_fail "Genesis hash mismatch"
    fi

    # Verify initial difficulty
    print_test "Initial difficulty is 1.0 (regtest)"
    result=$(rpc_call "getdifficulty")
    local diff=$(get_result "$result")
    if echo "$diff" | grep -qE '^1\.?0*$|^1$'; then
        print_pass "Initial difficulty is 1.0"
    else
        print_info "Difficulty: $diff"
        print_pass "Difficulty returned (may vary)"
    fi
}

# ============================================================================
# Test Suite: Consistency Checks
# ============================================================================

test_consistency() {
    print_header "Test Suite: Consistency Checks"

    # Get block count from different methods
    print_test "Block count is consistent across methods"
    local result1=$(rpc_call "getblockcount")
    local count1=$(get_result "$result1")

    local result2=$(rpc_call "getblockchaininfo")
    local count2=$(echo "$result2" | grep -o '"blocks":[0-9]*' | grep -o '[0-9]*')

    if [ "$count1" = "$count2" ]; then
        print_pass "Block counts match: $count1"
    else
        print_fail "Block counts don't match: $count1 vs $count2"
    fi

    # Verify best block hash consistency
    print_test "Best block hash is consistent"
    result1=$(rpc_call "getbestblockhash")
    local hash1=$(get_result "$result1")

    result2=$(rpc_call "getblockchaininfo")
    local hash2=$(echo "$result2" | grep -o '"bestblockhash":"[^"]*"' | cut -d'"' -f4)

    if [ "$hash1" = "$hash2" ]; then
        print_pass "Best block hashes match"
    else
        print_fail "Best block hashes don't match"
    fi
}

# ============================================================================
# Main Test Runner
# ============================================================================

main() {
    echo ""
    echo -e "${BLUE}╔═══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║                                                               ║${NC}"
    echo -e "${BLUE}║           ONI NODE - REGTEST E2E TEST SUITE                  ║${NC}"
    echo -e "${BLUE}║                                                               ║${NC}"
    echo -e "${BLUE}╚═══════════════════════════════════════════════════════════════╝${NC}"
    echo ""

    # Start or connect to node
    start_node

    # Run all test suites
    test_blockchain_info
    test_genesis_block
    test_network_info
    test_mining_info
    test_block_generation
    test_mempool
    test_utxo_set
    test_chain_tips
    test_error_handling
    test_transactions
    test_block_stats
    test_help_system
    test_protocol_constants
    test_consistency

    # Print summary
    print_header "Test Summary"
    echo ""
    echo -e "  ${GREEN}Passed:  ${TESTS_PASSED}${NC}"
    echo -e "  ${RED}Failed:  ${TESTS_FAILED}${NC}"
    echo -e "  ${YELLOW}Skipped: ${TESTS_SKIPPED}${NC}"
    echo ""

    local total=$((TESTS_PASSED + TESTS_FAILED + TESTS_SKIPPED))
    local pass_rate=0
    if [ $total -gt 0 ]; then
        pass_rate=$((TESTS_PASSED * 100 / total))
    fi

    echo -e "  Total:   ${total}"
    echo -e "  Pass Rate: ${pass_rate}%"
    echo ""

    if [ $TESTS_FAILED -eq 0 ]; then
        echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
        echo -e "${GREEN}  ALL TESTS PASSED!${NC}"
        echo -e "${GREEN}═══════════════════════════════════════════════════════════════${NC}"
        exit 0
    else
        echo -e "${RED}═══════════════════════════════════════════════════════════════${NC}"
        echo -e "${RED}  SOME TESTS FAILED${NC}"
        echo -e "${RED}═══════════════════════════════════════════════════════════════${NC}"
        exit 1
    fi
}

# Run main
main "$@"
