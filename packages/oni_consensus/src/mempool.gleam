// mempool.gleam - Transaction mempool implementation
//
// This module implements the Bitcoin transaction mempool with:
// - Mempool admission rules (policy)
// - Size limits and eviction
// - Orphan transaction handling
// - Fee-based prioritization
// - Ancestor/descendant tracking
//
// Phase 8 Implementation

import gleam/dict.{type Dict}
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/set.{type Set}
import oni_bitcoin.{
  type Amount, type OutPoint, type Transaction, type Txid,
}

// ============================================================================
// Constants
// ============================================================================

/// Maximum mempool size in bytes
pub const max_mempool_size = 300_000_000  // 300 MB

/// Maximum transaction size (policy limit, not consensus)
pub const max_tx_size = 400_000  // 400 KB

/// Minimum relay fee rate in sat/vB
pub const min_relay_fee_rate = 1

/// Default incremental relay fee rate in sat/vB
pub const incremental_relay_fee_rate = 1

/// Maximum ancestors allowed for a single transaction
pub const max_ancestors = 25

/// Maximum descendants allowed for a single transaction
pub const max_descendants = 25

/// Maximum ancestor/descendant size in bytes
pub const max_ancestor_size = 101_000  // ~101 KB

/// Maximum descendant size in bytes
pub const max_descendant_size = 101_000  // ~101 KB

/// Maximum orphan transactions to keep
pub const max_orphan_txs = 100

/// Maximum size of a single orphan transaction
pub const max_orphan_tx_size = 100_000  // 100 KB

/// Orphan transaction expiry time in seconds
pub const orphan_expiry_secs = 1200  // 20 minutes

/// Mempool expiry time in seconds (default 2 weeks)
pub const mempool_expiry_secs = 1_209_600

// ============================================================================
// Mempool Entry
// ============================================================================

/// A transaction entry in the mempool
pub type MempoolEntry {
  MempoolEntry(
    /// The transaction
    tx: Transaction,
    /// Transaction ID
    txid: Txid,
    /// Transaction size in virtual bytes
    vsize: Int,
    /// Transaction fee in satoshis
    fee: Amount,
    /// Fee rate in sat/vB (fee / vsize)
    fee_rate: Float,
    /// Time when transaction entered mempool (unix timestamp)
    time: Int,
    /// Block height when transaction entered mempool
    height: Int,
    /// Set of ancestor txids (transactions this depends on)
    ancestors: Set(String),
    /// Set of descendant txids (transactions that depend on this)
    descendants: Set(String),
    /// Cumulative ancestor size
    ancestor_size: Int,
    /// Cumulative ancestor fees
    ancestor_fees: Amount,
    /// Cumulative descendant size
    descendant_size: Int,
    /// Cumulative descendant fees
    descendant_fees: Amount,
  )
}

/// Create a new mempool entry
pub fn entry_new(
  tx: Transaction,
  txid: Txid,
  fee: Amount,
  time: Int,
  height: Int,
) -> MempoolEntry {
  let vsize = estimate_vsize(tx)
  let fee_sats = oni_bitcoin.amount_to_sats(fee)
  let fee_rate = case vsize > 0 {
    True -> int.to_float(fee_sats) /. int.to_float(vsize)
    False -> 0.0
  }

  MempoolEntry(
    tx: tx,
    txid: txid,
    vsize: vsize,
    fee: fee,
    fee_rate: fee_rate,
    time: time,
    height: height,
    ancestors: set.new(),
    descendants: set.new(),
    ancestor_size: vsize,
    ancestor_fees: fee,
    descendant_size: vsize,
    descendant_fees: fee,
  )
}

/// Estimate virtual size of a transaction
fn estimate_vsize(tx: Transaction) -> Int {
  // Simplified estimate: count inputs and outputs
  let base_size = 10  // Version + locktime overhead
  let input_size = list.length(tx.inputs) * 41  // Per-input average
  let output_size = list.length(tx.outputs) * 34  // Per-output average

  // Check if segwit
  let has_witness = list.any(tx.inputs, fn(input) {
    !list.is_empty(input.witness)
  })

  case has_witness {
    True -> {
      // SegWit: weight = base * 3 + total, vsize = weight / 4
      let witness_size = list.fold(tx.inputs, 0, fn(acc, input) {
        acc + list.fold(input.witness, 0, fn(w_acc, elem) {
          w_acc + get_bit_array_size(elem)
        })
      })
      let base = base_size + input_size + output_size
      let weight = base * 3 + base + witness_size
      weight / 4
    }
    False -> base_size + input_size + output_size
  }
}

fn get_bit_array_size(data: BitArray) -> Int {
  count_bytes(data, 0)
}

fn count_bytes(data: BitArray, acc: Int) -> Int {
  case data {
    <<_:8, rest:bits>> -> count_bytes(rest, acc + 1)
    _ -> acc
  }
}

/// Get ancestor score (used for eviction)
pub fn entry_ancestor_score(entry: MempoolEntry) -> Float {
  let fees = oni_bitcoin.amount_to_sats(entry.ancestor_fees)
  case entry.ancestor_size > 0 {
    True -> int.to_float(fees) /. int.to_float(entry.ancestor_size)
    False -> 0.0
  }
}

/// Get descendant score (used for mining)
pub fn entry_descendant_score(entry: MempoolEntry) -> Float {
  let fees = oni_bitcoin.amount_to_sats(entry.descendant_fees)
  case entry.descendant_size > 0 {
    True -> int.to_float(fees) /. int.to_float(entry.descendant_size)
    False -> 0.0
  }
}

// ============================================================================
// Mempool
// ============================================================================

/// The transaction mempool
pub type Mempool {
  Mempool(
    /// All transactions by txid
    txs: Dict(String, MempoolEntry),
    /// Transactions by outpoint (for UTXO lookup)
    by_outpoint: Dict(String, String),
    /// Total size in bytes
    total_size: Int,
    /// Total fees
    total_fees: Amount,
    /// Minimum fee rate for acceptance
    min_fee_rate: Float,
    /// Orphan transactions
    orphans: OrphanPool,
  )
}

/// Create a new empty mempool
pub fn mempool_new() -> Mempool {
  Mempool(
    txs: dict.new(),
    by_outpoint: dict.new(),
    total_size: 0,
    total_fees: oni_bitcoin.sats(0),
    min_fee_rate: int.to_float(min_relay_fee_rate),
    orphans: orphan_pool_new(),
  )
}

/// Get mempool size in bytes
pub fn mempool_size(pool: Mempool) -> Int {
  pool.total_size
}

/// Get mempool transaction count
pub fn mempool_count(pool: Mempool) -> Int {
  dict.size(pool.txs)
}

/// Check if mempool contains a transaction
pub fn mempool_has(pool: Mempool, txid: Txid) -> Bool {
  let key = oni_bitcoin.hash256_to_hex(txid.hash)
  dict.has_key(pool.txs, key)
}

/// Get a transaction from mempool
pub fn mempool_get(pool: Mempool, txid: Txid) -> Option(MempoolEntry) {
  let key = oni_bitcoin.hash256_to_hex(txid.hash)
  case dict.get(pool.txs, key) {
    Ok(entry) -> Some(entry)
    Error(_) -> None
  }
}

// ============================================================================
// Mempool Admission
// ============================================================================

/// Result of trying to add a transaction
pub type AddResult {
  AddOk(Mempool)
  AddOrphan(Mempool)
  AddError(MempoolError)
}

/// Mempool errors
pub type MempoolError {
  ErrTxAlreadyExists
  ErrTxTooLarge
  ErrFeeTooLow
  ErrConflict(Txid)
  ErrMissingInputs(List(OutPoint))
  ErrAncestorLimitExceeded
  ErrDescendantLimitExceeded
  ErrNonStandard(String)
  ErrConsensusInvalid(String)
  ErrMempoolFull
}

/// Add a transaction to the mempool
pub fn mempool_add(
  pool: Mempool,
  tx: Transaction,
  txid: Txid,
  fee: Amount,
  time: Int,
  height: Int,
) -> AddResult {
  let key = oni_bitcoin.hash256_to_hex(txid.hash)

  // Check if already exists
  case dict.has_key(pool.txs, key) {
    True -> AddError(ErrTxAlreadyExists)
    False -> {
      // Create entry
      let entry = entry_new(tx, txid, fee, time, height)

      // Check size limit
      case entry.vsize > max_tx_size {
        True -> AddError(ErrTxTooLarge)
        False -> {
          // Check fee rate
          case entry.fee_rate <. pool.min_fee_rate {
            True -> AddError(ErrFeeTooLow)
            False -> {
              // Check for missing inputs (would make it orphan)
              let missing = find_missing_inputs(pool, tx)
              case list.is_empty(missing) {
                False -> {
                  // Add to orphan pool
                  let new_orphans = orphan_pool_add(pool.orphans, tx, txid, time)
                  AddOrphan(Mempool(..pool, orphans: new_orphans))
                }
                True -> {
                  // Check ancestor/descendant limits
                  case check_package_limits(pool, entry) {
                    False -> AddError(ErrAncestorLimitExceeded)
                    True -> {
                      // Check mempool size
                      case pool.total_size + entry.vsize > max_mempool_size {
                        True -> {
                          // Try eviction
                          case try_evict_for_entry(pool, entry) {
                            Error(_) -> AddError(ErrMempoolFull)
                            Ok(evicted_pool) -> do_add(evicted_pool, entry, key)
                          }
                        }
                        False -> do_add(pool, entry, key)
                      }
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}

fn do_add(pool: Mempool, entry: MempoolEntry, key: String) -> AddResult {
  // Add to main index
  let new_txs = dict.insert(pool.txs, key, entry)

  // Add to outpoint index
  let new_by_outpoint = add_to_outpoint_index(pool.by_outpoint, entry.tx, key)

  // Update totals
  let new_size = pool.total_size + entry.vsize
  let new_fees = oni_bitcoin.sats(
    oni_bitcoin.amount_to_sats(pool.total_fees) +
    oni_bitcoin.amount_to_sats(entry.fee)
  )

  // Update ancestors and descendants
  let updated_pool = Mempool(
    ..pool,
    txs: new_txs,
    by_outpoint: new_by_outpoint,
    total_size: new_size,
    total_fees: new_fees,
  )

  // Update ancestor/descendant tracking
  let final_pool = update_ancestors_descendants(updated_pool, entry)

  AddOk(final_pool)
}

fn add_to_outpoint_index(
  index: Dict(String, String),
  tx: Transaction,
  txid_key: String,
) -> Dict(String, String) {
  // For each output, add an entry
  let outputs_with_idx = list.index_map(tx.outputs, fn(output, idx) {
    #(output, idx)
  })

  list.fold(outputs_with_idx, index, fn(acc, pair) {
    let #(_, idx) = pair
    let outpoint_key = txid_key <> ":" <> int.to_string(idx)
    dict.insert(acc, outpoint_key, txid_key)
  })
}

fn find_missing_inputs(pool: Mempool, tx: Transaction) -> List(OutPoint) {
  list.filter_map(tx.inputs, fn(input) {
    let outpoint_key = oni_bitcoin.hash256_to_hex(input.prevout.txid.hash) <>
      ":" <> int.to_string(input.prevout.vout)
    case dict.has_key(pool.by_outpoint, outpoint_key) {
      True -> Error(Nil)  // Found in mempool
      False -> Ok(input.prevout)  // Missing (could be in UTXO set)
    }
  })
}

fn check_package_limits(pool: Mempool, entry: MempoolEntry) -> Bool {
  // Calculate ancestor count and size
  let ancestor_info = get_ancestor_info(pool, entry.tx)

  ancestor_info.count <= max_ancestors &&
  ancestor_info.size <= max_ancestor_size
}

type AncestorInfo {
  AncestorInfo(count: Int, size: Int, fees: Int)
}

fn get_ancestor_info(pool: Mempool, tx: Transaction) -> AncestorInfo {
  let ancestor_txids = get_direct_ancestors(pool, tx)
  count_ancestors(pool, ancestor_txids, set.new(), 0, 0, 0)
}

fn get_direct_ancestors(pool: Mempool, tx: Transaction) -> List(String) {
  list.filter_map(tx.inputs, fn(input) {
    let key = oni_bitcoin.hash256_to_hex(input.prevout.txid.hash)
    case dict.has_key(pool.txs, key) {
      True -> Ok(key)
      False -> Error(Nil)
    }
  })
}

fn count_ancestors(
  pool: Mempool,
  to_check: List(String),
  visited: Set(String),
  count: Int,
  size: Int,
  fees: Int,
) -> AncestorInfo {
  case to_check {
    [] -> AncestorInfo(count: count, size: size, fees: fees)
    [txid, ..rest] -> {
      case set.contains(visited, txid) {
        True -> count_ancestors(pool, rest, visited, count, size, fees)
        False -> {
          case dict.get(pool.txs, txid) {
            Error(_) -> count_ancestors(pool, rest, visited, count, size, fees)
            Ok(entry) -> {
              let new_visited = set.insert(visited, txid)
              let new_count = count + 1
              let new_size = size + entry.vsize
              let new_fees = fees + oni_bitcoin.amount_to_sats(entry.fee)
              let more_ancestors = get_direct_ancestors(pool, entry.tx)
              let new_to_check = list.append(rest, more_ancestors)
              count_ancestors(pool, new_to_check, new_visited, new_count, new_size, new_fees)
            }
          }
        }
      }
    }
  }
}

fn update_ancestors_descendants(pool: Mempool, entry: MempoolEntry) -> Mempool {
  // For now, simplified implementation without full tracking
  pool
}

fn try_evict_for_entry(
  pool: Mempool,
  entry: MempoolEntry,
) -> Result(Mempool, Nil) {
  // Find lowest feerate transactions to evict
  let needed_space = entry.vsize
  let entries = dict.values(pool.txs)
  let sorted = list.sort(entries, fn(a, b) {
    float.compare(entry_ancestor_score(a), entry_ancestor_score(b))
  })

  evict_until_space(pool, sorted, needed_space, entry.fee_rate)
}

fn evict_until_space(
  pool: Mempool,
  candidates: List(MempoolEntry),
  needed: Int,
  min_rate: Float,
) -> Result(Mempool, Nil) {
  case needed <= 0 {
    True -> Ok(pool)
    False -> {
      case candidates {
        [] -> Error(Nil)
        [candidate, ..rest] -> {
          // Only evict if lower fee rate
          case entry_ancestor_score(candidate) <. min_rate {
            False -> Error(Nil)  // Would evict higher fee tx
            True -> {
              let new_pool = mempool_remove(pool, candidate.txid)
              let new_needed = needed - candidate.vsize
              evict_until_space(new_pool, rest, new_needed, min_rate)
            }
          }
        }
      }
    }
  }
}

/// Remove a transaction from mempool
pub fn mempool_remove(pool: Mempool, txid: Txid) -> Mempool {
  let key = oni_bitcoin.hash256_to_hex(txid.hash)

  case dict.get(pool.txs, key) {
    Error(_) -> pool
    Ok(entry) -> {
      // Remove from main index
      let new_txs = dict.delete(pool.txs, key)

      // Remove from outpoint index
      let new_by_outpoint = remove_from_outpoint_index(pool.by_outpoint, entry.tx, key)

      // Update totals
      let new_size = int.max(0, pool.total_size - entry.vsize)
      let new_fees = oni_bitcoin.sats(int.max(0,
        oni_bitcoin.amount_to_sats(pool.total_fees) -
        oni_bitcoin.amount_to_sats(entry.fee)
      ))

      Mempool(
        ..pool,
        txs: new_txs,
        by_outpoint: new_by_outpoint,
        total_size: new_size,
        total_fees: new_fees,
      )
    }
  }
}

fn remove_from_outpoint_index(
  index: Dict(String, String),
  tx: Transaction,
  txid_key: String,
) -> Dict(String, String) {
  let num_outputs = list.length(tx.outputs)
  remove_outputs_loop(index, txid_key, 0, num_outputs)
}

fn remove_outputs_loop(
  index: Dict(String, String),
  txid_key: String,
  current: Int,
  total: Int,
) -> Dict(String, String) {
  case current >= total {
    True -> index
    False -> {
      let outpoint_key = txid_key <> ":" <> int.to_string(current)
      let new_index = dict.delete(index, outpoint_key)
      remove_outputs_loop(new_index, txid_key, current + 1, total)
    }
  }
}

/// Remove transactions that conflict with a confirmed block
pub fn mempool_remove_for_block(
  pool: Mempool,
  txids: List(Txid),
  spent_outpoints: List(OutPoint),
) -> Mempool {
  // Remove transactions included in block
  let after_included = list.fold(txids, pool, fn(acc, txid) {
    mempool_remove(acc, txid)
  })

  // Remove transactions that spend same inputs (conflicts)
  remove_conflicts(after_included, spent_outpoints)
}

fn remove_conflicts(pool: Mempool, spent: List(OutPoint)) -> Mempool {
  list.fold(spent, pool, fn(acc, outpoint) {
    let key = oni_bitcoin.hash256_to_hex(outpoint.txid.hash) <>
      ":" <> int.to_string(outpoint.vout)
    case dict.get(acc.by_outpoint, key) {
      Error(_) -> acc
      Ok(txid_key) -> {
        // Find and remove conflicting transaction
        case dict.get(acc.txs, txid_key) {
          Error(_) -> acc
          Ok(entry) -> mempool_remove(acc, entry.txid)
        }
      }
    }
  })
}

// ============================================================================
// Orphan Pool
// ============================================================================

/// Orphan transaction entry
pub type OrphanEntry {
  OrphanEntry(
    tx: Transaction,
    txid: Txid,
    time: Int,
    from_peer: Option(String),
  )
}

/// Pool of orphan transactions
pub type OrphanPool {
  OrphanPool(
    orphans: Dict(String, OrphanEntry),
    by_prev: Dict(String, List(String)),
  )
}

/// Create a new orphan pool
pub fn orphan_pool_new() -> OrphanPool {
  OrphanPool(
    orphans: dict.new(),
    by_prev: dict.new(),
  )
}

/// Add an orphan transaction
pub fn orphan_pool_add(
  pool: OrphanPool,
  tx: Transaction,
  txid: Txid,
  time: Int,
) -> OrphanPool {
  let key = oni_bitcoin.hash256_to_hex(txid.hash)

  // Check limits
  case dict.size(pool.orphans) >= max_orphan_txs {
    True -> pool  // Don't add, pool is full
    False -> {
      let entry = OrphanEntry(
        tx: tx,
        txid: txid,
        time: time,
        from_peer: None,
      )

      let new_orphans = dict.insert(pool.orphans, key, entry)

      // Index by previous outpoint for quick lookup
      let new_by_prev = list.fold(tx.inputs, pool.by_prev, fn(acc, input) {
        let prev_key = oni_bitcoin.hash256_to_hex(input.prevout.txid.hash)
        case dict.get(acc, prev_key) {
          Ok(existing) -> dict.insert(acc, prev_key, [key, ..existing])
          Error(_) -> dict.insert(acc, prev_key, [key])
        }
      })

      OrphanPool(orphans: new_orphans, by_prev: new_by_prev)
    }
  }
}

/// Get orphans that depend on a given transaction
pub fn orphan_pool_get_children(pool: OrphanPool, txid: Txid) -> List(OrphanEntry) {
  let key = oni_bitcoin.hash256_to_hex(txid.hash)
  case dict.get(pool.by_prev, key) {
    Error(_) -> []
    Ok(child_keys) ->
      list.filter_map(child_keys, fn(child_key) {
        case dict.get(pool.orphans, child_key) {
          Ok(entry) -> Ok(entry)
          Error(_) -> Error(Nil)
        }
      })
  }
}

/// Remove an orphan transaction
pub fn orphan_pool_remove(pool: OrphanPool, txid: Txid) -> OrphanPool {
  let key = oni_bitcoin.hash256_to_hex(txid.hash)

  case dict.get(pool.orphans, key) {
    Error(_) -> pool
    Ok(entry) -> {
      let new_orphans = dict.delete(pool.orphans, key)

      // Remove from by_prev index
      let new_by_prev = list.fold(entry.tx.inputs, pool.by_prev, fn(acc, input) {
        let prev_key = oni_bitcoin.hash256_to_hex(input.prevout.txid.hash)
        case dict.get(acc, prev_key) {
          Error(_) -> acc
          Ok(children) -> {
            let filtered = list.filter(children, fn(k) { k != key })
            case list.is_empty(filtered) {
              True -> dict.delete(acc, prev_key)
              False -> dict.insert(acc, prev_key, filtered)
            }
          }
        }
      })

      OrphanPool(orphans: new_orphans, by_prev: new_by_prev)
    }
  }
}

/// Expire old orphans
pub fn orphan_pool_expire(pool: OrphanPool, current_time: Int) -> OrphanPool {
  let expiry_time = current_time - orphan_expiry_secs

  dict.fold(pool.orphans, pool, fn(acc, key, entry) {
    case entry.time < expiry_time {
      True -> orphan_pool_remove(acc, entry.txid)
      False -> acc
    }
  })
}

/// Count orphans
pub fn orphan_pool_count(pool: OrphanPool) -> Int {
  dict.size(pool.orphans)
}

// ============================================================================
// Fee Estimation
// ============================================================================

/// Fee estimation target (in blocks)
pub type FeeTarget {
  FeeTarget(blocks: Int)
}

/// Fee estimation result
pub type FeeEstimate {
  FeeEstimate(
    fee_rate: Float,
    target_blocks: Int,
    confidence: Float,
  )
}

/// Fee estimator state
pub type FeeEstimator {
  FeeEstimator(
    /// Historical fee data by target
    history: Dict(Int, List(Float)),
    /// Recent block fee rates
    block_rates: List(Float),
    /// Number of blocks tracked
    blocks_tracked: Int,
  )
}

/// Create a new fee estimator
pub fn fee_estimator_new() -> FeeEstimator {
  FeeEstimator(
    history: dict.new(),
    block_rates: [],
    blocks_tracked: 0,
  )
}

/// Record a transaction that was included in a block
pub fn fee_estimator_record_tx(
  est: FeeEstimator,
  fee_rate: Float,
  blocks_to_confirm: Int,
) -> FeeEstimator {
  // Update history for this confirmation target
  let target = int.min(blocks_to_confirm, 144)  // Cap at 144 blocks

  let new_history = case dict.get(est.history, target) {
    Error(_) -> dict.insert(est.history, target, [fee_rate])
    Ok(existing) -> {
      // Keep last 1000 samples
      let updated = case list.length(existing) >= 1000 {
        True -> [fee_rate, ..list.take(existing, 999)]
        False -> [fee_rate, ..existing]
      }
      dict.insert(est.history, target, updated)
    }
  }

  FeeEstimator(..est, history: new_history)
}

/// Record block fee statistics
pub fn fee_estimator_record_block(
  est: FeeEstimator,
  median_fee_rate: Float,
) -> FeeEstimator {
  let new_rates = case list.length(est.block_rates) >= 144 {
    True -> [median_fee_rate, ..list.take(est.block_rates, 143)]
    False -> [median_fee_rate, ..est.block_rates]
  }

  FeeEstimator(
    ..est,
    block_rates: new_rates,
    blocks_tracked: est.blocks_tracked + 1,
  )
}

/// Estimate fee for a target number of blocks
pub fn fee_estimator_estimate(
  est: FeeEstimator,
  target: FeeTarget,
) -> Option(FeeEstimate) {
  let target_blocks = int.min(target.blocks, 144)

  // Look for exact match first
  case dict.get(est.history, target_blocks) {
    Ok(samples) when list.length(samples) >= 10 -> {
      let fee_rate = percentile(samples, 50)
      Some(FeeEstimate(
        fee_rate: fee_rate,
        target_blocks: target_blocks,
        confidence: calculate_confidence(list.length(samples)),
      ))
    }
    _ -> {
      // Fall back to recent block median
      case list.is_empty(est.block_rates) {
        True -> None
        False -> {
          let fee_rate = percentile(est.block_rates, 50)
          Some(FeeEstimate(
            fee_rate: fee_rate,
            target_blocks: target_blocks,
            confidence: 0.5,  // Lower confidence
          ))
        }
      }
    }
  }
}

/// Calculate nth percentile of a list
fn percentile(values: List(Float), p: Int) -> Float {
  let sorted = list.sort(values, float.compare)
  let idx = list.length(sorted) * p / 100
  case list_at_float(sorted, idx) {
    Ok(v) -> v
    Error(_) -> 0.0
  }
}

fn list_at_float(lst: List(Float), idx: Int) -> Result(Float, Nil) {
  case lst, idx {
    [], _ -> Error(Nil)
    [head, ..], 0 -> Ok(head)
    [_, ..tail], n if n > 0 -> list_at_float(tail, n - 1)
    _, _ -> Error(Nil)
  }
}

fn calculate_confidence(sample_count: Int) -> Float {
  // Simple confidence based on sample size
  let base = int.to_float(int.min(sample_count, 1000)) /. 1000.0
  base *. 0.95
}

// ============================================================================
// Mempool Statistics
// ============================================================================

/// Mempool statistics
pub type MempoolStats {
  MempoolStats(
    size_bytes: Int,
    tx_count: Int,
    orphan_count: Int,
    total_fees: Int,
    min_fee_rate: Float,
    avg_fee_rate: Float,
  )
}

/// Get mempool statistics
pub fn mempool_stats(pool: Mempool) -> MempoolStats {
  let entries = dict.values(pool.txs)
  let total_fee_rate = list.fold(entries, 0.0, fn(acc, e) { acc +. e.fee_rate })
  let avg_rate = case dict.size(pool.txs) {
    0 -> 0.0
    n -> total_fee_rate /. int.to_float(n)
  }

  MempoolStats(
    size_bytes: pool.total_size,
    tx_count: dict.size(pool.txs),
    orphan_count: orphan_pool_count(pool.orphans),
    total_fees: oni_bitcoin.amount_to_sats(pool.total_fees),
    min_fee_rate: pool.min_fee_rate,
    avg_fee_rate: avg_rate,
  )
}

/// Get transactions sorted by fee rate for mining
pub fn mempool_get_for_block(
  pool: Mempool,
  max_weight: Int,
) -> List(MempoolEntry) {
  // Get all entries and sort by descendant score (ancestor-aware mining)
  let entries = dict.values(pool.txs)
  let sorted = list.sort(entries, fn(a, b) {
    // Higher score first
    float.compare(entry_descendant_score(b), entry_descendant_score(a))
  })

  // Take transactions up to weight limit
  select_for_block(sorted, max_weight, [])
}

fn select_for_block(
  candidates: List(MempoolEntry),
  remaining_weight: Int,
  acc: List(MempoolEntry),
) -> List(MempoolEntry) {
  case candidates {
    [] -> list.reverse(acc)
    [entry, ..rest] -> {
      let weight = entry.vsize * 4  // vsize to weight
      case weight <= remaining_weight {
        True ->
          select_for_block(rest, remaining_weight - weight, [entry, ..acc])
        False ->
          select_for_block(rest, remaining_weight, acc)
      }
    }
  }
}
