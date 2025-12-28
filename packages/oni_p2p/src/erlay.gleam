// erlay.gleam - Erlay Transaction Relay Protocol (BIP330)
//
// This module implements efficient transaction relay using set reconciliation:
// - Minisketch-based set reconciliation for efficient diff computation
// - Flooding vs reconciliation decision logic
// - Per-peer reconciliation state management
// - Short transaction ID computation with salted SipHash
//
// Erlay reduces transaction announcement bandwidth by ~84% while maintaining
// low latency propagation through strategic flooding to outbound peers.
//
// Reference: https://github.com/bitcoin/bips/blob/master/bip-0330.mediawiki

import gleam/bit_array
import gleam/bytes_builder
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/result
import oni_bitcoin

// ============================================================================
// Constants
// ============================================================================

/// Minisketch capacity for reconciliation
pub const default_sketch_capacity = 32

/// Maximum transactions to flood (outbound peers)
pub const max_flood_txs = 1000

/// Reconciliation interval in seconds
pub const reconciliation_interval_sec = 2

/// Short transaction ID size in bytes
pub const short_txid_bytes = 4

/// Maximum number of reconciliation attempts before fallback
pub const max_reconciliation_attempts = 3

/// Erlay protocol version
pub const erlay_version = 1

// ============================================================================
// Core Types
// ============================================================================

/// Erlay peer state
pub type ErlayPeerState {
  ErlayPeerState(
    /// Peer ID
    peer_id: Int,
    /// Whether peer supports Erlay
    erlay_enabled: Bool,
    /// Salt for SipHash (negotiated during handshake)
    salt: BitArray,
    /// Set of short txids we need to announce
    pending_announcements: Dict(BitArray, oni_bitcoin.Txid),
    /// Set of short txids we know peer has
    peer_known_txids: Dict(BitArray, Nil),
    /// Last reconciliation time
    last_reconciliation: Int,
    /// Number of reconciliation attempts
    reconciliation_attempts: Int,
    /// Is this an outbound connection (for flooding decision)
    is_outbound: Bool,
    /// Current reconciliation state
    recon_state: ReconciliationState,
    /// Statistics
    stats: ErlayStats,
  )
}

/// Reconciliation state machine
pub type ReconciliationState {
  /// Idle, ready to start reconciliation
  ReconIdle
  /// Initiated reconciliation, waiting for response
  ReconInitiated(our_sketch: Minisketch, request_id: Int)
  /// Received sketch, computing differences
  ReconReceived(their_sketch: Minisketch)
  /// Awaiting specific transactions
  ReconAwaitingTxs(missing: List(BitArray))
  /// Reconciliation complete
  ReconComplete
  /// Reconciliation failed
  ReconFailed(reason: String)
}

/// Erlay statistics
pub type ErlayStats {
  ErlayStats(
    /// Transactions announced via flooding
    flooded_count: Int,
    /// Transactions announced via reconciliation
    reconciled_count: Int,
    /// Reconciliation rounds performed
    reconciliation_rounds: Int,
    /// Reconciliation failures
    reconciliation_failures: Int,
    /// Bytes saved vs flooding
    bytes_saved: Int,
  )
}

/// Minisketch data structure for set reconciliation
pub type Minisketch {
  Minisketch(
    /// Capacity (maximum number of differences)
    capacity: Int,
    /// Field size (bits per element)
    field_size: Int,
    /// Sketch data
    data: BitArray,
    /// Elements added
    elements: List(BitArray),
  )
}

/// Erlay messages
pub type ErlayMessage {
  /// sendtxrcncl - Announce Erlay support
  SendTxRcncl(version: Int, salt: BitArray)
  /// reqtxrcncl - Request reconciliation
  ReqTxRcncl(request_id: Int, our_short_ids: List(BitArray))
  /// sketches - Reconciliation sketch
  TxReconcilSketch(request_id: Int, sketch: Minisketch)
  /// reqtxdiff - Request specific transactions after reconciliation
  ReqTxDiff(short_ids: List(BitArray))
  /// txdiff - Send missing transactions
  TxDiff(transactions: List(oni_bitcoin.Transaction))
}

/// Decision on how to relay a transaction
pub type RelayDecision {
  /// Flood to this peer immediately
  Flood
  /// Queue for reconciliation
  Reconcile
  /// Skip this peer (already knows or not Erlay-enabled)
  Skip
}

// ============================================================================
// Peer State Management
// ============================================================================

/// Create new Erlay peer state
pub fn new_peer_state(peer_id: Int, is_outbound: Bool) -> ErlayPeerState {
  ErlayPeerState(
    peer_id: peer_id,
    erlay_enabled: False,
    salt: <<>>,
    pending_announcements: dict.new(),
    peer_known_txids: dict.new(),
    last_reconciliation: 0,
    reconciliation_attempts: 0,
    is_outbound: is_outbound,
    recon_state: ReconIdle,
    stats: ErlayStats(
      flooded_count: 0,
      reconciled_count: 0,
      reconciliation_rounds: 0,
      reconciliation_failures: 0,
      bytes_saved: 0,
    ),
  )
}

/// Enable Erlay for peer after handshake
pub fn enable_erlay(
  state: ErlayPeerState,
  their_version: Int,
  their_salt: BitArray,
  our_salt: BitArray,
) -> Result(ErlayPeerState, String) {
  case their_version >= erlay_version {
    False -> Error("Incompatible Erlay version")
    True -> {
      // Combine salts to create shared salt
      let combined_salt = xor_salts(our_salt, their_salt)

      Ok(ErlayPeerState(
        ..state,
        erlay_enabled: True,
        salt: combined_salt,
      ))
    }
  }
}

/// Disable Erlay for peer
pub fn disable_erlay(state: ErlayPeerState) -> ErlayPeerState {
  ErlayPeerState(..state, erlay_enabled: False)
}

// ============================================================================
// Transaction Relay Decision
// ============================================================================

/// Decide how to relay a transaction to a peer
pub fn decide_relay(
  state: ErlayPeerState,
  txid: oni_bitcoin.Txid,
  is_high_priority: Bool,
) -> #(ErlayPeerState, RelayDecision) {
  let short_id = compute_short_txid(txid, state.salt)

  // Check if peer already knows this transaction
  case dict.has_key(state.peer_known_txids, short_id) {
    True -> #(state, Skip)
    False -> {
      case state.erlay_enabled {
        False -> {
          // Non-Erlay peer: always flood
          let new_known = dict.insert(state.peer_known_txids, short_id, Nil)
          let new_stats = ErlayStats(
            ..state.stats,
            flooded_count: state.stats.flooded_count + 1,
          )
          #(ErlayPeerState(..state, peer_known_txids: new_known, stats: new_stats), Flood)
        }
        True -> {
          // Erlay-enabled peer
          case state.is_outbound || is_high_priority {
            True -> {
              // Flood to outbound peers and high-priority txs for fast propagation
              let new_known = dict.insert(state.peer_known_txids, short_id, Nil)
              let new_stats = ErlayStats(
                ..state.stats,
                flooded_count: state.stats.flooded_count + 1,
              )
              #(ErlayPeerState(..state, peer_known_txids: new_known, stats: new_stats), Flood)
            }
            False -> {
              // Queue for reconciliation (inbound peers)
              let new_pending = dict.insert(state.pending_announcements, short_id, txid)
              #(ErlayPeerState(..state, pending_announcements: new_pending), Reconcile)
            }
          }
        }
      }
    }
  }
}

/// Check if reconciliation is needed
pub fn needs_reconciliation(state: ErlayPeerState, current_time: Int) -> Bool {
  state.erlay_enabled
  && dict.size(state.pending_announcements) > 0
  && current_time - state.last_reconciliation >= reconciliation_interval_sec * 1000
  && state.recon_state == ReconIdle
}

// ============================================================================
// Short Transaction ID
// ============================================================================

/// Compute short transaction ID using salted SipHash
pub fn compute_short_txid(txid: oni_bitcoin.Txid, salt: BitArray) -> BitArray {
  let txid_bytes = txid.hash.bytes

  // SipHash-2-4 with salt as key
  let #(k0, k1) = extract_siphash_key(salt)
  let hash = siphash_2_4(txid_bytes, k0, k1)

  // Take first 4 bytes
  case bit_array.slice(<<hash:64-little>>, 0, short_txid_bytes) {
    Ok(short_id) -> short_id
    Error(_) -> <<0, 0, 0, 0>>
  }
}

/// Compute short transaction IDs for a list of txids
pub fn compute_short_txids(
  txids: List(oni_bitcoin.Txid),
  salt: BitArray,
) -> List(BitArray) {
  list.map(txids, fn(txid) { compute_short_txid(txid, salt) })
}

/// Extract SipHash key from salt
fn extract_siphash_key(salt: BitArray) -> #(Int, Int) {
  case salt {
    <<k0:64-little, k1:64-little, _:bits>> -> #(k0, k1)
    <<k0:64-little>> -> #(k0, 0)
    _ -> #(0, 0)
  }
}

// ============================================================================
// Minisketch Implementation
// ============================================================================

/// Create a new minisketch
pub fn minisketch_new(capacity: Int) -> Minisketch {
  Minisketch(
    capacity: capacity,
    field_size: short_txid_bytes * 8,
    data: create_empty_sketch_data(capacity),
    elements: [],
  )
}

/// Add an element to the sketch
pub fn minisketch_add(sketch: Minisketch, element: BitArray) -> Minisketch {
  case list.length(sketch.elements) >= sketch.capacity {
    True -> sketch  // Sketch is full
    False -> {
      // Add element to the sketch
      // In production, this would use proper field operations
      let new_data = xor_into_sketch(sketch.data, element)
      Minisketch(
        ..sketch,
        data: new_data,
        elements: [element, ..sketch.elements],
      )
    }
  }
}

/// Merge two sketches (XOR operation)
pub fn minisketch_merge(a: Minisketch, b: Minisketch) -> Minisketch {
  case a.capacity == b.capacity {
    False -> a  // Incompatible sketches
    True -> {
      let merged_data = xor_bytes(a.data, b.data)
      Minisketch(
        ..a,
        data: merged_data,
        elements: [],  // Merged sketch, elements unknown
      )
    }
  }
}

/// Decode differences from a merged sketch
pub fn minisketch_decode(sketch: Minisketch) -> Result(List(BitArray), String) {
  // In production, this would use proper BCH decoding
  // For now, return empty list if sketch is zero (no differences)
  case is_zero_sketch(sketch.data) {
    True -> Ok([])
    False -> {
      // Simplified: return elements if available
      case list.length(sketch.elements) <= sketch.capacity {
        True -> Ok(sketch.elements)
        False -> Error("Too many differences")
      }
    }
  }
}

/// Serialize minisketch for network transmission
pub fn minisketch_serialize(sketch: Minisketch) -> BitArray {
  bytes_builder.new()
  |> bytes_builder.append(<<sketch.capacity:32-little>>)
  |> bytes_builder.append(<<sketch.field_size:8>>)
  |> bytes_builder.append(sketch.data)
  |> bytes_builder.to_bit_array
}

/// Deserialize minisketch from network data
pub fn minisketch_deserialize(data: BitArray) -> Result(#(Minisketch, BitArray), String) {
  case data {
    <<capacity:32-little, field_size:8, rest:bits>> -> {
      let sketch_size = capacity * 4  // 4 bytes per element slot
      case extract_bytes(rest, sketch_size) {
        Error(_) -> Error("Insufficient sketch data")
        Ok(#(sketch_data, remaining)) -> {
          Ok(#(
            Minisketch(
              capacity: capacity,
              field_size: field_size,
              data: sketch_data,
              elements: [],
            ),
            remaining,
          ))
        }
      }
    }
    _ -> Error("Invalid minisketch header")
  }
}

// ============================================================================
// Reconciliation Protocol
// ============================================================================

/// Start reconciliation with a peer
pub fn start_reconciliation(
  state: ErlayPeerState,
  request_id: Int,
) -> #(ErlayPeerState, ErlayMessage) {
  // Build sketch from pending announcements
  let sketch = dict.fold(
    state.pending_announcements,
    minisketch_new(default_sketch_capacity),
    fn(sk, short_id, _txid) { minisketch_add(sk, short_id) },
  )

  let short_ids = dict.keys(state.pending_announcements)

  let new_state = ErlayPeerState(
    ..state,
    recon_state: ReconInitiated(sketch, request_id),
    reconciliation_attempts: state.reconciliation_attempts + 1,
  )

  #(new_state, ReqTxRcncl(request_id, short_ids))
}

/// Handle incoming reconciliation request
pub fn handle_recon_request(
  state: ErlayPeerState,
  request_id: Int,
  their_short_ids: List(BitArray),
) -> #(ErlayPeerState, ErlayMessage) {
  // Build our sketch
  let our_sketch = dict.fold(
    state.pending_announcements,
    minisketch_new(default_sketch_capacity),
    fn(sk, short_id, _txid) { minisketch_add(sk, short_id) },
  )

  // Merge with their knowledge to find differences
  let their_sketch = list.fold(
    their_short_ids,
    minisketch_new(default_sketch_capacity),
    fn(sk, id) { minisketch_add(sk, id) },
  )

  let diff_sketch = minisketch_merge(our_sketch, their_sketch)

  let new_state = ErlayPeerState(
    ..state,
    recon_state: ReconReceived(their_sketch),
    last_reconciliation: current_time_ms(),
  )

  #(new_state, TxReconcilSketch(request_id, diff_sketch))
}

/// Handle incoming sketch response
pub fn handle_sketch_response(
  state: ErlayPeerState,
  _request_id: Int,
  their_sketch: Minisketch,
  our_mempool: List(oni_bitcoin.Txid),
) -> Result(#(ErlayPeerState, Option(ErlayMessage)), String) {
  case state.recon_state {
    ReconInitiated(our_sketch, _) -> {
      // Merge sketches to find differences
      let diff_sketch = minisketch_merge(our_sketch, their_sketch)

      case minisketch_decode(diff_sketch) {
        Error(reason) -> {
          let new_state = ErlayPeerState(
            ..state,
            recon_state: ReconFailed(reason),
            stats: ErlayStats(
              ..state.stats,
              reconciliation_failures: state.stats.reconciliation_failures + 1,
            ),
          )
          Error(reason)
        }
        Ok(differences) -> {
          // Identify which txs we're missing
          let missing = identify_missing(differences, our_mempool, state.salt)

          case list.is_empty(missing) {
            True -> {
              // No missing transactions
              let new_state = ErlayPeerState(
                ..state,
                recon_state: ReconComplete,
                pending_announcements: dict.new(),
                last_reconciliation: current_time_ms(),
                stats: ErlayStats(
                  ..state.stats,
                  reconciliation_rounds: state.stats.reconciliation_rounds + 1,
                  bytes_saved: state.stats.bytes_saved +
                    estimate_bytes_saved(dict.size(state.pending_announcements)),
                ),
              )
              Ok(#(new_state, None))
            }
            False -> {
              // Request missing transactions
              let new_state = ErlayPeerState(
                ..state,
                recon_state: ReconAwaitingTxs(missing),
              )
              Ok(#(new_state, Some(ReqTxDiff(missing))))
            }
          }
        }
      }
    }
    _ -> Error("Unexpected sketch response")
  }
}

/// Handle transaction diff request
pub fn handle_txdiff_request(
  state: ErlayPeerState,
  short_ids: List(BitArray),
  mempool: Dict(BitArray, oni_bitcoin.Transaction),
) -> #(ErlayPeerState, ErlayMessage) {
  // Find transactions matching the requested short IDs
  let txs = list.filter_map(short_ids, fn(short_id) {
    case dict.get(mempool, short_id) {
      Ok(tx) -> Some(tx)
      Error(_) -> None
    }
  })

  // Mark these as known to peer
  let new_known = list.fold(short_ids, state.peer_known_txids, fn(known, id) {
    dict.insert(known, id, Nil)
  })

  let new_stats = ErlayStats(
    ..state.stats,
    reconciled_count: state.stats.reconciled_count + list.length(txs),
  )

  let new_state = ErlayPeerState(
    ..state,
    peer_known_txids: new_known,
    stats: new_stats,
  )

  #(new_state, TxDiff(txs))
}

/// Handle received transaction diff
pub fn handle_txdiff_response(
  state: ErlayPeerState,
  transactions: List(oni_bitcoin.Transaction),
) -> #(ErlayPeerState, List(oni_bitcoin.Transaction)) {
  // Complete reconciliation
  let new_state = ErlayPeerState(
    ..state,
    recon_state: ReconComplete,
    pending_announcements: dict.new(),
    last_reconciliation: current_time_ms(),
    stats: ErlayStats(
      ..state.stats,
      reconciliation_rounds: state.stats.reconciliation_rounds + 1,
      reconciled_count: state.stats.reconciled_count + list.length(transactions),
      bytes_saved: state.stats.bytes_saved +
        estimate_bytes_saved(dict.size(state.pending_announcements)),
    ),
  )

  #(new_state, transactions)
}

/// Reset reconciliation state on failure
pub fn reset_reconciliation(state: ErlayPeerState) -> ErlayPeerState {
  ErlayPeerState(
    ..state,
    recon_state: ReconIdle,
    reconciliation_attempts: 0,
  )
}

// ============================================================================
// Message Serialization
// ============================================================================

/// Encode Erlay message for network transmission
pub fn encode_message(msg: ErlayMessage) -> BitArray {
  case msg {
    SendTxRcncl(version, salt) -> {
      <<version:32-little, salt:bits>>
    }

    ReqTxRcncl(request_id, short_ids) -> {
      let count = list.length(short_ids)
      let ids_data = list.fold(short_ids, <<>>, fn(acc, id) {
        bit_array.concat([acc, id])
      })
      <<request_id:32-little, count:32-little, ids_data:bits>>
    }

    TxReconcilSketch(request_id, sketch) -> {
      let sketch_data = minisketch_serialize(sketch)
      <<request_id:32-little, sketch_data:bits>>
    }

    ReqTxDiff(short_ids) -> {
      let count = list.length(short_ids)
      let ids_data = list.fold(short_ids, <<>>, fn(acc, id) {
        bit_array.concat([acc, id])
      })
      <<count:32-little, ids_data:bits>>
    }

    TxDiff(transactions) -> {
      let count = list.length(transactions)
      let tx_data = list.fold(transactions, <<>>, fn(acc, tx) {
        bit_array.concat([acc, oni_bitcoin.encode_tx(tx)])
      })
      <<count:32-little, tx_data:bits>>
    }
  }
}

/// Decode SendTxRcncl message
pub fn decode_sendtxrcncl(data: BitArray) -> Result(#(ErlayMessage, BitArray), String) {
  case data {
    <<version:32-little, salt:bytes-size(16), rest:bits>> -> {
      Ok(#(SendTxRcncl(version, salt), rest))
    }
    _ -> Error("Invalid sendtxrcncl message")
  }
}

/// Decode ReqTxRcncl message
pub fn decode_reqtxrcncl(data: BitArray) -> Result(#(ErlayMessage, BitArray), String) {
  case data {
    <<request_id:32-little, count:32-little, rest:bits>> -> {
      case decode_short_ids(rest, count, []) {
        Error(e) -> Error(e)
        Ok(#(short_ids, remaining)) -> {
          Ok(#(ReqTxRcncl(request_id, short_ids), remaining))
        }
      }
    }
    _ -> Error("Invalid reqtxrcncl message")
  }
}

fn decode_short_ids(
  data: BitArray,
  count: Int,
  acc: List(BitArray),
) -> Result(#(List(BitArray), BitArray), String) {
  case count {
    0 -> Ok(#(list.reverse(acc), data))
    _ -> {
      case data {
        <<id:bytes-size(4), rest:bits>> -> {
          decode_short_ids(rest, count - 1, [id, ..acc])
        }
        _ -> Error("Insufficient data for short IDs")
      }
    }
  }
}

// ============================================================================
// Erlay Manager
// ============================================================================

/// Erlay manager state
pub type ErlayManager {
  ErlayManager(
    /// Per-peer Erlay state
    peers: Dict(Int, ErlayPeerState),
    /// Our salt for handshakes
    our_salt: BitArray,
    /// Next request ID
    next_request_id: Int,
    /// Global statistics
    stats: ErlayStats,
  )
}

/// Create new Erlay manager
pub fn new_manager() -> ErlayManager {
  ErlayManager(
    peers: dict.new(),
    our_salt: generate_random_salt(),
    next_request_id: 1,
    stats: ErlayStats(
      flooded_count: 0,
      reconciled_count: 0,
      reconciliation_rounds: 0,
      reconciliation_failures: 0,
      bytes_saved: 0,
    ),
  )
}

/// Add a new peer
pub fn add_peer(
  manager: ErlayManager,
  peer_id: Int,
  is_outbound: Bool,
) -> ErlayManager {
  let peer_state = new_peer_state(peer_id, is_outbound)
  let new_peers = dict.insert(manager.peers, peer_id, peer_state)
  ErlayManager(..manager, peers: new_peers)
}

/// Remove a peer
pub fn remove_peer(manager: ErlayManager, peer_id: Int) -> ErlayManager {
  let new_peers = dict.delete(manager.peers, peer_id)
  ErlayManager(..manager, peers: new_peers)
}

/// Get peer state
pub fn get_peer(manager: ErlayManager, peer_id: Int) -> Option(ErlayPeerState) {
  dict.get(manager.peers, peer_id)
  |> option.from_result
}

/// Update peer state
pub fn update_peer(
  manager: ErlayManager,
  peer_id: Int,
  state: ErlayPeerState,
) -> ErlayManager {
  let new_peers = dict.insert(manager.peers, peer_id, state)
  ErlayManager(..manager, peers: new_peers)
}

/// Queue transaction for relay to all peers
pub fn queue_transaction(
  manager: ErlayManager,
  txid: oni_bitcoin.Txid,
  is_high_priority: Bool,
) -> #(ErlayManager, List(#(Int, RelayDecision))) {
  let #(new_peers, decisions) = dict.fold(
    manager.peers,
    #(dict.new(), []),
    fn(acc, peer_id, peer_state) {
      let #(peers_acc, decisions_acc) = acc
      let #(new_peer_state, decision) = decide_relay(peer_state, txid, is_high_priority)
      let new_peers_acc = dict.insert(peers_acc, peer_id, new_peer_state)
      let new_decisions_acc = [#(peer_id, decision), ..decisions_acc]
      #(new_peers_acc, new_decisions_acc)
    },
  )

  #(ErlayManager(..manager, peers: new_peers), decisions)
}

/// Get peers needing reconciliation
pub fn peers_needing_reconciliation(
  manager: ErlayManager,
  current_time: Int,
) -> List(Int) {
  dict.fold(manager.peers, [], fn(acc, peer_id, peer_state) {
    case needs_reconciliation(peer_state, current_time) {
      True -> [peer_id, ..acc]
      False -> acc
    }
  })
}

/// Get manager statistics
pub fn get_stats(manager: ErlayManager) -> ErlayStats {
  // Aggregate stats from all peers
  dict.fold(manager.peers, manager.stats, fn(acc, _peer_id, peer_state) {
    ErlayStats(
      flooded_count: acc.flooded_count + peer_state.stats.flooded_count,
      reconciled_count: acc.reconciled_count + peer_state.stats.reconciled_count,
      reconciliation_rounds: acc.reconciliation_rounds + peer_state.stats.reconciliation_rounds,
      reconciliation_failures: acc.reconciliation_failures + peer_state.stats.reconciliation_failures,
      bytes_saved: acc.bytes_saved + peer_state.stats.bytes_saved,
    )
  })
}

// ============================================================================
// Helper Functions
// ============================================================================

fn xor_salts(a: BitArray, b: BitArray) -> BitArray {
  xor_bytes(a, b)
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
    _, _ -> acc
  }
}

fn create_empty_sketch_data(capacity: Int) -> BitArray {
  create_zeros(capacity * 4)
}

fn create_zeros(n: Int) -> BitArray {
  case n <= 0 {
    True -> <<>>
    False -> <<0, { create_zeros(n - 1) }:bits>>
  }
}

fn xor_into_sketch(sketch_data: BitArray, element: BitArray) -> BitArray {
  // XOR element into the sketch at appropriate position
  // Simplified: XOR into first bytes
  case sketch_data, element {
    <<s_head:bytes-size(4), s_rest:bits>>, <<e:bytes-size(4)>> -> {
      let xored = xor_bytes(s_head, e)
      <<xored:bits, s_rest:bits>>
    }
    _, _ -> sketch_data
  }
}

fn is_zero_sketch(data: BitArray) -> Bool {
  is_all_zeros(data)
}

fn is_all_zeros(data: BitArray) -> Bool {
  case data {
    <<0, rest:bits>> -> is_all_zeros(rest)
    <<>> -> True
    _ -> False
  }
}

fn extract_bytes(data: BitArray, n: Int) -> Result(#(BitArray, BitArray), Nil) {
  case bit_array.slice(data, 0, n) {
    Error(_) -> Error(Nil)
    Ok(extracted) -> {
      let remaining_size = bit_array.byte_size(data) - n
      case bit_array.slice(data, n, remaining_size) {
        Error(_) -> Ok(#(extracted, <<>>))
        Ok(rest) -> Ok(#(extracted, rest))
      }
    }
  }
}

fn identify_missing(
  differences: List(BitArray),
  our_mempool: List(oni_bitcoin.Txid),
  salt: BitArray,
) -> List(BitArray) {
  // Compute short IDs for our mempool
  let our_short_ids = list.map(our_mempool, fn(txid) {
    compute_short_txid(txid, salt)
  })

  // Find which differences we don't have
  list.filter(differences, fn(diff) {
    !list.contains(our_short_ids, diff)
  })
}

fn estimate_bytes_saved(num_txs: Int) -> Int {
  // Each inv message is 36 bytes (32 txid + 4 type)
  // Reconciliation typically uses ~4 bytes per tx
  // Savings: 36 - 4 = 32 bytes per tx
  num_txs * 32
}

fn generate_random_salt() -> BitArray {
  // In production, use secure random
  <<0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde, 0xf0,
    0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88>>
}

fn current_time_ms() -> Int {
  // Placeholder - would use Erlang's system_time
  0
}

// SipHash implementation (simplified)
fn siphash_2_4(data: BitArray, k0: Int, k1: Int) -> Int {
  let v0 = int.bitwise_exclusive_or(k0, 0x736f6d6570736575)
  let v1 = int.bitwise_exclusive_or(k1, 0x646f72616e646f6d)
  let v2 = int.bitwise_exclusive_or(k0, 0x6c7967656e657261)
  let v3 = int.bitwise_exclusive_or(k1, 0x7465646279746573)

  let #(v0, v1, v2, v3) = process_blocks(data, v0, v1, v2, v3)

  // Finalization
  let v2 = int.bitwise_exclusive_or(v2, 0xff)
  let #(v0, v1, v2, v3) = sip_rounds(v0, v1, v2, v3, 4)

  v0
  |> int.bitwise_exclusive_or(v1)
  |> int.bitwise_exclusive_or(v2)
  |> int.bitwise_exclusive_or(v3)
}

fn process_blocks(
  data: BitArray,
  v0: Int,
  v1: Int,
  v2: Int,
  v3: Int,
) -> #(Int, Int, Int, Int) {
  case data {
    <<block:64-little, rest:bits>> -> {
      let v3 = int.bitwise_exclusive_or(v3, block)
      let #(v0, v1, v2, v3) = sip_rounds(v0, v1, v2, v3, 2)
      let v0 = int.bitwise_exclusive_or(v0, block)
      process_blocks(rest, v0, v1, v2, v3)
    }
    _ -> {
      // Handle remaining bytes
      let padded = pad_last_block(data)
      let v3 = int.bitwise_exclusive_or(v3, padded)
      let #(v0, v1, v2, v3) = sip_rounds(v0, v1, v2, v3, 2)
      let v0 = int.bitwise_exclusive_or(v0, padded)
      #(v0, v1, v2, v3)
    }
  }
}

fn pad_last_block(data: BitArray) -> Int {
  let len = bit_array.byte_size(data)
  let len_byte = int.bitwise_and(len, 0xff)

  case data {
    <<b0:8, b1:8, b2:8, b3:8, b4:8, b5:8, b6:8>> ->
      b0 + b1 * 256 + b2 * 65536 + b3 * 16777216 +
      b4 * 4294967296 + b5 * 1099511627776 + b6 * 281474976710656 +
      len_byte * 72057594037927936
    <<b0:8, b1:8, b2:8, b3:8, b4:8, b5:8>> ->
      b0 + b1 * 256 + b2 * 65536 + b3 * 16777216 +
      b4 * 4294967296 + b5 * 1099511627776 +
      len_byte * 72057594037927936
    _ -> len_byte * 72057594037927936
  }
}

fn sip_rounds(v0: Int, v1: Int, v2: Int, v3: Int, n: Int) -> #(Int, Int, Int, Int) {
  case n {
    0 -> #(v0, v1, v2, v3)
    _ -> {
      let #(v0, v1, v2, v3) = sip_round(v0, v1, v2, v3)
      sip_rounds(v0, v1, v2, v3, n - 1)
    }
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
