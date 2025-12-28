// pruning.gleam - Block pruning for disk-constrained nodes
//
// This module provides block pruning functionality to reduce disk usage
// by deleting old block data while preserving the UTXO set and block index.
//
// Pruning modes:
// - Manual: User specifies target size or blocks to keep
// - Automatic: Maintain a rolling window of blocks
//
// What is pruned:
// - Raw block data (transactions)
// - Undo data for pruned blocks
//
// What is kept:
// - Block headers and index (always needed for chain validation)
// - UTXO set (always needed for validation)
// - Recent blocks (configurable, default 288 = ~2 days)
//
// Important: Once pruned, a node cannot serve historical blocks to peers
// and some RPC methods will fail for pruned data.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import oni_bitcoin.{type BlockHash}
import oni_storage.{
  type BlockIndex, type BlockIndexEntry, type BlockStore, type Chainstate,
  type StorageError, type UndoStore,
}

// ============================================================================
// Types
// ============================================================================

/// Pruning configuration
pub type PruningConfig {
  PruningConfig(
    /// Whether pruning is enabled
    enabled: Bool,
    /// Target disk usage in bytes (0 = no target)
    target_size: Int,
    /// Minimum number of blocks to keep (default 288)
    min_blocks_to_keep: Int,
    /// Prune undo data as well
    prune_undo_data: Bool,
  )
}

/// Default pruning configuration (disabled)
pub fn default_config() -> PruningConfig {
  PruningConfig(
    enabled: False,
    target_size: 0,
    min_blocks_to_keep: 288,  // ~2 days of blocks
    prune_undo_data: True,
  )
}

/// Create config for pruned node with target size in MB
pub fn pruned_config(target_mb: Int) -> PruningConfig {
  PruningConfig(
    enabled: True,
    target_size: target_mb * 1024 * 1024,
    min_blocks_to_keep: 288,
    prune_undo_data: True,
  )
}

/// Pruning state tracking
pub type PruningState {
  PruningState(
    /// Lowest height with block data available
    pruned_height: Int,
    /// Total bytes pruned
    bytes_pruned: Int,
    /// Number of blocks pruned
    blocks_pruned: Int,
    /// Last prune timestamp
    last_prune_time: Int,
  )
}

/// Initial pruning state
pub fn initial_state() -> PruningState {
  PruningState(
    pruned_height: 0,
    bytes_pruned: 0,
    blocks_pruned: 0,
    last_prune_time: 0,
  )
}

/// Result of a pruning operation
pub type PruneResult {
  PruneResult(
    /// Number of blocks pruned
    blocks_pruned: Int,
    /// Bytes freed
    bytes_freed: Int,
    /// New lowest unpruned height
    new_pruned_height: Int,
  )
}

// ============================================================================
// Pruning Operations
// ============================================================================

/// Check if a block at given height can be pruned
pub fn can_prune_height(
  config: PruningConfig,
  chainstate: Chainstate,
  height: Int,
) -> Bool {
  case config.enabled {
    False -> False
    True -> {
      // Cannot prune if within minimum blocks window
      let min_keep_height = chainstate.best_height - config.min_blocks_to_keep
      height < min_keep_height
    }
  }
}

/// Calculate which blocks should be pruned
pub fn calculate_prune_range(
  config: PruningConfig,
  chainstate: Chainstate,
  current_pruned_height: Int,
) -> Option(#(Int, Int)) {
  case config.enabled {
    False -> None
    True -> {
      // Calculate the highest height we can prune to
      let max_prune_height = chainstate.best_height - config.min_blocks_to_keep

      case max_prune_height > current_pruned_height {
        False -> None  // Nothing to prune
        True -> Some(#(current_pruned_height + 1, max_prune_height))
      }
    }
  }
}

/// Prune blocks in a range (updates stores in place conceptually)
/// Returns updated stores and prune result
pub fn prune_block_range(
  block_store: BlockStore,
  undo_store: UndoStore,
  block_index: BlockIndex,
  config: PruningConfig,
  start_height: Int,
  end_height: Int,
) -> Result(#(BlockStore, UndoStore, PruneResult), StorageError) {
  prune_blocks_loop(
    block_store,
    undo_store,
    block_index,
    config,
    start_height,
    end_height,
    0,
    0,
  )
}

fn prune_blocks_loop(
  block_store: BlockStore,
  undo_store: UndoStore,
  block_index: BlockIndex,
  config: PruningConfig,
  current_height: Int,
  end_height: Int,
  blocks_pruned: Int,
  bytes_freed: Int,
) -> Result(#(BlockStore, UndoStore, PruneResult), StorageError) {
  case current_height > end_height {
    True -> {
      // Done pruning
      Ok(#(
        block_store,
        undo_store,
        PruneResult(
          blocks_pruned: blocks_pruned,
          bytes_freed: bytes_freed,
          new_pruned_height: end_height,
        ),
      ))
    }
    False -> {
      // Get block at this height
      case oni_storage.block_index_get_by_height(block_index, current_height) {
        None -> {
          // No block at this height, skip
          prune_blocks_loop(
            block_store,
            undo_store,
            block_index,
            config,
            current_height + 1,
            end_height,
            blocks_pruned,
            bytes_freed,
          )
        }
        Some(entry) -> {
          // Prune block data
          let #(new_block_store, block_size) = prune_single_block(block_store, entry.hash)

          // Prune undo data if configured
          let #(new_undo_store, undo_size) = case config.prune_undo_data {
            False -> #(undo_store, 0)
            True -> prune_undo_data(undo_store, entry.hash)
          }

          prune_blocks_loop(
            new_block_store,
            new_undo_store,
            block_index,
            config,
            current_height + 1,
            end_height,
            blocks_pruned + 1,
            bytes_freed + block_size + undo_size,
          )
        }
      }
    }
  }
}

/// Prune a single block from storage
fn prune_single_block(
  store: BlockStore,
  hash: BlockHash,
) -> #(BlockStore, Int) {
  // Estimate block size before removal (simplified - real impl would track sizes)
  let estimated_size = case oni_storage.block_store_has(store, hash) {
    False -> 0
    True -> 1_000_000  // ~1MB average block size estimate
  }

  let new_store = oni_storage.block_store_remove(store, hash)
  #(new_store, estimated_size)
}

/// Prune undo data for a block
fn prune_undo_data(
  store: UndoStore,
  hash: BlockHash,
) -> #(UndoStore, Int) {
  // Estimate undo data size (simplified)
  let estimated_size = 100_000  // ~100KB average undo data

  let new_store = oni_storage.undo_store_remove(store, hash)
  #(new_store, estimated_size)
}

// ============================================================================
// Pruning Queries
// ============================================================================

/// Check if a block is pruned
pub fn is_block_pruned(
  chainstate: Chainstate,
  height: Int,
) -> Bool {
  case chainstate.pruned_height {
    Some(pruned_h) -> height <= pruned_h
    None -> False
  }
}

/// Get the lowest unpruned block height
pub fn get_lowest_block_height(chainstate: Chainstate) -> Int {
  case chainstate.pruned_height {
    Some(h) -> h + 1
    None -> 0  // Genesis
  }
}

/// Calculate current disk usage estimate
pub fn estimate_disk_usage(
  chainstate: Chainstate,
  avg_block_size: Int,
) -> Int {
  let pruned_h = case chainstate.pruned_height {
    Some(h) -> h
    None -> 0
  }

  let unpruned_blocks = chainstate.best_height - pruned_h
  unpruned_blocks * avg_block_size
}

/// Check if pruning is needed based on disk usage
pub fn should_prune(
  config: PruningConfig,
  current_disk_usage: Int,
) -> Bool {
  case config.enabled, config.target_size > 0 {
    True, True -> current_disk_usage > config.target_size
    _, _ -> False
  }
}

// ============================================================================
// Automatic Pruning
// ============================================================================

/// Perform automatic pruning if needed
/// Returns the number of blocks pruned and bytes freed
pub fn auto_prune(
  block_store: BlockStore,
  undo_store: UndoStore,
  block_index: BlockIndex,
  chainstate: Chainstate,
  config: PruningConfig,
  prune_state: PruningState,
) -> Result(#(BlockStore, UndoStore, PruningState), StorageError) {
  case config.enabled {
    False -> Ok(#(block_store, undo_store, prune_state))
    True -> {
      // Check if we need to prune
      case calculate_prune_range(config, chainstate, prune_state.pruned_height) {
        None -> Ok(#(block_store, undo_store, prune_state))
        Some(#(start, end)) -> {
          // Perform pruning
          case prune_block_range(block_store, undo_store, block_index, config, start, end) {
            Error(e) -> Error(e)
            Ok(#(new_store, new_undo, result)) -> {
              let new_state = PruningState(
                ..prune_state,
                pruned_height: result.new_pruned_height,
                bytes_pruned: prune_state.bytes_pruned + result.bytes_freed,
                blocks_pruned: prune_state.blocks_pruned + result.blocks_pruned,
                last_prune_time: get_current_time(),
              )
              Ok(#(new_store, new_undo, new_state))
            }
          }
        }
      }
    }
  }
}

// ============================================================================
// Validation
// ============================================================================

/// Validate pruning configuration
pub fn validate_config(config: PruningConfig) -> Result(Nil, String) {
  case config.enabled {
    False -> Ok(Nil)
    True -> {
      // Minimum blocks must be at least 288 (2 days)
      case config.min_blocks_to_keep >= 288 {
        False -> Error("min_blocks_to_keep must be at least 288")
        True -> {
          // If target size is set, must be at least 550MB
          case config.target_size > 0 && config.target_size < 550_000_000 {
            True -> Error("target_size must be at least 550MB")
            False -> Ok(Nil)
          }
        }
      }
    }
  }
}

/// Check if node can serve block at height
pub fn can_serve_block(chainstate: Chainstate, height: Int) -> Bool {
  // Can serve if not pruned or height is above pruned level
  case chainstate.pruned_height {
    None -> True
    Some(pruned_h) -> height > pruned_h
  }
}

// ============================================================================
// Statistics
// ============================================================================

/// Pruning statistics for display
pub type PruningStats {
  PruningStats(
    /// Whether pruning is enabled
    enabled: Bool,
    /// Lowest available block height
    lowest_height: Int,
    /// Highest block height
    highest_height: Int,
    /// Number of blocks available
    blocks_available: Int,
    /// Estimated disk usage in bytes
    disk_usage: Int,
    /// Target disk usage (0 if not set)
    target_usage: Int,
    /// Total bytes pruned since start
    total_pruned: Int,
  )
}

/// Get pruning statistics
pub fn get_stats(
  config: PruningConfig,
  chainstate: Chainstate,
  prune_state: PruningState,
) -> PruningStats {
  let lowest = get_lowest_block_height(chainstate)
  let blocks_available = chainstate.best_height - lowest + 1

  PruningStats(
    enabled: config.enabled,
    lowest_height: lowest,
    highest_height: chainstate.best_height,
    blocks_available: blocks_available,
    disk_usage: estimate_disk_usage(chainstate, 1_000_000),
    target_usage: config.target_size,
    total_pruned: prune_state.bytes_pruned,
  )
}

// ============================================================================
// Helpers
// ============================================================================

/// Get current time in seconds (placeholder)
fn get_current_time() -> Int {
  // In real implementation: erlang.system_time(second)
  0
}

/// Format bytes for display
pub fn format_bytes(bytes: Int) -> String {
  case bytes {
    b if b < 1024 -> int.to_string(b) <> " B"
    b if b < 1024 * 1024 -> int.to_string(b / 1024) <> " KB"
    b if b < 1024 * 1024 * 1024 -> int.to_string(b / 1024 / 1024) <> " MB"
    b -> int.to_string(b / 1024 / 1024 / 1024) <> " GB"
  }
}
