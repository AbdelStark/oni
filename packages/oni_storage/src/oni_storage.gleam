// oni_storage - Block storage, UTXO database, and chainstate management
//
// This module provides persistent storage for:
// - Block data and indexes
// - UTXO set with batch operations
// - Chainstate (active chain tip, etc.)
// - Undo data for reorgs
//
// Phase 5 Implementation:
// - In-memory storage with architecturally correct interfaces
// - Block index with chain navigation
// - Chainstate manager with apply/disconnect block
// - UTXO cache with batch updates
// - Undo data generation and application

import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import oni_bitcoin.{
  type Block, type BlockHash, type BlockHeader,
  type OutPoint, type Transaction, type TxIn, type TxOut, type Txid,
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
  BlockNotInMainChain
  InvalidBlockHeight
  UndoDataMissing
  InvalidUndoData
  Other(String)
}

// ============================================================================
// UTXO Types
// ============================================================================

/// A coin (UTXO) in the database
pub type Coin {
  Coin(
    output: TxOut,
    height: Int,
    is_coinbase: Bool,
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

/// Get coin value in satoshis
pub fn coin_value(coin: Coin) -> Int {
  oni_bitcoin.amount_to_sats(coin.output.value)
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

/// Get number of UTXOs in the view
pub fn utxo_count(view: UtxoView) -> Int {
  dict.size(view.coins)
}

/// Convert outpoint to string key
fn outpoint_to_key(outpoint: OutPoint) -> String {
  oni_bitcoin.txid_to_hex(outpoint.txid) <> ":" <> int.to_string(outpoint.vout)
}

// ============================================================================
// UTXO Batch Operations
// ============================================================================

/// A batch of UTXO changes
pub type UtxoBatch {
  UtxoBatch(
    additions: List(#(OutPoint, Coin)),
    removals: List(OutPoint),
  )
}

/// Create an empty batch
pub fn utxo_batch_new() -> UtxoBatch {
  UtxoBatch(additions: [], removals: [])
}

/// Add a coin creation to the batch
pub fn utxo_batch_add(batch: UtxoBatch, outpoint: OutPoint, coin: Coin) -> UtxoBatch {
  UtxoBatch(..batch, additions: [#(outpoint, coin), ..batch.additions])
}

/// Add a coin removal to the batch
pub fn utxo_batch_remove(batch: UtxoBatch, outpoint: OutPoint) -> UtxoBatch {
  UtxoBatch(..batch, removals: [outpoint, ..batch.removals])
}

/// Apply batch to UTXO view
pub fn utxo_apply_batch(view: UtxoView, batch: UtxoBatch) -> UtxoView {
  // First apply removals
  let after_removals = list.fold(batch.removals, view, fn(v, outpoint) {
    utxo_remove(v, outpoint)
  })
  // Then apply additions
  list.fold(batch.additions, after_removals, fn(v, entry) {
    let #(outpoint, coin) = entry
    utxo_add(v, outpoint, coin)
  })
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
    total_work: Int,
    file_pos: Option(Int),
    undo_pos: Option(Int),
    timestamp: Int,
    bits: Int,
    nonce: Int,
    version: Int,
  )
}

/// Status of a block in the index
pub type BlockStatus {
  /// Header valid, data unknown
  BlockValidHeader
  /// Part of a valid tree (connected to genesis)
  BlockValidTree
  /// Transactions available and validated
  BlockValidTransactions
  /// Connected to active chain
  BlockValidChain
  /// All scripts verified
  BlockValidScripts
  /// Block failed validation
  BlockFailed
  /// Descendant of failed block
  BlockFailedChild
}

/// Create a block index entry from a block header
pub fn block_index_entry_from_header(
  header: BlockHeader,
  hash: BlockHash,
  height: Int,
  prev_work: Int,
) -> BlockIndexEntry {
  BlockIndexEntry(
    hash: hash,
    prev_hash: header.prev_block,
    height: height,
    status: BlockValidHeader,
    num_tx: 0,
    total_work: prev_work + calculate_work(header.bits),
    file_pos: None,
    undo_pos: None,
    timestamp: header.timestamp,
    bits: header.bits,
    nonce: header.nonce,
    version: header.version,
  )
}

/// Calculate work from difficulty bits (simplified)
fn calculate_work(bits: Int) -> Int {
  // Simplified work calculation
  // In reality this involves 256-bit arithmetic
  let exp = int.bitwise_shift_right(bits, 24)
  let mantissa = int.bitwise_and(bits, 0x00FFFFFF)
  case exp > 3 && mantissa > 0 {
    True -> {
      // Work is approximately 2^256 / target
      // Simplified: use inverse of target magnitude
      let target_magnitude = mantissa * pow2(8 * { exp - 3 })
      case target_magnitude > 0 {
        True -> max_work() / target_magnitude
        False -> 1
      }
    }
    False -> 1
  }
}

fn max_work() -> Int {
  // Simplified max work value
  0x0FFFFFFFFFFFFFFF
}

fn pow2(n: Int) -> Int {
  case n <= 0 {
    True -> 1
    False -> 2 * pow2(n - 1)
  }
}

// ============================================================================
// Block Index
// ============================================================================

/// Block index for chain navigation
pub type BlockIndex {
  BlockIndex(
    entries: Dict(String, BlockIndexEntry),
    by_height: Dict(Int, String),
    tip: Option(BlockHash),
  )
}

/// Create a new block index
pub fn block_index_new() -> BlockIndex {
  BlockIndex(
    entries: dict.new(),
    by_height: dict.new(),
    tip: None,
  )
}

/// Add an entry to the block index
pub fn block_index_add(index: BlockIndex, entry: BlockIndexEntry) -> BlockIndex {
  let key = block_hash_to_key(entry.hash)
  let new_entries = dict.insert(index.entries, key, entry)

  // Update by_height for main chain entries
  let new_by_height = case entry.status {
    BlockValidChain | BlockValidScripts ->
      dict.insert(index.by_height, entry.height, key)
    _ -> index.by_height
  }

  BlockIndex(..index, entries: new_entries, by_height: new_by_height)
}

/// Get entry by hash
pub fn block_index_get(index: BlockIndex, hash: BlockHash) -> Option(BlockIndexEntry) {
  let key = block_hash_to_key(hash)
  dict.get(index.entries, key)
  |> option.from_result
}

/// Get entry by height (main chain only)
pub fn block_index_get_by_height(index: BlockIndex, height: Int) -> Option(BlockIndexEntry) {
  case dict.get(index.by_height, height) {
    Ok(key) -> dict.get(index.entries, key) |> option.from_result
    Error(_) -> None
  }
}

/// Get the tip entry
pub fn block_index_get_tip(index: BlockIndex) -> Option(BlockIndexEntry) {
  case index.tip {
    Some(hash) -> block_index_get(index, hash)
    None -> None
  }
}

/// Set the tip
pub fn block_index_set_tip(index: BlockIndex, hash: BlockHash) -> BlockIndex {
  BlockIndex(..index, tip: Some(hash))
}

/// Update entry status
pub fn block_index_update_status(
  index: BlockIndex,
  hash: BlockHash,
  status: BlockStatus,
) -> BlockIndex {
  let key = block_hash_to_key(hash)
  case dict.get(index.entries, key) {
    Ok(entry) -> {
      let updated = BlockIndexEntry(..entry, status: status)
      let new_entries = dict.insert(index.entries, key, updated)

      // Update by_height if now in main chain
      let new_by_height = case status {
        BlockValidChain | BlockValidScripts ->
          dict.insert(index.by_height, entry.height, key)
        _ -> index.by_height
      }

      BlockIndex(..index, entries: new_entries, by_height: new_by_height)
    }
    Error(_) -> index
  }
}

/// Get ancestor at specific height
pub fn block_index_get_ancestor(
  index: BlockIndex,
  hash: BlockHash,
  target_height: Int,
) -> Option(BlockIndexEntry) {
  case block_index_get(index, hash) {
    None -> None
    Some(entry) -> {
      case target_height > entry.height {
        True -> None
        False -> get_ancestor_walk(index, entry, target_height)
      }
    }
  }
}

fn get_ancestor_walk(
  index: BlockIndex,
  entry: BlockIndexEntry,
  target_height: Int,
) -> Option(BlockIndexEntry) {
  case entry.height == target_height {
    True -> Some(entry)
    False -> {
      case block_index_get(index, entry.prev_hash) {
        None -> None
        Some(prev) -> get_ancestor_walk(index, prev, target_height)
      }
    }
  }
}

/// Find common ancestor of two blocks
pub fn block_index_find_common_ancestor(
  index: BlockIndex,
  hash1: BlockHash,
  hash2: BlockHash,
) -> Option(BlockIndexEntry) {
  case block_index_get(index, hash1), block_index_get(index, hash2) {
    Some(entry1), Some(entry2) -> find_common_ancestor_walk(index, entry1, entry2)
    _, _ -> None
  }
}

fn find_common_ancestor_walk(
  index: BlockIndex,
  entry1: BlockIndexEntry,
  entry2: BlockIndexEntry,
) -> Option(BlockIndexEntry) {
  case block_hash_eq(entry1.hash, entry2.hash) {
    True -> Some(entry1)
    False -> {
      case entry1.height > entry2.height {
        True -> {
          case block_index_get(index, entry1.prev_hash) {
            None -> None
            Some(prev1) -> find_common_ancestor_walk(index, prev1, entry2)
          }
        }
        False -> {
          case entry2.height > entry1.height {
            True -> {
              case block_index_get(index, entry2.prev_hash) {
                None -> None
                Some(prev2) -> find_common_ancestor_walk(index, entry1, prev2)
              }
            }
            False -> {
              // Same height, move both back
              case block_index_get(index, entry1.prev_hash),
                   block_index_get(index, entry2.prev_hash) {
                Some(prev1), Some(prev2) ->
                  find_common_ancestor_walk(index, prev1, prev2)
                _, _ -> None
              }
            }
          }
        }
      }
    }
  }
}

/// Check if block1 is ancestor of block2
pub fn block_index_is_ancestor(
  index: BlockIndex,
  ancestor_hash: BlockHash,
  descendant_hash: BlockHash,
) -> Bool {
  case block_index_get(index, ancestor_hash), block_index_get(index, descendant_hash) {
    Some(ancestor), Some(descendant) -> {
      case ancestor.height > descendant.height {
        True -> False
        False -> {
          case block_index_get_ancestor(index, descendant_hash, ancestor.height) {
            Some(at_height) -> block_hash_eq(at_height.hash, ancestor_hash)
            None -> False
          }
        }
      }
    }
    _, _ -> False
  }
}

fn block_hash_to_key(hash: BlockHash) -> String {
  oni_bitcoin.block_hash_to_hex(hash)
}

fn block_hash_eq(h1: BlockHash, h2: BlockHash) -> Bool {
  oni_bitcoin.block_hash_to_hex(h1) == oni_bitcoin.block_hash_to_hex(h2)
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
    total_coins: Int,
    total_amount: Int,
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
    total_coins: 1,
    total_amount: 5_000_000_000,
    pruned: False,
    pruned_height: None,
  )
}

// ============================================================================
// Undo Data Types
// ============================================================================

/// Undo data for a single transaction input (spent coin)
pub type TxInputUndo {
  TxInputUndo(
    coin: Coin,
  )
}

/// Undo data for a single transaction
pub type TxUndo {
  TxUndo(spent_coins: List(TxInputUndo))
}

/// Create empty tx undo
pub fn tx_undo_new() -> TxUndo {
  TxUndo(spent_coins: [])
}

/// Add a spent coin to tx undo
pub fn tx_undo_add_spent(undo: TxUndo, coin: Coin) -> TxUndo {
  TxUndo(spent_coins: [TxInputUndo(coin), ..undo.spent_coins])
}

/// Undo data for a block (used during reorgs)
pub type BlockUndo {
  BlockUndo(tx_undos: List(TxUndo))
}

/// Create empty block undo
pub fn block_undo_new() -> BlockUndo {
  BlockUndo(tx_undos: [])
}

/// Add transaction undo to block undo
pub fn block_undo_add(undo: BlockUndo, tx_undo: TxUndo) -> BlockUndo {
  BlockUndo(tx_undos: [tx_undo, ..undo.tx_undos])
}

/// Finalize block undo (reverse order for proper disconnection)
pub fn block_undo_finalize(undo: BlockUndo) -> BlockUndo {
  BlockUndo(tx_undos: list.reverse(undo.tx_undos))
}

/// Get tx undos in disconnect order (reverse of connect order)
pub fn block_undo_get_tx_undos(undo: BlockUndo) -> List(TxUndo) {
  list.reverse(undo.tx_undos)
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

/// Remove a block
pub fn block_store_remove(store: BlockStore, hash: BlockHash) -> BlockStore {
  let key = oni_bitcoin.block_hash_to_hex(hash)
  BlockStore(dict.delete(store.blocks, key))
}

/// Get block count
pub fn block_store_count(store: BlockStore) -> Int {
  dict.size(store.blocks)
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

/// Check if header exists
pub fn header_store_has(store: HeaderStore, hash: BlockHash) -> Bool {
  let key = oni_bitcoin.block_hash_to_hex(hash)
  dict.has_key(store.headers, key)
}

// ============================================================================
// Undo Data Storage
// ============================================================================

/// Store for block undo data
pub type UndoStore {
  UndoStore(undos: Dict(String, BlockUndo))
}

/// Create a new undo store
pub fn undo_store_new() -> UndoStore {
  UndoStore(dict.new())
}

/// Store undo data for a block
pub fn undo_store_put(store: UndoStore, hash: BlockHash, undo: BlockUndo) -> UndoStore {
  let key = oni_bitcoin.block_hash_to_hex(hash)
  UndoStore(dict.insert(store.undos, key, undo))
}

/// Get undo data for a block
pub fn undo_store_get(store: UndoStore, hash: BlockHash) -> Result(BlockUndo, StorageError) {
  let key = oni_bitcoin.block_hash_to_hex(hash)
  case dict.get(store.undos, key) {
    Ok(undo) -> Ok(undo)
    Error(_) -> Error(UndoDataMissing)
  }
}

/// Remove undo data
pub fn undo_store_remove(store: UndoStore, hash: BlockHash) -> UndoStore {
  let key = oni_bitcoin.block_hash_to_hex(hash)
  UndoStore(dict.delete(store.undos, key))
}

// ============================================================================
// Chainstate Manager
// ============================================================================

/// Complete storage state
pub type Storage {
  Storage(
    block_store: BlockStore,
    header_store: HeaderStore,
    undo_store: UndoStore,
    block_index: BlockIndex,
    utxo_view: UtxoView,
    chainstate: Chainstate,
  )
}

/// Create new storage with genesis block
pub fn storage_new(genesis_hash: BlockHash) -> Storage {
  let chainstate = chainstate_genesis(genesis_hash)
  let block_index = block_index_new()

  Storage(
    block_store: block_store_new(),
    header_store: header_store_new(),
    undo_store: undo_store_new(),
    block_index: block_index,
    utxo_view: utxo_view_new(),
    chainstate: chainstate,
  )
}

/// Get the current tip hash
pub fn storage_get_tip(storage: Storage) -> BlockHash {
  storage.chainstate.best_block
}

/// Get the current tip height
pub fn storage_get_height(storage: Storage) -> Int {
  storage.chainstate.best_height
}

/// Get UTXO by outpoint
pub fn storage_get_utxo(storage: Storage, outpoint: OutPoint) -> Option(Coin) {
  utxo_get(storage.utxo_view, outpoint)
}

/// Connect a block to the chain
/// Returns updated storage and the block undo data
pub fn storage_connect_block(
  storage: Storage,
  block: Block,
  block_hash: BlockHash,
  height: Int,
) -> Result(#(Storage, BlockUndo), StorageError) {
  // Validate height
  case height == storage.chainstate.best_height + 1 {
    False -> Error(InvalidBlockHeight)
    True -> {
      // Process all transactions
      let result = connect_block_txs(
        block.transactions,
        storage.utxo_view,
        height,
        block_undo_new(),
      )

      case result {
        Error(e) -> Error(e)
        Ok(#(new_utxo_view, block_undo)) -> {
          // Store the block
          let new_block_store = block_store_put(storage.block_store, block_hash, block)

          // Store undo data
          let finalized_undo = block_undo_finalize(block_undo)
          let new_undo_store = undo_store_put(storage.undo_store, block_hash, finalized_undo)

          // Update block index
          let entry = block_index_entry_from_header(
            block.header,
            block_hash,
            height,
            get_prev_work(storage.block_index, block.header.prev_block),
          )
          let entry_with_status = BlockIndexEntry(
            ..entry,
            status: BlockValidScripts,
            num_tx: list.length(block.transactions),
          )
          let new_block_index = block_index_add(storage.block_index, entry_with_status)
          let new_block_index = block_index_set_tip(new_block_index, block_hash)

          // Update chainstate
          let new_chainstate = Chainstate(
            ..storage.chainstate,
            best_block: block_hash,
            best_height: height,
            total_tx: storage.chainstate.total_tx + list.length(block.transactions),
            total_coins: utxo_count(new_utxo_view),
          )

          let new_storage = Storage(
            ..storage,
            block_store: new_block_store,
            undo_store: new_undo_store,
            block_index: new_block_index,
            utxo_view: new_utxo_view,
            chainstate: new_chainstate,
          )

          Ok(#(new_storage, finalized_undo))
        }
      }
    }
  }
}

fn get_prev_work(index: BlockIndex, prev_hash: BlockHash) -> Int {
  case block_index_get(index, prev_hash) {
    Some(entry) -> entry.total_work
    None -> 0
  }
}

/// Process transactions for block connection
fn connect_block_txs(
  txs: List(Transaction),
  utxo_view: UtxoView,
  height: Int,
  block_undo: BlockUndo,
) -> Result(#(UtxoView, BlockUndo), StorageError) {
  case txs {
    [] -> Ok(#(utxo_view, block_undo))
    [tx, ..rest] -> {
      case connect_tx(tx, utxo_view, height) {
        Error(e) -> Error(e)
        Ok(#(new_view, tx_undo)) -> {
          let new_block_undo = block_undo_add(block_undo, tx_undo)
          connect_block_txs(rest, new_view, height, new_block_undo)
        }
      }
    }
  }
}

/// Connect a single transaction
fn connect_tx(
  tx: Transaction,
  utxo_view: UtxoView,
  height: Int,
) -> Result(#(UtxoView, TxUndo), StorageError) {
  let is_coinbase = is_coinbase_tx(tx)

  // Spend inputs (not for coinbase)
  let spend_result = case is_coinbase {
    True -> Ok(#(utxo_view, tx_undo_new()))
    False -> spend_inputs(tx.inputs, utxo_view, tx_undo_new())
  }

  case spend_result {
    Error(e) -> Error(e)
    Ok(#(after_spend, tx_undo)) -> {
      // Add outputs
      let txid = compute_txid(tx)
      let after_add = add_outputs(tx.outputs, utxo_view: after_spend, txid: txid, height: height, is_coinbase: is_coinbase, vout: 0)
      Ok(#(after_add, tx_undo))
    }
  }
}

/// Spend transaction inputs
fn spend_inputs(
  inputs: List(TxIn),
  utxo_view: UtxoView,
  tx_undo: TxUndo,
) -> Result(#(UtxoView, TxUndo), StorageError) {
  case inputs {
    [] -> Ok(#(utxo_view, tx_undo))
    [input, ..rest] -> {
      case utxo_get(utxo_view, input.prevout) {
        None -> Error(NotFound)
        Some(coin) -> {
          let new_view = utxo_remove(utxo_view, input.prevout)
          let new_undo = tx_undo_add_spent(tx_undo, coin)
          spend_inputs(rest, new_view, new_undo)
        }
      }
    }
  }
}

/// Add transaction outputs
fn add_outputs(
  outputs: List(TxOut),
  utxo_view view: UtxoView,
  txid txid: Txid,
  height height: Int,
  is_coinbase is_coinbase: Bool,
  vout vout: Int,
) -> UtxoView {
  case outputs {
    [] -> view
    [output, ..rest] -> {
      let outpoint = oni_bitcoin.outpoint_new(txid, vout)
      let coin = coin_new(output, height, is_coinbase)
      let new_view = utxo_add(view, outpoint, coin)
      add_outputs(rest, utxo_view: new_view, txid: txid, height: height, is_coinbase: is_coinbase, vout: vout + 1)
    }
  }
}

/// Disconnect a block from the chain
pub fn storage_disconnect_block(
  storage: Storage,
  block_hash: BlockHash,
) -> Result(Storage, StorageError) {
  // Verify this is the tip
  case block_hash_eq(block_hash, storage.chainstate.best_block) {
    False -> Error(BlockNotInMainChain)
    True -> {
      // Get the block
      case block_store_get(storage.block_store, block_hash) {
        Error(e) -> Error(e)
        Ok(block) -> {
          // Get undo data
          case undo_store_get(storage.undo_store, block_hash) {
            Error(e) -> Error(e)
            Ok(block_undo) -> {
              // Disconnect transactions in reverse order
              let txs_reversed = list.reverse(block.transactions)
              let tx_undos = block_undo_get_tx_undos(block_undo)

              case disconnect_block_txs(txs_reversed, tx_undos, storage.utxo_view) {
                Error(e) -> Error(e)
                Ok(new_utxo_view) -> {
                  // Get previous block info
                  let prev_hash = block.header.prev_block
                  let prev_height = storage.chainstate.best_height - 1

                  // Update block index
                  let new_block_index = block_index_update_status(
                    storage.block_index,
                    block_hash,
                    BlockValidTransactions,
                  )
                  let new_block_index = block_index_set_tip(new_block_index, prev_hash)

                  // Update chainstate
                  let new_chainstate = Chainstate(
                    ..storage.chainstate,
                    best_block: prev_hash,
                    best_height: prev_height,
                    total_tx: storage.chainstate.total_tx - list.length(block.transactions),
                    total_coins: utxo_count(new_utxo_view),
                  )

                  // Remove undo data
                  let new_undo_store = undo_store_remove(storage.undo_store, block_hash)

                  let new_storage = Storage(
                    ..storage,
                    undo_store: new_undo_store,
                    block_index: new_block_index,
                    utxo_view: new_utxo_view,
                    chainstate: new_chainstate,
                  )

                  Ok(new_storage)
                }
              }
            }
          }
        }
      }
    }
  }
}

/// Disconnect transactions in reverse order
fn disconnect_block_txs(
  txs: List(Transaction),
  tx_undos: List(TxUndo),
  utxo_view: UtxoView,
) -> Result(UtxoView, StorageError) {
  case txs, tx_undos {
    [], _ -> Ok(utxo_view)
    [tx, ..rest_txs], [tx_undo, ..rest_undos] -> {
      case disconnect_tx(tx, tx_undo, utxo_view) {
        Error(e) -> Error(e)
        Ok(new_view) -> disconnect_block_txs(rest_txs, rest_undos, new_view)
      }
    }
    _, _ -> Error(InvalidUndoData)
  }
}

/// Disconnect a single transaction
fn disconnect_tx(
  tx: Transaction,
  tx_undo: TxUndo,
  utxo_view: UtxoView,
) -> Result(UtxoView, StorageError) {
  // Remove outputs (in reverse order)
  let txid = compute_txid(tx)
  let outputs_reversed = list.reverse(tx.outputs)
  let num_outputs = list.length(tx.outputs)
  let after_remove = remove_outputs(outputs_reversed, utxo_view, txid, num_outputs - 1)

  // Restore spent inputs (not for coinbase)
  case is_coinbase_tx(tx) {
    True -> Ok(after_remove)
    False -> restore_inputs(tx.inputs, tx_undo.spent_coins, after_remove)
  }
}

/// Remove transaction outputs
fn remove_outputs(
  outputs: List(TxOut),
  utxo_view: UtxoView,
  txid: Txid,
  vout: Int,
) -> UtxoView {
  case outputs {
    [] -> utxo_view
    [_, ..rest] -> {
      let outpoint = oni_bitcoin.outpoint_new(txid, vout)
      let new_view = utxo_remove(utxo_view, outpoint)
      remove_outputs(rest, new_view, txid, vout - 1)
    }
  }
}

/// Restore spent inputs
fn restore_inputs(
  inputs: List(TxIn),
  spent_coins: List(TxInputUndo),
  utxo_view: UtxoView,
) -> Result(UtxoView, StorageError) {
  case inputs, spent_coins {
    [], [] -> Ok(utxo_view)
    [input, ..rest_inputs], [TxInputUndo(coin), ..rest_coins] -> {
      let new_view = utxo_add(utxo_view, input.prevout, coin)
      restore_inputs(rest_inputs, rest_coins, new_view)
    }
    _, _ -> Error(InvalidUndoData)
  }
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
    cache_size: 450 * 1024 * 1024,
    max_open_files: 64,
  )
}

// ============================================================================
// Public API (Legacy compatibility)
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

/// Check if transaction is coinbase
fn is_coinbase_tx(tx: Transaction) -> Bool {
  case tx.inputs {
    [input] -> oni_bitcoin.outpoint_is_null(input.prevout)
    _ -> False
  }
}

/// Compute transaction ID (double SHA256 of legacy serialization)
fn compute_txid(tx: Transaction) -> Txid {
  let serialized = serialize_tx_legacy(tx)
  let hash = oni_bitcoin.hash256_digest(serialized)
  oni_bitcoin.Txid(hash)
}

/// Serialize transaction without witness
fn serialize_tx_legacy(tx: Transaction) -> BitArray {
  let inputs_data = list.fold(tx.inputs, <<>>, fn(acc, input) {
    let script = oni_bitcoin.script_to_bytes(input.script_sig)
    let input_data = <<
      input.prevout.txid.hash.bytes:bits,
      input.prevout.vout:32-little,
      { oni_bitcoin.compact_size_encode(bit_array_byte_size(script)) }:bits,
      script:bits,
      input.sequence:32-little,
    >>
    <<acc:bits, input_data:bits>>
  })

  let outputs_data = list.fold(tx.outputs, <<>>, fn(acc, output) {
    let script = oni_bitcoin.script_to_bytes(output.script_pubkey)
    let value = oni_bitcoin.amount_to_sats(output.value)
    let output_data = <<
      value:64-little,
      { oni_bitcoin.compact_size_encode(bit_array_byte_size(script)) }:bits,
      script:bits,
    >>
    <<acc:bits, output_data:bits>>
  })

  <<
    tx.version:32-little,
    { oni_bitcoin.compact_size_encode(list.length(tx.inputs)) }:bits,
    inputs_data:bits,
    { oni_bitcoin.compact_size_encode(list.length(tx.outputs)) }:bits,
    outputs_data:bits,
    tx.lock_time:32-little,
  >>
}

/// Get byte size of BitArray
fn bit_array_byte_size(data: BitArray) -> Int {
  byte_size_impl(data, 0)
}

fn byte_size_impl(data: BitArray, acc: Int) -> Int {
  case data {
    <<_:8, rest:bits>> -> byte_size_impl(rest, acc + 1)
    <<>> -> acc
    _ -> acc
  }
}
