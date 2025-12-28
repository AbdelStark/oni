// checkpoints_test.gleam - Tests for checkpoint validation

import gleam/option.{None, Some}
import checkpoints.{
  CheckpointMatch, CheckpointMismatch, Mainnet, NoCheckpointAtHeight,
  Regtest, Testnet,
}

// ============================================================================
// Checkpoint Set Tests
// ============================================================================

pub fn mainnet_checkpoints_exist_test() {
  let checkpoints = checkpoints.mainnet_checkpoints()

  // Should have multiple checkpoints
  let count = checkpoints.checkpoint_count(checkpoints)
  let assert True = count > 10
}

pub fn testnet_checkpoints_exist_test() {
  let checkpoints = checkpoints.testnet_checkpoints()

  // Should have checkpoints
  let count = checkpoints.checkpoint_count(checkpoints)
  let assert True = count > 0
}

pub fn regtest_has_genesis_checkpoint_test() {
  let checkpoints = checkpoints.regtest_checkpoints()

  // Regtest should have at least genesis
  let count = checkpoints.checkpoint_count(checkpoints)
  let assert True = count >= 1
}

// ============================================================================
// Checkpoint Verification Tests
// ============================================================================

pub fn verify_checkpoint_at_height_test() {
  let checkpoints = checkpoints.mainnet_checkpoints()

  // Height with no checkpoint should return NoCheckpointAtHeight
  let result = checkpoints.verify_checkpoint(
    checkpoints,
    12345,
    create_dummy_hash("000000000000000000000000000000000000000000000000000000000000abcd"),
  )

  let assert True = result == NoCheckpointAtHeight
}

pub fn get_checkpoint_at_known_height_test() {
  let checkpoints = checkpoints.mainnet_checkpoints()

  // Height 11111 is a known checkpoint
  let result = checkpoints.get_checkpoint_at_height(checkpoints, 11111)

  case result {
    Some(_hash) -> Nil
    None -> panic as "Should have checkpoint at height 11111"
  }
}

// ============================================================================
// Before/After Checkpoint Tests
// ============================================================================

pub fn is_before_last_checkpoint_test() {
  let checkpoints = checkpoints.mainnet_checkpoints()

  // Height 0 should be before last checkpoint
  let assert True = checkpoints.is_before_last_checkpoint(checkpoints, 0) == True

  // Height 1000000 might be after depending on checkpoint set
  // Just verify the function works
  let _ = checkpoints.is_before_last_checkpoint(checkpoints, 1_000_000)
  Nil
}

pub fn get_last_checkpoint_height_test() {
  let checkpoints = checkpoints.mainnet_checkpoints()

  let last_height = checkpoints.get_last_checkpoint_height(checkpoints)

  // Should be a reasonable mainnet height
  let assert True = last_height > 100_000
}

// ============================================================================
// Navigation Tests
// ============================================================================

pub fn get_next_checkpoint_height_test() {
  let checkpoints = checkpoints.mainnet_checkpoints()

  // Get next checkpoint after height 0
  let result = checkpoints.get_next_checkpoint_height(checkpoints, 0)

  case result {
    Some(height) -> {
      // Should be the first checkpoint (11111)
      let assert True = height > 0
    }
    None -> panic as "Should have next checkpoint after 0"
  }
}

pub fn get_previous_checkpoint_height_test() {
  let checkpoints = checkpoints.mainnet_checkpoints()

  // Get previous checkpoint before height 100000
  let result = checkpoints.get_previous_checkpoint_height(checkpoints, 100_000)

  case result {
    Some(height) -> {
      let assert True = height < 100_000
    }
    None -> panic as "Should have previous checkpoint before 100000"
  }
}

pub fn get_all_checkpoint_heights_test() {
  let checkpoints = checkpoints.mainnet_checkpoints()

  let heights = checkpoints.get_all_checkpoint_heights(checkpoints)

  // Should be sorted
  let assert True = is_sorted(heights)
}

fn is_sorted(list: List(Int)) -> Bool {
  case list {
    [] -> True
    [_] -> True
    [a, b, ..rest] -> a <= b && is_sorted([b, ..rest])
  }
}

// ============================================================================
// Reorg Protection Tests
// ============================================================================

pub fn reorg_conflicts_with_checkpoint_test() {
  let checkpoints = checkpoints.mainnet_checkpoints()

  // A reorg at height 0 affecting height 100000 should conflict
  // if there's a checkpoint between
  let conflicts = checkpoints.reorg_conflicts_with_checkpoint(
    checkpoints,
    0,
    100_000,
  )

  // There should be checkpoints in this range
  let assert True = conflicts == True
}

pub fn get_minimum_fork_height_test() {
  let checkpoints = checkpoints.mainnet_checkpoints()

  // Get minimum fork height at current height 200000
  let min_height = checkpoints.get_minimum_fork_height(checkpoints, 200_000)

  // Should be at or below 200000
  let assert True = min_height <= 200_000
  let assert True = min_height > 0
}

// ============================================================================
// Progress Tracking Tests
// ============================================================================

pub fn calculate_sync_progress_test() {
  let checkpoints = checkpoints.mainnet_checkpoints()

  // At height 0
  let progress0 = checkpoints.calculate_sync_progress(checkpoints, 0)
  let assert True = progress0.current_height == 0
  let assert True = progress0.checkpoints_passed == 0

  // At height 100000
  let progress100k = checkpoints.calculate_sync_progress(checkpoints, 100_000)
  let assert True = progress100k.current_height == 100_000
  let assert True = progress100k.checkpoints_passed > 0
}

// ============================================================================
// Network Selection Tests
// ============================================================================

pub fn get_checkpoints_by_network_test() {
  let mainnet = checkpoints.get_checkpoints(Mainnet)
  let testnet = checkpoints.get_checkpoints(Testnet)
  let regtest = checkpoints.get_checkpoints(Regtest)

  // Each should have different counts
  let assert True = checkpoints.checkpoint_count(mainnet) > 0
  let assert True = checkpoints.checkpoint_count(testnet) > 0
  let assert True = checkpoints.checkpoint_count(regtest) > 0
}

// ============================================================================
// Helper Functions
// ============================================================================

fn create_dummy_hash(hex: String) -> oni_bitcoin.BlockHash {
  case oni_bitcoin.block_hash_from_hex(hex) {
    Ok(h) -> h
    Error(_) -> oni_bitcoin.BlockHash(oni_bitcoin.Hash256(<<0:256>>))
  }
}

// External import
import oni_bitcoin
