// cache.gleam - Performance caching for consensus operations
//
// This module provides caching infrastructure for expensive operations,
// particularly signature verification which is the main CPU bottleneck
// during block validation.
//
// Design goals:
// - LRU eviction to bound memory usage
// - Thread-safe access for parallel validation
// - Metrics for cache hit/miss rates

import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/result
import oni_bitcoin

// ============================================================================
// Signature Cache
// ============================================================================

/// Cache entry for a verified signature
pub type SigCacheEntry {
  SigCacheEntry(
    /// The hash that was signed
    sighash: BitArray,
    /// The public key used
    pubkey: BitArray,
    /// The signature
    signature: BitArray,
    /// When this was added (for LRU)
    added_at: Int,
  )
}

/// LRU signature verification cache
pub type SigCache {
  SigCache(
    /// Map from sighash -> entry for quick lookup
    entries: Dict(BitArray, SigCacheEntry),
    /// Maximum number of entries
    max_size: Int,
    /// Current size
    size: Int,
    /// Cache statistics
    stats: CacheStats,
  )
}

/// Cache statistics
pub type CacheStats {
  CacheStats(
    hits: Int,
    misses: Int,
    evictions: Int,
  )
}

/// Create a new signature cache with given maximum size
pub fn sig_cache_new(max_size: Int) -> SigCache {
  SigCache(
    entries: dict.new(),
    max_size: max_size,
    size: 0,
    stats: CacheStats(hits: 0, misses: 0, evictions: 0),
  )
}

/// Default cache size (100,000 signatures)
pub const default_cache_size = 100_000

/// Create a cache with default size
pub fn sig_cache_default() -> SigCache {
  sig_cache_new(default_cache_size)
}

/// Build a cache key from sighash, pubkey, and signature
pub fn cache_key(sighash: BitArray, pubkey: BitArray, signature: BitArray) -> BitArray {
  // Concatenate all components for unique key
  <<sighash:bits, pubkey:bits, signature:bits>>
}

/// Check if a signature is in the cache
pub fn sig_cache_contains(
  cache: SigCache,
  sighash: BitArray,
  pubkey: BitArray,
  signature: BitArray,
) -> #(SigCache, Bool) {
  let key = cache_key(sighash, pubkey, signature)

  case dict.get(cache.entries, key) {
    Ok(_) -> {
      // Cache hit - update stats
      let new_stats = CacheStats(
        ..cache.stats,
        hits: cache.stats.hits + 1,
      )
      #(SigCache(..cache, stats: new_stats), True)
    }
    Error(_) -> {
      // Cache miss
      let new_stats = CacheStats(
        ..cache.stats,
        misses: cache.stats.misses + 1,
      )
      #(SigCache(..cache, stats: new_stats), False)
    }
  }
}

/// Add a verified signature to the cache
pub fn sig_cache_add(
  cache: SigCache,
  sighash: BitArray,
  pubkey: BitArray,
  signature: BitArray,
  timestamp: Int,
) -> SigCache {
  let key = cache_key(sighash, pubkey, signature)

  // Check if already present
  case dict.has_key(cache.entries, key) {
    True -> cache
    False -> {
      let entry = SigCacheEntry(
        sighash: sighash,
        pubkey: pubkey,
        signature: signature,
        added_at: timestamp,
      )

      // Evict if at capacity
      let #(cache_evicted, evictions) = case cache.size >= cache.max_size {
        True -> evict_oldest(cache, cache.max_size / 10)  // Evict 10%
        False -> #(cache, 0)
      }

      let new_entries = dict.insert(cache_evicted.entries, key, entry)
      let new_stats = CacheStats(
        ..cache_evicted.stats,
        evictions: cache_evicted.stats.evictions + evictions,
      )

      SigCache(
        entries: new_entries,
        max_size: cache.max_size,
        size: cache_evicted.size + 1,
        stats: new_stats,
      )
    }
  }
}

/// Evict oldest entries from the cache
fn evict_oldest(cache: SigCache, count: Int) -> #(SigCache, Int) {
  // Get all entries sorted by timestamp
  let entries_list = dict.to_list(cache.entries)

  // Sort by added_at timestamp (oldest first)
  let sorted = list.sort(entries_list, fn(a, b) {
    let #(_, entry_a) = a
    let #(_, entry_b) = b
    case entry_a.added_at < entry_b.added_at {
      True -> order.Lt
      False -> case entry_a.added_at > entry_b.added_at {
        True -> order.Gt
        False -> order.Eq
      }
    }
  })

  // Remove oldest entries
  let to_keep = list.drop(sorted, count)
  let new_entries = dict.from_list(to_keep)
  let evicted = cache.size - list.length(to_keep)

  #(
    SigCache(
      ..cache,
      entries: new_entries,
      size: list.length(to_keep),
    ),
    evicted,
  )
}

/// Get cache statistics
pub fn sig_cache_stats(cache: SigCache) -> CacheStats {
  cache.stats
}

/// Calculate cache hit rate as a percentage
pub fn cache_hit_rate(stats: CacheStats) -> Float {
  let total = stats.hits + stats.misses
  case total {
    0 -> 0.0
    _ -> int_to_float(stats.hits * 100) /. int_to_float(total)
  }
}

/// Clear the cache
pub fn sig_cache_clear(cache: SigCache) -> SigCache {
  SigCache(
    entries: dict.new(),
    max_size: cache.max_size,
    size: 0,
    stats: cache.stats,  // Keep stats
  )
}

// ============================================================================
// Batch Signature Verification
// ============================================================================

/// A batch of signatures to verify together
pub type SigBatch {
  SigBatch(
    /// Signatures pending verification
    pending: List(SigBatchEntry),
    /// Maximum batch size before auto-flush
    max_size: Int,
  )
}

/// Entry in a signature batch
pub type SigBatchEntry {
  SigBatchEntry(
    sighash: BitArray,
    pubkey: BitArray,
    signature: BitArray,
  )
}

/// Result of batch verification
pub type BatchVerifyResult {
  /// All signatures in batch are valid
  BatchValid
  /// At least one signature is invalid, with index
  BatchInvalid(failed_index: Int)
  /// Batch is empty
  BatchEmpty
}

/// Create a new signature batch
pub fn sig_batch_new(max_size: Int) -> SigBatch {
  SigBatch(pending: [], max_size: max_size)
}

/// Default batch size (64 signatures)
pub const default_batch_size = 64

/// Create a batch with default size
pub fn sig_batch_default() -> SigBatch {
  sig_batch_new(default_batch_size)
}

/// Add a signature to the batch
pub fn sig_batch_add(
  batch: SigBatch,
  sighash: BitArray,
  pubkey: BitArray,
  signature: BitArray,
) -> SigBatch {
  let entry = SigBatchEntry(
    sighash: sighash,
    pubkey: pubkey,
    signature: signature,
  )
  SigBatch(..batch, pending: [entry, ..batch.pending])
}

/// Check if batch is full and should be verified
pub fn sig_batch_is_full(batch: SigBatch) -> Bool {
  list.length(batch.pending) >= batch.max_size
}

/// Get number of pending signatures
pub fn sig_batch_size(batch: SigBatch) -> Int {
  list.length(batch.pending)
}

/// Clear the batch
pub fn sig_batch_clear(batch: SigBatch) -> SigBatch {
  SigBatch(..batch, pending: [])
}

/// Check batch against cache, returning entries that need verification
pub fn sig_batch_check_cache(
  batch: SigBatch,
  cache: SigCache,
) -> #(SigCache, List(SigBatchEntry)) {
  // Check each entry against cache, collect those not found
  list.fold(batch.pending, #(cache, []), fn(acc, entry) {
    let #(current_cache, uncached) = acc
    let #(new_cache, found) = sig_cache_contains(
      current_cache,
      entry.sighash,
      entry.pubkey,
      entry.signature,
    )
    case found {
      True -> #(new_cache, uncached)
      False -> #(new_cache, [entry, ..uncached])
    }
  })
}

/// Add verified batch results to cache
pub fn sig_batch_add_to_cache(
  entries: List(SigBatchEntry),
  cache: SigCache,
  timestamp: Int,
) -> SigCache {
  list.fold(entries, cache, fn(current_cache, entry) {
    sig_cache_add(
      current_cache,
      entry.sighash,
      entry.pubkey,
      entry.signature,
      timestamp,
    )
  })
}

// ============================================================================
// Script Cache
// ============================================================================

/// Cache for evaluated scripts (for replay protection)
pub type ScriptCacheEntry {
  ScriptCacheEntry(
    /// Transaction ID
    txid: oni_bitcoin.Txid,
    /// Input index
    input_index: Int,
    /// Script verification flags used
    flags: Int,
    /// Result of verification
    valid: Bool,
    /// When this was added (for LRU eviction)
    added_at: Int,
  )
}

/// Script verification cache
pub type ScriptCache {
  ScriptCache(
    entries: Dict(BitArray, ScriptCacheEntry),
    max_size: Int,
    size: Int,
    stats: CacheStats,
  )
}

/// Create a new script cache
pub fn script_cache_new(max_size: Int) -> ScriptCache {
  ScriptCache(
    entries: dict.new(),
    max_size: max_size,
    size: 0,
    stats: CacheStats(hits: 0, misses: 0, evictions: 0),
  )
}

/// Build script cache key
fn script_cache_key(txid: oni_bitcoin.Txid, input_index: Int, flags: Int) -> BitArray {
  let oni_bitcoin.Txid(hash) = txid
  <<hash.bytes:bits, input_index:32, flags:32>>
}

/// Check if a script verification is cached
pub fn script_cache_check(
  cache: ScriptCache,
  txid: oni_bitcoin.Txid,
  input_index: Int,
  flags: Int,
) -> #(ScriptCache, Option(Bool)) {
  let key = script_cache_key(txid, input_index, flags)

  case dict.get(cache.entries, key) {
    Ok(entry) -> {
      let new_stats = CacheStats(..cache.stats, hits: cache.stats.hits + 1)
      #(ScriptCache(..cache, stats: new_stats), Some(entry.valid))
    }
    Error(_) -> {
      let new_stats = CacheStats(..cache.stats, misses: cache.stats.misses + 1)
      #(ScriptCache(..cache, stats: new_stats), None)
    }
  }
}

/// Add a script verification result to the cache with LRU eviction
pub fn script_cache_add(
  cache: ScriptCache,
  txid: oni_bitcoin.Txid,
  input_index: Int,
  flags: Int,
  valid: Bool,
  timestamp: Int,
) -> ScriptCache {
  let key = script_cache_key(txid, input_index, flags)

  case dict.has_key(cache.entries, key) {
    True -> cache
    False -> {
      let entry = ScriptCacheEntry(
        txid: txid,
        input_index: input_index,
        flags: flags,
        valid: valid,
        added_at: timestamp,
      )

      // Evict if at capacity using LRU strategy
      let #(cache_evicted, evictions) = case cache.size >= cache.max_size {
        True -> script_cache_evict_oldest(cache, cache.max_size / 10)  // Evict 10%
        False -> #(cache, 0)
      }

      let new_entries = dict.insert(cache_evicted.entries, key, entry)
      let new_stats = CacheStats(
        ..cache_evicted.stats,
        evictions: cache_evicted.stats.evictions + evictions,
      )

      ScriptCache(
        entries: new_entries,
        max_size: cache.max_size,
        size: cache_evicted.size + 1,
        stats: new_stats,
      )
    }
  }
}

/// Evict oldest entries from the script cache (LRU eviction)
fn script_cache_evict_oldest(cache: ScriptCache, count: Int) -> #(ScriptCache, Int) {
  // Get all entries sorted by timestamp
  let entries_list = dict.to_list(cache.entries)

  // Sort by added_at timestamp (oldest first)
  let sorted = list.sort(entries_list, fn(a, b) {
    let #(_, entry_a) = a
    let #(_, entry_b) = b
    case entry_a.added_at < entry_b.added_at {
      True -> order.Lt
      False -> case entry_a.added_at > entry_b.added_at {
        True -> order.Gt
        False -> order.Eq
      }
    }
  })

  // Remove oldest entries
  let to_keep = list.drop(sorted, count)
  let new_entries = dict.from_list(to_keep)
  let evicted = cache.size - list.length(to_keep)

  #(
    ScriptCache(
      ..cache,
      entries: new_entries,
      size: list.length(to_keep),
    ),
    evicted,
  )
}

/// Clear the script cache
pub fn script_cache_clear(cache: ScriptCache) -> ScriptCache {
  ScriptCache(
    entries: dict.new(),
    max_size: cache.max_size,
    size: 0,
    stats: cache.stats,  // Keep stats
  )
}

/// Get script cache statistics
pub fn script_cache_stats(cache: ScriptCache) -> CacheStats {
  cache.stats
}

// ============================================================================
// Block Index Cache
// ============================================================================

/// Cached block index entry
pub type BlockIndexEntry {
  BlockIndexEntry(
    hash: oni_bitcoin.BlockHash,
    height: Int,
    prev_hash: oni_bitcoin.BlockHash,
    timestamp: Int,
    bits: Int,
    chainwork: BitArray,
  )
}

/// Block index cache for quick header lookups
pub type BlockIndexCache {
  BlockIndexCache(
    /// Hash -> entry mapping
    by_hash: Dict(BitArray, BlockIndexEntry),
    /// Height -> hash mapping (for main chain only)
    by_height: Dict(Int, oni_bitcoin.BlockHash),
    /// Maximum cached entries
    max_size: Int,
    /// Current size
    size: Int,
  )
}

/// Create a new block index cache
pub fn block_index_cache_new(max_size: Int) -> BlockIndexCache {
  BlockIndexCache(
    by_hash: dict.new(),
    by_height: dict.new(),
    max_size: max_size,
    size: 0,
  )
}

/// Get block by hash from cache
pub fn block_index_get(
  cache: BlockIndexCache,
  hash: oni_bitcoin.BlockHash,
) -> Option(BlockIndexEntry) {
  let key = block_hash_to_bytes(hash)
  case dict.get(cache.by_hash, key) {
    Ok(entry) -> Some(entry)
    Error(_) -> None
  }
}

/// Get block hash at height from cache
pub fn block_index_get_at_height(
  cache: BlockIndexCache,
  height: Int,
) -> Option(oni_bitcoin.BlockHash) {
  case dict.get(cache.by_height, height) {
    Ok(hash) -> Some(hash)
    Error(_) -> None
  }
}

/// Add block to index cache
pub fn block_index_add(
  cache: BlockIndexCache,
  entry: BlockIndexEntry,
  is_main_chain: Bool,
) -> BlockIndexCache {
  let key = block_hash_to_bytes(entry.hash)

  case cache.size >= cache.max_size {
    True -> cache  // Don't add if full
    False -> {
      let new_by_hash = dict.insert(cache.by_hash, key, entry)
      let new_by_height = case is_main_chain {
        True -> dict.insert(cache.by_height, entry.height, entry.hash)
        False -> cache.by_height
      }

      BlockIndexCache(
        by_hash: new_by_hash,
        by_height: new_by_height,
        max_size: cache.max_size,
        size: cache.size + 1,
      )
    }
  }
}

// ============================================================================
// Helper Functions
// ============================================================================

fn block_hash_to_bytes(hash: oni_bitcoin.BlockHash) -> BitArray {
  let oni_bitcoin.BlockHash(h) = hash
  h.bytes
}

/// Convert integer to float using Erlang's built-in conversion
/// This is O(1) unlike the previous O(n) implementation
@external(erlang, "erlang", "float")
fn int_to_float(n: Int) -> Float
