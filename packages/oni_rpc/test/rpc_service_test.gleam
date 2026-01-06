// rpc_service_test.gleam - Tests for the RPC service module
//
// These tests verify the RPC service actor behavior:
// - Service creation and startup
// - Request handling statistics
// - Integration with handlers

import gleam/option.{None}
import gleeunit
import gleeunit/should
import oni_rpc
import rpc_service

pub fn main() {
  gleeunit.main()
}

// ============================================================================
// Service State Tests
// ============================================================================

pub fn new_standalone_test() {
  let config = oni_rpc.default_config()
  let state = rpc_service.new_standalone(config)

  // Initial stats should be zero
  should.equal(state.requests_handled, 0)
  should.equal(state.requests_failed, 0)
}

pub fn service_stats_initial_test() {
  // Start service as actor
  let config = oni_rpc.default_config()
  let assert Ok(service) = rpc_service.start(config, None)

  // Get stats
  let stats = rpc_service.get_stats_sync(service)

  // Should be zero initially
  should.equal(stats.requests_handled, 0)
  should.equal(stats.requests_failed, 0)

  // Cleanup
  rpc_service.shutdown(service)
}

// ============================================================================
// Request Handling Tests
// ============================================================================

pub fn handle_getblockcount_test() {
  let config = oni_rpc.default_config()
  let assert Ok(service) = rpc_service.start(config, None)

  // Send a request
  let response =
    rpc_service.handle_request_sync(
      service,
      "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"getblockcount\"}",
      True,
    )

  // Response should contain result
  should.be_true(contains(response, "result"))
  should.be_true(contains(response, "jsonrpc"))

  // Cleanup
  rpc_service.shutdown(service)
}

pub fn handle_getbestblockhash_test() {
  let config = oni_rpc.default_config()
  let assert Ok(service) = rpc_service.start(config, None)

  // Send a request
  let response =
    rpc_service.handle_request_sync(
      service,
      "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"getbestblockhash\"}",
      True,
    )

  // Response should contain a 64-character hex hash
  should.be_true(contains(response, "result"))

  // Cleanup
  rpc_service.shutdown(service)
}

pub fn handle_help_test() {
  let config = oni_rpc.default_config()
  let assert Ok(service) = rpc_service.start(config, None)

  // Send a request
  let response =
    rpc_service.handle_request_sync(
      service,
      "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"help\"}",
      True,
    )

  // Response should contain help text
  should.be_true(contains(response, "Blockchain"))

  // Cleanup
  rpc_service.shutdown(service)
}

pub fn handle_unknown_method_test() {
  let config = oni_rpc.default_config()
  let assert Ok(service) = rpc_service.start(config, None)

  // Send a request for unknown method
  let response =
    rpc_service.handle_request_sync(
      service,
      "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"unknownmethod\"}",
      True,
    )

  // Response should contain error
  should.be_true(contains(response, "error"))
  should.be_true(contains(response, "-32601"))
  // Method not found

  // Cleanup
  rpc_service.shutdown(service)
}

pub fn handle_invalid_json_test() {
  let config = oni_rpc.default_config()
  let assert Ok(service) = rpc_service.start(config, None)

  // Send invalid JSON
  let response =
    rpc_service.handle_request_sync(service, "not valid json", True)

  // Response should contain error
  should.be_true(contains(response, "error"))

  // Cleanup
  rpc_service.shutdown(service)
}

// ============================================================================
// Statistics Tests
// ============================================================================

pub fn stats_increment_on_success_test() {
  let config = oni_rpc.default_config()
  let assert Ok(service) = rpc_service.start(config, None)

  // Send successful requests
  let _ =
    rpc_service.handle_request_sync(
      service,
      "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"getblockcount\"}",
      True,
    )
  let _ =
    rpc_service.handle_request_sync(
      service,
      "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"help\"}",
      True,
    )

  // Get stats
  let stats = rpc_service.get_stats_sync(service)

  // Should have handled 2 requests
  should.equal(stats.requests_handled, 2)

  // Cleanup
  rpc_service.shutdown(service)
}

pub fn stats_increment_on_failure_test() {
  let config = oni_rpc.default_config()
  let assert Ok(service) = rpc_service.start(config, None)

  // Send failed requests
  let _ =
    rpc_service.handle_request_sync(
      service,
      "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"unknownmethod\"}",
      True,
    )

  // Get stats
  let stats = rpc_service.get_stats_sync(service)

  // Should have handled 1 request with 1 failure
  should.equal(stats.requests_handled, 1)
  should.equal(stats.requests_failed, 1)

  // Cleanup
  rpc_service.shutdown(service)
}

// ============================================================================
// Multiple Request Tests
// ============================================================================

pub fn handle_multiple_requests_test() {
  let config = oni_rpc.default_config()
  let assert Ok(service) = rpc_service.start(config, None)

  // Send multiple requests
  let r1 =
    rpc_service.handle_request_sync(
      service,
      "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"getblockcount\"}",
      True,
    )
  let r2 =
    rpc_service.handle_request_sync(
      service,
      "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"getbestblockhash\"}",
      True,
    )
  let r3 =
    rpc_service.handle_request_sync(
      service,
      "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"getblockchaininfo\"}",
      True,
    )

  // All should have results
  should.be_true(contains(r1, "result"))
  should.be_true(contains(r2, "result"))
  should.be_true(contains(r3, "result"))

  // Get stats
  let stats = rpc_service.get_stats_sync(service)
  should.equal(stats.requests_handled, 3)

  // Cleanup
  rpc_service.shutdown(service)
}

// ============================================================================
// Helper Functions
// ============================================================================

fn contains(haystack: String, needle: String) -> Bool {
  case haystack {
    _ if haystack == needle -> True
    _ -> {
      let len = string_length(needle)
      check_contains(haystack, needle, len)
    }
  }
}

fn check_contains(haystack: String, needle: String, len: Int) -> Bool {
  case string_length(haystack) < len {
    True -> False
    False -> {
      case string_slice(haystack, 0, len) == needle {
        True -> True
        False -> check_contains(string_drop(haystack, 1), needle, len)
      }
    }
  }
}

@external(erlang, "string", "length")
fn string_length(s: String) -> Int

@external(erlang, "string", "slice")
fn string_slice(s: String, start: Int, len: Int) -> String

fn string_drop(s: String, n: Int) -> String {
  string_slice(s, n, string_length(s) - n)
}

// ============================================================================
// submitblock Tests
// ============================================================================

pub fn handle_submitblock_missing_param_test() {
  let config = oni_rpc.default_config()
  let assert Ok(service) = rpc_service.start(config, None)

  // Send submitblock without parameters
  let response =
    rpc_service.handle_request_sync(
      service,
      "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"submitblock\",\"params\":[]}",
      True,
    )

  // Response should contain error for invalid params
  should.be_true(contains(response, "error"))

  // Cleanup
  rpc_service.shutdown(service)
}

pub fn handle_submitblock_invalid_hex_test() {
  let config = oni_rpc.default_config()
  let assert Ok(service) = rpc_service.start(config, None)

  // Send submitblock with invalid hex
  let response =
    rpc_service.handle_request_sync(
      service,
      "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"submitblock\",\"params\":[\"notvalidhex\"]}",
      True,
    )

  // Response should contain error for invalid hex
  should.be_true(contains(response, "error"))

  // Cleanup
  rpc_service.shutdown(service)
}

pub fn handle_submitblock_truncated_block_test() {
  let config = oni_rpc.default_config()
  let assert Ok(service) = rpc_service.start(config, None)

  // Send submitblock with valid hex but truncated block data
  // This is only the first 40 bytes of a block header (should be 80 bytes)
  let response =
    rpc_service.handle_request_sync(
      service,
      "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"submitblock\",\"params\":[\"0100000000000000000000000000000000000000000000000000000000000000\"]}",
      True,
    )

  // Response should contain error for invalid block data
  should.be_true(contains(response, "error"))

  // Cleanup
  rpc_service.shutdown(service)
}

// ============================================================================
// sendrawtransaction Tests
// ============================================================================

pub fn handle_sendrawtransaction_missing_param_test() {
  let config = oni_rpc.default_config()
  let assert Ok(service) = rpc_service.start(config, None)

  // Send sendrawtransaction without parameters
  let response =
    rpc_service.handle_request_sync(
      service,
      "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"sendrawtransaction\",\"params\":[]}",
      True,
    )

  // Response should contain error for invalid params
  should.be_true(contains(response, "error"))

  // Cleanup
  rpc_service.shutdown(service)
}

pub fn handle_sendrawtransaction_invalid_hex_test() {
  let config = oni_rpc.default_config()
  let assert Ok(service) = rpc_service.start(config, None)

  // Send sendrawtransaction with invalid hex
  let response =
    rpc_service.handle_request_sync(
      service,
      "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"sendrawtransaction\",\"params\":[\"gggg\"]}",
      True,
    )

  // Response should contain error for invalid hex
  should.be_true(contains(response, "error"))

  // Cleanup
  rpc_service.shutdown(service)
}

pub fn handle_sendrawtransaction_truncated_tx_test() {
  let config = oni_rpc.default_config()
  let assert Ok(service) = rpc_service.start(config, None)

  // Send sendrawtransaction with truncated transaction data (just version bytes)
  let response =
    rpc_service.handle_request_sync(
      service,
      "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"sendrawtransaction\",\"params\":[\"01000000\"]}",
      True,
    )

  // Response should contain error for invalid transaction data
  should.be_true(contains(response, "error"))

  // Cleanup
  rpc_service.shutdown(service)
}
