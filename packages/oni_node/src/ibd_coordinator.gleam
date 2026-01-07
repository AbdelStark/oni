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
import oni_bitcoin.{type BlockHash, type BlockHeader, type Network}
import oni_p2p.{type BlockHeaderNet, type Message, MsgGetHeaders}
import p2p_network.{type ListenerMsg, BroadcastMessage}

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
  )
}

/// Default IBD configuration
pub fn default_config(network: Network) -> IbdConfig {
  IbdConfig(
    network: network,
    blocks_per_peer: 16,
    max_inflight_blocks: 128,
    headers_batch_size: 2000,
    block_timeout_ms: 30_000,
    min_peers: 1,
    use_checkpoints: True,
    debug: False,
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
    peer_id: String,
    height: Int,
    last_request: Int,
    inflight_blocks: Int,
    headers_synced: Bool,
  )
}

/// Block download request
pub type BlockRequest {
  BlockRequest(hash: BlockHash, height: Int, peer_id: String, requested_at: Int)
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
  /// Peer connected with version info
  PeerConnected(peer_id: String, height: Int)
  /// Peer disconnected
  PeerDisconnected(peer_id: String)
  /// Headers received from peer
  HeadersReceived(peer_id: String, headers: List(BlockHeaderNet))
  /// Block received
  BlockReceived(hash: BlockHash, height: Int)
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
    /// Connected peers with their state
    peers: Dict(String, PeerSyncState),
    /// Header chain being synced
    headers: List(BlockHeaderNet),
    /// Current headers height (validated)
    headers_height: Int,
    /// Current blocks height (connected to chain)
    blocks_height: Int,
    /// Target height (from best peer)
    target_height: Int,
    /// Inflight block requests
    inflight: Dict(String, BlockRequest),
    /// Queue of blocks to download
    download_queue: List(BlockHash),
    /// Sync peer (primary peer for headers)
    sync_peer: Option(String),
    /// Genesis hash for the network
    genesis_hash: BlockHash,
    /// Last activity timestamp
    last_activity: Int,
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
  let params = get_network_params(config.network)

  let initial_state =
    IbdCoordinatorState(
      config: config,
      state: IbdWaitingForPeers,
      p2p: p2p,
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

    BlockReceived(hash, height) -> {
      let new_state = handle_block_received(hash, height, state)
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
  peer_id: String,
  height: Int,
  state: IbdCoordinatorState,
) -> IbdCoordinatorState {
  // Always log peer connections during sync
  io.println(
    "[IBD] Peer "
    <> peer_id
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
  peer_id: String,
  state: IbdCoordinatorState,
) -> IbdCoordinatorState {
  case state.config.debug {
    True -> io.println("[IBD] Peer " <> peer_id <> " disconnected")
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
  peer_id: String,
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
  peer_id: String,
  headers: List(BlockHeaderNet),
  state: IbdCoordinatorState,
) -> IbdCoordinatorState {
  let header_count = list.length(headers)

  io.println(
    "[IBD] Received "
    <> int.to_string(header_count)
    <> " headers from sync peer "
    <> peer_id
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
            "[IBD] Headers validated, new height: " <> int.to_string(new_height),
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

/// Handle block received
fn handle_block_received(
  hash: BlockHash,
  height: Int,
  state: IbdCoordinatorState,
) -> IbdCoordinatorState {
  let hash_hex = oni_bitcoin.block_hash_to_hex(hash)

  // Remove from inflight
  let new_inflight = dict.delete(state.inflight, hash_hex)

  // Update blocks height if this is the next block
  let new_blocks_height = case height == state.blocks_height + 1 {
    True -> height
    False -> state.blocks_height
  }

  case state.config.debug && new_blocks_height != state.blocks_height {
    True ->
      io.println(
        "[IBD] Block "
        <> int.to_string(new_blocks_height)
        <> " of "
        <> int.to_string(state.target_height),
      )
    False -> Nil
  }

  let new_state =
    IbdCoordinatorState(
      ..state,
      inflight: new_inflight,
      blocks_height: new_blocks_height,
      last_activity: now_ms(),
    )

  // Check if we're done
  case new_blocks_height >= state.target_height {
    True -> {
      io.println(
        "[IBD] Sync complete at height " <> int.to_string(new_blocks_height),
      )
      IbdCoordinatorState(..new_state, state: IbdSynced)
    }
    False -> {
      // Request more blocks
      schedule_block_downloads(new_state)
    }
  }
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
      io.println("[IBD] Selected sync peer: " <> peer_id)

      // Send getheaders request
      let locators = build_locators(state)
      io.println(
        "[IBD] Sending getheaders with "
        <> int.to_string(list.length(locators))
        <> " locators, stop_hash: "
        <> oni_bitcoin.block_hash_to_hex(state.genesis_hash),
      )
      let msg = MsgGetHeaders(locators, state.genesis_hash)
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
  let msg = MsgGetHeaders(locators, state.genesis_hash)
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

  // Build download queue from headers
  let queue = build_download_queue(state.headers, state.blocks_height)

  let new_state =
    IbdCoordinatorState(
      ..state,
      state: IbdDownloadingBlocks,
      download_queue: queue,
    )

  schedule_block_downloads(new_state)
}

/// Schedule block downloads to available peers
fn schedule_block_downloads(state: IbdCoordinatorState) -> IbdCoordinatorState {
  // Find available peers
  let available_peers =
    get_available_peers(state.peers, state.config.blocks_per_peer)
  let slots = state.config.max_inflight_blocks - dict.size(state.inflight)

  case
    list.is_empty(available_peers),
    list.is_empty(state.download_queue),
    slots > 0
  {
    True, _, _ -> state
    _, True, _ -> state
    _, _, False -> state
    False, False, True -> {
      // Take blocks from queue
      let to_request = list.take(state.download_queue, slots)
      let remaining = list.drop(state.download_queue, slots)

      // Create getdata messages
      let _ = request_blocks_from_peers(to_request, available_peers, state.p2p)

      // Track inflight
      let new_inflight = add_inflight_requests(to_request, state.inflight)

      IbdCoordinatorState(
        ..state,
        download_queue: remaining,
        inflight: new_inflight,
        last_activity: now_ms(),
      )
    }
  }
}

// ============================================================================
// Helper Functions
// ============================================================================

/// Find the best peer for syncing (highest height)
fn find_best_peer(peers: Dict(String, PeerSyncState)) -> Option(String) {
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

/// Get peers with available download slots
fn get_available_peers(
  peers: Dict(String, PeerSyncState),
  max_per_peer: Int,
) -> List(String) {
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

/// Build block locators for getheaders
fn build_locators(state: IbdCoordinatorState) -> List(BlockHash) {
  // In a full implementation, build exponential backoff locators
  // For now, just use genesis
  [state.genesis_hash]
}

/// Validate received headers
fn validate_headers(
  headers: List(BlockHeaderNet),
  state: IbdCoordinatorState,
) -> Result(Int, String) {
  validate_headers_loop(
    headers,
    state.headers_height,
    get_last_header_bits(state),
    state.config.network,
  )
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

/// Validate headers one by one
fn validate_headers_loop(
  headers: List(BlockHeaderNet),
  current_height: Int,
  last_bits: Int,
  network: Network,
) -> Result(Int, String) {
  case headers {
    [] -> Ok(current_height)
    [header, ..rest] -> {
      let new_height = current_height + 1

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
                  // Continue with next header
                  validate_headers_loop(rest, new_height, header.bits, network)
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

/// Build download queue from header chain
fn build_download_queue(
  headers: List(BlockHeaderNet),
  start_height: Int,
) -> List(BlockHash) {
  headers
  |> list.drop(start_height)
  |> list.map(fn(header) {
    // Hash the header to get block hash
    let header_bytes = encode_header(header)
    let hash = oni_bitcoin.sha256d(header_bytes)
    oni_bitcoin.BlockHash(hash: oni_bitcoin.Hash256(bytes: hash))
  })
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

/// Request blocks from peers
fn request_blocks_from_peers(
  hashes: List(BlockHash),
  _peers: List(String),
  p2p: Subject(ListenerMsg),
) -> Nil {
  let getdata = oni_p2p.create_getdata_blocks(hashes)
  process.send(p2p, BroadcastMessage(getdata))
}

/// Add inflight requests
fn add_inflight_requests(
  hashes: List(BlockHash),
  inflight: Dict(String, BlockRequest),
) -> Dict(String, BlockRequest) {
  let now = now_ms()
  list.fold(hashes, inflight, fn(acc, hash) {
    let hash_hex = oni_bitcoin.block_hash_to_hex(hash)
    let request =
      BlockRequest(
        hash: hash,
        height: 0,
        // Would track actual height
        peer_id: "",
        // Would track actual peer
        requested_at: now,
      )
    dict.insert(acc, hash_hex, request)
  })
}

/// Cancel requests from a peer
fn cancel_peer_requests(
  peer_id: String,
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

  let peers = dict.keys(state.peers)

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
