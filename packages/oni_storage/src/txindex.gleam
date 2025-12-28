// txindex.gleam - Transaction index for historical transaction lookups
//
// This module provides a persistent index mapping transaction IDs (txids)
// to their location within the blockchain (block hash and position).
// This is essential for RPC methods like getrawtransaction.
//
// Database layout:
// - txindex_db: Txid (32 bytes) -> TxLocation (block_hash + tx_index + tx_offset)
//
// Features:
// - O(1) lookup of any confirmed transaction by txid
// - Batch updates during block connection/disconnection
// - Efficient serialization for minimal storage overhead
//
// Usage:
//   1. Call txindex_open(path) to open the index
//   2. Use txindex_put_batch during block connection
//   3. Use txindex_get to lookup transactions
//   4. Use txindex_remove_batch during block disconnection

import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import db_backend.{type DbHandle, BatchDelete, BatchPut, default_options}
import oni_bitcoin.{type BlockHash, type Txid}
import oni_storage.{type StorageError}

// ============================================================================
// Types
// ============================================================================

/// Location of a transaction within the blockchain
pub type TxLocation {
  TxLocation(
    /// Block containing this transaction
    block_hash: BlockHash,
    /// Index of transaction within the block (0 = coinbase)
    tx_index: Int,
    /// Height of the block
    block_height: Int,
  )
}

/// Transaction index handle
pub type TxIndexHandle {
  TxIndexHandle(
    /// Database handle (None if disabled)
    db: Option(DbHandle),
    /// Whether the index is enabled
    enabled: Bool,
    /// Path to database file
    path: String,
  )
}

/// Configuration for transaction index
pub type TxIndexConfig {
  TxIndexConfig(
    /// Path to store index data
    data_dir: String,
    /// Whether txindex is enabled
    enabled: Bool,
  )
}

// ============================================================================
// Index Operations
// ============================================================================

/// Open the transaction index
pub fn txindex_open(config: TxIndexConfig) -> Result(TxIndexHandle, StorageError) {
  case config.enabled {
    False -> {
      // Return a disabled handle
      Ok(TxIndexHandle(
        db: None,
        enabled: False,
        path: "",
      ))
    }
    True -> {
      let db_path = config.data_dir <> "/txindex.db"
      let options = default_options()

      case db_backend.db_open(db_path, options) {
        Ok(db) -> {
          Ok(TxIndexHandle(
            db: Some(db),
            enabled: True,
            path: db_path,
          ))
        }
        Error(err) -> Error(db_error_to_storage_error(err))
      }
    }
  }
}

/// Close the transaction index
pub fn txindex_close(handle: TxIndexHandle) -> Result(Nil, StorageError) {
  case handle.db {
    None -> Ok(Nil)
    Some(db) -> {
      db_backend.db_close(db)
      |> result.map_error(db_error_to_storage_error)
    }
  }
}

/// Check if txindex is enabled
pub fn txindex_is_enabled(handle: TxIndexHandle) -> Bool {
  handle.enabled
}

/// Look up a transaction by txid
pub fn txindex_get(
  handle: TxIndexHandle,
  txid: Txid,
) -> Result(TxLocation, StorageError) {
  case handle.db {
    None -> Error(oni_storage.Other("txindex is disabled"))
    Some(db) -> {
      let key = serialize_txid(txid)
      case db_backend.db_get(db, key) {
        Ok(data) -> deserialize_tx_location(data)
        Error(err) -> Error(db_error_to_storage_error(err))
      }
    }
  }
}

/// Check if a transaction exists in the index
pub fn txindex_has(handle: TxIndexHandle, txid: Txid) -> Bool {
  case handle.db {
    None -> False
    Some(db) -> {
      let key = serialize_txid(txid)
      db_backend.db_has(db, key)
    }
  }
}

/// Add a single transaction to the index
pub fn txindex_put(
  handle: TxIndexHandle,
  txid: Txid,
  location: TxLocation,
) -> Result(Nil, StorageError) {
  case handle.db {
    None -> Ok(Nil)  // No-op when disabled
    Some(db) -> {
      let key = serialize_txid(txid)
      let value = serialize_tx_location(location)
      db_backend.db_put(db, key, value)
      |> result.map_error(db_error_to_storage_error)
    }
  }
}

/// Remove a transaction from the index
pub fn txindex_remove(
  handle: TxIndexHandle,
  txid: Txid,
) -> Result(Nil, StorageError) {
  case handle.db {
    None -> Ok(Nil)
    Some(db) -> {
      let key = serialize_txid(txid)
      db_backend.db_delete(db, key)
      |> result.map_error(db_error_to_storage_error)
    }
  }
}

/// Batch add transactions (used during block connection)
pub fn txindex_put_batch(
  handle: TxIndexHandle,
  entries: List(#(Txid, TxLocation)),
) -> Result(Nil, StorageError) {
  case handle.db {
    None -> Ok(Nil)
    Some(db) -> {
      let ops = list.map(entries, fn(entry) {
        let #(txid, location) = entry
        BatchPut(serialize_txid(txid), serialize_tx_location(location))
      })
      db_backend.db_batch(db, ops)
      |> result.map_error(db_error_to_storage_error)
    }
  }
}

/// Batch remove transactions (used during block disconnection)
pub fn txindex_remove_batch(
  handle: TxIndexHandle,
  txids: List(Txid),
) -> Result(Nil, StorageError) {
  case handle.db {
    None -> Ok(Nil)
    Some(db) -> {
      let ops = list.map(txids, fn(txid) {
        BatchDelete(serialize_txid(txid))
      })
      db_backend.db_batch(db, ops)
      |> result.map_error(db_error_to_storage_error)
    }
  }
}

/// Sync the index to disk
pub fn txindex_sync(handle: TxIndexHandle) -> Result(Nil, StorageError) {
  case handle.db {
    None -> Ok(Nil)
    Some(db) -> {
      db_backend.db_sync(db)
      |> result.map_error(db_error_to_storage_error)
    }
  }
}

/// Get number of indexed transactions
pub fn txindex_count(handle: TxIndexHandle) -> Result(Int, StorageError) {
  case handle.db {
    None -> Ok(0)
    Some(db) -> {
      db_backend.db_count(db)
      |> result.map_error(db_error_to_storage_error)
    }
  }
}

// ============================================================================
// Block Indexing Helpers
// ============================================================================

/// Index all transactions in a block
/// Returns list of (txid, location) pairs for batch insertion
pub fn index_block_transactions(
  block_hash: BlockHash,
  block_height: Int,
  txids: List(Txid),
) -> List(#(Txid, TxLocation)) {
  index_txids_with_position(txids, block_hash, block_height, 0, [])
}

fn index_txids_with_position(
  txids: List(Txid),
  block_hash: BlockHash,
  block_height: Int,
  index: Int,
  acc: List(#(Txid, TxLocation)),
) -> List(#(Txid, TxLocation)) {
  case txids {
    [] -> acc
    [txid, ..rest] -> {
      let location = TxLocation(
        block_hash: block_hash,
        tx_index: index,
        block_height: block_height,
      )
      index_txids_with_position(
        rest,
        block_hash,
        block_height,
        index + 1,
        [#(txid, location), ..acc],
      )
    }
  }
}

// ============================================================================
// Serialization
// ============================================================================

/// Serialize txid to bytes (32 bytes)
fn serialize_txid(txid: Txid) -> BitArray {
  txid.hash.bytes
}

/// Serialize transaction location to bytes
/// Format: block_hash (32) + tx_index (4) + block_height (4) = 40 bytes
fn serialize_tx_location(location: TxLocation) -> BitArray {
  <<
    location.block_hash.hash.bytes:bits,
    location.tx_index:32-little,
    location.block_height:32-little,
  >>
}

/// Deserialize transaction location from bytes
fn deserialize_tx_location(data: BitArray) -> Result(TxLocation, StorageError) {
  case data {
    <<
      block_hash_bytes:bytes-size(32),
      tx_index:32-little,
      block_height:32-little,
    >> -> {
      Ok(TxLocation(
        block_hash: oni_bitcoin.BlockHash(
          hash: oni_bitcoin.Hash256(bytes: block_hash_bytes),
        ),
        tx_index: tx_index,
        block_height: block_height,
      ))
    }
    _ -> Error(oni_storage.CorruptData)
  }
}

// ============================================================================
// Helper Functions
// ============================================================================

/// Convert db error to storage error
fn db_error_to_storage_error(error: db_backend.DbError) -> StorageError {
  case error {
    db_backend.DbNotFound -> oni_storage.NotFound
    db_backend.KeyNotFound -> oni_storage.NotFound
    db_backend.Corrupted -> oni_storage.CorruptData
    db_backend.IoError(msg) -> oni_storage.IoError(msg)
    db_backend.Closed -> oni_storage.DatabaseError("Database closed")
    db_backend.SchemaMismatch(_, _) -> oni_storage.MigrationRequired
    db_backend.Other(msg) -> oni_storage.DatabaseError(msg)
  }
}

// ============================================================================
// Extended Transaction Info
// ============================================================================

/// Extended transaction info returned from lookups
pub type TxInfo {
  TxInfo(
    /// The transaction data
    txid: Txid,
    /// Block containing this transaction
    block_hash: BlockHash,
    /// Height of containing block
    block_height: Int,
    /// Position within block
    tx_index: Int,
    /// Number of confirmations (0 if unconfirmed)
    confirmations: Int,
    /// Block time
    block_time: Option(Int),
  )
}

/// Create TxInfo from location and current chain height
pub fn tx_info_from_location(
  txid: Txid,
  location: TxLocation,
  current_height: Int,
  block_time: Option(Int),
) -> TxInfo {
  let confirmations = case current_height >= location.block_height {
    True -> current_height - location.block_height + 1
    False -> 0
  }

  TxInfo(
    txid: txid,
    block_hash: location.block_hash,
    block_height: location.block_height,
    tx_index: location.tx_index,
    confirmations: confirmations,
    block_time: block_time,
  )
}
