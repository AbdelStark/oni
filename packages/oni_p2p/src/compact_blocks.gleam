// compact_blocks.gleam - BIP152 Compact Block Relay Implementation
//
// This module implements BIP152 (Compact Block Relay) for efficient
// block propagation. It includes:
// - Compact block encoding/decoding
// - Short transaction ID computation
// - Block reconstruction from compact blocks
// - High/low bandwidth mode support
//
// Reference: https://github.com/bitcoin/bips/blob/master/bip-0152.mediawiki

import gleam/bit_array
import gleam/bytes_builder
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/result
import oni_bitcoin

// ============================================================================
// Constants
// ============================================================================

/// Compact block protocol version
pub const compact_block_version_1 = 1

pub const compact_block_version_2 = 2

/// Size of short transaction IDs (6 bytes)
pub const short_txid_size = 6

/// Maximum number of prefilled transactions
pub const max_prefilled_txs = 10_000

/// Maximum number of short IDs in a compact block
pub const max_short_ids = 100_000

// ============================================================================
// Types
// ============================================================================

/// Compact block structure (sendcmpct version 1 or 2)
pub type CompactBlock {
  CompactBlock(
    /// Block header
    header: oni_bitcoin.BlockHeader,
    /// Nonce for short ID computation
    nonce: Int,
    /// Short transaction IDs
    short_ids: List(ShortTxId),
    /// Pre-filled transactions (always includes coinbase)
    prefilled_txns: List(PrefilledTx),
  )
}

/// 6-byte short transaction ID
pub type ShortTxId {
  ShortTxId(bytes: BitArray)
}

/// Pre-filled transaction with its index
pub type PrefilledTx {
  PrefilledTx(
    /// Differential index
    index: Int,
    /// The transaction
    tx: oni_bitcoin.Transaction,
  )
}

/// Block transaction request message
pub type BlockTxnRequest {
  BlockTxnRequest(
    /// Block hash
    block_hash: oni_bitcoin.BlockHash,
    /// Indices of requested transactions
    indexes: List(Int),
  )
}

/// Block transactions response message
pub type BlockTxn {
  BlockTxn(
    /// Block hash
    block_hash: oni_bitcoin.BlockHash,
    /// Requested transactions
    transactions: List(oni_bitcoin.Transaction),
  )
}

/// Sendcmpct message
pub type SendCmpct {
  SendCmpct(
    /// Announce compact blocks (high bandwidth mode)
    announce: Bool,
    /// Version (1 or 2)
    version: Int,
  )
}

/// Compact block reconstruction state
pub type ReconstructionState {
  ReconstructionState(
    /// The compact block being reconstructed
    compact_block: CompactBlock,
    /// Block hash for lookups
    block_hash: oni_bitcoin.BlockHash,
    /// Transactions we have (by absolute index)
    available_txs: Dict(Int, oni_bitcoin.Transaction),
    /// Short ID to absolute index mapping
    short_id_to_index: Dict(BitArray, Int),
    /// Missing transaction indices
    missing_indices: List(Int),
    /// SipHash key from header + nonce
    siphash_key: #(Int, Int),
  )
}

/// Result of block reconstruction
pub type ReconstructionResult {
  /// Block fully reconstructed
  Complete(oni_bitcoin.Block)
  /// Need more transactions
  NeedTxs(List(Int))
  /// Reconstruction failed
  Failed(String)
}

// ============================================================================
// Short Transaction ID Computation
// ============================================================================

/// Compute SipHash-2-4 key from block header and nonce
pub fn compute_siphash_key(
  header: oni_bitcoin.BlockHeader,
  nonce: Int,
) -> #(Int, Int) {
  // Serialize header and nonce
  let header_bytes = oni_bitcoin.encode_block_header(header)
  let nonce_bytes = encode_le_u64(nonce)

  // Compute SHA256 of (header || nonce)
  let preimage = bit_array.concat([header_bytes, nonce_bytes])
  let hash = oni_bitcoin.sha256d(preimage)

  // First 16 bytes of hash become the SipHash key
  case hash {
    <<k0_bytes:bytes-size(8), k1_bytes:bytes-size(8), _:bytes>> -> {
      let k0 = decode_le_u64(k0_bytes)
      let k1 = decode_le_u64(k1_bytes)
      #(k0, k1)
    }
    _ -> #(0, 0)
  }
}

/// Compute short transaction ID for a transaction
pub fn compute_short_txid(
  tx: oni_bitcoin.Transaction,
  siphash_key: #(Int, Int),
  use_wtxid: Bool,
) -> ShortTxId {
  // Get txid or wtxid depending on version
  let id = case use_wtxid {
    True -> {
      let wtxid = oni_bitcoin.wtxid_from_tx(tx)
      wtxid.hash.bytes
    }
    False -> {
      let txid = oni_bitcoin.txid_from_tx(tx)
      txid.hash.bytes
    }
  }

  // Compute SipHash-2-4 of the txid
  let #(k0, k1) = siphash_key
  let hash = siphash_2_4(id, k0, k1)

  // Take first 6 bytes
  let short_id = bit_array.slice(encode_le_u64(hash), 0, short_txid_size)
  case short_id {
    Ok(bytes) -> ShortTxId(bytes: bytes)
    Error(_) -> ShortTxId(bytes: <<0, 0, 0, 0, 0, 0>>)
  }
}

/// Simple SipHash-2-4 implementation
fn siphash_2_4(data: BitArray, k0: Int, k1: Int) -> Int {
  // Initialize state
  let v0 = int.bitwise_exclusive_or(k0, 0x736f6d6570736575)
  let v1 = int.bitwise_exclusive_or(k1, 0x646f72616e646f6d)
  let v2 = int.bitwise_exclusive_or(k0, 0x6c7967656e657261)
  let v3 = int.bitwise_exclusive_or(k1, 0x7465646279746573)

  // Process input
  let #(v0, v1, v2, v3) = siphash_process(data, v0, v1, v2, v3)

  // Finalize
  let v2 = int.bitwise_exclusive_or(v2, 0xff)
  let #(v0, v1, v2, v3) = sip_round(v0, v1, v2, v3)
  let #(v0, v1, v2, v3) = sip_round(v0, v1, v2, v3)
  let #(v0, v1, v2, v3) = sip_round(v0, v1, v2, v3)
  let #(v0, v1, v2, v3) = sip_round(v0, v1, v2, v3)

  // Return result
  v0
  |> int.bitwise_exclusive_or(v1)
  |> int.bitwise_exclusive_or(v2)
  |> int.bitwise_exclusive_or(v3)
}

fn siphash_process(
  data: BitArray,
  v0: Int,
  v1: Int,
  v2: Int,
  v3: Int,
) -> #(Int, Int, Int, Int) {
  case data {
    <<word:little-size(64), rest:bytes>> -> {
      let v3 = int.bitwise_exclusive_or(v3, word)
      let #(v0, v1, v2, v3) = sip_round(v0, v1, v2, v3)
      let #(v0, v1, v2, v3) = sip_round(v0, v1, v2, v3)
      let v0 = int.bitwise_exclusive_or(v0, word)
      siphash_process(rest, v0, v1, v2, v3)
    }
    _ -> {
      // Handle remaining bytes (padding with length)
      let len = bit_array.byte_size(data)
      let padded = pad_to_8_bytes(data, len)
      let word = case padded {
        <<w:little-size(64)>> -> w
        _ -> 0
      }
      let v3 = int.bitwise_exclusive_or(v3, word)
      let #(v0, v1, v2, v3) = sip_round(v0, v1, v2, v3)
      let #(v0, v1, v2, v3) = sip_round(v0, v1, v2, v3)
      let v0 = int.bitwise_exclusive_or(v0, word)
      #(v0, v1, v2, v3)
    }
  }
}

fn pad_to_8_bytes(data: BitArray, original_len: Int) -> BitArray {
  let padding_needed = 8 - bit_array.byte_size(data)
  let len_byte = int.bitwise_and(original_len, 0xff)
  case padding_needed {
    0 -> data
    n -> {
      let padding = create_zero_bytes(n - 1)
      bit_array.concat([data, padding, <<len_byte>>])
    }
  }
}

fn create_zero_bytes(n: Int) -> BitArray {
  case n <= 0 {
    True -> <<>>
    False -> bit_array.concat([<<0>>, create_zero_bytes(n - 1)])
  }
}

fn sip_round(v0: Int, v1: Int, v2: Int, v3: Int) -> #(Int, Int, Int, Int) {
  let v0 = int.bitwise_and(v0 + v1, 0xffffffffffffffff)
  let v1 = rotate_left_64(v1, 13)
  let v1 = int.bitwise_exclusive_or(v1, v0)
  let v0 = rotate_left_64(v0, 32)

  let v2 = int.bitwise_and(v2 + v3, 0xffffffffffffffff)
  let v3 = rotate_left_64(v3, 16)
  let v3 = int.bitwise_exclusive_or(v3, v2)

  let v0 = int.bitwise_and(v0 + v3, 0xffffffffffffffff)
  let v3 = rotate_left_64(v3, 21)
  let v3 = int.bitwise_exclusive_or(v3, v0)

  let v2 = int.bitwise_and(v2 + v1, 0xffffffffffffffff)
  let v1 = rotate_left_64(v1, 17)
  let v1 = int.bitwise_exclusive_or(v1, v2)
  let v2 = rotate_left_64(v2, 32)

  #(v0, v1, v2, v3)
}

fn rotate_left_64(value: Int, bits: Int) -> Int {
  let left = int.bitwise_shift_left(value, bits)
  let right = int.bitwise_shift_right(value, 64 - bits)
  int.bitwise_and(int.bitwise_or(left, right), 0xffffffffffffffff)
}

// ============================================================================
// Compact Block Encoding/Decoding
// ============================================================================

/// Create a compact block from a full block
pub fn create_compact_block(
  block: oni_bitcoin.Block,
  nonce: Int,
  use_segwit: Bool,
) -> CompactBlock {
  let siphash_key = compute_siphash_key(block.header, nonce)

  // Always prefill coinbase
  let coinbase = case block.transactions {
    [cb, ..] -> cb
    [] -> oni_bitcoin.transaction_new(1, [], [], 0)
  }
  let prefilled = [PrefilledTx(index: 0, tx: coinbase)]

  // Compute short IDs for remaining transactions
  let short_ids = case block.transactions {
    [_, ..rest] -> {
      list.map(rest, fn(tx) { compute_short_txid(tx, siphash_key, use_segwit) })
    }
    [] -> []
  }

  CompactBlock(
    header: block.header,
    nonce: nonce,
    short_ids: short_ids,
    prefilled_txns: prefilled,
  )
}

/// Encode a compact block to bytes
pub fn encode_compact_block(cb: CompactBlock) -> BitArray {
  let builder =
    bytes_builder.new()
    |> bytes_builder.append(oni_bitcoin.encode_block_header(cb.header))
    |> bytes_builder.append(encode_le_u64(cb.nonce))

  // Encode short IDs count and IDs
  let short_id_count = list.length(cb.short_ids)
  let builder =
    builder
    |> bytes_builder.append(oni_bitcoin.compact_size_encode(short_id_count))

  let builder =
    list.fold(cb.short_ids, builder, fn(b, sid) {
      bytes_builder.append(b, sid.bytes)
    })

  // Encode prefilled transactions
  let prefilled_count = list.length(cb.prefilled_txns)
  let builder =
    builder
    |> bytes_builder.append(oni_bitcoin.compact_size_encode(prefilled_count))

  let builder =
    list.fold(cb.prefilled_txns, builder, fn(b, ptx) {
      let idx_bytes = oni_bitcoin.compact_size_encode(ptx.index)
      let tx_bytes = oni_bitcoin.encode_tx(ptx.tx)
      b
      |> bytes_builder.append(idx_bytes)
      |> bytes_builder.append(tx_bytes)
    })

  bytes_builder.to_bit_array(builder)
}

/// Decode a compact block from bytes
pub fn decode_compact_block(
  data: BitArray,
) -> Result(#(CompactBlock, BitArray), String) {
  // Decode header (80 bytes)
  use #(header, rest) <- result.try(
    oni_bitcoin.decode_block_header(data)
    |> result.map_error(fn(_) { "Invalid block header" }),
  )

  // Decode nonce
  case rest {
    <<nonce:little-size(64), rest2:bytes>> -> {
      // Decode short ID count
      use #(short_id_count, rest3) <- result.try(
        oni_bitcoin.compact_size_decode(rest2)
        |> result.map_error(fn(_) { "Invalid short ID count" }),
      )

      // Validate count
      use _ <- result.try(case short_id_count > max_short_ids {
        True -> Error("Too many short IDs")
        False -> Ok(Nil)
      })

      // Decode short IDs
      use #(short_ids, rest4) <- result.try(
        decode_short_ids(rest3, short_id_count, []),
      )

      // Decode prefilled count
      use #(prefilled_count, rest5) <- result.try(
        oni_bitcoin.compact_size_decode(rest4)
        |> result.map_error(fn(_) { "Invalid prefilled count" }),
      )

      // Validate count
      use _ <- result.try(case prefilled_count > max_prefilled_txs {
        True -> Error("Too many prefilled transactions")
        False -> Ok(Nil)
      })

      // Decode prefilled transactions
      use #(prefilled_txns, rest6) <- result.try(decode_prefilled_txns(
        rest5,
        prefilled_count,
        [],
        0,
      ))

      Ok(#(
        CompactBlock(
          header: header,
          nonce: nonce,
          short_ids: short_ids,
          prefilled_txns: prefilled_txns,
        ),
        rest6,
      ))
    }
    _ -> Error("Insufficient data for nonce")
  }
}

fn decode_short_ids(
  data: BitArray,
  count: Int,
  acc: List(ShortTxId),
) -> Result(#(List(ShortTxId), BitArray), String) {
  case count {
    0 -> Ok(#(list.reverse(acc), data))
    _ -> {
      case data {
        <<id_bytes:bytes-size(6), rest:bytes>> -> {
          let sid = ShortTxId(bytes: id_bytes)
          decode_short_ids(rest, count - 1, [sid, ..acc])
        }
        _ -> Error("Insufficient data for short ID")
      }
    }
  }
}

fn decode_prefilled_txns(
  data: BitArray,
  count: Int,
  acc: List(PrefilledTx),
  last_index: Int,
) -> Result(#(List(PrefilledTx), BitArray), String) {
  case count {
    0 -> Ok(#(list.reverse(acc), data))
    _ -> {
      // Decode differential index
      use #(diff_index, rest1) <- result.try(
        oni_bitcoin.compact_size_decode(data)
        |> result.map_error(fn(_) { "Invalid prefilled index" }),
      )

      // Calculate absolute index
      let absolute_index = last_index + diff_index

      // Decode transaction
      use #(tx, rest2) <- result.try(
        oni_bitcoin.decode_tx(rest1)
        |> result.map_error(fn(_) { "Invalid prefilled transaction" }),
      )

      let ptx = PrefilledTx(index: absolute_index, tx: tx)
      decode_prefilled_txns(rest2, count - 1, [ptx, ..acc], absolute_index + 1)
    }
  }
}

// ============================================================================
// Block Reconstruction
// ============================================================================

/// Start reconstructing a block from a compact block and mempool
pub fn start_reconstruction(
  compact_block: CompactBlock,
  mempool_txs: List(oni_bitcoin.Transaction),
  use_segwit: Bool,
) -> ReconstructionState {
  let block_hash = oni_bitcoin.block_hash_from_header(compact_block.header)
  let siphash_key =
    compute_siphash_key(compact_block.header, compact_block.nonce)

  // Build short ID to index mapping
  let #(short_id_to_index, _) =
    list.fold(compact_block.short_ids, #(dict.new(), 0), fn(acc, sid) {
      let #(d, idx) = acc
      // Account for prefilled transactions before this index
      let adjusted_idx =
        adjust_index_for_prefilled(idx, compact_block.prefilled_txns)
      #(dict.insert(d, sid.bytes, adjusted_idx), idx + 1)
    })

  // Start with prefilled transactions
  let available_txs =
    list.fold(compact_block.prefilled_txns, dict.new(), fn(d, ptx) {
      dict.insert(d, ptx.index, ptx.tx)
    })

  // Try to fill in from mempool
  let available_txs =
    list.fold(mempool_txs, available_txs, fn(d, tx) {
      let sid = compute_short_txid(tx, siphash_key, use_segwit)
      case dict.get(short_id_to_index, sid.bytes) {
        Ok(idx) -> dict.insert(d, idx, tx)
        Error(_) -> d
      }
    })

  // Calculate total transaction count
  let total_txs =
    list.length(compact_block.short_ids)
    + list.length(compact_block.prefilled_txns)

  // Find missing indices
  let missing_indices = find_missing_indices(0, total_txs, available_txs, [])

  ReconstructionState(
    compact_block: compact_block,
    block_hash: block_hash,
    available_txs: available_txs,
    short_id_to_index: short_id_to_index,
    missing_indices: missing_indices,
    siphash_key: siphash_key,
  )
}

fn adjust_index_for_prefilled(
  short_id_index: Int,
  prefilled: List(PrefilledTx),
) -> Int {
  // Count prefilled transactions with index <= short_id_index
  let prefilled_before =
    list.fold(prefilled, 0, fn(count, ptx) {
      case ptx.index <= short_id_index + count {
        True -> count + 1
        False -> count
      }
    })
  short_id_index + prefilled_before
}

fn find_missing_indices(
  current: Int,
  total: Int,
  available: Dict(Int, oni_bitcoin.Transaction),
  acc: List(Int),
) -> List(Int) {
  case current >= total {
    True -> list.reverse(acc)
    False -> {
      case dict.has_key(available, current) {
        True -> find_missing_indices(current + 1, total, available, acc)
        False ->
          find_missing_indices(current + 1, total, available, [current, ..acc])
      }
    }
  }
}

/// Add transactions to reconstruction state
pub fn add_transactions(
  state: ReconstructionState,
  txs: List(#(Int, oni_bitcoin.Transaction)),
) -> ReconstructionState {
  let available =
    list.fold(txs, state.available_txs, fn(d, pair) {
      let #(idx, tx) = pair
      dict.insert(d, idx, tx)
    })

  let total_txs =
    list.length(state.compact_block.short_ids)
    + list.length(state.compact_block.prefilled_txns)

  let missing = find_missing_indices(0, total_txs, available, [])

  ReconstructionState(
    ..state,
    available_txs: available,
    missing_indices: missing,
  )
}

/// Try to finalize block reconstruction
pub fn finalize_reconstruction(
  state: ReconstructionState,
) -> ReconstructionResult {
  case state.missing_indices {
    [] -> {
      // All transactions available, build the block
      let total_txs =
        list.length(state.compact_block.short_ids)
        + list.length(state.compact_block.prefilled_txns)

      let transactions =
        collect_transactions(0, total_txs, state.available_txs, [])

      case transactions {
        Ok(txs) -> {
          let block =
            oni_bitcoin.Block(
              header: state.compact_block.header,
              transactions: txs,
            )
          Complete(block)
        }
        Error(msg) -> Failed(msg)
      }
    }
    missing -> NeedTxs(missing)
  }
}

fn collect_transactions(
  current: Int,
  total: Int,
  available: Dict(Int, oni_bitcoin.Transaction),
  acc: List(oni_bitcoin.Transaction),
) -> Result(List(oni_bitcoin.Transaction), String) {
  case current >= total {
    True -> Ok(list.reverse(acc))
    False -> {
      case dict.get(available, current) {
        Ok(tx) ->
          collect_transactions(current + 1, total, available, [tx, ..acc])
        Error(_) ->
          Error("Missing transaction at index " <> int.to_string(current))
      }
    }
  }
}

// ============================================================================
// Message Encoding/Decoding
// ============================================================================

/// Encode sendcmpct message
pub fn encode_sendcmpct(msg: SendCmpct) -> BitArray {
  let announce_byte = case msg.announce {
    True -> 1
    False -> 0
  }
  <<announce_byte:size(8), msg.version:little-size(64)>>
}

/// Decode sendcmpct message
pub fn decode_sendcmpct(
  data: BitArray,
) -> Result(#(SendCmpct, BitArray), String) {
  case data {
    <<announce:size(8), version:little-size(64), rest:bytes>> -> {
      Ok(#(SendCmpct(announce: announce != 0, version: version), rest))
    }
    _ -> Error("Invalid sendcmpct message")
  }
}

/// Encode getblocktxn message
pub fn encode_getblocktxn(req: BlockTxnRequest) -> BitArray {
  let builder =
    bytes_builder.new()
    |> bytes_builder.append(req.block_hash.hash.bytes)
    |> bytes_builder.append(
      oni_bitcoin.compact_size_encode(list.length(req.indexes)),
    )

  let builder =
    list.fold(req.indexes, builder, fn(b, idx) {
      bytes_builder.append(b, oni_bitcoin.compact_size_encode(idx))
    })

  bytes_builder.to_bit_array(builder)
}

/// Decode getblocktxn message
pub fn decode_getblocktxn(
  data: BitArray,
) -> Result(#(BlockTxnRequest, BitArray), String) {
  case data {
    <<hash_bytes:bytes-size(32), rest:bytes>> -> {
      use #(count, rest2) <- result.try(
        oni_bitcoin.compact_size_decode(rest)
        |> result.map_error(fn(_) { "Invalid index count" }),
      )

      use #(indexes, rest3) <- result.try(decode_indexes(rest2, count, [], 0))

      Ok(#(
        BlockTxnRequest(
          block_hash: oni_bitcoin.BlockHash(hash: oni_bitcoin.Hash256(
            bytes: hash_bytes,
          )),
          indexes: indexes,
        ),
        rest3,
      ))
    }
    _ -> Error("Invalid getblocktxn message")
  }
}

fn decode_indexes(
  data: BitArray,
  count: Int,
  acc: List(Int),
  last_idx: Int,
) -> Result(#(List(Int), BitArray), String) {
  case count {
    0 -> Ok(#(list.reverse(acc), data))
    _ -> {
      use #(diff, rest) <- result.try(
        oni_bitcoin.compact_size_decode(data)
        |> result.map_error(fn(_) { "Invalid index" }),
      )
      let absolute = last_idx + diff
      decode_indexes(rest, count - 1, [absolute, ..acc], absolute + 1)
    }
  }
}

/// Encode blocktxn message
pub fn encode_blocktxn(msg: BlockTxn) -> BitArray {
  let builder =
    bytes_builder.new()
    |> bytes_builder.append(msg.block_hash.hash.bytes)
    |> bytes_builder.append(
      oni_bitcoin.compact_size_encode(list.length(msg.transactions)),
    )

  let builder =
    list.fold(msg.transactions, builder, fn(b, tx) {
      bytes_builder.append(b, oni_bitcoin.encode_tx(tx))
    })

  bytes_builder.to_bit_array(builder)
}

/// Decode blocktxn message
pub fn decode_blocktxn(data: BitArray) -> Result(#(BlockTxn, BitArray), String) {
  case data {
    <<hash_bytes:bytes-size(32), rest:bytes>> -> {
      use #(count, rest2) <- result.try(
        oni_bitcoin.compact_size_decode(rest)
        |> result.map_error(fn(_) { "Invalid tx count" }),
      )

      use #(transactions, rest3) <- result.try(
        decode_transactions(rest2, count, []),
      )

      Ok(#(
        BlockTxn(
          block_hash: oni_bitcoin.BlockHash(hash: oni_bitcoin.Hash256(
            bytes: hash_bytes,
          )),
          transactions: transactions,
        ),
        rest3,
      ))
    }
    _ -> Error("Invalid blocktxn message")
  }
}

fn decode_transactions(
  data: BitArray,
  count: Int,
  acc: List(oni_bitcoin.Transaction),
) -> Result(#(List(oni_bitcoin.Transaction), BitArray), String) {
  case count {
    0 -> Ok(#(list.reverse(acc), data))
    _ -> {
      use #(tx, rest) <- result.try(
        oni_bitcoin.decode_tx(data)
        |> result.map_error(fn(_) { "Invalid transaction" }),
      )
      decode_transactions(rest, count - 1, [tx, ..acc])
    }
  }
}

// ============================================================================
// Peer State for Compact Blocks
// ============================================================================

/// Peer compact block state
pub type PeerCompactState {
  PeerCompactState(
    /// Does peer want high bandwidth mode?
    high_bandwidth_mode: Bool,
    /// Compact block version supported
    version: Int,
    /// Pending reconstructions
    pending: Dict(BitArray, ReconstructionState),
  )
}

/// Create new peer compact block state
pub fn new_peer_state() -> PeerCompactState {
  PeerCompactState(high_bandwidth_mode: False, version: 0, pending: dict.new())
}

/// Update peer state from sendcmpct message
pub fn update_peer_state(
  state: PeerCompactState,
  msg: SendCmpct,
) -> PeerCompactState {
  PeerCompactState(
    high_bandwidth_mode: msg.announce,
    version: int.max(state.version, msg.version),
    pending: state.pending,
  )
}

// ============================================================================
// Utility Functions
// ============================================================================

fn encode_le_u64(n: Int) -> BitArray {
  <<n:little-size(64)>>
}

fn decode_le_u64(data: BitArray) -> Int {
  case data {
    <<n:little-size(64)>> -> n
    _ -> 0
  }
}
