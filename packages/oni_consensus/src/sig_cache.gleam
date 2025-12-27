// sig_cache.gleam - Signature verification cache
//
// This module provides a cache for signature verification results to avoid
// redundant cryptographic operations. Signature verification is the most
// expensive operation during transaction validation, so caching results
// significantly improves performance during:
// - Block validation (many transactions)
// - Mempool acceptance (same tx may be checked multiple times)
// - Reorgs (reconnecting blocks with already-verified transactions)
//
// The cache is keyed by (txid/wtxid, input_index, sighash) to ensure
// correct behavior across different validation contexts.

import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import oni_bitcoin.{type Hash256, type Txid}

// ============================================================================
// Constants
// ============================================================================

/// Maximum number of entries in the cache
pub const default_max_entries = 100_000

/// Default cache cleanup interval (in entries added)
pub const cleanup_interval = 10_000

/// LRU eviction batch size
pub const eviction_batch_size = 1000

// ============================================================================
// Cache Key
// ============================================================================

/// Cache key uniquely identifies a signature verification
pub type CacheKey {
  CacheKey(
    /// Transaction ID (txid or wtxid depending on context)
    txid: Txid,
    /// Input index being validated
    input_index: Int,
    /// Sighash used for verification
    sighash: Hash256,
  )
}

/// Create a cache key
pub fn cache_key_new(
  txid: Txid,
  input_index: Int,
  sighash: Hash256,
) -> CacheKey {
  CacheKey(
    txid: txid,
    input_index: input_index,
    sighash: sighash,
  )
}

/// Convert cache key to string for dict lookup
pub fn cache_key_to_string(key: CacheKey) -> String {
  oni_bitcoin.txid_to_hex(key.txid) <>
    ":" <>
    int.to_string(key.input_index) <>
    ":" <>
    oni_bitcoin.hash256_to_hex(key.sighash)
}

// ============================================================================
// Cache Entry
// ============================================================================

/// A cached signature verification result
pub type CacheEntry {
  CacheEntry(
    /// Whether the signature was valid
    valid: Bool,
    /// Timestamp when this entry was added
    added_at: Int,
    /// Last access timestamp (for LRU)
    last_access: Int,
    /// Number of times this entry was accessed
    access_count: Int,
  )
}

/// Create a new cache entry
pub fn cache_entry_new(valid: Bool, timestamp: Int) -> CacheEntry {
  CacheEntry(
    valid: valid,
    added_at: timestamp,
    last_access: timestamp,
    access_count: 0,
  )
}

/// Mark entry as accessed
pub fn cache_entry_access(entry: CacheEntry, timestamp: Int) -> CacheEntry {
  CacheEntry(
    ..entry,
    last_access: timestamp,
    access_count: entry.access_count + 1,
  )
}

// ============================================================================
// Signature Cache
// ============================================================================

/// The signature verification cache
pub type SigCache {
  SigCache(
    /// Cached entries by key
    entries: Dict(String, CacheEntry),
    /// Maximum number of entries
    max_entries: Int,
    /// Current number of entries
    size: Int,
    /// Statistics
    stats: CacheStats,
    /// Counter for cleanup scheduling
    ops_since_cleanup: Int,
  )
}

/// Cache statistics
pub type CacheStats {
  CacheStats(
    /// Number of cache hits
    hits: Int,
    /// Number of cache misses
    misses: Int,
    /// Number of entries evicted
    evictions: Int,
    /// Number of entries added
    additions: Int,
    /// Number of invalid signatures cached
    invalid_cached: Int,
  )
}

/// Create a new signature cache
pub fn sig_cache_new() -> SigCache {
  sig_cache_with_size(default_max_entries)
}

/// Create a signature cache with custom size
pub fn sig_cache_with_size(max_entries: Int) -> SigCache {
  SigCache(
    entries: dict.new(),
    max_entries: max_entries,
    size: 0,
    stats: CacheStats(
      hits: 0,
      misses: 0,
      evictions: 0,
      additions: 0,
      invalid_cached: 0,
    ),
    ops_since_cleanup: 0,
  )
}

/// Look up a signature verification result
pub fn sig_cache_get(
  cache: SigCache,
  key: CacheKey,
  timestamp: Int,
) -> #(SigCache, Option(Bool)) {
  let key_str = cache_key_to_string(key)

  case dict.get(cache.entries, key_str) {
    Error(_) -> {
      // Cache miss
      let new_stats = CacheStats(..cache.stats, misses: cache.stats.misses + 1)
      #(SigCache(..cache, stats: new_stats), None)
    }
    Ok(entry) -> {
      // Cache hit - update access time
      let updated_entry = cache_entry_access(entry, timestamp)
      let new_entries = dict.insert(cache.entries, key_str, updated_entry)
      let new_stats = CacheStats(..cache.stats, hits: cache.stats.hits + 1)
      #(
        SigCache(..cache, entries: new_entries, stats: new_stats),
        Some(entry.valid),
      )
    }
  }
}

/// Store a signature verification result
pub fn sig_cache_put(
  cache: SigCache,
  key: CacheKey,
  valid: Bool,
  timestamp: Int,
) -> SigCache {
  let key_str = cache_key_to_string(key)

  // Check if already exists
  case dict.has_key(cache.entries, key_str) {
    True -> cache  // Don't update existing entries
    False -> {
      // Check if we need to evict
      let cache_after_eviction = case cache.size >= cache.max_entries {
        True -> evict_lru(cache, timestamp)
        False -> cache
      }

      // Add new entry
      let entry = cache_entry_new(valid, timestamp)
      let new_entries = dict.insert(cache_after_eviction.entries, key_str, entry)

      let new_stats = CacheStats(
        ..cache_after_eviction.stats,
        additions: cache_after_eviction.stats.additions + 1,
        invalid_cached: case valid {
          False -> cache_after_eviction.stats.invalid_cached + 1
          True -> cache_after_eviction.stats.invalid_cached
        },
      )

      let new_ops = cache_after_eviction.ops_since_cleanup + 1

      // Periodic cleanup if needed
      let final_cache = SigCache(
        ..cache_after_eviction,
        entries: new_entries,
        size: cache_after_eviction.size + 1,
        stats: new_stats,
        ops_since_cleanup: new_ops,
      )

      case new_ops >= cleanup_interval {
        True -> cleanup_old_entries(final_cache, timestamp)
        False -> final_cache
      }
    }
  }
}

/// Check if key exists in cache
pub fn sig_cache_contains(cache: SigCache, key: CacheKey) -> Bool {
  let key_str = cache_key_to_string(key)
  dict.has_key(cache.entries, key_str)
}

/// Get cache statistics
pub fn sig_cache_stats(cache: SigCache) -> CacheStats {
  cache.stats
}

/// Get cache size
pub fn sig_cache_size(cache: SigCache) -> Int {
  cache.size
}

/// Get hit ratio
pub fn sig_cache_hit_ratio(cache: SigCache) -> Float {
  let total = cache.stats.hits + cache.stats.misses
  case total {
    0 -> 0.0
    _ -> int.to_float(cache.stats.hits) /. int.to_float(total)
  }
}

/// Clear the cache
pub fn sig_cache_clear(cache: SigCache) -> SigCache {
  SigCache(
    ..cache,
    entries: dict.new(),
    size: 0,
    ops_since_cleanup: 0,
  )
}

// ============================================================================
// Eviction and Cleanup
// ============================================================================

/// Evict least recently used entries
fn evict_lru(cache: SigCache, _timestamp: Int) -> SigCache {
  // Get all entries with their keys and sort by last_access
  let entries_list = dict.to_list(cache.entries)
  let sorted = list.sort(entries_list, fn(a, b) {
    let #(_key_a, entry_a) = a
    let #(_key_b, entry_b) = b
    int.compare(entry_a.last_access, entry_b.last_access)
  })

  // Remove oldest entries
  let to_remove = list.take(sorted, eviction_batch_size)
  let keys_to_remove = list.map(to_remove, fn(pair) {
    let #(key, _entry) = pair
    key
  })

  let new_entries = list.fold(keys_to_remove, cache.entries, fn(acc, key) {
    dict.delete(acc, key)
  })

  let removed_count = list.length(keys_to_remove)

  SigCache(
    ..cache,
    entries: new_entries,
    size: cache.size - removed_count,
    stats: CacheStats(
      ..cache.stats,
      evictions: cache.stats.evictions + removed_count,
    ),
  )
}

/// Clean up old entries (called periodically)
fn cleanup_old_entries(cache: SigCache, timestamp: Int) -> SigCache {
  // For simplicity, just reset the counter
  // In a full implementation, we might remove very old entries
  // or entries that haven't been accessed in a long time
  SigCache(..cache, ops_since_cleanup: 0)
}

// ============================================================================
// Batch Operations
// ============================================================================

/// Result of batch signature verification
pub type BatchResult {
  BatchResult(
    /// Keys that were found in cache (with their validity)
    cached: List(#(CacheKey, Bool)),
    /// Keys that need verification
    uncached: List(CacheKey),
  )
}

/// Check multiple keys at once
pub fn sig_cache_batch_get(
  cache: SigCache,
  keys: List(CacheKey),
  timestamp: Int,
) -> #(SigCache, BatchResult) {
  let initial = BatchResult(cached: [], uncached: [])

  let #(final_cache, result) = list.fold(keys, #(cache, initial), fn(acc, key) {
    let #(current_cache, current_result) = acc

    case sig_cache_get(current_cache, key, timestamp) {
      #(new_cache, Some(valid)) -> {
        let new_result = BatchResult(
          ..current_result,
          cached: [#(key, valid), ..current_result.cached],
        )
        #(new_cache, new_result)
      }
      #(new_cache, None) -> {
        let new_result = BatchResult(
          ..current_result,
          uncached: [key, ..current_result.uncached],
        )
        #(new_cache, new_result)
      }
    }
  })

  #(final_cache, BatchResult(
    cached: list.reverse(result.cached),
    uncached: list.reverse(result.uncached),
  ))
}

/// Store multiple results at once
pub fn sig_cache_batch_put(
  cache: SigCache,
  results: List(#(CacheKey, Bool)),
  timestamp: Int,
) -> SigCache {
  list.fold(results, cache, fn(acc, pair) {
    let #(key, valid) = pair
    sig_cache_put(acc, key, valid, timestamp)
  })
}

// ============================================================================
// Transaction-level Operations
// ============================================================================

/// Cache all signatures for a transaction
pub fn sig_cache_put_tx(
  cache: SigCache,
  txid: Txid,
  num_inputs: Int,
  sighashes: List(Hash256),
  all_valid: Bool,
  timestamp: Int,
) -> SigCache {
  // Create entries for each input
  let indexed_hashes = list.index_map(sighashes, fn(hash, idx) { #(idx, hash) })

  list.fold(indexed_hashes, cache, fn(acc, pair) {
    let #(idx, hash) = pair
    case idx < num_inputs {
      True -> {
        let key = cache_key_new(txid, idx, hash)
        sig_cache_put(acc, key, all_valid, timestamp)
      }
      False -> acc
    }
  })
}

/// Check if all inputs for a transaction are cached and valid
pub fn sig_cache_check_tx(
  cache: SigCache,
  txid: Txid,
  num_inputs: Int,
  sighashes: List(Hash256),
  timestamp: Int,
) -> #(SigCache, Option(Bool)) {
  let indexed_hashes = list.index_map(sighashes, fn(hash, idx) { #(idx, hash) })

  check_inputs_recursive(cache, txid, indexed_hashes, num_inputs, timestamp)
}

fn check_inputs_recursive(
  cache: SigCache,
  txid: Txid,
  remaining: List(#(Int, Hash256)),
  num_inputs: Int,
  timestamp: Int,
) -> #(SigCache, Option(Bool)) {
  case remaining {
    [] -> #(cache, Some(True))  // All inputs verified
    [#(idx, hash), ..rest] -> {
      case idx >= num_inputs {
        True -> #(cache, Some(True))  // Past input count
        False -> {
          let key = cache_key_new(txid, idx, hash)
          case sig_cache_get(cache, key, timestamp) {
            #(new_cache, Some(True)) -> {
              check_inputs_recursive(new_cache, txid, rest, num_inputs, timestamp)
            }
            #(new_cache, Some(False)) -> {
              #(new_cache, Some(False))  // Invalid signature cached
            }
            #(new_cache, None) -> {
              #(new_cache, None)  // Cache miss
            }
          }
        }
      }
    }
  }
}

// ============================================================================
// Statistics and Debugging
// ============================================================================

/// Detailed cache statistics
pub type DetailedStats {
  DetailedStats(
    size: Int,
    max_size: Int,
    hit_ratio: Float,
    hits: Int,
    misses: Int,
    evictions: Int,
    additions: Int,
    invalid_cached: Int,
    memory_estimate_bytes: Int,
  )
}

/// Get detailed statistics
pub fn sig_cache_detailed_stats(cache: SigCache) -> DetailedStats {
  // Rough memory estimate: ~200 bytes per entry
  let memory = cache.size * 200

  DetailedStats(
    size: cache.size,
    max_size: cache.max_entries,
    hit_ratio: sig_cache_hit_ratio(cache),
    hits: cache.stats.hits,
    misses: cache.stats.misses,
    evictions: cache.stats.evictions,
    additions: cache.stats.additions,
    invalid_cached: cache.stats.invalid_cached,
    memory_estimate_bytes: memory,
  )
}
