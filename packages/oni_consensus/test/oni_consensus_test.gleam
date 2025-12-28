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

// ============================================================================
// Merkle Root Computation Tests
// ============================================================================

pub fn merkle_root_empty_test() {
  let txids: List(oni_bitcoin.Hash256) = []
  let root = oni_consensus.compute_merkle_root(txids)
  // Empty list should return zero hash
  root.bytes |> should.equal(<<0:256>>)
}

pub fn merkle_root_single_test() {
  // Single txid should be the merkle root
  let assert Ok(txid) = oni_bitcoin.hash256_from_bytes(<<1:256>>)
  let root = oni_consensus.compute_merkle_root([txid])
  root |> should.equal(txid)
}

pub fn merkle_root_two_test() {
  // Two txids - hash them together
  let assert Ok(txid1) = oni_bitcoin.hash256_from_bytes(<<1:256>>)
  let assert Ok(txid2) = oni_bitcoin.hash256_from_bytes(<<2:256>>)
  let root = oni_consensus.compute_merkle_root([txid1, txid2])
  // The root should be hash256(txid1 || txid2)
  let expected = oni_bitcoin.hash256_digest(bit_array.concat([txid1.bytes, txid2.bytes]))
  root |> should.equal(expected)
}

pub fn merkle_root_three_test() {
  // Three txids - should duplicate the last one for pairing
  let assert Ok(txid1) = oni_bitcoin.hash256_from_bytes(<<1:256>>)
  let assert Ok(txid2) = oni_bitcoin.hash256_from_bytes(<<2:256>>)
  let assert Ok(txid3) = oni_bitcoin.hash256_from_bytes(<<3:256>>)
  let root = oni_consensus.compute_merkle_root([txid1, txid2, txid3])
  // First level: hash(txid1||txid2), hash(txid3||txid3)
  let hash12 = oni_bitcoin.hash256_digest(bit_array.concat([txid1.bytes, txid2.bytes]))
  let hash33 = oni_bitcoin.hash256_digest(bit_array.concat([txid3.bytes, txid3.bytes]))
  // Second level: hash(hash12||hash33)
  let expected = oni_bitcoin.hash256_digest(bit_array.concat([hash12.bytes, hash33.bytes]))
  root |> should.equal(expected)
}

// ============================================================================
// Witness Commitment Tests
// ============================================================================

pub fn witness_commitment_test() {
  let assert Ok(wtxid_root) = oni_bitcoin.hash256_from_bytes(<<1:256>>)
  let nonce = <<0:256>>
  let commitment = oni_consensus.compute_witness_commitment(wtxid_root, nonce)
  // The commitment should be hash256(wtxid_root || nonce)
  let expected = oni_bitcoin.hash256_digest(bit_array.concat([wtxid_root.bytes, nonce]))
  commitment |> should.equal(expected)
}

// ============================================================================
// Signature Context Tests
// ============================================================================

pub fn sig_context_new_test() {
  // Create a simple transaction for testing
  let assert Ok(hash) = oni_bitcoin.hash256_from_bytes(<<1:256>>)
  let outpoint = oni_bitcoin.OutPoint(txid: oni_bitcoin.Txid(hash), vout: 0)
  let assert Ok(value) = oni_bitcoin.amount_from_sats(1000)
  let input = oni_bitcoin.TxIn(
    outpoint,
    oni_bitcoin.script_from_bytes(<<>>),
    0xffffffff,
    [],
  )
  let output = oni_bitcoin.TxOut(
    value,
    oni_bitcoin.script_from_bytes(<<>>),
  )
  let tx = oni_bitcoin.Transaction(
    version: 1,
    inputs: [input],
    outputs: [output],
    lock_time: 0,
  )

  let script_code = oni_bitcoin.script_from_bytes(<<0x76, 0xa9>>)  // OP_DUP OP_HASH160

  // Create sig context
  let sig_ctx = oni_consensus.sig_context_new(
    tx,
    0,  // input_index
    value,  // spent_value
    script_code,
    False,  // not segwit
    False,  // not taproot
  )

  sig_ctx.input_index |> should.equal(0)
  sig_ctx.is_segwit |> should.be_false
  sig_ctx.is_taproot |> should.be_false
}

pub fn script_context_with_sig_test() {
  // Create a simple transaction for testing
  let assert Ok(hash) = oni_bitcoin.hash256_from_bytes(<<1:256>>)
  let outpoint = oni_bitcoin.OutPoint(txid: oni_bitcoin.Txid(hash), vout: 0)
  let assert Ok(value) = oni_bitcoin.amount_from_sats(1000)
  let input = oni_bitcoin.TxIn(
    outpoint,
    oni_bitcoin.script_from_bytes(<<>>),
    0xffffffff,
    [],
  )
  let output = oni_bitcoin.TxOut(
    value,
    oni_bitcoin.script_from_bytes(<<>>),
  )
  let tx = oni_bitcoin.Transaction(
    version: 1,
    inputs: [input],
    outputs: [output],
    lock_time: 0,
  )

  let script_code = oni_bitcoin.script_from_bytes(<<0x76, 0xa9>>)
  let sig_ctx = oni_consensus.sig_context_new(tx, 0, value, script_code, True, False)

  let flags = oni_consensus.default_script_flags()
  let ctx = oni_consensus.script_context_with_sig(<<0x51>>, flags, sig_ctx)  // OP_TRUE

  // Execute script
  let result = oni_consensus.execute_script(ctx)
  result |> should.be_ok

  // Verify sig_ctx is present
  case ctx.sig_ctx {
    oni_consensus.SigContextSome(_) -> should.be_true(True)
    oni_consensus.SigContextNone -> should.fail()
  }
}

// ============================================================================
// Script Checksig Tests (Stub Verification)
// ============================================================================

pub fn execute_checksig_without_context_test() {
  // Without sig context, CHECKSIG should push 0 (false)
  let flags = oni_consensus.default_script_flags()
  // Push fake signature, push fake pubkey, then OP_CHECKSIG
  // 0x02 0xab 0xcd = push 2 bytes (signature)
  // 0x02 0x12 0x34 = push 2 bytes (pubkey)
  // 0xac = OP_CHECKSIG
  let script = <<0x02, 0xab, 0xcd, 0x02, 0x12, 0x34, 0xac>>
  let ctx = oni_consensus.script_context_new(script, flags)

  let result = oni_consensus.execute_script(ctx)
  result |> should.be_ok

  let assert Ok(final_ctx) = result
  // Without context, verify_signature returns false, so stack top should be empty (false)
  case final_ctx.stack {
    [top, ..] -> {
      // Top should be empty (false) since no sig context
      bit_array.byte_size(top) |> should.equal(0)
    }
    _ -> should.fail()
  }
}

pub fn execute_checksigverify_without_context_fails_test() {
  // Without sig context, CHECKSIGVERIFY should fail
  let flags = oni_consensus.default_script_flags()
  // Push fake signature, push fake pubkey, then OP_CHECKSIGVERIFY
  let script = <<0x02, 0xab, 0xcd, 0x02, 0x12, 0x34, 0xad>>
  let ctx = oni_consensus.script_context_new(script, flags)

  let result = oni_consensus.execute_script(ctx)
  // Should fail because verification fails without context
  case result {
    Error(oni_consensus.ScriptCheckSigFailed) -> should.be_true(True)
    _ -> should.fail()
  }
}

// ============================================================================
// Script Multisig Tests
// ============================================================================

pub fn execute_checkmultisig_0_of_0_test() {
  // 0-of-0 multisig: OP_0 OP_0 OP_0 OP_CHECKMULTISIG
  // Dummy, 0 sigs, 0 pubkeys
  let flags = oni_consensus.default_script_flags()
  let script = <<0x00, 0x00, 0x00, 0xae>>
  let ctx = oni_consensus.script_context_new(script, flags)

  let result = oni_consensus.execute_script(ctx)
  result |> should.be_ok

  let assert Ok(final_ctx) = result
  case final_ctx.stack {
    [top] -> {
      // 0-of-0 should succeed, pushing 1
      top |> should.equal(<<1:8>>)
    }
    _ -> should.fail()
  }
}

// ============================================================================
// Additional Stack Operation Tests
// ============================================================================

pub fn execute_op_hash160_test() {
  let flags = oni_consensus.default_script_flags()
  // Push 1 byte (0x01), then OP_HASH160
  let script = <<0x01, 0x01, 0xa9>>
  let ctx = oni_consensus.script_context_new(script, flags)

  let result = oni_consensus.execute_script(ctx)
  result |> should.be_ok

  let assert Ok(final_ctx) = result
  case final_ctx.stack {
    [hash] -> {
      // HASH160 output should be 20 bytes
      bit_array.byte_size(hash) |> should.equal(20)
    }
    _ -> should.fail()
  }
}

pub fn execute_op_sha256_test() {
  let flags = oni_consensus.default_script_flags()
  // Push 1 byte (0x01), then OP_SHA256
  let script = <<0x01, 0x01, 0xa8>>
  let ctx = oni_consensus.script_context_new(script, flags)

  let result = oni_consensus.execute_script(ctx)
  result |> should.be_ok

  let assert Ok(final_ctx) = result
  case final_ctx.stack {
    [hash] -> {
      // SHA256 output should be 32 bytes
      bit_array.byte_size(hash) |> should.equal(32)
    }
    _ -> should.fail()
  }
}

pub fn execute_op_hash256_test() {
  let flags = oni_consensus.default_script_flags()
  // Push 1 byte (0x01), then OP_HASH256
  let script = <<0x01, 0x01, 0xaa>>
  let ctx = oni_consensus.script_context_new(script, flags)

  let result = oni_consensus.execute_script(ctx)
  result |> should.be_ok

  let assert Ok(final_ctx) = result
  case final_ctx.stack {
    [hash] -> {
      // HASH256 output should be 32 bytes
      bit_array.byte_size(hash) |> should.equal(32)
    }
    _ -> should.fail()
  }
}

// ============================================================================
// Sighash Type Constants Tests
// ============================================================================

pub fn sighash_constants_test() {
  oni_consensus.sighash_all |> should.equal(0x01)
  oni_consensus.sighash_none |> should.equal(0x02)
  oni_consensus.sighash_single |> should.equal(0x03)
  oni_consensus.sighash_anyonecanpay |> should.equal(0x80)
}

// ============================================================================
// Advanced Script Execution Tests
// ============================================================================

pub fn execute_op_verify_true_test() {
  let flags = oni_consensus.default_script_flags()
  // Push 1, then OP_VERIFY - should succeed (consume the 1)
  let script = <<0x51, 0x69>>
  let ctx = oni_consensus.script_context_new(script, flags)

  let result = oni_consensus.execute_script(ctx)
  result |> should.be_ok

  let assert Ok(final_ctx) = result
  // Stack should be empty after VERIFY consumes the truthy value
  final_ctx.stack |> should.equal([])
}

pub fn execute_op_verify_false_test() {
  let flags = oni_consensus.default_script_flags()
  // Push 0, then OP_VERIFY - should fail
  let script = <<0x00, 0x69>>
  let ctx = oni_consensus.script_context_new(script, flags)

  let result = oni_consensus.execute_script(ctx)
  // Should fail because 0 is falsy
  result |> should.be_error
}

pub fn execute_op_drop_test() {
  let flags = oni_consensus.default_script_flags()
  // Push 1, Push 2, then OP_DROP - should leave only 1 on stack
  let script = <<0x51, 0x52, 0x75>>
  let ctx = oni_consensus.script_context_new(script, flags)

  let result = oni_consensus.execute_script(ctx)
  result |> should.be_ok

  let assert Ok(final_ctx) = result
  case final_ctx.stack {
    [<<1:8>>] -> should.be_true(True)
    _ -> should.fail()
  }
}

pub fn execute_op_2drop_test() {
  let flags = oni_consensus.default_script_flags()
  // Push 1, Push 2, Push 3, then OP_2DROP - should leave only 1 on stack
  let script = <<0x51, 0x52, 0x53, 0x6d>>
  let ctx = oni_consensus.script_context_new(script, flags)

  let result = oni_consensus.execute_script(ctx)
  result |> should.be_ok

  let assert Ok(final_ctx) = result
  case final_ctx.stack {
    [<<1:8>>] -> should.be_true(True)
    _ -> should.fail()
  }
}

pub fn execute_op_swap_test() {
  let flags = oni_consensus.default_script_flags()
  // Push 1, Push 2, then OP_SWAP - stack should be [1, 2] (top to bottom)
  let script = <<0x51, 0x52, 0x7c>>
  let ctx = oni_consensus.script_context_new(script, flags)

  let result = oni_consensus.execute_script(ctx)
  result |> should.be_ok

  let assert Ok(final_ctx) = result
  case final_ctx.stack {
    [<<1:8>>, <<2:8>>] -> should.be_true(True)
    _ -> should.fail()
  }
}

pub fn execute_op_over_test() {
  let flags = oni_consensus.default_script_flags()
  // Push 1, Push 2, then OP_OVER - stack should be [1, 2, 1]
  let script = <<0x51, 0x52, 0x78>>
  let ctx = oni_consensus.script_context_new(script, flags)

  let result = oni_consensus.execute_script(ctx)
  result |> should.be_ok

  let assert Ok(final_ctx) = result
  case final_ctx.stack {
    [<<1:8>>, <<2:8>>, <<1:8>>] -> should.be_true(True)
    _ -> should.fail()
  }
}

pub fn execute_op_size_test() {
  let flags = oni_consensus.default_script_flags()
  // Push 3 bytes, then OP_SIZE - should push 3 on top
  let script = <<0x03, 0x01, 0x02, 0x03, 0x82>>
  let ctx = oni_consensus.script_context_new(script, flags)

  let result = oni_consensus.execute_script(ctx)
  result |> should.be_ok

  let assert Ok(final_ctx) = result
  case final_ctx.stack {
    [<<3:8>>, _original] -> should.be_true(True)
    _ -> should.fail()
  }
}

pub fn execute_op_sub_test() {
  let flags = oni_consensus.default_script_flags()
  // Push 5, Push 3, OP_SUB -> should leave 2 on stack
  let script = <<0x55, 0x53, 0x94>>
  let ctx = oni_consensus.script_context_new(script, flags)

  let result = oni_consensus.execute_script(ctx)
  result |> should.be_ok

  let assert Ok(final_ctx) = result
  case final_ctx.stack {
    [<<2:8>>] -> should.be_true(True)
    _ -> should.fail()
  }
}

pub fn execute_op_negate_test() {
  let flags = oni_consensus.default_script_flags()
  // Push 5, OP_NEGATE -> should leave -5 on stack
  let script = <<0x55, 0x8f>>
  let ctx = oni_consensus.script_context_new(script, flags)

  let result = oni_consensus.execute_script(ctx)
  result |> should.be_ok

  let assert Ok(final_ctx) = result
  case final_ctx.stack {
    [top] -> {
      // -5 in script number encoding is 0x85
      top |> should.equal(<<0x85>>)
    }
    _ -> should.fail()
  }
}

pub fn execute_op_abs_test() {
  let flags = oni_consensus.default_script_flags()
  // Push -5 (0x85), OP_ABS -> should leave 5 on stack
  let script = <<0x01, 0x85, 0x90>>
  let ctx = oni_consensus.script_context_new(script, flags)

  let result = oni_consensus.execute_script(ctx)
  result |> should.be_ok

  let assert Ok(final_ctx) = result
  case final_ctx.stack {
    [<<5:8>>] -> should.be_true(True)
    _ -> should.fail()
  }
}

pub fn execute_op_not_true_test() {
  let flags = oni_consensus.default_script_flags()
  // Push 0, OP_NOT -> should leave 1 on stack
  let script = <<0x00, 0x91>>
  let ctx = oni_consensus.script_context_new(script, flags)

  let result = oni_consensus.execute_script(ctx)
  result |> should.be_ok

  let assert Ok(final_ctx) = result
  case final_ctx.stack {
    [<<1:8>>] -> should.be_true(True)
    _ -> should.fail()
  }
}

pub fn execute_op_not_false_test() {
  let flags = oni_consensus.default_script_flags()
  // Push 1, OP_NOT -> should leave 0 on stack
  let script = <<0x51, 0x91>>
  let ctx = oni_consensus.script_context_new(script, flags)

  let result = oni_consensus.execute_script(ctx)
  result |> should.be_ok

  let assert Ok(final_ctx) = result
  case final_ctx.stack {
    [<<>>] -> should.be_true(True)
    _ -> should.fail()
  }
}

pub fn execute_op_booland_test() {
  let flags = oni_consensus.default_script_flags()
  // Push 1, Push 1, OP_BOOLAND -> should leave 1 on stack
  let script = <<0x51, 0x51, 0x9a>>
  let ctx = oni_consensus.script_context_new(script, flags)

  let result = oni_consensus.execute_script(ctx)
  result |> should.be_ok

  let assert Ok(final_ctx) = result
  case final_ctx.stack {
    [<<1:8>>] -> should.be_true(True)
    _ -> should.fail()
  }
}

pub fn execute_op_boolor_test() {
  let flags = oni_consensus.default_script_flags()
  // Push 0, Push 1, OP_BOOLOR -> should leave 1 on stack
  let script = <<0x00, 0x51, 0x9b>>
  let ctx = oni_consensus.script_context_new(script, flags)

  let result = oni_consensus.execute_script(ctx)
  result |> should.be_ok

  let assert Ok(final_ctx) = result
  case final_ctx.stack {
    [<<1:8>>] -> should.be_true(True)
    _ -> should.fail()
  }
}

pub fn execute_op_numequal_test() {
  let flags = oni_consensus.default_script_flags()
  // Push 5, Push 5, OP_NUMEQUAL -> should leave 1 on stack
  let script = <<0x55, 0x55, 0x9c>>
  let ctx = oni_consensus.script_context_new(script, flags)

  let result = oni_consensus.execute_script(ctx)
  result |> should.be_ok

  let assert Ok(final_ctx) = result
  case final_ctx.stack {
    [<<1:8>>] -> should.be_true(True)
    _ -> should.fail()
  }
}

pub fn execute_op_numnotequal_test() {
  let flags = oni_consensus.default_script_flags()
  // Push 5, Push 3, OP_NUMNOTEQUAL -> should leave 1 on stack
  let script = <<0x55, 0x53, 0x9e>>
  let ctx = oni_consensus.script_context_new(script, flags)

  let result = oni_consensus.execute_script(ctx)
  result |> should.be_ok

  let assert Ok(final_ctx) = result
  case final_ctx.stack {
    [<<1:8>>] -> should.be_true(True)
    _ -> should.fail()
  }
}

pub fn execute_op_lessthan_test() {
  let flags = oni_consensus.default_script_flags()
  // Push 3, Push 5, OP_LESSTHAN -> should leave 1 on stack (3 < 5)
  let script = <<0x53, 0x55, 0x9f>>
  let ctx = oni_consensus.script_context_new(script, flags)

  let result = oni_consensus.execute_script(ctx)
  result |> should.be_ok

  let assert Ok(final_ctx) = result
  case final_ctx.stack {
    [<<1:8>>] -> should.be_true(True)
    _ -> should.fail()
  }
}

pub fn execute_op_greaterthan_test() {
  let flags = oni_consensus.default_script_flags()
  // Push 5, Push 3, OP_GREATERTHAN -> should leave 1 on stack (5 > 3)
  let script = <<0x55, 0x53, 0xa0>>
  let ctx = oni_consensus.script_context_new(script, flags)

  let result = oni_consensus.execute_script(ctx)
  result |> should.be_ok

  let assert Ok(final_ctx) = result
  case final_ctx.stack {
    [<<1:8>>] -> should.be_true(True)
    _ -> should.fail()
  }
}

pub fn execute_op_within_test() {
  let flags = oni_consensus.default_script_flags()
  // Push 5, Push 3, Push 7, OP_WITHIN -> should leave 1 on stack (3 <= 5 < 7)
  let script = <<0x55, 0x53, 0x57, 0xa5>>
  let ctx = oni_consensus.script_context_new(script, flags)

  let result = oni_consensus.execute_script(ctx)
  result |> should.be_ok

  let assert Ok(final_ctx) = result
  case final_ctx.stack {
    [<<1:8>>] -> should.be_true(True)
    _ -> should.fail()
  }
}

pub fn execute_op_if_else_endif_true_test() {
  let flags = oni_consensus.default_script_flags()
  // Push 1, OP_IF, Push 2, OP_ELSE, Push 3, OP_ENDIF
  // Should execute the IF branch and push 2
  let script = <<0x51, 0x63, 0x52, 0x67, 0x53, 0x68>>
  let ctx = oni_consensus.script_context_new(script, flags)

  let result = oni_consensus.execute_script(ctx)
  result |> should.be_ok

  let assert Ok(final_ctx) = result
  case final_ctx.stack {
    [<<2:8>>] -> should.be_true(True)
    _ -> should.fail()
  }
}

pub fn execute_op_if_else_endif_false_test() {
  let flags = oni_consensus.default_script_flags()
  // Push 0, OP_IF, Push 2, OP_ELSE, Push 3, OP_ENDIF
  // Should execute the ELSE branch and push 3
  let script = <<0x00, 0x63, 0x52, 0x67, 0x53, 0x68>>
  let ctx = oni_consensus.script_context_new(script, flags)

  let result = oni_consensus.execute_script(ctx)
  result |> should.be_ok

  let assert Ok(final_ctx) = result
  case final_ctx.stack {
    [<<3:8>>] -> should.be_true(True)
    _ -> should.fail()
  }
}

pub fn execute_op_notif_test() {
  let flags = oni_consensus.default_script_flags()
  // Push 0, OP_NOTIF, Push 5, OP_ENDIF
  // Should execute the NOTIF branch (since condition is false)
  let script = <<0x00, 0x64, 0x55, 0x68>>
  let ctx = oni_consensus.script_context_new(script, flags)

  let result = oni_consensus.execute_script(ctx)
  result |> should.be_ok

  let assert Ok(final_ctx) = result
  case final_ctx.stack {
    [<<5:8>>] -> should.be_true(True)
    _ -> should.fail()
  }
}

pub fn execute_op_ripemd160_test() {
  let flags = oni_consensus.default_script_flags()
  // Push 1 byte (0x01), then OP_RIPEMD160
  let script = <<0x01, 0x01, 0xa6>>
  let ctx = oni_consensus.script_context_new(script, flags)

  let result = oni_consensus.execute_script(ctx)
  result |> should.be_ok

  let assert Ok(final_ctx) = result
  case final_ctx.stack {
    [hash] -> {
      // RIPEMD160 output should be 20 bytes
      bit_array.byte_size(hash) |> should.equal(20)
    }
    _ -> should.fail()
  }
}

// ============================================================================
// P2PKH Standard Script Test
// ============================================================================

pub fn parse_p2pkh_script_test() {
  // Standard P2PKH scriptPubKey: OP_DUP OP_HASH160 <20 bytes> OP_EQUALVERIFY OP_CHECKSIG
  // We'll use a placeholder 20-byte hash
  let pubkey_hash = <<
    0x89, 0xab, 0xcd, 0xef, 0x01, 0x23, 0x45, 0x67, 0x89, 0xab,
    0xcd, 0xef, 0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef
  >>
  let script = bit_array.concat([
    <<0x76>>,  // OP_DUP
    <<0xa9>>,  // OP_HASH160
    <<0x14>>,  // Push 20 bytes
    pubkey_hash,
    <<0x88>>,  // OP_EQUALVERIFY
    <<0xac>>,  // OP_CHECKSIG
  ])

  let result = oni_consensus.parse_script(script)
  result |> should.be_ok

  let assert Ok(elements) = result
  // Should have 5 elements: DUP, HASH160, <pubkey_hash>, EQUALVERIFY, CHECKSIG
  list.length(elements) |> should.equal(5)
}

// ============================================================================
// Disabled Opcodes Tests
// ============================================================================

pub fn disabled_opcodes_test() {
  // Verify all disabled opcodes
  oni_consensus.opcode_is_disabled(oni_consensus.OpCat) |> should.be_true
  oni_consensus.opcode_is_disabled(oni_consensus.OpSubstr) |> should.be_true
  oni_consensus.opcode_is_disabled(oni_consensus.OpLeft) |> should.be_true
  oni_consensus.opcode_is_disabled(oni_consensus.OpRight) |> should.be_true
  oni_consensus.opcode_is_disabled(oni_consensus.OpInvert) |> should.be_true
  oni_consensus.opcode_is_disabled(oni_consensus.OpAnd) |> should.be_true
  oni_consensus.opcode_is_disabled(oni_consensus.OpOr) |> should.be_true
  oni_consensus.opcode_is_disabled(oni_consensus.OpXor) |> should.be_true
  oni_consensus.opcode_is_disabled(oni_consensus.Op2Mul) |> should.be_true
  oni_consensus.opcode_is_disabled(oni_consensus.Op2Div) |> should.be_true
  oni_consensus.opcode_is_disabled(oni_consensus.OpMul) |> should.be_true
  oni_consensus.opcode_is_disabled(oni_consensus.OpDiv) |> should.be_true
  oni_consensus.opcode_is_disabled(oni_consensus.OpMod) |> should.be_true
  oni_consensus.opcode_is_disabled(oni_consensus.OpLShift) |> should.be_true
  oni_consensus.opcode_is_disabled(oni_consensus.OpRShift) |> should.be_true

  // Verify enabled opcodes
  oni_consensus.opcode_is_disabled(oni_consensus.OpDup) |> should.be_false
  oni_consensus.opcode_is_disabled(oni_consensus.OpHash160) |> should.be_false
  oni_consensus.opcode_is_disabled(oni_consensus.OpCheckSig) |> should.be_false
}

// ============================================================================
// Script Number Edge Cases
// ============================================================================

pub fn encode_script_num_256_test() {
  // 256 = 0x0100
  oni_consensus.encode_script_num(256) |> should.equal(<<0x00, 0x01>>)
}

pub fn encode_script_num_negative_128_test() {
  // -128 = 0x8080 (128 with negative sign in next byte)
  oni_consensus.encode_script_num(-128) |> should.equal(<<0x80, 0x80>>)
}

pub fn decode_script_num_256_test() {
  oni_consensus.decode_script_num(<<0x00, 0x01>>) |> should.equal(Ok(256))
}

pub fn decode_script_num_negative_256_test() {
  oni_consensus.decode_script_num(<<0x00, 0x81>>) |> should.equal(Ok(-256))
}

// ============================================================================
// OP_SHA1 Tests
// ============================================================================

pub fn execute_op_sha1_test() {
  let flags = oni_consensus.default_script_flags()
  // Push 1 byte (0x01), then OP_SHA1 (0xa7)
  let script = <<0x01, 0x01, 0xa7>>
  let ctx = oni_consensus.script_context_new(script, flags)

  let result = oni_consensus.execute_script(ctx)
  result |> should.be_ok

  let assert Ok(final_ctx) = result
  case final_ctx.stack {
    [hash] -> {
      // SHA1 output should be 20 bytes
      bit_array.byte_size(hash) |> should.equal(20)
    }
    _ -> should.fail()
  }
}

pub fn execute_op_sha1_known_value_test() {
  let flags = oni_consensus.default_script_flags()
  // SHA1 of empty string is well-known: da39a3ee5e6b4b0d3255bfef95601890afd80709
  // Push 0 bytes (empty), then OP_SHA1
  let script = <<0x00, 0xa7>>
  let ctx = oni_consensus.script_context_new(script, flags)

  let result = oni_consensus.execute_script(ctx)
  result |> should.be_ok

  let assert Ok(final_ctx) = result
  case final_ctx.stack {
    [hash] -> {
      bit_array.byte_size(hash) |> should.equal(20)
      // Verify it's the SHA1 of empty string
      hash |> should.equal(<<0xda, 0x39, 0xa3, 0xee, 0x5e, 0x6b, 0x4b, 0x0d,
        0x32, 0x55, 0xbf, 0xef, 0x95, 0x60, 0x18, 0x90, 0xaf, 0xd8, 0x07, 0x09>>)
    }
    _ -> should.fail()
  }
}

// ============================================================================
// OP_CHECKLOCKTIMEVERIFY Tests (BIP65)
// ============================================================================

pub fn execute_cltv_without_context_fails_test() {
  // CLTV without transaction context should fail
  let flags = oni_consensus.default_script_flags()
  // Push locktime 100, then OP_CHECKLOCKTIMEVERIFY (0xb1)
  let script = <<0x01, 0x64, 0xb1>>
  let ctx = oni_consensus.script_context_new(script, flags)

  let result = oni_consensus.execute_script(ctx)
  // Should fail because no transaction context
  case result {
    Error(oni_consensus.ScriptCheckLockTimeVerifyFailed) -> should.be_true(True)
    _ -> should.fail()
  }
}

pub fn execute_cltv_with_context_succeeds_test() {
  // Create a transaction with locktime 500 and sequence not final
  let assert Ok(hash) = oni_bitcoin.hash256_from_bytes(<<1:256>>)
  let outpoint = oni_bitcoin.OutPoint(txid: oni_bitcoin.Txid(hash), vout: 0)
  let assert Ok(value) = oni_bitcoin.amount_from_sats(1000)
  let input = oni_bitcoin.TxIn(
    prevout: outpoint,
    script_sig: oni_bitcoin.script_from_bytes(<<>>),
    sequence: 0xfffffffe,  // Not final (0xffffffff would be final)
    witness: [],
  )
  let output = oni_bitcoin.TxOut(
    value: value,
    script_pubkey: oni_bitcoin.script_from_bytes(<<>>),
  )
  let tx = oni_bitcoin.Transaction(
    version: 1,
    inputs: [input],
    outputs: [output],
    lock_time: 500,  // tx locktime
  )

  let script_code = oni_bitcoin.script_from_bytes(<<>>)
  let sig_ctx = oni_consensus.sig_context_new(tx, 0, value, script_code, False, False)

  let flags = oni_consensus.default_script_flags()
  // Push locktime 100 (less than tx locktime 500), then CLTV
  // OP_PUSHBYTES_1 100 OP_CHECKLOCKTIMEVERIFY OP_DROP OP_TRUE
  let script = <<0x01, 0x64, 0xb1, 0x75, 0x51>>
  let ctx = oni_consensus.script_context_with_sig(script, flags, sig_ctx)

  let result = oni_consensus.execute_script(ctx)
  result |> should.be_ok
}

pub fn execute_cltv_locktime_not_reached_fails_test() {
  // Create a transaction with locktime 50 (less than required 100)
  let assert Ok(hash) = oni_bitcoin.hash256_from_bytes(<<1:256>>)
  let outpoint = oni_bitcoin.OutPoint(txid: oni_bitcoin.Txid(hash), vout: 0)
  let assert Ok(value) = oni_bitcoin.amount_from_sats(1000)
  let input = oni_bitcoin.TxIn(
    prevout: outpoint,
    script_sig: oni_bitcoin.script_from_bytes(<<>>),
    sequence: 0xfffffffe,
    witness: [],
  )
  let output = oni_bitcoin.TxOut(
    value: value,
    script_pubkey: oni_bitcoin.script_from_bytes(<<>>),
  )
  let tx = oni_bitcoin.Transaction(
    version: 1,
    inputs: [input],
    outputs: [output],
    lock_time: 50,  // Less than required
  )

  let script_code = oni_bitcoin.script_from_bytes(<<>>)
  let sig_ctx = oni_consensus.sig_context_new(tx, 0, value, script_code, False, False)

  let flags = oni_consensus.default_script_flags()
  // Push locktime 100, then CLTV
  let script = <<0x01, 0x64, 0xb1>>
  let ctx = oni_consensus.script_context_with_sig(script, flags, sig_ctx)

  let result = oni_consensus.execute_script(ctx)
  case result {
    Error(oni_consensus.ScriptCheckLockTimeVerifyFailed) -> should.be_true(True)
    _ -> should.fail()
  }
}

pub fn execute_cltv_final_sequence_fails_test() {
  // CLTV fails if input sequence is 0xffffffff (final)
  let assert Ok(hash) = oni_bitcoin.hash256_from_bytes(<<1:256>>)
  let outpoint = oni_bitcoin.OutPoint(txid: oni_bitcoin.Txid(hash), vout: 0)
  let assert Ok(value) = oni_bitcoin.amount_from_sats(1000)
  let input = oni_bitcoin.TxIn(
    prevout: outpoint,
    script_sig: oni_bitcoin.script_from_bytes(<<>>),
    sequence: 0xffffffff,  // Final!
    witness: [],
  )
  let output = oni_bitcoin.TxOut(
    value: value,
    script_pubkey: oni_bitcoin.script_from_bytes(<<>>),
  )
  let tx = oni_bitcoin.Transaction(
    version: 1,
    inputs: [input],
    outputs: [output],
    lock_time: 500,
  )

  let script_code = oni_bitcoin.script_from_bytes(<<>>)
  let sig_ctx = oni_consensus.sig_context_new(tx, 0, value, script_code, False, False)

  let flags = oni_consensus.default_script_flags()
  let script = <<0x01, 0x64, 0xb1>>  // Push 100, CLTV
  let ctx = oni_consensus.script_context_with_sig(script, flags, sig_ctx)

  let result = oni_consensus.execute_script(ctx)
  case result {
    Error(oni_consensus.ScriptCheckLockTimeVerifyFailed) -> should.be_true(True)
    _ -> should.fail()
  }
}

// ============================================================================
// OP_CHECKSEQUENCEVERIFY Tests (BIP112)
// ============================================================================

pub fn execute_csv_without_context_fails_test() {
  // CSV without transaction context should fail
  let flags = oni_consensus.default_script_flags()
  // Push sequence 10, then OP_CHECKSEQUENCEVERIFY (0xb2)
  let script = <<0x01, 0x0a, 0xb2>>
  let ctx = oni_consensus.script_context_new(script, flags)

  let result = oni_consensus.execute_script(ctx)
  case result {
    Error(oni_consensus.ScriptCheckSequenceVerifyFailed) -> should.be_true(True)
    _ -> should.fail()
  }
}

pub fn execute_csv_with_context_succeeds_test() {
  // Create a v2 transaction with proper sequence
  let assert Ok(hash) = oni_bitcoin.hash256_from_bytes(<<1:256>>)
  let outpoint = oni_bitcoin.OutPoint(txid: oni_bitcoin.Txid(hash), vout: 0)
  let assert Ok(value) = oni_bitcoin.amount_from_sats(1000)
  let input = oni_bitcoin.TxIn(
    prevout: outpoint,
    script_sig: oni_bitcoin.script_from_bytes(<<>>),
    sequence: 100,  // 100 blocks relative locktime
    witness: [],
  )
  let output = oni_bitcoin.TxOut(
    value: value,
    script_pubkey: oni_bitcoin.script_from_bytes(<<>>),
  )
  let tx = oni_bitcoin.Transaction(
    version: 2,  // Must be v2 for CSV
    inputs: [input],
    outputs: [output],
    lock_time: 0,
  )

  let script_code = oni_bitcoin.script_from_bytes(<<>>)
  let sig_ctx = oni_consensus.sig_context_new(tx, 0, value, script_code, False, False)

  let flags = oni_consensus.default_script_flags()
  // Push sequence 50 (less than input's 100), then CSV, DROP, TRUE
  let script = <<0x01, 0x32, 0xb2, 0x75, 0x51>>
  let ctx = oni_consensus.script_context_with_sig(script, flags, sig_ctx)

  let result = oni_consensus.execute_script(ctx)
  result |> should.be_ok
}

pub fn execute_csv_v1_transaction_fails_test() {
  // CSV requires transaction version >= 2
  let assert Ok(hash) = oni_bitcoin.hash256_from_bytes(<<1:256>>)
  let outpoint = oni_bitcoin.OutPoint(txid: oni_bitcoin.Txid(hash), vout: 0)
  let assert Ok(value) = oni_bitcoin.amount_from_sats(1000)
  let input = oni_bitcoin.TxIn(
    prevout: outpoint,
    script_sig: oni_bitcoin.script_from_bytes(<<>>),
    sequence: 100,
    witness: [],
  )
  let output = oni_bitcoin.TxOut(
    value: value,
    script_pubkey: oni_bitcoin.script_from_bytes(<<>>),
  )
  let tx = oni_bitcoin.Transaction(
    version: 1,  // v1 - CSV should fail
    inputs: [input],
    outputs: [output],
    lock_time: 0,
  )

  let script_code = oni_bitcoin.script_from_bytes(<<>>)
  let sig_ctx = oni_consensus.sig_context_new(tx, 0, value, script_code, False, False)

  let flags = oni_consensus.default_script_flags()
  let script = <<0x01, 0x32, 0xb2>>  // Push 50, CSV
  let ctx = oni_consensus.script_context_with_sig(script, flags, sig_ctx)

  let result = oni_consensus.execute_script(ctx)
  case result {
    Error(oni_consensus.ScriptCheckSequenceVerifyFailed) -> should.be_true(True)
    _ -> should.fail()
  }
}

pub fn execute_csv_disable_flag_succeeds_test() {
  // When disable flag (bit 31) is set in stack value, CSV is NOP
  let assert Ok(hash) = oni_bitcoin.hash256_from_bytes(<<1:256>>)
  let outpoint = oni_bitcoin.OutPoint(txid: oni_bitcoin.Txid(hash), vout: 0)
  let assert Ok(value) = oni_bitcoin.amount_from_sats(1000)
  let input = oni_bitcoin.TxIn(
    prevout: outpoint,
    script_sig: oni_bitcoin.script_from_bytes(<<>>),
    sequence: 0,  // Even with 0 sequence
    witness: [],
  )
  let output = oni_bitcoin.TxOut(
    value: value,
    script_pubkey: oni_bitcoin.script_from_bytes(<<>>),
  )
  let tx = oni_bitcoin.Transaction(
    version: 2,
    inputs: [input],
    outputs: [output],
    lock_time: 0,
  )

  let script_code = oni_bitcoin.script_from_bytes(<<>>)
  let sig_ctx = oni_consensus.sig_context_new(tx, 0, value, script_code, False, False)

  let flags = oni_consensus.default_script_flags()
  // Push 0x80000000 (disable flag set), CSV, DROP, TRUE
  // 0x80000000 in little-endian script number encoding: 0x00 0x00 0x00 0x80 0x00 (5 bytes with sign)
  // Actually, we need to use a 4-byte push with the value
  // The disable flag is bit 31, so value is 0x80000000
  // In script number: <<0x00, 0x00, 0x00, 0x80, 0x00>> - but this is 5 bytes
  // Let's use a simpler approach: 0xFFFFFF7F is safe (all bits except bit 31)
  // Actually let's just use the disabled flag pattern
  // Push 4 bytes: 0x00 0x00 0x00 0x80, then CSV should be a NOP
  let script = <<0x04, 0x00, 0x00, 0x00, 0x80, 0xb2, 0x75, 0x51>>
  let ctx = oni_consensus.script_context_with_sig(script, flags, sig_ctx)

  let result = oni_consensus.execute_script(ctx)
  // Should succeed because disable flag makes CSV a NOP
  result |> should.be_ok
}
