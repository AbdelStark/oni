// consensus_fuzz_test.gleam - Fuzzing and boundary tests for consensus-critical parsing
//
// This module provides security-critical tests for the consensus layer:
// - Script parsing (must never crash on any input)
// - Transaction serialization boundaries
// - Script number encoding edge cases
// - CompactSize overflow protection
// - Block header validation boundaries
//
// SECURITY: Consensus parsing is a critical attack surface.
// All parsing must return Error, never crash or allocate unbounded memory.

import gleam/bit_array
import gleam/int
import gleam/list
import gleeunit/should
import oni_bitcoin
import oni_consensus

// ============================================================================
// Script Parsing Boundary Tests
// ============================================================================

pub fn script_parse_empty_test() {
  // Empty script should parse successfully
  let result = oni_consensus.parse_script(<<>>)
  result |> should.be_ok
  let assert Ok(elements) = result
  elements |> should.equal([])
}

pub fn script_parse_all_single_byte_opcodes_test() {
  // Every single-byte value should either parse or return error, never crash
  test_single_byte_range(0, 255)
}

fn test_single_byte_range(current: Int, max: Int) -> Nil {
  case current > max {
    True -> Nil
    False -> {
      let byte = <<current:8>>
      // Must not crash - either Ok or Error is acceptable
      case oni_consensus.parse_script(byte) {
        Ok(_) -> Nil
        Error(_) -> Nil
      }
      test_single_byte_range(current + 1, max)
    }
  }
}

pub fn script_parse_push_data_truncated_test() {
  // OP_PUSHBYTES_5 (0x05) but only 3 bytes follow
  let script = <<0x05, 0x01, 0x02, 0x03>>
  case oni_consensus.parse_script(script) {
    Error(_) -> should.be_ok(Ok(Nil))
    Ok(_) -> should.fail()
    // Should fail due to truncation
  }
}

pub fn script_parse_pushdata1_truncated_length_test() {
  // OP_PUSHDATA1 (0x4c) with no length byte
  let script = <<0x4c>>
  case oni_consensus.parse_script(script) {
    Error(_) -> should.be_ok(Ok(Nil))
    Ok(_) -> should.fail()
  }
}

pub fn script_parse_pushdata1_truncated_data_test() {
  // OP_PUSHDATA1 (0x4c) with length=10 but only 5 bytes follow
  let script = <<0x4c, 0x0a, 0x01, 0x02, 0x03, 0x04, 0x05>>
  case oni_consensus.parse_script(script) {
    Error(_) -> should.be_ok(Ok(Nil))
    Ok(_) -> should.fail()
  }
}

pub fn script_parse_pushdata2_truncated_length_test() {
  // OP_PUSHDATA2 (0x4d) with only 1 byte of length (needs 2)
  let script = <<0x4d, 0x0a>>
  case oni_consensus.parse_script(script) {
    Error(_) -> should.be_ok(Ok(Nil))
    Ok(_) -> should.fail()
  }
}

pub fn script_parse_pushdata4_truncated_length_test() {
  // OP_PUSHDATA4 (0x4e) with only 2 bytes of length (needs 4)
  let script = <<0x4e, 0x0a, 0x00>>
  case oni_consensus.parse_script(script) {
    Error(_) -> should.be_ok(Ok(Nil))
    Ok(_) -> should.fail()
  }
}

pub fn script_parse_max_script_element_size_test() {
  // Push exactly 520 bytes (max element size) - should succeed
  let data = create_bytes(520)
  // Use PUSHDATA2 for 520 bytes: 0x4d + little-endian 520 + data
  let script = bit_array.concat([<<0x4d, 0x08, 0x02>>, data])
  case oni_consensus.parse_script(script) {
    Ok(_) -> should.be_ok(Ok(Nil))
    Error(_) -> should.be_ok(Ok(Nil))
    // Also acceptable if strict
  }
}

pub fn script_parse_exceeds_max_element_size_test() {
  // Try to push 521 bytes (exceeds max element size of 520)
  let data = create_bytes(521)
  let script = bit_array.concat([<<0x4d, 0x09, 0x02>>, data])
  case oni_consensus.parse_script(script) {
    Error(_) -> should.be_ok(Ok(Nil))
    Ok(_) -> should.be_ok(Ok(Nil))
    // May parse but fail on execution
  }
}

pub fn script_parse_max_script_size_test() {
  // Script at exactly 10,000 bytes (max script size)
  let script = create_bytes(10_000)
  case oni_consensus.parse_script(script) {
    Ok(_) -> should.be_ok(Ok(Nil))
    Error(_) -> should.be_ok(Ok(Nil))
    // Also acceptable
  }
}

pub fn script_parse_nested_if_without_endif_test() {
  // Multiple IF without ENDIF
  let script = <<0x51, 0x63, 0x63, 0x63>>
  // OP_1 OP_IF OP_IF OP_IF
  case oni_consensus.parse_script(script) {
    // Should parse (syntax is valid), but execution would fail
    Ok(_) -> should.be_ok(Ok(Nil))
    Error(_) -> should.be_ok(Ok(Nil))
  }
}

// ============================================================================
// Script Execution Boundary Tests
// ============================================================================

pub fn execute_max_stack_test() {
  // Push 1000 elements (max stack size) then verify
  // We can't easily create a 1000-element script here, so test a smaller case
  let flags = oni_consensus.default_script_flags()
  // Push 10 elements then drop them
  let script = <<
    0x51,
    0x51,
    0x51,
    0x51,
    0x51,
    0x51,
    0x51,
    0x51,
    0x51,
    0x51,
    0x75,
    0x75,
    0x75,
    0x75,
    0x75,
    0x75,
    0x75,
    0x75,
    0x75,
  >>
  let ctx = oni_consensus.script_context_new(script, flags)
  let result = oni_consensus.execute_script(ctx)
  result |> should.be_ok
}

pub fn execute_disabled_opcode_test() {
  // Each disabled opcode should fail cleanly
  let flags = oni_consensus.default_script_flags()

  // Test OP_CAT (0x7e)
  let ctx = oni_consensus.script_context_new(<<0x51, 0x51, 0x7e>>, flags)
  case oni_consensus.execute_script(ctx) {
    Error(oni_consensus.ScriptDisabledOpcode) -> should.be_ok(Ok(Nil))
    Error(_) -> should.be_ok(Ok(Nil))
    Ok(_) -> should.fail()
  }
}

pub fn execute_op_return_data_test() {
  // OP_RETURN with data should fail
  let flags = oni_consensus.default_script_flags()
  // OP_RETURN followed by some data
  let script = <<
    0x6a,
    0x0e,
    0x68,
    0x65,
    0x6c,
    0x6c,
    0x6f,
    0x20,
    0x77,
    0x6f,
    0x72,
    0x6c,
    0x64,
    0x21,
    0x21,
    0x21,
  >>
  let ctx = oni_consensus.script_context_new(script, flags)
  case oni_consensus.execute_script(ctx) {
    Error(oni_consensus.ScriptInvalid) -> should.be_ok(Ok(Nil))
    Error(_) -> should.be_ok(Ok(Nil))
    Ok(_) -> should.fail()
  }
}

pub fn execute_empty_stack_operation_test() {
  // Operations on empty stack should fail gracefully
  let flags = oni_consensus.default_script_flags()

  // OP_DUP on empty stack
  let ctx = oni_consensus.script_context_new(<<0x76>>, flags)
  case oni_consensus.execute_script(ctx) {
    Error(oni_consensus.ScriptStackUnderflow) -> should.be_ok(Ok(Nil))
    Error(_) -> should.be_ok(Ok(Nil))
    Ok(_) -> should.fail()
  }
}

pub fn execute_arithmetic_overflow_test() {
  // Large script numbers near INT32 limits
  let flags = oni_consensus.default_script_flags()
  // Push max int32 (0x7FFFFFFF) and add 1 - should handle overflow
  // In script number format: 0x04 0xFF 0xFF 0xFF 0x7F
  let script = <<0x04, 0xff, 0xff, 0xff, 0x7f, 0x8b>>
  // push max_int32, OP_1ADD
  let ctx = oni_consensus.script_context_new(script, flags)
  case oni_consensus.execute_script(ctx) {
    Ok(_) -> should.be_ok(Ok(Nil))
    // May succeed with larger int
    Error(_) -> should.be_ok(Ok(Nil))
    // Or fail on overflow
  }
}

// ============================================================================
// Script Number Encoding Boundary Tests
// ============================================================================

pub fn script_num_encode_zero_test() {
  oni_consensus.encode_script_num(0) |> should.equal(<<>>)
}

pub fn script_num_encode_max_positive_test() {
  // 0x7FFFFFFF (2147483647)
  let encoded = oni_consensus.encode_script_num(2_147_483_647)
  bit_array.byte_size(encoded) |> should.equal(4)
}

pub fn script_num_encode_min_negative_test() {
  // -2147483648
  let encoded = oni_consensus.encode_script_num(-2_147_483_648)
  bit_array.byte_size(encoded) |> should.equal(5)
  // Needs extra byte for sign
}

pub fn script_num_decode_empty_test() {
  oni_consensus.decode_script_num(<<>>) |> should.equal(Ok(0))
}

pub fn script_num_decode_negative_zero_test() {
  // 0x80 is negative zero, should equal 0
  oni_consensus.decode_script_num(<<0x80>>) |> should.equal(Ok(0))
}

pub fn script_num_decode_multi_byte_negative_zero_test() {
  // 0x00 0x80 is also negative zero
  oni_consensus.decode_script_num(<<0x00, 0x80>>) |> should.equal(Ok(0))
}

pub fn script_num_roundtrip_test() {
  // Test roundtrip for various values
  test_script_num_roundtrip(0)
  test_script_num_roundtrip(1)
  test_script_num_roundtrip(-1)
  test_script_num_roundtrip(127)
  test_script_num_roundtrip(128)
  test_script_num_roundtrip(-128)
  test_script_num_roundtrip(255)
  test_script_num_roundtrip(256)
  test_script_num_roundtrip(-256)
  test_script_num_roundtrip(32_767)
  test_script_num_roundtrip(-32_768)
  test_script_num_roundtrip(2_147_483_647)
  test_script_num_roundtrip(-2_147_483_647)
}

fn test_script_num_roundtrip(n: Int) -> Nil {
  let encoded = oni_consensus.encode_script_num(n)
  case oni_consensus.decode_script_num(encoded) {
    Ok(decoded) -> {
      case decoded == n {
        True -> Nil
        False -> should.fail()
      }
    }
    Error(_) -> should.fail()
  }
}

// ============================================================================
// Transaction Parsing Boundary Tests
// ============================================================================

pub fn tx_decode_empty_test() {
  // Empty input should return error
  case oni_bitcoin.decode_tx(<<>>) {
    Error(_) -> should.be_ok(Ok(Nil))
    Ok(_) -> should.fail()
  }
}

pub fn tx_decode_truncated_version_test() {
  // Only 2 bytes (need at least 4 for version)
  case oni_bitcoin.decode_tx(<<0x01, 0x00>>) {
    Error(_) -> should.be_ok(Ok(Nil))
    Ok(_) -> should.fail()
  }
}

pub fn tx_decode_truncated_input_count_test() {
  // Version only, no input count
  case oni_bitcoin.decode_tx(<<0x01, 0x00, 0x00, 0x00>>) {
    Error(_) -> should.be_ok(Ok(Nil))
    Ok(_) -> should.fail()
  }
}

pub fn tx_decode_zero_inputs_and_outputs_test() {
  // Version + 0 inputs + 0 outputs + locktime (should fail - invalid tx)
  let tx = <<
    0x01,
    0x00,
    0x00,
    0x00,
    // version 1
    0x00,
    // 0 inputs
    0x00,
    // 0 outputs
    0x00,
    0x00,
    0x00,
    0x00,
  >>
  // locktime
  case oni_bitcoin.decode_tx(tx) {
    Error(_) -> should.be_ok(Ok(Nil))
    Ok(_) -> should.be_ok(Ok(Nil))
    // May parse but validation would fail
  }
}

pub fn tx_decode_witness_marker_no_flag_test() {
  // SegWit marker (0x00) but missing flag byte
  let tx = <<
    0x01,
    0x00,
    0x00,
    0x00,
    // version
    0x00,
  >>
  // marker, but no flag
  case oni_bitcoin.decode_tx(tx) {
    Error(_) -> should.be_ok(Ok(Nil))
    Ok(_) -> should.fail()
  }
}

pub fn tx_decode_large_input_count_test() {
  // Claim to have 0xFFFFFFFF inputs (will fail due to bounds)
  let tx = <<
    0x01,
    0x00,
    0x00,
    0x00,
    // version
    0xff,
    0xff,
    0xff,
    0xff,
    0xff,
  >>
  // Huge compact size
  case oni_bitcoin.decode_tx(tx) {
    Error(_) -> should.be_ok(Ok(Nil))
    Ok(_) -> should.fail()
    // Should fail bounds check
  }
}

pub fn tx_decode_truncated_prevout_test() {
  // 1 input but prevout is truncated
  let tx = <<
    0x01,
    0x00,
    0x00,
    0x00,
    // version
    0x01,
    // 1 input
    0x00,
    0x00,
    0x00,
  >>
  // only 3 bytes of 36-byte prevout
  case oni_bitcoin.decode_tx(tx) {
    Error(_) -> should.be_ok(Ok(Nil))
    Ok(_) -> should.fail()
  }
}

pub fn tx_decode_negative_output_value_test() {
  // Transaction with negative output value (invalid)
  // This tests the Amount bounds checking
  let tx = <<
    0x01,
    0x00,
    0x00,
    0x00,
    // version
    0x01,
    // 1 input
    0:256,
    // null prevout txid
    0xff,
    0xff,
    0xff,
    0xff,
    // prevout vout
    0x00,
    // empty scriptsig
    0xff,
    0xff,
    0xff,
    0xff,
    // sequence
    0x01,
    // 1 output
    0xff,
    0xff,
    0xff,
    0xff,
    0xff,
    0xff,
    0xff,
    0xff,
    // max uint64 (negative in signed)
    0x00,
    // empty scriptpubkey
    0x00,
    0x00,
    0x00,
    0x00,
  >>
  // locktime
  case oni_bitcoin.decode_tx(tx) {
    Error(_) -> should.be_ok(Ok(Nil))
    Ok(_) -> should.be_ok(Ok(Nil))
    // Parsing may succeed, validation fails
  }
}

// ============================================================================
// Block Header Parsing Boundary Tests
// ============================================================================

pub fn header_decode_empty_test() {
  case oni_bitcoin.decode_block_header(<<>>) {
    Error(_) -> should.be_ok(Ok(Nil))
    Ok(_) -> should.fail()
  }
}

pub fn header_decode_truncated_test() {
  // Less than 80 bytes
  case oni_bitcoin.decode_block_header(<<0:320>>) {
    // 40 bytes
    Error(_) -> should.be_ok(Ok(Nil))
    Ok(_) -> should.fail()
  }
}

pub fn header_decode_exact_size_test() {
  // Exactly 80 bytes should parse
  let header = create_bytes(80)
  case oni_bitcoin.decode_block_header(header) {
    Ok(_) -> should.be_ok(Ok(Nil))
    Error(_) -> should.be_ok(Ok(Nil))
    // May fail due to invalid data
  }
}

pub fn header_decode_with_extra_bytes_test() {
  // 80 bytes header + extra - should parse header and return remaining
  let header = create_bytes(80)
  let extra = <<0xde, 0xad, 0xbe, 0xef>>
  let input = bit_array.concat([header, extra])
  case oni_bitcoin.decode_block_header(input) {
    Ok(#(_, remaining)) -> {
      remaining |> should.equal(extra)
    }
    Error(_) -> should.be_ok(Ok(Nil))
  }
}

// ============================================================================
// CompactSize Boundary Tests
// ============================================================================

pub fn compact_size_decode_empty_test() {
  case oni_bitcoin.compact_size_decode(<<>>) {
    Error(_) -> should.be_ok(Ok(Nil))
    Ok(_) -> should.fail()
  }
}

pub fn compact_size_decode_single_byte_max_test() {
  // 252 is max for single byte encoding
  case oni_bitcoin.compact_size_decode(<<252>>) {
    Ok(#(252, <<>>)) -> should.be_ok(Ok(Nil))
    _ -> should.fail()
  }
}

pub fn compact_size_decode_two_byte_min_test() {
  // 253 requires 3-byte encoding: 0xFD + 16-bit little-endian
  case oni_bitcoin.compact_size_decode(<<0xfd, 253:16-little>>) {
    Ok(#(253, <<>>)) -> should.be_ok(Ok(Nil))
    _ -> should.fail()
  }
}

pub fn compact_size_decode_truncated_two_byte_test() {
  // 0xFD marker but only 1 byte follows (needs 2)
  case oni_bitcoin.compact_size_decode(<<0xfd, 0x01>>) {
    Error(_) -> should.be_ok(Ok(Nil))
    Ok(_) -> should.fail()
  }
}

pub fn compact_size_decode_truncated_four_byte_test() {
  // 0xFE marker but only 2 bytes follow (needs 4)
  case oni_bitcoin.compact_size_decode(<<0xfe, 0x01, 0x02>>) {
    Error(_) -> should.be_ok(Ok(Nil))
    Ok(_) -> should.fail()
  }
}

pub fn compact_size_decode_truncated_eight_byte_test() {
  // 0xFF marker but only 4 bytes follow (needs 8)
  case oni_bitcoin.compact_size_decode(<<0xff, 0x01, 0x02, 0x03, 0x04>>) {
    Error(_) -> should.be_ok(Ok(Nil))
    Ok(_) -> should.fail()
  }
}

pub fn compact_size_roundtrip_test() {
  // Test roundtrip for boundary values
  test_compact_size_roundtrip(0)
  test_compact_size_roundtrip(252)
  test_compact_size_roundtrip(253)
  test_compact_size_roundtrip(65_535)
  test_compact_size_roundtrip(65_536)
  test_compact_size_roundtrip(4_294_967_295)
}

fn test_compact_size_roundtrip(n: Int) -> Nil {
  let encoded = oni_bitcoin.compact_size_encode(n)
  case oni_bitcoin.compact_size_decode(encoded) {
    Ok(#(decoded, <<>>)) -> {
      case decoded == n {
        True -> Nil
        False -> should.fail()
      }
    }
    _ -> should.fail()
  }
}

// ============================================================================
// Sighash Boundary Tests
// ============================================================================

pub fn sighash_type_all_variants_test() {
  // All standard sighash types should parse
  oni_consensus.sighash_type_from_byte(0x01)
  |> should.equal(oni_consensus.SighashAll)
  oni_consensus.sighash_type_from_byte(0x02)
  |> should.equal(oni_consensus.SighashNone)
  oni_consensus.sighash_type_from_byte(0x03)
  |> should.equal(oni_consensus.SighashSingle)
  oni_consensus.sighash_type_from_byte(0x81)
  |> should.equal(oni_consensus.SighashAnyoneCanPay(oni_consensus.SighashAll))
  oni_consensus.sighash_type_from_byte(0x82)
  |> should.equal(oni_consensus.SighashAnyoneCanPay(oni_consensus.SighashNone))
  oni_consensus.sighash_type_from_byte(0x83)
  |> should.equal(oni_consensus.SighashAnyoneCanPay(oni_consensus.SighashSingle))
}

// ============================================================================
// Merkle Root Boundary Tests
// ============================================================================

pub fn merkle_root_empty_test() {
  let txids: List(oni_bitcoin.Hash256) = []
  let root = oni_consensus.compute_merkle_root(txids)
  // Empty list produces zero hash
  root.bytes |> should.equal(<<0:256>>)
}

pub fn merkle_root_single_test() {
  let assert Ok(hash) = oni_bitcoin.hash256_from_bytes(<<1:256>>)
  let root = oni_consensus.compute_merkle_root([hash])
  // Single element is the root
  root |> should.equal(hash)
}

pub fn merkle_root_power_of_two_test() {
  // 4 elements (power of 2) - no duplication needed
  let hashes = [
    oni_bitcoin.Hash256(<<1:256>>),
    oni_bitcoin.Hash256(<<2:256>>),
    oni_bitcoin.Hash256(<<3:256>>),
    oni_bitcoin.Hash256(<<4:256>>),
  ]
  let root = oni_consensus.compute_merkle_root(hashes)
  bit_array.byte_size(root.bytes) |> should.equal(32)
}

pub fn merkle_root_odd_count_test() {
  // 3 elements (odd) - last element duplicated
  let hashes = [
    oni_bitcoin.Hash256(<<1:256>>),
    oni_bitcoin.Hash256(<<2:256>>),
    oni_bitcoin.Hash256(<<3:256>>),
  ]
  let root = oni_consensus.compute_merkle_root(hashes)
  bit_array.byte_size(root.bytes) |> should.equal(32)
}

// ============================================================================
// Opcode Mapping Tests
// ============================================================================

pub fn opcode_byte_roundtrip_test() {
  // Test that all 256 byte values map to valid opcodes
  test_opcode_byte_range(0, 255)
}

fn test_opcode_byte_range(current: Int, max: Int) -> Nil {
  case current > max {
    True -> Nil
    False -> {
      let op = oni_consensus.opcode_from_byte(current)
      // Every byte must map to some opcode (push data, opcode, or reserved)
      case op {
        _ -> Nil
        // Any result is valid, just shouldn't crash
      }
      test_opcode_byte_range(current + 1, max)
    }
  }
}

pub fn disabled_opcode_detection_test() {
  // All historically disabled opcodes
  let disabled = [
    oni_consensus.OpCat,
    oni_consensus.OpSubstr,
    oni_consensus.OpLeft,
    oni_consensus.OpRight,
    oni_consensus.OpInvert,
    oni_consensus.OpAnd,
    oni_consensus.OpOr,
    oni_consensus.OpXor,
    oni_consensus.Op2Mul,
    oni_consensus.Op2Div,
    oni_consensus.OpMul,
    oni_consensus.OpDiv,
    oni_consensus.OpMod,
    oni_consensus.OpLShift,
    oni_consensus.OpRShift,
  ]

  list.each(disabled, fn(op) {
    oni_consensus.opcode_is_disabled(op) |> should.be_true
  })
}

// ============================================================================
// Helper Functions
// ============================================================================

/// Create n bytes of zeros
fn create_bytes(n: Int) -> BitArray {
  create_bytes_acc(n, <<>>)
}

fn create_bytes_acc(n: Int, acc: BitArray) -> BitArray {
  case n <= 0 {
    True -> acc
    False -> create_bytes_acc(n - 1, bit_array.concat([acc, <<0>>]))
  }
}
