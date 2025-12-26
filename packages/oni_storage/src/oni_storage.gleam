// oni_storage - Block storage, UTXO database, and chainstate management
//
// This module provides persistent storage for:
// - Block data and indexes
// - UTXO set
// - Chainstate (active chain tip, etc.)
// - Undo data for reorgs

import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import oni_bitcoin.{
  type Amount, type Block, type BlockHash, type BlockHeader, type Hash256,
  type OutPoint, type Transaction, type TxOut, type Txid,
}

// ============================================================================
// Storage Errors
// ============================================================================

/// Storage operation errors
pub type StorageError {
  NotFound
  CorruptData
  DatabaseError(String)
  IoError(String)
  MigrationRequired
  ChecksumMismatch
  OutOfSpace
  Other(String)
}

// ============================================================================
// UTXO Types
// ============================================================================

/// A coin (UTXO) in the database
pub type Coin {
  Coin(
    output: TxOut,
    height: Int,       // Block height where this was created
    is_coinbase: Bool, // Whether from a coinbase transaction
  )
}

/// Create a new Coin
pub fn coin_new(output: TxOut, height: Int, is_coinbase: Bool) -> Coin {
  Coin(output, height, is_coinbase)
}

/// Check if coin is mature for spending (for coinbase)
pub fn coin_is_mature(coin: Coin, current_height: Int) -> Bool {
  case coin.is_coinbase {
    True -> current_height - coin.height >= 100
    False -> True
  }
}

// ============================================================================
// UTXO View Interface
// ============================================================================

/// Interface for reading UTXO set
pub type UtxoView {
  UtxoView(coins: Dict(String, Coin))
}

/// Create an empty UTXO view
pub fn utxo_view_new() -> UtxoView {
  UtxoView(dict.new())
}

/// Lookup a coin by outpoint
pub fn utxo_get(view: UtxoView, outpoint: OutPoint) -> Option(Coin) {
  let key = outpoint_to_key(outpoint)
  dict.get(view.coins, key)
  |> option.from_result
}

/// Add a coin to the view
pub fn utxo_add(view: UtxoView, outpoint: OutPoint, coin: Coin) -> UtxoView {
  let key = outpoint_to_key(outpoint)
  UtxoView(dict.insert(view.coins, key, coin))
}

/// Remove a coin from the view
pub fn utxo_remove(view: UtxoView, outpoint: OutPoint) -> UtxoView {
  let key = outpoint_to_key(outpoint)
  UtxoView(dict.delete(view.coins, key))
}

/// Check if a coin exists
pub fn utxo_has(view: UtxoView, outpoint: OutPoint) -> Bool {
  let key = outpoint_to_key(outpoint)
  dict.has_key(view.coins, key)
}

fn outpoint_to_key(outpoint: OutPoint) -> String {
  oni_bitcoin.txid_to_hex(outpoint.txid) <> ":" <> int_to_string(outpoint.vout)
}

// ============================================================================
// Block Index Types
// ============================================================================

/// Block index entry containing metadata about a block
pub type BlockIndexEntry {
  BlockIndexEntry(
    hash: BlockHash,
    prev_hash: BlockHash,
    height: Int,
    status: BlockStatus,
    num_tx: Int,
    file_pos: Option(Int),  // Position in block file
    undo_pos: Option(Int),  // Position of undo data
  )
}

/// Status of a block in the index
pub type BlockStatus {
  BlockValidUnknown
  BlockValidHeader
  BlockValidTree
  BlockValidTransactions
  BlockValidChain
  BlockValidScripts
  BlockFailed
  BlockFailedChild
}

// ============================================================================
// Chainstate Types
// ============================================================================

/// Current chainstate (active chain tip and metadata)
pub type Chainstate {
  Chainstate(
    best_block: BlockHash,
    best_height: Int,
    total_tx: Int,
    pruned: Bool,
    pruned_height: Option(Int),
  )
}

/// Create initial chainstate with genesis
pub fn chainstate_genesis(genesis_hash: BlockHash) -> Chainstate {
  Chainstate(
    best_block: genesis_hash,
    best_height: 0,
    total_tx: 1,
    pruned: False,
    pruned_height: None,
  )
}

// ============================================================================
// Block Storage Interface
// ============================================================================

/// Block store for raw block data
pub type BlockStore {
  BlockStore(blocks: Dict(String, Block))
}

/// Create a new empty block store
pub fn block_store_new() -> BlockStore {
  BlockStore(dict.new())
}

/// Store a block
pub fn block_store_put(store: BlockStore, hash: BlockHash, block: Block) -> BlockStore {
  let key = oni_bitcoin.block_hash_to_hex(hash)
  BlockStore(dict.insert(store.blocks, key, block))
}

/// Get a block by hash
pub fn block_store_get(store: BlockStore, hash: BlockHash) -> Result(Block, StorageError) {
  let key = oni_bitcoin.block_hash_to_hex(hash)
  case dict.get(store.blocks, key) {
    Ok(block) -> Ok(block)
    Error(_) -> Error(NotFound)
  }
}

/// Check if block exists
pub fn block_store_has(store: BlockStore, hash: BlockHash) -> Bool {
  let key = oni_bitcoin.block_hash_to_hex(hash)
  dict.has_key(store.blocks, key)
}

// ============================================================================
// Block Header Storage
// ============================================================================

/// Header store (separate from full blocks for IBD)
pub type HeaderStore {
  HeaderStore(headers: Dict(String, BlockHeader))
}

/// Create a new header store
pub fn header_store_new() -> HeaderStore {
  HeaderStore(dict.new())
}

/// Store a header
pub fn header_store_put(store: HeaderStore, hash: BlockHash, header: BlockHeader) -> HeaderStore {
  let key = oni_bitcoin.block_hash_to_hex(hash)
  HeaderStore(dict.insert(store.headers, key, header))
}

/// Get a header by hash
pub fn header_store_get(store: HeaderStore, hash: BlockHash) -> Result(BlockHeader, StorageError) {
  let key = oni_bitcoin.block_hash_to_hex(hash)
  case dict.get(store.headers, key) {
    Ok(header) -> Ok(header)
    Error(_) -> Error(NotFound)
  }
}

// ============================================================================
// Undo Data Types
// ============================================================================

/// Undo data for a single transaction
pub type TxUndo {
  TxUndo(prev_outs: List(Coin))
}

/// Undo data for a block (used during reorgs)
pub type BlockUndo {
  BlockUndo(tx_undos: List(TxUndo))
}

/// Create empty block undo
pub fn block_undo_new() -> BlockUndo {
  BlockUndo([])
}

/// Add transaction undo to block undo
pub fn block_undo_add(undo: BlockUndo, tx_undo: TxUndo) -> BlockUndo {
  BlockUndo([tx_undo, ..undo.tx_undos])
}

// ============================================================================
// Database Interface (Placeholder)
// ============================================================================

/// Database configuration
pub type DbConfig {
  DbConfig(
    path: String,
    cache_size: Int,
    max_open_files: Int,
  )
}

/// Default database configuration
pub fn default_db_config(path: String) -> DbConfig {
  DbConfig(
    path: path,
    cache_size: 450 * 1024 * 1024,  // 450MB default
    max_open_files: 64,
  )
}

// ============================================================================
// Public API (Placeholder implementations)
// ============================================================================

/// Get header by hash (placeholder)
pub fn get_header(_hash: BlockHash) -> Result(Nil, StorageError) {
  Error(NotFound)
}

/// Get block by hash (placeholder)
pub fn get_block(_hash: BlockHash) -> Result(Block, StorageError) {
  Error(NotFound)
}

/// Get UTXO by outpoint (placeholder)
pub fn get_utxo(_outpoint: OutPoint) -> Result(Coin, StorageError) {
  Error(NotFound)
}

/// Get current chainstate (placeholder)
pub fn get_chainstate() -> Result(Chainstate, StorageError) {
  Error(NotFound)
}

// ============================================================================
// Helper Functions
// ============================================================================

fn int_to_string(n: Int) -> String {
  case n {
    0 -> "0"
    _ -> do_int_to_string(n, "")
  }
}

fn do_int_to_string(n: Int, acc: String) -> String {
  case n {
    0 -> acc
    _ -> {
      let digit = n % 10
      let char = case digit {
        0 -> "0"
        1 -> "1"
        2 -> "2"
        3 -> "3"
        4 -> "4"
        5 -> "5"
        6 -> "6"
        7 -> "7"
        8 -> "8"
        _ -> "9"
      }
      do_int_to_string(n / 10, char <> acc)
    }
  }
}
