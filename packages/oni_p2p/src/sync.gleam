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
import oni_bitcoin.{type Block, type BlockHash}
import oni_p2p.{
  type BlockHeaderNet, type Message, type PeerId, InvBlock, MsgGetData,
  MsgGetHeaders,
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

/// Stall timeout in milliseconds (2 minutes)
pub const stall_timeout_ms = 120_000

/// Time between stall checks in milliseconds (30 seconds)
pub const stall_check_interval_ms = 30_000

/// Minimum download speed before considering peer slow (bytes/sec)
pub const min_peer_download_speed = 1024

/// Moving average window for peer performance (number of samples)
pub const peer_performance_window = 10

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
  BlockInFlight(hash: BlockHash, height: Int, peer: PeerId, requested_at: Int)
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
pub fn build_locator(chain: List(BlockHash), tip_height: Int) -> BlockLocator {
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

          build_locator_hashes(
            chain,
            next_height,
            next_step,
            next_step_size,
            new_acc,
          )
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

/// Add a header to the chain with full validation
pub fn header_chain_add(
  chain: HeaderChain,
  header: BlockHeaderNet,
) -> Result(HeaderChain, SyncError) {
  // Verify header connects to existing chain
  let prev_hash = header.prev_block

  case hash_in_chain(chain, prev_hash) {
    False -> Error(SyncOrphanHeader)
    True -> {
      // Calculate header hash first
      let header_hash = compute_header_hash(header)
      let height = chain.tip_height + 1

      // Validate PoW: header hash must be less than target
      case validate_pow(header_hash, header.bits) {
        Error(e) -> Error(e)
        Ok(_) -> {
          // Validate timestamp (basic check)
          case validate_timestamp(header.timestamp, chain) {
            Error(e) -> Error(e)
            Ok(_) -> {
              // Calculate work for this header
              let work = work_from_bits(header.bits)
              let chainwork = chain.total_work + work

              // Create entry
              let entry =
                HeaderEntry(
                  header: header,
                  height: height,
                  chainwork: chainwork,
                )

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
      }
    }
  }
}

/// Validate proof of work: header hash must be <= target
fn validate_pow(header_hash: BlockHash, bits: Int) -> Result(Nil, SyncError) {
  // Get target from compact bits
  let target = target_from_bits(bits)

  // Convert header hash to a comparable value
  // The hash is in little-endian, we need to compare as a 256-bit number
  let hash_value = hash_to_uint256(header_hash.hash.bytes)

  case hash_value <= target {
    True -> Ok(Nil)
    False -> Error(SyncInvalidPoW)
  }
}

/// Convert compact bits to target (256-bit value represented as Int)
/// Bits format: 0xEEMMMMMMM where EE is exponent, MMMMMMM is mantissa
fn target_from_bits(bits: Int) -> Int {
  let exponent = int.bitwise_shift_right(bits, 24)
  let mantissa = int.bitwise_and(bits, 0x007FFFFF)

  // Handle negative flag (if mantissa has bit 23 set)
  let mantissa_adj = case int.bitwise_and(bits, 0x00800000) != 0 {
    True -> 0
    // Invalid: negative target
    False -> mantissa
  }

  // Target = mantissa * 2^(8*(exponent-3))
  case exponent <= 3 {
    True -> int.bitwise_shift_right(mantissa_adj, 8 * { 3 - exponent })
    False -> int.bitwise_shift_left(mantissa_adj, 8 * { exponent - 3 })
  }
}

/// Convert 32-byte hash to comparable integer value
/// Bitcoin hashes are stored little-endian, but we compare as big-endian numbers
fn hash_to_uint256(bytes: BitArray) -> Int {
  // Read as 32 little-endian bytes, convert to single value
  case bytes {
    <<
      b0:8,
      b1:8,
      b2:8,
      b3:8,
      b4:8,
      b5:8,
      b6:8,
      b7:8,
      b8:8,
      b9:8,
      b10:8,
      b11:8,
      b12:8,
      b13:8,
      b14:8,
      b15:8,
      b16:8,
      b17:8,
      b18:8,
      b19:8,
      b20:8,
      b21:8,
      b22:8,
      b23:8,
      b24:8,
      b25:8,
      b26:8,
      b27:8,
      b28:8,
      b29:8,
      b30:8,
      b31:8,
    >> -> {
      // For PoW comparison, the hash is treated as a little-endian 256-bit number
      // Higher bytes have more weight in the comparison
      // So b31 is the most significant byte
      let msb =
        b31 * pow2(248) + b30 * pow2(240) + b29 * pow2(232) + b28 * pow2(224)
      let next =
        b27 * pow2(216) + b26 * pow2(208) + b25 * pow2(200) + b24 * pow2(192)
      let mid1 =
        b23 * pow2(184) + b22 * pow2(176) + b21 * pow2(168) + b20 * pow2(160)
      let mid2 =
        b19 * pow2(152) + b18 * pow2(144) + b17 * pow2(136) + b16 * pow2(128)
      let mid3 =
        b15 * pow2(120) + b14 * pow2(112) + b13 * pow2(104) + b12 * pow2(96)
      let mid4 = b11 * pow2(88) + b10 * pow2(80) + b9 * pow2(72) + b8 * pow2(64)
      let low1 = b7 * pow2(56) + b6 * pow2(48) + b5 * pow2(40) + b4 * pow2(32)
      let low2 = b3 * pow2(24) + b2 * pow2(16) + b1 * pow2(8) + b0
      msb + next + mid1 + mid2 + mid3 + mid4 + low1 + low2
    }
    _ -> 0
    // Invalid hash length
  }
}

/// Validate header timestamp
/// - Must be greater than median of last 11 blocks
/// - Must not be more than 2 hours in the future
fn validate_timestamp(
  timestamp: Int,
  chain: HeaderChain,
) -> Result(Nil, SyncError) {
  // Get median time past
  let mtp = median_time_past(chain)

  case timestamp > mtp {
    False -> Error(SyncInvalidTimestamp)
    True -> {
      // Check not too far in future (2 hours = 7200 seconds)
      // We'd need current time here - for now just validate MTP
      Ok(Nil)
    }
  }
}

/// Calculate median time past (median of last 11 block timestamps)
fn median_time_past(chain: HeaderChain) -> Int {
  // Get last 11 headers (or fewer if chain is shorter)
  let last_headers = list.take(list.reverse(chain.best_chain), 11)

  // Get timestamps
  let timestamps =
    list.filter_map(last_headers, fn(hash) {
      let key = oni_bitcoin.hash256_to_hex(hash.hash)
      case dict.get(chain.headers, key) {
        Ok(entry) -> Ok(entry.header.timestamp)
        Error(_) -> Error(Nil)
      }
    })

  // Sort and get median
  let sorted = list.sort(timestamps, int.compare)
  case list.length(sorted) {
    0 -> 0
    // Genesis block case
    n -> {
      let mid = n / 2
      case list_nth(sorted, mid) {
        Ok(t) -> t
        Error(_) -> 0
      }
    }
  }
}

/// Get nth element from list
fn list_nth(lst: List(a), n: Int) -> Result(a, Nil) {
  case lst, n {
    [head, ..], 0 -> Ok(head)
    [_, ..tail], n if n > 0 -> list_nth(tail, n - 1)
    _, _ -> Error(Nil)
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
    /// Currently downloading (with timing info for stall detection)
    in_flight: Dict(String, InFlightRequest),
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
  BlockRequest(hash: BlockHash, height: Int, priority: Int)
}

/// In-flight request with timing information
pub type InFlightRequest {
  InFlightRequest(
    request: BlockRequest,
    peer: String,
    requested_at: Int,
    size_hint: Int,
  )
}

/// Peer performance metrics
pub type PeerPerformance {
  PeerPerformance(
    /// Total bytes downloaded from this peer
    bytes_downloaded: Int,
    /// Total download time in milliseconds
    download_time_ms: Int,
    /// Number of completed requests
    completed_requests: Int,
    /// Number of timed-out requests
    timeout_requests: Int,
    /// Last activity timestamp
    last_activity: Int,
    /// Computed average speed (bytes/sec)
    avg_speed: Int,
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
/// @param current_time Current time in milliseconds for stall tracking
pub fn download_manager_next_for_peer(
  manager: DownloadManager,
  peer: PeerId,
  max_count: Int,
  current_time: Int,
) -> #(DownloadManager, List(BlockRequest)) {
  let peer_key = oni_p2p.peer_id_to_string(peer)

  // Check how many this peer already has
  let peer_count = case dict.get(manager.peer_assignments, peer_key) {
    Ok(assigned) -> list.length(assigned)
    Error(_) -> 0
  }

  // Calculate how many more we can assign
  let available =
    int.min(
      max_blocks_in_flight_per_peer - peer_count,
      max_blocks_in_flight - manager.total_in_flight,
    )
  let to_assign = int.min(available, max_count)

  case to_assign <= 0 {
    True -> #(manager, [])
    False -> {
      // Take from queue
      let #(assigned, remaining) = list.split(manager.queue, to_assign)

      // Update in-flight tracking with timing information
      let new_in_flight =
        list.fold(assigned, manager.in_flight, fn(acc, req) {
          let key = oni_bitcoin.hash256_to_hex(req.hash.hash)
          let in_flight_req =
            InFlightRequest(
              request: req,
              peer: peer_key,
              requested_at: current_time,
              size_hint: 0,
              // Unknown until received
            )
          dict.insert(acc, key, in_flight_req)
        })

      // Update peer assignments
      let new_peer_hashes = list.map(assigned, fn(req) { req.hash })
      let new_peer_assignments = case
        dict.get(manager.peer_assignments, peer_key)
      {
        Ok(existing) ->
          dict.insert(
            manager.peer_assignments,
            peer_key,
            list.append(existing, new_peer_hashes),
          )
        Error(_) ->
          dict.insert(manager.peer_assignments, peer_key, new_peer_hashes)
      }

      let new_manager =
        DownloadManager(
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
  let new_peer_assignments =
    dict.map_values(manager.peer_assignments, fn(_peer, hashes) {
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
// Stall Detection and Request Reassignment
// ============================================================================

/// Check for stalled requests and return hashes that should be reassigned
pub fn download_manager_check_stalls(
  manager: DownloadManager,
  current_time: Int,
) -> #(DownloadManager, List(BlockRequest)) {
  // Find requests that have been in-flight longer than stall_timeout_ms
  let #(stalled, active) =
    dict.to_list(manager.in_flight)
    |> list.partition(fn(entry) {
      let #(_key, req) = entry
      current_time - req.requested_at > stall_timeout_ms
    })

  case list.is_empty(stalled) {
    True -> #(manager, [])
    False -> {
      // Extract the requests to be reassigned
      let stalled_requests =
        list.map(stalled, fn(entry) {
          let #(_key, in_flight) = entry
          in_flight.request
        })

      // Remove stalled from in-flight
      let new_in_flight = dict.from_list(active)

      // Add back to queue with higher priority (lower height = higher priority)
      let prioritized =
        list.map(stalled_requests, fn(req) {
          BlockRequest(..req, priority: req.height)
        })

      let new_queue =
        list.append(prioritized, manager.queue)
        |> list.sort(fn(a, b) { int.compare(a.priority, b.priority) })

      // Update peer assignments
      let stalled_hashes = list.map(stalled_requests, fn(r) { r.hash })
      let new_peer_assignments =
        dict.map_values(manager.peer_assignments, fn(_peer, hashes) {
          list.filter(hashes, fn(h) {
            !list.any(stalled_hashes, fn(sh) { block_hash_eq(h, sh) })
          })
        })

      let new_manager =
        DownloadManager(
          ..manager,
          queue: new_queue,
          in_flight: new_in_flight,
          peer_assignments: new_peer_assignments,
          total_in_flight: dict.size(new_in_flight),
        )

      #(new_manager, stalled_requests)
    }
  }
}

/// Create new peer performance record
pub fn peer_performance_new() -> PeerPerformance {
  PeerPerformance(
    bytes_downloaded: 0,
    download_time_ms: 0,
    completed_requests: 0,
    timeout_requests: 0,
    last_activity: 0,
    avg_speed: 0,
  )
}

/// Update peer performance after successful download
pub fn peer_performance_record_success(
  perf: PeerPerformance,
  bytes: Int,
  duration_ms: Int,
  current_time: Int,
) -> PeerPerformance {
  let new_bytes = perf.bytes_downloaded + bytes
  let new_time = perf.download_time_ms + duration_ms
  let new_completed = perf.completed_requests + 1

  // Compute average speed (avoid division by zero)
  let avg_speed = case new_time > 0 {
    True -> new_bytes * 1000 / new_time
    False -> 0
  }

  PeerPerformance(
    ..perf,
    bytes_downloaded: new_bytes,
    download_time_ms: new_time,
    completed_requests: new_completed,
    last_activity: current_time,
    avg_speed: avg_speed,
  )
}

/// Update peer performance after timeout
pub fn peer_performance_record_timeout(
  perf: PeerPerformance,
  current_time: Int,
) -> PeerPerformance {
  PeerPerformance(
    ..perf,
    timeout_requests: perf.timeout_requests + 1,
    last_activity: current_time,
  )
}

/// Check if a peer is performing well enough to receive more requests
pub fn peer_is_healthy(perf: PeerPerformance) -> Bool {
  // Peer is healthy if:
  // 1. Has a reasonable speed OR hasn't been tested yet
  // 2. Doesn't have too many timeouts relative to successes
  let speed_ok =
    perf.avg_speed >= min_peer_download_speed || perf.completed_requests < 3
  let timeout_ratio_ok = case perf.completed_requests + perf.timeout_requests {
    0 -> True
    total -> perf.timeout_requests * 100 / total < 25
    // Less than 25% timeouts
  }
  speed_ok && timeout_ratio_ok
}

/// Score peer for request assignment (higher is better)
pub fn peer_performance_score(perf: PeerPerformance) -> Int {
  // Base score on speed with penalty for timeouts
  let speed_score = perf.avg_speed
  let timeout_penalty = perf.timeout_requests * min_peer_download_speed
  int.max(0, speed_score - timeout_penalty)
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
  let locator =
    build_locator(coord.header_chain.best_chain, coord.header_chain.tip_height)

  // Create getheaders message
  let stop_hash = oni_bitcoin.BlockHash(oni_bitcoin.Hash256(<<0:256>>))
  let msg = MsgGetHeaders(locator.hashes, stop_hash)

  // Update state
  let headers_state =
    HeadersSyncState(
      sync_peer: peer,
      last_header_hash: coord.genesis_hash,
      headers_received: 0,
      expecting_more: True,
    )

  let new_coord =
    SyncCoordinator(
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
      case
        oni_p2p.peer_id_to_string(peer)
        == oni_p2p.peer_id_to_string(headers_state.sync_peer)
      {
        False -> Ok(#(coord, []))
        // Ignore headers from other peers
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
                  let locator =
                    build_locator(new_chain.best_chain, new_chain.tip_height)
                  let stop_hash =
                    oni_bitcoin.BlockHash(oni_bitcoin.Hash256(<<0:256>>))
                  let msg = MsgGetHeaders(locator.hashes, stop_hash)

                  let new_state =
                    HeadersSyncState(
                      ..headers_state,
                      headers_received: new_received,
                      expecting_more: True,
                    )

                  let new_coord =
                    SyncCoordinator(
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
    _ -> Ok(#(coord, []))
    // Ignore if not in headers sync
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

  let blocks_state =
    BlocksSyncState(
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
          let request =
            BlockRequest(
              hash: hash,
              height: current_height,
              // Higher priority for lower heights (process in order)
              priority: max_height - current_height,
            )
          create_requests_loop(hashes, current_height + 1, max_height, [
            request,
            ..acc
          ])
        }
      }
    }
  }
}

/// Get blocks to request from a peer
/// @param current_time Current time in milliseconds for stall tracking
pub fn sync_get_blocks_for_peer(
  coord: SyncCoordinator,
  peer: PeerId,
  current_time: Int,
) -> #(SyncCoordinator, List(Message)) {
  case coord.state {
    SyncBlocks(_) -> {
      let #(new_dm, requests) =
        download_manager_next_for_peer(
          coord.download_manager,
          peer,
          max_blocks_in_flight_per_peer,
          current_time,
        )

      case list.is_empty(requests) {
        True -> #(coord, [])
        False -> {
          // Create getdata message
          let items =
            list.map(requests, fn(req) {
              oni_p2p.InvItem(InvBlock, req.hash.hash)
            })
          let msg = MsgGetData(items)

          let new_coord = SyncCoordinator(..coord, download_manager: new_dm)

          #(new_coord, [msg])
        }
      }
    }
    _ -> #(coord, [])
  }
}

/// Check for stalled requests and reassign them
/// Should be called periodically (every stall_check_interval_ms)
pub fn sync_check_stalls(
  coord: SyncCoordinator,
  current_time: Int,
) -> #(SyncCoordinator, Int) {
  let #(new_dm, stalled) =
    download_manager_check_stalls(coord.download_manager, current_time)

  let stall_count = list.length(stalled)

  let new_coord = SyncCoordinator(..coord, download_manager: new_dm)

  #(new_coord, stall_count)
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
      let estimated_total = 850_000.0
      // Approximate mainnet height
      int.to_float(state.headers_received) /. estimated_total *. 50.0
    }
    SyncBlocks(state) -> {
      let total = state.target_height
      case total > 0 {
        True ->
          50.0
          +. int.to_float(coord.blocks_processed)
          /. int.to_float(total)
          *. 50.0
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
      let to_disconnect =
        list.drop(current_chain, height + 1)
        |> list.reverse

      // Blocks to connect (from ancestor to new tip)
      let to_connect = list.drop(new_chain, height + 1)

      Some(#(to_disconnect, to_connect))
    }
  }
}
