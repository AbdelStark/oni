// mempool_manager.gleam - Enhanced mempool with chainstate integration
//
// This module provides a mempool manager that integrates with the chainstate
// for contextual transaction validation. It wraps the basic mempool actor
// and adds:
//
// - UTXO existence checking against chainstate
// - Double-spend detection (chainstate + mempool)
// - Fee calculation from actual input values
// - Mempool UTXO overlay for child transactions
// - Policy enforcement via mempool_policy
//
// The manager acts as a coordinator between:
// - Chainstate actor (for UTXO lookups)
// - Basic mempool actor (for tx storage)
// - Policy/validation modules (for checks)

import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import oni_bitcoin.{type Amount, type OutPoint, type Transaction, type Txid, Amount}
import oni_supervisor.{
  type ChainstateMsg, type MempoolMsg, AddTx, ClearConfirmed, GetSize,
  GetUtxo, MempoolShutdown,
}
import mempool_validation.{
  type UtxoLookupResult, type UtxoView, type ValidationResult,
  UtxoAvailable, UtxoInMempool, UtxoNotFound, UtxoSpent,
}
import mempool_policy

// ============================================================================
// Manager Types
// ============================================================================

/// Messages for the mempool manager actor
pub type ManagerMsg {
  /// Submit a transaction for validation and inclusion
  SubmitTx(
    tx: Transaction,
    reply: Subject(Result(SubmitResult, SubmitError)),
  )
  /// Get transaction by txid
  GetTx(txid: Txid, reply: Subject(Option(Transaction)))
  /// Get mempool info
  GetInfo(reply: Subject(MempoolInfo))
  /// Get fee estimates
  GetFeeEstimate(blocks: Int, reply: Subject(FeeEstimate))
  /// Test if a transaction would be accepted
  TestAccept(tx: Transaction, reply: Subject(TestAcceptResult))
  /// Evict low-fee transactions to make room
  EvictLowFee(target_size: Int)
  /// Handle new block (remove confirmed, update UTXO view)
  OnBlockConnected(txids: List(Txid))
  /// Handle reorg (restore previously removed txs)
  OnBlockDisconnected(txids: List(Txid))
  /// Shutdown the manager
  Shutdown
}

/// Successful transaction submission result
pub type SubmitResult {
  SubmitResult(
    txid: Txid,
    fee: Int,
    vsize: Int,
    fee_rate: Float,
  )
}

/// Transaction submission error
pub type SubmitError {
  /// Policy rejection
  PolicyRejected(reason: String)
  /// Validation failure
  ValidationFailed(reason: String)
  /// Mempool full
  MempoolFull
  /// Already in mempool
  AlreadyInMempool
  /// Conflicts with existing tx
  ConflictingTx(txid: String)
}

/// Mempool information
pub type MempoolInfo {
  MempoolInfo(
    size: Int,
    bytes: Int,
    usage: Int,
    max_size: Int,
    min_fee_rate: Float,
  )
}

/// Fee estimation result
pub type FeeEstimate {
  FeeEstimate(
    fee_rate: Float,
    blocks: Int,
  )
}

/// Test acceptance result
pub type TestAcceptResult {
  TestAcceptResult(
    allowed: Bool,
    fee: Int,
    vsize: Int,
    reject_reason: Option(String),
  )
}

// ============================================================================
// Manager State
// ============================================================================

/// Manager actor state
pub type ManagerState {
  ManagerState(
    /// Handle to chainstate actor
    chainstate: Subject(ChainstateMsg),
    /// Handle to basic mempool actor
    mempool: Subject(MempoolMsg),
    /// Cached mempool UTXOs (outputs created by mempool txs)
    mempool_utxos: Dict(String, MempoolUtxo),
    /// Spent outputs in mempool (prevents double-spend)
    spent_outputs: Dict(String, Txid),
    /// Transaction metadata (fees, sizes, etc.)
    tx_metadata: Dict(String, TxMetadata),
    /// Current chain height
    chain_height: Int,
    /// Fee rate histogram for estimation
    fee_histogram: List(#(Float, Int)),
  )
}

/// UTXO created by a mempool transaction
pub type MempoolUtxo {
  MempoolUtxo(
    value: Amount,
    script_pubkey: oni_bitcoin.Script,
    creating_txid: Txid,
  )
}

/// Metadata about a mempool transaction
pub type TxMetadata {
  TxMetadata(
    fee: Int,
    vsize: Int,
    fee_rate: Float,
    ancestor_count: Int,
    time_added: Int,
  )
}

// ============================================================================
// Manager Lifecycle
// ============================================================================

/// Start the mempool manager actor
pub fn start(
  chainstate: Subject(ChainstateMsg),
  mempool: Subject(MempoolMsg),
  chain_height: Int,
) -> Result(Subject(ManagerMsg), actor.StartError) {
  let initial_state = ManagerState(
    chainstate: chainstate,
    mempool: mempool,
    mempool_utxos: dict.new(),
    spent_outputs: dict.new(),
    tx_metadata: dict.new(),
    chain_height: chain_height,
    fee_histogram: [],
  )

  actor.start(initial_state, handle_manager_msg)
}

// ============================================================================
// Message Handler
// ============================================================================

fn handle_manager_msg(
  msg: ManagerMsg,
  state: ManagerState,
) -> actor.Next(ManagerMsg, ManagerState) {
  case msg {
    SubmitTx(tx, reply) -> {
      // Step 1: Check policy (stateless)
      let policy_result = mempool_policy.check_transaction(tx, mempool_policy.default_policy_config())
      case policy_result {
        Error(policy_error) -> {
          let reason = mempool_policy.error_to_string(policy_error)
          process.send(reply, Error(PolicyRejected(reason)))
          actor.continue(state)
        }
        Ok(_) -> {
          // Step 2: Create UTXO view combining chainstate and mempool
          let utxo_view = create_utxo_view(state)

          // Step 3: Validate contextually
          let validation_result = mempool_validation.validate_transaction(tx, utxo_view)
          case validation_result {
            Error(validation_error) -> {
              let reason = mempool_validation.error_to_string(validation_error)
              process.send(reply, Error(ValidationFailed(reason)))
              actor.continue(state)
            }
            Ok(result) -> {
              // Step 4: Check for conflicts (double-spends against mempool)
              case check_mempool_conflicts(tx, state) {
                Some(conflicting_txid) -> {
                  process.send(reply, Error(ConflictingTx(conflicting_txid)))
                  actor.continue(state)
                }
                None -> {
                  // Step 5: Add to underlying mempool
                  let add_result = process.call(state.mempool, AddTx(tx, _), 5000)
                  case add_result {
                    Error("Transaction already in mempool") -> {
                      process.send(reply, Error(AlreadyInMempool))
                      actor.continue(state)
                    }
                    Error("Mempool full") -> {
                      process.send(reply, Error(MempoolFull))
                      actor.continue(state)
                    }
                    Error(reason) -> {
                      process.send(reply, Error(ValidationFailed(reason)))
                      actor.continue(state)
                    }
                    Ok(_) -> {
                      // Step 6: Update manager state
                      let txid = oni_bitcoin.txid_from_tx(tx)
                      let new_state = update_state_after_add(state, tx, txid, result)

                      let submit_result = SubmitResult(
                        txid: txid,
                        fee: result.fee,
                        vsize: result.vsize,
                        fee_rate: result.fee_rate,
                      )
                      process.send(reply, Ok(submit_result))
                      actor.continue(new_state)
                    }
                  }
                }
              }
            }
          }
        }
      }
    }

    GetTx(txid, reply) -> {
      let txid_hex = oni_bitcoin.txid_to_hex(txid)
      // Check if we have metadata (means it's in mempool)
      case dict.get(state.tx_metadata, txid_hex) {
        Error(_) -> {
          process.send(reply, None)
          actor.continue(state)
        }
        Ok(_) -> {
          // For now, we'd need to get from underlying mempool
          // This is a limitation - we should store txs in manager too
          process.send(reply, None)
          actor.continue(state)
        }
      }
    }

    GetInfo(reply) -> {
      let size = process.call(state.mempool, GetSize, 5000)
      let min_fee = calculate_min_fee_rate(state)

      let info = MempoolInfo(
        size: size,
        bytes: calculate_mempool_bytes(state),
        usage: size,
        max_size: 300_000_000,  // From config
        min_fee_rate: min_fee,
      )
      process.send(reply, info)
      actor.continue(state)
    }

    GetFeeEstimate(blocks, reply) -> {
      let fee_rate = estimate_fee_rate(state, blocks)
      process.send(reply, FeeEstimate(fee_rate: fee_rate, blocks: blocks))
      actor.continue(state)
    }

    TestAccept(tx, reply) -> {
      // Run validation without adding to mempool
      let policy_result = mempool_policy.check_transaction(tx, mempool_policy.default_policy_config())
      case policy_result {
        Error(policy_error) -> {
          let reason = mempool_policy.error_to_string(policy_error)
          process.send(reply, TestAcceptResult(
            allowed: False,
            fee: 0,
            vsize: 0,
            reject_reason: Some(reason),
          ))
        }
        Ok(_) -> {
          let utxo_view = create_utxo_view(state)
          case mempool_validation.validate_transaction(tx, utxo_view) {
            Error(validation_error) -> {
              let reason = mempool_validation.error_to_string(validation_error)
              process.send(reply, TestAcceptResult(
                allowed: False,
                fee: 0,
                vsize: 0,
                reject_reason: Some(reason),
              ))
            }
            Ok(result) -> {
              process.send(reply, TestAcceptResult(
                allowed: True,
                fee: result.fee,
                vsize: result.vsize,
                reject_reason: None,
              ))
            }
          }
        }
      }
      actor.continue(state)
    }

    EvictLowFee(target_size) -> {
      // Would evict lowest fee-rate txs
      // For now, just acknowledge
      let _ = target_size
      actor.continue(state)
    }

    OnBlockConnected(txids) -> {
      // Remove confirmed transactions and their metadata
      process.send(state.mempool, ClearConfirmed(txids))
      let new_state = remove_confirmed_txs(state, txids)
      let updated_state = ManagerState(
        ..new_state,
        chain_height: state.chain_height + 1,
      )
      actor.continue(updated_state)
    }

    OnBlockDisconnected(_txids) -> {
      // Would restore previously confirmed txs
      let updated_state = ManagerState(
        ..state,
        chain_height: state.chain_height - 1,
      )
      actor.continue(updated_state)
    }

    Shutdown -> {
      process.send(state.mempool, MempoolShutdown)
      actor.Stop(process.Normal)
    }
  }
}

// ============================================================================
// UTXO View Creation
// ============================================================================

/// Create a UTXO view combining chainstate and mempool
fn create_utxo_view(state: ManagerState) -> UtxoView {
  mempool_validation.UtxoView(
    lookup: fn(outpoint) { lookup_utxo(state, outpoint) },
    chain_height: state.chain_height,
    median_time_past: 0,  // Would need to calculate
  )
}

/// Look up a UTXO from chainstate or mempool
fn lookup_utxo(state: ManagerState, outpoint: OutPoint) -> UtxoLookupResult {
  let outpoint_key = outpoint_to_key(outpoint)

  // First check if spent in mempool
  case dict.get(state.spent_outputs, outpoint_key) {
    Ok(_) -> UtxoSpent
    Error(_) -> {
      // Check mempool UTXOs (unconfirmed parents)
      case dict.get(state.mempool_utxos, outpoint_key) {
        Ok(mempool_utxo) -> {
          let info = mempool_validation.UtxoInfo(
            value: mempool_utxo.value,
            script_pubkey: mempool_utxo.script_pubkey,
            height: state.chain_height + 1,  // Unconfirmed
            is_coinbase: False,
          )
          UtxoInMempool(info)
        }
        Error(_) -> {
          // Check chainstate
          let chainstate_result = process.call(
            state.chainstate,
            GetUtxo(outpoint, _),
            5000,
          )
          case chainstate_result {
            None -> UtxoNotFound
            Some(coin_info) -> {
              let info = mempool_validation.UtxoInfo(
                value: coin_info.value,
                script_pubkey: coin_info.script_pubkey,
                height: coin_info.height,
                is_coinbase: coin_info.is_coinbase,
              )
              UtxoAvailable(info)
            }
          }
        }
      }
    }
  }
}

// ============================================================================
// State Updates
// ============================================================================

/// Update state after successfully adding a transaction
fn update_state_after_add(
  state: ManagerState,
  tx: Transaction,
  txid: Txid,
  result: ValidationResult,
) -> ManagerState {
  let txid_hex = oni_bitcoin.txid_to_hex(txid)

  // Add metadata
  let metadata = TxMetadata(
    fee: result.fee,
    vsize: result.vsize,
    fee_rate: result.fee_rate,
    ancestor_count: result.ancestor_count,
    time_added: 0,  // Would use actual timestamp
  )
  let new_metadata = dict.insert(state.tx_metadata, txid_hex, metadata)

  // Mark inputs as spent
  let new_spent = list.fold(tx.inputs, state.spent_outputs, fn(acc, input) {
    let key = outpoint_to_key(input.prevout)
    dict.insert(acc, key, txid)
  })

  // Add outputs to mempool UTXOs
  let new_utxos = add_tx_outputs_to_mempool(state.mempool_utxos, tx, txid)

  // Update fee histogram
  let new_histogram = update_fee_histogram(state.fee_histogram, result.fee_rate, result.vsize)

  ManagerState(
    ..state,
    mempool_utxos: new_utxos,
    spent_outputs: new_spent,
    tx_metadata: new_metadata,
    fee_histogram: new_histogram,
  )
}

/// Add transaction outputs to mempool UTXO set
fn add_tx_outputs_to_mempool(
  utxos: Dict(String, MempoolUtxo),
  tx: Transaction,
  txid: Txid,
) -> Dict(String, MempoolUtxo) {
  add_outputs_loop(utxos, tx.outputs, txid, 0)
}

fn add_outputs_loop(
  utxos: Dict(String, MempoolUtxo),
  outputs: List(oni_bitcoin.TxOut),
  txid: Txid,
  index: Int,
) -> Dict(String, MempoolUtxo) {
  case outputs {
    [] -> utxos
    [output, ..rest] -> {
      let outpoint = oni_bitcoin.OutPoint(txid: txid, vout: index)
      let key = outpoint_to_key(outpoint)
      let mempool_utxo = MempoolUtxo(
        value: output.value,
        script_pubkey: output.script_pubkey,
        creating_txid: txid,
      )
      let new_utxos = dict.insert(utxos, key, mempool_utxo)
      add_outputs_loop(new_utxos, rest, txid, index + 1)
    }
  }
}

/// Remove confirmed transactions from tracking
fn remove_confirmed_txs(
  state: ManagerState,
  txids: List(Txid),
) -> ManagerState {
  list.fold(txids, state, fn(s, txid) {
    let txid_hex = oni_bitcoin.txid_to_hex(txid)

    // Remove metadata
    let new_metadata = dict.delete(s.tx_metadata, txid_hex)

    // Remove from mempool UTXOs (outputs are now in chainstate)
    // This is simplified - would need to track which UTXOs belong to which tx
    let new_utxos = dict.filter(s.mempool_utxos, fn(_key, utxo) {
      utxo.creating_txid != txid
    })

    // Remove from spent outputs
    let new_spent = dict.filter(s.spent_outputs, fn(_key, spending_txid) {
      spending_txid != txid
    })

    ManagerState(
      ..s,
      mempool_utxos: new_utxos,
      spent_outputs: new_spent,
      tx_metadata: new_metadata,
    )
  })
}

// ============================================================================
// Conflict Detection
// ============================================================================

/// Check if transaction conflicts with any mempool transaction
fn check_mempool_conflicts(
  tx: Transaction,
  state: ManagerState,
) -> Option(String) {
  check_conflicts_loop(tx.inputs, state)
}

fn check_conflicts_loop(
  inputs: List(oni_bitcoin.TxIn),
  state: ManagerState,
) -> Option(String) {
  case inputs {
    [] -> None
    [input, ..rest] -> {
      let key = outpoint_to_key(input.prevout)
      case dict.get(state.spent_outputs, key) {
        Ok(spending_txid) -> Some(oni_bitcoin.txid_to_hex(spending_txid))
        Error(_) -> check_conflicts_loop(rest, state)
      }
    }
  }
}

// ============================================================================
// Fee Estimation
// ============================================================================

/// Update fee histogram with new transaction
fn update_fee_histogram(
  histogram: List(#(Float, Int)),
  fee_rate: Float,
  vsize: Int,
) -> List(#(Float, Int)) {
  // Simple approach: add to front, keep sorted
  // In production, would use buckets
  let entry = #(fee_rate, vsize)
  list.sort([entry, ..histogram], fn(a, b) {
    case a.0 >. b.0 {
      True -> order.Lt
      False -> order.Gt
    }
  })
  |> list.take(1000)  // Keep limited history
}

/// Estimate fee rate for target confirmation blocks
fn estimate_fee_rate(state: ManagerState, _target_blocks: Int) -> Float {
  // Simple approach: use median of recent fees
  case state.fee_histogram {
    [] -> 1.0  // Minimum fee
    histogram -> {
      let total_size = list.fold(histogram, 0, fn(acc, entry) {
        acc + entry.1
      })
      let target = total_size / 2
      find_median_fee_rate(histogram, 0, target)
    }
  }
}

fn find_median_fee_rate(
  histogram: List(#(Float, Int)),
  accumulated: Int,
  target: Int,
) -> Float {
  case histogram {
    [] -> 1.0
    [#(rate, size), ..rest] -> {
      let new_acc = accumulated + size
      case new_acc >= target {
        True -> rate
        False -> find_median_fee_rate(rest, new_acc, target)
      }
    }
  }
}

/// Calculate total mempool bytes
fn calculate_mempool_bytes(state: ManagerState) -> Int {
  dict.fold(state.tx_metadata, 0, fn(acc, _key, meta) {
    acc + meta.vsize
  })
}

/// Calculate minimum fee rate to get into mempool
fn calculate_min_fee_rate(state: ManagerState) -> Float {
  // If mempool is not full, return minimum relay fee
  let size = dict.size(state.tx_metadata)
  case size < 300_000 {  // threshold
    True -> 1.0
    False -> {
      // Return lowest fee rate in mempool
      let rates = dict.fold(state.tx_metadata, [], fn(acc, _key, meta) {
        [meta.fee_rate, ..acc]
      })
      case list.reduce(rates, fn(a, b) { case a <. b { True -> a False -> b } }) {
        Ok(min) -> min
        Error(_) -> 1.0
      }
    }
  }
}

// ============================================================================
// Helper Functions
// ============================================================================

/// Convert outpoint to string key
fn outpoint_to_key(outpoint: OutPoint) -> String {
  oni_bitcoin.txid_to_hex(outpoint.txid) <> ":" <> int.to_string(outpoint.vout)
}

// Import for list.sort
import gleam/order
