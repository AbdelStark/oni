import gleam/option.{None, Some}
import gleeunit
import gleeunit/should
import oni_bitcoin
import oni_storage.{BlockValidScripts, BlockValidTransactions}

pub fn main() {
  gleeunit.main()
}

// ============================================================================
// Test Helpers
// ============================================================================

/// Create a test block hash from a simple integer
fn make_block_hash(n: Int) -> oni_bitcoin.BlockHash {
  let bytes = <<
    n:8,
    0:8,
    0:8,
    0:8,
    0:8,
    0:8,
    0:8,
    0:8,
    0:8,
    0:8,
    0:8,
    0:8,
    0:8,
    0:8,
    0:8,
    0:8,
    0:8,
    0:8,
    0:8,
    0:8,
    0:8,
    0:8,
    0:8,
    0:8,
    0:8,
    0:8,
    0:8,
    0:8,
    0:8,
    0:8,
    0:8,
    0:8,
  >>
  let assert Ok(hash) = oni_bitcoin.block_hash_from_bytes(bytes)
  hash
}

/// Create a test txid from a simple integer
fn make_txid(n: Int) -> oni_bitcoin.Txid {
  let bytes = <<
    n:8,
    0:8,
    0:8,
    0:8,
    0:8,
    0:8,
    0:8,
    0:8,
    0:8,
    0:8,
    0:8,
    0:8,
    0:8,
    0:8,
    0:8,
    0:8,
    0:8,
    0:8,
    0:8,
    0:8,
    0:8,
    0:8,
    0:8,
    0:8,
    0:8,
    0:8,
    0:8,
    0:8,
    0:8,
    0:8,
    0:8,
    0:8,
  >>
  let assert Ok(txid) = oni_bitcoin.txid_from_bytes(bytes)
  txid
}

/// Create a test amount
fn make_amount(sats: Int) -> oni_bitcoin.Amount {
  let assert Ok(amount) = oni_bitcoin.amount_from_sats(sats)
  amount
}

/// Create a test TxOut
fn make_txout(value: Int) -> oni_bitcoin.TxOut {
  oni_bitcoin.txout_new(
    make_amount(value),
    oni_bitcoin.script_from_bytes(<<0x00, 0x14, 0:160>>),
    // P2WPKH-like
  )
}

/// Create a coinbase transaction
fn make_coinbase_tx(value: Int) -> oni_bitcoin.Transaction {
  let null_outpoint = oni_bitcoin.outpoint_null()
  let coinbase_input =
    oni_bitcoin.TxIn(
      prevout: null_outpoint,
      script_sig: oni_bitcoin.script_from_bytes(<<0x03, 0x01, 0x00, 0x00>>),
      // Height 1
      sequence: 0xFFFFFFFF,
      witness: [],
    )
  oni_bitcoin.transaction_new(1, [coinbase_input], [make_txout(value)], 0)
}

/// Create a test block header
fn make_block_header(
  prev_hash: oni_bitcoin.BlockHash,
) -> oni_bitcoin.BlockHeader {
  oni_bitcoin.block_header_new(
    1,
    prev_hash,
    oni_bitcoin.Hash256(<<0:256>>),
    1_231_006_505,
    0x1d00ffff,
    0,
  )
}

/// Create a test block
fn make_block(
  prev_hash: oni_bitcoin.BlockHash,
  transactions: List(oni_bitcoin.Transaction),
) -> oni_bitcoin.Block {
  oni_bitcoin.block_new(make_block_header(prev_hash), transactions)
}

// ============================================================================
// UTXO View Tests
// ============================================================================

pub fn utxo_view_new_test() {
  let view = oni_storage.utxo_view_new()
  oni_storage.utxo_count(view)
  |> should.equal(0)
}

pub fn utxo_add_and_get_test() {
  let view = oni_storage.utxo_view_new()
  let txid = make_txid(1)
  let outpoint = oni_bitcoin.outpoint_new(txid, 0)
  let txout = make_txout(50_000_000)
  let coin = oni_storage.coin_new(txout, 100, False)

  let view = oni_storage.utxo_add(view, outpoint, coin)

  oni_storage.utxo_count(view)
  |> should.equal(1)

  case oni_storage.utxo_get(view, outpoint) {
    Some(c) -> {
      oni_storage.coin_value(c)
      |> should.equal(50_000_000)
    }
    None -> should.fail()
  }
}

pub fn utxo_remove_test() {
  let view = oni_storage.utxo_view_new()
  let txid = make_txid(1)
  let outpoint = oni_bitcoin.outpoint_new(txid, 0)
  let coin = oni_storage.coin_new(make_txout(50_000_000), 100, False)

  let view = oni_storage.utxo_add(view, outpoint, coin)
  oni_storage.utxo_count(view)
  |> should.equal(1)

  let view = oni_storage.utxo_remove(view, outpoint)
  oni_storage.utxo_count(view)
  |> should.equal(0)

  oni_storage.utxo_has(view, outpoint)
  |> should.equal(False)
}

pub fn utxo_has_test() {
  let view = oni_storage.utxo_view_new()
  let txid = make_txid(1)
  let outpoint = oni_bitcoin.outpoint_new(txid, 0)

  oni_storage.utxo_has(view, outpoint)
  |> should.equal(False)

  let coin = oni_storage.coin_new(make_txout(50_000_000), 100, False)
  let view = oni_storage.utxo_add(view, outpoint, coin)

  oni_storage.utxo_has(view, outpoint)
  |> should.equal(True)
}

// ============================================================================
// UTXO Batch Tests
// ============================================================================

pub fn utxo_batch_operations_test() {
  let view = oni_storage.utxo_view_new()

  // Add some initial UTXOs
  let txid1 = make_txid(1)
  let outpoint1 = oni_bitcoin.outpoint_new(txid1, 0)
  let coin1 = oni_storage.coin_new(make_txout(100), 1, False)
  let view = oni_storage.utxo_add(view, outpoint1, coin1)

  let txid2 = make_txid(2)
  let outpoint2 = oni_bitcoin.outpoint_new(txid2, 0)
  let coin2 = oni_storage.coin_new(make_txout(200), 1, False)
  let view = oni_storage.utxo_add(view, outpoint2, coin2)

  // Create a batch that removes one and adds one
  let txid3 = make_txid(3)
  let outpoint3 = oni_bitcoin.outpoint_new(txid3, 0)
  let coin3 = oni_storage.coin_new(make_txout(300), 2, False)

  let batch = oni_storage.utxo_batch_new()
  let batch = oni_storage.utxo_batch_remove(batch, outpoint1)
  let batch = oni_storage.utxo_batch_add(batch, outpoint3, coin3)

  let view = oni_storage.utxo_apply_batch(view, batch)

  // outpoint1 should be gone
  oni_storage.utxo_has(view, outpoint1)
  |> should.equal(False)

  // outpoint2 should still exist
  oni_storage.utxo_has(view, outpoint2)
  |> should.equal(True)

  // outpoint3 should exist
  oni_storage.utxo_has(view, outpoint3)
  |> should.equal(True)

  oni_storage.utxo_count(view)
  |> should.equal(2)
}

// ============================================================================
// Coin Maturity Tests
// ============================================================================

pub fn coin_maturity_non_coinbase_test() {
  let coin = oni_storage.coin_new(make_txout(100), 100, False)

  // Non-coinbase coins are always mature
  oni_storage.coin_is_mature(coin, 100)
  |> should.equal(True)

  oni_storage.coin_is_mature(coin, 101)
  |> should.equal(True)
}

pub fn coin_maturity_coinbase_test() {
  let coin = oni_storage.coin_new(make_txout(5_000_000_000), 100, True)

  // Coinbase needs 100 confirmations
  oni_storage.coin_is_mature(coin, 100)
  |> should.equal(False)

  oni_storage.coin_is_mature(coin, 199)
  |> should.equal(False)

  oni_storage.coin_is_mature(coin, 200)
  |> should.equal(True)

  oni_storage.coin_is_mature(coin, 201)
  |> should.equal(True)
}

// ============================================================================
// Block Index Tests
// ============================================================================

pub fn block_index_new_test() {
  let index = oni_storage.block_index_new()
  case oni_storage.block_index_get_tip(index) {
    None -> should.be_true(True)
    Some(_) -> should.fail()
  }
}

pub fn block_index_add_and_get_test() {
  let index = oni_storage.block_index_new()
  let genesis_hash = make_block_hash(0)
  let block1_hash = make_block_hash(1)

  let genesis_header = make_block_header(make_block_hash(255))
  // prev doesn't matter for genesis
  let entry =
    oni_storage.block_index_entry_from_header(
      genesis_header,
      genesis_hash,
      0,
      0,
    )
  let entry = oni_storage.BlockIndexEntry(..entry, status: BlockValidScripts)
  let index = oni_storage.block_index_add(index, entry)

  case oni_storage.block_index_get(index, genesis_hash) {
    Some(e) -> {
      e.height |> should.equal(0)
    }
    None -> should.fail()
  }

  // Block 1 should not exist
  case oni_storage.block_index_get(index, block1_hash) {
    None -> should.be_true(True)
    Some(_) -> should.fail()
  }
}

pub fn block_index_get_by_height_test() {
  let index = oni_storage.block_index_new()
  let genesis_hash = make_block_hash(0)

  let genesis_header = make_block_header(make_block_hash(255))
  let entry =
    oni_storage.block_index_entry_from_header(
      genesis_header,
      genesis_hash,
      0,
      0,
    )
  let entry = oni_storage.BlockIndexEntry(..entry, status: BlockValidScripts)
  let index = oni_storage.block_index_add(index, entry)

  case oni_storage.block_index_get_by_height(index, 0) {
    Some(e) ->
      oni_bitcoin.block_hash_to_hex(e.hash)
      |> should.equal(oni_bitcoin.block_hash_to_hex(genesis_hash))
    None -> should.fail()
  }

  case oni_storage.block_index_get_by_height(index, 1) {
    None -> should.be_true(True)
    Some(_) -> should.fail()
  }
}

pub fn block_index_set_tip_test() {
  let index = oni_storage.block_index_new()
  let genesis_hash = make_block_hash(0)

  let genesis_header = make_block_header(make_block_hash(255))
  let entry =
    oni_storage.block_index_entry_from_header(
      genesis_header,
      genesis_hash,
      0,
      0,
    )
  let entry = oni_storage.BlockIndexEntry(..entry, status: BlockValidScripts)
  let index = oni_storage.block_index_add(index, entry)
  let index = oni_storage.block_index_set_tip(index, genesis_hash)

  case oni_storage.block_index_get_tip(index) {
    Some(e) -> e.height |> should.equal(0)
    None -> should.fail()
  }
}

pub fn block_index_update_status_test() {
  let index = oni_storage.block_index_new()
  let hash = make_block_hash(1)

  let header = make_block_header(make_block_hash(0))
  let entry = oni_storage.block_index_entry_from_header(header, hash, 1, 0)
  let index = oni_storage.block_index_add(index, entry)

  // Initially BlockValidHeader
  case oni_storage.block_index_get(index, hash) {
    Some(e) ->
      case e.status {
        oni_storage.BlockValidHeader -> should.be_true(True)
        _ -> should.fail()
      }
    None -> should.fail()
  }

  // Update to BlockValidTransactions
  let index =
    oni_storage.block_index_update_status(index, hash, BlockValidTransactions)
  case oni_storage.block_index_get(index, hash) {
    Some(e) ->
      case e.status {
        BlockValidTransactions -> should.be_true(True)
        _ -> should.fail()
      }
    None -> should.fail()
  }
}

pub fn block_index_ancestor_test() {
  let index = oni_storage.block_index_new()

  // Build a chain: genesis -> block1 -> block2
  let genesis_hash = make_block_hash(0)
  let block1_hash = make_block_hash(1)
  let block2_hash = make_block_hash(2)

  let genesis_header = make_block_header(make_block_hash(255))
  let genesis_entry =
    oni_storage.block_index_entry_from_header(
      genesis_header,
      genesis_hash,
      0,
      0,
    )
  let genesis_entry =
    oni_storage.BlockIndexEntry(..genesis_entry, status: BlockValidScripts)
  let index = oni_storage.block_index_add(index, genesis_entry)

  let block1_header = make_block_header(genesis_hash)
  let block1_entry =
    oni_storage.block_index_entry_from_header(block1_header, block1_hash, 1, 0)
  let block1_entry =
    oni_storage.BlockIndexEntry(..block1_entry, status: BlockValidScripts)
  let index = oni_storage.block_index_add(index, block1_entry)

  let block2_header = make_block_header(block1_hash)
  let block2_entry =
    oni_storage.block_index_entry_from_header(block2_header, block2_hash, 2, 0)
  let block2_entry =
    oni_storage.BlockIndexEntry(..block2_entry, status: BlockValidScripts)
  let index = oni_storage.block_index_add(index, block2_entry)

  // Get ancestor of block2 at height 0 (genesis)
  case oni_storage.block_index_get_ancestor(index, block2_hash, 0) {
    Some(e) -> e.height |> should.equal(0)
    None -> should.fail()
  }

  // Get ancestor of block2 at height 1 (block1)
  case oni_storage.block_index_get_ancestor(index, block2_hash, 1) {
    Some(e) -> e.height |> should.equal(1)
    None -> should.fail()
  }

  // Get ancestor of block2 at height 2 (itself)
  case oni_storage.block_index_get_ancestor(index, block2_hash, 2) {
    Some(e) -> e.height |> should.equal(2)
    None -> should.fail()
  }

  // Target height > block height should return None
  case oni_storage.block_index_get_ancestor(index, block2_hash, 3) {
    None -> should.be_true(True)
    Some(_) -> should.fail()
  }
}

pub fn block_index_is_ancestor_test() {
  let index = oni_storage.block_index_new()

  let genesis_hash = make_block_hash(0)
  let block1_hash = make_block_hash(1)
  let block2_hash = make_block_hash(2)

  let genesis_header = make_block_header(make_block_hash(255))
  let genesis_entry =
    oni_storage.block_index_entry_from_header(
      genesis_header,
      genesis_hash,
      0,
      0,
    )
  let genesis_entry =
    oni_storage.BlockIndexEntry(..genesis_entry, status: BlockValidScripts)
  let index = oni_storage.block_index_add(index, genesis_entry)

  let block1_header = make_block_header(genesis_hash)
  let block1_entry =
    oni_storage.block_index_entry_from_header(block1_header, block1_hash, 1, 0)
  let block1_entry =
    oni_storage.BlockIndexEntry(..block1_entry, status: BlockValidScripts)
  let index = oni_storage.block_index_add(index, block1_entry)

  let block2_header = make_block_header(block1_hash)
  let block2_entry =
    oni_storage.block_index_entry_from_header(block2_header, block2_hash, 2, 0)
  let block2_entry =
    oni_storage.BlockIndexEntry(..block2_entry, status: BlockValidScripts)
  let index = oni_storage.block_index_add(index, block2_entry)

  // Genesis is ancestor of block2
  oni_storage.block_index_is_ancestor(index, genesis_hash, block2_hash)
  |> should.equal(True)

  // Block1 is ancestor of block2
  oni_storage.block_index_is_ancestor(index, block1_hash, block2_hash)
  |> should.equal(True)

  // Block2 is not ancestor of genesis
  oni_storage.block_index_is_ancestor(index, block2_hash, genesis_hash)
  |> should.equal(False)
}

// ============================================================================
// Block Store Tests
// ============================================================================

pub fn block_store_operations_test() {
  let store = oni_storage.block_store_new()
  oni_storage.block_store_count(store) |> should.equal(0)

  let hash = make_block_hash(1)
  let block = make_block(make_block_hash(0), [make_coinbase_tx(50_000_000)])

  let store = oni_storage.block_store_put(store, hash, block)
  oni_storage.block_store_count(store) |> should.equal(1)
  oni_storage.block_store_has(store, hash) |> should.equal(True)

  case oni_storage.block_store_get(store, hash) {
    Ok(_) -> should.be_true(True)
    Error(_) -> should.fail()
  }

  let store = oni_storage.block_store_remove(store, hash)
  oni_storage.block_store_has(store, hash) |> should.equal(False)
}

// ============================================================================
// Header Store Tests
// ============================================================================

pub fn header_store_operations_test() {
  let store = oni_storage.header_store_new()

  let hash = make_block_hash(1)
  let header = make_block_header(make_block_hash(0))

  oni_storage.header_store_has(store, hash) |> should.equal(False)

  let store = oni_storage.header_store_put(store, hash, header)
  oni_storage.header_store_has(store, hash) |> should.equal(True)

  case oni_storage.header_store_get(store, hash) {
    Ok(h) -> h.version |> should.equal(1)
    Error(_) -> should.fail()
  }
}

// ============================================================================
// Undo Store Tests
// ============================================================================

pub fn undo_store_operations_test() {
  let store = oni_storage.undo_store_new()
  let hash = make_block_hash(1)

  case oni_storage.undo_store_get(store, hash) {
    Error(oni_storage.UndoDataMissing) -> should.be_true(True)
    _ -> should.fail()
  }

  let block_undo = oni_storage.block_undo_new()
  let store = oni_storage.undo_store_put(store, hash, block_undo)

  case oni_storage.undo_store_get(store, hash) {
    Ok(_) -> should.be_true(True)
    Error(_) -> should.fail()
  }

  let store = oni_storage.undo_store_remove(store, hash)
  case oni_storage.undo_store_get(store, hash) {
    Error(oni_storage.UndoDataMissing) -> should.be_true(True)
    _ -> should.fail()
  }
}

// ============================================================================
// Storage Connect/Disconnect Tests
// ============================================================================

pub fn storage_new_test() {
  let genesis_hash = make_block_hash(0)
  let storage = oni_storage.storage_new(genesis_hash)

  oni_storage.storage_get_height(storage) |> should.equal(0)
}

pub fn storage_connect_block_test() {
  let genesis_hash = make_block_hash(0)
  let storage = oni_storage.storage_new(genesis_hash)

  let block1_hash = make_block_hash(1)
  let coinbase_tx = make_coinbase_tx(5_000_000_000)
  let block1 = make_block(genesis_hash, [coinbase_tx])

  case oni_storage.storage_connect_block(storage, block1, block1_hash, 1) {
    Ok(#(new_storage, _undo)) -> {
      oni_storage.storage_get_height(new_storage) |> should.equal(1)

      // UTXO should exist for coinbase output
      oni_storage.utxo_count(new_storage.utxo_view) |> should.equal(1)
    }
    Error(_) -> should.fail()
  }
}

pub fn storage_connect_block_wrong_height_test() {
  let genesis_hash = make_block_hash(0)
  let storage = oni_storage.storage_new(genesis_hash)

  let block2_hash = make_block_hash(2)
  let block2 = make_block(make_block_hash(1), [make_coinbase_tx(5_000_000_000)])

  // Should fail because we're trying to connect at height 2 when current is 0
  case oni_storage.storage_connect_block(storage, block2, block2_hash, 2) {
    Error(oni_storage.InvalidBlockHeight) -> should.be_true(True)
    _ -> should.fail()
  }
}

pub fn storage_connect_and_disconnect_test() {
  let genesis_hash = make_block_hash(0)
  let storage = oni_storage.storage_new(genesis_hash)

  // Connect block 1
  let block1_hash = make_block_hash(1)
  let coinbase_tx = make_coinbase_tx(5_000_000_000)
  let block1 = make_block(genesis_hash, [coinbase_tx])

  let assert Ok(#(storage, _undo)) =
    oni_storage.storage_connect_block(storage, block1, block1_hash, 1)

  oni_storage.storage_get_height(storage) |> should.equal(1)
  oni_storage.utxo_count(storage.utxo_view) |> should.equal(1)

  // Disconnect block 1
  case oni_storage.storage_disconnect_block(storage, block1_hash) {
    Ok(new_storage) -> {
      oni_storage.storage_get_height(new_storage) |> should.equal(0)
      // Coinbase output should be removed
      oni_storage.utxo_count(new_storage.utxo_view) |> should.equal(0)
    }
    Error(_) -> should.fail()
  }
}

pub fn storage_disconnect_wrong_block_test() {
  let genesis_hash = make_block_hash(0)
  let storage = oni_storage.storage_new(genesis_hash)

  let block1_hash = make_block_hash(1)
  let block1 = make_block(genesis_hash, [make_coinbase_tx(5_000_000_000)])

  let assert Ok(#(storage, _)) =
    oni_storage.storage_connect_block(storage, block1, block1_hash, 1)

  // Try to disconnect a different block (not the tip)
  let wrong_hash = make_block_hash(99)
  case oni_storage.storage_disconnect_block(storage, wrong_hash) {
    Error(oni_storage.BlockNotInMainChain) -> should.be_true(True)
    _ -> should.fail()
  }
}

// ============================================================================
// Undo Data Tests
// ============================================================================

pub fn tx_undo_operations_test() {
  let tx_undo = oni_storage.tx_undo_new()
  let coin = oni_storage.coin_new(make_txout(100), 1, False)
  let tx_undo = oni_storage.tx_undo_add_spent(tx_undo, coin)

  case tx_undo.spent_coins {
    [oni_storage.TxInputUndo(c)] -> {
      oni_storage.coin_value(c) |> should.equal(100)
    }
    _ -> should.fail()
  }
}

pub fn block_undo_operations_test() {
  let block_undo = oni_storage.block_undo_new()

  let coin1 = oni_storage.coin_new(make_txout(100), 1, False)
  let tx_undo1 = oni_storage.tx_undo_new()
  let tx_undo1 = oni_storage.tx_undo_add_spent(tx_undo1, coin1)

  let coin2 = oni_storage.coin_new(make_txout(200), 1, False)
  let tx_undo2 = oni_storage.tx_undo_new()
  let tx_undo2 = oni_storage.tx_undo_add_spent(tx_undo2, coin2)

  let block_undo = oni_storage.block_undo_add(block_undo, tx_undo1)
  let block_undo = oni_storage.block_undo_add(block_undo, tx_undo2)
  let block_undo = oni_storage.block_undo_finalize(block_undo)

  // Get undos in disconnect order (should be reversed from add order)
  let tx_undos = oni_storage.block_undo_get_tx_undos(block_undo)
  case tx_undos {
    [u1, u2] -> {
      // First undo should be tx_undo2 (last added, first to disconnect)
      case u1.spent_coins {
        [oni_storage.TxInputUndo(c)] ->
          oni_storage.coin_value(c) |> should.equal(200)
        _ -> should.fail()
      }
      // Second undo should be tx_undo1
      case u2.spent_coins {
        [oni_storage.TxInputUndo(c)] ->
          oni_storage.coin_value(c) |> should.equal(100)
        _ -> should.fail()
      }
    }
    _ -> should.fail()
  }
}

// ============================================================================
// Chainstate Tests
// ============================================================================

pub fn chainstate_genesis_test() {
  let genesis_hash = make_block_hash(0)
  let chainstate = oni_storage.chainstate_genesis(genesis_hash)

  chainstate.best_height |> should.equal(0)
  chainstate.total_tx |> should.equal(1)
  chainstate.pruned |> should.equal(False)
}

// ============================================================================
// Error Type Tests
// ============================================================================

pub fn not_found_test() {
  let hash_bytes = <<
    0x00, 0x00, 0x00, 0x00, 0x00, 0x19, 0xd6, 0x68, 0x9c, 0x08, 0x5a, 0xe1, 0x65,
    0x83, 0x1e, 0x93, 0x4f, 0xf7, 0x63, 0xae, 0x46, 0xa2, 0xa6, 0xc1, 0x72, 0xb3,
    0xf1, 0xb6, 0x0a, 0x8c, 0xe2, 0x6f,
  >>
  let assert Ok(h) = oni_bitcoin.block_hash_from_bytes(hash_bytes)
  oni_storage.get_header(h)
  |> should.equal(Error(oni_storage.NotFound))
}

pub fn storage_error_types_test() {
  // Verify NotFound error is constructed correctly
  let _err = oni_storage.NotFound
  should.be_true(True)
}

pub fn database_error_test() {
  // Verify DatabaseError contains the message
  let err = oni_storage.DatabaseError("Connection failed")
  let oni_storage.DatabaseError(msg) = err
  msg |> should.equal("Connection failed")
}
