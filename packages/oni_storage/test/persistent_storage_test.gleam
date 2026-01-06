// persistent_storage_test.gleam - Tests for persistent storage layer

import gleam/option.{None, Some}
import gleeunit
import gleeunit/should
import oni_bitcoin
import oni_storage
import persistent_storage.{
  block_index_get, block_index_has, block_index_put, chainstate_get,
  chainstate_put, persistent_storage_close, persistent_storage_open,
  persistent_storage_sync, undo_delete, undo_get, undo_put, utxo_batch,
  utxo_count, utxo_delete, utxo_get, utxo_has, utxo_put,
}

pub fn main() {
  gleeunit.main()
}

// ============================================================================
// UTXO Tests
// ============================================================================

pub fn utxo_put_and_get_test() {
  let path = "/tmp/oni_persistent_test_1"
  cleanup_dir(path)

  let assert Ok(handle) = persistent_storage_open(path)

  // Create a test coin
  let outpoint = create_test_outpoint(1, 0)
  let coin = create_test_coin(1000, 100, False)

  // Put the coin
  let assert Ok(_) = utxo_put(handle, outpoint, coin)

  // Get it back
  let assert Ok(retrieved) = utxo_get(handle, outpoint)

  should.equal(retrieved.height, coin.height)
  should.equal(retrieved.is_coinbase, coin.is_coinbase)
  should.equal(oni_bitcoin.amount_to_sats(retrieved.output.value), 1000)

  let assert Ok(_) = persistent_storage_close(handle)
  cleanup_dir(path)
}

pub fn utxo_delete_test() {
  let path = "/tmp/oni_persistent_test_2"
  cleanup_dir(path)

  let assert Ok(handle) = persistent_storage_open(path)

  let outpoint = create_test_outpoint(2, 0)
  let coin = create_test_coin(2000, 200, True)

  // Put and verify
  let assert Ok(_) = utxo_put(handle, outpoint, coin)
  should.be_true(utxo_has(handle, outpoint))

  // Delete
  let assert Ok(_) = utxo_delete(handle, outpoint)
  should.be_false(utxo_has(handle, outpoint))

  let assert Ok(_) = persistent_storage_close(handle)
  cleanup_dir(path)
}

pub fn utxo_count_test() {
  let path = "/tmp/oni_persistent_test_3"
  cleanup_dir(path)

  let assert Ok(handle) = persistent_storage_open(path)

  // Initially empty
  let assert Ok(count0) = utxo_count(handle)
  should.equal(count0, 0)

  // Add some UTXOs
  let assert Ok(_) =
    utxo_put(
      handle,
      create_test_outpoint(1, 0),
      create_test_coin(100, 1, False),
    )
  let assert Ok(_) =
    utxo_put(
      handle,
      create_test_outpoint(2, 0),
      create_test_coin(200, 2, False),
    )
  let assert Ok(_) =
    utxo_put(
      handle,
      create_test_outpoint(3, 0),
      create_test_coin(300, 3, False),
    )

  let assert Ok(count3) = utxo_count(handle)
  should.equal(count3, 3)

  let assert Ok(_) = persistent_storage_close(handle)
  cleanup_dir(path)
}

pub fn utxo_batch_test() {
  let path = "/tmp/oni_persistent_test_4"
  cleanup_dir(path)

  let assert Ok(handle) = persistent_storage_open(path)

  // First add a UTXO
  let outpoint1 = create_test_outpoint(1, 0)
  let coin1 = create_test_coin(100, 1, False)
  let assert Ok(_) = utxo_put(handle, outpoint1, coin1)

  // Batch: add new UTXOs and remove old one
  let outpoint2 = create_test_outpoint(2, 0)
  let outpoint3 = create_test_outpoint(3, 0)
  let coin2 = create_test_coin(200, 2, False)
  let coin3 = create_test_coin(300, 3, False)

  let assert Ok(_) =
    utxo_batch(handle, [#(outpoint2, coin2), #(outpoint3, coin3)], [outpoint1])

  // Verify batch results
  should.be_false(utxo_has(handle, outpoint1))
  should.be_true(utxo_has(handle, outpoint2))
  should.be_true(utxo_has(handle, outpoint3))

  let assert Ok(_) = persistent_storage_close(handle)
  cleanup_dir(path)
}

pub fn utxo_persists_test() {
  let path = "/tmp/oni_persistent_test_5"
  cleanup_dir(path)

  let outpoint = create_test_outpoint(42, 1)
  let coin = create_test_coin(5000, 50, True)

  // Open, write, sync, close
  let assert Ok(handle1) = persistent_storage_open(path)
  let assert Ok(_) = utxo_put(handle1, outpoint, coin)
  let assert Ok(_) = persistent_storage_sync(handle1)
  let assert Ok(_) = persistent_storage_close(handle1)

  // Reopen and verify
  let assert Ok(handle2) = persistent_storage_open(path)
  should.be_true(utxo_has(handle2, outpoint))
  let assert Ok(retrieved) = utxo_get(handle2, outpoint)
  should.equal(retrieved.height, 50)
  should.equal(retrieved.is_coinbase, True)

  let assert Ok(_) = persistent_storage_close(handle2)
  cleanup_dir(path)
}

// ============================================================================
// Block Index Tests
// ============================================================================

pub fn block_index_put_and_get_test() {
  let path = "/tmp/oni_persistent_test_6"
  cleanup_dir(path)

  let assert Ok(handle) = persistent_storage_open(path)

  let entry = create_test_block_index_entry(100)

  // Put the entry
  let assert Ok(_) = block_index_put(handle, entry)

  // Get it back
  let assert Ok(retrieved) = block_index_get(handle, entry.hash)

  should.equal(retrieved.height, entry.height)
  should.equal(retrieved.num_tx, entry.num_tx)
  should.equal(retrieved.total_work, entry.total_work)

  let assert Ok(_) = persistent_storage_close(handle)
  cleanup_dir(path)
}

pub fn block_index_has_test() {
  let path = "/tmp/oni_persistent_test_7"
  cleanup_dir(path)

  let assert Ok(handle) = persistent_storage_open(path)

  let entry = create_test_block_index_entry(200)

  should.be_false(block_index_has(handle, entry.hash))
  let assert Ok(_) = block_index_put(handle, entry)
  should.be_true(block_index_has(handle, entry.hash))

  let assert Ok(_) = persistent_storage_close(handle)
  cleanup_dir(path)
}

pub fn block_index_persists_test() {
  let path = "/tmp/oni_persistent_test_8"
  cleanup_dir(path)

  let entry = create_test_block_index_entry(300)

  // Open, write, close
  let assert Ok(handle1) = persistent_storage_open(path)
  let assert Ok(_) = block_index_put(handle1, entry)
  let assert Ok(_) = persistent_storage_sync(handle1)
  let assert Ok(_) = persistent_storage_close(handle1)

  // Reopen and verify
  let assert Ok(handle2) = persistent_storage_open(path)
  should.be_true(block_index_has(handle2, entry.hash))
  let assert Ok(retrieved) = block_index_get(handle2, entry.hash)
  should.equal(retrieved.height, 300)

  let assert Ok(_) = persistent_storage_close(handle2)
  cleanup_dir(path)
}

// ============================================================================
// Chainstate Tests
// ============================================================================

pub fn chainstate_put_and_get_test() {
  let path = "/tmp/oni_persistent_test_9"
  cleanup_dir(path)

  let assert Ok(handle) = persistent_storage_open(path)

  let genesis_hash = create_test_block_hash(0)
  let chainstate =
    oni_storage.Chainstate(
      best_block: genesis_hash,
      best_height: 0,
      total_tx: 1,
      total_coins: 1,
      total_amount: 5_000_000_000,
      pruned: False,
      pruned_height: None,
    )

  // Put chainstate
  let assert Ok(_) = chainstate_put(handle, chainstate)

  // Get it back
  let assert Ok(retrieved) = chainstate_get(handle)

  should.equal(retrieved.best_height, 0)
  should.equal(retrieved.total_tx, 1)
  should.equal(retrieved.total_coins, 1)
  should.equal(retrieved.total_amount, 5_000_000_000)
  should.equal(retrieved.pruned, False)

  let assert Ok(_) = persistent_storage_close(handle)
  cleanup_dir(path)
}

pub fn chainstate_update_test() {
  let path = "/tmp/oni_persistent_test_10"
  cleanup_dir(path)

  let assert Ok(handle) = persistent_storage_open(path)

  let genesis_hash = create_test_block_hash(0)
  let chainstate1 =
    oni_storage.Chainstate(
      best_block: genesis_hash,
      best_height: 0,
      total_tx: 1,
      total_coins: 1,
      total_amount: 5_000_000_000,
      pruned: False,
      pruned_height: None,
    )

  let assert Ok(_) = chainstate_put(handle, chainstate1)

  // Update chainstate
  let new_hash = create_test_block_hash(1)
  let chainstate2 =
    oni_storage.Chainstate(
      ..chainstate1,
      best_block: new_hash,
      best_height: 1,
      total_tx: 5,
      total_coins: 10,
    )

  let assert Ok(_) = chainstate_put(handle, chainstate2)

  // Verify update
  let assert Ok(retrieved) = chainstate_get(handle)
  should.equal(retrieved.best_height, 1)
  should.equal(retrieved.total_tx, 5)
  should.equal(retrieved.total_coins, 10)

  let assert Ok(_) = persistent_storage_close(handle)
  cleanup_dir(path)
}

pub fn chainstate_persists_test() {
  let path = "/tmp/oni_persistent_test_11"
  cleanup_dir(path)

  let genesis_hash = create_test_block_hash(0)
  let chainstate =
    oni_storage.Chainstate(
      best_block: genesis_hash,
      best_height: 500,
      total_tx: 1000,
      total_coins: 2000,
      total_amount: 10_000_000_000,
      pruned: False,
      pruned_height: None,
    )

  // Open, write, close
  let assert Ok(handle1) = persistent_storage_open(path)
  let assert Ok(_) = chainstate_put(handle1, chainstate)
  let assert Ok(_) = persistent_storage_sync(handle1)
  let assert Ok(_) = persistent_storage_close(handle1)

  // Reopen and verify
  let assert Ok(handle2) = persistent_storage_open(path)
  let assert Ok(retrieved) = chainstate_get(handle2)
  should.equal(retrieved.best_height, 500)
  should.equal(retrieved.total_tx, 1000)

  let assert Ok(_) = persistent_storage_close(handle2)
  cleanup_dir(path)
}

// ============================================================================
// Undo Data Tests
// ============================================================================

pub fn undo_put_and_get_test() {
  let path = "/tmp/oni_persistent_test_12"
  cleanup_dir(path)

  let assert Ok(handle) = persistent_storage_open(path)

  let block_hash = create_test_block_hash(1)
  let coin = create_test_coin(1000, 50, False)
  let tx_undo =
    oni_storage.TxUndo(spent_coins: [oni_storage.TxInputUndo(coin: coin)])
  let block_undo = oni_storage.BlockUndo(tx_undos: [tx_undo])

  // Put undo data
  let assert Ok(_) = undo_put(handle, block_hash, block_undo)

  // Get it back
  let assert Ok(retrieved) = undo_get(handle, block_hash)

  // Verify structure
  should.equal(list_length(retrieved.tx_undos), 1)

  let assert Ok(_) = persistent_storage_close(handle)
  cleanup_dir(path)
}

pub fn undo_delete_test() {
  let path = "/tmp/oni_persistent_test_13"
  cleanup_dir(path)

  let assert Ok(handle) = persistent_storage_open(path)

  let block_hash = create_test_block_hash(2)
  let block_undo = oni_storage.BlockUndo(tx_undos: [])

  // Put undo data
  let assert Ok(_) = undo_put(handle, block_hash, block_undo)

  // Verify it exists
  let assert Ok(_) = undo_get(handle, block_hash)

  // Delete it
  let assert Ok(_) = undo_delete(handle, block_hash)

  // Verify it's gone
  let result = undo_get(handle, block_hash)
  should.be_error(result)

  let assert Ok(_) = persistent_storage_close(handle)
  cleanup_dir(path)
}

pub fn undo_persists_test() {
  let path = "/tmp/oni_persistent_test_14"
  cleanup_dir(path)

  let block_hash = create_test_block_hash(3)
  let coin1 = create_test_coin(100, 10, False)
  let coin2 = create_test_coin(200, 20, True)
  let tx_undo =
    oni_storage.TxUndo(spent_coins: [
      oni_storage.TxInputUndo(coin: coin1),
      oni_storage.TxInputUndo(coin: coin2),
    ])
  let block_undo = oni_storage.BlockUndo(tx_undos: [tx_undo])

  // Open, write, close
  let assert Ok(handle1) = persistent_storage_open(path)
  let assert Ok(_) = undo_put(handle1, block_hash, block_undo)
  let assert Ok(_) = persistent_storage_sync(handle1)
  let assert Ok(_) = persistent_storage_close(handle1)

  // Reopen and verify
  let assert Ok(handle2) = persistent_storage_open(path)
  let assert Ok(retrieved) = undo_get(handle2, block_hash)
  should.equal(list_length(retrieved.tx_undos), 1)

  let assert Ok(_) = persistent_storage_close(handle2)
  cleanup_dir(path)
}

// ============================================================================
// Helper Functions
// ============================================================================

/// Create a test outpoint
fn create_test_outpoint(tx_num: Int, vout: Int) -> oni_bitcoin.OutPoint {
  let hash_bytes = <<tx_num:256>>
  oni_bitcoin.OutPoint(
    txid: oni_bitcoin.Txid(hash: oni_bitcoin.Hash256(bytes: hash_bytes)),
    vout: vout,
  )
}

/// Create a test coin
fn create_test_coin(
  value: Int,
  height: Int,
  is_coinbase: Bool,
) -> oni_storage.Coin {
  oni_storage.Coin(
    output: oni_bitcoin.TxOut(
      value: oni_bitcoin.Amount(sats: value),
      script_pubkey: oni_bitcoin.Script(bytes: <<0x00, 0x14, 0:160>>),
    ),
    height: height,
    is_coinbase: is_coinbase,
  )
}

/// Create a test block hash
fn create_test_block_hash(n: Int) -> oni_bitcoin.BlockHash {
  let hash_bytes = <<n:256>>
  oni_bitcoin.BlockHash(hash: oni_bitcoin.Hash256(bytes: hash_bytes))
}

/// Create a test block index entry
fn create_test_block_index_entry(height: Int) -> oni_storage.BlockIndexEntry {
  oni_storage.BlockIndexEntry(
    hash: create_test_block_hash(height),
    prev_hash: create_test_block_hash(height - 1),
    height: height,
    status: oni_storage.BlockValidScripts,
    num_tx: 10,
    total_work: 1000 * height,
    file_pos: Some(height * 1000),
    undo_pos: Some(height * 100),
    timestamp: 1_234_567_890 + height,
    bits: 0x207fffff,
    nonce: height * 17,
    version: 1,
  )
}

/// Clean up test directory
fn cleanup_dir(path: String) -> Nil {
  let _ = delete_file(path <> "/utxo.db")
  let _ = delete_file(path <> "/block_index.db")
  let _ = delete_file(path <> "/chainstate.db")
  let _ = delete_file(path <> "/undo.db")
  let _ = delete_dir(path)
  Nil
}

/// Get length of list
fn list_length(list: List(a)) -> Int {
  do_list_length(list, 0)
}

fn do_list_length(list: List(a), acc: Int) -> Int {
  case list {
    [] -> acc
    [_, ..rest] -> do_list_length(rest, acc + 1)
  }
}

@external(erlang, "file", "delete")
fn delete_file(path: String) -> Result(Nil, Nil)

@external(erlang, "file", "del_dir")
fn delete_dir(path: String) -> Result(Nil, Nil)
