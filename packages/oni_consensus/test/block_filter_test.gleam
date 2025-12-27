// block_filter_test.gleam - Tests for Compact Block Filters (BIP157/158)

import gleam/bit_array
import gleam/int
import gleam/list
import gleeunit
import gleeunit/should
import oni_bitcoin
import oni_consensus/block_filter

pub fn main() {
  gleeunit.main()
}

// ============================================================================
// Golomb-Rice Encoding Tests
// ============================================================================

pub fn gr_encode_decode_single_test() {
  // Test encoding and decoding a single value
  let p = 19
  let deltas = [100, 200, 50]
  let encoded = block_filter.golomb_rice_encode(deltas, p)
  let decoded = block_filter.golomb_rice_decode(encoded, 3, p)

  // Decoded should be cumulative sums of deltas
  decoded |> should.equal([100, 300, 350])
}

pub fn gr_encode_decode_empty_test() {
  let p = 19
  let encoded = block_filter.golomb_rice_encode([], p)
  let decoded = block_filter.golomb_rice_decode(encoded, 0, p)

  decoded |> should.equal([])
}

pub fn gr_encode_decode_large_values_test() {
  let p = 19
  let deltas = [524288, 1000000, 12345]
  let encoded = block_filter.golomb_rice_encode(deltas, p)
  let decoded = block_filter.golomb_rice_decode(encoded, 3, p)

  decoded |> should.equal([524288, 1524288, 1536633])
}

// ============================================================================
// GCS Parameters Tests
// ============================================================================

pub fn gcs_params_basic_test() {
  let params = block_filter.basic_gcs_params(100)

  params.p |> should.equal(block_filter.filter_p)
  params.m |> should.equal(block_filter.filter_m)
  params.n |> should.equal(100)
  params.modulus |> should.equal(100 * block_filter.filter_m)
}

pub fn gcs_params_empty_test() {
  let params = block_filter.basic_gcs_params(0)

  params.n |> should.equal(0)
  params.modulus |> should.equal(0)
}

// ============================================================================
// Filter Construction Tests
// ============================================================================

pub fn construct_empty_block_filter_test() {
  // Create an empty block (just coinbase)
  let genesis_hash = oni_bitcoin.BlockHash(oni_bitcoin.Hash256(<<0:256>>))

  let coinbase_input = oni_bitcoin.TxIn(
    prevout: oni_bitcoin.OutPoint(
      txid: oni_bitcoin.Txid(oni_bitcoin.Hash256(<<0:256>>)),
      vout: 0xFFFFFFFF,
    ),
    script_sig: oni_bitcoin.script_from_bytes(<<4, 0, 0, 0, 0>>),
    sequence: 0xFFFFFFFF,
    witness: [],
  )

  let coinbase_output = oni_bitcoin.TxOut(
    value: oni_bitcoin.sats(5_000_000_000),
    script_pubkey: oni_bitcoin.script_from_bytes(<<0x51>>),  // OP_1
  )

  let coinbase_tx = oni_bitcoin.Transaction(
    version: 1,
    inputs: [coinbase_input],
    outputs: [coinbase_output],
    lock_time: 0,
  )

  let header = oni_bitcoin.BlockHeader(
    version: 1,
    prev_block: genesis_hash,
    merkle_root: oni_bitcoin.Hash256(<<0:256>>),
    timestamp: 1231006505,
    bits: 0x1d00ffff,
    nonce: 0,
  )

  let block = oni_bitcoin.Block(
    header: header,
    transactions: [coinbase_tx],
  )

  let filter = block_filter.construct_basic_filter(block, genesis_hash)

  filter.filter_type |> should.equal(block_filter.filter_type_basic)
  // Should have 1 element (the coinbase output script)
  filter.n_elements |> should.equal(1)
}

// ============================================================================
// Filter Matching Tests
// ============================================================================

pub fn filter_match_present_test() {
  // Create a simple filter manually
  let block_hash = oni_bitcoin.BlockHash(oni_bitcoin.Hash256(<<1:256>>))

  // Create a block with a known output script
  let test_script = <<0x76, 0xa9, 0x14>>  // Start of P2PKH
  let output = oni_bitcoin.TxOut(
    value: oni_bitcoin.sats(1000),
    script_pubkey: oni_bitcoin.script_from_bytes(test_script),
  )

  let input = oni_bitcoin.TxIn(
    prevout: oni_bitcoin.OutPoint(
      txid: oni_bitcoin.Txid(oni_bitcoin.Hash256(<<2:256>>)),
      vout: 0,
    ),
    script_sig: oni_bitcoin.script_from_bytes(<<>>),
    sequence: 0xFFFFFFFF,
    witness: [],
  )

  let tx = oni_bitcoin.Transaction(
    version: 1,
    inputs: [input],
    outputs: [output],
    lock_time: 0,
  )

  let header = oni_bitcoin.BlockHeader(
    version: 1,
    prev_block: block_hash,
    merkle_root: oni_bitcoin.Hash256(<<0:256>>),
    timestamp: 1231006505,
    bits: 0x1d00ffff,
    nonce: 0,
  )

  let block = oni_bitcoin.Block(
    header: header,
    transactions: [tx],
  )

  let filter = block_filter.construct_basic_filter(block, block_hash)

  // Query for the script that's in the filter
  let matches = block_filter.filter_match(filter, [test_script])
  matches |> should.equal(True)
}

pub fn filter_match_absent_test() {
  let block_hash = oni_bitcoin.BlockHash(oni_bitcoin.Hash256(<<1:256>>))

  let test_script = <<0x76, 0xa9, 0x14>>
  let output = oni_bitcoin.TxOut(
    value: oni_bitcoin.sats(1000),
    script_pubkey: oni_bitcoin.script_from_bytes(test_script),
  )

  let input = oni_bitcoin.TxIn(
    prevout: oni_bitcoin.OutPoint(
      txid: oni_bitcoin.Txid(oni_bitcoin.Hash256(<<2:256>>)),
      vout: 0,
    ),
    script_sig: oni_bitcoin.script_from_bytes(<<>>),
    sequence: 0xFFFFFFFF,
    witness: [],
  )

  let tx = oni_bitcoin.Transaction(
    version: 1,
    inputs: [input],
    outputs: [output],
    lock_time: 0,
  )

  let header = oni_bitcoin.BlockHeader(
    version: 1,
    prev_block: block_hash,
    merkle_root: oni_bitcoin.Hash256(<<0:256>>),
    timestamp: 1231006505,
    bits: 0x1d00ffff,
    nonce: 0,
  )

  let block = oni_bitcoin.Block(
    header: header,
    transactions: [tx],
  )

  let filter = block_filter.construct_basic_filter(block, block_hash)

  // Query for a different script that's NOT in the filter
  let other_script = <<0x00, 0x14, 0xab, 0xcd>>
  let matches = block_filter.filter_match(filter, [other_script])
  // Should be False (or possibly True due to false positive, but very unlikely)
  // With proper implementation, this should be False
  matches |> should.equal(False)
}

// ============================================================================
// Filter Header Chain Tests
// ============================================================================

pub fn filter_hash_test() {
  let block_hash = oni_bitcoin.BlockHash(oni_bitcoin.Hash256(<<1:256>>))
  let filter = block_filter.BlockFilter(
    filter_type: 0,
    block_hash: block_hash,
    n_elements: 0,
    filter_data: <<1, 2, 3, 4>>,
  )

  let hash = block_filter.filter_hash(filter)

  // Hash should be 32 bytes
  bit_array.byte_size(hash.bytes) |> should.equal(32)
}

pub fn genesis_filter_header_test() {
  let block_hash = oni_bitcoin.BlockHash(oni_bitcoin.Hash256(<<1:256>>))
  let filter = block_filter.BlockFilter(
    filter_type: 0,
    block_hash: block_hash,
    n_elements: 0,
    filter_data: <<>>,
  )

  let header = block_filter.genesis_filter_header(filter)

  header.filter_type |> should.equal(0)
  // prev_header should be all zeros for genesis
  header.prev_header.bytes |> should.equal(<<0:256>>)
}

pub fn filter_header_chain_test() {
  let block_hash1 = oni_bitcoin.BlockHash(oni_bitcoin.Hash256(<<1:256>>))
  let block_hash2 = oni_bitcoin.BlockHash(oni_bitcoin.Hash256(<<2:256>>))

  let filter1 = block_filter.BlockFilter(
    filter_type: 0,
    block_hash: block_hash1,
    n_elements: 1,
    filter_data: <<1, 2, 3>>,
  )

  let filter2 = block_filter.BlockFilter(
    filter_type: 0,
    block_hash: block_hash2,
    n_elements: 1,
    filter_data: <<4, 5, 6>>,
  )

  // Create header chain
  let header1 = block_filter.genesis_filter_header(filter1)
  let header2 = block_filter.compute_filter_header(filter2, header1.header)

  // Header2's prev_header should be header1's header
  header2.prev_header |> should.equal(header1.header)
}

// ============================================================================
// Serialization Tests
// ============================================================================

pub fn encode_decode_filter_test() {
  let block_hash = oni_bitcoin.BlockHash(oni_bitcoin.Hash256(<<1:256>>))
  let filter = block_filter.BlockFilter(
    filter_type: 0,
    block_hash: block_hash,
    n_elements: 5,
    filter_data: <<1, 2, 3, 4, 5, 6, 7, 8>>,
  )

  let encoded = block_filter.encode_filter(filter)
  let decoded = block_filter.decode_filter(encoded, 0, block_hash)

  case decoded {
    Ok(f) -> {
      f.n_elements |> should.equal(5)
      f.filter_data |> should.equal(<<1, 2, 3, 4, 5, 6, 7, 8>>)
    }
    Error(_) -> should.fail()
  }
}

// ============================================================================
// Filter Type Tests
// ============================================================================

pub fn filter_type_conversion_test() {
  block_filter.filter_type_to_byte(block_filter.BasicFilter)
  |> should.equal(0)

  block_filter.filter_type_to_byte(block_filter.ExtendedFilter)
  |> should.equal(1)

  block_filter.filter_type_from_byte(0)
  |> should.equal(option.Some(block_filter.BasicFilter))

  block_filter.filter_type_from_byte(1)
  |> should.equal(option.Some(block_filter.ExtendedFilter))

  block_filter.filter_type_from_byte(255)
  |> should.equal(option.None)
}
