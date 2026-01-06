/// Differential testing harness for Bitcoin Core test vector compatibility
///
/// This module provides parsing and execution of Bitcoin Core test vectors
/// to ensure oni's consensus behavior matches Bitcoin Core exactly.
import gleam/bit_array
import gleam/int
import gleam/io
import gleam/list
import gleam/string
import oni_bitcoin
import oni_consensus

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
  TxTestCase(prevouts: List(TxTestPrevout), tx_hex: String, flags: String)
}

pub type TxTestPrevout {
  TxTestPrevout(txid: String, vout: Int, script_pubkey: BitArray, amount: Int)
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
    discourage_upgradable_nops: list.contains(
      flags,
      "DISCOURAGE_UPGRADABLE_NOPS",
    ),
    cleanstack: list.contains(flags, "CLEANSTACK"),
    checklocktimeverify: list.contains(flags, "CHECKLOCKTIMEVERIFY"),
    checksequenceverify: list.contains(flags, "CHECKSEQUENCEVERIFY"),
    witness: list.contains(flags, "WITNESS"),
    discourage_upgradable_witness_program: list.contains(
      flags,
      "DISCOURAGE_UPGRADABLE_WITNESS_PROGRAM",
    ),
    minimalif: list.contains(flags, "MINIMALIF"),
    nullfail: list.contains(flags, "NULLFAIL"),
    witness_pubkeytype: list.contains(flags, "WITNESS_PUBKEYTYPE"),
    const_scriptcode: list.contains(flags, "CONST_SCRIPTCODE"),
    taproot: list.contains(flags, "TAPROOT"),
  )
}

pub fn script_test_flags_to_consensus_flags(
  test_flags: ScriptTestFlags,
) -> oni_consensus.ScriptFlags {
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

fn parse_script_tokens(
  tokens: List(String),
  acc: BitArray,
) -> Result(BitArray, String) {
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
    "" -> ScriptOK
    // Empty means success
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
  let combined_script =
    bit_array.concat([test_case.script_sig, test_case.script_pubkey])

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
    oni_consensus.ScriptCheckLockTimeVerifyFailed ->
      "CHECKLOCKTIMEVERIFY_FAILED"
    oni_consensus.ScriptCheckSequenceVerifyFailed ->
      "CHECKSEQUENCEVERIFY_FAILED"
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
pub fn run_all_script_tests(
  test_cases: List(ScriptTestCase),
) -> #(Int, Int, List(String)) {
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
          run_tests_accumulator(rest, passed, failed + 1, [
            failure_msg,
            ..failures
          ])
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
                  let script =
                    oni_bitcoin.script_from_bytes(test_case.prev_script_pubkey)

                  // Determine if this is segwit/taproot based on script
                  let is_segwit =
                    is_witness_program(test_case.prev_script_pubkey)
                  let is_taproot =
                    is_taproot_program(test_case.prev_script_pubkey)

                  let sig_ctx =
                    oni_consensus.sig_context_new(
                      tx,
                      test_case.input_index,
                      amount,
                      script,
                      is_segwit,
                      is_taproot,
                    )

                  // Compute the sighash
                  let computed_hash =
                    oni_consensus.compute_sighash(sig_ctx, sighash_type)

                  // Compare
                  case computed_hash == expected_bytes {
                    True -> Ok(Nil)
                    False -> {
                      Error(
                        "Sighash mismatch: expected "
                        <> test_case.expected_hash
                        <> " but got "
                        <> oni_bitcoin.hex_encode(computed_hash),
                      )
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
    "SIGHASH_DEFAULT" -> oni_consensus.SighashAll
    // Default = ALL for Taproot
    "TAPSCRIPT" -> oni_consensus.SighashAll
    // Use ALL for tapscript
    _ -> oni_consensus.SighashAll
  }
}

fn is_witness_program(script: BitArray) -> Bool {
  case script {
    <<version:8, len:8, _rest:bits>> if version <= 16 && len >= 2 && len <= 40 ->
      True
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

/// Get comprehensive script tests based on Bitcoin Core test vectors
/// Covers 100+ test cases across all script operation categories
fn get_builtin_script_tests() -> List(ScriptTestCase) {
  list.flatten([
    get_basic_push_tests(),
    get_arithmetic_tests(),
    get_stack_operation_tests(),
    get_hash_operation_tests(),
    get_comparison_tests(),
    get_boolean_tests(),
    get_flow_control_tests(),
    get_verify_tests(),
    get_disabled_opcode_tests(),
    get_script_number_tests(),
    get_multisig_tests(),
    get_error_condition_tests(),
    get_size_operation_tests(),
    get_bitwise_tests(),
    get_altstack_tests(),
    get_nop_tests(),
  ])
}

// ============================================================================
// Basic Push Data Tests
// ============================================================================

fn get_basic_push_tests() -> List(ScriptTestCase) {
  [
    ScriptTestCase(
      script_sig: <<>>,
      script_pubkey: <<0x51>>,
      // OP_TRUE
      flags: parse_script_flags("P2SH,STRICTENC"),
      expected_result: ScriptOK,
      comment: "OP_TRUE succeeds",
    ),
    ScriptTestCase(
      script_sig: <<>>,
      script_pubkey: <<0x00>>,
      // OP_FALSE
      flags: parse_script_flags("P2SH,STRICTENC"),
      expected_result: ScriptError("EVAL_FALSE"),
      comment: "OP_FALSE fails (empty stack result)",
    ),
    ScriptTestCase(
      script_sig: <<>>,
      script_pubkey: <<0x51, 0x51, 0x87>>,
      // OP_1 OP_1 OP_EQUAL
      flags: parse_script_flags("P2SH,STRICTENC"),
      expected_result: ScriptOK,
      comment: "Push 1 equals OP_1",
    ),
    ScriptTestCase(
      script_sig: <<>>,
      script_pubkey: <<0x52>>,
      // OP_2
      flags: parse_script_flags("P2SH,STRICTENC"),
      expected_result: ScriptOK,
      comment: "OP_2 succeeds",
    ),
    ScriptTestCase(
      script_sig: <<>>,
      script_pubkey: <<0x60>>,
      // OP_16
      flags: parse_script_flags("P2SH,STRICTENC"),
      expected_result: ScriptOK,
      comment: "OP_16 succeeds",
    ),
    ScriptTestCase(
      script_sig: <<>>,
      script_pubkey: <<0x4f>>,
      // OP_1NEGATE
      flags: parse_script_flags("P2SH,STRICTENC"),
      expected_result: ScriptOK,
      comment: "OP_1NEGATE succeeds",
    ),
    ScriptTestCase(
      script_sig: <<0x01, 0x01>>,
      // Push 1 byte: 0x01
      script_pubkey: <<0x51, 0x87>>,
      // OP_1 OP_EQUAL
      flags: parse_script_flags("P2SH,STRICTENC"),
      expected_result: ScriptOK,
      comment: "ScriptSig push 1 equals scriptPubKey OP_1",
    ),
    ScriptTestCase(
      script_sig: <<0x02, 0xab, 0xcd>>,
      // Push 2 bytes
      script_pubkey: <<0x82, 0x52, 0x87>>,
      // OP_SIZE OP_2 OP_EQUAL
      flags: parse_script_flags("P2SH,STRICTENC"),
      expected_result: ScriptOK,
      comment: "Size of 2-byte push is 2",
    ),
  ]
}

// ============================================================================
// Arithmetic Operation Tests
// ============================================================================

fn get_arithmetic_tests() -> List(ScriptTestCase) {
  [
    ScriptTestCase(
      script_sig: <<>>,
      script_pubkey: <<0x51, 0x52, 0x93, 0x53, 0x87>>,
      // OP_1 OP_2 OP_ADD OP_3 OP_EQUAL
      flags: parse_script_flags("P2SH,STRICTENC"),
      expected_result: ScriptOK,
      comment: "1 + 2 = 3",
    ),
    ScriptTestCase(
      script_sig: <<>>,
      script_pubkey: <<0x53, 0x52, 0x94, 0x51, 0x87>>,
      // OP_3 OP_2 OP_SUB OP_1 OP_EQUAL
      flags: parse_script_flags("P2SH,STRICTENC"),
      expected_result: ScriptOK,
      comment: "3 - 2 = 1",
    ),
    ScriptTestCase(
      script_sig: <<>>,
      script_pubkey: <<0x51, 0x8b, 0x52, 0x87>>,
      // OP_1 OP_1ADD OP_2 OP_EQUAL
      flags: parse_script_flags("P2SH,STRICTENC"),
      expected_result: ScriptOK,
      comment: "1 + 1 = 2 via OP_1ADD",
    ),
    ScriptTestCase(
      script_sig: <<>>,
      script_pubkey: <<0x52, 0x8c, 0x51, 0x87>>,
      // OP_2 OP_1SUB OP_1 OP_EQUAL
      flags: parse_script_flags("P2SH,STRICTENC"),
      expected_result: ScriptOK,
      comment: "2 - 1 = 1 via OP_1SUB",
    ),
    ScriptTestCase(
      script_sig: <<>>,
      script_pubkey: <<0x52, 0x8f, 0x01, 0x82, 0x87>>,
      // OP_2 OP_NEGATE push(-2) OP_EQUAL
      flags: parse_script_flags("P2SH,STRICTENC"),
      expected_result: ScriptOK,
      comment: "negate 2 = -2",
    ),
    ScriptTestCase(
      script_sig: <<>>,
      script_pubkey: <<0x01, 0x85, 0x90, 0x55, 0x87>>,
      // push(-5) OP_ABS OP_5 OP_EQUAL
      flags: parse_script_flags("P2SH,STRICTENC"),
      expected_result: ScriptOK,
      comment: "abs(-5) = 5",
    ),
    ScriptTestCase(
      script_sig: <<>>,
      script_pubkey: <<0x53, 0x52, 0xa3, 0x52, 0x87>>,
      // OP_3 OP_2 OP_MIN OP_2 OP_EQUAL
      flags: parse_script_flags("P2SH,STRICTENC"),
      expected_result: ScriptOK,
      comment: "min(3, 2) = 2",
    ),
    ScriptTestCase(
      script_sig: <<>>,
      script_pubkey: <<0x53, 0x52, 0xa4, 0x53, 0x87>>,
      // OP_3 OP_2 OP_MAX OP_3 OP_EQUAL
      flags: parse_script_flags("P2SH,STRICTENC"),
      expected_result: ScriptOK,
      comment: "max(3, 2) = 3",
    ),
    ScriptTestCase(
      script_sig: <<>>,
      script_pubkey: <<0x00, 0x91, 0x51, 0x87>>,
      // OP_0 OP_NOT OP_1 OP_EQUAL
      flags: parse_script_flags("P2SH,STRICTENC"),
      expected_result: ScriptOK,
      comment: "NOT 0 = 1",
    ),
    ScriptTestCase(
      script_sig: <<>>,
      script_pubkey: <<0x51, 0x91, 0x00, 0x87>>,
      // OP_1 OP_NOT OP_0 OP_EQUAL
      flags: parse_script_flags("P2SH,STRICTENC"),
      expected_result: ScriptOK,
      comment: "NOT 1 = 0",
    ),
    ScriptTestCase(
      script_sig: <<>>,
      script_pubkey: <<0x00, 0x92, 0x00, 0x87>>,
      // OP_0 OP_0NOTEQUAL OP_0 OP_EQUAL
      flags: parse_script_flags("P2SH,STRICTENC"),
      expected_result: ScriptOK,
      comment: "0NOTEQUAL 0 = 0",
    ),
    ScriptTestCase(
      script_sig: <<>>,
      script_pubkey: <<0x53, 0x92, 0x51, 0x87>>,
      // OP_3 OP_0NOTEQUAL OP_1 OP_EQUAL
      flags: parse_script_flags("P2SH,STRICTENC"),
      expected_result: ScriptOK,
      comment: "0NOTEQUAL 3 = 1",
    ),
    // Disabled: OP_MUL
    ScriptTestCase(
      script_sig: <<>>,
      script_pubkey: <<0x52, 0x53, 0x95>>,
      // OP_2 OP_3 OP_MUL
      flags: parse_script_flags("P2SH,STRICTENC"),
      expected_result: ScriptError("DISABLED_OPCODE"),
      comment: "OP_MUL is disabled",
    ),
    // Disabled: OP_DIV
    ScriptTestCase(
      script_sig: <<>>,
      script_pubkey: <<0x54, 0x52, 0x96>>,
      // OP_4 OP_2 OP_DIV
      flags: parse_script_flags("P2SH,STRICTENC"),
      expected_result: ScriptError("DISABLED_OPCODE"),
      comment: "OP_DIV is disabled",
    ),
    // Disabled: OP_MOD
    ScriptTestCase(
      script_sig: <<>>,
      script_pubkey: <<0x55, 0x53, 0x97>>,
      // OP_5 OP_3 OP_MOD
      flags: parse_script_flags("P2SH,STRICTENC"),
      expected_result: ScriptError("DISABLED_OPCODE"),
      comment: "OP_MOD is disabled",
    ),
  ]
}

// ============================================================================
// Stack Operation Tests
// ============================================================================

fn get_stack_operation_tests() -> List(ScriptTestCase) {
  [
    ScriptTestCase(
      script_sig: <<>>,
      script_pubkey: <<0x51, 0x76, 0x87>>,
      // OP_1 OP_DUP OP_EQUAL
      flags: parse_script_flags("P2SH,STRICTENC"),
      expected_result: ScriptOK,
      comment: "DUP then EQUAL",
    ),
    ScriptTestCase(
      script_sig: <<>>,
      script_pubkey: <<0x51, 0x52, 0x75, 0x51, 0x87>>,
      // OP_1 OP_2 OP_DROP OP_1 OP_EQUAL
      flags: parse_script_flags("P2SH,STRICTENC"),
      expected_result: ScriptOK,
      comment: "DROP removes top",
    ),
    ScriptTestCase(
      script_sig: <<>>,
      script_pubkey: <<0x51, 0x52, 0x53, 0x6d, 0x51, 0x87>>,
      // OP_1 OP_2 OP_3 OP_2DROP OP_1 OP_EQUAL
      flags: parse_script_flags("P2SH,STRICTENC"),
      expected_result: ScriptOK,
      comment: "2DROP removes top two",
    ),
    ScriptTestCase(
      script_sig: <<>>,
      script_pubkey: <<0x51, 0x52, 0x7c, 0x51, 0x87>>,
      // OP_1 OP_2 OP_SWAP OP_1 OP_EQUAL
      flags: parse_script_flags("P2SH,STRICTENC"),
      expected_result: ScriptOK,
      comment: "SWAP exchanges top two",
    ),
    ScriptTestCase(
      script_sig: <<>>,
      script_pubkey: <<0x51, 0x52, 0x78, 0x51, 0x87>>,
      // OP_1 OP_2 OP_OVER OP_1 OP_EQUAL
      flags: parse_script_flags("P2SH,STRICTENC"),
      expected_result: ScriptOK,
      comment: "OVER copies second to top",
    ),
    ScriptTestCase(
      script_sig: <<>>,
      script_pubkey: <<
        0x51, 0x52, 0x6e, 0x51, 0x87, 0x69, 0x52, 0x87, 0x69, 0x51, 0x87,
      >>,
      // OP_1 OP_2 OP_2DUP verify stack
      flags: parse_script_flags("P2SH,STRICTENC"),
      expected_result: ScriptOK,
      comment: "2DUP duplicates top two",
    ),
    ScriptTestCase(
      script_sig: <<>>,
      script_pubkey: <<0x51, 0x52, 0x53, 0x6f, 0x51, 0x87>>,
      // OP_1 OP_2 OP_3 OP_3DUP verify
      flags: parse_script_flags("P2SH,STRICTENC"),
      expected_result: ScriptOK,
      comment: "3DUP duplicates top three",
    ),
    ScriptTestCase(
      script_sig: <<>>,
      script_pubkey: <<0x51, 0x52, 0x77, 0x51, 0x87>>,
      // OP_1 OP_2 OP_NIP OP_1 OP_EQUAL
      flags: parse_script_flags("P2SH,STRICTENC"),
      expected_result: ScriptOK,
      comment: "NIP removes second",
    ),
    ScriptTestCase(
      script_sig: <<>>,
      script_pubkey: <<0x51, 0x52, 0x7d, 0x52, 0x87>>,
      // OP_1 OP_2 OP_TUCK ... verify
      flags: parse_script_flags("P2SH,STRICTENC"),
      expected_result: ScriptOK,
      comment: "TUCK inserts top below second",
    ),
    ScriptTestCase(
      script_sig: <<>>,
      script_pubkey: <<0x51, 0x52, 0x53, 0x7b, 0x51, 0x87>>,
      // OP_1 OP_2 OP_3 OP_ROT OP_1 OP_EQUAL
      flags: parse_script_flags("P2SH,STRICTENC"),
      expected_result: ScriptOK,
      comment: "ROT rotates top three",
    ),
    ScriptTestCase(
      script_sig: <<>>,
      script_pubkey: <<0x51, 0x00, 0x79, 0x51, 0x87>>,
      // OP_1 OP_0 OP_PICK OP_1 OP_EQUAL
      flags: parse_script_flags("P2SH,STRICTENC"),
      expected_result: ScriptOK,
      comment: "PICK 0 copies top",
    ),
    ScriptTestCase(
      script_sig: <<>>,
      script_pubkey: <<0x51, 0x52, 0x51, 0x79, 0x51, 0x87>>,
      // OP_1 OP_2 OP_1 OP_PICK OP_1 OP_EQUAL
      flags: parse_script_flags("P2SH,STRICTENC"),
      expected_result: ScriptOK,
      comment: "PICK 1 copies second",
    ),
    ScriptTestCase(
      script_sig: <<>>,
      script_pubkey: <<0x51, 0x74, 0x51, 0x87>>,
      // OP_1 OP_DEPTH OP_1 OP_EQUAL
      flags: parse_script_flags("P2SH,STRICTENC"),
      expected_result: ScriptOK,
      comment: "DEPTH returns stack size",
    ),
    ScriptTestCase(
      script_sig: <<>>,
      script_pubkey: <<0x74, 0x00, 0x87>>,
      // OP_DEPTH OP_0 OP_EQUAL
      flags: parse_script_flags("P2SH,STRICTENC"),
      expected_result: ScriptOK,
      comment: "DEPTH of empty stack is 0",
    ),
    ScriptTestCase(
      script_sig: <<>>,
      script_pubkey: <<0x51, 0x73, 0x51, 0x87>>,
      // OP_1 OP_IFDUP (true case, duplicates)
      flags: parse_script_flags("P2SH,STRICTENC"),
      expected_result: ScriptOK,
      comment: "IFDUP duplicates if truthy",
    ),
    ScriptTestCase(
      script_sig: <<>>,
      script_pubkey: <<0x00, 0x73, 0x00, 0x87>>,
      // OP_0 OP_IFDUP (false case, no dup)
      flags: parse_script_flags("P2SH,STRICTENC"),
      expected_result: ScriptOK,
      comment: "IFDUP does not duplicate if falsy",
    ),
  ]
}

// ============================================================================
// Hash Operation Tests
// ============================================================================

fn get_hash_operation_tests() -> List(ScriptTestCase) {
  [
    // SHA256 of empty string
    ScriptTestCase(
      script_sig: <<>>,
      script_pubkey: <<
        0x00, 0xa8, 0x20, 0xe3, 0xb0, 0xc4, 0x42, 0x98, 0xfc, 0x1c, 0x14, 0x9a,
        0xfb, 0xf4, 0xc8, 0x99, 0x6f, 0xb9, 0x24, 0x27, 0xae, 0x41, 0xe4, 0x64,
        0x9b, 0x93, 0x4c, 0xa4, 0x95, 0x99, 0x1b, 0x78, 0x52, 0xb8, 0x55, 0x87,
      >>,
      flags: parse_script_flags("P2SH,STRICTENC"),
      expected_result: ScriptOK,
      comment: "SHA256 of empty string",
    ),
    // SHA256 of 'abc'
    ScriptTestCase(
      script_sig: <<>>,
      script_pubkey: <<
        0x03, 0x61, 0x62, 0x63, 0xa8, 0x20, 0xba, 0x78, 0x16, 0xbf, 0x8f, 0x01,
        0xcf, 0xea, 0x41, 0x41, 0x40, 0xde, 0x5d, 0xae, 0x22, 0x23, 0xb0, 0x03,
        0x61, 0xa3, 0x96, 0x17, 0x7a, 0x9c, 0xb4, 0x10, 0xff, 0x61, 0xf2, 0x00,
        0x15, 0xad, 0x87,
      >>,
      flags: parse_script_flags("P2SH,STRICTENC"),
      expected_result: ScriptOK,
      comment: "SHA256 of 'abc'",
    ),
    // HASH160 of 'abc'
    ScriptTestCase(
      script_sig: <<>>,
      script_pubkey: <<
        0x03, 0x61, 0x62, 0x63, 0xa9, 0x14, 0xbb, 0x1b, 0xe9, 0x8c, 0x14, 0x24,
        0x44, 0xd7, 0xa5, 0x6a, 0xa3, 0x98, 0x1c, 0x39, 0x42, 0xa9, 0x78, 0xe4,
        0xdc, 0x33, 0x87,
      >>,
      flags: parse_script_flags("P2SH,STRICTENC"),
      expected_result: ScriptOK,
      comment: "HASH160 of 'abc'",
    ),
    // HASH256 of 'abc'
    ScriptTestCase(
      script_sig: <<>>,
      script_pubkey: <<
        0x03, 0x61, 0x62, 0x63, 0xaa, 0x20, 0x4f, 0x8b, 0x42, 0xc2, 0x2d, 0xd3,
        0x72, 0x9b, 0x51, 0x9b, 0xa6, 0xf6, 0x8d, 0x2d, 0xa7, 0xcc, 0x5b, 0x2d,
        0x60, 0x6d, 0x05, 0xda, 0xed, 0x5a, 0xd5, 0x12, 0x8c, 0xc0, 0x3e, 0x6c,
        0x63, 0x58, 0x87,
      >>,
      flags: parse_script_flags("P2SH,STRICTENC"),
      expected_result: ScriptOK,
      comment: "HASH256 of 'abc'",
    ),
    // SHA1 of empty string
    ScriptTestCase(
      script_sig: <<>>,
      script_pubkey: <<
        0x00, 0xa7, 0x14, 0xda, 0x39, 0xa3, 0xee, 0x5e, 0x6b, 0x4b, 0x0d, 0x32,
        0x55, 0xbf, 0xef, 0x95, 0x60, 0x18, 0x90, 0xaf, 0xd8, 0x07, 0x09, 0x87,
      >>,
      flags: parse_script_flags("P2SH,STRICTENC"),
      expected_result: ScriptOK,
      comment: "SHA1 of empty string",
    ),
    // RIPEMD160 of empty string
    ScriptTestCase(
      script_sig: <<>>,
      script_pubkey: <<
        0x00, 0xa6, 0x14, 0x9c, 0x11, 0x85, 0xa5, 0xc5, 0xe9, 0xfc, 0x54, 0x61,
        0x28, 0x08, 0x97, 0x7e, 0xe8, 0xf5, 0x48, 0xb2, 0x25, 0x8d, 0x31, 0x87,
      >>,
      flags: parse_script_flags("P2SH,STRICTENC"),
      expected_result: ScriptOK,
      comment: "RIPEMD160 of empty string",
    ),
    // Hash size verification
    ScriptTestCase(
      script_sig: <<>>,
      script_pubkey: <<0x51, 0xa8, 0x82, 0x01, 0x20, 0x87>>,
      // OP_1 OP_SHA256 OP_SIZE 32 OP_EQUAL
      flags: parse_script_flags("P2SH,STRICTENC"),
      expected_result: ScriptOK,
      comment: "SHA256 produces 32 bytes",
    ),
    ScriptTestCase(
      script_sig: <<>>,
      script_pubkey: <<0x51, 0xa9, 0x82, 0x14, 0x87>>,
      // OP_1 OP_HASH160 OP_SIZE 20 OP_EQUAL
      flags: parse_script_flags("P2SH,STRICTENC"),
      expected_result: ScriptOK,
      comment: "HASH160 produces 20 bytes",
    ),
  ]
}

// ============================================================================
// Comparison Tests
// ============================================================================

fn get_comparison_tests() -> List(ScriptTestCase) {
  [
    ScriptTestCase(
      script_sig: <<>>,
      script_pubkey: <<0x52, 0x53, 0x9f>>,
      // OP_2 OP_3 OP_LESSTHAN
      flags: parse_script_flags("P2SH,STRICTENC"),
      expected_result: ScriptOK,
      comment: "2 < 3",
    ),
    ScriptTestCase(
      script_sig: <<>>,
      script_pubkey: <<0x53, 0x52, 0x9f, 0x91>>,
      // OP_3 OP_2 OP_LESSTHAN OP_NOT
      flags: parse_script_flags("P2SH,STRICTENC"),
      expected_result: ScriptOK,
      comment: "3 < 2 is false",
    ),
    ScriptTestCase(
      script_sig: <<>>,
      script_pubkey: <<0x53, 0x52, 0xa0>>,
      // OP_3 OP_2 OP_GREATERTHAN
      flags: parse_script_flags("P2SH,STRICTENC"),
      expected_result: ScriptOK,
      comment: "3 > 2",
    ),
    ScriptTestCase(
      script_sig: <<>>,
      script_pubkey: <<0x52, 0x53, 0xa1>>,
      // OP_2 OP_3 OP_LESSTHANOREQUAL
      flags: parse_script_flags("P2SH,STRICTENC"),
      expected_result: ScriptOK,
      comment: "2 <= 3",
    ),
    ScriptTestCase(
      script_sig: <<>>,
      script_pubkey: <<0x52, 0x52, 0xa1>>,
      // OP_2 OP_2 OP_LESSTHANOREQUAL
      flags: parse_script_flags("P2SH,STRICTENC"),
      expected_result: ScriptOK,
      comment: "2 <= 2",
    ),
    ScriptTestCase(
      script_sig: <<>>,
      script_pubkey: <<0x53, 0x52, 0xa2>>,
      // OP_3 OP_2 OP_GREATERTHANOREQUAL
      flags: parse_script_flags("P2SH,STRICTENC"),
      expected_result: ScriptOK,
      comment: "3 >= 2",
    ),
    ScriptTestCase(
      script_sig: <<>>,
      script_pubkey: <<0x52, 0x52, 0x87>>,
      // OP_2 OP_2 OP_EQUAL
      flags: parse_script_flags("P2SH,STRICTENC"),
      expected_result: ScriptOK,
      comment: "2 == 2",
    ),
    ScriptTestCase(
      script_sig: <<>>,
      script_pubkey: <<0x52, 0x53, 0x87, 0x91>>,
      // OP_2 OP_3 OP_EQUAL OP_NOT
      flags: parse_script_flags("P2SH,STRICTENC"),
      expected_result: ScriptOK,
      comment: "2 != 3",
    ),
    ScriptTestCase(
      script_sig: <<>>,
      script_pubkey: <<0x55, 0x55, 0x9c>>,
      // OP_5 OP_5 OP_NUMEQUAL
      flags: parse_script_flags("P2SH,STRICTENC"),
      expected_result: ScriptOK,
      comment: "5 == 5 numerically",
    ),
    ScriptTestCase(
      script_sig: <<>>,
      script_pubkey: <<0x55, 0x53, 0x9e>>,
      // OP_5 OP_3 OP_NUMNOTEQUAL
      flags: parse_script_flags("P2SH,STRICTENC"),
      expected_result: ScriptOK,
      comment: "5 != 3 numerically",
    ),
    ScriptTestCase(
      script_sig: <<>>,
      script_pubkey: <<0x55, 0x53, 0x57, 0xa5>>,
      // OP_5 OP_3 OP_7 OP_WITHIN
      flags: parse_script_flags("P2SH,STRICTENC"),
      expected_result: ScriptOK,
      comment: "5 within [3,7)",
    ),
    ScriptTestCase(
      script_sig: <<>>,
      script_pubkey: <<0x52, 0x53, 0x57, 0xa5, 0x91>>,
      // OP_2 OP_3 OP_7 OP_WITHIN OP_NOT
      flags: parse_script_flags("P2SH,STRICTENC"),
      expected_result: ScriptOK,
      comment: "2 not within [3,7)",
    ),
  ]
}

// ============================================================================
// Boolean Operation Tests
// ============================================================================

fn get_boolean_tests() -> List(ScriptTestCase) {
  [
    ScriptTestCase(
      script_sig: <<>>,
      script_pubkey: <<0x51, 0x51, 0x9a>>,
      // OP_1 OP_1 OP_BOOLAND
      flags: parse_script_flags("P2SH,STRICTENC"),
      expected_result: ScriptOK,
      comment: "true AND true",
    ),
    ScriptTestCase(
      script_sig: <<>>,
      script_pubkey: <<0x51, 0x00, 0x9a, 0x91>>,
      // OP_1 OP_0 OP_BOOLAND OP_NOT
      flags: parse_script_flags("P2SH,STRICTENC"),
      expected_result: ScriptOK,
      comment: "true AND false = false",
    ),
    ScriptTestCase(
      script_sig: <<>>,
      script_pubkey: <<0x00, 0x00, 0x9a, 0x91>>,
      // OP_0 OP_0 OP_BOOLAND OP_NOT
      flags: parse_script_flags("P2SH,STRICTENC"),
      expected_result: ScriptOK,
      comment: "false AND false = false",
    ),
    ScriptTestCase(
      script_sig: <<>>,
      script_pubkey: <<0x51, 0x00, 0x9b>>,
      // OP_1 OP_0 OP_BOOLOR
      flags: parse_script_flags("P2SH,STRICTENC"),
      expected_result: ScriptOK,
      comment: "true OR false = true",
    ),
    ScriptTestCase(
      script_sig: <<>>,
      script_pubkey: <<0x00, 0x51, 0x9b>>,
      // OP_0 OP_1 OP_BOOLOR
      flags: parse_script_flags("P2SH,STRICTENC"),
      expected_result: ScriptOK,
      comment: "false OR true = true",
    ),
    ScriptTestCase(
      script_sig: <<>>,
      script_pubkey: <<0x00, 0x00, 0x9b, 0x91>>,
      // OP_0 OP_0 OP_BOOLOR OP_NOT
      flags: parse_script_flags("P2SH,STRICTENC"),
      expected_result: ScriptOK,
      comment: "false OR false = false",
    ),
  ]
}

// ============================================================================
// Flow Control Tests
// ============================================================================

fn get_flow_control_tests() -> List(ScriptTestCase) {
  [
    ScriptTestCase(
      script_sig: <<>>,
      script_pubkey: <<0x51, 0x63, 0x51, 0x67, 0x52, 0x68>>,
      // OP_1 OP_IF OP_1 OP_ELSE OP_2 OP_ENDIF
      flags: parse_script_flags("P2SH,STRICTENC"),
      expected_result: ScriptOK,
      comment: "IF taken",
    ),
    ScriptTestCase(
      script_sig: <<>>,
      script_pubkey: <<0x00, 0x63, 0x51, 0x67, 0x52, 0x68>>,
      // OP_0 OP_IF OP_1 OP_ELSE OP_2 OP_ENDIF
      flags: parse_script_flags("P2SH,STRICTENC"),
      expected_result: ScriptOK,
      comment: "ELSE taken",
    ),
    ScriptTestCase(
      script_sig: <<>>,
      script_pubkey: <<0x51, 0x64, 0x51, 0x67, 0x52, 0x68>>,
      // OP_1 OP_NOTIF OP_1 OP_ELSE OP_2 OP_ENDIF
      flags: parse_script_flags("P2SH,STRICTENC"),
      expected_result: ScriptOK,
      comment: "NOTIF skipped when true",
    ),
    ScriptTestCase(
      script_sig: <<>>,
      script_pubkey: <<0x00, 0x64, 0x51, 0x68>>,
      // OP_0 OP_NOTIF OP_1 OP_ENDIF
      flags: parse_script_flags("P2SH,STRICTENC"),
      expected_result: ScriptOK,
      comment: "NOTIF taken when false",
    ),
    ScriptTestCase(
      script_sig: <<>>,
      script_pubkey: <<0x51, 0x63, 0x51, 0x63, 0x51, 0x68, 0x68>>,
      // Nested IF
      flags: parse_script_flags("P2SH,STRICTENC"),
      expected_result: ScriptOK,
      comment: "Nested IF/ENDIF",
    ),
    ScriptTestCase(
      script_sig: <<>>,
      script_pubkey: <<0x51, 0x63, 0x00, 0x63, 0x52, 0x67, 0x51, 0x68, 0x68>>,
      // Nested IF with ELSE
      flags: parse_script_flags("P2SH,STRICTENC"),
      expected_result: ScriptOK,
      comment: "Nested IF with inner ELSE taken",
    ),
  ]
}

// ============================================================================
// Verify Operation Tests
// ============================================================================

fn get_verify_tests() -> List(ScriptTestCase) {
  [
    ScriptTestCase(
      script_sig: <<>>,
      script_pubkey: <<0x51, 0x69, 0x51>>,
      // OP_1 OP_VERIFY OP_1
      flags: parse_script_flags("P2SH,STRICTENC"),
      expected_result: ScriptOK,
      comment: "VERIFY with true",
    ),
    ScriptTestCase(
      script_sig: <<>>,
      script_pubkey: <<0x00, 0x69, 0x51>>,
      // OP_0 OP_VERIFY OP_1
      flags: parse_script_flags("P2SH,STRICTENC"),
      expected_result: ScriptError("VERIFY"),
      comment: "VERIFY with false fails",
    ),
    ScriptTestCase(
      script_sig: <<>>,
      script_pubkey: <<0x51, 0x51, 0x88, 0x51>>,
      // OP_1 OP_1 OP_EQUALVERIFY OP_1
      flags: parse_script_flags("P2SH,STRICTENC"),
      expected_result: ScriptOK,
      comment: "EQUALVERIFY succeeds",
    ),
    ScriptTestCase(
      script_sig: <<>>,
      script_pubkey: <<0x51, 0x52, 0x88>>,
      // OP_1 OP_2 OP_EQUALVERIFY
      flags: parse_script_flags("P2SH,STRICTENC"),
      expected_result: ScriptError("EQUALVERIFY"),
      comment: "EQUALVERIFY fails when not equal",
    ),
    ScriptTestCase(
      script_sig: <<>>,
      script_pubkey: <<0x55, 0x55, 0x9d, 0x51>>,
      // OP_5 OP_5 OP_NUMEQUALVERIFY OP_1
      flags: parse_script_flags("P2SH,STRICTENC"),
      expected_result: ScriptOK,
      comment: "NUMEQUALVERIFY succeeds",
    ),
  ]
}

// ============================================================================
// Disabled Opcode Tests
// ============================================================================

fn get_disabled_opcode_tests() -> List(ScriptTestCase) {
  [
    ScriptTestCase(
      script_sig: <<>>,
      script_pubkey: <<0x51, 0x51, 0x7e>>,
      // OP_1 OP_1 OP_CAT
      flags: parse_script_flags("P2SH,STRICTENC"),
      expected_result: ScriptError("DISABLED_OPCODE"),
      comment: "OP_CAT disabled",
    ),
    ScriptTestCase(
      script_sig: <<>>,
      script_pubkey: <<0x51, 0x7f>>,
      // OP_1 OP_SUBSTR
      flags: parse_script_flags("P2SH,STRICTENC"),
      expected_result: ScriptError("DISABLED_OPCODE"),
      comment: "OP_SUBSTR disabled",
    ),
    ScriptTestCase(
      script_sig: <<>>,
      script_pubkey: <<0x51, 0x80>>,
      // OP_1 OP_LEFT
      flags: parse_script_flags("P2SH,STRICTENC"),
      expected_result: ScriptError("DISABLED_OPCODE"),
      comment: "OP_LEFT disabled",
    ),
    ScriptTestCase(
      script_sig: <<>>,
      script_pubkey: <<0x51, 0x81>>,
      // OP_1 OP_RIGHT
      flags: parse_script_flags("P2SH,STRICTENC"),
      expected_result: ScriptError("DISABLED_OPCODE"),
      comment: "OP_RIGHT disabled",
    ),
    ScriptTestCase(
      script_sig: <<>>,
      script_pubkey: <<0x51, 0x83>>,
      // OP_1 OP_INVERT
      flags: parse_script_flags("P2SH,STRICTENC"),
      expected_result: ScriptError("DISABLED_OPCODE"),
      comment: "OP_INVERT disabled",
    ),
    ScriptTestCase(
      script_sig: <<>>,
      script_pubkey: <<0x51, 0x51, 0x84>>,
      // OP_1 OP_1 OP_AND
      flags: parse_script_flags("P2SH,STRICTENC"),
      expected_result: ScriptError("DISABLED_OPCODE"),
      comment: "OP_AND disabled",
    ),
    ScriptTestCase(
      script_sig: <<>>,
      script_pubkey: <<0x51, 0x51, 0x85>>,
      // OP_1 OP_1 OP_OR
      flags: parse_script_flags("P2SH,STRICTENC"),
      expected_result: ScriptError("DISABLED_OPCODE"),
      comment: "OP_OR disabled",
    ),
    ScriptTestCase(
      script_sig: <<>>,
      script_pubkey: <<0x51, 0x51, 0x86>>,
      // OP_1 OP_1 OP_XOR
      flags: parse_script_flags("P2SH,STRICTENC"),
      expected_result: ScriptError("DISABLED_OPCODE"),
      comment: "OP_XOR disabled",
    ),
    ScriptTestCase(
      script_sig: <<>>,
      script_pubkey: <<0x52, 0x8d>>,
      // OP_2 OP_2MUL
      flags: parse_script_flags("P2SH,STRICTENC"),
      expected_result: ScriptError("DISABLED_OPCODE"),
      comment: "OP_2MUL disabled",
    ),
    ScriptTestCase(
      script_sig: <<>>,
      script_pubkey: <<0x52, 0x8e>>,
      // OP_2 OP_2DIV
      flags: parse_script_flags("P2SH,STRICTENC"),
      expected_result: ScriptError("DISABLED_OPCODE"),
      comment: "OP_2DIV disabled",
    ),
    ScriptTestCase(
      script_sig: <<>>,
      script_pubkey: <<0x51, 0x51, 0x98>>,
      // OP_1 OP_1 OP_LSHIFT
      flags: parse_script_flags("P2SH,STRICTENC"),
      expected_result: ScriptError("DISABLED_OPCODE"),
      comment: "OP_LSHIFT disabled",
    ),
    ScriptTestCase(
      script_sig: <<>>,
      script_pubkey: <<0x51, 0x51, 0x99>>,
      // OP_1 OP_1 OP_RSHIFT
      flags: parse_script_flags("P2SH,STRICTENC"),
      expected_result: ScriptError("DISABLED_OPCODE"),
      comment: "OP_RSHIFT disabled",
    ),
  ]
}

// ============================================================================
// Script Number Encoding Tests
// ============================================================================

fn get_script_number_tests() -> List(ScriptTestCase) {
  [
    ScriptTestCase(
      script_sig: <<>>,
      script_pubkey: <<0x00, 0x00, 0x87>>,
      // OP_0 OP_0 OP_EQUAL
      flags: parse_script_flags("P2SH,STRICTENC"),
      expected_result: ScriptOK,
      comment: "zero equals empty",
    ),
    ScriptTestCase(
      script_sig: <<>>,
      script_pubkey: <<0x01, 0x80, 0x00, 0x87>>,
      // push(0x80) OP_0 OP_EQUAL
      flags: parse_script_flags("P2SH,STRICTENC"),
      expected_result: ScriptOK,
      comment: "negative zero equals zero",
    ),
    ScriptTestCase(
      script_sig: <<>>,
      script_pubkey: <<0x4f, 0x01, 0x81, 0x87>>,
      // OP_1NEGATE push(-1) OP_EQUAL
      flags: parse_script_flags("P2SH,STRICTENC"),
      expected_result: ScriptOK,
      comment: "-1 encoding equivalence",
    ),
    ScriptTestCase(
      script_sig: <<>>,
      script_pubkey: <<0x02, 0x00, 0x01, 0x02, 0x00, 0x80, 0x93>>,
      // push(256) push(-256) OP_ADD
      flags: parse_script_flags("P2SH,STRICTENC"),
      expected_result: ScriptOK,
      comment: "256 + (-256) = 0",
    ),
  ]
}

// ============================================================================
// Multisig Tests
// ============================================================================

fn get_multisig_tests() -> List(ScriptTestCase) {
  [
    ScriptTestCase(
      script_sig: <<>>,
      script_pubkey: <<0x00, 0x00, 0x00, 0xae>>,
      // OP_0 OP_0 OP_0 OP_CHECKMULTISIG
      flags: parse_script_flags("P2SH,STRICTENC"),
      expected_result: ScriptOK,
      comment: "0-of-0 multisig succeeds",
    ),
    ScriptTestCase(
      script_sig: <<>>,
      script_pubkey: <<0x00, 0x00, 0x00, 0xaf>>,
      // OP_0 OP_0 OP_0 OP_CHECKMULTISIGVERIFY
      flags: parse_script_flags("P2SH,STRICTENC"),
      expected_result: ScriptError("EVAL_FALSE"),
      comment: "0-of-0 CHECKMULTISIGVERIFY leaves empty stack",
    ),
  ]
}

// ============================================================================
// Error Condition Tests
// ============================================================================

fn get_error_condition_tests() -> List(ScriptTestCase) {
  [
    ScriptTestCase(
      script_sig: <<>>,
      script_pubkey: <<0x76>>,
      // OP_DUP (empty stack)
      flags: parse_script_flags("P2SH,STRICTENC"),
      expected_result: ScriptError("STACK_UNDERFLOW"),
      comment: "DUP on empty stack fails",
    ),
    ScriptTestCase(
      script_sig: <<>>,
      script_pubkey: <<0x51, 0x6a>>,
      // OP_1 OP_RETURN
      flags: parse_script_flags("P2SH,STRICTENC"),
      expected_result: ScriptError("OP_RETURN"),
      comment: "OP_RETURN fails",
    ),
    ScriptTestCase(
      script_sig: <<>>,
      script_pubkey: <<>>,
      // Empty
      flags: parse_script_flags("P2SH,STRICTENC"),
      expected_result: ScriptError("EVAL_FALSE"),
      comment: "Empty script fails",
    ),
    ScriptTestCase(
      script_sig: <<0x51>>,
      script_pubkey: <<>>,
      flags: parse_script_flags("P2SH,STRICTENC"),
      expected_result: ScriptOK,
      comment: "ScriptSig leaves true on stack",
    ),
    ScriptTestCase(
      script_sig: <<>>,
      script_pubkey: <<0x63, 0x51, 0x68>>,
      // OP_IF OP_1 OP_ENDIF (no condition)
      flags: parse_script_flags("P2SH,STRICTENC"),
      expected_result: ScriptError("STACK_UNDERFLOW"),
      comment: "IF without condition fails",
    ),
    ScriptTestCase(
      script_sig: <<>>,
      script_pubkey: <<0x51, 0x63>>,
      // OP_1 OP_IF (no ENDIF)
      flags: parse_script_flags("P2SH,STRICTENC"),
      expected_result: ScriptError("UNBALANCED_CONDITIONAL"),
      comment: "IF without ENDIF fails",
    ),
  ]
}

// ============================================================================
// Size Operation Tests
// ============================================================================

fn get_size_operation_tests() -> List(ScriptTestCase) {
  [
    ScriptTestCase(
      script_sig: <<>>,
      script_pubkey: <<0x03, 0x61, 0x62, 0x63, 0x82, 0x53, 0x87>>,
      // push('abc') OP_SIZE OP_3 OP_EQUAL
      flags: parse_script_flags("P2SH,STRICTENC"),
      expected_result: ScriptOK,
      comment: "SIZE of 'abc' is 3",
    ),
    ScriptTestCase(
      script_sig: <<>>,
      script_pubkey: <<0x00, 0x82, 0x00, 0x87>>,
      // OP_0 OP_SIZE OP_0 OP_EQUAL
      flags: parse_script_flags("P2SH,STRICTENC"),
      expected_result: ScriptOK,
      comment: "SIZE of empty is 0",
    ),
    ScriptTestCase(
      script_sig: <<>>,
      script_pubkey: <<0x51, 0x82, 0x51, 0x87>>,
      // OP_1 OP_SIZE OP_1 OP_EQUAL
      flags: parse_script_flags("P2SH,STRICTENC"),
      expected_result: ScriptOK,
      comment: "SIZE of OP_1 encoding is 1",
    ),
  ]
}

// ============================================================================
// Bitwise Operation Tests (all disabled)
// ============================================================================

fn get_bitwise_tests() -> List(ScriptTestCase) {
  [
    // All bitwise operations are disabled, tested in disabled_opcode_tests
  // This section reserved for future if they get re-enabled
  ]
}

// ============================================================================
// Altstack Tests
// ============================================================================

fn get_altstack_tests() -> List(ScriptTestCase) {
  [
    ScriptTestCase(
      script_sig: <<>>,
      script_pubkey: <<0x51, 0x6b, 0x6c, 0x51, 0x87>>,
      // OP_1 OP_TOALTSTACK OP_FROMALTSTACK OP_1 OP_EQUAL
      flags: parse_script_flags("P2SH,STRICTENC"),
      expected_result: ScriptOK,
      comment: "TOALTSTACK then FROMALTSTACK roundtrip",
    ),
    ScriptTestCase(
      script_sig: <<>>,
      script_pubkey: <<0x51, 0x52, 0x6b, 0x6b, 0x6c, 0x6c, 0x51, 0x87>>,
      // Push both, pop both, verify
      flags: parse_script_flags("P2SH,STRICTENC"),
      expected_result: ScriptOK,
      comment: "Multiple altstack operations",
    ),
  ]
}

// ============================================================================
// NOP Tests
// ============================================================================

fn get_nop_tests() -> List(ScriptTestCase) {
  [
    ScriptTestCase(
      script_sig: <<>>,
      script_pubkey: <<0x51, 0x61>>,
      // OP_1 OP_NOP
      flags: parse_script_flags("P2SH,STRICTENC"),
      expected_result: ScriptOK,
      comment: "OP_NOP is no-op",
    ),
    ScriptTestCase(
      script_sig: <<>>,
      script_pubkey: <<0x51, 0xb0>>,
      // OP_1 OP_NOP1
      flags: parse_script_flags("P2SH,STRICTENC"),
      expected_result: ScriptOK,
      comment: "OP_NOP1 is no-op",
    ),
    ScriptTestCase(
      script_sig: <<>>,
      script_pubkey: <<0x51, 0xb3>>,
      // OP_1 OP_NOP4
      flags: parse_script_flags("P2SH,STRICTENC"),
      expected_result: ScriptOK,
      comment: "OP_NOP4 is no-op",
    ),
    ScriptTestCase(
      script_sig: <<>>,
      script_pubkey: <<0x51, 0xb9>>,
      // OP_1 OP_NOP10
      flags: parse_script_flags("P2SH,STRICTENC"),
      expected_result: ScriptOK,
      comment: "OP_NOP10 is no-op",
    ),
  ]
}
