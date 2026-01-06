// persistent_storage.gleam - Persistent storage layer using db_backend
//
// This module provides persistent storage for the oni node by wrapping
// db_backend.gleam. It handles serialization/deserialization of all
// storage types to/from BitArrays.
//
// Database layout:
// - utxo_db: OutPoint (key) -> Coin (value)
// - block_index_db: BlockHash (key) -> BlockIndexEntry (value)
// - chainstate_db: Fixed keys for chainstate metadata
// - undo_db: BlockHash (key) -> BlockUndo (value)
//
// Usage:
//   1. Call persistent_storage_open(data_dir) to open all databases
//   2. Use the returned handle with storage operations
//   3. Call persistent_storage_close(handle) on shutdown

import db_backend.{
  type DbError, type DbHandle, BatchDelete, BatchPut, default_options,
}
import gleam/bit_array
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import oni_bitcoin.{type BlockHash, type OutPoint}
import oni_storage.{
  type BlockIndexEntry, type BlockStatus, type BlockUndo, type Chainstate,
  type Coin, type StorageError, type TxInputUndo, type TxUndo,
}

// ============================================================================
// Types
// ============================================================================

/// Handle to persistent storage (wraps multiple database handles)
pub type PersistentStorageHandle {
  PersistentStorageHandle(
    /// UTXO database
    utxo_db: DbHandle,
    /// Block index database
    block_index_db: DbHandle,
    /// Chainstate database (metadata)
    chainstate_db: DbHandle,
    /// Block undo data database
    undo_db: DbHandle,
    /// Data directory path
    data_dir: String,
  )
}

/// Chainstate keys in database
const chainstate_best_block_key = <<"chainstate:best_block">>

const chainstate_best_height_key = <<"chainstate:best_height">>

const chainstate_total_tx_key = <<"chainstate:total_tx">>

const chainstate_total_coins_key = <<"chainstate:total_coins">>

const chainstate_total_amount_key = <<"chainstate:total_amount">>

const chainstate_pruned_key = <<"chainstate:pruned">>

const chainstate_pruned_height_key = <<"chainstate:pruned_height">>

// ============================================================================
// Open/Close Operations
// ============================================================================

/// Open persistent storage
pub fn persistent_storage_open(
  data_dir: String,
) -> Result(PersistentStorageHandle, StorageError) {
  let options = default_options()

  // Ensure data directory exists
  let _ = make_dir(data_dir)

  // Open UTXO database
  use utxo_db <- result.try(
    db_backend.db_open(data_dir <> "/utxo.db", options)
    |> result.map_error(db_error_to_storage_error),
  )

  // Open block index database
  use block_index_db <- result.try(
    db_backend.db_open(data_dir <> "/block_index.db", options)
    |> result.map_error(db_error_to_storage_error),
  )

  // Open chainstate database
  use chainstate_db <- result.try(
    db_backend.db_open(data_dir <> "/chainstate.db", options)
    |> result.map_error(db_error_to_storage_error),
  )

  // Open undo database
  use undo_db <- result.try(
    db_backend.db_open(data_dir <> "/undo.db", options)
    |> result.map_error(db_error_to_storage_error),
  )

  Ok(PersistentStorageHandle(
    utxo_db: utxo_db,
    block_index_db: block_index_db,
    chainstate_db: chainstate_db,
    undo_db: undo_db,
    data_dir: data_dir,
  ))
}

/// Close persistent storage
pub fn persistent_storage_close(
  handle: PersistentStorageHandle,
) -> Result(Nil, StorageError) {
  // Close all databases
  use _ <- result.try(
    db_backend.db_close(handle.utxo_db)
    |> result.map_error(db_error_to_storage_error),
  )
  use _ <- result.try(
    db_backend.db_close(handle.block_index_db)
    |> result.map_error(db_error_to_storage_error),
  )
  use _ <- result.try(
    db_backend.db_close(handle.chainstate_db)
    |> result.map_error(db_error_to_storage_error),
  )
  use _ <- result.try(
    db_backend.db_close(handle.undo_db)
    |> result.map_error(db_error_to_storage_error),
  )
  Ok(Nil)
}

/// Sync all databases to disk
pub fn persistent_storage_sync(
  handle: PersistentStorageHandle,
) -> Result(Nil, StorageError) {
  use _ <- result.try(
    db_backend.db_sync(handle.utxo_db)
    |> result.map_error(db_error_to_storage_error),
  )
  use _ <- result.try(
    db_backend.db_sync(handle.block_index_db)
    |> result.map_error(db_error_to_storage_error),
  )
  use _ <- result.try(
    db_backend.db_sync(handle.chainstate_db)
    |> result.map_error(db_error_to_storage_error),
  )
  use _ <- result.try(
    db_backend.db_sync(handle.undo_db)
    |> result.map_error(db_error_to_storage_error),
  )
  Ok(Nil)
}

// ============================================================================
// UTXO Operations
// ============================================================================

/// Get a UTXO by outpoint
pub fn utxo_get(
  handle: PersistentStorageHandle,
  outpoint: OutPoint,
) -> Result(Coin, StorageError) {
  let key = serialize_outpoint(outpoint)
  use data <- result.try(
    db_backend.db_get(handle.utxo_db, key)
    |> result.map_error(db_error_to_storage_error),
  )
  deserialize_coin(data)
}

/// Put a UTXO
pub fn utxo_put(
  handle: PersistentStorageHandle,
  outpoint: OutPoint,
  coin: Coin,
) -> Result(Nil, StorageError) {
  let key = serialize_outpoint(outpoint)
  let value = serialize_coin(coin)
  db_backend.db_put(handle.utxo_db, key, value)
  |> result.map_error(db_error_to_storage_error)
}

/// Delete a UTXO
pub fn utxo_delete(
  handle: PersistentStorageHandle,
  outpoint: OutPoint,
) -> Result(Nil, StorageError) {
  let key = serialize_outpoint(outpoint)
  db_backend.db_delete(handle.utxo_db, key)
  |> result.map_error(db_error_to_storage_error)
}

/// Check if UTXO exists
pub fn utxo_has(handle: PersistentStorageHandle, outpoint: OutPoint) -> Bool {
  let key = serialize_outpoint(outpoint)
  db_backend.db_has(handle.utxo_db, key)
}

/// Get UTXO count
pub fn utxo_count(handle: PersistentStorageHandle) -> Result(Int, StorageError) {
  db_backend.db_count(handle.utxo_db)
  |> result.map_error(db_error_to_storage_error)
}

/// Apply a batch of UTXO changes
pub fn utxo_batch(
  handle: PersistentStorageHandle,
  additions: List(#(OutPoint, Coin)),
  removals: List(OutPoint),
) -> Result(Nil, StorageError) {
  // Build batch operations
  let add_ops =
    list.map(additions, fn(entry) {
      let #(outpoint, coin) = entry
      BatchPut(serialize_outpoint(outpoint), serialize_coin(coin))
    })

  let remove_ops =
    list.map(removals, fn(outpoint) {
      BatchDelete(serialize_outpoint(outpoint))
    })

  let ops = list.append(remove_ops, add_ops)

  db_backend.db_batch(handle.utxo_db, ops)
  |> result.map_error(db_error_to_storage_error)
}

// ============================================================================
// Block Index Operations
// ============================================================================

/// Get block index entry by hash
pub fn block_index_get(
  handle: PersistentStorageHandle,
  hash: BlockHash,
) -> Result(BlockIndexEntry, StorageError) {
  let key = serialize_block_hash(hash)
  use data <- result.try(
    db_backend.db_get(handle.block_index_db, key)
    |> result.map_error(db_error_to_storage_error),
  )
  deserialize_block_index_entry(data)
}

/// Put block index entry
pub fn block_index_put(
  handle: PersistentStorageHandle,
  entry: BlockIndexEntry,
) -> Result(Nil, StorageError) {
  let key = serialize_block_hash(entry.hash)
  let value = serialize_block_index_entry(entry)
  db_backend.db_put(handle.block_index_db, key, value)
  |> result.map_error(db_error_to_storage_error)
}

/// Check if block index entry exists
pub fn block_index_has(handle: PersistentStorageHandle, hash: BlockHash) -> Bool {
  let key = serialize_block_hash(hash)
  db_backend.db_has(handle.block_index_db, key)
}

// ============================================================================
// Chainstate Operations
// ============================================================================

/// Get chainstate
pub fn chainstate_get(
  handle: PersistentStorageHandle,
) -> Result(Chainstate, StorageError) {
  // Read all chainstate values
  use best_block_data <- result.try(
    db_backend.db_get(handle.chainstate_db, chainstate_best_block_key)
    |> result.map_error(db_error_to_storage_error),
  )
  use best_height_data <- result.try(
    db_backend.db_get(handle.chainstate_db, chainstate_best_height_key)
    |> result.map_error(db_error_to_storage_error),
  )
  use total_tx_data <- result.try(
    db_backend.db_get(handle.chainstate_db, chainstate_total_tx_key)
    |> result.map_error(db_error_to_storage_error),
  )
  use total_coins_data <- result.try(
    db_backend.db_get(handle.chainstate_db, chainstate_total_coins_key)
    |> result.map_error(db_error_to_storage_error),
  )
  use total_amount_data <- result.try(
    db_backend.db_get(handle.chainstate_db, chainstate_total_amount_key)
    |> result.map_error(db_error_to_storage_error),
  )
  use pruned_data <- result.try(
    db_backend.db_get(handle.chainstate_db, chainstate_pruned_key)
    |> result.map_error(db_error_to_storage_error),
  )

  // Deserialize
  use best_block <- result.try(deserialize_block_hash(best_block_data))
  use best_height <- result.try(deserialize_int(best_height_data))
  use total_tx <- result.try(deserialize_int(total_tx_data))
  use total_coins <- result.try(deserialize_int(total_coins_data))
  use total_amount <- result.try(deserialize_int(total_amount_data))
  use pruned <- result.try(deserialize_bool(pruned_data))

  // Pruned height is optional
  let pruned_height = case pruned {
    False -> None
    True -> {
      case
        db_backend.db_get(handle.chainstate_db, chainstate_pruned_height_key)
      {
        Ok(data) -> {
          case deserialize_int(data) {
            Ok(h) -> Some(h)
            Error(_) -> None
          }
        }
        Error(_) -> None
      }
    }
  }

  Ok(oni_storage.Chainstate(
    best_block: best_block,
    best_height: best_height,
    total_tx: total_tx,
    total_coins: total_coins,
    total_amount: total_amount,
    pruned: pruned,
    pruned_height: pruned_height,
  ))
}

/// Put chainstate
pub fn chainstate_put(
  handle: PersistentStorageHandle,
  chainstate: Chainstate,
) -> Result(Nil, StorageError) {
  // Build batch operations
  let ops = [
    BatchPut(
      chainstate_best_block_key,
      serialize_block_hash(chainstate.best_block),
    ),
    BatchPut(chainstate_best_height_key, serialize_int(chainstate.best_height)),
    BatchPut(chainstate_total_tx_key, serialize_int(chainstate.total_tx)),
    BatchPut(chainstate_total_coins_key, serialize_int(chainstate.total_coins)),
    BatchPut(
      chainstate_total_amount_key,
      serialize_int(chainstate.total_amount),
    ),
    BatchPut(chainstate_pruned_key, serialize_bool(chainstate.pruned)),
  ]

  let ops = case chainstate.pruned_height {
    Some(h) -> [BatchPut(chainstate_pruned_height_key, serialize_int(h)), ..ops]
    None -> ops
  }

  db_backend.db_batch(handle.chainstate_db, ops)
  |> result.map_error(db_error_to_storage_error)
}

// ============================================================================
// Undo Data Operations
// ============================================================================

/// Get block undo data
pub fn undo_get(
  handle: PersistentStorageHandle,
  hash: BlockHash,
) -> Result(BlockUndo, StorageError) {
  let key = serialize_block_hash(hash)
  use data <- result.try(
    db_backend.db_get(handle.undo_db, key)
    |> result.map_error(db_error_to_storage_error),
  )
  deserialize_block_undo(data)
}

/// Put block undo data
pub fn undo_put(
  handle: PersistentStorageHandle,
  hash: BlockHash,
  undo: BlockUndo,
) -> Result(Nil, StorageError) {
  let key = serialize_block_hash(hash)
  let value = serialize_block_undo(undo)
  db_backend.db_put(handle.undo_db, key, value)
  |> result.map_error(db_error_to_storage_error)
}

/// Delete block undo data
pub fn undo_delete(
  handle: PersistentStorageHandle,
  hash: BlockHash,
) -> Result(Nil, StorageError) {
  let key = serialize_block_hash(hash)
  db_backend.db_delete(handle.undo_db, key)
  |> result.map_error(db_error_to_storage_error)
}

// ============================================================================
// Serialization Functions
// ============================================================================

/// Serialize an outpoint to bytes (txid + vout)
fn serialize_outpoint(outpoint: OutPoint) -> BitArray {
  <<outpoint.txid.hash.bytes:bits, outpoint.vout:32-little>>
}

/// Serialize a coin to bytes
fn serialize_coin(coin: Coin) -> BitArray {
  let script_bytes = oni_bitcoin.script_to_bytes(coin.output.script_pubkey)
  let script_len = byte_size(script_bytes)
  let value = oni_bitcoin.amount_to_sats(coin.output.value)
  let is_coinbase_byte = case coin.is_coinbase {
    True -> 1
    False -> 0
  }

  <<
    value:64-little,
    coin.height:32-little,
    is_coinbase_byte:8,
    script_len:32-little,
    script_bytes:bits,
  >>
}

/// Deserialize a coin from bytes
fn deserialize_coin(data: BitArray) -> Result(Coin, StorageError) {
  case data {
    <<
      value:64-little,
      height:32-little,
      is_coinbase_byte:8,
      script_len:32-little,
      rest:bits,
    >> -> {
      case bit_array_slice(rest, 0, script_len) {
        Ok(script_bytes) -> {
          let output =
            oni_bitcoin.TxOut(
              value: oni_bitcoin.Amount(sats: value),
              script_pubkey: oni_bitcoin.Script(bytes: script_bytes),
            )
          let is_coinbase = is_coinbase_byte == 1
          Ok(oni_storage.Coin(
            output: output,
            height: height,
            is_coinbase: is_coinbase,
          ))
        }
        Error(_) -> Error(oni_storage.CorruptData)
      }
    }
    _ -> Error(oni_storage.CorruptData)
  }
}

/// Serialize a block hash
fn serialize_block_hash(hash: BlockHash) -> BitArray {
  hash.hash.bytes
}

/// Deserialize a block hash
fn deserialize_block_hash(data: BitArray) -> Result(BlockHash, StorageError) {
  case byte_size(data) == 32 {
    True -> Ok(oni_bitcoin.BlockHash(hash: oni_bitcoin.Hash256(bytes: data)))
    False -> Error(oni_storage.CorruptData)
  }
}

/// Serialize an integer
fn serialize_int(n: Int) -> BitArray {
  <<n:64-little>>
}

/// Deserialize an integer
fn deserialize_int(data: BitArray) -> Result(Int, StorageError) {
  case data {
    <<n:64-little>> -> Ok(n)
    _ -> Error(oni_storage.CorruptData)
  }
}

/// Serialize a boolean
fn serialize_bool(b: Bool) -> BitArray {
  case b {
    True -> <<1:8>>
    False -> <<0:8>>
  }
}

/// Deserialize a boolean
fn deserialize_bool(data: BitArray) -> Result(Bool, StorageError) {
  case data {
    <<1:8>> -> Ok(True)
    <<0:8>> -> Ok(False)
    _ -> Error(oni_storage.CorruptData)
  }
}

/// Serialize a block index entry
fn serialize_block_index_entry(entry: BlockIndexEntry) -> BitArray {
  let status_byte = status_to_byte(entry.status)
  let file_pos = option_int_to_bytes(entry.file_pos)
  let undo_pos = option_int_to_bytes(entry.undo_pos)

  <<
    entry.hash.hash.bytes:bits,
    // 32 bytes
    entry.prev_hash.hash.bytes:bits,
    // 32 bytes
    entry.height:32-little,
    status_byte:8,
    entry.num_tx:32-little,
    entry.total_work:64-little,
    file_pos:bits,
    // 9 bytes (1 flag + 8 int)
    undo_pos:bits,
    // 9 bytes (1 flag + 8 int)
    entry.timestamp:32-little,
    entry.bits:32-little,
    entry.nonce:32-little,
    entry.version:32-little,
  >>
}

/// Deserialize a block index entry
fn deserialize_block_index_entry(
  data: BitArray,
) -> Result(BlockIndexEntry, StorageError) {
  case data {
    <<
      hash_bytes:bytes-size(32),
      prev_hash_bytes:bytes-size(32),
      height:32-little,
      status_byte:8,
      num_tx:32-little,
      total_work:64-little,
      file_pos_flag:8,
      file_pos_value:64-little,
      undo_pos_flag:8,
      undo_pos_value:64-little,
      timestamp:32-little,
      bits:32-little,
      nonce:32-little,
      version:32-little,
    >> -> {
      let hash =
        oni_bitcoin.BlockHash(hash: oni_bitcoin.Hash256(bytes: hash_bytes))
      let prev_hash =
        oni_bitcoin.BlockHash(hash: oni_bitcoin.Hash256(bytes: prev_hash_bytes))
      let status = byte_to_status(status_byte)
      let file_pos = case file_pos_flag {
        1 -> Some(file_pos_value)
        _ -> None
      }
      let undo_pos = case undo_pos_flag {
        1 -> Some(undo_pos_value)
        _ -> None
      }

      Ok(oni_storage.BlockIndexEntry(
        hash: hash,
        prev_hash: prev_hash,
        height: height,
        status: status,
        num_tx: num_tx,
        total_work: total_work,
        file_pos: file_pos,
        undo_pos: undo_pos,
        timestamp: timestamp,
        bits: bits,
        nonce: nonce,
        version: version,
      ))
    }
    _ -> Error(oni_storage.CorruptData)
  }
}

/// Convert status to byte
fn status_to_byte(status: BlockStatus) -> Int {
  case status {
    oni_storage.BlockValidHeader -> 0
    oni_storage.BlockValidTree -> 1
    oni_storage.BlockValidTransactions -> 2
    oni_storage.BlockValidChain -> 3
    oni_storage.BlockValidScripts -> 4
    oni_storage.BlockFailed -> 5
    oni_storage.BlockFailedChild -> 6
  }
}

/// Convert byte to status
fn byte_to_status(byte: Int) -> BlockStatus {
  case byte {
    0 -> oni_storage.BlockValidHeader
    1 -> oni_storage.BlockValidTree
    2 -> oni_storage.BlockValidTransactions
    3 -> oni_storage.BlockValidChain
    4 -> oni_storage.BlockValidScripts
    5 -> oni_storage.BlockFailed
    _ -> oni_storage.BlockFailedChild
  }
}

/// Serialize optional int
fn option_int_to_bytes(opt: Option(Int)) -> BitArray {
  case opt {
    Some(n) -> <<1:8, n:64-little>>
    None -> <<0:8, 0:64-little>>
  }
}

/// Serialize block undo data
fn serialize_block_undo(undo: BlockUndo) -> BitArray {
  let tx_count = list.length(undo.tx_undos)
  let tx_data =
    list.fold(undo.tx_undos, <<>>, fn(acc, tx_undo) {
      let tx_undo_bytes = serialize_tx_undo(tx_undo)
      <<acc:bits, tx_undo_bytes:bits>>
    })

  <<tx_count:32-little, tx_data:bits>>
}

/// Serialize transaction undo data
fn serialize_tx_undo(undo: TxUndo) -> BitArray {
  let coin_count = list.length(undo.spent_coins)
  let coins_data =
    list.fold(undo.spent_coins, <<>>, fn(acc, input_undo) {
      let coin_bytes = serialize_coin(input_undo.coin)
      let coin_len = byte_size(coin_bytes)
      <<acc:bits, coin_len:32-little, coin_bytes:bits>>
    })

  <<coin_count:32-little, coins_data:bits>>
}

/// Deserialize block undo data
fn deserialize_block_undo(data: BitArray) -> Result(BlockUndo, StorageError) {
  case data {
    <<tx_count:32-little, rest:bits>> -> {
      case deserialize_tx_undos(rest, tx_count, []) {
        Ok(tx_undos) -> Ok(oni_storage.BlockUndo(tx_undos: tx_undos))
        Error(e) -> Error(e)
      }
    }
    _ -> Error(oni_storage.CorruptData)
  }
}

/// Deserialize multiple tx undos
fn deserialize_tx_undos(
  data: BitArray,
  remaining: Int,
  acc: List(TxUndo),
) -> Result(List(TxUndo), StorageError) {
  case remaining <= 0 {
    True -> Ok(list.reverse(acc))
    False -> {
      case deserialize_tx_undo_with_rest(data) {
        Ok(#(tx_undo, rest)) ->
          deserialize_tx_undos(rest, remaining - 1, [tx_undo, ..acc])
        Error(e) -> Error(e)
      }
    }
  }
}

/// Deserialize a single tx undo and return remaining data
fn deserialize_tx_undo_with_rest(
  data: BitArray,
) -> Result(#(TxUndo, BitArray), StorageError) {
  case data {
    <<coin_count:32-little, rest:bits>> -> {
      case deserialize_input_undos(rest, coin_count, []) {
        Ok(#(spent_coins, remaining)) ->
          Ok(#(oni_storage.TxUndo(spent_coins: spent_coins), remaining))
        Error(e) -> Error(e)
      }
    }
    _ -> Error(oni_storage.CorruptData)
  }
}

/// Deserialize input undos
fn deserialize_input_undos(
  data: BitArray,
  remaining: Int,
  acc: List(TxInputUndo),
) -> Result(#(List(TxInputUndo), BitArray), StorageError) {
  case remaining <= 0 {
    True -> Ok(#(list.reverse(acc), data))
    False -> {
      case data {
        <<coin_len:32-little, rest:bits>> -> {
          case bit_array_slice(rest, 0, coin_len) {
            Ok(coin_bytes) -> {
              case deserialize_coin(coin_bytes) {
                Ok(coin) -> {
                  let new_rest = bit_array_drop(rest, coin_len)
                  let input_undo = oni_storage.TxInputUndo(coin: coin)
                  deserialize_input_undos(new_rest, remaining - 1, [
                    input_undo,
                    ..acc
                  ])
                }
                Error(e) -> Error(e)
              }
            }
            Error(_) -> Error(oni_storage.CorruptData)
          }
        }
        _ -> Error(oni_storage.CorruptData)
      }
    }
  }
}

// ============================================================================
// Helper Functions
// ============================================================================

/// Convert db_backend error to storage error
fn db_error_to_storage_error(error: DbError) -> StorageError {
  case error {
    db_backend.DbNotFound -> oni_storage.NotFound
    db_backend.KeyNotFound -> oni_storage.NotFound
    db_backend.Corrupted -> oni_storage.CorruptData
    db_backend.IoError(msg) -> oni_storage.IoError(msg)
    db_backend.Closed -> oni_storage.DatabaseError("Database closed")
    db_backend.SchemaMismatch(_expected, _found) ->
      oni_storage.MigrationRequired
    db_backend.Other(msg) -> oni_storage.DatabaseError(msg)
  }
}

/// Get byte size of bit array
@external(erlang, "erlang", "byte_size")
fn byte_size(data: BitArray) -> Int

/// Create a directory
@external(erlang, "file", "make_dir")
fn make_dir(path: String) -> Result(Nil, Nil)

/// Slice a bit array
fn bit_array_slice(
  data: BitArray,
  start: Int,
  length: Int,
) -> Result(BitArray, Nil) {
  bit_array.slice(data, start, length)
}

/// Drop bytes from beginning of bit array
fn bit_array_drop(data: BitArray, n: Int) -> BitArray {
  case bit_array.slice(data, n, byte_size(data) - n) {
    Ok(rest) -> rest
    Error(_) -> <<>>
  }
}
