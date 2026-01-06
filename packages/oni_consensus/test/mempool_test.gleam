import gleam/option.{None, Some}
import gleeunit
import gleeunit/should
import mempool
import oni_bitcoin

pub fn main() {
  gleeunit.main()
}

// ============================================================================
// Helper Functions
// ============================================================================

fn make_txid(n: Int) -> oni_bitcoin.Txid {
  let bytes = <<n:256-little>>
  let assert Ok(txid) = oni_bitcoin.txid_from_bytes(bytes)
  txid
}

fn make_outpoint(n: Int, vout: Int) -> oni_bitcoin.OutPoint {
  oni_bitcoin.OutPoint(txid: make_txid(n), vout: vout)
}

fn make_simple_tx(inputs: List(Int), outputs: Int) -> oni_bitcoin.Transaction {
  let tx_inputs =
    inputs
    |> list.map(fn(n) {
      oni_bitcoin.TxIn(
        prevout: make_outpoint(n, 0),
        script_sig: oni_bitcoin.Script(<<>>),
        sequence: 0xFFFFFFFF,
        witness: [],
      )
    })

  let tx_outputs =
    list.range(0, outputs - 1)
    |> list.map(fn(_) {
      oni_bitcoin.TxOut(
        value: oni_bitcoin.sats(1000),
        script_pubkey: oni_bitcoin.Script(<<>>),
      )
    })

  oni_bitcoin.Transaction(
    version: 2,
    inputs: tx_inputs,
    outputs: tx_outputs,
    lock_time: 0,
  )
}

import gleam/list

// ============================================================================
// Mempool Tests
// ============================================================================

pub fn mempool_new_test() {
  let pool = mempool.mempool_new()

  mempool.mempool_size(pool) |> should.equal(0)
  mempool.mempool_count(pool) |> should.equal(0)
}

pub fn mempool_stats_empty_test() {
  let pool = mempool.mempool_new()
  let stats = mempool.mempool_stats(pool)

  stats.tx_count |> should.equal(0)
  stats.size_bytes |> should.equal(0)
  stats.total_fees |> should.equal(0)
}

pub fn mempool_has_not_found_test() {
  let pool = mempool.mempool_new()
  let txid = make_txid(1)

  mempool.mempool_has(pool, txid) |> should.be_false
}

pub fn mempool_get_not_found_test() {
  let pool = mempool.mempool_new()
  let txid = make_txid(1)

  case mempool.mempool_get(pool, txid) {
    None -> should.be_ok(Ok(Nil))
    Some(_) -> should.fail()
  }
}

// ============================================================================
// Orphan Pool Tests
// ============================================================================

pub fn orphan_pool_new_test() {
  let pool = mempool.orphan_pool_new()

  mempool.orphan_pool_count(pool) |> should.equal(0)
}

pub fn orphan_pool_add_test() {
  let pool = mempool.orphan_pool_new()
  let tx = make_simple_tx([1], 1)
  let txid = make_txid(100)

  let updated = mempool.orphan_pool_add(pool, tx, txid, 1000)

  mempool.orphan_pool_count(updated) |> should.equal(1)
}

pub fn orphan_pool_remove_test() {
  let pool = mempool.orphan_pool_new()
  let tx = make_simple_tx([1], 1)
  let txid = make_txid(100)

  let with_orphan = mempool.orphan_pool_add(pool, tx, txid, 1000)
  mempool.orphan_pool_count(with_orphan) |> should.equal(1)

  let after_remove = mempool.orphan_pool_remove(with_orphan, txid)
  mempool.orphan_pool_count(after_remove) |> should.equal(0)
}

pub fn orphan_pool_expire_test() {
  let pool = mempool.orphan_pool_new()
  let tx = make_simple_tx([1], 1)
  let txid = make_txid(100)

  // Add with old timestamp
  let with_orphan = mempool.orphan_pool_add(pool, tx, txid, 0)
  mempool.orphan_pool_count(with_orphan) |> should.equal(1)

  // Expire with current time way in future
  let after_expire = mempool.orphan_pool_expire(with_orphan, 100_000_000)
  mempool.orphan_pool_count(after_expire) |> should.equal(0)
}

pub fn orphan_pool_no_expire_recent_test() {
  let pool = mempool.orphan_pool_new()
  let tx = make_simple_tx([1], 1)
  let txid = make_txid(100)

  // Add with recent timestamp
  let with_orphan = mempool.orphan_pool_add(pool, tx, txid, 1000)

  // Try to expire with time only slightly later
  let after_expire = mempool.orphan_pool_expire(with_orphan, 1500)
  mempool.orphan_pool_count(after_expire) |> should.equal(1)
}

// ============================================================================
// Fee Estimator Tests
// ============================================================================

pub fn fee_estimator_new_test() {
  let est = mempool.fee_estimator_new()

  // New estimator should have no estimate
  case mempool.fee_estimator_estimate(est, mempool.FeeTarget(6)) {
    None -> should.be_ok(Ok(Nil))
    Some(_) -> should.fail()
  }
}

pub fn fee_estimator_record_block_test() {
  let est = mempool.fee_estimator_new()

  let updated = mempool.fee_estimator_record_block(est, 5.0)

  // After recording one block, should have an estimate
  case mempool.fee_estimator_estimate(updated, mempool.FeeTarget(6)) {
    Some(estimate) -> {
      estimate.fee_rate |> should.equal(5.0)
      estimate.confidence |> should.equal(0.5)
    }
    None -> should.fail()
  }
}

pub fn fee_estimator_multiple_blocks_test() {
  let est = mempool.fee_estimator_new()

  // Record several blocks
  let est1 = mempool.fee_estimator_record_block(est, 1.0)
  let est2 = mempool.fee_estimator_record_block(est1, 3.0)
  let est3 = mempool.fee_estimator_record_block(est2, 5.0)

  case mempool.fee_estimator_estimate(est3, mempool.FeeTarget(1)) {
    Some(estimate) -> {
      // Should return median of 1.0, 3.0, 5.0 which is 3.0
      estimate.fee_rate |> should.equal(3.0)
    }
    None -> should.fail()
  }
}

// ============================================================================
// Entry Tests
// ============================================================================

pub fn entry_ancestor_score_test() {
  let tx = make_simple_tx([1], 2)
  let txid = make_txid(1)
  let fee = oni_bitcoin.sats(1000)

  let entry = mempool.entry_new(tx, txid, fee, 1000, 800_000)

  // Should have non-zero score
  let score = mempool.entry_ancestor_score(entry)
  case score >. 0.0 {
    True -> should.be_ok(Ok(Nil))
    False -> should.fail()
  }
}

pub fn entry_descendant_score_test() {
  let tx = make_simple_tx([1], 2)
  let txid = make_txid(1)
  let fee = oni_bitcoin.sats(1000)

  let entry = mempool.entry_new(tx, txid, fee, 1000, 800_000)

  let score = mempool.entry_descendant_score(entry)
  case score >. 0.0 {
    True -> should.be_ok(Ok(Nil))
    False -> should.fail()
  }
}
