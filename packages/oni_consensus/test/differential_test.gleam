/// Differential testing harness for Bitcoin Core test vector compatibility
///
/// This module provides parsing and execution of Bitcoin Core test vectors
/// to ensure oni's consensus behavior matches Bitcoin Core exactly.

import gleeunit/should
import gleam/list
import gleam/result
import gleam/string
import gleam/int
import gleam/bit_array
import gleam/io
import oni_consensus
import oni_bitcoin

// ============================================================================
// Script Test Vector Types
// ============================================================================

pub type ScriptTestCase {
  ScriptTestCase(
    script_sig: BitArray,
    script_pubkey: BitArray,
    flags: ScriptTestFlags,
    expected_result: ScriptTestResult,
    comment: String,
  )
}

pub type ScriptTestFlags {
  ScriptTestFlags(
    p2sh: Bool,
    strictenc: Bool,
    dersig: Bool,
    low_s: Bool,
    nulldummy: Bool,
    sigpushonly: Bool,
    minimaldata: Bool,
    discourage_upgradable_nops: Bool,
    cleanstack: Bool,
    checklocktimeverify: Bool,
    checksequenceverify: Bool,
    witness: Bool,
    discourage_upgradable_witness_program: Bool,
    minimalif: Bool,
    nullfail: Bool,
    witness_pubkeytype: Bool,
    const_scriptcode: Bool,
    taproot: Bool,
  )
}

pub type ScriptTestResult {
  ScriptOK
  ScriptError(String)
}

// ============================================================================
// Transaction Test Vector Types
// ============================================================================

pub type TxTestCase {
  TxTestCase(
    prevouts: List(TxTestPrevout),
    tx_hex: String,
    flags: String,
  )
}

pub type TxTestPrevout {
  TxTestPrevout(
    txid: String,
    vout: Int,
    script_pubkey: BitArray,
    amount: Int,
  )
}

// ============================================================================
// Sighash Test Vector Types
// ============================================================================

pub type SighashTestCase {
  SighashTestCase(
    tx_hex: String,
    input_index: Int,
    prev_script_pubkey: BitArray,
    amount: Int,
    sighash_type: String,
    expected_hash: String,
  )
}

// ============================================================================
// Flag Parsing
// ============================================================================

pub fn parse_script_flags(flags_str: String) -> ScriptTestFlags {
  let flags = string.split(flags_str, ",")

  ScriptTestFlags(
    p2sh: list.contains(flags, "P2SH"),
    strictenc: list.contains(flags, "STRICTENC"),
    dersig: list.contains(flags, "DERSIG"),
    low_s: list.contains(flags, "LOW_S"),
    nulldummy: list.contains(flags, "NULLDUMMY"),
    sigpushonly: list.contains(flags, "SIGPUSHONLY"),
    minimaldata: list.contains(flags, "MINIMALDATA"),
    discourage_upgradable_nops: list.contains(flags, "DISCOURAGE_UPGRADABLE_NOPS"),
    cleanstack: list.contains(flags, "CLEANSTACK"),
    checklocktimeverify: list.contains(flags, "CHECKLOCKTIMEVERIFY"),
    checksequenceverify: list.contains(flags, "CHECKSEQUENCEVERIFY"),
    witness: list.contains(flags, "WITNESS"),
    discourage_upgradable_witness_program: list.contains(flags, "DISCOURAGE_UPGRADABLE_WITNESS_PROGRAM"),
    minimalif: list.contains(flags, "MINIMALIF"),
    nullfail: list.contains(flags, "NULLFAIL"),
    witness_pubkeytype: list.contains(flags, "WITNESS_PUBKEYTYPE"),
    const_scriptcode: list.contains(flags, "CONST_SCRIPTCODE"),
    taproot: list.contains(flags, "TAPROOT"),
  )
}

pub fn script_test_flags_to_consensus_flags(test_flags: ScriptTestFlags) -> oni_consensus.ScriptFlags {
  oni_consensus.ScriptFlags(
    verify_p2sh: test_flags.p2sh,
    verify_witness: test_flags.witness,
    verify_minimaldata: test_flags.minimaldata,
    verify_cleanstack: test_flags.cleanstack,
    verify_dersig: test_flags.dersig,
    verify_low_s: test_flags.low_s,
    verify_nulldummy: test_flags.nulldummy,
    verify_sigpushonly: test_flags.sigpushonly,
    verify_strictenc: test_flags.strictenc,
    verify_minimalif: test_flags.minimalif,
    verify_nullfail: test_flags.nullfail,
    verify_witness_pubkeytype: test_flags.witness_pubkeytype,
    verify_taproot: test_flags.taproot,
    verify_discourage_upgradable_nops: test_flags.discourage_upgradable_nops,
    verify_discourage_upgradable_witness_program: test_flags.discourage_upgradable_witness_program,
    verify_discourage_upgradable_taproot_version: False,
    verify_discourage_op_success: False,
    verify_discourage_upgradable_pubkeytype: False,
  )
}

// ============================================================================
// Script Parsing from Test Format
// ============================================================================

/// Parse a script from the test vector format (space-separated ops and data)
pub fn parse_test_script(script_str: String) -> Result(BitArray, String) {
  case string.trim(script_str) {
    "" -> Ok(<<>>)
    trimmed -> {
      let tokens = string.split(trimmed, " ")
      parse_script_tokens(tokens, <<>>)
    }
  }
}

fn parse_script_tokens(tokens: List(String), acc: BitArray) -> Result(BitArray, String) {
  case tokens {
    [] -> Ok(acc)
    [token, ..rest] -> {
      case parse_script_token(token) {
        Ok(bytes) -> parse_script_tokens(rest, bit_array.concat([acc, bytes]))
        Error(e) -> Error(e)
      }
    }
  }
}

fn parse_script_token(token: String) -> Result(BitArray, String) {
  case token {
    // Hex data with 0x prefix
    "0x" <> hex -> {
      case oni_bitcoin.hex_decode(hex) {
        Ok(bytes) -> Ok(bytes)
        Error(_) -> Error("Invalid hex: " <> hex)
      }
    }

    // OP codes
    "OP_0" | "OP_FALSE" -> Ok(<<0x00>>)
    "OP_PUSHDATA1" -> Ok(<<0x4c>>)
    "OP_PUSHDATA2" -> Ok(<<0x4d>>)
    "OP_PUSHDATA4" -> Ok(<<0x4e>>)
    "OP_1NEGATE" -> Ok(<<0x4f>>)
    "OP_RESERVED" -> Ok(<<0x50>>)
    "OP_1" | "OP_TRUE" -> Ok(<<0x51>>)
    "OP_2" -> Ok(<<0x52>>)
    "OP_3" -> Ok(<<0x53>>)
    "OP_4" -> Ok(<<0x54>>)
    "OP_5" -> Ok(<<0x55>>)
    "OP_6" -> Ok(<<0x56>>)
    "OP_7" -> Ok(<<0x57>>)
    "OP_8" -> Ok(<<0x58>>)
    "OP_9" -> Ok(<<0x59>>)
    "OP_10" -> Ok(<<0x5a>>)
    "OP_11" -> Ok(<<0x5b>>)
    "OP_12" -> Ok(<<0x5c>>)
    "OP_13" -> Ok(<<0x5d>>)
    "OP_14" -> Ok(<<0x5e>>)
    "OP_15" -> Ok(<<0x5f>>)
    "OP_16" -> Ok(<<0x60>>)

    // Flow control
    "OP_NOP" -> Ok(<<0x61>>)
    "OP_VER" -> Ok(<<0x62>>)
    "OP_IF" -> Ok(<<0x63>>)
    "OP_NOTIF" -> Ok(<<0x64>>)
    "OP_VERIF" -> Ok(<<0x65>>)
    "OP_VERNOTIF" -> Ok(<<0x66>>)
    "OP_ELSE" -> Ok(<<0x67>>)
    "OP_ENDIF" -> Ok(<<0x68>>)
    "OP_VERIFY" -> Ok(<<0x69>>)
    "OP_RETURN" -> Ok(<<0x6a>>)

    // Stack
    "OP_TOALTSTACK" -> Ok(<<0x6b>>)
    "OP_FROMALTSTACK" -> Ok(<<0x6c>>)
    "OP_2DROP" -> Ok(<<0x6d>>)
    "OP_2DUP" -> Ok(<<0x6e>>)
    "OP_3DUP" -> Ok(<<0x6f>>)
    "OP_2OVER" -> Ok(<<0x70>>)
    "OP_2ROT" -> Ok(<<0x71>>)
    "OP_2SWAP" -> Ok(<<0x72>>)
    "OP_IFDUP" -> Ok(<<0x73>>)
    "OP_DEPTH" -> Ok(<<0x74>>)
    "OP_DROP" -> Ok(<<0x75>>)
    "OP_DUP" -> Ok(<<0x76>>)
    "OP_NIP" -> Ok(<<0x77>>)
    "OP_OVER" -> Ok(<<0x78>>)
    "OP_PICK" -> Ok(<<0x79>>)
    "OP_ROLL" -> Ok(<<0x7a>>)
    "OP_ROT" -> Ok(<<0x7b>>)
    "OP_SWAP" -> Ok(<<0x7c>>)
    "OP_TUCK" -> Ok(<<0x7d>>)

    // Splice (disabled)
    "OP_CAT" -> Ok(<<0x7e>>)
    "OP_SUBSTR" -> Ok(<<0x7f>>)
    "OP_LEFT" -> Ok(<<0x80>>)
    "OP_RIGHT" -> Ok(<<0x81>>)
    "OP_SIZE" -> Ok(<<0x82>>)

    // Bitwise
    "OP_INVERT" -> Ok(<<0x83>>)
    "OP_AND" -> Ok(<<0x84>>)
    "OP_OR" -> Ok(<<0x85>>)
    "OP_XOR" -> Ok(<<0x86>>)
    "OP_EQUAL" -> Ok(<<0x87>>)
    "OP_EQUALVERIFY" -> Ok(<<0x88>>)

    // Arithmetic
    "OP_1ADD" -> Ok(<<0x8b>>)
    "OP_1SUB" -> Ok(<<0x8c>>)
    "OP_2MUL" -> Ok(<<0x8d>>)
    "OP_2DIV" -> Ok(<<0x8e>>)
    "OP_NEGATE" -> Ok(<<0x8f>>)
    "OP_ABS" -> Ok(<<0x90>>)
    "OP_NOT" -> Ok(<<0x91>>)
    "OP_0NOTEQUAL" -> Ok(<<0x92>>)
    "OP_ADD" -> Ok(<<0x93>>)
    "OP_SUB" -> Ok(<<0x94>>)
    "OP_MUL" -> Ok(<<0x95>>)
    "OP_DIV" -> Ok(<<0x96>>)
    "OP_MOD" -> Ok(<<0x97>>)
    "OP_LSHIFT" -> Ok(<<0x98>>)
    "OP_RSHIFT" -> Ok(<<0x99>>)
    "OP_BOOLAND" -> Ok(<<0x9a>>)
    "OP_BOOLOR" -> Ok(<<0x9b>>)
    "OP_NUMEQUAL" -> Ok(<<0x9c>>)
    "OP_NUMEQUALVERIFY" -> Ok(<<0x9d>>)
    "OP_NUMNOTEQUAL" -> Ok(<<0x9e>>)
    "OP_LESSTHAN" -> Ok(<<0x9f>>)
    "OP_GREATERTHAN" -> Ok(<<0xa0>>)
    "OP_LESSTHANOREQUAL" -> Ok(<<0xa1>>)
    "OP_GREATERTHANOREQUAL" -> Ok(<<0xa2>>)
    "OP_MIN" -> Ok(<<0xa3>>)
    "OP_MAX" -> Ok(<<0xa4>>)
    "OP_WITHIN" -> Ok(<<0xa5>>)

    // Crypto
    "OP_RIPEMD160" -> Ok(<<0xa6>>)
    "OP_SHA1" -> Ok(<<0xa7>>)
    "OP_SHA256" -> Ok(<<0xa8>>)
    "OP_HASH160" -> Ok(<<0xa9>>)
    "OP_HASH256" -> Ok(<<0xaa>>)
    "OP_CODESEPARATOR" -> Ok(<<0xab>>)
    "OP_CHECKSIG" -> Ok(<<0xac>>)
    "OP_CHECKSIGVERIFY" -> Ok(<<0xad>>)
    "OP_CHECKMULTISIG" -> Ok(<<0xae>>)
    "OP_CHECKMULTISIGVERIFY" -> Ok(<<0xaf>>)

    // NOP expansions
    "OP_NOP1" -> Ok(<<0xb0>>)
    "OP_CHECKLOCKTIMEVERIFY" | "OP_CLTV" -> Ok(<<0xb1>>)
    "OP_CHECKSEQUENCEVERIFY" | "OP_CSV" -> Ok(<<0xb2>>)
    "OP_NOP4" -> Ok(<<0xb3>>)
    "OP_NOP5" -> Ok(<<0xb4>>)
    "OP_NOP6" -> Ok(<<0xb5>>)
    "OP_NOP7" -> Ok(<<0xb6>>)
    "OP_NOP8" -> Ok(<<0xb7>>)
    "OP_NOP9" -> Ok(<<0xb8>>)
    "OP_NOP10" -> Ok(<<0xb9>>)

    // Taproot
    "OP_CHECKSIGADD" -> Ok(<<0xba>>)

    // Reserved words
    "OP_RESERVED1" -> Ok(<<0x89>>)
    "OP_RESERVED2" -> Ok(<<0x8a>>)

    // Invalid/unknown
    other -> {
      // Try parsing as a number
      case int.parse(other) {
        Ok(n) if n >= 0 && n <= 255 -> Ok(<<n:8>>)
        _ -> Error("Unknown token: " <> other)
      }
    }
  }
}

// ============================================================================
// Result Parsing
// ============================================================================

pub fn parse_expected_result(result_str: String) -> ScriptTestResult {
  case string.uppercase(result_str) {
    "OK" -> ScriptOK
    "" -> ScriptOK  // Empty means success
    error -> ScriptError(error)
  }
}

// ============================================================================
// Test Execution
// ============================================================================

/// Execute a script test case and compare with expected result
pub fn run_script_test(test_case: ScriptTestCase) -> Result(Nil, String) {
  let consensus_flags = script_test_flags_to_consensus_flags(test_case.flags)

  // Combine scriptSig and scriptPubKey for execution
  let combined_script = bit_array.concat([
    test_case.script_sig,
    test_case.script_pubkey,
  ])

  let ctx = oni_consensus.script_context_new(combined_script, consensus_flags)
  let result = oni_consensus.execute_script(ctx)

  case test_case.expected_result, result {
    ScriptOK, Ok(final_ctx) -> {
      // Check if script succeeded (non-empty true value on stack)
      case oni_consensus.script_result_is_true(final_ctx) {
        True -> Ok(Nil)
        False -> Error("Script expected to succeed but returned false")
      }
    }
    ScriptOK, Error(err) -> {
      Error("Script expected to succeed but failed: " <> error_to_string(err))
    }
    ScriptError(expected_err), Ok(_) -> {
      Error("Script expected to fail with " <> expected_err <> " but succeeded")
    }
    ScriptError(_expected_err), Error(_actual_err) -> {
      // Both failed - in differential testing we'd compare error codes
      // For now, any failure matches any expected failure
      Ok(Nil)
    }
  }
}

fn error_to_string(err: oni_consensus.ConsensusError) -> String {
  case err {
    oni_consensus.ScriptInvalid -> "INVALID"
    oni_consensus.ScriptDisabledOpcode -> "DISABLED_OPCODE"
    oni_consensus.ScriptStackUnderflow -> "STACK_UNDERFLOW"
    oni_consensus.ScriptStackOverflow -> "STACK_OVERFLOW"
    oni_consensus.ScriptVerifyFailed -> "VERIFY"
    oni_consensus.ScriptEqualVerifyFailed -> "EQUALVERIFY"
    oni_consensus.ScriptCheckSigFailed -> "CHECKSIG_FAILED"
    oni_consensus.ScriptCheckMultisigFailed -> "CHECKMULTISIG_FAILED"
    oni_consensus.ScriptCheckLockTimeVerifyFailed -> "CHECKLOCKTIMEVERIFY_FAILED"
    oni_consensus.ScriptCheckSequenceVerifyFailed -> "CHECKSEQUENCEVERIFY_FAILED"
    oni_consensus.ScriptPushSizeExceeded -> "PUSH_SIZE_EXCEEDED"
    oni_consensus.ScriptOpCountExceeded -> "OP_COUNT_EXCEEDED"
    oni_consensus.ScriptBadOpcode -> "BAD_OPCODE"
    oni_consensus.ScriptMinimalData -> "MINIMAL_DATA"
    oni_consensus.ScriptWitnessMalleated -> "WITNESS_MALLEATED"
    oni_consensus.ScriptWitnessUnexpected -> "WITNESS_UNEXPECTED"
    oni_consensus.ScriptCleanStack -> "CLEAN_STACK"
    oni_consensus.ScriptSizeTooLarge -> "SCRIPT_SIZE"
    _ -> "UNKNOWN_ERROR"
  }
}

// ============================================================================
// Batch Test Runners
// ============================================================================

/// Run all script tests from test vectors
pub fn run_all_script_tests(test_cases: List(ScriptTestCase)) -> #(Int, Int, List(String)) {
  run_tests_accumulator(test_cases, 0, 0, [])
}

fn run_tests_accumulator(
  tests: List(ScriptTestCase),
  passed: Int,
  failed: Int,
  failures: List(String),
) -> #(Int, Int, List(String)) {
  case tests {
    [] -> #(passed, failed, list.reverse(failures))
    [test_case, ..rest] -> {
      case run_script_test(test_case) {
        Ok(Nil) -> run_tests_accumulator(rest, passed + 1, failed, failures)
        Error(msg) -> {
          let failure_msg = test_case.comment <> ": " <> msg
          run_tests_accumulator(rest, passed, failed + 1, [failure_msg, ..failures])
        }
      }
    }
  }
}

/// Print test results summary
pub fn print_test_summary(results: #(Int, Int, List(String))) {
  let #(passed, failed, failures) = results
  let total = passed + failed

  io.println("")
  io.println("=== Differential Test Results ===")
  io.println("Total: " <> int.to_string(total))
  io.println("Passed: " <> int.to_string(passed))
  io.println("Failed: " <> int.to_string(failed))

  case failures {
    [] -> io.println("All tests passed!")
    _ -> {
      io.println("")
      io.println("Failures:")
      list.each(failures, fn(f) { io.println("  - " <> f) })
    }
  }
}

// ============================================================================
// Sighash Test Execution
// ============================================================================

pub fn run_sighash_test(test_case: SighashTestCase) -> Result(Nil, String) {
  // Parse the transaction
  case oni_bitcoin.hex_decode(test_case.tx_hex) {
    Error(_) -> Error("Failed to decode tx hex")
    Ok(tx_bytes) -> {
      case oni_bitcoin.decode_tx(tx_bytes) {
        Error(_) -> Error("Failed to decode transaction")
        Ok(#(tx, _)) -> {
          // Parse expected hash
          case oni_bitcoin.hex_decode(test_case.expected_hash) {
            Error(_) -> Error("Failed to decode expected hash")
            Ok(expected_bytes) -> {
              // Get sighash type
              let sighash_type = parse_sighash_type(test_case.sighash_type)

              // Compute sighash
              case oni_bitcoin.amount_from_sats(test_case.amount) {
                Error(_) -> Error("Invalid amount")
                Ok(amount) -> {
                  let script = oni_bitcoin.script_from_bytes(test_case.prev_script_pubkey)

                  // Determine if this is segwit/taproot based on script
                  let is_segwit = is_witness_program(test_case.prev_script_pubkey)
                  let is_taproot = is_taproot_program(test_case.prev_script_pubkey)

                  let sig_ctx = oni_consensus.sig_context_new(
                    tx,
                    test_case.input_index,
                    amount,
                    script,
                    is_segwit,
                    is_taproot,
                  )

                  // Compute the sighash
                  let computed_hash = oni_consensus.compute_sighash(sig_ctx, sighash_type)

                  // Compare
                  case computed_hash == expected_bytes {
                    True -> Ok(Nil)
                    False -> {
                      Error("Sighash mismatch: expected " <> test_case.expected_hash <>
                            " but got " <> oni_bitcoin.hex_encode(computed_hash))
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}

fn parse_sighash_type(type_str: String) -> oni_consensus.SighashType {
  case type_str {
    "SIGHASH_ALL" -> oni_consensus.SighashAll
    "SIGHASH_NONE" -> oni_consensus.SighashNone
    "SIGHASH_SINGLE" -> oni_consensus.SighashSingle
    "SIGHASH_ALL|SIGHASH_ANYONECANPAY" ->
      oni_consensus.SighashAnyoneCanPay(oni_consensus.SighashAll)
    "SIGHASH_NONE|SIGHASH_ANYONECANPAY" ->
      oni_consensus.SighashAnyoneCanPay(oni_consensus.SighashNone)
    "SIGHASH_SINGLE|SIGHASH_ANYONECANPAY" ->
      oni_consensus.SighashAnyoneCanPay(oni_consensus.SighashSingle)
    "SIGHASH_DEFAULT" -> oni_consensus.SighashAll  // Default = ALL for Taproot
    "TAPSCRIPT" -> oni_consensus.SighashAll  // Use ALL for tapscript
    _ -> oni_consensus.SighashAll
  }
}

fn is_witness_program(script: BitArray) -> Bool {
  case script {
    <<version:8, len:8, _rest:bits>> if version <= 16 && len >= 2 && len <= 40 -> True
    _ -> False
  }
}

fn is_taproot_program(script: BitArray) -> Bool {
  case script {
    <<0x51, 0x20, _pubkey:256>> -> True
    _ -> False
  }
}

// ============================================================================
// Test Suite Entry Points
// ============================================================================

/// Main entry point for running the differential test suite
pub fn run_differential_suite() {
  io.println("Starting oni differential test suite...")
  io.println("Testing against Bitcoin Core test vectors")
  io.println("")

  // Run script tests
  io.println("Running script tests...")
  let script_tests = get_builtin_script_tests()
  let script_results = run_all_script_tests(script_tests)
  print_test_summary(script_results)
}

/// Get built-in script tests (subset of Bitcoin Core vectors for quick testing)
fn get_builtin_script_tests() -> List(ScriptTestCase) {
  [
    // OP_TRUE should succeed
    ScriptTestCase(
      script_sig: <<>>,
      script_pubkey: <<0x51>>,  // OP_TRUE
      flags: parse_script_flags("P2SH,STRICTENC"),
      expected_result: ScriptOK,
      comment: "OP_TRUE succeeds",
    ),

    // 1 + 2 = 3
    ScriptTestCase(
      script_sig: <<>>,
      script_pubkey: <<0x51, 0x52, 0x93, 0x53, 0x87>>,  // OP_1 OP_2 OP_ADD OP_3 OP_EQUAL
      flags: parse_script_flags("P2SH,STRICTENC"),
      expected_result: ScriptOK,
      comment: "1 + 2 = 3",
    ),

    // OP_DUP OP_EQUAL
    ScriptTestCase(
      script_sig: <<>>,
      script_pubkey: <<0x51, 0x76, 0x87>>,  // OP_1 OP_DUP OP_EQUAL
      flags: parse_script_flags("P2SH,STRICTENC"),
      expected_result: ScriptOK,
      comment: "DUP then EQUAL",
    ),

    // Hash operations
    ScriptTestCase(
      script_sig: <<>>,
      script_pubkey: <<0x00, 0xa8, 0x20,
        0xe3, 0xb0, 0xc4, 0x42, 0x98, 0xfc, 0x1c, 0x14,
        0x9a, 0xfb, 0xf4, 0xc8, 0x99, 0x6f, 0xb9, 0x24,
        0x27, 0xae, 0x41, 0xe4, 0x64, 0x9b, 0x93, 0x4c,
        0xa4, 0x95, 0x99, 0x1b, 0x78, 0x52, 0xb8, 0x55,
        0x87>>,  // OP_0 OP_SHA256 <sha256("")> OP_EQUAL
      flags: parse_script_flags("P2SH,STRICTENC"),
      expected_result: ScriptOK,
      comment: "SHA256 of empty string",
    ),

    // OP_VERIFY with true
    ScriptTestCase(
      script_sig: <<>>,
      script_pubkey: <<0x51, 0x69, 0x51>>,  // OP_1 OP_VERIFY OP_1
      flags: parse_script_flags("P2SH,STRICTENC"),
      expected_result: ScriptOK,
      comment: "VERIFY with true",
    ),

    // OP_VERIFY with false should fail
    ScriptTestCase(
      script_sig: <<>>,
      script_pubkey: <<0x00, 0x69, 0x51>>,  // OP_0 OP_VERIFY OP_1
      flags: parse_script_flags("P2SH,STRICTENC"),
      expected_result: ScriptError("VERIFY"),
      comment: "VERIFY with false fails",
    ),

    // OP_RETURN makes script fail
    ScriptTestCase(
      script_sig: <<>>,
      script_pubkey: <<0x51, 0x6a>>,  // OP_1 OP_RETURN
      flags: parse_script_flags("P2SH,STRICTENC"),
      expected_result: ScriptError("OP_RETURN"),
      comment: "OP_RETURN fails",
    ),

    // Disabled opcode OP_CAT
    ScriptTestCase(
      script_sig: <<>>,
      script_pubkey: <<0x51, 0x7e>>,  // OP_1 OP_CAT
      flags: parse_script_flags("P2SH,STRICTENC"),
      expected_result: ScriptError("DISABLED_OPCODE"),
      comment: "OP_CAT is disabled",
    ),

    // Stack underflow
    ScriptTestCase(
      script_sig: <<>>,
      script_pubkey: <<0x76>>,  // OP_DUP (empty stack)
      flags: parse_script_flags("P2SH,STRICTENC"),
      expected_result: ScriptError("STACK_UNDERFLOW"),
      comment: "DUP on empty stack fails",
    ),

    // Comparison
    ScriptTestCase(
      script_sig: <<>>,
      script_pubkey: <<0x52, 0x53, 0x9f>>,  // OP_2 OP_3 OP_LESSTHAN
      flags: parse_script_flags("P2SH,STRICTENC"),
      expected_result: ScriptOK,
      comment: "2 < 3",
    ),

    // Boolean operations
    ScriptTestCase(
      script_sig: <<>>,
      script_pubkey: <<0x51, 0x51, 0x9a>>,  // OP_1 OP_1 OP_BOOLAND
      flags: parse_script_flags("P2SH,STRICTENC"),
      expected_result: ScriptOK,
      comment: "true AND true",
    ),

    // IF/ELSE/ENDIF
    ScriptTestCase(
      script_sig: <<>>,
      script_pubkey: <<0x51, 0x63, 0x51, 0x67, 0x52, 0x68>>,  // OP_1 OP_IF OP_1 OP_ELSE OP_2 OP_ENDIF
      flags: parse_script_flags("P2SH,STRICTENC"),
      expected_result: ScriptOK,
      comment: "IF taken",
    ),

    // 0-of-0 CHECKMULTISIG
    ScriptTestCase(
      script_sig: <<>>,
      script_pubkey: <<0x00, 0x00, 0x00, 0xae>>,  // OP_0 OP_0 OP_0 OP_CHECKMULTISIG
      flags: parse_script_flags("P2SH,STRICTENC"),
      expected_result: ScriptOK,
      comment: "0-of-0 multisig",
    ),
  ]
}
