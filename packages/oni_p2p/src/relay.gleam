// relay.gleam - Transaction and block relay logic
//
// This module implements Bitcoin's relay protocol:
// - Inventory announcement (inv messages)
// - Request tracking (getdata messages)
// - Transaction and block propagation
// - Bandwidth and DoS limiting
//
// Phase 8 Implementation

import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/set.{type Set}
import oni_bitcoin.{type BlockHash, type Hash256, type Txid}
import oni_p2p.{
  type InvItem, type InvType, type Message, type PeerId,
  InvBlock, InvTx, InvWitnessTx, MsgGetData, MsgInv,
}

// ============================================================================
// Constants
// ============================================================================

/// Maximum number of inventory items to announce at once
pub const max_inv_batch = 1000

/// Maximum number of in-flight getdata requests per peer
pub const max_in_flight_per_peer = 100

/// Request timeout in milliseconds
pub const request_timeout_ms = 60_000

/// Minimum time between inv announcements (ms)
pub const inv_broadcast_interval_ms = 500

/// Maximum transactions to track per peer for inv
pub const max_tx_inv_per_peer = 5000

/// Maximum blocks to track per peer for inv
pub const max_block_inv_per_peer = 1000

// ============================================================================
// Relay State
// ============================================================================

/// Transaction relay manager
pub type TxRelay {
  TxRelay(
    /// Transactions we've announced to each peer
    announced: Dict(String, Set(String)),
    /// Transactions each peer has announced to us
    peer_announced: Dict(String, Set(String)),
    /// Pending requests to peers
    pending_requests: Dict(String, PendingRequest),
    /// Transactions to announce
    announce_queue: List(Txid),
    /// Last announcement time
    last_announce_time: Int,
  )
}

/// Block relay manager
pub type BlockRelay {
  BlockRelay(
    /// Blocks we've announced to each peer
    announced: Dict(String, Set(String)),
    /// Blocks each peer has announced to us
    peer_announced: Dict(String, Set(String)),
    /// Pending block requests
    pending_requests: Dict(String, PendingRequest),
    /// Blocks to announce
    announce_queue: List(BlockHash),
    /// Compact block preferences per peer
    compact_block_peers: Set(String),
  )
}

/// A pending data request
pub type PendingRequest {
  PendingRequest(
    hash: Hash256,
    peer: PeerId,
    requested_at: Int,
    inv_type: InvType,
  )
}

// ============================================================================
// Transaction Relay
// ============================================================================

/// Create a new transaction relay manager
pub fn tx_relay_new() -> TxRelay {
  TxRelay(
    announced: dict.new(),
    peer_announced: dict.new(),
    pending_requests: dict.new(),
    announce_queue: [],
    last_announce_time: 0,
  )
}

/// Queue a transaction for announcement
pub fn tx_relay_announce(relay: TxRelay, txid: Txid) -> TxRelay {
  TxRelay(..relay, announce_queue: [txid, ..relay.announce_queue])
}

/// Get inv messages to send to a peer
pub fn tx_relay_get_inv(
  relay: TxRelay,
  peer: PeerId,
  current_time: Int,
) -> #(TxRelay, Option(Message)) {
  // Check if enough time has passed
  case current_time - relay.last_announce_time < inv_broadcast_interval_ms {
    True -> #(relay, None)
    False -> {
      let peer_key = oni_p2p.peer_id_to_string(peer)

      // Get transactions not yet announced to this peer
      let already_announced = case dict.get(relay.announced, peer_key) {
        Ok(set) -> set
        Error(_) -> set.new()
      }

      let to_announce = list.filter(relay.announce_queue, fn(txid) {
        let key = oni_bitcoin.hash256_to_hex(txid.hash)
        !set.contains(already_announced, key)
      })

      case list.is_empty(to_announce) {
        True -> #(relay, None)
        False -> {
          // Take up to max_inv_batch
          let batch = list.take(to_announce, max_inv_batch)

          // Create inv message
          let items = list.map(batch, fn(txid) {
            oni_p2p.InvItem(InvTx, txid.hash)
          })
          let msg = MsgInv(items)

          // Update announced set
          let new_announced_set = list.fold(batch, already_announced, fn(acc, txid) {
            set.insert(acc, oni_bitcoin.hash256_to_hex(txid.hash))
          })
          let new_announced = dict.insert(relay.announced, peer_key, new_announced_set)

          // Update relay state
          let new_relay = TxRelay(
            ..relay,
            announced: new_announced,
            last_announce_time: current_time,
          )

          #(new_relay, Some(msg))
        }
      }
    }
  }
}

/// Handle incoming inv message from a peer
pub fn tx_relay_on_inv(
  relay: TxRelay,
  peer: PeerId,
  items: List(InvItem),
) -> #(TxRelay, List(InvItem)) {
  let peer_key = oni_p2p.peer_id_to_string(peer)

  // Filter to just transaction items
  let tx_items = list.filter(items, fn(item) {
    case item.inv_type {
      InvTx | InvWitnessTx -> True
      _ -> False
    }
  })

  // Track what peer has announced
  let current_announced = case dict.get(relay.peer_announced, peer_key) {
    Ok(s) -> s
    Error(_) -> set.new()
  }

  let #(new_announced, to_request) = list.fold(
    tx_items,
    #(current_announced, []),
    fn(acc, item) {
      let #(announced, requests) = acc
      let key = oni_bitcoin.hash256_to_hex(item.hash)

      case set.contains(announced, key) {
        True -> acc  // Already know about this
        False -> {
          let new_announced = set.insert(announced, key)
          // Limit per-peer tracking
          let limited = case set.size(new_announced) > max_tx_inv_per_peer {
            True -> set.new()  // Reset if too many
            False -> new_announced
          }
          #(limited, [item, ..requests])
        }
      }
    }
  )

  let new_peer_announced = dict.insert(relay.peer_announced, peer_key, new_announced)
  let new_relay = TxRelay(..relay, peer_announced: new_peer_announced)

  #(new_relay, list.reverse(to_request))
}

/// Create getdata message for requested items
pub fn tx_relay_create_getdata(
  relay: TxRelay,
  peer: PeerId,
  items: List(InvItem),
  current_time: Int,
  witness: Bool,
) -> #(TxRelay, Option(Message)) {
  let peer_key = oni_p2p.peer_id_to_string(peer)

  // Check in-flight limit
  let current_in_flight = count_in_flight_for_peer(relay.pending_requests, peer_key)
  case current_in_flight >= max_in_flight_per_peer {
    True -> #(relay, None)
    False -> {
      let available = max_in_flight_per_peer - current_in_flight
      let batch = list.take(items, available)

      case list.is_empty(batch) {
        True -> #(relay, None)
        False -> {
          // Convert to witness type if requested
          let request_items = list.map(batch, fn(item) {
            case witness && item.inv_type == InvTx {
              True -> oni_p2p.InvItem(InvWitnessTx, item.hash)
              False -> item
            }
          })

          // Track pending requests
          let new_pending = list.fold(request_items, relay.pending_requests, fn(acc, item) {
            let key = oni_bitcoin.hash256_to_hex(item.hash)
            let request = PendingRequest(
              hash: item.hash,
              peer: peer,
              requested_at: current_time,
              inv_type: item.inv_type,
            )
            dict.insert(acc, key, request)
          })

          let msg = MsgGetData(request_items)
          let new_relay = TxRelay(..relay, pending_requests: new_pending)

          #(new_relay, Some(msg))
        }
      }
    }
  }
}

/// Mark a request as completed
pub fn tx_relay_complete_request(relay: TxRelay, hash: Hash256) -> TxRelay {
  let key = oni_bitcoin.hash256_to_hex(hash)
  TxRelay(..relay, pending_requests: dict.delete(relay.pending_requests, key))
}

/// Remove timed out requests
pub fn tx_relay_expire_requests(relay: TxRelay, current_time: Int) -> TxRelay {
  let cutoff = current_time - request_timeout_ms
  let new_pending = dict.filter(relay.pending_requests, fn(_key, req) {
    req.requested_at > cutoff
  })
  TxRelay(..relay, pending_requests: new_pending)
}

/// Clear state for disconnected peer
pub fn tx_relay_peer_disconnected(relay: TxRelay, peer: PeerId) -> TxRelay {
  let peer_key = oni_p2p.peer_id_to_string(peer)

  // Remove from announced tracking
  let new_announced = dict.delete(relay.announced, peer_key)
  let new_peer_announced = dict.delete(relay.peer_announced, peer_key)

  // Remove pending requests for this peer
  let new_pending = dict.filter(relay.pending_requests, fn(_key, req) {
    oni_p2p.peer_id_to_string(req.peer) != peer_key
  })

  TxRelay(
    ..relay,
    announced: new_announced,
    peer_announced: new_peer_announced,
    pending_requests: new_pending,
  )
}

fn count_in_flight_for_peer(pending: Dict(String, PendingRequest), peer_key: String) -> Int {
  dict.fold(pending, 0, fn(acc, _key, req) {
    case oni_p2p.peer_id_to_string(req.peer) == peer_key {
      True -> acc + 1
      False -> acc
    }
  })
}

// ============================================================================
// Block Relay
// ============================================================================

/// Create a new block relay manager
pub fn block_relay_new() -> BlockRelay {
  BlockRelay(
    announced: dict.new(),
    peer_announced: dict.new(),
    pending_requests: dict.new(),
    announce_queue: [],
    compact_block_peers: set.new(),
  )
}

/// Queue a block for announcement
pub fn block_relay_announce(relay: BlockRelay, hash: BlockHash) -> BlockRelay {
  BlockRelay(..relay, announce_queue: [hash, ..relay.announce_queue])
}

/// Enable compact blocks for a peer
pub fn block_relay_enable_compact(relay: BlockRelay, peer: PeerId) -> BlockRelay {
  let peer_key = oni_p2p.peer_id_to_string(peer)
  BlockRelay(..relay, compact_block_peers: set.insert(relay.compact_block_peers, peer_key))
}

/// Check if peer supports compact blocks
pub fn block_relay_uses_compact(relay: BlockRelay, peer: PeerId) -> Bool {
  let peer_key = oni_p2p.peer_id_to_string(peer)
  set.contains(relay.compact_block_peers, peer_key)
}

/// Get inv messages for block announcements
pub fn block_relay_get_inv(
  relay: BlockRelay,
  peer: PeerId,
) -> #(BlockRelay, Option(Message)) {
  let peer_key = oni_p2p.peer_id_to_string(peer)

  let already_announced = case dict.get(relay.announced, peer_key) {
    Ok(s) -> s
    Error(_) -> set.new()
  }

  let to_announce = list.filter(relay.announce_queue, fn(hash) {
    let key = oni_bitcoin.hash256_to_hex(hash.hash)
    !set.contains(already_announced, key)
  })

  case list.is_empty(to_announce) {
    True -> #(relay, None)
    False -> {
      let batch = list.take(to_announce, max_inv_batch)

      let items = list.map(batch, fn(hash) {
        oni_p2p.InvItem(InvBlock, hash.hash)
      })
      let msg = MsgInv(items)

      let new_announced_set = list.fold(batch, already_announced, fn(acc, hash) {
        set.insert(acc, oni_bitcoin.hash256_to_hex(hash.hash))
      })
      let new_announced = dict.insert(relay.announced, peer_key, new_announced_set)

      let new_relay = BlockRelay(..relay, announced: new_announced)

      #(new_relay, Some(msg))
    }
  }
}

/// Handle incoming block inv
pub fn block_relay_on_inv(
  relay: BlockRelay,
  peer: PeerId,
  items: List(InvItem),
) -> #(BlockRelay, List(InvItem)) {
  let peer_key = oni_p2p.peer_id_to_string(peer)

  let block_items = list.filter(items, fn(item) {
    case item.inv_type {
      InvBlock -> True
      _ -> False
    }
  })

  let current_announced = case dict.get(relay.peer_announced, peer_key) {
    Ok(s) -> s
    Error(_) -> set.new()
  }

  let #(new_announced, to_request) = list.fold(
    block_items,
    #(current_announced, []),
    fn(acc, item) {
      let #(announced, requests) = acc
      let key = oni_bitcoin.hash256_to_hex(item.hash)

      case set.contains(announced, key) {
        True -> acc
        False -> {
          let new_announced = set.insert(announced, key)
          let limited = case set.size(new_announced) > max_block_inv_per_peer {
            True -> set.new()
            False -> new_announced
          }
          #(limited, [item, ..requests])
        }
      }
    }
  )

  let new_peer_announced = dict.insert(relay.peer_announced, peer_key, new_announced)
  let new_relay = BlockRelay(..relay, peer_announced: new_peer_announced)

  #(new_relay, list.reverse(to_request))
}

/// Create getdata for blocks
pub fn block_relay_create_getdata(
  relay: BlockRelay,
  peer: PeerId,
  items: List(InvItem),
  current_time: Int,
) -> #(BlockRelay, Option(Message)) {
  let peer_key = oni_p2p.peer_id_to_string(peer)

  let current_in_flight = count_in_flight_for_peer(relay.pending_requests, peer_key)
  case current_in_flight >= max_in_flight_per_peer {
    True -> #(relay, None)
    False -> {
      let available = max_in_flight_per_peer - current_in_flight
      let batch = list.take(items, available)

      case list.is_empty(batch) {
        True -> #(relay, None)
        False -> {
          let new_pending = list.fold(batch, relay.pending_requests, fn(acc, item) {
            let key = oni_bitcoin.hash256_to_hex(item.hash)
            let request = PendingRequest(
              hash: item.hash,
              peer: peer,
              requested_at: current_time,
              inv_type: item.inv_type,
            )
            dict.insert(acc, key, request)
          })

          let msg = MsgGetData(batch)
          let new_relay = BlockRelay(..relay, pending_requests: new_pending)

          #(new_relay, Some(msg))
        }
      }
    }
  }
}

/// Mark block request as completed
pub fn block_relay_complete_request(relay: BlockRelay, hash: Hash256) -> BlockRelay {
  let key = oni_bitcoin.hash256_to_hex(hash)
  BlockRelay(..relay, pending_requests: dict.delete(relay.pending_requests, key))
}

/// Clear state for disconnected peer
pub fn block_relay_peer_disconnected(relay: BlockRelay, peer: PeerId) -> BlockRelay {
  let peer_key = oni_p2p.peer_id_to_string(peer)

  let new_announced = dict.delete(relay.announced, peer_key)
  let new_peer_announced = dict.delete(relay.peer_announced, peer_key)
  let new_compact = set.delete(relay.compact_block_peers, peer_key)

  let new_pending = dict.filter(relay.pending_requests, fn(_key, req) {
    oni_p2p.peer_id_to_string(req.peer) != peer_key
  })

  BlockRelay(
    ..relay,
    announced: new_announced,
    peer_announced: new_peer_announced,
    pending_requests: new_pending,
    compact_block_peers: new_compact,
  )
}

// ============================================================================
// Combined Relay Stats
// ============================================================================

/// Relay statistics
pub type RelayStats {
  RelayStats(
    tx_pending_requests: Int,
    tx_announced_count: Int,
    block_pending_requests: Int,
    block_announced_count: Int,
  )
}

/// Get relay statistics
pub fn relay_stats(tx_relay: TxRelay, block_relay: BlockRelay) -> RelayStats {
  RelayStats(
    tx_pending_requests: dict.size(tx_relay.pending_requests),
    tx_announced_count: list.length(tx_relay.announce_queue),
    block_pending_requests: dict.size(block_relay.pending_requests),
    block_announced_count: list.length(block_relay.announce_queue),
  )
}

// ============================================================================
// Notfound Handling
// ============================================================================

/// Handle notfound message
pub fn handle_notfound(
  tx_relay: TxRelay,
  block_relay: BlockRelay,
  items: List(InvItem),
) -> #(TxRelay, BlockRelay) {
  let #(new_tx_relay, new_block_relay) = list.fold(
    items,
    #(tx_relay, block_relay),
    fn(acc, item) {
      let #(tr, br) = acc
      case item.inv_type {
        InvTx | InvWitnessTx -> {
          #(tx_relay_complete_request(tr, item.hash), br)
        }
        InvBlock -> {
          #(tr, block_relay_complete_request(br, item.hash))
        }
        _ -> acc
      }
    }
  )

  #(new_tx_relay, new_block_relay)
}
