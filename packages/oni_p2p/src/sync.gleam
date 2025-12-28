// sync.gleam - Initial Block Download (IBD) coordinator
//
// This module implements the headers-first synchronization strategy:
// 1. Download headers using getheaders/headers messages
// 2. Validate header chain (PoW, difficulty, timestamps)
// 3. Download blocks in parallel with bounded concurrency
// 4. Connect blocks to chainstate
// 5. Handle reorgs during sync
//
// Phase 7 Implementation

import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import oni_bitcoin.{type BlockHash, type Block}
import oni_p2p.{
  type BlockHeaderNet, type Message, type PeerId,
  InvBlock, MsgGetData, MsgGetHeaders,
}

// ============================================================================
// Constants
// ============================================================================

/// Maximum headers in a single getheaders response
pub const max_headers_per_message = 2000

/// Maximum blocks to request in parallel per peer
pub const max_blocks_in_flight_per_peer = 16

/// Maximum total blocks in flight across all peers
pub const max_blocks_in_flight = 1024

/// Number of headers to get ahead before starting block download
pub const headers_download_buffer = 8000

/// Block locator exponential backoff base (2^n)
pub const locator_step_base = 2

/// Maximum block locators to include
pub const max_locators = 101

/// Download window size (how far ahead to request)
pub const download_window_size = 1024

// ============================================================================
// Sync State
// ============================================================================

/// Overall sync state
pub type SyncState {
  /// Not syncing (at tip)
  SyncIdle
  /// Downloading headers
  SyncHeaders(HeadersSyncState)
  /// Downloading blocks
  SyncBlocks(BlocksSyncState)
  /// Verification in progress
  SyncVerifying
}

/// Headers synchronization state
pub type HeadersSyncState {
  HeadersSyncState(
    /// Peer we're syncing headers from
    sync_peer: PeerId,
    /// Last header hash we've received
    last_header_hash: BlockHash,
    /// Total headers received so far
    headers_received: Int,
    /// Whether we expect more headers
    expecting_more: Bool,
  )
}

/// Block download state
pub type BlocksSyncState {
  BlocksSyncState(
    /// Next block height to request
    next_height_to_request: Int,
    /// Next block height to process
    next_height_to_process: Int,
    /// Target height (tip height)
    target_height: Int,
    /// Blocks currently being downloaded
    blocks_in_flight: Dict(BlockHash, BlockInFlight),
    /// Downloaded but not yet processed blocks
    downloaded_blocks: Dict(Int, Block),
    /// Per-peer in-flight counts
    peer_in_flight: Dict(String, Int),
  )
}

/// Information about a block being downloaded
pub type BlockInFlight {
  BlockInFlight(
    hash: BlockHash,
    height: Int,
    peer: PeerId,
    requested_at: Int,
  )
}

/// Create initial sync state
pub fn sync_state_new() -> SyncState {
  SyncIdle
}

/// Check if sync is in progress
pub fn is_syncing(state: SyncState) -> Bool {
  case state {
    SyncIdle -> False
    _ -> True
  }
}

// ============================================================================
// Block Locator
// ============================================================================

/// Block locator hashes for getheaders/getblocks
pub type BlockLocator {
  BlockLocator(hashes: List(BlockHash))
}

/// Build a block locator starting from a chain of headers
/// Uses exponential backoff: 10 most recent, then 2^n steps back
pub fn build_locator(
  chain: List(BlockHash),
  tip_height: Int,
) -> BlockLocator {
  let hashes = build_locator_hashes(chain, tip_height, 0, 1, [])
  BlockLocator(hashes: hashes)
}

fn build_locator_hashes(
  chain: List(BlockHash),
  current_height: Int,
  step: Int,
  step_size: Int,
  acc: List(BlockHash),
) -> List(BlockHash) {
  // Stop if we've collected enough or gone past genesis
  case list.length(acc) >= max_locators || current_height < 0 {
    True -> list.reverse(acc)
    False -> {
      // Get hash at current height
      case list_at(chain, current_height) {
        Error(_) -> list.reverse(acc)
        Ok(hash) -> {
          // Add to accumulator
          let new_acc = [hash, ..acc]

          // Calculate next height with exponential backoff
          let next_step = step + 1
          let next_step_size = case next_step > 10 {
            True -> step_size * locator_step_base
            False -> 1
          }
          let next_height = current_height - next_step_size

          build_locator_hashes(chain, next_height, next_step, next_step_size, new_acc)
        }
      }
    }
  }
}

/// Get element at index from list
fn list_at(lst: List(a), index: Int) -> Result(a, Nil) {
  case lst, index {
    [], _ -> Error(Nil)
    [head, ..], 0 -> Ok(head)
    [_, ..tail], n if n > 0 -> list_at(tail, n - 1)
    _, _ -> Error(Nil)
  }
}

// ============================================================================
// Header Chain
// ============================================================================

/// Header chain being synced
pub type HeaderChain {
  HeaderChain(
    /// Headers indexed by hash
    headers: Dict(String, HeaderEntry),
    /// Best chain hashes in order (genesis first)
    best_chain: List(BlockHash),
    /// Tip height
    tip_height: Int,
    /// Total work
    total_work: Int,
  )
}

/// Entry in the header chain
pub type HeaderEntry {
  HeaderEntry(
    header: BlockHeaderNet,
    height: Int,
    /// Cumulative chainwork
    chainwork: Int,
  )
}

/// Create a new header chain starting with genesis
pub fn header_chain_new(genesis_hash: BlockHash) -> HeaderChain {
  HeaderChain(
    headers: dict.new(),
    best_chain: [genesis_hash],
    tip_height: 0,
    total_work: 0,
  )
}

/// Get the tip hash
pub fn header_chain_tip(chain: HeaderChain) -> Option(BlockHash) {
  case list.last(chain.best_chain) {
    Ok(hash) -> Some(hash)
    Error(_) -> None
  }
}

/// Get the tip height
pub fn header_chain_height(chain: HeaderChain) -> Int {
  chain.tip_height
}

/// Add a header to the chain
pub fn header_chain_add(
  chain: HeaderChain,
  header: BlockHeaderNet,
) -> Result(HeaderChain, SyncError) {
  // Verify header connects to existing chain
  let prev_hash = header.prev_block

  case hash_in_chain(chain, prev_hash) {
    False -> Error(SyncOrphanHeader)
    True -> {
      // Calculate work for this header
      let work = work_from_bits(header.bits)
      let height = chain.tip_height + 1
      let chainwork = chain.total_work + work

      // Create entry
      let entry = HeaderEntry(
        header: header,
        height: height,
        chainwork: chainwork,
      )

      // Calculate new header hash
      let header_hash = compute_header_hash(header)
      let key = oni_bitcoin.hash256_to_hex(header_hash.hash)

      // Update chain
      Ok(HeaderChain(
        headers: dict.insert(chain.headers, key, entry),
        best_chain: list.append(chain.best_chain, [header_hash]),
        tip_height: height,
        total_work: chainwork,
      ))
    }
  }
}

/// Check if a hash is in the best chain
fn hash_in_chain(chain: HeaderChain, hash: BlockHash) -> Bool {
  list.any(chain.best_chain, fn(h) { block_hash_eq(h, hash) })
}

/// Compare two block hashes
fn block_hash_eq(a: BlockHash, b: BlockHash) -> Bool {
  a.hash.bytes == b.hash.bytes
}

/// Compute block header hash
fn compute_header_hash(header: BlockHeaderNet) -> BlockHash {
  let header_bytes = <<
    header.version:32-little,
    header.prev_block.hash.bytes:bits,
    header.merkle_root.bytes:bits,
    header.timestamp:32-little,
    header.bits:32-little,
    header.nonce:32-little,
  >>
  let hash = oni_bitcoin.hash256_digest(header_bytes)
  oni_bitcoin.BlockHash(hash)
}

/// Calculate work from difficulty bits
fn work_from_bits(bits: Int) -> Int {
  // Simplified work calculation
  // Work = 2^256 / (target + 1)
  // For simplicity, we use an approximation based on bits
  let exponent = bits / 0x1000000
  let mantissa = bits % 0x1000000

  case mantissa > 0 && exponent > 0 && exponent < 32 {
    True -> {
      // Approximate work as 2^(256 - 8*exponent) / mantissa
      let shift = 256 - 8 * exponent
      case shift > 0 && shift < 256 {
        True -> pow2(shift) / mantissa
        False -> 1
      }
    }
    False -> 1
  }
}

fn pow2(n: Int) -> Int {
  case n <= 0 {
    True -> 1
    False -> 2 * pow2(n - 1)
  }
}

// ============================================================================
// Sync Errors
// ============================================================================

/// Sync-related errors
pub type SyncError {
  SyncOrphanHeader
  SyncInvalidHeader(String)
  SyncInvalidPoW
  SyncInvalidTimestamp
  SyncNoBlockForHeight(Int)
  SyncPeerMisbehaved(PeerId)
  SyncTimeout
  SyncDownloadFailed(BlockHash)
  SyncValidationFailed(String)
  SyncReorgRequired(Int)
}

// ============================================================================
// Download Manager
// ============================================================================

/// Block download manager state
pub type DownloadManager {
  DownloadManager(
    /// Blocks that need to be downloaded
    queue: List(BlockRequest),
    /// Currently downloading
    in_flight: Dict(String, BlockRequest),
    /// Completed downloads
    completed: Dict(String, Block),
    /// Per-peer assignments
    peer_assignments: Dict(String, List(BlockHash)),
    /// Total in-flight count
    total_in_flight: Int,
  )
}

/// Request for a block
pub type BlockRequest {
  BlockRequest(
    hash: BlockHash,
    height: Int,
    priority: Int,
  )
}

/// Create a new download manager
pub fn download_manager_new() -> DownloadManager {
  DownloadManager(
    queue: [],
    in_flight: dict.new(),
    completed: dict.new(),
    peer_assignments: dict.new(),
    total_in_flight: 0,
  )
}

/// Add blocks to download queue
pub fn download_manager_add(
  manager: DownloadManager,
  requests: List(BlockRequest),
) -> DownloadManager {
  let new_queue = list.append(manager.queue, requests)
  DownloadManager(..manager, queue: new_queue)
}

/// Get next blocks to request from a peer
pub fn download_manager_next_for_peer(
  manager: DownloadManager,
  peer: PeerId,
  max_count: Int,
) -> #(DownloadManager, List(BlockRequest)) {
  let peer_key = oni_p2p.peer_id_to_string(peer)

  // Check how many this peer already has
  let peer_count = case dict.get(manager.peer_assignments, peer_key) {
    Ok(assigned) -> list.length(assigned)
    Error(_) -> 0
  }

  // Calculate how many more we can assign
  let available = int.min(
    max_blocks_in_flight_per_peer - peer_count,
    max_blocks_in_flight - manager.total_in_flight,
  )
  let to_assign = int.min(available, max_count)

  case to_assign <= 0 {
    True -> #(manager, [])
    False -> {
      // Take from queue
      let #(assigned, remaining) = list.split(manager.queue, to_assign)

      // Update in-flight tracking
      let new_in_flight = list.fold(assigned, manager.in_flight, fn(acc, req) {
        let key = oni_bitcoin.hash256_to_hex(req.hash.hash)
        dict.insert(acc, key, req)
      })

      // Update peer assignments
      let new_peer_hashes = list.map(assigned, fn(req) { req.hash })
      let new_peer_assignments = case dict.get(manager.peer_assignments, peer_key) {
        Ok(existing) ->
          dict.insert(manager.peer_assignments, peer_key, list.append(existing, new_peer_hashes))
        Error(_) ->
          dict.insert(manager.peer_assignments, peer_key, new_peer_hashes)
      }

      let new_manager = DownloadManager(
        ..manager,
        queue: remaining,
        in_flight: new_in_flight,
        peer_assignments: new_peer_assignments,
        total_in_flight: manager.total_in_flight + list.length(assigned),
      )

      #(new_manager, assigned)
    }
  }
}

/// Mark a block as downloaded
pub fn download_manager_complete(
  manager: DownloadManager,
  hash: BlockHash,
  block: Block,
) -> DownloadManager {
  let key = oni_bitcoin.hash256_to_hex(hash.hash)

  // Remove from in-flight
  let new_in_flight = dict.delete(manager.in_flight, key)

  // Add to completed
  let new_completed = dict.insert(manager.completed, key, block)

  // Remove from peer assignments (simplified)
  let new_peer_assignments = dict.map_values(manager.peer_assignments, fn(_peer, hashes) {
    list.filter(hashes, fn(h) { !block_hash_eq(h, hash) })
  })

  DownloadManager(
    ..manager,
    in_flight: new_in_flight,
    completed: new_completed,
    peer_assignments: new_peer_assignments,
    total_in_flight: int.max(0, manager.total_in_flight - 1),
  )
}

/// Check if download is complete
pub fn download_manager_is_complete(manager: DownloadManager) -> Bool {
  list.is_empty(manager.queue) && dict.size(manager.in_flight) == 0
}

/// Get count of pending downloads
pub fn download_manager_pending_count(manager: DownloadManager) -> Int {
  list.length(manager.queue) + dict.size(manager.in_flight)
}

// ============================================================================
// Sync Coordinator
// ============================================================================

/// Sync coordinator manages the overall sync process
pub type SyncCoordinator {
  SyncCoordinator(
    state: SyncState,
    header_chain: HeaderChain,
    download_manager: DownloadManager,
    genesis_hash: BlockHash,
    best_known_tip: Option(BlockHash),
    sync_start_time: Int,
    blocks_processed: Int,
    bytes_downloaded: Int,
  )
}

/// Create a new sync coordinator
pub fn sync_coordinator_new(genesis_hash: BlockHash) -> SyncCoordinator {
  SyncCoordinator(
    state: SyncIdle,
    header_chain: header_chain_new(genesis_hash),
    download_manager: download_manager_new(),
    genesis_hash: genesis_hash,
    best_known_tip: None,
    sync_start_time: 0,
    blocks_processed: 0,
    bytes_downloaded: 0,
  )
}

/// Start header sync with a peer
pub fn sync_start_headers(
  coord: SyncCoordinator,
  peer: PeerId,
  timestamp: Int,
) -> #(SyncCoordinator, List(Message)) {
  // Build locator from current chain
  let locator = build_locator(coord.header_chain.best_chain, coord.header_chain.tip_height)

  // Create getheaders message
  let stop_hash = oni_bitcoin.BlockHash(oni_bitcoin.Hash256(<<0:256>>))
  let msg = MsgGetHeaders(locator.hashes, stop_hash)

  // Update state
  let headers_state = HeadersSyncState(
    sync_peer: peer,
    last_header_hash: coord.genesis_hash,
    headers_received: 0,
    expecting_more: True,
  )

  let new_coord = SyncCoordinator(
    ..coord,
    state: SyncHeaders(headers_state),
    sync_start_time: timestamp,
  )

  #(new_coord, [msg])
}

/// Handle received headers
pub fn sync_on_headers(
  coord: SyncCoordinator,
  peer: PeerId,
  headers: List(BlockHeaderNet),
) -> Result(#(SyncCoordinator, List(Message)), SyncError) {
  case coord.state {
    SyncHeaders(headers_state) -> {
      // Verify this is from our sync peer
      case oni_p2p.peer_id_to_string(peer) == oni_p2p.peer_id_to_string(headers_state.sync_peer) {
        False -> Ok(#(coord, []))  // Ignore headers from other peers
        True -> {
          // Add headers to chain
          case add_headers_to_chain(coord.header_chain, headers) {
            Error(e) -> Error(e)
            Ok(new_chain) -> {
              let headers_count = list.length(headers)
              let new_received = headers_state.headers_received + headers_count

              // Check if we got a full batch (more headers expected)
              let expecting_more = headers_count == max_headers_per_message

              case expecting_more {
                True -> {
                  // Request more headers
                  let locator = build_locator(new_chain.best_chain, new_chain.tip_height)
                  let stop_hash = oni_bitcoin.BlockHash(oni_bitcoin.Hash256(<<0:256>>))
                  let msg = MsgGetHeaders(locator.hashes, stop_hash)

                  let new_state = HeadersSyncState(
                    ..headers_state,
                    headers_received: new_received,
                    expecting_more: True,
                  )

                  let new_coord = SyncCoordinator(
                    ..coord,
                    state: SyncHeaders(new_state),
                    header_chain: new_chain,
                  )

                  Ok(#(new_coord, [msg]))
                }
                False -> {
                  // Headers sync complete, start block download
                  let new_coord = start_block_download(coord, new_chain)
                  Ok(#(new_coord, []))
                }
              }
            }
          }
        }
      }
    }
    _ -> Ok(#(coord, []))  // Ignore if not in headers sync
  }
}

/// Add multiple headers to chain
fn add_headers_to_chain(
  chain: HeaderChain,
  headers: List(BlockHeaderNet),
) -> Result(HeaderChain, SyncError) {
  case headers {
    [] -> Ok(chain)
    [header, ..rest] -> {
      case header_chain_add(chain, header) {
        Error(e) -> Error(e)
        Ok(new_chain) -> add_headers_to_chain(new_chain, rest)
      }
    }
  }
}

/// Start block download phase
fn start_block_download(
  coord: SyncCoordinator,
  header_chain: HeaderChain,
) -> SyncCoordinator {
  // Create block requests for all blocks
  let requests = create_block_requests(header_chain, 0)
  let download_manager = download_manager_add(coord.download_manager, requests)

  let blocks_state = BlocksSyncState(
    next_height_to_request: 0,
    next_height_to_process: 0,
    target_height: header_chain.tip_height,
    blocks_in_flight: dict.new(),
    downloaded_blocks: dict.new(),
    peer_in_flight: dict.new(),
  )

  SyncCoordinator(
    ..coord,
    state: SyncBlocks(blocks_state),
    header_chain: header_chain,
    download_manager: download_manager,
  )
}

/// Create block requests from header chain
fn create_block_requests(
  chain: HeaderChain,
  start_height: Int,
) -> List(BlockRequest) {
  create_requests_loop(chain.best_chain, start_height, chain.tip_height, [])
}

fn create_requests_loop(
  hashes: List(BlockHash),
  current_height: Int,
  max_height: Int,
  acc: List(BlockRequest),
) -> List(BlockRequest) {
  case current_height > max_height {
    True -> list.reverse(acc)
    False -> {
      case list_at(hashes, current_height) {
        Error(_) -> list.reverse(acc)
        Ok(hash) -> {
          let request = BlockRequest(
            hash: hash,
            height: current_height,
            // Higher priority for lower heights (process in order)
            priority: max_height - current_height,
          )
          create_requests_loop(hashes, current_height + 1, max_height, [request, ..acc])
        }
      }
    }
  }
}

/// Get blocks to request from a peer
pub fn sync_get_blocks_for_peer(
  coord: SyncCoordinator,
  peer: PeerId,
) -> #(SyncCoordinator, List(Message)) {
  case coord.state {
    SyncBlocks(_) -> {
      let #(new_dm, requests) = download_manager_next_for_peer(
        coord.download_manager,
        peer,
        max_blocks_in_flight_per_peer,
      )

      case list.is_empty(requests) {
        True -> #(coord, [])
        False -> {
          // Create getdata message
          let items = list.map(requests, fn(req) {
            oni_p2p.InvItem(InvBlock, req.hash.hash)
          })
          let msg = MsgGetData(items)

          let new_coord = SyncCoordinator(
            ..coord,
            download_manager: new_dm,
          )

          #(new_coord, [msg])
        }
      }
    }
    _ -> #(coord, [])
  }
}

/// Handle received block
pub fn sync_on_block(
  coord: SyncCoordinator,
  hash: BlockHash,
  block: Block,
) -> SyncCoordinator {
  let new_dm = download_manager_complete(coord.download_manager, hash, block)
  let new_blocks = coord.blocks_processed + 1

  SyncCoordinator(
    ..coord,
    download_manager: new_dm,
    blocks_processed: new_blocks,
  )
}

/// Check if sync is complete
pub fn sync_is_complete(coord: SyncCoordinator) -> Bool {
  case coord.state {
    SyncBlocks(_) -> download_manager_is_complete(coord.download_manager)
    _ -> False
  }
}

/// Get sync progress as percentage
pub fn sync_progress(coord: SyncCoordinator) -> Float {
  case coord.state {
    SyncHeaders(state) -> {
      // Estimate based on headers received
      let estimated_total = 850_000.0  // Approximate mainnet height
      int.to_float(state.headers_received) /. estimated_total *. 50.0
    }
    SyncBlocks(state) -> {
      let total = state.target_height
      case total > 0 {
        True -> 50.0 +. int.to_float(coord.blocks_processed) /. int.to_float(total) *. 50.0
        False -> 50.0
      }
    }
    _ -> 0.0
  }
}

/// Get sync statistics
pub type SyncStats {
  SyncStats(
    state: String,
    header_height: Int,
    blocks_processed: Int,
    blocks_pending: Int,
    bytes_downloaded: Int,
    sync_duration_ms: Int,
  )
}

pub fn sync_get_stats(coord: SyncCoordinator, current_time: Int) -> SyncStats {
  let state_str = case coord.state {
    SyncIdle -> "idle"
    SyncHeaders(_) -> "headers"
    SyncBlocks(_) -> "blocks"
    SyncVerifying -> "verifying"
  }

  SyncStats(
    state: state_str,
    header_height: coord.header_chain.tip_height,
    blocks_processed: coord.blocks_processed,
    blocks_pending: download_manager_pending_count(coord.download_manager),
    bytes_downloaded: coord.bytes_downloaded,
    sync_duration_ms: current_time - coord.sync_start_time,
  )
}

// ============================================================================
// Reorg Handling
// ============================================================================

/// Find the common ancestor between two chains
pub fn find_common_ancestor(
  chain1: List(BlockHash),
  chain2: List(BlockHash),
) -> Option(#(BlockHash, Int)) {
  find_ancestor_loop(chain1, chain2, 0)
}

fn find_ancestor_loop(
  chain1: List(BlockHash),
  chain2: List(BlockHash),
  height: Int,
) -> Option(#(BlockHash, Int)) {
  case chain1, chain2 {
    [h1, ..rest1], [h2, ..rest2] -> {
      case block_hash_eq(h1, h2) {
        True -> {
          // Found common ancestor, continue to find deepest
          case find_ancestor_loop(rest1, rest2, height + 1) {
            Some(deeper) -> Some(deeper)
            None -> Some(#(h1, height))
          }
        }
        False -> None
      }
    }
    _, _ -> None
  }
}

/// Calculate blocks to disconnect and connect for a reorg
pub fn calculate_reorg(
  current_chain: List(BlockHash),
  new_chain: List(BlockHash),
) -> Option(#(List(BlockHash), List(BlockHash))) {
  case find_common_ancestor(current_chain, new_chain) {
    None -> None
    Some(#(_ancestor, height)) -> {
      // Blocks to disconnect (from current tip back to ancestor)
      let to_disconnect = list.drop(current_chain, height + 1)
        |> list.reverse

      // Blocks to connect (from ancestor to new tip)
      let to_connect = list.drop(new_chain, height + 1)

      Some(#(to_disconnect, to_connect))
    }
  }
}
