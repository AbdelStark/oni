// reorg_handler.gleam - Chain Reorganization Handler
//
// This module handles blockchain reorganizations (reorgs):
// - Detecting when the best chain changes
// - Disconnecting blocks from old chain
// - Connecting blocks on new chain
// - Updating mempool after reorg
// - Emitting reorg notifications
//
// Reorg Safety:
// - Maximum reorg depth limit (to prevent DoS)
// - Atomic batch operations
// - Proper undo data management
// - Mempool transaction revalidation

import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import oni_bitcoin.{type Block, type BlockHash, type Network, type Transaction}
import oni_storage.{type BlockIndexEntry, type BlockUndo}
import oni_supervisor.{type MempoolMsg}
import persistent_chainstate.{
  type PersistentChainstateMsg, ConnectBlock, DisconnectBlock, GetBlock,
}

// ============================================================================
// Configuration
// ============================================================================

/// Reorg handler configuration
pub type ReorgConfig {
  ReorgConfig(
    /// Maximum allowed reorg depth
    max_reorg_depth: Int,
    /// Whether to re-add disconnected txs to mempool
    resubmit_txs: Bool,
    /// Debug logging
    debug: Bool,
  )
}

/// Default reorg configuration
pub fn default_config() -> ReorgConfig {
  ReorgConfig(max_reorg_depth: 100, resubmit_txs: True, debug: False)
}

// ============================================================================
// Types
// ============================================================================

/// Reorg event
pub type ReorgEvent {
  ReorgEvent(
    /// Common ancestor of old and new chains
    fork_point: BlockHash,
    /// Height of fork point
    fork_height: Int,
    /// Number of blocks disconnected
    blocks_disconnected: Int,
    /// Number of blocks connected
    blocks_connected: Int,
    /// Transactions that need mempool revalidation
    resubmit_txs: List(Transaction),
  )
}

/// Block on fork (for comparison)
pub type ForkBlock {
  ForkBlock(hash: BlockHash, height: Int, prev_hash: BlockHash, total_work: Int)
}

// ============================================================================
// Messages
// ============================================================================

/// Messages for the reorg handler actor
pub type ReorgMsg {
  /// Check if new block causes a reorg
  CheckReorg(new_tip: BlockHash, new_work: Int, reply: Subject(ReorgResult))
  /// Execute a reorg
  ExecuteReorg(
    old_tip: BlockHash,
    new_tip: BlockHash,
    reply: Subject(Result(ReorgEvent, String)),
  )
  /// Get reorg statistics
  GetStats(reply: Subject(ReorgStats))
  /// Shutdown
  Shutdown
}

/// Result of reorg check
pub type ReorgResult {
  NoReorgNeeded
  ReorgRequired(old_tip: BlockHash, new_tip: BlockHash, depth: Int)
  ReorgTooDeep(depth: Int)
}

/// Reorg statistics
pub type ReorgStats {
  ReorgStats(
    total_reorgs: Int,
    max_depth_seen: Int,
    blocks_disconnected: Int,
    blocks_connected: Int,
    txs_resubmitted: Int,
  )
}

// ============================================================================
// State
// ============================================================================

/// Reorg handler actor state
type ReorgState {
  ReorgState(
    config: ReorgConfig,
    chainstate: Subject(PersistentChainstateMsg),
    mempool: Subject(MempoolMsg),
    /// Current tip hash
    current_tip: Option(BlockHash),
    /// Current tip height
    current_height: Int,
    /// Statistics
    stats: ReorgStats,
    /// Block index cache (hash -> entry)
    block_index: Dict(String, ForkBlock),
  )
}

// ============================================================================
// Public API
// ============================================================================

/// Start the reorg handler
pub fn start(
  config: ReorgConfig,
  chainstate: Subject(PersistentChainstateMsg),
  mempool: Subject(MempoolMsg),
) -> Result(Subject(ReorgMsg), actor.StartError) {
  let initial_state =
    ReorgState(
      config: config,
      chainstate: chainstate,
      mempool: mempool,
      current_tip: None,
      current_height: 0,
      stats: ReorgStats(
        total_reorgs: 0,
        max_depth_seen: 0,
        blocks_disconnected: 0,
        blocks_connected: 0,
        txs_resubmitted: 0,
      ),
      block_index: dict.new(),
    )

  actor.start(initial_state, handle_message)
}

/// Perform a reorganization between two chains
/// Returns the blocks to disconnect and blocks to connect
pub fn plan_reorg(
  old_tip: ForkBlock,
  new_tip: ForkBlock,
  block_index: Dict(String, ForkBlock),
) -> Result(#(List(ForkBlock), List(ForkBlock)), String) {
  // Find common ancestor
  case find_common_ancestor(old_tip, new_tip, block_index) {
    Error(err) -> Error(err)
    Ok(#(ancestor, disconnect_path, connect_path)) -> {
      let _ = ancestor
      // Used for verification
      Ok(#(disconnect_path, connect_path))
    }
  }
}

// ============================================================================
// Message Handler
// ============================================================================

fn handle_message(
  msg: ReorgMsg,
  state: ReorgState,
) -> actor.Next(ReorgMsg, ReorgState) {
  case msg {
    CheckReorg(new_tip, new_work, reply) -> {
      let result = check_reorg(new_tip, new_work, state)
      process.send(reply, result)
      actor.continue(state)
    }

    ExecuteReorg(old_tip, new_tip, reply) -> {
      case execute_reorg(old_tip, new_tip, state) {
        Error(err) -> {
          process.send(reply, Error(err))
          actor.continue(state)
        }
        Ok(#(event, new_state)) -> {
          process.send(reply, Ok(event))
          actor.continue(new_state)
        }
      }
    }

    GetStats(reply) -> {
      process.send(reply, state.stats)
      actor.continue(state)
    }

    Shutdown -> {
      io.println("[Reorg] Shutting down...")
      actor.Stop(process.Normal)
    }
  }
}

// ============================================================================
// Reorg Logic
// ============================================================================

/// Check if a reorg is needed by comparing chain work
fn check_reorg(
  new_tip: BlockHash,
  new_work: Int,
  state: ReorgState,
) -> ReorgResult {
  case state.current_tip {
    // No current tip - we're at genesis, no reorg possible
    None -> NoReorgNeeded

    Some(current_tip) -> {
      // Get current tip's info from block index
      let current_hex = oni_bitcoin.block_hash_to_hex(current_tip)
      let new_hex = oni_bitcoin.block_hash_to_hex(new_tip)

      // Same block = no reorg needed
      case current_hex == new_hex {
        True -> NoReorgNeeded
        False -> {
          case dict.get(state.block_index, current_hex) {
            Error(_) -> {
              // Current tip not in index - shouldn't happen
              NoReorgNeeded
            }
            Ok(current_block) -> {
              // Compare total work: new chain must have MORE work to trigger reorg
              case new_work > current_block.total_work {
                False -> {
                  // New chain doesn't have more work - no reorg
                  NoReorgNeeded
                }
                True -> {
                  // New chain has more work - calculate reorg depth
                  case dict.get(state.block_index, new_hex) {
                    Error(_) -> NoReorgNeeded
                    Ok(new_block) -> {
                      // Find common ancestor to determine depth
                      case
                        find_common_ancestor(
                          current_block,
                          new_block,
                          state.block_index,
                        )
                      {
                        Error(_) -> NoReorgNeeded
                        Ok(#(ancestor, disconnect_path, _connect_path)) -> {
                          let depth = list.length(disconnect_path)

                          // Check if reorg depth exceeds limit
                          case depth > state.config.max_reorg_depth {
                            True -> ReorgTooDeep(depth)
                            False -> {
                              let _ = ancestor
                              ReorgRequired(
                                old_tip: current_tip,
                                new_tip: new_tip,
                                depth: depth,
                              )
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
    }
  }
}

/// Execute a chain reorganization
fn execute_reorg(
  old_tip: BlockHash,
  new_tip: BlockHash,
  state: ReorgState,
) -> Result(#(ReorgEvent, ReorgState), String) {
  case state.config.debug {
    True ->
      io.println(
        "[Reorg] Executing reorg from "
        <> oni_bitcoin.block_hash_to_hex(old_tip)
        <> " to "
        <> oni_bitcoin.block_hash_to_hex(new_tip),
      )
    False -> Nil
  }

  // Get fork blocks from index
  let old_tip_hex = oni_bitcoin.block_hash_to_hex(old_tip)
  let new_tip_hex = oni_bitcoin.block_hash_to_hex(new_tip)

  case
    dict.get(state.block_index, old_tip_hex),
    dict.get(state.block_index, new_tip_hex)
  {
    Error(_), _ -> Error("Old tip not found in block index")
    _, Error(_) -> Error("New tip not found in block index")
    Ok(old_block), Ok(new_block) -> {
      case plan_reorg(old_block, new_block, state.block_index) {
        Error(err) -> Error(err)
        Ok(#(to_disconnect, to_connect)) -> {
          // Check depth limit
          let depth = list.length(to_disconnect)
          case depth > state.config.max_reorg_depth {
            True -> Error("Reorg too deep: " <> int.to_string(depth))
            False -> {
              // Execute the reorg
              case do_reorg(to_disconnect, to_connect, state) {
                Error(err) -> Error(err)
                Ok(#(event, new_state)) -> Ok(#(event, new_state))
              }
            }
          }
        }
      }
    }
  }
}

/// Actually perform the reorganization
fn do_reorg(
  to_disconnect: List(ForkBlock),
  to_connect: List(ForkBlock),
  state: ReorgState,
) -> Result(#(ReorgEvent, ReorgState), String) {
  // 1. Disconnect blocks from old chain (in reverse order)
  let disconnect_result = disconnect_blocks(to_disconnect, state)

  case disconnect_result {
    Error(err) -> Error("Failed to disconnect blocks: " <> err)
    Ok(#(disconnected_txs, state1)) -> {
      // 2. Connect blocks on new chain
      let connect_result = connect_blocks(to_connect, state1)

      case connect_result {
        Error(err) -> Error("Failed to connect blocks: " <> err)
        Ok(#(confirmed_txids, state2)) -> {
          // 3. Resubmit disconnected transactions (minus those confirmed in new chain)
          let txs_to_resubmit =
            filter_confirmed(disconnected_txs, confirmed_txids)

          case state.config.resubmit_txs {
            True -> resubmit_transactions(txs_to_resubmit, state2.mempool)
            False -> Nil
          }

          // 4. Build event and update stats
          let fork_point = case list.last(to_disconnect) {
            Ok(block) -> block.prev_hash
            Error(_) -> old_tip_fallback()
          }

          let event =
            ReorgEvent(
              fork_point: fork_point,
              fork_height: case list.last(to_disconnect) {
                Ok(block) -> block.height - 1
                Error(_) -> 0
              },
              blocks_disconnected: list.length(to_disconnect),
              blocks_connected: list.length(to_connect),
              resubmit_txs: txs_to_resubmit,
            )

          let new_stats =
            ReorgStats(
              ..state2.stats,
              total_reorgs: state2.stats.total_reorgs + 1,
              max_depth_seen: int.max(
                state2.stats.max_depth_seen,
                list.length(to_disconnect),
              ),
              blocks_disconnected: state2.stats.blocks_disconnected
                + list.length(to_disconnect),
              blocks_connected: state2.stats.blocks_connected
                + list.length(to_connect),
              txs_resubmitted: state2.stats.txs_resubmitted
                + list.length(txs_to_resubmit),
            )

          // Update current tip
          let new_tip = case list.first(to_connect) {
            Ok(block) -> Some(block.hash)
            Error(_) -> state.current_tip
          }

          let new_height = case list.first(to_connect) {
            Ok(block) -> block.height
            Error(_) -> state.current_height
          }

          io.println(
            "[Reorg] Completed: disconnected "
            <> int.to_string(list.length(to_disconnect))
            <> ", connected "
            <> int.to_string(list.length(to_connect)),
          )

          Ok(#(
            event,
            ReorgState(
              ..state2,
              stats: new_stats,
              current_tip: new_tip,
              current_height: new_height,
            ),
          ))
        }
      }
    }
  }
}

/// Disconnect blocks and collect transactions
fn disconnect_blocks(
  blocks: List(ForkBlock),
  state: ReorgState,
) -> Result(#(List(Transaction), ReorgState), String) {
  disconnect_blocks_loop(list.reverse(blocks), [], state)
}

fn disconnect_blocks_loop(
  remaining: List(ForkBlock),
  collected_txs: List(Transaction),
  state: ReorgState,
) -> Result(#(List(Transaction), ReorgState), String) {
  case remaining {
    [] -> Ok(#(collected_txs, state))
    [block, ..rest] -> {
      case state.config.debug {
        True ->
          io.println(
            "[Reorg] Disconnecting block at height "
            <> int.to_string(block.height),
          )
        False -> Nil
      }

      // First, get the full block to collect its transactions
      let block_txs = case
        process.call(state.chainstate, GetBlock(block.hash, _), 30_000)
      {
        Some(full_block) ->
          // Skip coinbase (first tx), collect the rest
          case full_block.transactions {
            [_, ..rest_txs] -> rest_txs
            [] -> []
          }
        None -> []
      }

      // Disconnect the block via chainstate
      case process.call(state.chainstate, DisconnectBlock, 60_000) {
        Ok(_) -> {
          // Block disconnected successfully, continue with next
          let new_collected = list.append(collected_txs, block_txs)
          disconnect_blocks_loop(rest, new_collected, state)
        }
        Error(err) -> Error("Failed to disconnect block: " <> err)
      }
    }
  }
}

/// Connect blocks on new chain
fn connect_blocks(
  blocks: List(ForkBlock),
  state: ReorgState,
) -> Result(#(List(oni_bitcoin.Txid), ReorgState), String) {
  connect_blocks_loop(blocks, [], state)
}

fn connect_blocks_loop(
  remaining: List(ForkBlock),
  confirmed_txids: List(oni_bitcoin.Txid),
  state: ReorgState,
) -> Result(#(List(oni_bitcoin.Txid), ReorgState), String) {
  case remaining {
    [] -> Ok(#(confirmed_txids, state))
    [block, ..rest] -> {
      case state.config.debug {
        True ->
          io.println(
            "[Reorg] Connecting block at height " <> int.to_string(block.height),
          )
        False -> Nil
      }

      // Fetch the full block from storage
      case process.call(state.chainstate, GetBlock(block.hash, _), 30_000) {
        None ->
          Error(
            "Block not found in storage: "
            <> oni_bitcoin.block_hash_to_hex(block.hash),
          )
        Some(full_block) -> {
          // Connect the block via chainstate
          case
            process.call(state.chainstate, ConnectBlock(full_block, _), 60_000)
          {
            Error(err) -> Error("Failed to connect block: " <> err)
            Ok(_) -> {
              // Collect all txids from this block (for filtering resubmissions)
              let block_txids =
                list.map(full_block.transactions, oni_bitcoin.txid_from_tx)
              let new_confirmed = list.append(confirmed_txids, block_txids)
              connect_blocks_loop(rest, new_confirmed, state)
            }
          }
        }
      }
    }
  }
}

/// Filter out transactions that were confirmed in the new chain
fn filter_confirmed(
  txs: List(Transaction),
  confirmed: List(oni_bitcoin.Txid),
) -> List(Transaction) {
  let confirmed_set =
    list.fold(confirmed, dict.new(), fn(acc, txid) {
      dict.insert(acc, oni_bitcoin.txid_to_hex(txid), True)
    })

  list.filter(txs, fn(tx) {
    let txid = oni_bitcoin.txid_from_tx(tx)
    let txid_hex = oni_bitcoin.txid_to_hex(txid)
    case dict.get(confirmed_set, txid_hex) {
      Ok(_) -> False
      Error(_) -> True
    }
  })
}

/// Resubmit transactions to mempool
fn resubmit_transactions(
  txs: List(Transaction),
  mempool: Subject(MempoolMsg),
) -> Nil {
  list.each(txs, fn(tx) {
    // Create a new subject for the response (we don't wait for it)
    let reply = process.new_subject()
    process.send(mempool, oni_supervisor.AddTx(tx, reply))
  })
}

// ============================================================================
// Chain Navigation
// ============================================================================

/// Find common ancestor of two forks
fn find_common_ancestor(
  tip_a: ForkBlock,
  tip_b: ForkBlock,
  block_index: Dict(String, ForkBlock),
) -> Result(#(ForkBlock, List(ForkBlock), List(ForkBlock)), String) {
  // Walk back both chains until they meet
  find_ancestor_loop(tip_a, tip_b, [], [], block_index)
}

fn find_ancestor_loop(
  a: ForkBlock,
  b: ForkBlock,
  path_a: List(ForkBlock),
  path_b: List(ForkBlock),
  block_index: Dict(String, ForkBlock),
) -> Result(#(ForkBlock, List(ForkBlock), List(ForkBlock)), String) {
  // Check if we've found the common ancestor
  let a_hex = oni_bitcoin.block_hash_to_hex(a.hash)
  let b_hex = oni_bitcoin.block_hash_to_hex(b.hash)

  case a_hex == b_hex {
    True -> Ok(#(a, path_a, path_b))
    False -> {
      // Walk back the higher chain
      case a.height >= b.height {
        True -> {
          let prev_hex = oni_bitcoin.block_hash_to_hex(a.prev_hash)
          case dict.get(block_index, prev_hex) {
            Error(_) -> Error("Block not found in index: " <> prev_hex)
            Ok(prev_a) ->
              find_ancestor_loop(prev_a, b, [a, ..path_a], path_b, block_index)
          }
        }
        False -> {
          let prev_hex = oni_bitcoin.block_hash_to_hex(b.prev_hash)
          case dict.get(block_index, prev_hex) {
            Error(_) -> Error("Block not found in index: " <> prev_hex)
            Ok(prev_b) ->
              find_ancestor_loop(a, prev_b, path_a, [b, ..path_b], block_index)
          }
        }
      }
    }
  }
}

/// Fallback for old tip (shouldn't happen in normal operation)
fn old_tip_fallback() -> BlockHash {
  oni_bitcoin.BlockHash(hash: oni_bitcoin.Hash256(bytes: <<0:256>>))
}
