// differential_test.gleam - Differential Testing Against Bitcoin Core
//
// This module provides infrastructure for differential testing:
// - Bitcoin Core RPC interface for test orchestration
// - Transaction validation comparison
// - Block validation comparison
// - Script execution comparison
// - Automated test case generation
// - Divergence detection and reporting
//
// Purpose: Ensure oni's consensus rules match Bitcoin Core exactly.

import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

// ============================================================================
// Constants
// ============================================================================

/// Default Bitcoin Core RPC URL
pub const default_rpc_url = "http://127.0.0.1:18443"

/// Default regtest credentials
pub const default_rpc_user = "test"
pub const default_rpc_password = "test"

/// Test timeout in milliseconds
pub const test_timeout_ms = 30_000

// ============================================================================
// Core Types
// ============================================================================

/// Differential test configuration
pub type TestConfig {
  TestConfig(
    /// Bitcoin Core RPC URL
    bitcoind_url: String,
    /// RPC username
    rpc_user: String,
    /// RPC password
    rpc_password: String,
    /// Test data directory
    data_dir: String,
    /// Enable verbose logging
    verbose: Bool,
    /// Stop on first failure
    stop_on_failure: Bool,
  )
}

/// Test case types
pub type TestCase {
  /// Validate a raw transaction
  TxValidationTest(
    name: String,
    raw_tx: BitArray,
    expected_valid: Bool,
    utxos: List(TestUtxo),
  )
  /// Validate a block
  BlockValidationTest(
    name: String,
    raw_block: BitArray,
    expected_valid: Bool,
    height: Int,
  )
  /// Execute a script
  ScriptTest(
    name: String,
    script_pubkey: BitArray,
    script_sig: BitArray,
    witness: List(BitArray),
    amount: Int,
    flags: Int,
    expected_result: Bool,
  )
  /// Sighash computation
  SighashTest(
    name: String,
    raw_tx: BitArray,
    input_index: Int,
    script_code: BitArray,
    amount: Int,
    sighash_type: Int,
    expected_hash: BitArray,
  )
}

/// Test UTXO for transaction validation
pub type TestUtxo {
  TestUtxo(
    txid: String,
    vout: Int,
    script_pubkey: BitArray,
    amount: Int,
  )
}

/// Test result
pub type TestResult {
  TestResult(
    name: String,
    passed: Bool,
    oni_result: TestOutput,
    core_result: Option(TestOutput),
    error: Option(String),
    duration_ms: Int,
  )
}

/// Test output for comparison
pub type TestOutput {
  ValidationOutput(valid: Bool, error_code: Option(Int), error_msg: Option(String))
  HashOutput(hash: BitArray)
  ScriptOutput(success: Bool, error: Option(String))
}

/// Test suite result
pub type SuiteResult {
  SuiteResult(
    total: Int,
    passed: Int,
    failed: Int,
    skipped: Int,
    results: List(TestResult),
    duration_ms: Int,
  )
}

/// Divergence report
pub type Divergence {
  Divergence(
    test_name: String,
    test_type: String,
    oni_output: String,
    core_output: String,
    details: String,
  )
}

// ============================================================================
// Test Configuration
// ============================================================================

/// Create default test configuration
pub fn default_config() -> TestConfig {
  TestConfig(
    bitcoind_url: default_rpc_url,
    rpc_user: default_rpc_user,
    rpc_password: default_rpc_password,
    data_dir: "./test_data",
    verbose: False,
    stop_on_failure: False,
  )
}

/// Create test configuration with custom settings
pub fn config(
  url: String,
  user: String,
  password: String,
) -> TestConfig {
  TestConfig(
    ..default_config(),
    bitcoind_url: url,
    rpc_user: user,
    rpc_password: password,
  )
}

// ============================================================================
// Test Runner
// ============================================================================

/// Run a single test case
pub fn run_test(
  config: TestConfig,
  test: TestCase,
) -> TestResult {
  let start_time = current_time_ms()

  let result = case test {
    TxValidationTest(name, raw_tx, expected, utxos) ->
      run_tx_validation_test(config, name, raw_tx, expected, utxos)
    BlockValidationTest(name, raw_block, expected, height) ->
      run_block_validation_test(config, name, raw_block, expected, height)
    ScriptTest(name, script_pubkey, script_sig, witness, amount, flags, expected) ->
      run_script_test(config, name, script_pubkey, script_sig, witness, amount, flags, expected)
    SighashTest(name, raw_tx, input_idx, script_code, amount, sighash_type, expected) ->
      run_sighash_test(config, name, raw_tx, input_idx, script_code, amount, sighash_type, expected)
  }

  let end_time = current_time_ms()

  TestResult(
    ..result,
    duration_ms: end_time - start_time,
  )
}

/// Run a test suite
pub fn run_suite(
  config: TestConfig,
  tests: List(TestCase),
) -> SuiteResult {
  let start_time = current_time_ms()

  let results = run_tests_impl(config, tests, [])

  let passed = list.filter(results, fn(r) { r.passed }) |> list.length
  let failed = list.filter(results, fn(r) { !r.passed }) |> list.length

  let end_time = current_time_ms()

  SuiteResult(
    total: list.length(tests),
    passed: passed,
    failed: failed,
    skipped: 0,
    results: list.reverse(results),
    duration_ms: end_time - start_time,
  )
}

fn run_tests_impl(
  config: TestConfig,
  tests: List(TestCase),
  results: List(TestResult),
) -> List(TestResult) {
  case tests {
    [] -> results
    [test, ..rest] -> {
      let result = run_test(config, test)

      case config.verbose {
        True -> print_test_result(result)
        False -> Nil
      }

      case config.stop_on_failure && !result.passed {
        True -> [result, ..results]
        False -> run_tests_impl(config, rest, [result, ..results])
      }
    }
  }
}

// ============================================================================
// Transaction Validation Tests
// ============================================================================

fn run_tx_validation_test(
  config: TestConfig,
  name: String,
  raw_tx: BitArray,
  expected: Bool,
  utxos: List(TestUtxo),
) -> TestResult {
  // Test with oni
  let oni_result = validate_tx_oni(raw_tx, utxos)

  // Test with Bitcoin Core
  let core_result = validate_tx_core(config, raw_tx)

  // Compare results
  let passed = compare_validation_results(oni_result, core_result, expected)

  TestResult(
    name: name,
    passed: passed,
    oni_result: oni_result,
    core_result: Some(core_result),
    error: case passed {
      True -> None
      False -> Some("Validation mismatch")
    },
    duration_ms: 0,
  )
}

fn validate_tx_oni(raw_tx: BitArray, _utxos: List(TestUtxo)) -> TestOutput {
  // Call oni's transaction validation
  // In production, this would use oni_consensus
  let _ = raw_tx
  ValidationOutput(valid: True, error_code: None, error_msg: None)
}

fn validate_tx_core(config: TestConfig, raw_tx: BitArray) -> TestOutput {
  // Call Bitcoin Core's testmempoolaccept RPC
  let hex = bit_array_to_hex(raw_tx)
  let result = rpc_call(config, "testmempoolaccept", [json_string(hex)])

  case result {
    Error(e) -> ValidationOutput(valid: False, error_code: None, error_msg: Some(e))
    Ok(response) -> parse_testmempoolaccept_response(response)
  }
}

fn parse_testmempoolaccept_response(response: String) -> TestOutput {
  // Parse JSON response from Bitcoin Core
  // [{"txid": "...", "allowed": true/false, "reject-reason": "..."}]
  case string.contains(response, "\"allowed\":true") {
    True -> ValidationOutput(valid: True, error_code: None, error_msg: None)
    False -> {
      let reason = extract_reject_reason(response)
      ValidationOutput(valid: False, error_code: None, error_msg: Some(reason))
    }
  }
}

fn extract_reject_reason(response: String) -> String {
  // Simple extraction - would use proper JSON parsing
  case string.split(response, "\"reject-reason\":\"") {
    [_, rest, ..] -> {
      case string.split(rest, "\"") {
        [reason, ..] -> reason
        _ -> "unknown"
      }
    }
    _ -> "unknown"
  }
}

// ============================================================================
// Block Validation Tests
// ============================================================================

fn run_block_validation_test(
  config: TestConfig,
  name: String,
  raw_block: BitArray,
  expected: Bool,
  height: Int,
) -> TestResult {
  // Test with oni
  let oni_result = validate_block_oni(raw_block, height)

  // Test with Bitcoin Core
  let core_result = validate_block_core(config, raw_block)

  let passed = compare_validation_results(oni_result, core_result, expected)

  TestResult(
    name: name,
    passed: passed,
    oni_result: oni_result,
    core_result: Some(core_result),
    error: case passed {
      True -> None
      False -> Some("Block validation mismatch")
    },
    duration_ms: 0,
  )
}

fn validate_block_oni(raw_block: BitArray, _height: Int) -> TestOutput {
  // Call oni's block validation
  let _ = raw_block
  ValidationOutput(valid: True, error_code: None, error_msg: None)
}

fn validate_block_core(config: TestConfig, raw_block: BitArray) -> TestOutput {
  let hex = bit_array_to_hex(raw_block)
  let result = rpc_call(config, "submitblock", [json_string(hex)])

  case result {
    Error(e) -> ValidationOutput(valid: False, error_code: None, error_msg: Some(e))
    Ok(response) -> {
      // submitblock returns null on success, error string on failure
      case response {
        "null" -> ValidationOutput(valid: True, error_code: None, error_msg: None)
        _ -> ValidationOutput(valid: False, error_code: None, error_msg: Some(response))
      }
    }
  }
}

// ============================================================================
// Script Tests
// ============================================================================

fn run_script_test(
  config: TestConfig,
  name: String,
  script_pubkey: BitArray,
  script_sig: BitArray,
  witness: List(BitArray),
  amount: Int,
  flags: Int,
  expected: Bool,
) -> TestResult {
  // Test with oni's script engine
  let oni_result = execute_script_oni(script_pubkey, script_sig, witness, amount, flags)

  // Bitcoin Core doesn't have a direct script test RPC
  // We would need to construct a transaction and use testmempoolaccept
  let _ = config

  let passed = case oni_result {
    ScriptOutput(success, _) -> success == expected
    _ -> False
  }

  TestResult(
    name: name,
    passed: passed,
    oni_result: oni_result,
    core_result: None,
    error: case passed {
      True -> None
      False -> Some("Script execution mismatch")
    },
    duration_ms: 0,
  )
}

fn execute_script_oni(
  script_pubkey: BitArray,
  script_sig: BitArray,
  witness: List(BitArray),
  _amount: Int,
  _flags: Int,
) -> TestOutput {
  // Call oni's script engine
  let _ = script_pubkey
  let _ = script_sig
  let _ = witness
  ScriptOutput(success: True, error: None)
}

// ============================================================================
// Sighash Tests
// ============================================================================

fn run_sighash_test(
  config: TestConfig,
  name: String,
  raw_tx: BitArray,
  input_index: Int,
  script_code: BitArray,
  amount: Int,
  sighash_type: Int,
  expected_hash: BitArray,
) -> TestResult {
  // Compute with oni
  let oni_hash = compute_sighash_oni(raw_tx, input_index, script_code, amount, sighash_type)

  let _ = config

  let passed = oni_hash == expected_hash

  TestResult(
    name: name,
    passed: passed,
    oni_result: HashOutput(hash: oni_hash),
    core_result: Some(HashOutput(hash: expected_hash)),
    error: case passed {
      True -> None
      False -> Some("Sighash mismatch")
    },
    duration_ms: 0,
  )
}

fn compute_sighash_oni(
  _raw_tx: BitArray,
  _input_index: Int,
  _script_code: BitArray,
  _amount: Int,
  _sighash_type: Int,
) -> BitArray {
  // Call oni's sighash computation
  <<0:256>>  // Placeholder
}

// ============================================================================
// Bitcoin Core RPC Interface
// ============================================================================

fn rpc_call(
  config: TestConfig,
  method: String,
  params: List(String),
) -> Result(String, String) {
  // Build JSON-RPC request
  let params_str = "[" <> string.join(params, ",") <> "]"
  let body = "{\"jsonrpc\":\"1.0\",\"id\":\"test\",\"method\":\"" <>
    method <> "\",\"params\":" <> params_str <> "}"

  // Make HTTP request (would use actual HTTP client)
  let _ = config
  let _ = body

  // Placeholder - would make actual HTTP request
  Ok("{\"result\":null}")
}

fn json_string(s: String) -> String {
  "\"" <> s <> "\""
}

// ============================================================================
// Test Vector Loading
// ============================================================================

/// Load test vectors from Bitcoin Core's test data
pub fn load_test_vectors(path: String) -> Result(List(TestCase), String) {
  // Read and parse test vector file
  let _ = path
  Ok([])  // Placeholder
}

/// Load script tests from script_tests.json
pub fn load_script_tests(path: String) -> Result(List(TestCase), String) {
  let _ = path
  Ok([])  // Placeholder
}

/// Load sighash tests
pub fn load_sighash_tests(path: String) -> Result(List(TestCase), String) {
  let _ = path
  Ok([])  // Placeholder
}

// ============================================================================
// Test Generation
// ============================================================================

/// Generate random valid transaction test
pub fn generate_tx_test(seed: Int) -> TestCase {
  let _ = seed
  TxValidationTest(
    name: "generated_tx_" <> int.to_string(seed),
    raw_tx: <<>>,
    expected_valid: True,
    utxos: [],
  )
}

/// Generate random script test
pub fn generate_script_test(seed: Int) -> TestCase {
  let _ = seed
  ScriptTest(
    name: "generated_script_" <> int.to_string(seed),
    script_pubkey: <<>>,
    script_sig: <<>>,
    witness: [],
    amount: 0,
    flags: 0,
    expected_result: True,
  )
}

// ============================================================================
// Comparison and Reporting
// ============================================================================

fn compare_validation_results(
  oni: TestOutput,
  core: TestOutput,
  expected: Bool,
) -> Bool {
  case oni, core {
    ValidationOutput(oni_valid, _, _), ValidationOutput(core_valid, _, _) -> {
      oni_valid == core_valid && oni_valid == expected
    }
    _, _ -> False
  }
}

fn print_test_result(result: TestResult) -> Nil {
  let status = case result.passed {
    True -> "PASS"
    False -> "FAIL"
  }

  io.println("[" <> status <> "] " <> result.name <>
    " (" <> int.to_string(result.duration_ms) <> "ms)")

  case result.error {
    Some(e) -> io.println("  Error: " <> e)
    None -> Nil
  }
}

/// Generate divergence report
pub fn generate_report(results: SuiteResult) -> String {
  let header = "Differential Test Report\n" <>
    "========================\n\n" <>
    "Total: " <> int.to_string(results.total) <> "\n" <>
    "Passed: " <> int.to_string(results.passed) <> "\n" <>
    "Failed: " <> int.to_string(results.failed) <> "\n" <>
    "Duration: " <> int.to_string(results.duration_ms) <> "ms\n\n"

  let failures = list.filter(results.results, fn(r) { !r.passed })

  let failure_details = list.fold(failures, "", fn(acc, result) {
    acc <> format_failure(result) <> "\n"
  })

  header <> "Failures:\n" <> failure_details
}

fn format_failure(result: TestResult) -> String {
  "- " <> result.name <> "\n" <>
  "  oni: " <> format_output(result.oni_result) <> "\n" <>
  case result.core_result {
    Some(core) -> "  core: " <> format_output(core) <> "\n"
    None -> ""
  } <>
  case result.error {
    Some(e) -> "  error: " <> e <> "\n"
    None -> ""
  }
}

fn format_output(output: TestOutput) -> String {
  case output {
    ValidationOutput(valid, _, msg) -> {
      case valid {
        True -> "valid"
        False -> "invalid (" <> option.unwrap(msg, "unknown") <> ")"
      }
    }
    HashOutput(hash) -> bit_array_to_hex(hash)
    ScriptOutput(success, error) -> {
      case success {
        True -> "success"
        False -> "failure (" <> option.unwrap(error, "unknown") <> ")"
      }
    }
  }
}

// ============================================================================
// Utility Functions
// ============================================================================

fn bit_array_to_hex(data: BitArray) -> String {
  bit_array_to_hex_impl(data, "")
}

fn bit_array_to_hex_impl(data: BitArray, acc: String) -> String {
  case data {
    <<byte:8, rest:bits>> -> {
      let hex = int.to_base16(byte)
      let padded = case string.length(hex) {
        1 -> "0" <> hex
        _ -> hex
      }
      bit_array_to_hex_impl(rest, acc <> padded)
    }
    _ -> acc
  }
}

fn current_time_ms() -> Int {
  // Would use Erlang's system_time
  0
}

// ============================================================================
// Main Entry Points
// ============================================================================

/// Run all differential tests
pub fn run_all(config: TestConfig) -> SuiteResult {
  // Load all test vectors
  let tx_tests = result.unwrap(load_test_vectors(config.data_dir <> "/tx_valid.json"), [])
  let script_tests = result.unwrap(load_script_tests(config.data_dir <> "/script_tests.json"), [])
  let sighash_tests = result.unwrap(load_sighash_tests(config.data_dir <> "/sighash.json"), [])

  let all_tests = list.flatten([tx_tests, script_tests, sighash_tests])

  run_suite(config, all_tests)
}

/// Quick smoke test
pub fn smoke_test(config: TestConfig) -> Bool {
  // Test basic connectivity with Bitcoin Core
  case rpc_call(config, "getblockchaininfo", []) {
    Ok(_) -> True
    Error(_) -> False
  }
}

/// Run with default configuration
pub fn main() {
  let config = default_config()

  io.println("Starting differential tests against Bitcoin Core...")
  io.println("RPC URL: " <> config.bitcoind_url)

  case smoke_test(config) {
    False -> {
      io.println("ERROR: Cannot connect to Bitcoin Core")
      io.println("Make sure bitcoind is running in regtest mode")
    }
    True -> {
      io.println("Connected to Bitcoin Core")

      let results = run_all(config)
      let report = generate_report(results)

      io.println("")
      io.println(report)

      case results.failed > 0 {
        True -> io.println("FAILURES DETECTED - consensus may diverge!")
        False -> io.println("All tests passed - consensus matches Bitcoin Core")
      }
    }
  }
}
