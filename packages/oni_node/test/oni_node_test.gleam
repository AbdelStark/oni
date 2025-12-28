// oni_node_test.gleam - Tests for the oni_node supervision tree
//
// Tests cover:
// - Chainstate actor lifecycle and operations
// - Mempool actor operations (add, remove, validation)
// - Integration between supervisor and storage/consensus

import gleeunit
import gleeunit/should
import gleam/erlang/process
import gleam/option.{None}
import oni_bitcoin
import oni_supervisor

pub fn main() {
  gleeunit.main()
}

// ============================================================================
// Chainstate Actor Tests
// ============================================================================

pub fn chainstate_start_test() {
  // Test that chainstate actor starts successfully
  let result = oni_supervisor.start_chainstate(oni_bitcoin.Mainnet)
  should.be_ok(result)
}

pub fn chainstate_initial_height_test() {
  // Test that chainstate starts at height 0
  let assert Ok(subject) = oni_supervisor.start_chainstate(oni_bitcoin.Mainnet)
  let height = process.call(subject, oni_supervisor.GetHeight, 1000)
  should.equal(height, 0)
}

pub fn chainstate_initial_tip_test() {
  // Test that chainstate starts with genesis tip
  let assert Ok(subject) = oni_supervisor.start_chainstate(oni_bitcoin.Mainnet)
  let tip = process.call(subject, oni_supervisor.GetTip, 1000)
  // Should have a tip (genesis hash)
  should.be_true(option.is_some(tip))
}

pub fn chainstate_testnet_start_test() {
  // Test that testnet chainstate starts successfully
  let result = oni_supervisor.start_chainstate(oni_bitcoin.Testnet)
  should.be_ok(result)
}

pub fn chainstate_regtest_start_test() {
  // Test that regtest chainstate starts successfully
  let result = oni_supervisor.start_chainstate(oni_bitcoin.Regtest)
  should.be_ok(result)
}

// ============================================================================
// Mempool Actor Tests
// ============================================================================

pub fn mempool_start_test() {
  // Test that mempool actor starts successfully
  let result = oni_supervisor.start_mempool(1000)
  should.be_ok(result)
}

pub fn mempool_initial_size_test() {
  // Test that mempool starts empty
  let assert Ok(subject) = oni_supervisor.start_mempool(1000)
  let size = process.call(subject, oni_supervisor.GetSize, 1000)
  should.equal(size, 0)
}

pub fn mempool_initial_txids_test() {
  // Test that mempool starts with no txids
  let assert Ok(subject) = oni_supervisor.start_mempool(1000)
  let txids = process.call(subject, oni_supervisor.GetTxids, 1000)
  should.equal(txids, [])
}

pub fn mempool_add_invalid_tx_test() {
  // Test that invalid transactions are rejected
  let assert Ok(subject) = oni_supervisor.start_mempool(1000)

  // Create an invalid transaction (no inputs)
  let invalid_tx = oni_bitcoin.Transaction(
    version: 1,
    inputs: [],  // No inputs - invalid
    outputs: [
      oni_bitcoin.TxOut(
        value: oni_bitcoin.sats(1000),
        script_pubkey: oni_bitcoin.script_from_bytes(<<>>),
      ),
    ],
    lock_time: 0,
  )

  let result = process.call(subject, oni_supervisor.AddTx(invalid_tx, _), 1000)
  should.be_error(result)
}

pub fn mempool_add_no_outputs_tx_test() {
  // Test that transactions with no outputs are rejected
  let assert Ok(subject) = oni_supervisor.start_mempool(1000)

  // Create a coinbase-like input (for testing structure only)
  let null_outpoint = oni_bitcoin.OutPoint(
    txid: oni_bitcoin.Txid(hash: oni_bitcoin.Hash256(<<0:256>>)),
    vout: 0xFFFFFFFF,
  )

  let invalid_tx = oni_bitcoin.Transaction(
    version: 1,
    inputs: [
      oni_bitcoin.TxIn(
        prevout: null_outpoint,
        script_sig: oni_bitcoin.script_from_bytes(<<0x04, 0x00, 0x00, 0x00, 0x00>>),
        sequence: 0xFFFFFFFF,
        witness: [],
      ),
    ],
    outputs: [],  // No outputs - invalid
    lock_time: 0,
  )

  let result = process.call(subject, oni_supervisor.AddTx(invalid_tx, _), 1000)
  should.be_error(result)
}

pub fn mempool_size_limit_test() {
  // Test that mempool respects size limits
  let assert Ok(subject) = oni_supervisor.start_mempool(0)  // Zero size limit

  // Create a minimal valid-structured transaction
  let null_outpoint = oni_bitcoin.OutPoint(
    txid: oni_bitcoin.Txid(hash: oni_bitcoin.Hash256(<<1:256>>)),
    vout: 0,
  )

  let tx = oni_bitcoin.Transaction(
    version: 1,
    inputs: [
      oni_bitcoin.TxIn(
        prevout: null_outpoint,
        script_sig: oni_bitcoin.script_from_bytes(<<>>),
        sequence: 0xFFFFFFFF,
        witness: [],
      ),
    ],
    outputs: [
      oni_bitcoin.TxOut(
        value: oni_bitcoin.sats(1000),
        script_pubkey: oni_bitcoin.script_from_bytes(<<>>),
      ),
    ],
    lock_time: 0,
  )

  let result = process.call(subject, oni_supervisor.AddTx(tx, _), 1000)
  should.be_error(result)  // Should fail - mempool full
}

// ============================================================================
// Sync Coordinator Actor Tests
// ============================================================================

pub fn sync_start_test() {
  // Test that sync coordinator starts successfully
  let result = oni_supervisor.start_sync()
  should.be_ok(result)
}

pub fn sync_initial_state_test() {
  // Test that sync coordinator starts in IBD state
  let assert Ok(subject) = oni_supervisor.start_sync()
  let state = process.call(subject, oni_supervisor.GetSyncState, 1000)
  // Initial state should be "idle" or "ibd"
  should.be_true(state == "idle" || state == "ibd")
}

// ============================================================================
// Integration Tests
// ============================================================================

pub fn node_handles_creation_test() {
  // Test that all actors can be created and bundled
  let assert Ok(chainstate) = oni_supervisor.start_chainstate(oni_bitcoin.Regtest)
  let assert Ok(mempool) = oni_supervisor.start_mempool(10_000)
  let assert Ok(sync) = oni_supervisor.start_sync()

  let handles = oni_supervisor.NodeHandles(
    chainstate: chainstate,
    mempool: mempool,
    sync: sync,
  )

  // Verify handles are valid by querying each
  let height = process.call(handles.chainstate, oni_supervisor.GetHeight, 1000)
  let size = process.call(handles.mempool, oni_supervisor.GetSize, 1000)
  let state = process.call(handles.sync, oni_supervisor.GetSyncState, 1000)

  should.equal(height, 0)
  should.equal(size, 0)
  should.be_true(state == "idle" || state == "ibd")
}

pub fn utxo_not_found_test() {
  // Test that non-existent UTXOs return None
  let assert Ok(subject) = oni_supervisor.start_chainstate(oni_bitcoin.Regtest)

  let outpoint = oni_bitcoin.OutPoint(
    txid: oni_bitcoin.Txid(hash: oni_bitcoin.Hash256(<<1:256>>)),
    vout: 0,
  )

  let result = process.call(subject, oni_supervisor.GetUtxo(outpoint, _), 1000)
  should.equal(result, None)
}
