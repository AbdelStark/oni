import gleeunit
import gleeunit/should
import oni_consensus

pub fn main() {
  gleeunit.main()
}

// ============================================================================
// Opcode Tests
// ============================================================================

pub fn opcode_from_byte_push_test() {
  let op = oni_consensus.opcode_from_byte(0x76)  // OP_DUP
  op |> should.equal(oni_consensus.OpDup)
}

pub fn opcode_from_byte_push_data_test() {
  let op = oni_consensus.opcode_from_byte(0x05)  // Push 5 bytes
  op |> should.equal(oni_consensus.OpPushBytes(5))
}

pub fn opcode_is_disabled_test() {
  oni_consensus.opcode_is_disabled(oni_consensus.OpCat)
  |> should.be_true

  oni_consensus.opcode_is_disabled(oni_consensus.OpDup)
  |> should.be_false
}

// ============================================================================
// Script Flags Tests
// ============================================================================

pub fn default_script_flags_test() {
  let flags = oni_consensus.default_script_flags()
  flags.verify_p2sh |> should.be_true
  flags.verify_witness |> should.be_true
  flags.verify_taproot |> should.be_true
}

// ============================================================================
// Sighash Tests
// ============================================================================

pub fn sighash_type_from_byte_all_test() {
  let sh = oni_consensus.sighash_type_from_byte(0x01)
  sh |> should.equal(oni_consensus.SighashAll)
}

pub fn sighash_type_from_byte_none_test() {
  let sh = oni_consensus.sighash_type_from_byte(0x02)
  sh |> should.equal(oni_consensus.SighashNone)
}

pub fn sighash_type_from_byte_single_test() {
  let sh = oni_consensus.sighash_type_from_byte(0x03)
  sh |> should.equal(oni_consensus.SighashSingle)
}

pub fn sighash_type_from_byte_anyonecanpay_test() {
  let sh = oni_consensus.sighash_type_from_byte(0x81)
  sh |> should.equal(oni_consensus.SighashAnyoneCanPay(oni_consensus.SighashAll))
}

// ============================================================================
// Constants Tests
// ============================================================================

pub fn constants_test() {
  oni_consensus.max_script_element_size |> should.equal(520)
  oni_consensus.max_script_size |> should.equal(10_000)
  oni_consensus.max_ops_per_script |> should.equal(201)
  oni_consensus.max_stack_size |> should.equal(1000)
  oni_consensus.max_block_weight |> should.equal(4_000_000)
  oni_consensus.coinbase_maturity |> should.equal(100)
}

// ============================================================================
// Script Number Encoding Tests
// ============================================================================

pub fn encode_script_num_zero_test() {
  oni_consensus.encode_script_num(0) |> should.equal(<<>>)
}

pub fn encode_script_num_one_test() {
  oni_consensus.encode_script_num(1) |> should.equal(<<0x01>>)
}

pub fn encode_script_num_negative_one_test() {
  oni_consensus.encode_script_num(-1) |> should.equal(<<0x81>>)
}

pub fn encode_script_num_127_test() {
  oni_consensus.encode_script_num(127) |> should.equal(<<0x7f>>)
}

pub fn encode_script_num_128_test() {
  // 128 needs extra byte for sign
  oni_consensus.encode_script_num(128) |> should.equal(<<0x80, 0x00>>)
}

pub fn decode_script_num_empty_test() {
  oni_consensus.decode_script_num(<<>>) |> should.equal(Ok(0))
}

pub fn decode_script_num_one_test() {
  oni_consensus.decode_script_num(<<0x01>>) |> should.equal(Ok(1))
}

pub fn decode_script_num_negative_one_test() {
  oni_consensus.decode_script_num(<<0x81>>) |> should.equal(Ok(-1))
}

// ============================================================================
// Script Parsing Tests
// ============================================================================

pub fn parse_empty_script_test() {
  let result = oni_consensus.parse_script(<<>>)
  result |> should.be_ok
  let assert Ok(elements) = result
  elements |> should.equal([])
}

pub fn parse_op_dup_test() {
  // OP_DUP = 0x76
  let result = oni_consensus.parse_script(<<0x76>>)
  result |> should.be_ok
  let assert Ok(elements) = result
  case elements {
    [oni_consensus.OpElement(oni_consensus.OpDup)] -> should.be_true(True)
    _ -> should.fail()
  }
}

pub fn parse_push_data_test() {
  // Push 3 bytes: 0x03 followed by 3 bytes
  let result = oni_consensus.parse_script(<<0x03, 0x01, 0x02, 0x03>>)
  result |> should.be_ok
  let assert Ok(elements) = result
  case elements {
    [oni_consensus.DataElement(data)] -> {
      data |> should.equal(<<0x01, 0x02, 0x03>>)
    }
    _ -> should.fail()
  }
}

pub fn parse_op_true_test() {
  // OP_TRUE = 0x51
  let result = oni_consensus.parse_script(<<0x51>>)
  result |> should.be_ok
  let assert Ok(elements) = result
  case elements {
    [oni_consensus.OpElement(oni_consensus.OpTrue)] -> should.be_true(True)
    _ -> should.fail()
  }
}

// ============================================================================
// Script Execution Tests
// ============================================================================

pub fn execute_empty_script_test() {
  let flags = oni_consensus.default_script_flags()
  let ctx = oni_consensus.script_context_new(<<>>, flags)
  let result = oni_consensus.execute_script(ctx)
  result |> should.be_ok
}

pub fn execute_op_true_test() {
  let flags = oni_consensus.default_script_flags()
  // OP_TRUE (0x51)
  let ctx = oni_consensus.script_context_new(<<0x51>>, flags)
  let result = oni_consensus.execute_script(ctx)
  result |> should.be_ok
  let assert Ok(final_ctx) = result
  // Stack should have one element: 0x01
  case final_ctx.stack {
    [<<1:8>>] -> should.be_true(True)
    _ -> should.fail()
  }
}

pub fn execute_op_dup_test() {
  let flags = oni_consensus.default_script_flags()
  // Push 0x01, then DUP
  let ctx = oni_consensus.script_context_new(<<0x51, 0x76>>, flags)
  let result = oni_consensus.execute_script(ctx)
  result |> should.be_ok
  let assert Ok(final_ctx) = result
  // Stack should have two elements: 0x01, 0x01
  case final_ctx.stack {
    [<<1:8>>, <<1:8>>] -> should.be_true(True)
    _ -> should.fail()
  }
}

pub fn execute_op_equal_true_test() {
  let flags = oni_consensus.default_script_flags()
  // Push 1, Push 1, EQUAL -> should leave 1 on stack
  let ctx = oni_consensus.script_context_new(<<0x51, 0x51, 0x87>>, flags)
  let result = oni_consensus.execute_script(ctx)
  result |> should.be_ok
  let assert Ok(final_ctx) = result
  case final_ctx.stack {
    [<<1:8>>] -> should.be_true(True)
    _ -> should.fail()
  }
}

pub fn execute_op_equal_false_test() {
  let flags = oni_consensus.default_script_flags()
  // Push 1, Push 2, EQUAL -> should leave empty (false) on stack
  let ctx = oni_consensus.script_context_new(<<0x51, 0x52, 0x87>>, flags)
  let result = oni_consensus.execute_script(ctx)
  result |> should.be_ok
  let assert Ok(final_ctx) = result
  case final_ctx.stack {
    [<<>>] -> should.be_true(True)
    _ -> should.fail()
  }
}

pub fn execute_op_add_test() {
  let flags = oni_consensus.default_script_flags()
  // Push 2, Push 3, ADD -> should leave 5 on stack
  let ctx = oni_consensus.script_context_new(<<0x52, 0x53, 0x93>>, flags)
  let result = oni_consensus.execute_script(ctx)
  result |> should.be_ok
  let assert Ok(final_ctx) = result
  case final_ctx.stack {
    [<<5:8>>] -> should.be_true(True)
    _ -> should.fail()
  }
}

pub fn execute_hash160_test() {
  let flags = oni_consensus.default_script_flags()
  // Push 1 byte (0x01), then HASH160
  let ctx = oni_consensus.script_context_new(<<0x01, 0xAB, 0xa9>>, flags)
  let result = oni_consensus.execute_script(ctx)
  result |> should.be_ok
  let assert Ok(final_ctx) = result
  // Stack should have a 20-byte hash
  case final_ctx.stack {
    [hash] -> {
      should.be_true(bit_array.byte_size(hash) == 20)
    }
    _ -> should.fail()
  }
}

import gleam/bit_array
