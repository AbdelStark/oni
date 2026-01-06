// unified_storage.gleam - Unified storage interface bridging memory and persistence
//
// This module provides a unified storage interface that:
// - Uses in-memory cache for fast access
// - Syncs to persistent storage on mutations
// - Loads from persistent storage on startup
//
// Architecture:
// ┌─────────────────────────────────┐
// │     Application (oni_node)     │
// ├─────────────────────────────────┤
// │    unified_storage (this)       │
// │    ├── In-memory cache          │
// │    └── Write-through to disk    │
// ├─────────────────────────────────┤
// │    persistent_storage.gleam     │
// ├─────────────────────────────────┤
// │    db_backend.gleam (DETS)      │
// └─────────────────────────────────┘

import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import oni_bitcoin.{type Block, type BlockHash, type OutPoint, type Transaction}
import oni_storage.{
  type BlockIndexEntry, type BlockUndo, type Chainstate, type Coin,
  type StorageError, type UtxoView,
}
import persistent_storage.{type PersistentStorageHandle}

// ============================================================================
// Types
// ============================================================================

/// Unified storage handle with both cache and persistent storage
pub type UnifiedStorage {
  UnifiedStorage(
    /// Persistent storage handle (None for memory-only mode)
    persistent: Option(PersistentStorageHandle),
    /// UTXO cache (in-memory)
    utxo_cache: UtxoView,
    /// Block index cache
    block_index_cache: Dict(String, BlockIndexEntry),
    /// Chainstate
    chainstate: Chainstate,
    /// Data directory (empty for memory-only)
    data_dir: String,
    /// Whether we're in memory-only mode
    memory_only: Bool,
  )
}

// ============================================================================
// Initialization
// ============================================================================

/// Open unified storage with persistent backing
pub fn open(data_dir: String) -> Result(UnifiedStorage, StorageError) {
  // Try to open persistent storage
  case persistent_storage.persistent_storage_open(data_dir) {
    Ok(handle) -> {
      // Load chainstate from disk (or use genesis if not found)
      let chainstate = case persistent_storage.chainstate_get(handle) {
        Ok(cs) -> cs
        Error(_) -> genesis_chainstate()
      }

      Ok(UnifiedStorage(
        persistent: Some(handle),
        utxo_cache: oni_storage.utxo_view_new(),
        block_index_cache: dict.new(),
        chainstate: chainstate,
        data_dir: data_dir,
        memory_only: False,
      ))
    }
    Error(e) -> Error(e)
  }
}

/// Create memory-only storage (for testing)
pub fn open_memory() -> UnifiedStorage {
  UnifiedStorage(
    persistent: None,
    utxo_cache: oni_storage.utxo_view_new(),
    block_index_cache: dict.new(),
    chainstate: genesis_chainstate(),
    data_dir: "",
    memory_only: True,
  )
}

/// Close storage and flush to disk
pub fn close(storage: UnifiedStorage) -> Result(Nil, StorageError) {
  case storage.persistent {
    Some(handle) -> {
      // Flush chainstate
      case persistent_storage.chainstate_put(handle, storage.chainstate) {
        Error(e) -> Error(e)
        Ok(_) -> {
          let _ = persistent_storage.persistent_storage_close(handle)
          Ok(Nil)
        }
      }
    }
    None -> Ok(Nil)
  }
}

// ============================================================================
// UTXO Operations
// ============================================================================

/// Get a UTXO from cache or persistent storage
pub fn get_utxo(
  storage: UnifiedStorage,
  outpoint: OutPoint,
) -> #(UnifiedStorage, Option(Coin)) {
  // First check cache
  case oni_storage.utxo_get(storage.utxo_cache, outpoint) {
    Some(coin) -> #(storage, Some(coin))
    None -> {
      // Check persistent storage
      case storage.persistent {
        None -> #(storage, None)
        Some(handle) -> {
          case persistent_storage.utxo_get(handle, outpoint) {
            Error(_) -> #(storage, None)
            Ok(coin) -> {
              // Add to cache
              let new_cache =
                oni_storage.utxo_add(storage.utxo_cache, outpoint, coin)
              #(UnifiedStorage(..storage, utxo_cache: new_cache), Some(coin))
            }
          }
        }
      }
    }
  }
}

/// Add a UTXO (writes to both cache and persistent storage)
pub fn add_utxo(
  storage: UnifiedStorage,
  outpoint: OutPoint,
  coin: Coin,
) -> Result(UnifiedStorage, StorageError) {
  // Add to cache
  let new_cache = oni_storage.utxo_add(storage.utxo_cache, outpoint, coin)
  let updated = UnifiedStorage(..storage, utxo_cache: new_cache)

  // Write to persistent storage
  case storage.persistent {
    None -> Ok(updated)
    Some(handle) -> {
      case persistent_storage.utxo_put(handle, outpoint, coin) {
        Ok(_) -> Ok(updated)
        Error(e) -> Error(e)
      }
    }
  }
}

/// Remove a UTXO (from both cache and persistent storage)
pub fn remove_utxo(
  storage: UnifiedStorage,
  outpoint: OutPoint,
) -> Result(UnifiedStorage, StorageError) {
  // Remove from cache
  let new_cache = oni_storage.utxo_remove(storage.utxo_cache, outpoint)
  let updated = UnifiedStorage(..storage, utxo_cache: new_cache)

  // Remove from persistent storage
  case storage.persistent {
    None -> Ok(updated)
    Some(handle) -> {
      case persistent_storage.utxo_delete(handle, outpoint) {
        Ok(_) -> Ok(updated)
        Error(e) -> Error(e)
      }
    }
  }
}

/// Apply batch UTXO changes (efficient for block connect/disconnect)
pub fn batch_utxo(
  storage: UnifiedStorage,
  additions: List(#(OutPoint, Coin)),
  removals: List(OutPoint),
) -> Result(UnifiedStorage, StorageError) {
  // Update cache
  let cache_with_removals =
    list.fold(removals, storage.utxo_cache, fn(cache, op) {
      oni_storage.utxo_remove(cache, op)
    })
  let cache_with_additions =
    list.fold(additions, cache_with_removals, fn(cache, entry) {
      let #(op, coin) = entry
      oni_storage.utxo_add(cache, op, coin)
    })
  let updated = UnifiedStorage(..storage, utxo_cache: cache_with_additions)

  // Write to persistent storage
  case storage.persistent {
    None -> Ok(updated)
    Some(handle) -> {
      case persistent_storage.utxo_batch(handle, additions, removals) {
        Ok(_) -> Ok(updated)
        Error(e) -> Error(e)
      }
    }
  }
}

// ============================================================================
// Block Index Operations
// ============================================================================

/// Get block index entry from cache or persistent storage
pub fn get_block_index(
  storage: UnifiedStorage,
  hash: BlockHash,
) -> #(UnifiedStorage, Option(BlockIndexEntry)) {
  let key = oni_bitcoin.block_hash_to_hex(hash)

  // First check cache
  case dict.get(storage.block_index_cache, key) {
    Ok(entry) -> #(storage, Some(entry))
    Error(_) -> {
      // Check persistent storage
      case storage.persistent {
        None -> #(storage, None)
        Some(handle) -> {
          case persistent_storage.block_index_get(handle, hash) {
            Error(_) -> #(storage, None)
            Ok(entry) -> {
              // Add to cache
              let new_cache = dict.insert(storage.block_index_cache, key, entry)
              #(
                UnifiedStorage(..storage, block_index_cache: new_cache),
                Some(entry),
              )
            }
          }
        }
      }
    }
  }
}

/// Put block index entry (writes to both cache and persistent storage)
pub fn put_block_index(
  storage: UnifiedStorage,
  entry: BlockIndexEntry,
) -> Result(UnifiedStorage, StorageError) {
  let key = oni_bitcoin.block_hash_to_hex(entry.hash)

  // Add to cache
  let new_cache = dict.insert(storage.block_index_cache, key, entry)
  let updated = UnifiedStorage(..storage, block_index_cache: new_cache)

  // Write to persistent storage
  case storage.persistent {
    None -> Ok(updated)
    Some(handle) -> {
      case persistent_storage.block_index_put(handle, entry) {
        Ok(_) -> Ok(updated)
        Error(e) -> Error(e)
      }
    }
  }
}

// ============================================================================
// Chainstate Operations
// ============================================================================

/// Get current chainstate
pub fn get_chainstate(storage: UnifiedStorage) -> Chainstate {
  storage.chainstate
}

/// Update chainstate
pub fn update_chainstate(
  storage: UnifiedStorage,
  chainstate: Chainstate,
) -> Result(UnifiedStorage, StorageError) {
  let updated = UnifiedStorage(..storage, chainstate: chainstate)

  // Write to persistent storage
  case storage.persistent {
    None -> Ok(updated)
    Some(handle) -> {
      case persistent_storage.chainstate_put(handle, chainstate) {
        Ok(_) -> Ok(updated)
        Error(e) -> Error(e)
      }
    }
  }
}

/// Get best block hash
pub fn get_best_block(storage: UnifiedStorage) -> BlockHash {
  storage.chainstate.best_block
}

/// Get best block height
pub fn get_best_height(storage: UnifiedStorage) -> Int {
  storage.chainstate.best_height
}

// ============================================================================
// Undo Data Operations
// ============================================================================

/// Get undo data for a block
pub fn get_undo(storage: UnifiedStorage, hash: BlockHash) -> Option(BlockUndo) {
  case storage.persistent {
    None -> None
    Some(handle) -> {
      case persistent_storage.undo_get(handle, hash) {
        Ok(undo) -> Some(undo)
        Error(_) -> None
      }
    }
  }
}

/// Put undo data for a block
pub fn put_undo(
  storage: UnifiedStorage,
  hash: BlockHash,
  undo: BlockUndo,
) -> Result(Nil, StorageError) {
  case storage.persistent {
    None -> Ok(Nil)
    Some(handle) -> persistent_storage.undo_put(handle, hash, undo)
  }
}

// ============================================================================
// Block Connect/Disconnect
// ============================================================================

/// Connect a block - update UTXO set and chainstate
pub fn connect_block(
  storage: UnifiedStorage,
  block: Block,
  height: Int,
) -> Result(#(UnifiedStorage, BlockUndo), StorageError) {
  // Collect UTXO changes
  let #(additions, removals, tx_undos) =
    process_block_transactions(storage, block.transactions, height)

  // Create undo data
  let undo = oni_storage.BlockUndo(tx_undos: tx_undos)

  // Apply UTXO batch
  use updated_storage <- result.try(batch_utxo(storage, additions, removals))

  // Update chainstate
  let block_hash = oni_bitcoin.block_hash_from_header(block.header)
  let new_chainstate =
    oni_storage.Chainstate(
      ..updated_storage.chainstate,
      best_block: block_hash,
      best_height: height,
      total_tx: updated_storage.chainstate.total_tx
        + list.length(block.transactions),
      total_coins: updated_storage.chainstate.total_coins
        + list.length(additions)
        - list.length(removals),
    )

  use final_storage <- result.try(update_chainstate(
    updated_storage,
    new_chainstate,
  ))

  // Store undo data
  case put_undo(final_storage, block_hash, undo) {
    Ok(_) -> Ok(#(final_storage, undo))
    Error(e) -> Error(e)
  }
}

/// Disconnect a block - revert UTXO set using undo data
pub fn disconnect_block(
  storage: UnifiedStorage,
  block: Block,
  undo: BlockUndo,
  prev_hash: BlockHash,
  prev_height: Int,
) -> Result(UnifiedStorage, StorageError) {
  // Reverse the block transactions
  let #(additions, removals) = reverse_block_transactions(block, undo)

  // Apply UTXO batch (note: additions become removals and vice versa)
  use updated_storage <- result.try(batch_utxo(storage, additions, removals))

  // Update chainstate
  let new_chainstate =
    oni_storage.Chainstate(
      ..updated_storage.chainstate,
      best_block: prev_hash,
      best_height: prev_height,
      total_tx: updated_storage.chainstate.total_tx
        - list.length(block.transactions),
      total_coins: updated_storage.chainstate.total_coins
        + list.length(removals)
        - list.length(additions),
    )

  update_chainstate(updated_storage, new_chainstate)
}

// ============================================================================
// Helper Functions
// ============================================================================

/// Genesis chainstate (for initial state)
fn genesis_chainstate() -> Chainstate {
  oni_storage.Chainstate(
    best_block: oni_bitcoin.mainnet_params().genesis_hash,
    best_height: 0,
    total_tx: 1,
    total_coins: 1,
    total_amount: 5_000_000_000,
    pruned: False,
    pruned_height: None,
  )
}

/// Process block transactions to get UTXO changes
fn process_block_transactions(
  storage: UnifiedStorage,
  transactions: List(Transaction),
  height: Int,
) -> #(List(#(OutPoint, Coin)), List(OutPoint), List(oni_storage.TxUndo)) {
  list.index_fold(transactions, #([], [], []), fn(acc, tx, tx_index) {
    let #(additions, removals, undos) = acc
    let is_coinbase = tx_index == 0

    // Get spent coins for undo data (skip coinbase)
    let input_undos = case is_coinbase {
      True -> []
      False -> {
        list.filter_map(tx.inputs, fn(input) {
          let #(_, maybe_coin) = get_utxo(storage, input.prevout)
          case maybe_coin {
            Some(coin) -> Ok(oni_storage.TxInputUndo(coin: coin))
            None -> Error(Nil)
          }
        })
      }
    }

    // Remove spent outputs (skip coinbase inputs)
    let new_removals = case is_coinbase {
      True -> removals
      False -> {
        list.append(removals, list.map(tx.inputs, fn(input) { input.prevout }))
      }
    }

    // Add new outputs
    let txid = oni_bitcoin.txid_from_tx(tx)
    let new_additions =
      list.index_fold(tx.outputs, additions, fn(add_acc, output, vout) {
        let outpoint = oni_bitcoin.OutPoint(txid: txid, vout: vout)
        let coin =
          oni_storage.Coin(
            output: output,
            height: height,
            is_coinbase: is_coinbase,
          )
        list.append(add_acc, [#(outpoint, coin)])
      })

    let new_undos =
      list.append(undos, [
        oni_storage.TxUndo(spent_coins: input_undos),
      ])

    #(new_additions, new_removals, new_undos)
  })
}

/// Reverse block transactions for disconnect
fn reverse_block_transactions(
  block: Block,
  undo: BlockUndo,
) -> #(List(#(OutPoint, Coin)), List(OutPoint)) {
  // Removals: the outputs created by this block
  let removals =
    list.flatten(
      list.index_map(block.transactions, fn(tx, _) {
        let txid = oni_bitcoin.txid_from_tx(tx)
        list.index_map(tx.outputs, fn(_, vout) {
          oni_bitcoin.OutPoint(txid: txid, vout: vout)
        })
      }),
    )

  // Additions: restore the spent inputs (from undo data)
  let additions =
    list.zip(block.transactions, undo.tx_undos)
    |> list.flat_map(fn(pair) {
      let #(tx, tx_undo) = pair
      list.zip(tx.inputs, tx_undo.spent_coins)
      |> list.map(fn(input_pair) {
        let #(input, input_undo) = input_pair
        #(input.prevout, input_undo.coin)
      })
    })

  #(additions, removals)
}
