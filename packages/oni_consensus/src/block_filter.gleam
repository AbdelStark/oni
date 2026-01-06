// block_filter.gleam - Compact Block Filters (BIP157/158)
//
// This module implements compact block filters for efficient light client
// transaction matching. It provides:
// - Golomb-Rice Coding (GCS) for space-efficient set representation
// - Basic filter construction (outputs + prevouts)
// - Filter header chain for commitment
// - Query interface for matching
//
// BIP157: Client Side Block Filtering
// BIP158: Compact Block Filters for Light Clients

import gleam/bit_array
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import oni_bitcoin.{
  type Block, type BlockHash, type Hash256, type OutPoint, type Transaction,
}

// ============================================================================
// Constants (BIP158)
// ============================================================================

/// Parameter P - false positive rate = 1/M where M = 2^P
pub const filter_p = 19

/// Parameter M = 2^P = 524288
pub const filter_m = 524_288

/// Parameter N - number of hash functions (1 for basic)
pub const filter_n = 1

/// Filter type: Basic (0x00) - includes prevouts and output scripts
pub const filter_type_basic = 0

/// Filter type: Extended (0x01) - includes additional data
pub const filter_type_extended = 1

/// SipHash key from block hash (first 16 bytes)
pub const siphash_key_size = 16

// ============================================================================
// Types
// ============================================================================

/// A compact block filter
pub type BlockFilter {
  BlockFilter(
    filter_type: Int,
    block_hash: BlockHash,
    n_elements: Int,
    filter_data: BitArray,
  )
}

/// Filter header for the filter chain
pub type FilterHeader {
  FilterHeader(
    filter_type: Int,
    block_hash: BlockHash,
    filter_hash: Hash256,
    prev_header: Hash256,
    header: Hash256,
  )
}

/// GCS (Golomb-Coded Set) parameters
pub type GcsParams {
  GcsParams(p: Int, m: Int, n: Int, modulus: Int)
}

/// Create default GCS params for basic filter
pub fn basic_gcs_params(n_elements: Int) -> GcsParams {
  let modulus = n_elements * filter_m
  GcsParams(p: filter_p, m: filter_m, n: n_elements, modulus: modulus)
}

// ============================================================================
// Filter Construction
// ============================================================================

/// Construct a basic block filter (BIP158)
pub fn construct_basic_filter(
  block: Block,
  block_hash: BlockHash,
) -> BlockFilter {
  // Collect all elements to include in the filter
  let elements = collect_filter_elements(block)

  // Remove duplicates
  let unique_elements = list.unique(elements)
  let n = list.length(unique_elements)

  case n {
    0 ->
      BlockFilter(
        filter_type: filter_type_basic,
        block_hash: block_hash,
        n_elements: 0,
        filter_data: <<>>,
      )
    _ -> {
      // Get SipHash key from block hash
      let key = siphash_key_from_block_hash(block_hash)

      // Hash elements to integers
      let params = basic_gcs_params(n)
      let hashed =
        list.map(unique_elements, fn(elem) {
          hash_to_range(elem, key, params.modulus)
        })

      // Sort hashed values
      let sorted = list.sort(hashed, int.compare)

      // Compute deltas
      let deltas = compute_deltas(sorted)

      // Encode using Golomb-Rice coding
      let filter_data = golomb_rice_encode(deltas, params.p)

      BlockFilter(
        filter_type: filter_type_basic,
        block_hash: block_hash,
        n_elements: n,
        filter_data: filter_data,
      )
    }
  }
}

/// Collect filter elements from a block
fn collect_filter_elements(block: Block) -> List(BitArray) {
  list.flat_map(block.transactions, fn(tx) { collect_tx_elements(tx) })
}

/// Collect filter elements from a transaction
fn collect_tx_elements(tx: Transaction) -> List(BitArray) {
  // Collect output scripts (for matching receiving addresses)
  let output_scripts =
    list.filter_map(tx.outputs, fn(output) {
      let script_bytes = oni_bitcoin.script_to_bytes(output.script_pubkey)
      // Skip empty scripts and OP_RETURN outputs
      case bit_array.byte_size(script_bytes) {
        0 -> Error(Nil)
        _ ->
          case is_op_return(script_bytes) {
            True -> Error(Nil)
            False -> Ok(script_bytes)
          }
      }
    })

  // Collect input prevout scripts (for matching spent outputs)
  // Note: For the coinbase tx, skip inputs as they don't have prevouts
  let input_outpoints = case is_coinbase(tx) {
    True -> []
    False ->
      list.map(tx.inputs, fn(input) { serialize_outpoint(input.prevout) })
  }

  list.append(output_scripts, input_outpoints)
}

/// Check if a script is OP_RETURN
fn is_op_return(script: BitArray) -> Bool {
  case script {
    <<0x6a:8, _rest:bits>> -> True
    _ -> False
  }
}

/// Check if transaction is coinbase
fn is_coinbase(tx: Transaction) -> Bool {
  case tx.inputs {
    [input] -> oni_bitcoin.outpoint_is_null(input.prevout)
    _ -> False
  }
}

/// Serialize an outpoint
fn serialize_outpoint(outpoint: OutPoint) -> BitArray {
  bit_array.concat([
    outpoint.txid.hash.bytes,
    <<outpoint.vout:32-little>>,
  ])
}

// ============================================================================
// SipHash-2-4
// ============================================================================

/// Extract SipHash key from block hash (first 16 bytes)
fn siphash_key_from_block_hash(block_hash: BlockHash) -> BitArray {
  case bit_array.slice(block_hash.hash.bytes, 0, siphash_key_size) {
    Ok(key) -> key
    Error(_) -> <<0:128>>
  }
}

/// Hash data to a value in range [0, modulus) using SipHash-2-4
fn hash_to_range(data: BitArray, key: BitArray, modulus: Int) -> Int {
  let hash = siphash_2_4(data, key)
  // Fast reduction using multiplication
  int.bitwise_and(hash * modulus / 0x10000000000000000, modulus - 1)
}

/// SipHash-2-4 implementation
/// This is a simplified implementation for BIP158
fn siphash_2_4(data: BitArray, key: BitArray) -> Int {
  // Extract key parts (k0, k1)
  let #(k0, k1) = parse_siphash_key(key)

  // Initialize state
  let v0 = int.bitwise_exclusive_or(k0, 0x736f6d6570736575)
  let v1 = int.bitwise_exclusive_or(k1, 0x646f72616e646f6d)
  let v2 = int.bitwise_exclusive_or(k0, 0x6c7967656e657261)
  let v3 = int.bitwise_exclusive_or(k1, 0x7465646279746573)

  // Process data in 8-byte blocks
  let #(v0, v1, v2, v3) = siphash_process_blocks(data, v0, v1, v2, v3)

  // Finalization
  let b = bit_array.byte_size(data)
  let last_block = siphash_last_block(data, b)

  let v3_2 = int.bitwise_exclusive_or(v3, last_block)
  let #(v0_2, v1_2, v2_2, v3_2) =
    siphash_round(siphash_round(#(v0, v1, v2, v3_2)))
  let v0_3 = int.bitwise_exclusive_or(v0_2, last_block)

  let v2_3 = int.bitwise_exclusive_or(v2_2, 0xff)
  let #(v0_4, v1_4, v2_4, v3_4) =
    siphash_round(
      siphash_round(siphash_round(siphash_round(#(v0_3, v1_2, v2_3, v3_2)))),
    )

  int.bitwise_exclusive_or(
    int.bitwise_exclusive_or(v0_4, v1_4),
    int.bitwise_exclusive_or(v2_4, v3_4),
  )
  |> int.bitwise_and(0xFFFFFFFFFFFFFFFF)
}

fn parse_siphash_key(key: BitArray) -> #(Int, Int) {
  case key {
    <<k0:64-little, k1:64-little, _rest:bits>> -> #(k0, k1)
    <<k0:64-little>> -> #(k0, 0)
    _ -> #(0, 0)
  }
}

fn siphash_process_blocks(
  data: BitArray,
  v0: Int,
  v1: Int,
  v2: Int,
  v3: Int,
) -> #(Int, Int, Int, Int) {
  case data {
    <<block:64-little, rest:bits>> -> {
      case bit_array.byte_size(rest) >= 8 {
        True -> {
          let v3_new = int.bitwise_exclusive_or(v3, block)
          let #(v0_new, v1_new, v2_new, v3_new) =
            siphash_round(siphash_round(#(v0, v1, v2, v3_new)))
          let v0_new = int.bitwise_exclusive_or(v0_new, block)
          siphash_process_blocks(rest, v0_new, v1_new, v2_new, v3_new)
        }
        False -> #(v0, v1, v2, v3)
      }
    }
    _ -> #(v0, v1, v2, v3)
  }
}

fn siphash_round(state: #(Int, Int, Int, Int)) -> #(Int, Int, Int, Int) {
  let #(v0, v1, v2, v3) = state

  let v0 = int.bitwise_and(v0 + v1, 0xFFFFFFFFFFFFFFFF)
  let v1 = rotl64(v1, 13)
  let v1 = int.bitwise_exclusive_or(v1, v0)
  let v0 = rotl64(v0, 32)

  let v2 = int.bitwise_and(v2 + v3, 0xFFFFFFFFFFFFFFFF)
  let v3 = rotl64(v3, 16)
  let v3 = int.bitwise_exclusive_or(v3, v2)

  let v0 = int.bitwise_and(v0 + v3, 0xFFFFFFFFFFFFFFFF)
  let v3 = rotl64(v3, 21)
  let v3 = int.bitwise_exclusive_or(v3, v0)

  let v2 = int.bitwise_and(v2 + v1, 0xFFFFFFFFFFFFFFFF)
  let v1 = rotl64(v1, 17)
  let v1 = int.bitwise_exclusive_or(v1, v2)
  let v2 = rotl64(v2, 32)

  #(v0, v1, v2, v3)
}

fn rotl64(x: Int, n: Int) -> Int {
  let masked = int.bitwise_and(x, 0xFFFFFFFFFFFFFFFF)
  int.bitwise_and(
    int.bitwise_or(
      int.bitwise_shift_left(masked, n),
      int.bitwise_shift_right(masked, 64 - n),
    ),
    0xFFFFFFFFFFFFFFFF,
  )
}

fn siphash_last_block(data: BitArray, length: Int) -> Int {
  let len_byte = int.bitwise_shift_left(int.bitwise_and(length, 0xff), 56)
  let remaining_bytes = int.bitwise_and(length, 7)

  // Get last partial block
  let offset = length - remaining_bytes
  let partial = case bit_array.slice(data, offset, remaining_bytes) {
    Ok(p) -> p
    Error(_) -> <<>>
  }

  // Pad to 8 bytes
  let padded = siphash_pad_block(partial, remaining_bytes, 0)
  int.bitwise_or(len_byte, padded)
}

fn siphash_pad_block(data: BitArray, remaining: Int, acc: Int) -> Int {
  case data, remaining {
    <<b:8, rest:bits>>, n -> {
      case n > 0 {
        True -> {
          let shift = 8 * { remaining - n }
          let new_acc = int.bitwise_or(acc, int.bitwise_shift_left(b, shift))
          siphash_pad_block(rest, n - 1, new_acc)
        }
        False -> acc
      }
    }
    _, _ -> acc
  }
}

// ============================================================================
// Golomb-Rice Coding
// ============================================================================

/// Compute deltas from sorted values
fn compute_deltas(sorted: List(Int)) -> List(Int) {
  compute_deltas_acc(sorted, 0, [])
}

fn compute_deltas_acc(sorted: List(Int), prev: Int, acc: List(Int)) -> List(Int) {
  case sorted {
    [] -> list.reverse(acc)
    [val, ..rest] -> {
      let delta = val - prev
      compute_deltas_acc(rest, val, [delta, ..acc])
    }
  }
}

/// Encode deltas using Golomb-Rice coding
pub fn golomb_rice_encode(deltas: List(Int), p: Int) -> BitArray {
  let bits = list.flat_map(deltas, fn(delta) { encode_single_gr(delta, p) })
  bits_to_bytes(bits)
}

/// Encode a single value using Golomb-Rice
fn encode_single_gr(value: Int, p: Int) -> List(Int) {
  let divisor = int.bitwise_shift_left(1, p)
  let quotient = value / divisor
  let remainder = int.bitwise_and(value, divisor - 1)

  // Unary encode quotient (q ones followed by a zero)
  let unary = list.repeat(1, quotient) |> list.append([0])

  // Binary encode remainder (p bits)
  let binary = encode_binary(remainder, p, [])

  list.append(unary, binary)
}

fn encode_binary(value: Int, bits: Int, acc: List(Int)) -> List(Int) {
  case bits {
    0 -> list.reverse(acc)
    _ -> {
      let bit = int.bitwise_and(int.bitwise_shift_right(value, bits - 1), 1)
      encode_binary(value, bits - 1, [bit, ..acc])
    }
  }
}

/// Convert bits to bytes
fn bits_to_bytes(bits: List(Int)) -> BitArray {
  bits_to_bytes_acc(bits, <<>>, 0, 0)
}

fn bits_to_bytes_acc(
  bits: List(Int),
  acc: BitArray,
  current_byte: Int,
  bit_pos: Int,
) -> BitArray {
  case bits {
    [] -> {
      // Flush remaining bits
      case bit_pos > 0 {
        True -> {
          let padded = int.bitwise_shift_left(current_byte, 8 - bit_pos)
          bit_array.append(acc, <<padded:8>>)
        }
        False -> acc
      }
    }
    [bit, ..rest] -> {
      let new_byte =
        int.bitwise_or(int.bitwise_shift_left(current_byte, 1), bit)
      let new_pos = bit_pos + 1
      case new_pos >= 8 {
        True -> {
          let new_acc = bit_array.append(acc, <<new_byte:8>>)
          bits_to_bytes_acc(rest, new_acc, 0, 0)
        }
        False -> bits_to_bytes_acc(rest, acc, new_byte, new_pos)
      }
    }
  }
}

/// Decode Golomb-Rice encoded data
pub fn golomb_rice_decode(data: BitArray, n_elements: Int, p: Int) -> List(Int) {
  let bits = bytes_to_bits(data)
  decode_gr_values(bits, n_elements, p, 0, [])
}

fn bytes_to_bits(data: BitArray) -> List(Int) {
  bytes_to_bits_acc(data, [])
}

fn bytes_to_bits_acc(data: BitArray, acc: List(Int)) -> List(Int) {
  case data {
    <<>> -> list.reverse(acc)
    <<byte:8, rest:bits>> -> {
      let bits = [
        int.bitwise_and(int.bitwise_shift_right(byte, 7), 1),
        int.bitwise_and(int.bitwise_shift_right(byte, 6), 1),
        int.bitwise_and(int.bitwise_shift_right(byte, 5), 1),
        int.bitwise_and(int.bitwise_shift_right(byte, 4), 1),
        int.bitwise_and(int.bitwise_shift_right(byte, 3), 1),
        int.bitwise_and(int.bitwise_shift_right(byte, 2), 1),
        int.bitwise_and(int.bitwise_shift_right(byte, 1), 1),
        int.bitwise_and(byte, 1),
      ]
      bytes_to_bits_acc(rest, list.append(list.reverse(bits), acc))
    }
    // Handle partial bytes at end (less than 8 bits)
    _ -> list.reverse(acc)
  }
}

fn decode_gr_values(
  bits: List(Int),
  remaining: Int,
  p: Int,
  prev: Int,
  acc: List(Int),
) -> List(Int) {
  case remaining <= 0 {
    True -> list.reverse(acc)
    False -> {
      case decode_single_gr(bits, p) {
        Error(_) -> list.reverse(acc)
        Ok(#(delta, rest_bits)) -> {
          let value = prev + delta
          decode_gr_values(rest_bits, remaining - 1, p, value, [value, ..acc])
        }
      }
    }
  }
}

fn decode_single_gr(bits: List(Int), p: Int) -> Result(#(Int, List(Int)), Nil) {
  // Decode unary part (count 1s until 0)
  case decode_unary(bits, 0) {
    Error(_) -> Error(Nil)
    Ok(#(quotient, rest)) -> {
      // Decode binary part (p bits)
      case decode_binary(rest, p) {
        Error(_) -> Error(Nil)
        Ok(#(remainder, final_rest)) -> {
          let value = quotient * int.bitwise_shift_left(1, p) + remainder
          Ok(#(value, final_rest))
        }
      }
    }
  }
}

fn decode_unary(bits: List(Int), count: Int) -> Result(#(Int, List(Int)), Nil) {
  case bits {
    [] -> Error(Nil)
    [0, ..rest] -> Ok(#(count, rest))
    [1, ..rest] -> decode_unary(rest, count + 1)
    _ -> Error(Nil)
  }
}

fn decode_binary(bits: List(Int), p: Int) -> Result(#(Int, List(Int)), Nil) {
  decode_binary_acc(bits, p, 0)
}

fn decode_binary_acc(
  bits: List(Int),
  remaining: Int,
  acc: Int,
) -> Result(#(Int, List(Int)), Nil) {
  case remaining {
    0 -> Ok(#(acc, bits))
    _ -> {
      case bits {
        [] -> Error(Nil)
        [bit, ..rest] -> {
          let new_acc = int.bitwise_or(int.bitwise_shift_left(acc, 1), bit)
          decode_binary_acc(rest, remaining - 1, new_acc)
        }
      }
    }
  }
}

// ============================================================================
// Filter Matching
// ============================================================================

/// Check if any element matches the filter
pub fn filter_match(filter: BlockFilter, elements: List(BitArray)) -> Bool {
  case filter.n_elements {
    0 -> False
    n -> {
      let key = siphash_key_from_block_hash(filter.block_hash)
      let params = basic_gcs_params(n)

      // Hash query elements
      let query_hashes =
        list.map(elements, fn(elem) { hash_to_range(elem, key, params.modulus) })
        |> list.sort(int.compare)

      // Decode filter values
      let filter_values = golomb_rice_decode(filter.filter_data, n, params.p)

      // Check for intersection
      check_intersection(query_hashes, filter_values)
    }
  }
}

/// Check if any element matches the filter (single element convenience)
pub fn filter_match_single(filter: BlockFilter, element: BitArray) -> Bool {
  filter_match(filter, [element])
}

/// Check if two sorted lists have any common element
fn check_intersection(list1: List(Int), list2: List(Int)) -> Bool {
  case list1, list2 {
    [], _ -> False
    _, [] -> False
    [a, ..rest1], [b, ..rest2] -> {
      case int.compare(a, b) {
        order.Lt -> check_intersection(rest1, [b, ..rest2])
        order.Gt -> check_intersection([a, ..rest1], rest2)
        order.Eq -> True
      }
    }
  }
}

// ============================================================================
// Filter Headers (Chain)
// ============================================================================

/// Compute filter hash
pub fn filter_hash(filter: BlockFilter) -> Hash256 {
  oni_bitcoin.hash256_digest(filter.filter_data)
}

/// Compute filter header
pub fn compute_filter_header(
  filter: BlockFilter,
  prev_header: Hash256,
) -> FilterHeader {
  let fhash = filter_hash(filter)

  // header = hash(filter_hash || prev_header)
  let header_preimage = bit_array.concat([fhash.bytes, prev_header.bytes])
  let header = oni_bitcoin.hash256_digest(header_preimage)

  FilterHeader(
    filter_type: filter.filter_type,
    block_hash: filter.block_hash,
    filter_hash: fhash,
    prev_header: prev_header,
    header: header,
  )
}

/// Genesis filter header (prev_header is all zeros)
pub fn genesis_filter_header(filter: BlockFilter) -> FilterHeader {
  let zero_hash = oni_bitcoin.Hash256(<<0:256>>)
  compute_filter_header(filter, zero_hash)
}

// ============================================================================
// Serialization
// ============================================================================

/// Serialize a block filter
pub fn encode_filter(filter: BlockFilter) -> BitArray {
  let n_bytes = oni_bitcoin.compact_size_encode(filter.n_elements)
  bit_array.concat([
    n_bytes,
    filter.filter_data,
  ])
}

/// Deserialize a block filter
pub fn decode_filter(
  data: BitArray,
  filter_type: Int,
  block_hash: BlockHash,
) -> Result(BlockFilter, Nil) {
  case oni_bitcoin.compact_size_decode(data) {
    Error(_) -> Error(Nil)
    Ok(#(n_elements, rest)) -> {
      Ok(BlockFilter(
        filter_type: filter_type,
        block_hash: block_hash,
        n_elements: n_elements,
        filter_data: rest,
      ))
    }
  }
}

/// Serialize filter header
pub fn encode_filter_header(header: FilterHeader) -> BitArray {
  header.header.bytes
}

// ============================================================================
// Filter Messages (BIP157 P2P)
// ============================================================================

/// Filter types for getcfilters/cfilter messages
pub type FilterType {
  BasicFilter
  ExtendedFilter
}

pub fn filter_type_to_byte(ft: FilterType) -> Int {
  case ft {
    BasicFilter -> 0
    ExtendedFilter -> 1
  }
}

pub fn filter_type_from_byte(b: Int) -> Option(FilterType) {
  case b {
    0 -> Some(BasicFilter)
    1 -> Some(ExtendedFilter)
    _ -> None
  }
}
