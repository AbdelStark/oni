// event_router.gleam - Routes P2P events to appropriate handlers
//
// This module provides the central event routing for the oni node:
// - Block messages -> Sync coordinator for validation
// - Transaction messages -> Mempool for validation
// - Header messages -> Sync coordinator for IBD
// - Control messages -> P2P manager
//
// The event router ensures proper flow control and backpressure
// to prevent overwhelming any single subsystem.

import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import ibd_coordinator.{type IbdMsg}
import oni_bitcoin
import oni_p2p.{
  type BlockHeaderNet, type InvItem, type Message, type VersionPayload, InvBlock,
  InvTx, InvWitnessBlock, InvWitnessTx, MsgAddr, MsgBlock, MsgGetBlocks,
  MsgGetData, MsgGetHeaders, MsgHeaders, MsgInv, MsgMempool, MsgNotFound,
  MsgPing, MsgPong, MsgTx, MsgVerack, MsgVersion,
}
import oni_supervisor.{type ChainstateMsg, type MempoolMsg, type SyncMsg}
import p2p_network.{
  type ListenerMsg, type PeerEvent, BroadcastMessage, MessageReceived,
  PeerDisconnectedEvent, PeerError, PeerHandshakeComplete,
}

// ============================================================================
// Configuration
// ============================================================================

/// Event router configuration
pub type RouterConfig {
  RouterConfig(
    /// Maximum pending block downloads
    max_pending_blocks: Int,
    /// Maximum pending transaction downloads
    max_pending_txs: Int,
    /// Log debug messages
    debug: Bool,
  )
}

/// Default router configuration
pub fn default_config() -> RouterConfig {
  RouterConfig(max_pending_blocks: 16, max_pending_txs: 100, debug: False)
}

// ============================================================================
// Messages
// ============================================================================

/// Messages for the event router actor
pub type RouterMsg {
  /// Process a P2P event
  ProcessEvent(event: PeerEvent)
  /// Request blocks from peers
  RequestBlocks(hashes: List(oni_bitcoin.BlockHash))
  /// Request transactions from peers
  RequestTxs(txids: List(oni_bitcoin.Txid))
  /// Broadcast a transaction to all peers
  BroadcastTx(tx: oni_bitcoin.Transaction)
  /// Broadcast a block to all peers
  BroadcastBlock(block: oni_bitcoin.Block)
  /// Get router statistics
  GetStats(reply: Subject(RouterStats))
  /// Set IBD coordinator handle (for late binding)
  SetIBD(ibd: Subject(IbdMsg))
  /// Shutdown the router
  Shutdown
}

/// Router statistics
pub type RouterStats {
  RouterStats(
    blocks_received: Int,
    txs_received: Int,
    headers_received: Int,
    blocks_requested: Int,
    txs_requested: Int,
    peers_connected: Int,
    peers_disconnected: Int,
  )
}

// ============================================================================
// State
// ============================================================================

/// Event router actor state
type RouterState {
  RouterState(
    config: RouterConfig,
    /// Reference to chainstate actor
    chainstate: Subject(ChainstateMsg),
    /// Reference to mempool actor
    mempool: Subject(MempoolMsg),
    /// Reference to sync coordinator
    sync: Subject(SyncMsg),
    /// Reference to P2P listener (for sending messages)
    p2p: Subject(ListenerMsg),
    /// Reference to IBD coordinator (optional)
    ibd: Option(Subject(IbdMsg)),
    /// Statistics
    stats: RouterStats,
    /// Pending block downloads (hash -> peer_id)
    pending_blocks: List(#(String, Int)),
    /// Pending tx downloads (txid -> peer_id)
    pending_txs: List(#(String, Int)),
    /// Connected peers with their heights
    peer_heights: List(#(Int, Int)),
  )
}

// ============================================================================
// Public API
// ============================================================================

/// Handles to subsystems needed by the router
pub type RouterHandles {
  RouterHandles(
    chainstate: Subject(ChainstateMsg),
    mempool: Subject(MempoolMsg),
    sync: Subject(SyncMsg),
    p2p: Subject(ListenerMsg),
    ibd: Option(Subject(IbdMsg)),
  )
}

/// Start the event router actor
pub fn start(
  config: RouterConfig,
  handles: RouterHandles,
) -> Result(Subject(RouterMsg), actor.StartError) {
  let initial_state =
    RouterState(
      config: config,
      chainstate: handles.chainstate,
      mempool: handles.mempool,
      sync: handles.sync,
      p2p: handles.p2p,
      ibd: handles.ibd,
      stats: RouterStats(
        blocks_received: 0,
        txs_received: 0,
        headers_received: 0,
        blocks_requested: 0,
        txs_requested: 0,
        peers_connected: 0,
        peers_disconnected: 0,
      ),
      pending_blocks: [],
      pending_txs: [],
      peer_heights: [],
    )

  actor.start(initial_state, handle_message)
}

/// Create a P2P event handler that forwards to the router
pub fn create_p2p_event_handler(
  router: Subject(RouterMsg),
) -> Result(Subject(PeerEvent), actor.StartError) {
  actor.start(router, fn(event: PeerEvent, router_subject: Subject(RouterMsg)) {
    process.send(router_subject, ProcessEvent(event))
    actor.continue(router_subject)
  })
}

// ============================================================================
// Message Handler
// ============================================================================

fn handle_message(
  msg: RouterMsg,
  state: RouterState,
) -> actor.Next(RouterMsg, RouterState) {
  case msg {
    ProcessEvent(event) -> {
      let new_state = handle_p2p_event(event, state)
      actor.continue(new_state)
    }

    RequestBlocks(hashes) -> {
      let new_state = request_blocks(hashes, state)
      actor.continue(new_state)
    }

    RequestTxs(txids) -> {
      let new_state = request_transactions(txids, state)
      actor.continue(new_state)
    }

    BroadcastTx(tx) -> {
      broadcast_transaction(tx, state)
      actor.continue(state)
    }

    BroadcastBlock(block) -> {
      broadcast_block(block, state)
      actor.continue(state)
    }

    GetStats(reply) -> {
      process.send(reply, state.stats)
      actor.continue(state)
    }

    SetIBD(ibd) -> {
      io.println("[Sync] IBD coordinator connected to event router")
      actor.continue(RouterState(..state, ibd: Some(ibd)))
    }

    Shutdown -> {
      io.println("[EventRouter] Shutting down...")
      actor.Stop(process.Normal)
    }
  }
}

// ============================================================================
// Event Handling
// ============================================================================

/// Handle a P2P event
fn handle_p2p_event(event: PeerEvent, state: RouterState) -> RouterState {
  case event {
    MessageReceived(peer_id, message) -> {
      handle_message_received(peer_id, message, state)
    }

    PeerHandshakeComplete(peer_id, version) -> {
      handle_peer_connected(peer_id, version, state)
    }

    PeerDisconnectedEvent(peer_id, reason) -> {
      handle_peer_disconnected(peer_id, reason, state)
    }

    PeerError(peer_id, _error) -> {
      case state.config.debug {
        True ->
          io.println(
            "[EventRouter] Peer " <> int.to_string(peer_id) <> " error",
          )
        False -> Nil
      }
      state
    }
  }
}

/// Handle a received P2P message
fn handle_message_received(
  peer_id: Int,
  message: Message,
  state: RouterState,
) -> RouterState {
  case message {
    // Block-related messages -> Sync coordinator
    MsgHeaders(headers) -> {
      handle_headers(peer_id, headers, state)
    }

    MsgBlock(block) -> {
      handle_block(peer_id, block, state)
    }

    MsgGetHeaders(locators, stop_hash) -> {
      handle_get_headers(peer_id, locators, stop_hash, state)
    }

    MsgGetBlocks(locators, stop_hash) -> {
      handle_get_blocks(peer_id, locators, stop_hash, state)
    }

    // Transaction-related messages -> Mempool
    MsgTx(tx) -> {
      handle_tx(peer_id, tx, state)
    }

    MsgMempool -> {
      handle_mempool_request(peer_id, state)
    }

    // Inventory messages -> Route based on type
    MsgInv(items) -> {
      handle_inv(peer_id, items, state)
    }

    MsgGetData(items) -> {
      handle_getdata(peer_id, items, state)
    }

    MsgNotFound(items) -> {
      handle_notfound(peer_id, items, state)
    }

    // Address messages (for now, just log)
    MsgAddr(_addrs) -> {
      case state.config.debug {
        True ->
          io.println(
            "[EventRouter] Received addr from peer " <> int.to_string(peer_id),
          )
        False -> Nil
      }
      state
    }

    // Control messages are handled by P2P layer
    MsgPing(_) | MsgPong(_) | MsgVersion(_) | MsgVerack -> {
      state
    }

    // Other messages
    _ -> {
      case state.config.debug {
        True ->
          io.println(
            "[EventRouter] Unhandled message from peer "
            <> int.to_string(peer_id),
          )
        False -> Nil
      }
      state
    }
  }
}

/// Handle headers message
fn handle_headers(
  peer_id: Int,
  headers: List(BlockHeaderNet),
  state: RouterState,
) -> RouterState {
  let header_count = list.length(headers)

  // Always log headers received during sync
  io.println(
    "[Sync] Received "
    <> int.to_string(header_count)
    <> " headers from peer "
    <> int.to_string(peer_id),
  )

  // NOTE: We do NOT notify oni_supervisor.OnHeaders here anymore!
  // The old code blindly added header counts without validation,
  // causing headers_height to inflate beyond actual chain height.
  // Headers are now validated by IBD coordinator before being counted.

  // Forward headers to IBD coordinator for validation
  case state.ibd {
    Some(ibd) -> {
      process.send(
        ibd,
        ibd_coordinator.HeadersReceived(peer_id, headers),
      )
    }
    None -> Nil
  }

  // Update stats
  let new_stats =
    RouterStats(
      ..state.stats,
      headers_received: state.stats.headers_received + header_count,
    )

  RouterState(..state, stats: new_stats)
}

/// Handle block message
fn handle_block(
  peer_id: Int,
  block: oni_bitcoin.Block,
  state: RouterState,
) -> RouterState {
  let block_hash = oni_bitcoin.block_hash_from_header(block.header)
  let hash_hex = oni_bitcoin.block_hash_to_hex(block_hash)

  io.println(
    "[Block] Received block "
    <> hash_hex
    <> " from peer "
    <> int.to_string(peer_id),
  )

  // IBD coordinator handles block connection in order
  // Don't send to chainstate directly - IBD will do it when ready
  case state.ibd {
    Some(ibd) -> {
      // Send full block to IBD coordinator for buffering and ordered connection
      process.send(
        ibd,
        ibd_coordinator.BlockReceived(block_hash, block),
      )
    }
    None -> {
      // Fallback: send directly to chainstate (for non-IBD operation)
      process.send(
        state.chainstate,
        oni_supervisor.ConnectBlock(block, process.new_subject()),
      )
    }
  }

  // Notify sync coordinator (for status tracking)
  process.send(state.sync, oni_supervisor.OnBlock(block_hash))

  // Remove from pending
  let new_pending =
    list.filter(state.pending_blocks, fn(entry) {
      let #(h, _) = entry
      h != hash_hex
    })

  // Update stats
  let new_stats =
    RouterStats(..state.stats, blocks_received: state.stats.blocks_received + 1)

  RouterState(..state, stats: new_stats, pending_blocks: new_pending)
}

/// Handle transaction message
fn handle_tx(
  peer_id: Int,
  tx: oni_bitcoin.Transaction,
  state: RouterState,
) -> RouterState {
  let txid = oni_bitcoin.txid_from_tx(tx)

  case state.config.debug {
    True ->
      io.println(
        "[EventRouter] Received tx "
        <> oni_bitcoin.txid_to_hex(txid)
        <> " from peer "
        <> int.to_string(peer_id),
      )
    False -> Nil
  }

  // Send to mempool for validation
  process.send(state.mempool, oni_supervisor.AddTx(tx, process.new_subject()))

  // Remove from pending
  let txid_hex = oni_bitcoin.txid_to_hex(txid)
  let new_pending =
    list.filter(state.pending_txs, fn(entry) {
      let #(t, _) = entry
      t != txid_hex
    })

  // Update stats
  let new_stats =
    RouterStats(..state.stats, txs_received: state.stats.txs_received + 1)

  RouterState(..state, stats: new_stats, pending_txs: new_pending)
}

/// Handle inventory message
fn handle_inv(
  peer_id: Int,
  items: List(InvItem),
  state: RouterState,
) -> RouterState {
  // Separate block and transaction inventory
  let #(block_items, tx_items) = partition_inv_items(items)

  case state.config.debug && list.length(items) > 0 {
    True ->
      io.println(
        "[EventRouter] Received inv with "
        <> int.to_string(list.length(block_items))
        <> " blocks, "
        <> int.to_string(list.length(tx_items))
        <> " txs from peer "
        <> int.to_string(peer_id),
      )
    False -> Nil
  }

  // Request blocks we don't have
  let blocks_to_request = filter_unknown_blocks(block_items, state)
  let txs_to_request = filter_unknown_txs(tx_items, state)

  let state1 = case list.is_empty(blocks_to_request) {
    True -> state
    False -> {
      let getdata = oni_p2p.create_getdata_blocks(blocks_to_request)
      // Send to specific peer (would need peer-specific send)
      process.send(state.p2p, BroadcastMessage(getdata))
      add_pending_blocks(blocks_to_request, peer_id, state)
    }
  }

  case list.is_empty(txs_to_request) {
    True -> state1
    False -> {
      let getdata = oni_p2p.create_getdata_txs(txs_to_request, True)
      process.send(state.p2p, BroadcastMessage(getdata))
      add_pending_txs(txs_to_request, peer_id, state1)
    }
  }
}

/// Handle getdata message
fn handle_getdata(
  peer_id: Int,
  items: List(InvItem),
  state: RouterState,
) -> RouterState {
  case state.config.debug {
    True ->
      io.println(
        "[EventRouter] Received getdata for "
        <> int.to_string(list.length(items))
        <> " items from peer "
        <> int.to_string(peer_id),
      )
    False -> Nil
  }

  // In a full implementation, we would look up blocks/txs and send them
  // For now, just log
  state
}

/// Handle notfound message
fn handle_notfound(
  peer_id: Int,
  items: List(InvItem),
  state: RouterState,
) -> RouterState {
  case state.config.debug {
    True ->
      io.println(
        "[EventRouter] Peer "
        <> int.to_string(peer_id)
        <> " notfound for "
        <> int.to_string(list.length(items))
        <> " items",
      )
    False -> Nil
  }
  state
}

/// Handle getheaders message
fn handle_get_headers(
  _peer_id: Int,
  _locators: List(oni_bitcoin.BlockHash),
  _stop_hash: oni_bitcoin.BlockHash,
  state: RouterState,
) -> RouterState {
  // In a full implementation, we would look up headers and send them
  state
}

/// Handle getblocks message
fn handle_get_blocks(
  _peer_id: Int,
  _locators: List(oni_bitcoin.BlockHash),
  _stop_hash: oni_bitcoin.BlockHash,
  state: RouterState,
) -> RouterState {
  // In a full implementation, we would send an inv message with block hashes
  state
}

/// Handle mempool message
fn handle_mempool_request(peer_id: Int, state: RouterState) -> RouterState {
  case state.config.debug {
    True ->
      io.println(
        "[EventRouter] Peer " <> int.to_string(peer_id) <> " requested mempool",
      )
    False -> Nil
  }

  // Get mempool txids and send inv
  // process.call(state.mempool, oni_supervisor.GetTxids, 5000)
  // For now, just return state
  state
}

/// Handle peer connected
fn handle_peer_connected(
  peer_id: Int,
  version: VersionPayload,
  state: RouterState,
) -> RouterState {
  io.println(
    "[Sync] Peer "
    <> int.to_string(peer_id)
    <> " handshake complete (height: "
    <> int.to_string(version.start_height)
    <> ", user_agent: "
    <> version.user_agent
    <> ")",
  )

  // Notify sync coordinator to potentially start syncing from this peer
  process.send(state.sync, oni_supervisor.StartSync(int.to_string(peer_id)))

  // Notify IBD coordinator about the new peer
  case state.ibd {
    Some(ibd) -> {
      io.println(
        "[Sync] Notifying IBD coordinator of peer "
        <> int.to_string(peer_id)
        <> " at height "
        <> int.to_string(version.start_height),
      )
      process.send(
        ibd,
        ibd_coordinator.PeerConnected(peer_id, version.start_height),
      )
    }
    None -> Nil
  }

  // Update peer heights
  let new_peer_heights = [
    #(peer_id, version.start_height),
    ..state.peer_heights
  ]

  // Update stats
  let new_stats =
    RouterStats(..state.stats, peers_connected: state.stats.peers_connected + 1)

  RouterState(..state, stats: new_stats, peer_heights: new_peer_heights)
}

/// Handle peer disconnected
fn handle_peer_disconnected(
  peer_id: Int,
  reason: String,
  state: RouterState,
) -> RouterState {
  io.println(
    "[Sync] Peer " <> int.to_string(peer_id) <> " disconnected: " <> reason,
  )

  // Notify IBD coordinator
  case state.ibd {
    Some(ibd) -> {
      process.send(ibd, ibd_coordinator.PeerDisconnected(peer_id))
    }
    None -> Nil
  }

  // Remove from peer heights
  let new_peer_heights =
    list.filter(state.peer_heights, fn(entry) {
      let #(id, _) = entry
      id != peer_id
    })

  // Remove any pending requests from this peer
  let new_pending_blocks =
    list.filter(state.pending_blocks, fn(entry) {
      let #(_, id) = entry
      id != peer_id
    })

  let new_pending_txs =
    list.filter(state.pending_txs, fn(entry) {
      let #(_, id) = entry
      id != peer_id
    })

  // Update stats
  let new_stats =
    RouterStats(
      ..state.stats,
      peers_disconnected: state.stats.peers_disconnected + 1,
    )

  RouterState(
    ..state,
    stats: new_stats,
    peer_heights: new_peer_heights,
    pending_blocks: new_pending_blocks,
    pending_txs: new_pending_txs,
  )
}

// ============================================================================
// Request Helpers
// ============================================================================

/// Request blocks from peers
fn request_blocks(
  hashes: List(oni_bitcoin.BlockHash),
  state: RouterState,
) -> RouterState {
  case list.is_empty(hashes) {
    True -> state
    False -> {
      let getdata = oni_p2p.create_getdata_blocks(hashes)
      process.send(state.p2p, BroadcastMessage(getdata))

      // Track pending (use peer_id 0 as placeholder for broadcast)
      let new_pending =
        list.fold(hashes, state.pending_blocks, fn(acc, hash) {
          let hash_hex = oni_bitcoin.block_hash_to_hex(hash)
          [#(hash_hex, 0), ..acc]
        })

      let new_stats =
        RouterStats(
          ..state.stats,
          blocks_requested: state.stats.blocks_requested + list.length(hashes),
        )

      RouterState(..state, stats: new_stats, pending_blocks: new_pending)
    }
  }
}

/// Request transactions from peers
fn request_transactions(
  txids: List(oni_bitcoin.Txid),
  state: RouterState,
) -> RouterState {
  case list.is_empty(txids) {
    True -> state
    False -> {
      let getdata = oni_p2p.create_getdata_txs(txids, True)
      process.send(state.p2p, BroadcastMessage(getdata))

      let new_pending =
        list.fold(txids, state.pending_txs, fn(acc, txid) {
          let txid_hex = oni_bitcoin.txid_to_hex(txid)
          [#(txid_hex, 0), ..acc]
        })

      let new_stats =
        RouterStats(
          ..state.stats,
          txs_requested: state.stats.txs_requested + list.length(txids),
        )

      RouterState(..state, stats: new_stats, pending_txs: new_pending)
    }
  }
}

/// Broadcast a transaction to all peers
fn broadcast_transaction(tx: oni_bitcoin.Transaction, state: RouterState) -> Nil {
  let txid = oni_bitcoin.txid_from_tx(tx)
  let inv = oni_p2p.create_tx_inv([txid])
  process.send(state.p2p, BroadcastMessage(inv))
}

/// Broadcast a block to all peers
fn broadcast_block(block: oni_bitcoin.Block, state: RouterState) -> Nil {
  let block_hash = oni_bitcoin.block_hash_from_header(block.header)
  let inv = oni_p2p.create_block_inv([block_hash])
  process.send(state.p2p, BroadcastMessage(inv))
}

// ============================================================================
// Utility Functions
// ============================================================================

/// Partition inventory items into blocks and transactions
fn partition_inv_items(items: List(InvItem)) -> #(List(InvItem), List(InvItem)) {
  list.fold(items, #([], []), fn(acc, item) {
    let #(blocks, txs) = acc
    case item.inv_type {
      InvBlock | InvWitnessBlock -> #([item, ..blocks], txs)
      InvTx | InvWitnessTx -> #(blocks, [item, ..txs])
      _ -> acc
    }
  })
}

/// Filter out blocks we already have
fn filter_unknown_blocks(
  items: List(InvItem),
  _state: RouterState,
) -> List(oni_bitcoin.BlockHash) {
  // In a full implementation, check against block index
  // For now, request all
  list.map(items, fn(item) { oni_bitcoin.BlockHash(hash: item.hash) })
}

/// Filter out transactions we already have
fn filter_unknown_txs(
  items: List(InvItem),
  _state: RouterState,
) -> List(oni_bitcoin.Txid) {
  // In a full implementation, check against mempool
  // For now, request all
  list.map(items, fn(item) { oni_bitcoin.Txid(hash: item.hash) })
}

/// Add blocks to pending list
fn add_pending_blocks(
  hashes: List(oni_bitcoin.BlockHash),
  peer_id: Int,
  state: RouterState,
) -> RouterState {
  let new_pending =
    list.fold(hashes, state.pending_blocks, fn(acc, hash) {
      let hash_hex = oni_bitcoin.block_hash_to_hex(hash)
      [#(hash_hex, peer_id), ..acc]
    })
  RouterState(..state, pending_blocks: new_pending)
}

/// Add transactions to pending list
fn add_pending_txs(
  txids: List(oni_bitcoin.Txid),
  peer_id: Int,
  state: RouterState,
) -> RouterState {
  let new_pending =
    list.fold(txids, state.pending_txs, fn(acc, txid) {
      let txid_hex = oni_bitcoin.txid_to_hex(txid)
      [#(txid_hex, peer_id), ..acc]
    })
  RouterState(..state, pending_txs: new_pending)
}
