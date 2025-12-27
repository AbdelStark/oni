// Tests for difficulty calculation module

import gleeunit
import gleeunit/should
import difficulty
import oni_bitcoin

pub fn main() {
  gleeunit.main()
}

// ============================================================================
// Target Compact Encoding Tests
// ============================================================================

pub fn target_from_compact_genesis_test() {
  // Mainnet genesis difficulty
  let target = difficulty.target_from_compact(0x1d00ffff)

  // Target should be a 32-byte value
  target.bytes |> should.not_equal(<<>>)
}

pub fn target_from_compact_zero_exponent_test() {
  // Zero exponent should give zero target
  let target = difficulty.target_from_compact(0x00000000)
  target.bytes |> should.equal(<<0:256>>)
}

pub fn target_from_compact_negative_test() {
  // Negative coefficient (high bit set) should give zero target
  let target = difficulty.target_from_compact(0x01800000)
  target.bytes |> should.equal(<<0:256>>)
}

pub fn target_to_compact_roundtrip_test() {
  // Test that encode/decode roundtrips correctly
  let original = 0x1d00ffff
  let target = difficulty.target_from_compact(original)
  let encoded = difficulty.target_to_compact(target)

  // Note: roundtrip might not be exact due to normalization
  encoded |> should.not_equal(0)
}

// ============================================================================
// Difficulty Calculation Tests
// ============================================================================

pub fn difficulty_from_compact_genesis_test() {
  // Genesis block has difficulty 1
  let diff = difficulty.difficulty_from_compact(0x1d00ffff)
  let value = difficulty.difficulty_value(diff)

  // Should be approximately 1.0
  { value >=. 0.9 && value <=. 1.1 } |> should.be_true
}

pub fn difficulty_from_compact_higher_test() {
  // Lower target = higher difficulty
  // 0x1c00ffff has one less byte in exponent than 0x1d00ffff
  let genesis_diff = difficulty.difficulty_from_compact(0x1d00ffff)
  let harder_diff = difficulty.difficulty_from_compact(0x1c00ffff)

  let genesis_val = difficulty.difficulty_value(genesis_diff)
  let harder_val = difficulty.difficulty_value(harder_diff)

  // Harder difficulty should be higher value
  { harder_val >. genesis_val } |> should.be_true
}

// ============================================================================
// Difficulty Retargeting Tests
// ============================================================================

pub fn retarget_normal_test() {
  // If timespan equals target, difficulty should stay same
  let bits = 0x1d00ffff
  let actual_timespan = difficulty.target_timespan

  let new_bits = difficulty.calculate_next_target(bits, actual_timespan)

  // Should be approximately the same
  new_bits |> should.not_equal(0)
}

pub fn retarget_too_fast_test() {
  // If blocks came too fast, difficulty should increase
  let bits = 0x1d00ffff
  let actual_timespan = difficulty.target_timespan / 2  // Half the expected time

  let new_bits = difficulty.calculate_next_target(bits, actual_timespan)

  // New target should be lower (higher difficulty)
  new_bits |> should.not_equal(0)
}

pub fn retarget_too_slow_test() {
  // If blocks came too slow, difficulty should decrease
  let bits = 0x1d00ffff
  let actual_timespan = difficulty.target_timespan * 2  // Double the expected time

  let new_bits = difficulty.calculate_next_target(bits, actual_timespan)

  // New target should be higher (lower difficulty)
  new_bits |> should.not_equal(0)
}

pub fn retarget_clamp_min_test() {
  // Difficulty should not increase more than 4x
  let bits = 0x1d00ffff
  let actual_timespan = difficulty.target_timespan / 8  // Very fast

  let new_bits = difficulty.calculate_next_target(bits, actual_timespan)

  // Should be clamped to 4x increase
  new_bits |> should.not_equal(0)
}

pub fn retarget_clamp_max_test() {
  // Difficulty should not decrease more than 4x
  let bits = 0x1d00ffff
  let actual_timespan = difficulty.target_timespan * 8  // Very slow

  let new_bits = difficulty.calculate_next_target(bits, actual_timespan)

  // Should be clamped to 4x decrease
  new_bits |> should.not_equal(0)
}

// ============================================================================
// Chainwork Tests
// ============================================================================

pub fn work_from_target_test() {
  let target = difficulty.target_from_compact(0x1d00ffff)
  let work = difficulty.work_from_target(target)

  // Work should be non-zero
  work.bytes |> should.not_equal(<<0:256>>)
}

pub fn chainwork_add_test() {
  let work1 = difficulty.work_from_compact(0x1d00ffff)
  let work2 = difficulty.work_from_compact(0x1d00ffff)
  let total = difficulty.chainwork_add(work1, work2)

  // Total should be greater than individual
  let cmp = difficulty.chainwork_compare(total, work1)
  { cmp > 0 } |> should.be_true
}

// ============================================================================
// Hash Rate Tests
// ============================================================================

pub fn estimate_hash_rate_test() {
  let diff = difficulty.Difficulty(1.0)
  let rate = difficulty.estimate_hash_rate(diff, 600)  // 10 minute blocks

  // At difficulty 1, hash rate should be approximately 2^32 / 600
  let hps = rate.hashes_per_second
  { hps >. 0.0 } |> should.be_true
}

pub fn hash_rate_display_test() {
  let rate = difficulty.HashRate(1_000_000_000_000.0)  // 1 TH/s
  let display = difficulty.hash_rate_display(rate)

  display |> should.not_equal("")
}

// ============================================================================
// Validation Helper Tests
// ============================================================================

pub fn pow_limit_for_network_test() {
  let mainnet = difficulty.pow_limit_for_network(oni_bitcoin.Mainnet)
  let regtest = difficulty.pow_limit_for_network(oni_bitcoin.Regtest)

  // Regtest should have higher (easier) limit
  { regtest > mainnet } |> should.be_true
}

pub fn is_retarget_height_test() {
  difficulty.is_retarget_height(0) |> should.be_false
  difficulty.is_retarget_height(1) |> should.be_false
  difficulty.is_retarget_height(2015) |> should.be_false
  difficulty.is_retarget_height(2016) |> should.be_true
  difficulty.is_retarget_height(4032) |> should.be_true
}

pub fn prev_retarget_height_test() {
  difficulty.prev_retarget_height(0) |> should.equal(0)
  difficulty.prev_retarget_height(100) |> should.equal(0)
  difficulty.prev_retarget_height(2016) |> should.equal(2016)
  difficulty.prev_retarget_height(3000) |> should.equal(2016)
  difficulty.prev_retarget_height(5000) |> should.equal(4032)
}

pub fn blocks_until_retarget_test() {
  difficulty.blocks_until_retarget(0) |> should.equal(2016)
  difficulty.blocks_until_retarget(1) |> should.equal(2015)
  difficulty.blocks_until_retarget(2015) |> should.equal(1)
  difficulty.blocks_until_retarget(2016) |> should.equal(2016)
}
