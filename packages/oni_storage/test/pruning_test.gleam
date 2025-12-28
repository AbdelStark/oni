// pruning_test.gleam - Tests for block pruning

import gleeunit
import gleeunit/should
import gleam/option.{None, Some}
import pruning
import oni_storage

pub fn main() {
  gleeunit.main()
}

// ============================================================================
// Configuration Tests
// ============================================================================

pub fn default_config_disabled_test() {
  let config = pruning.default_config()
  should.equal(config.enabled, False)
  should.equal(config.min_blocks_to_keep, 288)
}

pub fn pruned_config_enabled_test() {
  let config = pruning.pruned_config(1000)  // 1000 MB
  should.equal(config.enabled, True)
  should.equal(config.target_size, 1000 * 1024 * 1024)
  should.equal(config.min_blocks_to_keep, 288)
}

// ============================================================================
// Validation Tests
// ============================================================================

pub fn validate_disabled_config_test() {
  let config = pruning.default_config()
  let result = pruning.validate_config(config)
  should.equal(result, Ok(Nil))
}

pub fn validate_enabled_config_ok_test() {
  let config = pruning.PruningConfig(
    enabled: True,
    target_size: 600_000_000,  // 600 MB
    min_blocks_to_keep: 288,
    prune_undo_data: True,
  )
  let result = pruning.validate_config(config)
  should.equal(result, Ok(Nil))
}

pub fn validate_min_blocks_too_low_test() {
  let config = pruning.PruningConfig(
    enabled: True,
    target_size: 600_000_000,
    min_blocks_to_keep: 100,  // Too low
    prune_undo_data: True,
  )
  let result = pruning.validate_config(config)
  should.be_error(result)
}

pub fn validate_target_size_too_small_test() {
  let config = pruning.PruningConfig(
    enabled: True,
    target_size: 100_000_000,  // 100 MB - too small
    min_blocks_to_keep: 288,
    prune_undo_data: True,
  )
  let result = pruning.validate_config(config)
  should.be_error(result)
}

// ============================================================================
// Prune Eligibility Tests
// ============================================================================

pub fn can_prune_disabled_test() {
  let config = pruning.default_config()
  let chainstate = create_test_chainstate(1000)

  let result = pruning.can_prune_height(config, chainstate, 100)
  should.equal(result, False)
}

pub fn can_prune_enabled_old_block_test() {
  let config = pruning.pruned_config(1000)
  let chainstate = create_test_chainstate(1000)

  // Block 100 is well before keep window (1000 - 288 = 712)
  let result = pruning.can_prune_height(config, chainstate, 100)
  should.equal(result, True)
}

pub fn can_prune_enabled_recent_block_test() {
  let config = pruning.pruned_config(1000)
  let chainstate = create_test_chainstate(1000)

  // Block 900 is within keep window
  let result = pruning.can_prune_height(config, chainstate, 900)
  should.equal(result, False)
}

// ============================================================================
// Prune Range Calculation Tests
// ============================================================================

pub fn calculate_prune_range_disabled_test() {
  let config = pruning.default_config()
  let chainstate = create_test_chainstate(1000)

  let result = pruning.calculate_prune_range(config, chainstate, 0)
  should.equal(result, None)
}

pub fn calculate_prune_range_nothing_to_prune_test() {
  let config = pruning.pruned_config(1000)
  let chainstate = create_test_chainstate(1000)

  // Already pruned up to max prune height
  let result = pruning.calculate_prune_range(config, chainstate, 712)
  should.equal(result, None)
}

pub fn calculate_prune_range_with_work_test() {
  let config = pruning.pruned_config(1000)
  let chainstate = create_test_chainstate(1000)

  // Haven't pruned anything yet
  let result = pruning.calculate_prune_range(config, chainstate, 0)

  case result {
    Some(#(start, end)) -> {
      should.equal(start, 1)
      should.equal(end, 712)  // 1000 - 288
    }
    None -> should.fail()
  }
}

// ============================================================================
// Is Block Pruned Tests
// ============================================================================

pub fn is_block_pruned_not_pruned_test() {
  let chainstate = oni_storage.Chainstate(
    best_block: create_zero_hash(),
    best_height: 1000,
    total_tx: 0,
    total_coins: 0,
    total_amount: 0,
    pruned: False,
    pruned_height: None,
  )

  let result = pruning.is_block_pruned(chainstate, 100)
  should.equal(result, False)
}

pub fn is_block_pruned_yes_test() {
  let chainstate = oni_storage.Chainstate(
    best_block: create_zero_hash(),
    best_height: 1000,
    total_tx: 0,
    total_coins: 0,
    total_amount: 0,
    pruned: True,
    pruned_height: Some(500),
  )

  let result = pruning.is_block_pruned(chainstate, 100)
  should.equal(result, True)
}

pub fn is_block_pruned_no_above_height_test() {
  let chainstate = oni_storage.Chainstate(
    best_block: create_zero_hash(),
    best_height: 1000,
    total_tx: 0,
    total_coins: 0,
    total_amount: 0,
    pruned: True,
    pruned_height: Some(500),
  )

  let result = pruning.is_block_pruned(chainstate, 600)
  should.equal(result, False)
}

// ============================================================================
// Statistics Tests
// ============================================================================

pub fn initial_state_test() {
  let state = pruning.initial_state()
  should.equal(state.pruned_height, 0)
  should.equal(state.bytes_pruned, 0)
  should.equal(state.blocks_pruned, 0)
}

pub fn get_stats_test() {
  let config = pruning.pruned_config(1000)
  let chainstate = create_test_chainstate(1000)
  let state = pruning.initial_state()

  let stats = pruning.get_stats(config, chainstate, state)

  should.equal(stats.enabled, True)
  should.equal(stats.highest_height, 1000)
  should.equal(stats.lowest_height, 1)  // pruned_height + 1 = 0 + 1
}

// ============================================================================
// Format Bytes Tests
// ============================================================================

pub fn format_bytes_small_test() {
  should.equal(pruning.format_bytes(500), "500 B")
}

pub fn format_bytes_kb_test() {
  should.equal(pruning.format_bytes(5000), "4 KB")
}

pub fn format_bytes_mb_test() {
  should.equal(pruning.format_bytes(5_000_000), "4 MB")
}

pub fn format_bytes_gb_test() {
  should.equal(pruning.format_bytes(5_000_000_000), "4 GB")
}

// ============================================================================
// Can Serve Block Tests
// ============================================================================

pub fn can_serve_block_not_pruned_test() {
  let chainstate = oni_storage.Chainstate(
    best_block: create_zero_hash(),
    best_height: 1000,
    total_tx: 0,
    total_coins: 0,
    total_amount: 0,
    pruned: False,
    pruned_height: None,
  )

  let result = pruning.can_serve_block(chainstate, 100)
  should.equal(result, True)
}

pub fn can_serve_block_pruned_available_test() {
  let chainstate = oni_storage.Chainstate(
    best_block: create_zero_hash(),
    best_height: 1000,
    total_tx: 0,
    total_coins: 0,
    total_amount: 0,
    pruned: True,
    pruned_height: Some(500),
  )

  let result = pruning.can_serve_block(chainstate, 600)
  should.equal(result, True)
}

pub fn can_serve_block_pruned_not_available_test() {
  let chainstate = oni_storage.Chainstate(
    best_block: create_zero_hash(),
    best_height: 1000,
    total_tx: 0,
    total_coins: 0,
    total_amount: 0,
    pruned: True,
    pruned_height: Some(500),
  )

  let result = pruning.can_serve_block(chainstate, 400)
  should.equal(result, False)
}

// ============================================================================
// Helper Functions
// ============================================================================

import oni_bitcoin

fn create_test_chainstate(height: Int) -> oni_storage.Chainstate {
  oni_storage.Chainstate(
    best_block: create_zero_hash(),
    best_height: height,
    total_tx: 0,
    total_coins: 0,
    total_amount: 0,
    pruned: False,
    pruned_height: None,
  )
}

fn create_zero_hash() -> oni_bitcoin.BlockHash {
  let bytes = <<
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
  >>
  oni_bitcoin.BlockHash(hash: oni_bitcoin.Hash256(bytes: bytes))
}
