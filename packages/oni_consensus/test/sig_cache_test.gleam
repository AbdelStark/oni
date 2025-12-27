// sig_cache_test.gleam - Tests for signature verification cache

import gleam/list
import gleam/option.{None, Some}
import gleeunit
import gleeunit/should
import oni_bitcoin
import oni_consensus/sig_cache

pub fn main() {
  gleeunit.main()
}

// ============================================================================
// Helper Functions
// ============================================================================

fn make_txid(n: Int) -> oni_bitcoin.Txid {
  let bytes = <<n:256>>
  oni_bitcoin.Txid(oni_bitcoin.Hash256(bytes))
}

fn make_hash(n: Int) -> oni_bitcoin.Hash256 {
  oni_bitcoin.Hash256(<<n:256>>)
}

fn make_key(txid_n: Int, idx: Int, hash_n: Int) -> sig_cache.CacheKey {
  sig_cache.cache_key_new(make_txid(txid_n), idx, make_hash(hash_n))
}

// ============================================================================
// Cache Key Tests
// ============================================================================

pub fn cache_key_to_string_test() {
  let key = make_key(1, 0, 2)
  let str = sig_cache.cache_key_to_string(key)

  // Should contain txid, input index, and sighash
  str |> should.not_equal("")
}

pub fn cache_key_uniqueness_test() {
  let key1 = make_key(1, 0, 1)
  let key2 = make_key(1, 1, 1)  // Different input
  let key3 = make_key(1, 0, 2)  // Different sighash

  let str1 = sig_cache.cache_key_to_string(key1)
  let str2 = sig_cache.cache_key_to_string(key2)
  let str3 = sig_cache.cache_key_to_string(key3)

  // All should be different
  str1 |> should.not_equal(str2)
  str1 |> should.not_equal(str3)
  str2 |> should.not_equal(str3)
}

// ============================================================================
// Cache Entry Tests
// ============================================================================

pub fn cache_entry_new_test() {
  let entry = sig_cache.cache_entry_new(True, 1000)

  entry.valid |> should.equal(True)
  entry.added_at |> should.equal(1000)
  entry.last_access |> should.equal(1000)
  entry.access_count |> should.equal(0)
}

pub fn cache_entry_access_test() {
  let entry = sig_cache.cache_entry_new(True, 1000)
  let accessed = sig_cache.cache_entry_access(entry, 2000)

  accessed.last_access |> should.equal(2000)
  accessed.access_count |> should.equal(1)
  accessed.added_at |> should.equal(1000)  // Unchanged
}

// ============================================================================
// Basic Cache Operations
// ============================================================================

pub fn sig_cache_new_test() {
  let cache = sig_cache.sig_cache_new()

  sig_cache.sig_cache_size(cache) |> should.equal(0)
}

pub fn sig_cache_put_get_test() {
  let cache = sig_cache.sig_cache_new()
  let key = make_key(1, 0, 1)

  // Put a valid result
  let cache2 = sig_cache.sig_cache_put(cache, key, True, 1000)

  // Get should return the cached result
  let #(_cache3, result) = sig_cache.sig_cache_get(cache2, key, 2000)

  result |> should.equal(Some(True))
}

pub fn sig_cache_miss_test() {
  let cache = sig_cache.sig_cache_new()
  let key = make_key(1, 0, 1)

  // Get without put should return None
  let #(_cache2, result) = sig_cache.sig_cache_get(cache, key, 1000)

  result |> should.equal(None)
}

pub fn sig_cache_contains_test() {
  let cache = sig_cache.sig_cache_new()
  let key1 = make_key(1, 0, 1)
  let key2 = make_key(2, 0, 1)

  let cache2 = sig_cache.sig_cache_put(cache, key1, True, 1000)

  sig_cache.sig_cache_contains(cache2, key1) |> should.equal(True)
  sig_cache.sig_cache_contains(cache2, key2) |> should.equal(False)
}

pub fn sig_cache_size_test() {
  let cache = sig_cache.sig_cache_new()
    |> sig_cache.sig_cache_put(make_key(1, 0, 1), True, 1000)
    |> sig_cache.sig_cache_put(make_key(2, 0, 1), True, 1001)
    |> sig_cache.sig_cache_put(make_key(3, 0, 1), False, 1002)

  sig_cache.sig_cache_size(cache) |> should.equal(3)
}

pub fn sig_cache_clear_test() {
  let cache = sig_cache.sig_cache_new()
    |> sig_cache.sig_cache_put(make_key(1, 0, 1), True, 1000)
    |> sig_cache.sig_cache_put(make_key(2, 0, 1), True, 1001)

  sig_cache.sig_cache_size(cache) |> should.equal(2)

  let cleared = sig_cache.sig_cache_clear(cache)
  sig_cache.sig_cache_size(cleared) |> should.equal(0)
}

// ============================================================================
// Statistics Tests
// ============================================================================

pub fn sig_cache_stats_hits_misses_test() {
  let cache = sig_cache.sig_cache_new()
  let key = make_key(1, 0, 1)

  // Miss
  let #(cache2, _) = sig_cache.sig_cache_get(cache, key, 1000)

  // Put
  let cache3 = sig_cache.sig_cache_put(cache2, key, True, 1001)

  // Hit
  let #(cache4, _) = sig_cache.sig_cache_get(cache3, key, 1002)
  let #(cache5, _) = sig_cache.sig_cache_get(cache4, key, 1003)

  let stats = sig_cache.sig_cache_stats(cache5)
  stats.hits |> should.equal(2)
  stats.misses |> should.equal(1)
}

pub fn sig_cache_hit_ratio_test() {
  let cache = sig_cache.sig_cache_new()
  let key = make_key(1, 0, 1)

  // 1 miss
  let #(cache2, _) = sig_cache.sig_cache_get(cache, key, 1000)

  // Put
  let cache3 = sig_cache.sig_cache_put(cache2, key, True, 1001)

  // 3 hits
  let #(cache4, _) = sig_cache.sig_cache_get(cache3, key, 1002)
  let #(cache5, _) = sig_cache.sig_cache_get(cache4, key, 1003)
  let #(cache6, _) = sig_cache.sig_cache_get(cache5, key, 1004)

  // Hit ratio should be 3/4 = 0.75
  let ratio = sig_cache.sig_cache_hit_ratio(cache6)
  // Allow small floating point error
  should.be_true(ratio > 0.74 && ratio < 0.76)
}

pub fn sig_cache_invalid_cached_count_test() {
  let cache = sig_cache.sig_cache_new()
    |> sig_cache.sig_cache_put(make_key(1, 0, 1), True, 1000)
    |> sig_cache.sig_cache_put(make_key(2, 0, 1), False, 1001)
    |> sig_cache.sig_cache_put(make_key(3, 0, 1), False, 1002)

  let stats = sig_cache.sig_cache_stats(cache)
  stats.invalid_cached |> should.equal(2)
}

// ============================================================================
// Eviction Tests
// ============================================================================

pub fn sig_cache_eviction_test() {
  // Create cache with small max size
  let cache = sig_cache.sig_cache_with_size(100)

  // Fill beyond capacity
  let filled = list.fold(list.range(1, 150), cache, fn(acc, n) {
    sig_cache.sig_cache_put(acc, make_key(n, 0, 1), True, n)
  })

  // Size should be reduced
  let size = sig_cache.sig_cache_size(filled)
  size |> should.be_true(size <= 100)

  // Stats should show evictions
  let stats = sig_cache.sig_cache_stats(filled)
  stats.evictions |> should.be_true(stats.evictions > 0)
}

// ============================================================================
// Batch Operations Tests
// ============================================================================

pub fn sig_cache_batch_get_test() {
  let cache = sig_cache.sig_cache_new()
    |> sig_cache.sig_cache_put(make_key(1, 0, 1), True, 1000)
    |> sig_cache.sig_cache_put(make_key(2, 0, 1), True, 1001)

  let keys = [
    make_key(1, 0, 1),  // Cached
    make_key(2, 0, 1),  // Cached
    make_key(3, 0, 1),  // Not cached
  ]

  let #(_cache2, result) = sig_cache.sig_cache_batch_get(cache, keys, 2000)

  list.length(result.cached) |> should.equal(2)
  list.length(result.uncached) |> should.equal(1)
}

pub fn sig_cache_batch_put_test() {
  let cache = sig_cache.sig_cache_new()

  let results = [
    #(make_key(1, 0, 1), True),
    #(make_key(2, 0, 1), False),
    #(make_key(3, 0, 1), True),
  ]

  let cache2 = sig_cache.sig_cache_batch_put(cache, results, 1000)

  sig_cache.sig_cache_size(cache2) |> should.equal(3)
  sig_cache.sig_cache_contains(cache2, make_key(1, 0, 1)) |> should.equal(True)
  sig_cache.sig_cache_contains(cache2, make_key(2, 0, 1)) |> should.equal(True)
  sig_cache.sig_cache_contains(cache2, make_key(3, 0, 1)) |> should.equal(True)
}

// ============================================================================
// Transaction-level Operations Tests
// ============================================================================

pub fn sig_cache_put_tx_test() {
  let cache = sig_cache.sig_cache_new()
  let txid = make_txid(1)
  let sighashes = [make_hash(1), make_hash(2), make_hash(3)]

  let cache2 = sig_cache.sig_cache_put_tx(cache, txid, 3, sighashes, True, 1000)

  // All inputs should be cached
  sig_cache.sig_cache_contains(cache2, sig_cache.cache_key_new(txid, 0, make_hash(1)))
  |> should.equal(True)
  sig_cache.sig_cache_contains(cache2, sig_cache.cache_key_new(txid, 1, make_hash(2)))
  |> should.equal(True)
  sig_cache.sig_cache_contains(cache2, sig_cache.cache_key_new(txid, 2, make_hash(3)))
  |> should.equal(True)
}

pub fn sig_cache_check_tx_all_cached_test() {
  let cache = sig_cache.sig_cache_new()
  let txid = make_txid(1)
  let sighashes = [make_hash(1), make_hash(2)]

  // Cache all inputs
  let cache2 = sig_cache.sig_cache_put_tx(cache, txid, 2, sighashes, True, 1000)

  // Check should return True
  let #(_cache3, result) = sig_cache.sig_cache_check_tx(cache2, txid, 2, sighashes, 2000)
  result |> should.equal(Some(True))
}

pub fn sig_cache_check_tx_partial_cached_test() {
  let cache = sig_cache.sig_cache_new()
  let txid = make_txid(1)

  // Only cache first input
  let cache2 = sig_cache.sig_cache_put(
    cache,
    sig_cache.cache_key_new(txid, 0, make_hash(1)),
    True,
    1000,
  )

  let sighashes = [make_hash(1), make_hash(2)]

  // Check should return None (not fully cached)
  let #(_cache3, result) = sig_cache.sig_cache_check_tx(cache2, txid, 2, sighashes, 2000)
  result |> should.equal(None)
}

pub fn sig_cache_check_tx_invalid_cached_test() {
  let cache = sig_cache.sig_cache_new()
  let txid = make_txid(1)
  let sighashes = [make_hash(1), make_hash(2)]

  // Cache with invalid signature
  let cache2 = sig_cache.sig_cache_put_tx(cache, txid, 2, sighashes, False, 1000)

  // Check should return False
  let #(_cache3, result) = sig_cache.sig_cache_check_tx(cache2, txid, 2, sighashes, 2000)
  result |> should.equal(Some(False))
}

// ============================================================================
// Detailed Stats Tests
// ============================================================================

pub fn sig_cache_detailed_stats_test() {
  let cache = sig_cache.sig_cache_with_size(1000)
    |> sig_cache.sig_cache_put(make_key(1, 0, 1), True, 1000)
    |> sig_cache.sig_cache_put(make_key(2, 0, 1), True, 1001)

  let stats = sig_cache.sig_cache_detailed_stats(cache)

  stats.size |> should.equal(2)
  stats.max_size |> should.equal(1000)
  stats.additions |> should.equal(2)
  stats.memory_estimate_bytes |> should.be_true(stats.memory_estimate_bytes > 0)
}

// ============================================================================
// Edge Cases
// ============================================================================

pub fn sig_cache_no_update_existing_test() {
  let cache = sig_cache.sig_cache_new()
  let key = make_key(1, 0, 1)

  // Put with True
  let cache2 = sig_cache.sig_cache_put(cache, key, True, 1000)

  // Try to put with False - should not update
  let cache3 = sig_cache.sig_cache_put(cache2, key, False, 2000)

  // Should still be True
  let #(_cache4, result) = sig_cache.sig_cache_get(cache3, key, 3000)
  result |> should.equal(Some(True))
}

pub fn sig_cache_zero_inputs_test() {
  let cache = sig_cache.sig_cache_new()
  let txid = make_txid(1)

  // Transaction with zero inputs
  let cache2 = sig_cache.sig_cache_put_tx(cache, txid, 0, [], True, 1000)

  // Size should still be 0
  sig_cache.sig_cache_size(cache2) |> should.equal(0)
}

pub fn sig_cache_empty_hit_ratio_test() {
  let cache = sig_cache.sig_cache_new()

  // Hit ratio on empty cache should be 0
  sig_cache.sig_cache_hit_ratio(cache) |> should.equal(0.0)
}
