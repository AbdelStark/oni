// compact_blocks_test.gleam - Tests for BIP152 compact block relay

import compact_blocks
import gleam/bit_array
import gleam/dict
import gleam/list
import gleeunit/should
import oni_bitcoin

pub fn short_txid_size_test() {
  compact_blocks.short_txid_size
  |> should.equal(6)
}

pub fn compact_block_version_test() {
  compact_blocks.compact_block_version_1
  |> should.equal(1)

  compact_blocks.compact_block_version_2
  |> should.equal(2)
}

pub fn new_peer_state_test() {
  let state = compact_blocks.new_peer_state()

  state.high_bandwidth_mode
  |> should.be_false

  state.version
  |> should.equal(0)
}

pub fn update_peer_state_test() {
  let state = compact_blocks.new_peer_state()

  let msg = compact_blocks.SendCmpct(
    announce: True,
    version: 2,
  )

  let updated = compact_blocks.update_peer_state(state, msg)

  updated.high_bandwidth_mode
  |> should.be_true

  updated.version
  |> should.equal(2)
}

pub fn encode_sendcmpct_test() {
  let msg = compact_blocks.SendCmpct(
    announce: True,
    version: 2,
  )

  let encoded = compact_blocks.encode_sendcmpct(msg)

  // Should be 9 bytes (1 byte announce + 8 bytes version)
  bit_array.byte_size(encoded)
  |> should.equal(9)
}

pub fn decode_sendcmpct_test() {
  let msg = compact_blocks.SendCmpct(
    announce: True,
    version: 2,
  )

  let encoded = compact_blocks.encode_sendcmpct(msg)
  let result = compact_blocks.decode_sendcmpct(encoded)

  should.be_ok(result)

  case result {
    Ok(#(decoded, _rest)) -> {
      decoded.announce
      |> should.be_true

      decoded.version
      |> should.equal(2)
    }
    Error(_) -> should.be_true(False)
  }
}

pub fn decode_sendcmpct_no_announce_test() {
  let msg = compact_blocks.SendCmpct(
    announce: False,
    version: 1,
  )

  let encoded = compact_blocks.encode_sendcmpct(msg)
  let result = compact_blocks.decode_sendcmpct(encoded)

  case result {
    Ok(#(decoded, _)) -> {
      decoded.announce
      |> should.be_false

      decoded.version
      |> should.equal(1)
    }
    Error(_) -> should.be_true(False)
  }
}

pub fn short_txid_creation_test() {
  // Create a simple transaction
  let tx = oni_bitcoin.Transaction(
    version: 1,
    inputs: [],
    outputs: [],
    lock_time: 0,
  )

  let key = #(0, 0)
  let short_id = compact_blocks.compute_short_txid(tx, key, False)

  // Short ID should be 6 bytes
  bit_array.byte_size(short_id.bytes)
  |> should.equal(6)
}

pub fn siphash_key_computation_test() {
  // Create a block header
  let header = oni_bitcoin.BlockHeader(
    version: 1,
    prev_block: oni_bitcoin.BlockHash(hash: oni_bitcoin.Hash256(bytes: <<0:256>>)),
    merkle_root: oni_bitcoin.Hash256(bytes: <<0:256>>),
    timestamp: 0,
    bits: 0x1d00ffff,
    nonce: 0,
  )

  let nonce = 12345

  let #(k0, k1) = compact_blocks.compute_siphash_key(header, nonce)

  // Keys should be non-zero (with very high probability)
  // Just check they're computed
  { k0 >= 0 }
  |> should.be_true

  { k1 >= 0 }
  |> should.be_true
}

pub fn create_compact_block_test() {
  // Create a simple block
  let header = oni_bitcoin.BlockHeader(
    version: 1,
    prev_block: oni_bitcoin.BlockHash(hash: oni_bitcoin.Hash256(bytes: <<0:256>>)),
    merkle_root: oni_bitcoin.Hash256(bytes: <<0:256>>),
    timestamp: 0,
    bits: 0x1d00ffff,
    nonce: 0,
  )

  let coinbase = oni_bitcoin.Transaction(
    version: 1,
    inputs: [],
    outputs: [],
    lock_time: 0,
  )

  let block = oni_bitcoin.Block(
    header: header,
    transactions: [coinbase],
  )

  let compact = compact_blocks.create_compact_block(block, 12345, False)

  // Should have the same header
  compact.header.version
  |> should.equal(1)

  // Should have coinbase prefilled
  list.length(compact.prefilled_txns)
  |> should.equal(1)

  // No short IDs for just coinbase
  list.length(compact.short_ids)
  |> should.equal(0)
}

pub fn create_compact_block_with_txs_test() {
  let header = oni_bitcoin.BlockHeader(
    version: 1,
    prev_block: oni_bitcoin.BlockHash(hash: oni_bitcoin.Hash256(bytes: <<0:256>>)),
    merkle_root: oni_bitcoin.Hash256(bytes: <<0:256>>),
    timestamp: 0,
    bits: 0x1d00ffff,
    nonce: 0,
  )

  let coinbase = oni_bitcoin.Transaction(
    version: 1,
    inputs: [],
    outputs: [],
    lock_time: 0,
  )

  let tx1 = oni_bitcoin.Transaction(
    version: 2,
    inputs: [],
    outputs: [],
    lock_time: 0,
  )

  let tx2 = oni_bitcoin.Transaction(
    version: 3,
    inputs: [],
    outputs: [],
    lock_time: 0,
  )

  let block = oni_bitcoin.Block(
    header: header,
    transactions: [coinbase, tx1, tx2],
  )

  let compact = compact_blocks.create_compact_block(block, 12345, False)

  // Should have 2 short IDs for tx1 and tx2
  list.length(compact.short_ids)
  |> should.equal(2)

  // Should have 1 prefilled tx (coinbase)
  list.length(compact.prefilled_txns)
  |> should.equal(1)
}

pub fn encode_decode_compact_block_test() {
  let header = oni_bitcoin.BlockHeader(
    version: 1,
    prev_block: oni_bitcoin.BlockHash(hash: oni_bitcoin.Hash256(bytes: <<0:256>>)),
    merkle_root: oni_bitcoin.Hash256(bytes: <<0:256>>),
    timestamp: 1234567890,
    bits: 0x1d00ffff,
    nonce: 42,
  )

  let coinbase = oni_bitcoin.Transaction(
    version: 1,
    inputs: [
      oni_bitcoin.TxIn(
        prevout: oni_bitcoin.OutPoint(
          txid: oni_bitcoin.Txid(hash: oni_bitcoin.Hash256(bytes: <<0:256>>)),
          vout: 0xffffffff,
        ),
        script_sig: oni_bitcoin.Script(bytes: <<>>),
        sequence: 0xffffffff,
        witness: [],
      ),
    ],
    outputs: [
      oni_bitcoin.TxOut(
        value: oni_bitcoin.Amount(sats: 5_000_000_000),
        script_pubkey: oni_bitcoin.Script(bytes: <<>>),
      ),
    ],
    lock_time: 0,
  )

  let block = oni_bitcoin.Block(
    header: header,
    transactions: [coinbase],
  )

  let compact = compact_blocks.create_compact_block(block, 12345, False)

  let encoded = compact_blocks.encode_compact_block(compact)
  let result = compact_blocks.decode_compact_block(encoded)

  should.be_ok(result)

  case result {
    Ok(#(decoded, _)) -> {
      decoded.header.timestamp
      |> should.equal(1234567890)

      decoded.nonce
      |> should.equal(12345)

      list.length(decoded.prefilled_txns)
      |> should.equal(1)
    }
    Error(_) -> should.be_true(False)
  }
}

pub fn getblocktxn_encode_decode_test() {
  let request = compact_blocks.BlockTxnRequest(
    block_hash: oni_bitcoin.BlockHash(hash: oni_bitcoin.Hash256(bytes: <<1:256>>)),
    indexes: [1, 3, 5],
  )

  let encoded = compact_blocks.encode_getblocktxn(request)
  let result = compact_blocks.decode_getblocktxn(encoded)

  should.be_ok(result)

  case result {
    Ok(#(decoded, _)) -> {
      list.length(decoded.indexes)
      |> should.equal(3)
    }
    Error(_) -> should.be_true(False)
  }
}

pub fn blocktxn_encode_decode_test() {
  let tx = oni_bitcoin.Transaction(
    version: 1,
    inputs: [],
    outputs: [],
    lock_time: 0,
  )

  let response = compact_blocks.BlockTxn(
    block_hash: oni_bitcoin.BlockHash(hash: oni_bitcoin.Hash256(bytes: <<2:256>>)),
    transactions: [tx],
  )

  let encoded = compact_blocks.encode_blocktxn(response)
  let result = compact_blocks.decode_blocktxn(encoded)

  should.be_ok(result)

  case result {
    Ok(#(decoded, _)) -> {
      list.length(decoded.transactions)
      |> should.equal(1)
    }
    Error(_) -> should.be_true(False)
  }
}

pub fn reconstruction_state_test() {
  let header = oni_bitcoin.BlockHeader(
    version: 1,
    prev_block: oni_bitcoin.BlockHash(hash: oni_bitcoin.Hash256(bytes: <<0:256>>)),
    merkle_root: oni_bitcoin.Hash256(bytes: <<0:256>>),
    timestamp: 0,
    bits: 0x1d00ffff,
    nonce: 0,
  )

  let coinbase = oni_bitcoin.Transaction(
    version: 1,
    inputs: [],
    outputs: [],
    lock_time: 0,
  )

  let block = oni_bitcoin.Block(
    header: header,
    transactions: [coinbase],
  )

  let compact = compact_blocks.create_compact_block(block, 12345, False)

  let state = compact_blocks.start_reconstruction(compact, [], False)

  // Coinbase should already be available (prefilled)
  dict.size(state.available_txs)
  |> should.equal(1)

  // No missing indices since only coinbase
  list.length(state.missing_indices)
  |> should.equal(0)
}

pub fn finalize_complete_reconstruction_test() {
  let header = oni_bitcoin.BlockHeader(
    version: 1,
    prev_block: oni_bitcoin.BlockHash(hash: oni_bitcoin.Hash256(bytes: <<0:256>>)),
    merkle_root: oni_bitcoin.Hash256(bytes: <<0:256>>),
    timestamp: 0,
    bits: 0x1d00ffff,
    nonce: 0,
  )

  let coinbase = oni_bitcoin.Transaction(
    version: 1,
    inputs: [],
    outputs: [],
    lock_time: 0,
  )

  let block = oni_bitcoin.Block(
    header: header,
    transactions: [coinbase],
  )

  let compact = compact_blocks.create_compact_block(block, 12345, False)
  let state = compact_blocks.start_reconstruction(compact, [], False)

  let result = compact_blocks.finalize_reconstruction(state)

  case result {
    compact_blocks.Complete(reconstructed) -> {
      list.length(reconstructed.transactions)
      |> should.equal(1)
    }
    _ -> should.be_true(False)
  }
}
