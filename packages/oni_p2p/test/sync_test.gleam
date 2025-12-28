import gleeunit
import gleeunit/should
import gleam/list
import gleam/option.{None, Some}
import oni_bitcoin
import oni_p2p
import sync

pub fn main() {
  gleeunit.main()
}

// ============================================================================
// Helper Functions
// ============================================================================

fn genesis_hash() -> oni_bitcoin.BlockHash {
  let assert Ok(hash) = oni_bitcoin.block_hash_from_bytes(<<0:256>>)
  hash
}

fn make_block_hash(n: Int) -> oni_bitcoin.BlockHash {
  // Create a simple hash from an integer for testing
  let bytes = <<n:256-little>>
  let assert Ok(hash) = oni_bitcoin.block_hash_from_bytes(bytes)
  hash
}

// Helper function for creating test headers (used in future tests)
pub fn make_test_header(prev: oni_bitcoin.BlockHash, nonce: Int) -> oni_p2p.BlockHeaderNet {
  oni_p2p.BlockHeaderNet(
    version: 1,
    prev_block: prev,
    merkle_root: oni_bitcoin.Hash256(<<0:256>>),
    timestamp: 1234567890,
    bits: 0x1d00ffff,  // Mainnet genesis difficulty
    nonce: nonce,
  )
}

// ============================================================================
// Sync State Tests
// ============================================================================

pub fn sync_state_new_test() {
  let state = sync.sync_state_new()
  sync.is_syncing(state) |> should.be_false
}

// ============================================================================
// Block Locator Tests
// ============================================================================

pub fn build_locator_empty_chain_test() {
  let locator = sync.build_locator([], 0)
  locator.hashes |> should.equal([])
}

pub fn build_locator_single_block_test() {
  let genesis = genesis_hash()
  let chain = [genesis]
  let locator = sync.build_locator(chain, 0)

  // Should contain just genesis
  list.length(locator.hashes) |> should.equal(1)
}

pub fn build_locator_small_chain_test() {
  // Build a small chain of 5 blocks
  let chain = [
    make_block_hash(0),
    make_block_hash(1),
    make_block_hash(2),
    make_block_hash(3),
    make_block_hash(4),
  ]

  let locator = sync.build_locator(chain, 4)

  // For small chains, all blocks should be included
  list.length(locator.hashes) |> should.equal(5)
}

// ============================================================================
// Header Chain Tests
// ============================================================================

pub fn header_chain_new_test() {
  let genesis = genesis_hash()
  let chain = sync.header_chain_new(genesis)

  sync.header_chain_height(chain) |> should.equal(0)
}

pub fn header_chain_tip_test() {
  let genesis = genesis_hash()
  let chain = sync.header_chain_new(genesis)

  case sync.header_chain_tip(chain) {
    Some(tip) -> {
      tip.hash.bytes |> should.equal(genesis.hash.bytes)
    }
    None -> should.fail()
  }
}

// ============================================================================
// Download Manager Tests
// ============================================================================

pub fn download_manager_new_test() {
  let dm = sync.download_manager_new()

  sync.download_manager_is_complete(dm) |> should.be_true
  sync.download_manager_pending_count(dm) |> should.equal(0)
}

pub fn download_manager_add_test() {
  let dm = sync.download_manager_new()

  let requests = [
    sync.BlockRequest(make_block_hash(1), 1, 100),
    sync.BlockRequest(make_block_hash(2), 2, 99),
    sync.BlockRequest(make_block_hash(3), 3, 98),
  ]

  let updated = sync.download_manager_add(dm, requests)

  sync.download_manager_is_complete(updated) |> should.be_false
  sync.download_manager_pending_count(updated) |> should.equal(3)
}

pub fn download_manager_next_for_peer_test() {
  let dm = sync.download_manager_new()

  let requests = [
    sync.BlockRequest(make_block_hash(1), 1, 100),
    sync.BlockRequest(make_block_hash(2), 2, 99),
    sync.BlockRequest(make_block_hash(3), 3, 98),
  ]

  let dm_with_requests = sync.download_manager_add(dm, requests)
  let peer = oni_p2p.peer_id("test-peer")

  let #(updated_dm, assigned) = sync.download_manager_next_for_peer(dm_with_requests, peer, 2)

  // Should have assigned 2 blocks
  list.length(assigned) |> should.equal(2)

  // Should have 1 remaining in queue
  sync.download_manager_pending_count(updated_dm) |> should.equal(3)  // 2 in-flight + 1 queued
}

// ============================================================================
// Sync Coordinator Tests
// ============================================================================

pub fn sync_coordinator_new_test() {
  let genesis = genesis_hash()
  let coord = sync.sync_coordinator_new(genesis)

  sync.sync_is_complete(coord) |> should.be_false
}

pub fn sync_start_headers_test() {
  let genesis = genesis_hash()
  let coord = sync.sync_coordinator_new(genesis)
  let peer = oni_p2p.peer_id("sync-peer")

  let #(new_coord, messages) = sync.sync_start_headers(coord, peer, 1000)

  // Should produce a getheaders message
  list.length(messages) |> should.equal(1)

  // Should be syncing now
  sync.is_syncing(new_coord.state) |> should.be_true
}

pub fn sync_progress_idle_test() {
  let genesis = genesis_hash()
  let coord = sync.sync_coordinator_new(genesis)

  sync.sync_progress(coord) |> should.equal(0.0)
}

pub fn sync_get_stats_test() {
  let genesis = genesis_hash()
  let coord = sync.sync_coordinator_new(genesis)

  let stats = sync.sync_get_stats(coord, 1000)

  stats.state |> should.equal("idle")
  stats.header_height |> should.equal(0)
  stats.blocks_processed |> should.equal(0)
}

// ============================================================================
// Reorg Tests
// ============================================================================

pub fn find_common_ancestor_identical_chains_test() {
  let chain = [
    make_block_hash(0),
    make_block_hash(1),
    make_block_hash(2),
  ]

  case sync.find_common_ancestor(chain, chain) {
    Some(#(_hash, height)) -> height |> should.equal(2)
    None -> should.fail()
  }
}

pub fn find_common_ancestor_fork_test() {
  let chain1 = [
    make_block_hash(0),
    make_block_hash(1),
    make_block_hash(2),
  ]

  let chain2 = [
    make_block_hash(0),
    make_block_hash(1),
    make_block_hash(99),  // Different block at height 2
  ]

  case sync.find_common_ancestor(chain1, chain2) {
    Some(#(_hash, height)) -> height |> should.equal(1)
    None -> should.fail()
  }
}

pub fn find_common_ancestor_no_common_test() {
  let chain1 = [make_block_hash(1)]
  let chain2 = [make_block_hash(2)]

  case sync.find_common_ancestor(chain1, chain2) {
    Some(_) -> should.fail()
    None -> should.be_ok(Ok(Nil))
  }
}

pub fn calculate_reorg_test() {
  let current = [
    make_block_hash(0),
    make_block_hash(1),
    make_block_hash(2),
    make_block_hash(3),
  ]

  let new_chain = [
    make_block_hash(0),
    make_block_hash(1),
    make_block_hash(100),  // Fork starts here
    make_block_hash(101),
    make_block_hash(102),
  ]

  case sync.calculate_reorg(current, new_chain) {
    Some(#(to_disconnect, to_connect)) -> {
      // Should disconnect blocks 2 and 3
      list.length(to_disconnect) |> should.equal(2)
      // Should connect blocks 100, 101, 102
      list.length(to_connect) |> should.equal(3)
    }
    None -> should.fail()
  }
}
