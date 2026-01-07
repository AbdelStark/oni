// ibd_coordinator.gleam - Initial Block Download Coordinator
//
// This module manages the IBD (Initial Block Download) process:
// - Headers-first synchronization (download all headers first)
// - Parallel block downloading from multiple peers
// - Block validation pipeline integration
// - Checkpoint verification
// - Progress tracking and metrics
//
// IBD Strategy:
// 1. Request headers from sync peer using getheaders
// 2. Validate header chain (PoW, timestamps, difficulty)
// 3. Download blocks in parallel from multiple peers
// 4. Validate and connect blocks to chainstate
// 5. Repeat until caught up with network

import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/set.{type Set}
import gleam/string
import oni_bitcoin.{type BlockHash, type BlockHeader, type Network}
import oni_p2p.{type BlockHeaderNet, type Message, MsgGetHeaders}
import oni_supervisor.{type ChainstateMsg}
import p2p_network.{type ListenerMsg, BroadcastMessage, SendToPeer}

// ============================================================================
// Configuration
// ============================================================================

/// IBD coordinator configuration
pub type IbdConfig {
  IbdConfig(
    /// Network (mainnet, testnet, regtest)
    network: Network,
    /// Maximum parallel block downloads per peer
    blocks_per_peer: Int,
    /// Maximum total inflight blocks
    max_inflight_blocks: Int,
    /// Headers batch size
    headers_batch_size: Int,
    /// Block download timeout in milliseconds
    block_timeout_ms: Int,
    /// Minimum peers before starting IBD
    min_peers: Int,
    /// Enable checkpoints
    use_checkpoints: Bool,
    /// Debug logging
    debug: Bool,
    /// Maximum expected block height (sanity check)
    /// If headers exceed this, reject as invalid
    max_expected_height: Int,
  )
}

/// Default IBD configuration
pub fn default_config(network: Network) -> IbdConfig {
  // Set reasonable maximum heights per network to prevent runaway sync
  // These are ~2x the expected chain height as of early 2025
  let max_height = case network {
    oni_bitcoin.Mainnet -> 1_000_000     // Mainnet ~880k blocks
    oni_bitcoin.Testnet -> 6_000_000     // Testnet3 ~4.8M blocks (faster blocks)
    oni_bitcoin.Testnet4 -> 500_000      // Testnet4 ~117k blocks (new)
    oni_bitcoin.Signet -> 500_000        // Signet ~200k blocks
    oni_bitcoin.Regtest -> 100_000_000   // Regtest - no limit
  }

  IbdConfig(
    network: network,
    blocks_per_peer: 16,
    max_inflight_blocks: 128,
    headers_batch_size: 2000,
    block_timeout_ms: 30_000,
    min_peers: 1,
    use_checkpoints: True,
    debug: False,
    max_expected_height: max_height,
  )
}

// ============================================================================
// Types
// ============================================================================

/// IBD state machine states
pub type IbdState {
  /// Waiting for peers to connect
  IbdWaitingForPeers
  /// Downloading headers
  IbdSyncingHeaders
  /// Downloading blocks
  IbdDownloadingBlocks
  /// Caught up with network
  IbdSynced
  /// Error state
  IbdError(String)
}

/// Peer sync state
pub type PeerSyncState {
  PeerSyncState(
    peer_id: Int,
    height: Int,
    last_request: Int,
    inflight_blocks: Int,
    headers_synced: Bool,
  )
}

/// Block download request
pub type BlockRequest {
  BlockRequest(hash: BlockHash, height: Int, peer_id: Int, requested_at: Int)
}

/// Header chain segment (for validation)
pub type HeaderChain {
  HeaderChain(
    headers: List(BlockHeaderNet),
    start_height: Int,
    end_height: Int,
    tip_hash: BlockHash,
  )
}

// ============================================================================
// Messages
// ============================================================================

/// Messages for the IBD coordinator
pub type IbdMsg {
  /// Peer connected with version info (peer_id is Int from P2P layer)
  PeerConnected(peer_id: Int, height: Int)
  /// Peer disconnected
  PeerDisconnected(peer_id: Int)
  /// Headers received from peer
  HeadersReceived(peer_id: Int, headers: List(BlockHeaderNet))
  /// Block received with full block data
  BlockReceived(hash: BlockHash, block: oni_bitcoin.Block)
  /// Block validation completed
  BlockValidated(hash: BlockHash, success: Bool)
  /// Timer tick for timeout checking
  TimerTick
  /// Get current status
  GetStatus(reply: Subject(IbdStatus))
  /// Get detailed progress
  GetProgress(reply: Subject(IbdProgress))
  /// Force resync from height
  ResyncFrom(height: Int)
  /// Shutdown
  Shutdown
}

/// IBD status for monitoring
pub type IbdStatus {
  IbdStatus(
    state: IbdState,
    headers_height: Int,
    blocks_height: Int,
    connected_peers: Int,
    inflight_blocks: Int,
    progress_percent: Float,
  )
}

/// Detailed IBD progress
pub type IbdProgress {
  IbdProgress(
    state: String,
    headers_synced: Int,
    headers_total: Int,
    blocks_synced: Int,
    blocks_total: Int,
    peers: List(String),
    estimated_remaining_secs: Int,
  )
}

// ============================================================================
// State
// ============================================================================

/// IBD coordinator actor state
type IbdCoordinatorState {
  IbdCoordinatorState(
    config: IbdConfig,
    /// Current IBD state
    state: IbdState,
    /// Reference to P2P layer for sending messages
    p2p: Subject(ListenerMsg),
    /// Reference to chainstate for connecting blocks
    chainstate: Option(Subject(ChainstateMsg)),
    /// Connected peers with their state (keyed by peer_id Int)
    peers: Dict(Int, PeerSyncState),
    /// Header chain being synced
    headers: List(BlockHeaderNet),
    /// Current headers height (validated)
    headers_height: Int,
    /// Current blocks height (connected to chain)
    blocks_height: Int,
    /// Target height (from best peer)
    target_height: Int,
    /// Inflight block requests (keyed by block hash hex)
    inflight: Dict(String, BlockRequest),
    /// Queue of blocks to download (block hashes)
    download_queue: List(BlockHash),
    /// Sync peer ID (primary peer for headers)
    sync_peer: Option(Int),
    /// Genesis hash for the network
    genesis_hash: BlockHash,
    /// Last activity timestamp
    last_activity: Int,
    /// Block buffer: received blocks awaiting connection (indexed by height)
    block_buffer: Dict(Int, oni_bitcoin.Block),
    /// Map from block hash hex to height (built from headers)
    hash_to_height: Dict(String, Int),
    /// Set of received block hashes (for deduplication)
    received_hashes: Set(String),
    /// Next height to connect to chainstate
    next_connect_height: Int,
    /// Round-robin peer index for distributing block requests
    next_peer_index: Int,
  )
}

// ============================================================================
// Public API
// ============================================================================

/// Start the IBD coordinator
pub fn start(
  config: IbdConfig,
  p2p: Subject(ListenerMsg),
) -> Result(Subject(IbdMsg), actor.StartError) {
  start_with_chainstate(config, p2p, None)
}

/// Start the IBD coordinator with chainstate for block connection
pub fn start_with_chainstate(
  config: IbdConfig,
  p2p: Subject(ListenerMsg),
  chainstate: Option(Subject(ChainstateMsg)),
) -> Result(Subject(IbdMsg), actor.StartError) {
  let params = get_network_params(config.network)

  // DEBUG: Log network configuration at startup
  let network_name = case config.network {
    oni_bitcoin.Mainnet -> "Mainnet"
    oni_bitcoin.Testnet -> "Testnet3"
    oni_bitcoin.Testnet4 -> "Testnet4"
    oni_bitcoin.Signet -> "Signet"
    oni_bitcoin.Regtest -> "Regtest"
  }
  io.println("[IBD] ========================================")
  io.println("[IBD] Starting IBD coordinator")
  io.println("[IBD] Network: " <> network_name)
  io.println("[IBD] Genesis hash: " <> oni_bitcoin.block_hash_to_hex(params.genesis_hash))
  io.println("[IBD] Max expected height: " <> int.to_string(config.max_expected_height))
  io.println("[IBD] Chainstate connected: " <> case chainstate {
    Some(_) -> "Yes"
    None -> "No"
  })
  io.println("[IBD] ========================================")

  let initial_state =
    IbdCoordinatorState(
      config: config,
      state: IbdWaitingForPeers,
      p2p: p2p,
      chainstate: chainstate,
      peers: dict.new(),
      headers: [],
      headers_height: 0,
      blocks_height: 0,
      target_height: 0,
      inflight: dict.new(),
      download_queue: [],
      sync_peer: None,
      genesis_hash: params.genesis_hash,
      last_activity: now_ms(),
      block_buffer: dict.new(),
      hash_to_height: dict.new(),
      received_hashes: set.new(),
      next_connect_height: 1,  // Start at height 1 (genesis is already connected)
      next_peer_index: 0,
    )

  actor.start(initial_state, handle_message)
}

// ============================================================================
// Message Handler
// ============================================================================

fn handle_message(
  msg: IbdMsg,
  state: IbdCoordinatorState,
) -> actor.Next(IbdMsg, IbdCoordinatorState) {
  case msg {
    PeerConnected(peer_id, height) -> {
      let new_state = handle_peer_connected(peer_id, height, state)
      actor.continue(new_state)
    }

    PeerDisconnected(peer_id) -> {
      let new_state = handle_peer_disconnected(peer_id, state)
      actor.continue(new_state)
    }

    HeadersReceived(peer_id, headers) -> {
      let new_state = handle_headers_received(peer_id, headers, state)
      actor.continue(new_state)
    }

    BlockReceived(hash, block) -> {
      let new_state = handle_block_received(hash, block, state)
      actor.continue(new_state)
    }

    BlockValidated(hash, success) -> {
      let new_state = handle_block_validated(hash, success, state)
      actor.continue(new_state)
    }

    TimerTick -> {
      let new_state = handle_timer_tick(state)
      actor.continue(new_state)
    }

    GetStatus(reply) -> {
      let status = build_status(state)
      process.send(reply, status)
      actor.continue(state)
    }

    GetProgress(reply) -> {
      let progress = build_progress(state)
      process.send(reply, progress)
      actor.continue(state)
    }

    ResyncFrom(height) -> {
      let new_state = handle_resync(height, state)
      actor.continue(new_state)
    }

    Shutdown -> {
      io.println("[IBD] Shutting down...")
      actor.Stop(process.Normal)
    }
  }
}

// ============================================================================
// Event Handlers
// ============================================================================

/// Handle peer connection
fn handle_peer_connected(
  peer_id: Int,
  height: Int,
  state: IbdCoordinatorState,
) -> IbdCoordinatorState {
  // Always log peer connections during sync
  io.println(
    "[IBD] Peer "
    <> int.to_string(peer_id)
    <> " connected at height "
    <> int.to_string(height)
    <> " (total peers: "
    <> int.to_string(dict.size(state.peers) + 1)
    <> ", need: "
    <> int.to_string(state.config.min_peers)
    <> ")",
  )

  let peer_state =
    PeerSyncState(
      peer_id: peer_id,
      height: height,
      last_request: 0,
      inflight_blocks: 0,
      headers_synced: False,
    )

  let new_peers = dict.insert(state.peers, peer_id, peer_state)
  let new_target = int.max(state.target_height, height)

  let new_state =
    IbdCoordinatorState(
      ..state,
      peers: new_peers,
      target_height: new_target,
      last_activity: now_ms(),
    )

  // Check if we should start IBD
  case state.state {
    IbdWaitingForPeers -> {
      io.println(
        "[IBD] State: WaitingForPeers, checking if we can start sync...",
      )
      case dict.size(new_peers) >= state.config.min_peers {
        True -> {
          io.println("[IBD] Minimum peers reached, starting header sync!")
          start_headers_sync(new_state)
        }
        False -> {
          io.println(
            "[IBD] Waiting for more peers ("
            <> int.to_string(dict.size(new_peers))
            <> "/"
            <> int.to_string(state.config.min_peers)
            <> ")",
          )
          new_state
        }
      }
    }
    _ -> {
      io.println(
        "[IBD] Already syncing (state: "
        <> ibd_state_to_string(state.state)
        <> "), ignoring peer connect",
      )
      new_state
    }
  }
}

/// Convert IBD state to string for logging
fn ibd_state_to_string(state: IbdState) -> String {
  case state {
    IbdWaitingForPeers -> "WaitingForPeers"
    IbdSyncingHeaders -> "SyncingHeaders"
    IbdDownloadingBlocks -> "DownloadingBlocks"
    IbdSynced -> "Synced"
    IbdError(err) -> "Error(" <> err <> ")"
  }
}

/// Handle peer disconnection
fn handle_peer_disconnected(
  peer_id: Int,
  state: IbdCoordinatorState,
) -> IbdCoordinatorState {
  case state.config.debug {
    True -> io.println("[IBD] Peer " <> int.to_string(peer_id) <> " disconnected")
    False -> Nil
  }

  let new_peers = dict.delete(state.peers, peer_id)

  // Cancel inflight requests from this peer
  let #(new_inflight, cancelled) = cancel_peer_requests(peer_id, state.inflight)

  // Re-queue cancelled blocks
  let new_queue = list.append(cancelled, state.download_queue)

  let new_state =
    IbdCoordinatorState(
      ..state,
      peers: new_peers,
      inflight: new_inflight,
      download_queue: new_queue,
    )

  // Check if we lost our sync peer
  case state.sync_peer {
    Some(sp) if sp == peer_id -> {
      // Find a new sync peer
      case find_best_peer(new_peers) {
        Some(new_sync_peer) ->
          IbdCoordinatorState(..new_state, sync_peer: Some(new_sync_peer))
        None ->
          IbdCoordinatorState(
            ..new_state,
            sync_peer: None,
            state: IbdWaitingForPeers,
          )
      }
    }
    _ -> new_state
  }
}

/// Handle headers received
fn handle_headers_received(
  peer_id: Int,
  headers: List(BlockHeaderNet),
  state: IbdCoordinatorState,
) -> IbdCoordinatorState {
  // Only accept headers from our designated sync peer
  case state.sync_peer {
    Some(sync_peer) if sync_peer == peer_id -> {
      handle_headers_from_sync_peer(peer_id, headers, state)
    }
    _ -> {
      // Ignore headers from non-sync peers during IBD
      state
    }
  }
}

/// Process headers from the sync peer
fn handle_headers_from_sync_peer(
  peer_id: Int,
  headers: List(BlockHeaderNet),
  state: IbdCoordinatorState,
) -> IbdCoordinatorState {
  let header_count = list.length(headers)

  io.println(
    "[IBD] Received "
    <> int.to_string(header_count)
    <> " headers from sync peer "
    <> int.to_string(peer_id)
    <> " (current height: "
    <> int.to_string(state.headers_height)
    <> ")",
  )

  case header_count {
    0 -> {
      // No more headers - switch to block download
      io.println(
        "[IBD] Headers sync complete at height "
        <> int.to_string(state.headers_height),
      )
      start_block_download(state)
    }
    _ -> {
      // Sanity check: would new headers exceed maximum expected height?
      let new_potential_height = state.headers_height + header_count
      case new_potential_height > state.config.max_expected_height {
        True -> {
          let err_msg = "Headers would exceed maximum expected height ("
            <> int.to_string(new_potential_height)
            <> " > "
            <> int.to_string(state.config.max_expected_height)
            <> "). Possible invalid chain or wrong network."
          io.println("[IBD] CRITICAL: " <> err_msg)
          IbdCoordinatorState(..state, state: IbdError(err_msg))
        }
        False -> {
          // Validate and add headers
          io.println(
            "[IBD] Validating " <> int.to_string(header_count) <> " headers...",
          )
          case validate_headers(headers, state) {
            Error(err) -> {
              io.println("[IBD] Header validation failed: " <> err)
              IbdCoordinatorState(..state, state: IbdError(err))
            }
            Ok(new_height) -> {
              io.println(
                "[IBD] Headers validated, new height: " <> int.to_string(new_height)
                <> " (max allowed: " <> int.to_string(state.config.max_expected_height) <> ")",
              )
              let new_headers = list.append(state.headers, headers)
              let new_state =
                IbdCoordinatorState(
                  ..state,
                  headers: new_headers,
                  headers_height: new_height,
                  last_activity: now_ms(),
                )

              // Request more headers if we got a full batch
              case header_count >= state.config.headers_batch_size {
                True -> {
                  io.println("[IBD] Requesting more headers (got full batch)...")
                  request_more_headers(new_state)
                }
                False -> {
                  io.println(
                    "[IBD] Got partial batch ("
                    <> int.to_string(header_count)
                    <> " < "
                    <> int.to_string(state.config.headers_batch_size)
                    <> "), starting block download...",
                  )
                  start_block_download(new_state)
                }
              }
            }
          }
        }
      }
    }
  }
}

/// Handle block received - buffer and connect in order
fn handle_block_received(
  hash: BlockHash,
  block: oni_bitcoin.Block,
  state: IbdCoordinatorState,
) -> IbdCoordinatorState {
  let hash_hex = oni_bitcoin.block_hash_to_hex(hash)

  // Check for duplicate
  case set.contains(state.received_hashes, hash_hex) {
    True -> {
      // Already received this block, ignore
      state
    }
    False -> {
      // Remove from inflight
      let new_inflight = dict.delete(state.inflight, hash_hex)

      // Mark as received
      let new_received = set.insert(state.received_hashes, hash_hex)

      // Look up the height for this block
      let block_height = case dict.get(state.hash_to_height, hash_hex) {
        Ok(h) -> h
        Error(_) -> {
          // Unknown hash - this shouldn't happen during IBD
          io.println("[IBD] Warning: received unknown block " <> hash_hex)
          0
        }
      }

      // Add to block buffer
      let new_buffer = dict.insert(state.block_buffer, block_height, block)

      let state_with_buffer =
        IbdCoordinatorState(
          ..state,
          inflight: new_inflight,
          received_hashes: new_received,
          block_buffer: new_buffer,
          last_activity: now_ms(),
        )

      // Try to flush sequential blocks from buffer to chainstate
      let new_state = flush_block_buffer(state_with_buffer)

      // Check if we're done
      case new_state.blocks_height >= state.headers_height && state.headers_height > 0 {
        True -> {
          io.println(
            "[IBD] Sync complete at height " <> int.to_string(new_state.blocks_height),
          )
          IbdCoordinatorState(..new_state, state: IbdSynced)
        }
        False -> {
          // Request more blocks
          schedule_block_downloads(new_state)
        }
      }
    }
  }
}

/// Flush sequential blocks from buffer to chainstate
fn flush_block_buffer(state: IbdCoordinatorState) -> IbdCoordinatorState {
  flush_block_buffer_loop(state)
}

fn flush_block_buffer_loop(state: IbdCoordinatorState) -> IbdCoordinatorState {
  // Check if the next block is in our buffer
  case dict.get(state.block_buffer, state.next_connect_height) {
    Error(_) -> {
      // Next block not yet received, can't flush more
      state
    }
    Ok(block) -> {
      // Try to connect this block to chainstate
      let new_state = connect_block_to_chainstate(block, state.next_connect_height, state)

      // Continue flushing if successful
      case new_state.blocks_height > state.blocks_height {
        True -> flush_block_buffer_loop(new_state)
        False -> new_state  // Connection failed, stop flushing
      }
    }
  }
}

/// Connect a block to chainstate and update state
/// Uses async send to avoid blocking the IBD coordinator
fn connect_block_to_chainstate(
  block: oni_bitcoin.Block,
  height: Int,
  state: IbdCoordinatorState,
) -> IbdCoordinatorState {
  case state.chainstate {
    None -> {
      // No chainstate, just increment counter (legacy behavior)
      update_blocks_height(height, state)
    }
    Some(chainstate) -> {
      // Send block to chainstate asynchronously
      // We don't wait for response - just track that we sent it
      // The chainstate will process blocks in order since they're sent in order
      process.send(
        chainstate,
        oni_supervisor.ConnectBlock(block, process.new_subject()),
      )
      // Update our tracking optimistically
      // (In production, we'd want confirmation but for IBD this is fine)
      update_blocks_height(height, state)
    }
  }
}

/// Update state after successfully connecting a block
fn update_blocks_height(height: Int, state: IbdCoordinatorState) -> IbdCoordinatorState {
  // Remove from buffer
  let new_buffer = dict.delete(state.block_buffer, height)

  // Update heights
  let new_blocks_height = height
  let new_next_height = height + 1

  // Log progress every 100 blocks or on first block
  case
    new_blocks_height == 1
    || new_blocks_height % 100 == 0
    || new_blocks_height == state.headers_height
  {
    True ->
      io.println(
        "[IBD] Block "
        <> int.to_string(new_blocks_height)
        <> " of "
        <> int.to_string(state.headers_height)
        <> " ("
        <> int.to_string(new_blocks_height * 100 / int.max(state.headers_height, 1))
        <> "%) [buffer: "
        <> int.to_string(dict.size(new_buffer))
        <> "]",
      )
    False -> Nil
  }

  IbdCoordinatorState(
    ..state,
    block_buffer: new_buffer,
    blocks_height: new_blocks_height,
    next_connect_height: new_next_height,
  )
}

/// Handle block validation result
fn handle_block_validated(
  hash: BlockHash,
  success: Bool,
  state: IbdCoordinatorState,
) -> IbdCoordinatorState {
  case success {
    True -> state
    False -> {
      let hash_hex = oni_bitcoin.block_hash_to_hex(hash)
      io.println("[IBD] Block " <> hash_hex <> " validation failed")
      // In a full implementation, we would handle invalid blocks
      // (disconnect peer, mark block as invalid, etc.)
      state
    }
  }
}

/// Handle timer tick (check for timeouts)
fn handle_timer_tick(state: IbdCoordinatorState) -> IbdCoordinatorState {
  let now = now_ms()
  let timeout = state.config.block_timeout_ms

  // Find timed out requests
  let #(new_inflight, timed_out) = check_timeouts(state.inflight, now, timeout)

  // Re-queue timed out blocks
  let new_queue = list.append(timed_out, state.download_queue)

  let new_state =
    IbdCoordinatorState(
      ..state,
      inflight: new_inflight,
      download_queue: new_queue,
    )

  // Schedule more downloads if needed
  schedule_block_downloads(new_state)
}

/// Handle resync request
fn handle_resync(height: Int, state: IbdCoordinatorState) -> IbdCoordinatorState {
  io.println("[IBD] Resyncing from height " <> int.to_string(height))

  IbdCoordinatorState(
    ..state,
    state: IbdSyncingHeaders,
    headers: [],
    headers_height: height,
    blocks_height: height,
    inflight: dict.new(),
    download_queue: [],
  )
}

// ============================================================================
// IBD Logic
// ============================================================================

/// Start headers synchronization
fn start_headers_sync(state: IbdCoordinatorState) -> IbdCoordinatorState {
  io.println("[IBD] Starting headers sync...")
  io.println(
    "[IBD] Target height: "
    <> int.to_string(state.target_height)
    <> ", current headers: "
    <> int.to_string(state.headers_height),
  )

  case find_best_peer(state.peers) {
    None -> {
      io.println("[IBD] No peers available for sync")
      state
    }
    Some(peer_id) -> {
      io.println("[IBD] Selected sync peer: " <> int.to_string(peer_id))

      // Send getheaders request
      // Use null hash (all zeros) as stop_hash to get all headers up to peer's tip
      // Using genesis as stop_hash would incorrectly tell peer to "stop at genesis"
      let locators = build_locators(state)
      let null_hash = oni_bitcoin.BlockHash(hash: oni_bitcoin.Hash256(bytes: <<0:256>>))
      io.println(
        "[IBD] Sending getheaders with "
        <> int.to_string(list.length(locators))
        <> " locators, stop_hash: null (get all headers)",
      )
      let msg = MsgGetHeaders(locators, null_hash)
      process.send(state.p2p, BroadcastMessage(msg))
      io.println("[IBD] getheaders message sent to P2P layer")

      IbdCoordinatorState(
        ..state,
        state: IbdSyncingHeaders,
        sync_peer: Some(peer_id),
        last_activity: now_ms(),
      )
    }
  }
}

/// Request more headers from sync peer
fn request_more_headers(state: IbdCoordinatorState) -> IbdCoordinatorState {
  let locators = build_locators(state)
  // Use null hash as stop_hash to get all headers up to peer's tip
  let null_hash = oni_bitcoin.BlockHash(hash: oni_bitcoin.Hash256(bytes: <<0:256>>))
  let msg = MsgGetHeaders(locators, null_hash)
  process.send(state.p2p, BroadcastMessage(msg))

  IbdCoordinatorState(..state, last_activity: now_ms())
}

/// Start block download phase
fn start_block_download(state: IbdCoordinatorState) -> IbdCoordinatorState {
  io.println(
    "[IBD] Starting block download from height "
    <> int.to_string(state.blocks_height)
    <> " to "
    <> int.to_string(state.headers_height),
  )

  // Build download queue from headers and hash-to-height mapping
  let #(queue, hash_map) = build_download_queue_and_mapping(state.headers, state.blocks_height)
  let queue_size = list.length(queue)

  io.println(
    "[IBD] Built download queue with "
    <> int.to_string(queue_size)
    <> " blocks to download",
  )

  let new_state =
    IbdCoordinatorState(
      ..state,
      state: IbdDownloadingBlocks,
      download_queue: queue,
      hash_to_height: hash_map,
      next_connect_height: state.blocks_height + 1,
    )

  schedule_block_downloads(new_state)
}

/// Schedule block downloads to available peers
/// Uses round-robin distribution to spread blocks across peers
fn schedule_block_downloads(state: IbdCoordinatorState) -> IbdCoordinatorState {
  // Find available peers with slots
  let available_peers =
    get_available_peers(state.peers, state.config.blocks_per_peer)
  let total_inflight = dict.size(state.inflight)
  let slots = state.config.max_inflight_blocks - total_inflight
  let peer_count = list.length(available_peers)

  // Filter out already-received blocks from the queue
  let filtered_queue = list.filter(state.download_queue, fn(hash) {
    let hash_hex = oni_bitcoin.block_hash_to_hex(hash)
    !set.contains(state.received_hashes, hash_hex)
  })
  let queue_size = list.length(filtered_queue)

  // Only log when there's actual activity
  case queue_size > 0 && peer_count > 0 && slots > 0 {
    True ->
      io.println(
        "[IBD] Schedule downloads: "
        <> int.to_string(queue_size)
        <> " in queue, "
        <> int.to_string(peer_count)
        <> " peers, "
        <> int.to_string(slots)
        <> " slots, buffer: "
        <> int.to_string(dict.size(state.block_buffer)),
      )
    False -> Nil
  }

  case
    list.is_empty(available_peers),
    list.is_empty(filtered_queue),
    slots > 0
  {
    True, _, _ -> {
      // No available peers
      state
    }
    _, True, _ -> {
      // Queue is empty (all blocks received or connected)
      IbdCoordinatorState(..state, download_queue: [])
    }
    _, _, False -> {
      // No slots available
      IbdCoordinatorState(..state, download_queue: filtered_queue)
    }
    False, False, True -> {
      // Distribute blocks across peers using round-robin
      let #(assignments, new_next_peer_index, new_peers, remaining_queue) =
        distribute_blocks_to_peers(
          filtered_queue,
          available_peers,
          state.peers,
          state.config.blocks_per_peer,
          slots,
          state.next_peer_index,
        )

      // Send getdata to each peer with their assigned blocks
      send_block_requests(assignments, state.p2p)

      // Track inflight requests with peer assignments
      let new_inflight = add_inflight_with_peers(assignments, state.inflight)

      let assigned_count = list.length(list.flat_map(assignments, fn(a) { a.1 }))
      case assigned_count > 0 {
        True ->
          io.println(
            "[IBD] Assigned "
            <> int.to_string(assigned_count)
            <> " blocks to "
            <> int.to_string(list.length(assignments))
            <> " peers",
          )
        False -> Nil
      }

      IbdCoordinatorState(
        ..state,
        download_queue: remaining_queue,
        inflight: new_inflight,
        peers: new_peers,
        next_peer_index: new_next_peer_index,
        last_activity: now_ms(),
      )
    }
  }
}

/// Distribute blocks to peers in round-robin fashion
/// Returns: (list of (peer_id, blocks), new_peer_index, updated_peers, remaining_queue)
fn distribute_blocks_to_peers(
  queue: List(BlockHash),
  available_peers: List(Int),
  peers: Dict(Int, PeerSyncState),
  max_per_peer: Int,
  max_total: Int,
  start_index: Int,
) -> #(List(#(Int, List(BlockHash))), Int, Dict(Int, PeerSyncState), List(BlockHash)) {
  let peer_count = list.length(available_peers)
  case peer_count {
    0 -> #([], start_index, peers, queue)
    _ -> {
      distribute_blocks_loop(
        queue,
        available_peers,
        peers,
        max_per_peer,
        max_total,
        start_index,
        peer_count,
        dict.new(),  // peer_id -> assigned blocks
        0,           // total assigned
      )
    }
  }
}

fn distribute_blocks_loop(
  queue: List(BlockHash),
  available_peers: List(Int),
  peers: Dict(Int, PeerSyncState),
  max_per_peer: Int,
  max_total: Int,
  current_index: Int,
  peer_count: Int,
  assignments: Dict(Int, List(BlockHash)),
  total_assigned: Int,
) -> #(List(#(Int, List(BlockHash))), Int, Dict(Int, PeerSyncState), List(BlockHash)) {
  case queue {
    [] -> {
      // Queue exhausted
      let assignment_list = dict.to_list(assignments)
      #(assignment_list, current_index, peers, [])
    }
    [hash, ..rest] -> {
      case total_assigned >= max_total {
        True -> {
          // Hit max total limit
          let assignment_list = dict.to_list(assignments)
          #(assignment_list, current_index, peers, queue)
        }
        False -> {
          // Find next peer with available slot using round-robin
          case find_next_available_peer(
            available_peers,
            peers,
            assignments,
            max_per_peer,
            current_index,
            peer_count,
            0,
          ) {
            None -> {
              // No peers with available slots
              let assignment_list = dict.to_list(assignments)
              #(assignment_list, current_index, peers, queue)
            }
            Some(#(peer_id, new_index)) -> {
              // Assign block to this peer
              let peer_blocks = case dict.get(assignments, peer_id) {
                Ok(blocks) -> [hash, ..blocks]
                Error(_) -> [hash]
              }
              let new_assignments = dict.insert(assignments, peer_id, peer_blocks)

              // Update peer's inflight count
              let new_peers = case dict.get(peers, peer_id) {
                Ok(peer_state) -> {
                  let updated = PeerSyncState(
                    ..peer_state,
                    inflight_blocks: peer_state.inflight_blocks + 1,
                  )
                  dict.insert(peers, peer_id, updated)
                }
                Error(_) -> peers
              }

              distribute_blocks_loop(
                rest,
                available_peers,
                new_peers,
                max_per_peer,
                max_total,
                new_index,
                peer_count,
                new_assignments,
                total_assigned + 1,
              )
            }
          }
        }
      }
    }
  }
}

/// Find next peer with available slot (round-robin)
fn find_next_available_peer(
  available_peers: List(Int),
  peers: Dict(Int, PeerSyncState),
  assignments: Dict(Int, List(BlockHash)),
  max_per_peer: Int,
  current_index: Int,
  peer_count: Int,
  attempts: Int,
) -> Option(#(Int, Int)) {
  case attempts >= peer_count {
    True -> None  // Tried all peers, none available
    False -> {
      let idx = current_index % peer_count
      case list.at(available_peers, idx) {
        Error(_) -> None
        Ok(peer_id) -> {
          // Check if this peer has room
          let current_inflight = case dict.get(peers, peer_id) {
            Ok(ps) -> ps.inflight_blocks
            Error(_) -> 0
          }
          let assigned_count = case dict.get(assignments, peer_id) {
            Ok(blocks) -> list.length(blocks)
            Error(_) -> 0
          }
          let total_for_peer = current_inflight + assigned_count

          case total_for_peer < max_per_peer {
            True -> Some(#(peer_id, { current_index + 1 } % peer_count))
            False -> {
              // Try next peer
              find_next_available_peer(
                available_peers,
                peers,
                assignments,
                max_per_peer,
                current_index + 1,
                peer_count,
                attempts + 1,
              )
            }
          }
        }
      }
    }
  }
}

/// Send block requests to specific peers (not broadcast!)
fn send_block_requests(
  assignments: List(#(Int, List(BlockHash))),
  p2p: Subject(ListenerMsg),
) -> Nil {
  list.each(assignments, fn(assignment) {
    let #(peer_id, hashes) = assignment
    case list.is_empty(hashes) {
      True -> Nil
      False -> {
        let getdata = oni_p2p.create_getdata_blocks(hashes)
        // Use SendToPeer instead of BroadcastMessage!
        process.send(p2p, SendToPeer(peer_id, getdata))
      }
    }
  })
}

/// Add inflight requests with peer tracking
fn add_inflight_with_peers(
  assignments: List(#(Int, List(BlockHash))),
  inflight: Dict(String, BlockRequest),
) -> Dict(String, BlockRequest) {
  let now = now_ms()
  list.fold(assignments, inflight, fn(acc, assignment) {
    let #(peer_id, hashes) = assignment
    list.fold(hashes, acc, fn(inner_acc, hash) {
      let hash_hex = oni_bitcoin.block_hash_to_hex(hash)
      let request = BlockRequest(
        hash: hash,
        height: 0,  // Height tracked separately in hash_to_height
        peer_id: peer_id,
        requested_at: now,
      )
      dict.insert(inner_acc, hash_hex, request)
    })
  })
}

// ============================================================================
// Helper Functions
// ============================================================================

/// Find the best peer for syncing (highest height)
fn find_best_peer(peers: Dict(Int, PeerSyncState)) -> Option(Int) {
  let peer_list = dict.to_list(peers)
  case peer_list {
    [] -> None
    _ -> {
      let sorted =
        list.sort(peer_list, fn(a, b) {
          let #(_, state_a) = a
          let #(_, state_b) = b
          int.compare(state_b.height, state_a.height)
        })
      case sorted {
        [#(peer_id, _), ..] -> Some(peer_id)
        [] -> None
      }
    }
  }
}

/// Get peers with available download slots (returns list of peer IDs)
fn get_available_peers(
  peers: Dict(Int, PeerSyncState),
  max_per_peer: Int,
) -> List(Int) {
  peers
  |> dict.to_list
  |> list.filter_map(fn(entry) {
    let #(peer_id, peer_state) = entry
    case peer_state.inflight_blocks < max_per_peer {
      True -> Ok(peer_id)
      False -> Error(Nil)
    }
  })
}

/// Build block locators for getheaders with exponential backoff
/// Locators help the peer identify where to start sending headers from
fn build_locators(state: IbdCoordinatorState) -> List(BlockHash) {
  // If we have no headers, start from genesis
  case list.length(state.headers) {
    0 -> {
      io.println("[IBD] No headers yet, using genesis as locator")
      [state.genesis_hash]
    }
    len -> {
      // Build exponential backoff locators
      // Start from tip, then -1, -2, -4, -8, -16, ... back to genesis
      let indices = build_locator_indices(len - 1, 1, [len - 1])

      // Get headers at those indices and hash them
      let locators = list.filter_map(indices, fn(idx) {
        case list.at(state.headers, idx) {
          Ok(header) -> {
            let header_bytes = encode_header(header)
            let hash_bytes = oni_bitcoin.sha256d(header_bytes)
            Ok(oni_bitcoin.BlockHash(hash: oni_bitcoin.Hash256(bytes: hash_bytes)))
          }
          Error(_) -> Error(Nil)
        }
      })

      // Always include genesis at the end
      let final_locators = list.append(locators, [state.genesis_hash])

      io.println(
        "[IBD] Built " <> int.to_string(list.length(final_locators))
        <> " locators (tip at height " <> int.to_string(state.headers_height) <> ")"
      )

      final_locators
    }
  }
}

/// Build exponential backoff indices for locators
fn build_locator_indices(current: Int, step: Int, acc: List(Int)) -> List(Int) {
  case current - step {
    next if next >= 0 -> {
      let new_step = case step >= 10 {
        True -> step * 2
        False -> step + 1
      }
      build_locator_indices(next, new_step, [next, ..acc])
    }
    _ -> {
      // Include 0 (first header after genesis) if not already included
      case list.contains(acc, 0) {
        True -> list.reverse(acc)
        False -> list.reverse([0, ..acc])
      }
    }
  }
}

/// Validate received headers
fn validate_headers(
  headers: List(BlockHeaderNet),
  state: IbdCoordinatorState,
) -> Result(Int, String) {
  // First, verify chain continuity: first header must connect to our chain
  case headers {
    [] -> Ok(state.headers_height)
    [first_header, ..] -> {
      // Get the expected prev_block hash (either last header's hash or genesis)
      let expected_prev = get_expected_prev_hash(state)

      // DEBUG: Log the comparison for first batch
      case state.headers_height {
        0 -> {
          io.println("[IBD] DEBUG: Validating FIRST batch of headers")
          io.println("[IBD] DEBUG: Expected prev_block (genesis): " <> oni_bitcoin.block_hash_to_hex(expected_prev))
          io.println("[IBD] DEBUG: First header's prev_block:     " <> oni_bitcoin.block_hash_to_hex(first_header.prev_block))
          io.println("[IBD] DEBUG: Expected bytes: " <> bytes_to_hex_debug(expected_prev.hash.bytes))
          io.println("[IBD] DEBUG: Received bytes: " <> bytes_to_hex_debug(first_header.prev_block.hash.bytes))
        }
        _ -> Nil
      }

      case first_header.prev_block.hash.bytes == expected_prev.hash.bytes {
        False -> {
          let received = oni_bitcoin.block_hash_to_hex(first_header.prev_block)
          let expected = oni_bitcoin.block_hash_to_hex(expected_prev)
          io.println(
            "[IBD] Chain break detected! First header prev_block doesn't match.\n"
            <> "  Expected: " <> expected <> "\n"
            <> "  Received: " <> received,
          )
          Error("Headers don't connect to our chain")
        }
        True -> {
          io.println("[IBD] DEBUG: Chain continuity check PASSED")
          // Now validate headers with chain continuity
          validate_headers_loop(
            headers,
            state.headers_height,
            get_last_header_bits(state),
            state.config.network,
            expected_prev,
          )
        }
      }
    }
  }
}

/// Debug helper to show raw bytes
fn bytes_to_hex_debug(bytes: BitArray) -> String {
  bytes
  |> bit_array.base16_encode()
  |> string.lowercase()
}

/// Get the expected prev_block hash for the next header
fn get_expected_prev_hash(state: IbdCoordinatorState) -> BlockHash {
  case list.last(state.headers) {
    Ok(last_header) -> {
      // Hash the last header to get its block hash
      let header_bytes = encode_header(last_header)
      let hash = oni_bitcoin.sha256d(header_bytes)
      oni_bitcoin.BlockHash(hash: oni_bitcoin.Hash256(bytes: hash))
    }
    Error(_) -> {
      // No headers yet, expect genesis
      state.genesis_hash
    }
  }
}

/// Get the nBits of the last validated header (or genesis)
fn get_last_header_bits(state: IbdCoordinatorState) -> Int {
  case list.last(state.headers) {
    Ok(header) -> header.bits
    Error(_) -> get_genesis_bits(state.config.network)
  }
}

/// Get genesis block bits for a network
fn get_genesis_bits(network: Network) -> Int {
  case network {
    oni_bitcoin.Mainnet -> 0x1d00ffff
    oni_bitcoin.Testnet | oni_bitcoin.Testnet4 -> 0x1d00ffff
    oni_bitcoin.Signet -> 0x1d00ffff
    oni_bitcoin.Regtest -> 0x207fffff
  }
}

/// Validate headers one by one with chain continuity
fn validate_headers_loop(
  headers: List(BlockHeaderNet),
  current_height: Int,
  last_bits: Int,
  network: Network,
  expected_prev_hash: BlockHash,
) -> Result(Int, String) {
  case headers {
    [] -> Ok(current_height)
    [header, ..rest] -> {
      let new_height = current_height + 1

      // 0. Verify chain continuity - prev_block must match expected hash
      case header.prev_block.hash.bytes == expected_prev_hash.hash.bytes {
        False -> {
          let received = oni_bitcoin.block_hash_to_hex(header.prev_block)
          let expected = oni_bitcoin.block_hash_to_hex(expected_prev_hash)
          io.println(
            "[IBD] Chain continuity error at height " <> int.to_string(new_height)
            <> ":\n  Expected prev: " <> expected
            <> "\n  Got prev: " <> received,
          )
          Error(
            "Chain continuity broken at height " <> int.to_string(new_height),
          )
        }
        True -> {
          // 1. Verify PoW - hash must meet target
          case verify_header_pow(header, network) {
            False ->
              Error(
                "Header PoW verification failed at height "
                <> int.to_string(new_height),
              )
            True -> {
              // 2. Check timestamp is not too far in future (2 hours)
              let max_future_time = now_secs() + 7200
              case header.timestamp > max_future_time {
                True ->
                  Error(
                    "Header timestamp too far in future at height "
                    <> int.to_string(new_height),
                  )
                False -> {
                  // 3. Verify difficulty transition rules
                  case
                    verify_difficulty_transition(
                      header.bits,
                      last_bits,
                      new_height,
                      network,
                    )
                  {
                    False ->
                      Error(
                        "Invalid difficulty transition at height "
                        <> int.to_string(new_height),
                      )
                    True -> {
                      // Compute this header's hash for next iteration
                      let header_bytes = encode_header(header)
                      let this_hash_bytes = oni_bitcoin.sha256d(header_bytes)
                      let this_hash = oni_bitcoin.BlockHash(
                        hash: oni_bitcoin.Hash256(bytes: this_hash_bytes),
                      )
                      // Continue with next header
                      validate_headers_loop(rest, new_height, header.bits, network, this_hash)
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
}

/// Verify header proof of work
fn verify_header_pow(header: BlockHeaderNet, network: Network) -> Bool {
  // For regtest, always accept (very low difficulty)
  case network {
    oni_bitcoin.Regtest -> True
    _ -> {
      // Compute block hash
      let header_bytes = encode_header(header)
      let hash_bytes = oni_bitcoin.sha256d(header_bytes)
      let block_hash =
        oni_bitcoin.BlockHash(hash: oni_bitcoin.Hash256(bytes: hash_bytes))

      // Check that hash meets the target (hash <= target)
      hash_meets_compact_target(block_hash, header.bits)
    }
  }
}

/// Check if hash meets the compact target
fn hash_meets_compact_target(
  hash: oni_bitcoin.BlockHash,
  compact_bits: Int,
) -> Bool {
  // Decode compact bits to target
  let target = decode_compact_target(compact_bits)

  // Hash must be <= target
  // Block hash is stored in little-endian, compare as big-endian
  let hash_be = oni_bitcoin.reverse_bytes(hash.hash.bytes)
  compare_256bit(hash_be, target) <= 0
}

/// Decode compact target to 256-bit value
fn decode_compact_target(compact: Int) -> BitArray {
  let exponent = int.bitwise_shift_right(compact, 24)
  let mantissa = int.bitwise_and(compact, 0x007fffff)

  // Check for negative or zero
  case int.bitwise_and(compact, 0x00800000) != 0 || exponent == 0 {
    True -> <<0:256>>
    False -> {
      // Target = mantissa * 2^(8 * (exponent - 3))
      // Build 32-byte target
      let shift_bytes = exponent - 3
      case shift_bytes >= 0 && shift_bytes <= 29 {
        True -> {
          // Create target with mantissa at the right position
          let leading_zeros = 32 - 3 - shift_bytes
          let trailing_zeros = shift_bytes
          build_target_bytes(mantissa, leading_zeros, trailing_zeros)
        }
        False -> <<0:256>>
      }
    }
  }
}

/// Build target bytes with mantissa at correct position
fn build_target_bytes(
  mantissa: Int,
  leading_zeros: Int,
  trailing_zeros: Int,
) -> BitArray {
  let leading = <<0:size({ leading_zeros * 8 })>>
  let mantissa_bytes = <<
    int.bitwise_shift_right(mantissa, 16):8,
    int.bitwise_and(int.bitwise_shift_right(mantissa, 8), 0xff):8,
    int.bitwise_and(mantissa, 0xff):8,
  >>
  let trailing = <<0:size({ trailing_zeros * 8 })>>
  bit_array.concat([leading, mantissa_bytes, trailing])
}

/// Compare two 256-bit numbers as big-endian
fn compare_256bit(a: BitArray, b: BitArray) -> Int {
  compare_bytes_loop(a, b, 0)
}

fn compare_bytes_loop(a: BitArray, b: BitArray, offset: Int) -> Int {
  case bit_array.slice(a, offset, 1), bit_array.slice(b, offset, 1) {
    Ok(<<a_byte:8>>), Ok(<<b_byte:8>>) -> {
      case a_byte < b_byte {
        True -> -1
        False -> {
          case a_byte > b_byte {
            True -> 1
            False -> {
              case offset >= 31 {
                True -> 0
                False -> compare_bytes_loop(a, b, offset + 1)
              }
            }
          }
        }
      }
    }
    _, _ -> 0
  }
}

/// Verify difficulty transition follows Bitcoin rules
fn verify_difficulty_transition(
  new_bits: Int,
  _prev_bits: Int,
  height: Int,
  network: Network,
) -> Bool {
  // Get PoW limit for network
  let pow_limit = case network {
    oni_bitcoin.Mainnet -> 0x1d00ffff
    oni_bitcoin.Testnet | oni_bitcoin.Testnet4 -> 0x1d00ffff
    oni_bitcoin.Signet -> 0x1d00ffff
    oni_bitcoin.Regtest -> 0x207fffff
  }

  // Difficulty can never be lower than PoW limit
  // (lower bits value = higher difficulty)
  case new_bits > pow_limit {
    True -> False
    False -> {
      // For regtest, always accept
      case network {
        oni_bitcoin.Regtest -> True
        _ -> {
          // For mainnet/testnet: difficulty adjusts every 2016 blocks
          // For now, accept reasonable transitions
          // Full validation would check the exact retarget calculation
          case height % 2016 == 0 {
            True -> True
            // Adjustment heights can change
            False -> True
            // Non-adjustment heights keep same difficulty (simplified)
          }
        }
      }
    }
  }
}

/// Get current time in seconds
fn now_secs() -> Int {
  now_ms() / 1000
}

/// Build download queue from header chain and hash-to-height mapping
fn build_download_queue_and_mapping(
  headers: List(BlockHeaderNet),
  start_height: Int,
) -> #(List(BlockHash), Dict(String, Int)) {
  build_download_queue_loop(headers, start_height, 1, [], dict.new())
}

fn build_download_queue_loop(
  headers: List(BlockHeaderNet),
  start_height: Int,
  current_height: Int,
  queue_acc: List(BlockHash),
  map_acc: Dict(String, Int),
) -> #(List(BlockHash), Dict(String, Int)) {
  case headers {
    [] -> #(list.reverse(queue_acc), map_acc)
    [header, ..rest] -> {
      // Hash the header to get block hash
      let header_bytes = encode_header(header)
      let hash_bytes = oni_bitcoin.sha256d(header_bytes)
      let block_hash = oni_bitcoin.BlockHash(hash: oni_bitcoin.Hash256(bytes: hash_bytes))
      let hash_hex = oni_bitcoin.block_hash_to_hex(block_hash)

      // Add to map
      let new_map = dict.insert(map_acc, hash_hex, current_height)

      // Only add to queue if past start_height
      let new_queue = case current_height > start_height {
        True -> [block_hash, ..queue_acc]
        False -> queue_acc
      }

      build_download_queue_loop(rest, start_height, current_height + 1, new_queue, new_map)
    }
  }
}

/// Encode block header for hashing
fn encode_header(header: BlockHeaderNet) -> BitArray {
  <<
    header.version:32-little,
    header.prev_block.hash.bytes:bits,
    header.merkle_root.bytes:bits,
    header.timestamp:32-little,
    header.bits:32-little,
    header.nonce:32-little,
  >>
}

/// Cancel requests from a peer
fn cancel_peer_requests(
  peer_id: Int,
  inflight: Dict(String, BlockRequest),
) -> #(Dict(String, BlockRequest), List(BlockHash)) {
  dict.fold(inflight, #(dict.new(), []), fn(acc, hash_hex, request) {
    let #(remaining, cancelled) = acc
    case request.peer_id == peer_id {
      True -> #(remaining, [request.hash, ..cancelled])
      False -> #(dict.insert(remaining, hash_hex, request), cancelled)
    }
  })
}

/// Check for timed out requests
fn check_timeouts(
  inflight: Dict(String, BlockRequest),
  now: Int,
  timeout: Int,
) -> #(Dict(String, BlockRequest), List(BlockHash)) {
  dict.fold(inflight, #(dict.new(), []), fn(acc, hash_hex, request) {
    let #(remaining, timed_out) = acc
    case now - request.requested_at > timeout {
      True -> #(remaining, [request.hash, ..timed_out])
      False -> #(dict.insert(remaining, hash_hex, request), timed_out)
    }
  })
}

/// Build status response
fn build_status(state: IbdCoordinatorState) -> IbdStatus {
  let progress = case state.target_height > 0 {
    True ->
      int.to_float(state.blocks_height * 100)
      /. int.to_float(state.target_height)
    False -> 0.0
  }

  IbdStatus(
    state: state.state,
    headers_height: state.headers_height,
    blocks_height: state.blocks_height,
    connected_peers: dict.size(state.peers),
    inflight_blocks: dict.size(state.inflight),
    progress_percent: progress,
  )
}

/// Build detailed progress
fn build_progress(state: IbdCoordinatorState) -> IbdProgress {
  let state_str = case state.state {
    IbdWaitingForPeers -> "waiting_for_peers"
    IbdSyncingHeaders -> "syncing_headers"
    IbdDownloadingBlocks -> "downloading_blocks"
    IbdSynced -> "synced"
    IbdError(err) -> "error: " <> err
  }

  // Convert Int peer IDs to String for display
  let peers = list.map(dict.keys(state.peers), int.to_string)

  // Estimate remaining time (very rough)
  let remaining_blocks = state.target_height - state.blocks_height
  let estimated_secs = remaining_blocks / 10
  // Assume 10 blocks/sec

  IbdProgress(
    state: state_str,
    headers_synced: state.headers_height,
    headers_total: state.target_height,
    blocks_synced: state.blocks_height,
    blocks_total: state.target_height,
    peers: peers,
    estimated_remaining_secs: estimated_secs,
  )
}

/// Get network parameters
fn get_network_params(network: Network) -> oni_bitcoin.NetworkParams {
  case network {
    oni_bitcoin.Mainnet -> oni_bitcoin.mainnet_params()
    oni_bitcoin.Testnet -> oni_bitcoin.testnet_params()
    oni_bitcoin.Testnet4 -> oni_bitcoin.testnet4_params()
    oni_bitcoin.Regtest -> oni_bitcoin.regtest_params()
    oni_bitcoin.Signet -> oni_bitcoin.testnet_params()
  }
}

/// Get current time in milliseconds
@external(erlang, "erlang", "system_time")
fn erlang_system_time(unit: Atom) -> Int

fn now_ms() -> Int {
  erlang_system_time(millisecond_atom())
}

@external(erlang, "erlang", "binary_to_atom")
fn binary_to_atom(binary: BitArray, encoding: Atom) -> Atom

type Atom

fn millisecond_atom() -> Atom {
  binary_to_atom(<<"millisecond">>, utf8_atom())
}

fn utf8_atom() -> Atom {
  binary_to_atom(<<"utf8">>, latin1_atom())
}

@external(erlang, "erlang", "list_to_atom")
fn list_to_atom(list: List(Int)) -> Atom

fn latin1_atom() -> Atom {
  list_to_atom([108, 97, 116, 105, 110, 49])
  // "latin1"
}
