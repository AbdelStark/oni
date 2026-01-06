// txindex_test.gleam - Tests for transaction index

import gleeunit
import gleeunit/should
import txindex

pub fn main() {
  gleeunit.main()
}

// ============================================================================
// Configuration Tests
// ============================================================================

pub fn default_config_disabled_test() {
  let config = txindex.TxIndexConfig(data_dir: "/tmp/test", enabled: False)
  should.equal(config.enabled, False)
}

pub fn enabled_config_test() {
  let config = txindex.TxIndexConfig(data_dir: "/tmp/test", enabled: True)
  should.equal(config.enabled, True)
}

// ============================================================================
// TxLocation Tests
// ============================================================================

pub fn tx_location_creation_test() {
  // Test that we can create a TxLocation
  let location =
    txindex.TxLocation(
      block_hash: create_test_block_hash(),
      tx_index: 5,
      block_height: 100_000,
    )

  should.equal(location.tx_index, 5)
  should.equal(location.block_height, 100_000)
}

// ============================================================================
// Block Indexing Helpers Tests
// ============================================================================

pub fn index_block_transactions_empty_test() {
  let entries =
    txindex.index_block_transactions(create_test_block_hash(), 100, [])
  should.equal(entries, [])
}

pub fn index_block_transactions_single_test() {
  let txid = create_test_txid()
  let block_hash = create_test_block_hash()

  let entries = txindex.index_block_transactions(block_hash, 100, [txid])

  should.equal(list.length(entries), 1)
}

pub fn index_block_transactions_multiple_test() {
  let txids = [create_test_txid(), create_test_txid(), create_test_txid()]
  let block_hash = create_test_block_hash()

  let entries = txindex.index_block_transactions(block_hash, 500_000, txids)

  should.equal(list.length(entries), 3)
}

// ============================================================================
// TxInfo Tests
// ============================================================================

pub fn tx_info_from_location_confirmations_test() {
  let txid = create_test_txid()
  let location =
    txindex.TxLocation(
      block_hash: create_test_block_hash(),
      tx_index: 0,
      block_height: 100,
    )

  // Current height is 150, so 51 confirmations
  let info = txindex.tx_info_from_location(txid, location, 150, option.None)

  should.equal(info.confirmations, 51)
  should.equal(info.block_height, 100)
  should.equal(info.tx_index, 0)
}

pub fn tx_info_single_confirmation_test() {
  let txid = create_test_txid()
  let location =
    txindex.TxLocation(
      block_hash: create_test_block_hash(),
      tx_index: 5,
      block_height: 100,
    )

  // Block just confirmed (current height == block height)
  let info = txindex.tx_info_from_location(txid, location, 100, option.None)

  should.equal(info.confirmations, 1)
}

// ============================================================================
// Helper Functions for Tests
// ============================================================================

import gleam/list
import gleam/option
import oni_bitcoin

fn create_test_block_hash() -> oni_bitcoin.BlockHash {
  let bytes = <<
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 1,
  >>
  oni_bitcoin.BlockHash(hash: oni_bitcoin.Hash256(bytes: bytes))
}

fn create_test_txid() -> oni_bitcoin.Txid {
  let bytes = <<
    1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21,
    22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32,
  >>
  oni_bitcoin.Txid(hash: oni_bitcoin.Hash256(bytes: bytes))
}
