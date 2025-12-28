// difficulty.gleam - Bitcoin difficulty calculation
//
// This module provides difficulty-related calculations:
// - Compact target encoding/decoding
// - Difficulty retargeting algorithm
// - Chainwork calculation
// - Difficulty to hash rate conversion

import gleam/bit_array
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import oni_bitcoin.{type BlockHeader, type BlockHash, type Hash256}

// ============================================================================
// Constants
// ============================================================================

/// Target timespan for difficulty adjustment (2 weeks = 14 days)
pub const target_timespan = 1_209_600  // 14 * 24 * 60 * 60 seconds

/// Target block time (10 minutes)
pub const target_spacing = 600  // 10 * 60 seconds

/// Number of blocks per difficulty adjustment
pub const difficulty_adjustment_interval = 2016

/// Minimum difficulty adjustment factor (1/4)
pub const min_adjustment_factor = 0.25

/// Maximum difficulty adjustment factor (4x)
pub const max_adjustment_factor = 4.0

/// Proof of work limit for mainnet (minimum difficulty)
/// This is 2^224 - represents difficulty 1
pub const pow_limit_mainnet_bits = 0x1d00ffff

/// Proof of work limit for testnet
pub const pow_limit_testnet_bits = 0x1d00ffff

/// Proof of work limit for regtest (very low difficulty)
pub const pow_limit_regtest_bits = 0x207fffff

// ============================================================================
// Types
// ============================================================================

/// Represents a 256-bit target value for proof of work
pub type Target {
  Target(bytes: BitArray)
}

/// Represents the total chainwork (cumulative difficulty)
pub type Chainwork {
  Chainwork(bytes: BitArray)
}

/// Difficulty as a floating point number relative to genesis difficulty
pub type Difficulty {
  Difficulty(value: Float)
}

/// Network hash rate estimate
pub type HashRate {
  HashRate(hashes_per_second: Float)
}

// ============================================================================
// Compact Target (nBits) Encoding/Decoding
// ============================================================================

/// Decode compact target from nBits field
/// The format is: coefficient * 2^(8 * (exponent - 3))
/// nBits = (exponent << 24) | coefficient
pub fn target_from_compact(compact: Int) -> Target {
  let exponent = int.bitwise_shift_right(compact, 24)
  let coefficient = int.bitwise_and(compact, 0x007fffff)

  // Check for negative (high bit of coefficient set)
  case int.bitwise_and(compact, 0x00800000) != 0 {
    True -> Target(<<0:256>>)  // Negative treated as zero
    False -> {
      case exponent == 0 {
        True -> Target(<<0:256>>)  // Zero exponent = zero target
        False -> {
          // Calculate the full target value
          // Target = coefficient * 2^(8 * (exponent - 3))
          let target = compute_target_value(coefficient, exponent)
          Target(target)
        }
      }
    }
  }
}

fn compute_target_value(coefficient: Int, exponent: Int) -> BitArray {
  // The target is a 256-bit (32 byte) value
  // coefficient goes in bytes [32-exponent, 32-exponent+3)
  let shift_bytes = exponent - 3

  case shift_bytes >= 0 && shift_bytes <= 29 {
    True -> {
      // Create 32-byte target
      let zeros_after = shift_bytes
      let zeros_before = 32 - 3 - zeros_after

      case zeros_before >= 0 {
        True -> {
          let before = create_zeros(zeros_before)
          let coef_bytes = <<coefficient:24-big>>
          let after = create_zeros(zeros_after)
          bit_array.concat([before, coef_bytes, after])
        }
        False -> <<0:256>>
      }
    }
    False -> <<0:256>>
  }
}

/// Encode target to compact nBits format
pub fn target_to_compact(target: Target) -> Int {
  // Find the most significant non-zero byte
  case find_first_nonzero(target.bytes, 0) {
    None -> 0
    Some(#(first_byte, position)) -> {
      // Get 3 bytes starting from first non-zero
      let remaining = 32 - position
      let exponent = remaining

      // Extract coefficient (3 bytes)
      case extract_coefficient(target.bytes, position) {
        Error(_) -> 0
        Ok(coefficient) -> {
          // If high bit is set, shift right and increment exponent
          let #(final_coef, final_exp) = case int.bitwise_and(coefficient, 0x00800000) != 0 {
            True -> #(int.bitwise_shift_right(coefficient, 8), exponent + 1)
            False -> #(coefficient, exponent)
          }

          int.bitwise_or(int.bitwise_shift_left(final_exp, 24), final_coef)
        }
      }
    }
  }
}

fn find_first_nonzero(bytes: BitArray, pos: Int) -> Option(#(Int, Int)) {
  case bytes {
    <<0:8, rest:bits>> -> find_first_nonzero(rest, pos + 1)
    <<b:8, _rest:bits>> -> Some(#(b, pos))
    _ -> None
  }
}

fn extract_coefficient(bytes: BitArray, start: Int) -> Result(Int, Nil) {
  case bit_array.slice(bytes, start, 3) {
    Ok(<<a:8, b:8, c:8>>) -> Ok(a * 65536 + b * 256 + c)
    Ok(<<a:8, b:8>>) -> Ok(a * 65536 + b * 256)
    Ok(<<a:8>>) -> Ok(a * 65536)
    _ -> Error(Nil)
  }
}

fn create_zeros(n: Int) -> BitArray {
  create_zeros_acc(n, <<>>)
}

fn create_zeros_acc(n: Int, acc: BitArray) -> BitArray {
  case n <= 0 {
    True -> acc
    False -> create_zeros_acc(n - 1, bit_array.append(acc, <<0:8>>))
  }
}

// ============================================================================
// Difficulty Calculation
// ============================================================================

/// Calculate difficulty from compact target
/// Difficulty = genesis_target / current_target
pub fn difficulty_from_compact(compact: Int) -> Difficulty {
  let target = target_from_compact(compact)
  difficulty_from_target(target)
}

/// Calculate difficulty from target
pub fn difficulty_from_target(target: Target) -> Difficulty {
  // Genesis target (difficulty 1) for mainnet
  let genesis_target = target_from_compact(pow_limit_mainnet_bits)

  // Difficulty = genesis_target / current_target
  let genesis_val = target_to_float(genesis_target)
  let current_val = target_to_float(target)

  case current_val >. 0.0 {
    True -> Difficulty(genesis_val /. current_val)
    False -> Difficulty(0.0)
  }
}

/// Convert target to approximate float (for difficulty calculations)
fn target_to_float(target: Target) -> Float {
  // Use the first 8 bytes as a float approximation
  // This loses precision but is sufficient for difficulty calculations
  let value = bytes_to_float(target.bytes, 0.0)
  value
}

fn bytes_to_float(bytes: BitArray, acc: Float) -> Float {
  case bytes {
    <<b:8, rest:bits>> -> {
      let new_acc = acc *. 256.0 +. int.to_float(b)
      bytes_to_float(rest, new_acc)
    }
    _ -> acc
  }
}

/// Get difficulty as a float value
pub fn difficulty_value(d: Difficulty) -> Float {
  d.value
}

// ============================================================================
// Difficulty Retargeting
// ============================================================================

/// Calculate the next target based on the previous period
/// This implements the Bitcoin difficulty adjustment algorithm
pub fn calculate_next_target(
  prev_target_bits: Int,
  actual_timespan: Int,
) -> Int {
  // Clamp the timespan to prevent extreme adjustments
  let clamped_timespan = clamp_timespan(actual_timespan)

  // Get the previous target
  let prev_target = target_from_compact(prev_target_bits)

  // Calculate new target = prev_target * actual_timespan / target_timespan
  let new_target = scale_target(prev_target, clamped_timespan, target_timespan)

  // Ensure we don't exceed the PoW limit
  let final_target = clamp_target(new_target, pow_limit_mainnet_bits)

  target_to_compact(final_target)
}

fn clamp_timespan(actual: Int) -> Int {
  let min_timespan = target_timespan / 4
  let max_timespan = target_timespan * 4

  case actual < min_timespan {
    True -> min_timespan
    False -> {
      case actual > max_timespan {
        True -> max_timespan
        False -> actual
      }
    }
  }
}

fn scale_target(target: Target, numerator: Int, denominator: Int) -> Target {
  // Multiply target by numerator/denominator
  // This is done with big integer arithmetic on the target bytes
  let scaled = scale_bytes(target.bytes, numerator, denominator)
  Target(scaled)
}

fn scale_bytes(bytes: BitArray, num: Int, den: Int) -> BitArray {
  // Convert to a list of bytes, scale, and convert back
  // This is a simplified implementation
  case bytes_to_int(bytes) {
    0 -> bytes
    value -> {
      let scaled = value * num / den
      int_to_bytes(scaled, 32)
    }
  }
}

fn bytes_to_int(bytes: BitArray) -> Int {
  bytes_to_int_acc(bytes, 0)
}

fn bytes_to_int_acc(bytes: BitArray, acc: Int) -> Int {
  case bytes {
    <<b:8, rest:bits>> -> bytes_to_int_acc(rest, acc * 256 + b)
    _ -> acc
  }
}

fn int_to_bytes(value: Int, size: Int) -> BitArray {
  int_to_bytes_acc(value, size, <<>>)
}

fn int_to_bytes_acc(value: Int, remaining: Int, acc: BitArray) -> BitArray {
  case remaining {
    0 -> acc
    _ -> {
      let byte = value % 256
      let rest = value / 256
      int_to_bytes_acc(rest, remaining - 1, <<byte:8, acc:bits>>)
    }
  }
}

fn clamp_target(target: Target, limit_bits: Int) -> Target {
  let limit = target_from_compact(limit_bits)
  case compare_targets(target, limit) {
    order if order > 0 -> limit  // Target exceeds limit, use limit
    _ -> target
  }
}

fn compare_targets(a: Target, b: Target) -> Int {
  compare_bytes_recursive(a.bytes, b.bytes)
}

fn compare_bytes_recursive(a: BitArray, b: BitArray) -> Int {
  case a, b {
    <<ah:8, arest:bits>>, <<bh:8, brest:bits>> -> {
      case ah - bh {
        0 -> compare_bytes_recursive(arest, brest)
        diff -> diff
      }
    }
    <<_:8, _:bits>>, <<>> -> 1
    <<>>, <<_:8, _:bits>> -> -1
    <<>>, <<>> -> 0
    _, _ -> 0
  }
}

// ============================================================================
// Chainwork Calculation
// ============================================================================

/// Calculate work for a single block from its target
/// Work = 2^256 / (target + 1)
pub fn work_from_target(target: Target) -> Chainwork {
  // Approximate: work ≈ 2^256 / target
  // For simplicity, we use the inverse scaled appropriately
  let target_val = bytes_to_int(target.bytes)

  case target_val > 0 {
    True -> {
      // We can't represent 2^256, so we use a scaled representation
      // Work is stored as a 256-bit value
      let work = compute_work_value(target_val)
      Chainwork(int_to_bytes(work, 32))
    }
    False -> Chainwork(<<0:256>>)
  }
}

fn compute_work_value(target: Int) -> Int {
  // (~target / (target + 1)) + 1
  // This is an approximation that works for large targets
  case target {
    0 -> 0
    _ -> {
      let max_256 = compute_max_256()
      max_256 / { target + 1 } + 1
    }
  }
}

fn compute_max_256() -> Int {
  // 2^256 - 1 (max value representable in 256 bits)
  // We compute this iteratively to avoid overflow issues
  compute_power(2, 256) - 1
}

fn compute_power(base: Int, exp: Int) -> Int {
  compute_power_acc(base, exp, 1)
}

fn compute_power_acc(base: Int, exp: Int, acc: Int) -> Int {
  case exp {
    0 -> acc
    _ -> compute_power_acc(base, exp - 1, acc * base)
  }
}

/// Calculate work for a block from its nBits
pub fn work_from_compact(compact: Int) -> Chainwork {
  let target = target_from_compact(compact)
  work_from_target(target)
}

/// Add two chainwork values
pub fn chainwork_add(a: Chainwork, b: Chainwork) -> Chainwork {
  let a_val = bytes_to_int(a.bytes)
  let b_val = bytes_to_int(b.bytes)
  Chainwork(int_to_bytes(a_val + b_val, 32))
}

/// Compare two chainwork values
/// Returns: negative if a < b, 0 if equal, positive if a > b
pub fn chainwork_compare(a: Chainwork, b: Chainwork) -> Int {
  compare_bytes_recursive(a.bytes, b.bytes)
}

/// Get chainwork as bytes
pub fn chainwork_bytes(cw: Chainwork) -> BitArray {
  cw.bytes
}

// ============================================================================
// Hash Rate Estimation
// ============================================================================

/// Estimate network hash rate from difficulty and block time
pub fn estimate_hash_rate(difficulty: Difficulty, block_time: Int) -> HashRate {
  // Hash rate = difficulty * 2^32 / block_time
  // 2^32 hashes are needed on average for difficulty 1
  let hashes_per_block = difficulty.value *. 4_294_967_296.0
  let hash_rate = hashes_per_block /. int.to_float(block_time)
  HashRate(hash_rate)
}

/// Estimate hash rate from recent blocks
pub fn estimate_hash_rate_from_blocks(
  difficulty: Difficulty,
  num_blocks: Int,
  timespan: Int,
) -> HashRate {
  // Average block time
  let avg_block_time = case num_blocks > 0 {
    True -> timespan / num_blocks
    False -> target_spacing
  }

  estimate_hash_rate(difficulty, avg_block_time)
}

/// Format hash rate for display
pub fn hash_rate_display(rate: HashRate) -> String {
  let h = rate.hashes_per_second

  case h >=. 1_000_000_000_000_000_000.0 {
    True -> float_to_string_approx(h /. 1_000_000_000_000_000_000.0, 2) <> " EH/s"
    False -> {
      case h >=. 1_000_000_000_000_000.0 {
        True -> float_to_string_approx(h /. 1_000_000_000_000_000.0, 2) <> " PH/s"
        False -> {
          case h >=. 1_000_000_000_000.0 {
            True -> float_to_string_approx(h /. 1_000_000_000_000.0, 2) <> " TH/s"
            False -> {
              case h >=. 1_000_000_000.0 {
                True -> float_to_string_approx(h /. 1_000_000_000.0, 2) <> " GH/s"
                False -> {
                  case h >=. 1_000_000.0 {
                    True -> float_to_string_approx(h /. 1_000_000.0, 2) <> " MH/s"
                    False -> float_to_string_approx(h, 2) <> " H/s"
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}

fn float_to_string_approx(f: Float, decimals: Int) -> String {
  // Simple float to string conversion
  let whole = float.truncate(f)
  let frac = f -. int.to_float(whole)
  let frac_scaled = float.truncate(frac *. compute_power_float(10.0, decimals))

  int.to_string(whole) <> "." <> int.to_string(frac_scaled)
}

fn compute_power_float(base: Float, exp: Int) -> Float {
  case exp {
    0 -> 1.0
    _ -> base *. compute_power_float(base, exp - 1)
  }
}

// ============================================================================
// Validation Helpers
// ============================================================================

/// Check if a block hash meets the target difficulty
pub fn hash_meets_target(hash: BlockHash, target: Target) -> Bool {
  // Hash must be <= target (both are 256-bit big-endian values)
  // Block hash is stored in little-endian, so we reverse for comparison
  let hash_be = oni_bitcoin.reverse_bytes(hash.hash.bytes)
  compare_bytes_recursive(hash_be, target.bytes) <= 0
}

/// Check if a block hash meets the compact target
pub fn hash_meets_compact(hash: BlockHash, compact: Int) -> Bool {
  let target = target_from_compact(compact)
  hash_meets_target(hash, target)
}

/// Get the PoW limit for a network
pub fn pow_limit_for_network(network: oni_bitcoin.Network) -> Int {
  case network {
    oni_bitcoin.Mainnet -> pow_limit_mainnet_bits
    oni_bitcoin.Testnet -> pow_limit_testnet_bits
    oni_bitcoin.Signet -> pow_limit_testnet_bits
    oni_bitcoin.Regtest -> pow_limit_regtest_bits
  }
}

/// Check if difficulty adjustment is needed at this height
pub fn is_retarget_height(height: Int) -> Bool {
  height > 0 && height % difficulty_adjustment_interval == 0
}

/// Get the height of the previous retarget point
pub fn prev_retarget_height(height: Int) -> Int {
  { height / difficulty_adjustment_interval } * difficulty_adjustment_interval
}

/// Get the expected number of blocks until next adjustment
pub fn blocks_until_retarget(height: Int) -> Int {
  difficulty_adjustment_interval - { height % difficulty_adjustment_interval }
}
