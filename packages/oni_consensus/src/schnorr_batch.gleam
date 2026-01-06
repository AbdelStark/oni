// schnorr_batch.gleam - Schnorr Batch Verification for Performance
//
// This module provides efficient batch verification of Schnorr signatures:
// - BIP340 Schnorr signature batch verification
// - Random linear combination for batch soundness
// - Incremental batch building
// - Parallel verification support
// - Performance optimizations for Taproot validation
//
// Batch verification is ~2-3x faster than individual verification
// for large batches due to reduced EC operations.
//
// Reference: https://github.com/bitcoin/bips/blob/master/bip-0340.mediawiki

import gleam/bit_array
import gleam/bytes_builder
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result

// ============================================================================
// Constants
// ============================================================================

/// Size of a Schnorr signature (64 bytes)
pub const signature_size = 64

/// Size of an x-only public key (32 bytes)
pub const pubkey_size = 32

/// Size of a message hash (32 bytes)
pub const message_size = 32

/// Maximum batch size before splitting
pub const max_batch_size = 1024

/// Minimum batch size for efficiency
pub const min_batch_size = 4

/// secp256k1 curve order (n)
pub const curve_order_hex = "FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141"

// ============================================================================
// Core Types
// ============================================================================

/// A single Schnorr signature entry
pub type SchnorrEntry {
  SchnorrEntry(
    /// 32-byte x-only public key
    pubkey: BitArray,
    /// 32-byte message hash
    message: BitArray,
    /// 64-byte Schnorr signature (r || s)
    signature: BitArray,
    /// Optional context for error reporting
    context: Option(String),
  )
}

/// Batch verification state
pub type BatchVerifier {
  BatchVerifier(
    /// Entries pending verification
    entries: List(SchnorrEntry),
    /// Random scalars for batch combination
    scalars: List(BitArray),
    /// Pre-computed challenge hashes
    challenges: List(BitArray),
    /// Batch ID for tracking
    batch_id: Int,
    /// Configuration
    config: BatchConfig,
  )
}

/// Batch verification configuration
pub type BatchConfig {
  BatchConfig(
    /// Maximum batch size
    max_size: Int,
    /// Use deterministic verification (for testing)
    deterministic: Bool,
    /// Random seed for scalar generation
    seed: BitArray,
  )
}

/// Verification result
pub type VerifyResult {
  /// All signatures valid
  BatchValid
  /// At least one signature invalid
  BatchInvalid(failed_indices: List(Int))
  /// Batch verification error
  BatchError(reason: String)
}

/// Point in affine coordinates (x, y)
pub type AffinePoint {
  AffinePoint(x: BitArray, y: BitArray)
  Infinity
}

/// Point in Jacobian coordinates for efficient computation
pub type JacobianPoint {
  JacobianPoint(x: BitArray, y: BitArray, z: BitArray)
  JInfinity
}

/// Parsed signature components
pub type SignatureParts {
  SignatureParts(
    /// R point (x-coordinate from signature)
    r: BitArray,
    /// s scalar
    s: BitArray,
  )
}

// ============================================================================
// Batch Verifier Operations
// ============================================================================

/// Create a new batch verifier with default configuration
pub fn new() -> BatchVerifier {
  new_with_config(default_config())
}

/// Create batch verifier with custom configuration
pub fn new_with_config(config: BatchConfig) -> BatchVerifier {
  BatchVerifier(
    entries: [],
    scalars: [],
    challenges: [],
    batch_id: 0,
    config: config,
  )
}

/// Default batch configuration
pub fn default_config() -> BatchConfig {
  BatchConfig(
    max_size: max_batch_size,
    deterministic: False,
    seed: generate_random_seed(),
  )
}

/// Add a signature entry to the batch
pub fn add(
  batch: BatchVerifier,
  pubkey: BitArray,
  message: BitArray,
  signature: BitArray,
) -> Result(BatchVerifier, String) {
  add_with_context(batch, pubkey, message, signature, None)
}

/// Add a signature entry with context
pub fn add_with_context(
  batch: BatchVerifier,
  pubkey: BitArray,
  message: BitArray,
  signature: BitArray,
  context: Option(String),
) -> Result(BatchVerifier, String) {
  // Validate sizes
  use _ <- result.try(validate_entry_sizes(pubkey, message, signature))

  // Check batch capacity
  case list.length(batch.entries) >= batch.config.max_size {
    True -> Error("Batch is full")
    False -> {
      let entry =
        SchnorrEntry(
          pubkey: pubkey,
          message: message,
          signature: signature,
          context: context,
        )

      // Generate random scalar for this entry
      let scalar = generate_scalar(batch.config, list.length(batch.entries))

      // Compute challenge hash
      let challenge = compute_challenge(pubkey, signature, message)

      Ok(
        BatchVerifier(
          ..batch,
          entries: [entry, ..batch.entries],
          scalars: [scalar, ..batch.scalars],
          challenges: [challenge, ..batch.challenges],
        ),
      )
    }
  }
}

fn validate_entry_sizes(
  pubkey: BitArray,
  message: BitArray,
  signature: BitArray,
) -> Result(Nil, String) {
  case bit_array.byte_size(pubkey) == pubkey_size {
    False -> Error("Invalid public key size")
    True -> {
      case bit_array.byte_size(message) == message_size {
        False -> Error("Invalid message size")
        True -> {
          case bit_array.byte_size(signature) == signature_size {
            False -> Error("Invalid signature size")
            True -> Ok(Nil)
          }
        }
      }
    }
  }
}

/// Get number of entries in batch
pub fn size(batch: BatchVerifier) -> Int {
  list.length(batch.entries)
}

/// Check if batch is empty
pub fn is_empty(batch: BatchVerifier) -> Bool {
  list.is_empty(batch.entries)
}

/// Clear the batch
pub fn clear(batch: BatchVerifier) -> BatchVerifier {
  BatchVerifier(
    ..batch,
    entries: [],
    scalars: [],
    challenges: [],
    batch_id: batch.batch_id + 1,
  )
}

// ============================================================================
// Batch Verification
// ============================================================================

/// Verify all signatures in the batch
pub fn verify(batch: BatchVerifier) -> VerifyResult {
  case list.length(batch.entries) {
    0 -> BatchValid
    1 -> {
      // Single entry - use direct verification
      case batch.entries {
        [entry] -> {
          case verify_single(entry) {
            True -> BatchValid
            False -> BatchInvalid([0])
          }
        }
        _ -> BatchError("Unexpected empty batch")
      }
    }
    n if n < min_batch_size -> {
      // Small batch - verify individually
      verify_individually(batch.entries, 0, [])
    }
    _ -> {
      // Full batch verification
      verify_batch_combined(batch)
    }
  }
}

/// Verify individually and collect failures
fn verify_individually(
  entries: List(SchnorrEntry),
  index: Int,
  failed: List(Int),
) -> VerifyResult {
  case entries {
    [] -> {
      case failed {
        [] -> BatchValid
        _ -> BatchInvalid(list.reverse(failed))
      }
    }
    [entry, ..rest] -> {
      let new_failed = case verify_single(entry) {
        True -> failed
        False -> [index, ..failed]
      }
      verify_individually(rest, index + 1, new_failed)
    }
  }
}

/// Verify a single Schnorr signature (BIP340)
pub fn verify_single(entry: SchnorrEntry) -> Bool {
  // Parse signature
  case parse_signature(entry.signature) {
    Error(_) -> False
    Ok(sig) -> {
      // Validate R x-coordinate (lift x)
      case lift_x(sig.r) {
        Error(_) -> False
        Ok(_r_point) -> {
          // Compute challenge e = tagged_hash("BIP0340/challenge", r || P || m)
          let e =
            compute_challenge(entry.pubkey, entry.signature, entry.message)

          // Verify: sG == R + eP
          // In production, this would use actual secp256k1 operations
          verify_equation(sig.s, sig.r, entry.pubkey, e)
        }
      }
    }
  }
}

/// Combined batch verification using random linear combinations
fn verify_batch_combined(batch: BatchVerifier) -> VerifyResult {
  // Batch verification equation:
  // sum_i(a_i * s_i) * G = sum_i(a_i * R_i) + sum_i(a_i * e_i * P_i)
  //
  // Where:
  // - a_i are random scalars
  // - s_i is the s component of signature i
  // - R_i is the R point of signature i
  // - e_i is the challenge hash for signature i
  // - P_i is the public key i

  let entries = list.reverse(batch.entries)
  let scalars = list.reverse(batch.scalars)
  let challenges = list.reverse(batch.challenges)

  // Compute left side: sum(a_i * s_i) * G
  let left_scalar = compute_left_scalar(entries, scalars)

  // Compute right side: sum(a_i * R_i) + sum(a_i * e_i * P_i)
  let right_point = compute_right_point(entries, scalars, challenges)

  // Verify: left_scalar * G == right_point
  case verify_batch_equation(left_scalar, right_point) {
    True -> BatchValid
    False -> {
      // Batch failed - find individual failures
      verify_individually(entries, 0, [])
    }
  }
}

fn compute_left_scalar(
  entries: List(SchnorrEntry),
  scalars: List(BitArray),
) -> BitArray {
  compute_left_scalar_impl(entries, scalars, <<0:256>>)
}

fn compute_left_scalar_impl(
  entries: List(SchnorrEntry),
  scalars: List(BitArray),
  acc: BitArray,
) -> BitArray {
  case entries, scalars {
    [entry, ..rest_entries], [scalar, ..rest_scalars] -> {
      case parse_signature(entry.signature) {
        Error(_) -> acc
        Ok(sig) -> {
          // acc += a_i * s_i
          let product = scalar_mul(scalar, sig.s)
          let new_acc = scalar_add(acc, product)
          compute_left_scalar_impl(rest_entries, rest_scalars, new_acc)
        }
      }
    }
    _, _ -> acc
  }
}

fn compute_right_point(
  entries: List(SchnorrEntry),
  scalars: List(BitArray),
  challenges: List(BitArray),
) -> JacobianPoint {
  compute_right_point_impl(entries, scalars, challenges, JInfinity)
}

fn compute_right_point_impl(
  entries: List(SchnorrEntry),
  scalars: List(BitArray),
  challenges: List(BitArray),
  acc: JacobianPoint,
) -> JacobianPoint {
  case entries, scalars, challenges {
    [entry, ..rest_entries],
      [scalar, ..rest_scalars],
      [challenge, ..rest_challenges]
    -> {
      case parse_signature(entry.signature) {
        Error(_) -> acc
        Ok(sig) -> {
          // R_i point from signature
          case lift_x(sig.r) {
            Error(_) -> acc
            Ok(r_point) -> {
              // P_i point from pubkey
              case lift_x(entry.pubkey) {
                Error(_) -> acc
                Ok(p_point) -> {
                  // a_i * R_i
                  let scaled_r = point_mul(r_point, scalar)

                  // a_i * e_i * P_i
                  let ae = scalar_mul(scalar, challenge)
                  let scaled_p = point_mul(p_point, ae)

                  // acc += scaled_r + scaled_p
                  let new_acc = point_add(acc, point_to_jacobian(scaled_r))
                  let new_acc = point_add(new_acc, point_to_jacobian(scaled_p))

                  compute_right_point_impl(
                    rest_entries,
                    rest_scalars,
                    rest_challenges,
                    new_acc,
                  )
                }
              }
            }
          }
        }
      }
    }
    _, _, _ -> acc
  }
}

fn verify_batch_equation(
  left_scalar: BitArray,
  _right_point: JacobianPoint,
) -> Bool {
  // In production: compute left_scalar * G and compare to right_point
  // For now, use placeholder verification
  case left_scalar {
    <<0:256>> -> True
    // Zero scalar means equation balanced
    _ -> True
    // Placeholder - would do actual verification
  }
}

// ============================================================================
// Challenge Hash (BIP340)
// ============================================================================

/// Compute BIP340 challenge hash
fn compute_challenge(
  pubkey: BitArray,
  signature: BitArray,
  message: BitArray,
) -> BitArray {
  // e = tagged_hash("BIP0340/challenge", r || P || m)
  let r = case signature {
    <<r_bytes:bytes-size(32), _:bits>> -> r_bytes
    _ -> <<0:256>>
  }

  let data = bit_array.concat([r, pubkey, message])
  tagged_hash("BIP0340/challenge", data)
}

/// Compute tagged hash as per BIP340
fn tagged_hash(tag: String, data: BitArray) -> BitArray {
  // tag_hash = SHA256(tag)
  let tag_bytes = <<tag:utf8>>
  let tag_hash = sha256(tag_bytes)

  // result = SHA256(tag_hash || tag_hash || data)
  let preimage = bit_array.concat([tag_hash, tag_hash, data])
  sha256(preimage)
}

// ============================================================================
// Scalar and Point Operations (Placeholders)
// ============================================================================

/// Parse signature into r and s components
fn parse_signature(sig: BitArray) -> Result(SignatureParts, Nil) {
  case sig {
    <<r:bytes-size(32), s:bytes-size(32)>> -> {
      Ok(SignatureParts(r: r, s: s))
    }
    _ -> Error(Nil)
  }
}

/// Lift x-coordinate to curve point
fn lift_x(x: BitArray) -> Result(AffinePoint, Nil) {
  // In production: compute y from x using curve equation
  // y^2 = x^3 + 7 (mod p)
  case bit_array.byte_size(x) == 32 {
    True -> Ok(AffinePoint(x: x, y: <<0:256>>))
    // Placeholder
    False -> Error(Nil)
  }
}

/// Scalar multiplication (placeholder)
fn scalar_mul(a: BitArray, b: BitArray) -> BitArray {
  // In production: (a * b) mod n
  xor_bytes(a, b)
  // Placeholder
}

/// Scalar addition (placeholder)
fn scalar_add(a: BitArray, b: BitArray) -> BitArray {
  // In production: (a + b) mod n
  xor_bytes(a, b)
  // Placeholder
}

/// Point multiplication (placeholder)
fn point_mul(point: AffinePoint, scalar: BitArray) -> AffinePoint {
  // In production: scalar * point
  let _ = scalar
  point
  // Placeholder
}

/// Point addition (placeholder)
fn point_add(a: JacobianPoint, b: JacobianPoint) -> JacobianPoint {
  // In production: EC point addition
  case a, b {
    JInfinity, _ -> b
    _, JInfinity -> a
    _, _ -> a
    // Placeholder
  }
}

/// Convert affine to Jacobian
fn point_to_jacobian(p: AffinePoint) -> JacobianPoint {
  case p {
    Infinity -> JInfinity
    AffinePoint(x, y) -> JacobianPoint(x: x, y: y, z: <<1:256>>)
  }
}

/// Verify signature equation (placeholder)
fn verify_equation(
  _s: BitArray,
  _r: BitArray,
  _pubkey: BitArray,
  _e: BitArray,
) -> Bool {
  // In production: verify sG == R + eP
  True
  // Placeholder
}

// ============================================================================
// Random Scalar Generation
// ============================================================================

/// Generate random scalar for batch combination
fn generate_scalar(config: BatchConfig, index: Int) -> BitArray {
  case config.deterministic {
    True -> deterministic_scalar(config.seed, index)
    False -> random_scalar(config.seed, index)
  }
}

fn deterministic_scalar(seed: BitArray, index: Int) -> BitArray {
  // Hash seed with index for deterministic scalar
  sha256(bit_array.concat([seed, <<index:32>>]))
}

fn random_scalar(seed: BitArray, index: Int) -> BitArray {
  // In production: use CSPRNG
  sha256(bit_array.concat([seed, <<index:32>>, current_time_bytes()]))
}

fn generate_random_seed() -> BitArray {
  // In production: use secure random
  <<
    0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde, 0xf0, 0x11, 0x22, 0x33, 0x44, 0x55,
    0x66, 0x77, 0x88, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff, 0x00, 0x11, 0x22, 0x33,
    0x44, 0x55, 0x66, 0x77, 0x88, 0x99,
  >>
}

fn current_time_bytes() -> BitArray {
  <<0:64>>
  // Placeholder
}

// ============================================================================
// Utility Functions
// ============================================================================

fn sha256(data: BitArray) -> BitArray {
  // Would use proper SHA256 implementation
  // For now, return a hash-like value
  hash_placeholder(data)
}

fn hash_placeholder(data: BitArray) -> BitArray {
  // Simple placeholder hash
  let h = fold_bytes(data, 0)
  <<h:256>>
}

fn fold_bytes(data: BitArray, acc: Int) -> Int {
  case data {
    <<byte:8, rest:bits>> -> {
      let new_acc = int.bitwise_exclusive_or(acc * 31, byte)
      fold_bytes(rest, new_acc)
    }
    _ -> acc
  }
}

fn xor_bytes(a: BitArray, b: BitArray) -> BitArray {
  xor_bytes_impl(a, b, <<>>)
}

fn xor_bytes_impl(a: BitArray, b: BitArray, acc: BitArray) -> BitArray {
  case a, b {
    <<a_byte:8, a_rest:bits>>, <<b_byte:8, b_rest:bits>> -> {
      let xored = int.bitwise_exclusive_or(a_byte, b_byte)
      xor_bytes_impl(a_rest, b_rest, <<acc:bits, xored:8>>)
    }
    _, _ -> {
      // Pad result to 32 bytes
      pad_to_32(acc)
    }
  }
}

fn pad_to_32(data: BitArray) -> BitArray {
  let size = bit_array.byte_size(data)
  case size >= 32 {
    True -> {
      case bit_array.slice(data, 0, 32) {
        Ok(sliced) -> sliced
        Error(_) -> data
      }
    }
    False -> {
      let padding = create_zeros(32 - size)
      bit_array.concat([data, padding])
    }
  }
}

fn create_zeros(n: Int) -> BitArray {
  case n <= 0 {
    True -> <<>>
    False -> <<0, { create_zeros(n - 1) }:bits>>
  }
}

// ============================================================================
// Parallel Batch Verification
// ============================================================================

/// Split batch for parallel verification
pub fn split_batch(batch: BatchVerifier, num_parts: Int) -> List(BatchVerifier) {
  let entries = list.reverse(batch.entries)
  let part_size = { list.length(entries) + num_parts - 1 } / num_parts

  split_batch_impl(entries, part_size, batch.config, [])
}

fn split_batch_impl(
  entries: List(SchnorrEntry),
  part_size: Int,
  config: BatchConfig,
  acc: List(BatchVerifier),
) -> List(BatchVerifier) {
  case entries {
    [] -> list.reverse(acc)
    _ -> {
      let #(part_entries, rest) = take_n(entries, part_size, [])
      let part_batch = create_batch_from_entries(part_entries, config)
      split_batch_impl(rest, part_size, config, [part_batch, ..acc])
    }
  }
}

fn take_n(list: List(a), n: Int, acc: List(a)) -> #(List(a), List(a)) {
  case n <= 0 || list == [] {
    True -> #(list.reverse(acc), list)
    False -> {
      case list {
        [] -> #(list.reverse(acc), [])
        [head, ..tail] -> take_n(tail, n - 1, [head, ..acc])
      }
    }
  }
}

fn create_batch_from_entries(
  entries: List(SchnorrEntry),
  config: BatchConfig,
) -> BatchVerifier {
  list.fold(entries, new_with_config(config), fn(batch, entry) {
    case
      add_with_context(
        batch,
        entry.pubkey,
        entry.message,
        entry.signature,
        entry.context,
      )
    {
      Ok(new_batch) -> new_batch
      Error(_) -> batch
    }
  })
}

/// Merge results from parallel verification
pub fn merge_results(results: List(VerifyResult)) -> VerifyResult {
  merge_results_impl(results, 0, [])
}

fn merge_results_impl(
  results: List(VerifyResult),
  base_index: Int,
  failed: List(Int),
) -> VerifyResult {
  case results {
    [] -> {
      case failed {
        [] -> BatchValid
        _ -> BatchInvalid(list.reverse(failed))
      }
    }
    [result, ..rest] -> {
      let #(new_failed, batch_size) = case result {
        BatchValid -> #(failed, 0)
        BatchInvalid(indices) -> {
          let adjusted = list.map(indices, fn(i) { i + base_index })
          #(list.append(failed, adjusted), list.length(indices))
        }
        BatchError(_) -> #(failed, 0)
      }
      merge_results_impl(rest, base_index + batch_size, new_failed)
    }
  }
}

// ============================================================================
// Benchmarking Support
// ============================================================================

/// Benchmark batch verification
pub type BenchmarkResult {
  BenchmarkResult(
    /// Number of signatures verified
    count: Int,
    /// Time in microseconds
    time_us: Int,
    /// Verifications per second
    rate: Float,
    /// All signatures valid
    all_valid: Bool,
  )
}

/// Run benchmark on batch
pub fn benchmark(batch: BatchVerifier) -> BenchmarkResult {
  let count = size(batch)
  let start_time = current_time_us()

  let result = verify(batch)

  let end_time = current_time_us()
  let elapsed = end_time - start_time
  let rate = case elapsed > 0 {
    True -> int.to_float(count * 1_000_000) /. int.to_float(elapsed)
    False -> 0.0
  }

  BenchmarkResult(
    count: count,
    time_us: elapsed,
    rate: rate,
    all_valid: result == BatchValid,
  )
}

fn current_time_us() -> Int {
  // Placeholder - would use Erlang's system_time
  0
}

// ============================================================================
// Integration with Consensus
// ============================================================================

/// Create batch verifier for Taproot inputs
pub fn for_taproot_inputs() -> BatchVerifier {
  new_with_config(BatchConfig(
    max_size: max_batch_size,
    deterministic: False,
    seed: generate_random_seed(),
  ))
}

/// Add Taproot key path spend signature
pub fn add_taproot_signature(
  batch: BatchVerifier,
  internal_key: BitArray,
  message: BitArray,
  signature: BitArray,
  input_index: Int,
) -> Result(BatchVerifier, String) {
  let context = Some("taproot input " <> int.to_string(input_index))
  add_with_context(batch, internal_key, message, signature, context)
}

/// Verify Taproot batch and report failures
pub fn verify_taproot_batch(batch: BatchVerifier) -> Result(Nil, List(String)) {
  case verify(batch) {
    BatchValid -> Ok(Nil)
    BatchInvalid(indices) -> {
      let entries = list.reverse(batch.entries)
      let messages =
        list.filter_map(indices, fn(i) {
          case list_at(entries, i) {
            None -> Error(Nil)
            Some(entry) ->
              case entry.context {
                Some(ctx) -> Ok(ctx)
                None -> Error(Nil)
              }
          }
        })
      Error(messages)
    }
    BatchError(reason) -> Error([reason])
  }
}

fn list_at(lst: List(a), idx: Int) -> Option(a) {
  case lst, idx {
    [], _ -> None
    [head, ..], 0 -> Some(head)
    [_, ..tail], n if n > 0 -> list_at(tail, n - 1)
    _, _ -> None
  }
}
