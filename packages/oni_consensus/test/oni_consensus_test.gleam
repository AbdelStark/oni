import gleeunit
import gleeunit/should
import gleam/bit_array
import gleam/list
import oni_consensus
import validation
import oni_bitcoin
import oni_storage

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

// ============================================================================
// Validation Module Tests (Phase 4)
// ============================================================================

pub fn validation_flags_default_test() {
  let flags = validation.default_validation_flags()
  flags.bip16 |> should.be_true
  flags.bip141 |> should.be_true
  flags.bip341 |> should.be_true
}

pub fn is_coinbase_test() {
  // Create a coinbase transaction
  let null_hash = oni_bitcoin.Hash256(<<0:256>>)
  let null_outpoint = oni_bitcoin.OutPoint(
    txid: oni_bitcoin.Txid(null_hash),
    vout: 0xFFFFFFFF,
  )
  let coinbase_input = oni_bitcoin.TxIn(
    prevout: null_outpoint,
    script_sig: oni_bitcoin.script_from_bytes(<<>>),
    sequence: 0xFFFFFFFF,
    witness: [],
  )
  let assert Ok(value) = oni_bitcoin.amount_from_sats(5_000_000_000)
  let output = oni_bitcoin.TxOut(
    value: value,
    script_pubkey: oni_bitcoin.script_from_bytes(<<>>),
  )
  let coinbase_tx = oni_bitcoin.Transaction(
    version: 1,
    inputs: [coinbase_input],
    outputs: [output],
    lock_time: 0,
  )

  validation.is_coinbase(coinbase_tx) |> should.be_true
}

pub fn is_not_coinbase_test() {
  // Create a normal transaction
  let assert Ok(hash) = oni_bitcoin.hash256_from_bytes(<<1:256>>)
  let outpoint = oni_bitcoin.OutPoint(
    txid: oni_bitcoin.Txid(hash),
    vout: 0,
  )
  let input = oni_bitcoin.TxIn(
    prevout: outpoint,
    script_sig: oni_bitcoin.script_from_bytes(<<>>),
    sequence: 0xFFFFFFFF,
    witness: [],
  )
  let assert Ok(value) = oni_bitcoin.amount_from_sats(1000)
  let output = oni_bitcoin.TxOut(
    value: value,
    script_pubkey: oni_bitcoin.script_from_bytes(<<>>),
  )
  let normal_tx = oni_bitcoin.Transaction(
    version: 1,
    inputs: [input],
    outputs: [output],
    lock_time: 0,
  )

  validation.is_coinbase(normal_tx) |> should.be_false
}

pub fn validate_tx_stateless_empty_inputs_test() {
  let assert Ok(value) = oni_bitcoin.amount_from_sats(1000)
  let output = oni_bitcoin.TxOut(
    value: value,
    script_pubkey: oni_bitcoin.script_from_bytes(<<>>),
  )
  let tx = oni_bitcoin.Transaction(
    version: 1,
    inputs: [],
    outputs: [output],
    lock_time: 0,
  )

  let result = validation.validate_tx_stateless(tx)
  result |> should.be_error
}

pub fn validate_tx_stateless_empty_outputs_test() {
  let assert Ok(hash) = oni_bitcoin.hash256_from_bytes(<<1:256>>)
  let outpoint = oni_bitcoin.OutPoint(
    txid: oni_bitcoin.Txid(hash),
    vout: 0,
  )
  let input = oni_bitcoin.TxIn(
    prevout: outpoint,
    script_sig: oni_bitcoin.script_from_bytes(<<>>),
    sequence: 0xFFFFFFFF,
    witness: [],
  )
  let tx = oni_bitcoin.Transaction(
    version: 1,
    inputs: [input],
    outputs: [],
    lock_time: 0,
  )

  let result = validation.validate_tx_stateless(tx)
  result |> should.be_error
}

pub fn validate_tx_stateless_valid_test() {
  let assert Ok(hash) = oni_bitcoin.hash256_from_bytes(<<1:256>>)
  let outpoint = oni_bitcoin.OutPoint(
    txid: oni_bitcoin.Txid(hash),
    vout: 0,
  )
  let input = oni_bitcoin.TxIn(
    prevout: outpoint,
    script_sig: oni_bitcoin.script_from_bytes(<<>>),
    sequence: 0xFFFFFFFF,
    witness: [],
  )
  let assert Ok(value) = oni_bitcoin.amount_from_sats(1000)
  let output = oni_bitcoin.TxOut(
    value: value,
    script_pubkey: oni_bitcoin.script_from_bytes(<<>>),
  )
  let tx = oni_bitcoin.Transaction(
    version: 1,
    inputs: [input],
    outputs: [output],
    lock_time: 0,
  )

  let result = validation.validate_tx_stateless(tx)
  result |> should.be_ok
}

pub fn validate_tx_duplicate_inputs_test() {
  let assert Ok(hash) = oni_bitcoin.hash256_from_bytes(<<1:256>>)
  let outpoint = oni_bitcoin.OutPoint(
    txid: oni_bitcoin.Txid(hash),
    vout: 0,
  )
  let input = oni_bitcoin.TxIn(
    prevout: outpoint,
    script_sig: oni_bitcoin.script_from_bytes(<<>>),
    sequence: 0xFFFFFFFF,
    witness: [],
  )
  let assert Ok(value) = oni_bitcoin.amount_from_sats(1000)
  let output = oni_bitcoin.TxOut(
    value: value,
    script_pubkey: oni_bitcoin.script_from_bytes(<<>>),
  )
  // Same input twice = duplicate
  let tx = oni_bitcoin.Transaction(
    version: 1,
    inputs: [input, input],
    outputs: [output],
    lock_time: 0,
  )

  let result = validation.validate_tx_stateless(tx)
  result |> should.be_error
}

pub fn calculate_tx_weight_test() {
  let assert Ok(hash) = oni_bitcoin.hash256_from_bytes(<<1:256>>)
  let outpoint = oni_bitcoin.OutPoint(
    txid: oni_bitcoin.Txid(hash),
    vout: 0,
  )
  let input = oni_bitcoin.TxIn(
    prevout: outpoint,
    script_sig: oni_bitcoin.script_from_bytes(<<>>),
    sequence: 0xFFFFFFFF,
    witness: [],
  )
  let assert Ok(value) = oni_bitcoin.amount_from_sats(1000)
  let output = oni_bitcoin.TxOut(
    value: value,
    script_pubkey: oni_bitcoin.script_from_bytes(<<>>),
  )
  let tx = oni_bitcoin.Transaction(
    version: 1,
    inputs: [input],
    outputs: [output],
    lock_time: 0,
  )

  let weight = validation.calculate_tx_weight(tx)
  // Weight should be positive and reasonable
  should.be_true(weight > 0)
  should.be_true(weight < validation.max_tx_weight)
}

pub fn sighash_type_all_test() {
  let sh = validation.sighash_type_from_byte(0x01)
  sh |> should.equal(validation.SighashAll)
}

pub fn sighash_type_none_test() {
  let sh = validation.sighash_type_from_byte(0x02)
  sh |> should.equal(validation.SighashNone)
}

pub fn sighash_type_single_test() {
  let sh = validation.sighash_type_from_byte(0x03)
  sh |> should.equal(validation.SighashSingle)
}

pub fn sighash_type_anyonecanpay_all_test() {
  let sh = validation.sighash_type_from_byte(0x81)
  sh |> should.equal(validation.SighashAnyoneCanPay(validation.SighashAll))
}

pub fn constants_validation_test() {
  validation.max_tx_weight |> should.equal(4_000_000)
  validation.max_block_weight |> should.equal(4_000_000)
  validation.coinbase_maturity |> should.equal(100)
  validation.witness_scale_factor |> should.equal(4)
  validation.locktime_threshold |> should.equal(500_000_000)
}

pub fn utxo_view_operations_test() {
  // Create an empty UTXO view
  let view = oni_storage.utxo_view_new()

  // Create an outpoint
  let assert Ok(hash) = oni_bitcoin.hash256_from_bytes(<<1:256>>)
  let outpoint = oni_bitcoin.OutPoint(
    txid: oni_bitcoin.Txid(hash),
    vout: 0,
  )

  // Should not find the coin initially
  oni_storage.utxo_has(view, outpoint) |> should.be_false

  // Add a coin
  let assert Ok(value) = oni_bitcoin.amount_from_sats(5000)
  let output = oni_bitcoin.TxOut(
    value: value,
    script_pubkey: oni_bitcoin.script_from_bytes(<<>>),
  )
  let coin = oni_storage.coin_new(output, 100, False)
  let view2 = oni_storage.utxo_add(view, outpoint, coin)

  // Should find it now
  oni_storage.utxo_has(view2, outpoint) |> should.be_true

  // Remove it
  let view3 = oni_storage.utxo_remove(view2, outpoint)
  oni_storage.utxo_has(view3, outpoint) |> should.be_false
}

pub fn coin_maturity_test() {
  let assert Ok(value) = oni_bitcoin.amount_from_sats(5_000_000_000)
  let output = oni_bitcoin.TxOut(
    value: value,
    script_pubkey: oni_bitcoin.script_from_bytes(<<>>),
  )

  // Non-coinbase is always mature
  let regular_coin = oni_storage.coin_new(output, 100, False)
  oni_storage.coin_is_mature(regular_coin, 101) |> should.be_true
  oni_storage.coin_is_mature(regular_coin, 100) |> should.be_true

  // Coinbase needs 100 confirmations
  let coinbase_coin = oni_storage.coin_new(output, 100, True)
  oni_storage.coin_is_mature(coinbase_coin, 199) |> should.be_false
  oni_storage.coin_is_mature(coinbase_coin, 200) |> should.be_true
  oni_storage.coin_is_mature(coinbase_coin, 201) |> should.be_true
}
