// ban_manager.gleam - Peer misbehavior scoring and ban management
//
// This module implements a peer scoring and ban system to protect against:
// - Peers sending invalid data (bad blocks, malformed messages)
// - DoS attempts (too many messages, invalid requests)
// - Protocol violations (wrong versions, unexpected messages)
//
// The system tracks misbehavior scores and bans peers that exceed thresholds.

import gleam/dict.{type Dict}
import gleam/int
import gleam/list

// ============================================================================
// Constants
// ============================================================================

/// Misbehavior score that triggers a ban
pub const ban_threshold = 100

/// Default ban duration in seconds (24 hours)
pub const default_ban_duration = 86_400

/// Score decay rate per second
pub const score_decay_rate = 1

/// Maximum score before capping
pub const max_score = 200

// ============================================================================
// Misbehavior Categories and Penalties
// ============================================================================

/// Types of misbehavior with associated penalties
pub type Misbehavior {
  /// Invalid block header
  InvalidBlockHeader
  /// Invalid block (fails validation)
  InvalidBlock
  /// Invalid transaction
  InvalidTransaction
  /// Malformed message (parse error)
  MalformedMessage
  /// Unexpected message type
  UnexpectedMessage
  /// Protocol version mismatch
  VersionMismatch
  /// Too many inventory items
  TooManyInventory
  /// Sending unrequested data
  UnrequestedData
  /// Headers chain doesn't connect
  DisconnectedHeaders
  /// Invalid proof of work
  InvalidPoW
  /// Invalid merkle root
  InvalidMerkleRoot
  /// Invalid signature
  InvalidSignature
  /// Double-spend attempt
  DoubleSpend
  /// Excessive message rate
  MessageRateExceeded
  /// Duplicate messages
  DuplicateMessage
  /// Invalid address
  InvalidAddress
  /// Ping/pong mismatch
  PingPongMismatch
  /// Stale block announcement
  StaleBlock
  /// Other misbehavior with custom penalty
  Other(Int)
}

/// Get the penalty score for a misbehavior type
pub fn misbehavior_penalty(misbehavior: Misbehavior) -> Int {
  case misbehavior {
    InvalidBlockHeader -> 100  // Immediate ban
    InvalidBlock -> 100  // Immediate ban
    InvalidTransaction -> 10
    MalformedMessage -> 20
    UnexpectedMessage -> 10
    VersionMismatch -> 100  // Immediate ban
    TooManyInventory -> 20
    UnrequestedData -> 5
    DisconnectedHeaders -> 20
    InvalidPoW -> 100  // Immediate ban
    InvalidMerkleRoot -> 100  // Immediate ban
    InvalidSignature -> 100  // Immediate ban
    DoubleSpend -> 100  // Immediate ban
    MessageRateExceeded -> 25
    DuplicateMessage -> 1
    InvalidAddress -> 5
    PingPongMismatch -> 10
    StaleBlock -> 5
    Other(penalty) -> penalty
  }
}

/// Check if a misbehavior should result in immediate disconnect
pub fn is_immediate_disconnect(misbehavior: Misbehavior) -> Bool {
  case misbehavior {
    InvalidBlockHeader -> True
    InvalidBlock -> True
    VersionMismatch -> True
    InvalidPoW -> True
    InvalidMerkleRoot -> True
    InvalidSignature -> True
    DoubleSpend -> True
    _ -> False
  }
}

// ============================================================================
// Peer Score Entry
// ============================================================================

/// Score entry for a peer
pub type PeerScore {
  PeerScore(
    /// Current misbehavior score
    score: Int,
    /// Last update timestamp (unix seconds)
    last_update: Int,
    /// Number of misbehavior incidents
    incident_count: Int,
    /// Recent misbehavior types
    recent_incidents: List(Misbehavior),
  )
}

/// Create a new peer score entry
pub fn peer_score_new() -> PeerScore {
  PeerScore(
    score: 0,
    last_update: 0,
    incident_count: 0,
    recent_incidents: [],
  )
}

/// Add misbehavior to a peer's score
pub fn peer_score_add(
  score: PeerScore,
  misbehavior: Misbehavior,
  current_time: Int,
) -> PeerScore {
  // Apply decay first
  let decayed = apply_score_decay(score, current_time)

  // Add new penalty
  let penalty = misbehavior_penalty(misbehavior)
  let new_score = int.min(decayed.score + penalty, max_score)

  // Keep track of recent incidents (last 10)
  let new_incidents = case list.length(decayed.recent_incidents) >= 10 {
    True -> [misbehavior, ..list.take(decayed.recent_incidents, 9)]
    False -> [misbehavior, ..decayed.recent_incidents]
  }

  PeerScore(
    score: new_score,
    last_update: current_time,
    incident_count: decayed.incident_count + 1,
    recent_incidents: new_incidents,
  )
}

/// Apply decay to a peer's score based on elapsed time
fn apply_score_decay(score: PeerScore, current_time: Int) -> PeerScore {
  case score.last_update {
    0 -> PeerScore(..score, last_update: current_time)
    last -> {
      let elapsed = current_time - last
      let decay = elapsed * score_decay_rate
      let new_score = int.max(0, score.score - decay)
      PeerScore(..score, score: new_score, last_update: current_time)
    }
  }
}

/// Check if peer should be banned
pub fn peer_score_should_ban(score: PeerScore) -> Bool {
  score.score >= ban_threshold
}

/// Get the current score (with decay applied)
pub fn peer_score_current(score: PeerScore, current_time: Int) -> Int {
  let decayed = apply_score_decay(score, current_time)
  decayed.score
}

// ============================================================================
// Ban Entry
// ============================================================================

/// A ban entry for a peer or IP
pub type BanEntry {
  BanEntry(
    /// Ban reason
    reason: BanReason,
    /// Ban start time (unix seconds)
    ban_time: Int,
    /// Ban duration in seconds
    duration: Int,
    /// Whether the ban was manually applied
    manual: Bool,
  )
}

/// Reason for a ban
pub type BanReason {
  /// Automatic ban due to misbehavior score
  AutoBan(final_score: Int, last_misbehavior: Misbehavior)
  /// Manual ban by operator
  ManualBan(description: String)
  /// Ban imported from a list
  ImportedBan
}

/// Create a new automatic ban entry
pub fn ban_entry_auto(
  score: PeerScore,
  misbehavior: Misbehavior,
  current_time: Int,
) -> BanEntry {
  BanEntry(
    reason: AutoBan(score.score, misbehavior),
    ban_time: current_time,
    duration: default_ban_duration,
    manual: False,
  )
}

/// Create a new manual ban entry
pub fn ban_entry_manual(
  description: String,
  current_time: Int,
  duration: Int,
) -> BanEntry {
  BanEntry(
    reason: ManualBan(description),
    ban_time: current_time,
    duration: duration,
    manual: True,
  )
}

/// Check if a ban has expired
pub fn ban_entry_expired(entry: BanEntry, current_time: Int) -> Bool {
  current_time >= entry.ban_time + entry.duration
}

/// Get remaining ban duration
pub fn ban_entry_remaining(entry: BanEntry, current_time: Int) -> Int {
  let expiry = entry.ban_time + entry.duration
  int.max(0, expiry - current_time)
}

// ============================================================================
// Ban Manager
// ============================================================================

/// The ban manager tracks scores and bans for all peers
pub type BanManager {
  BanManager(
    /// Misbehavior scores by peer ID
    scores: Dict(String, PeerScore),
    /// Active bans by peer ID
    peer_bans: Dict(String, BanEntry),
    /// Active bans by IP address
    ip_bans: Dict(String, BanEntry),
    /// Subnet bans (CIDR notation)
    subnet_bans: Dict(String, BanEntry),
    /// Statistics
    stats: BanStats,
  )
}

/// Ban manager statistics
pub type BanStats {
  BanStats(
    /// Total misbehavior incidents recorded
    total_incidents: Int,
    /// Total automatic bans issued
    auto_bans: Int,
    /// Total manual bans issued
    manual_bans: Int,
    /// Currently active bans
    active_bans: Int,
    /// Expired bans (cleaned up)
    expired_bans: Int,
  )
}

/// Create a new ban manager
pub fn ban_manager_new() -> BanManager {
  BanManager(
    scores: dict.new(),
    peer_bans: dict.new(),
    ip_bans: dict.new(),
    subnet_bans: dict.new(),
    stats: BanStats(
      total_incidents: 0,
      auto_bans: 0,
      manual_bans: 0,
      active_bans: 0,
      expired_bans: 0,
    ),
  )
}

/// Record misbehavior for a peer
pub fn record_misbehavior(
  manager: BanManager,
  peer_id: String,
  misbehavior: Misbehavior,
  current_time: Int,
) -> #(BanManager, BanAction) {
  // Get or create peer score
  let current_score = case dict.get(manager.scores, peer_id) {
    Ok(score) -> score
    Error(_) -> peer_score_new()
  }

  // Add misbehavior
  let new_score = peer_score_add(current_score, misbehavior, current_time)

  // Update scores
  let new_scores = dict.insert(manager.scores, peer_id, new_score)

  // Update stats
  let new_stats = BanStats(
    ..manager.stats,
    total_incidents: manager.stats.total_incidents + 1,
  )

  // Check if should ban
  case peer_score_should_ban(new_score) {
    False -> {
      // Check for immediate disconnect
      case is_immediate_disconnect(misbehavior) {
        True -> #(
          BanManager(..manager, scores: new_scores, stats: new_stats),
          Disconnect,
        )
        False -> #(
          BanManager(..manager, scores: new_scores, stats: new_stats),
          NoAction,
        )
      }
    }
    True -> {
      // Create ban entry
      let ban_entry = ban_entry_auto(new_score, misbehavior, current_time)
      let new_peer_bans = dict.insert(manager.peer_bans, peer_id, ban_entry)

      let final_stats = BanStats(
        ..new_stats,
        auto_bans: new_stats.auto_bans + 1,
        active_bans: new_stats.active_bans + 1,
      )

      #(
        BanManager(
          ..manager,
          scores: new_scores,
          peer_bans: new_peer_bans,
          stats: final_stats,
        ),
        Ban(ban_entry),
      )
    }
  }
}

/// Action to take after recording misbehavior
pub type BanAction {
  /// No action needed
  NoAction
  /// Disconnect the peer but don't ban
  Disconnect
  /// Ban the peer
  Ban(BanEntry)
}

/// Check if a peer is banned
pub fn is_peer_banned(
  manager: BanManager,
  peer_id: String,
  current_time: Int,
) -> Bool {
  case dict.get(manager.peer_bans, peer_id) {
    Error(_) -> False
    Ok(entry) -> !ban_entry_expired(entry, current_time)
  }
}

/// Check if an IP is banned
pub fn is_ip_banned(
  manager: BanManager,
  ip: String,
  current_time: Int,
) -> Bool {
  case dict.get(manager.ip_bans, ip) {
    Error(_) -> check_subnet_bans(manager, ip, current_time)
    Ok(entry) -> !ban_entry_expired(entry, current_time)
  }
}

/// Check subnet bans (simplified - exact match only for now)
fn check_subnet_bans(
  manager: BanManager,
  _ip: String,
  _current_time: Int,
) -> Bool {
  // In a full implementation, this would check CIDR ranges
  dict.size(manager.subnet_bans) > 0
}

/// Manually ban a peer
pub fn ban_peer(
  manager: BanManager,
  peer_id: String,
  description: String,
  current_time: Int,
  duration: Int,
) -> BanManager {
  let entry = ban_entry_manual(description, current_time, duration)
  let new_bans = dict.insert(manager.peer_bans, peer_id, entry)
  let new_stats = BanStats(
    ..manager.stats,
    manual_bans: manager.stats.manual_bans + 1,
    active_bans: manager.stats.active_bans + 1,
  )

  BanManager(..manager, peer_bans: new_bans, stats: new_stats)
}

/// Manually ban an IP
pub fn ban_ip(
  manager: BanManager,
  ip: String,
  description: String,
  current_time: Int,
  duration: Int,
) -> BanManager {
  let entry = ban_entry_manual(description, current_time, duration)
  let new_bans = dict.insert(manager.ip_bans, ip, entry)
  let new_stats = BanStats(
    ..manager.stats,
    manual_bans: manager.stats.manual_bans + 1,
    active_bans: manager.stats.active_bans + 1,
  )

  BanManager(..manager, ip_bans: new_bans, stats: new_stats)
}

/// Unban a peer
pub fn unban_peer(manager: BanManager, peer_id: String) -> BanManager {
  case dict.has_key(manager.peer_bans, peer_id) {
    False -> manager
    True -> {
      let new_bans = dict.delete(manager.peer_bans, peer_id)
      let new_stats = BanStats(
        ..manager.stats,
        active_bans: int.max(0, manager.stats.active_bans - 1),
      )
      BanManager(..manager, peer_bans: new_bans, stats: new_stats)
    }
  }
}

/// Unban an IP
pub fn unban_ip(manager: BanManager, ip: String) -> BanManager {
  case dict.has_key(manager.ip_bans, ip) {
    False -> manager
    True -> {
      let new_bans = dict.delete(manager.ip_bans, ip)
      let new_stats = BanStats(
        ..manager.stats,
        active_bans: int.max(0, manager.stats.active_bans - 1),
      )
      BanManager(..manager, ip_bans: new_bans, stats: new_stats)
    }
  }
}

/// Clean up expired bans
pub fn cleanup_expired_bans(
  manager: BanManager,
  current_time: Int,
) -> BanManager {
  // Clean peer bans
  let #(active_peer_bans, expired_peer_count) =
    cleanup_ban_dict(manager.peer_bans, current_time)

  // Clean IP bans
  let #(active_ip_bans, expired_ip_count) =
    cleanup_ban_dict(manager.ip_bans, current_time)

  // Clean subnet bans
  let #(active_subnet_bans, expired_subnet_count) =
    cleanup_ban_dict(manager.subnet_bans, current_time)

  let total_expired = expired_peer_count + expired_ip_count + expired_subnet_count

  let new_stats = BanStats(
    ..manager.stats,
    active_bans: manager.stats.active_bans - total_expired,
    expired_bans: manager.stats.expired_bans + total_expired,
  )

  BanManager(
    ..manager,
    peer_bans: active_peer_bans,
    ip_bans: active_ip_bans,
    subnet_bans: active_subnet_bans,
    stats: new_stats,
  )
}

fn cleanup_ban_dict(
  bans: Dict(String, BanEntry),
  current_time: Int,
) -> #(Dict(String, BanEntry), Int) {
  dict.fold(bans, #(dict.new(), 0), fn(acc, key, entry) {
    let #(active, count) = acc
    case ban_entry_expired(entry, current_time) {
      True -> #(active, count + 1)
      False -> #(dict.insert(active, key, entry), count)
    }
  })
}

/// Get peer score
pub fn get_peer_score(
  manager: BanManager,
  peer_id: String,
  current_time: Int,
) -> Int {
  case dict.get(manager.scores, peer_id) {
    Error(_) -> 0
    Ok(score) -> peer_score_current(score, current_time)
  }
}

/// Get all active bans
pub fn get_active_bans(
  manager: BanManager,
  current_time: Int,
) -> List(#(String, BanEntry)) {
  let peer_bans = dict.to_list(manager.peer_bans)
    |> list.filter(fn(pair) {
      let #(_key, entry) = pair
      !ban_entry_expired(entry, current_time)
    })

  let ip_bans = dict.to_list(manager.ip_bans)
    |> list.filter(fn(pair) {
      let #(_key, entry) = pair
      !ban_entry_expired(entry, current_time)
    })

  list.append(peer_bans, ip_bans)
}

/// Get ban statistics
pub fn get_stats(manager: BanManager) -> BanStats {
  manager.stats
}

// ============================================================================
// Serialization for Persistence
// ============================================================================

/// Export bans for persistence (returns list of peer_id/ip, ban_time, duration, reason)
pub type BanExport {
  BanExport(
    identifier: String,
    ban_type: BanExportType,
    ban_time: Int,
    duration: Int,
    reason: String,
    manual: Bool,
  )
}

pub type BanExportType {
  PeerBan
  IpBan
  SubnetBan
}

/// Export all active bans
pub fn export_bans(
  manager: BanManager,
  current_time: Int,
) -> List(BanExport) {
  let peer_exports = dict.to_list(manager.peer_bans)
    |> list.filter_map(fn(pair) {
      let #(peer_id, entry) = pair
      case ban_entry_expired(entry, current_time) {
        True -> Error(Nil)
        False -> Ok(BanExport(
          identifier: peer_id,
          ban_type: PeerBan,
          ban_time: entry.ban_time,
          duration: entry.duration,
          reason: ban_reason_to_string(entry.reason),
          manual: entry.manual,
        ))
      }
    })

  let ip_exports = dict.to_list(manager.ip_bans)
    |> list.filter_map(fn(pair) {
      let #(ip, entry) = pair
      case ban_entry_expired(entry, current_time) {
        True -> Error(Nil)
        False -> Ok(BanExport(
          identifier: ip,
          ban_type: IpBan,
          ban_time: entry.ban_time,
          duration: entry.duration,
          reason: ban_reason_to_string(entry.reason),
          manual: entry.manual,
        ))
      }
    })

  list.append(peer_exports, ip_exports)
}

fn ban_reason_to_string(reason: BanReason) -> String {
  case reason {
    AutoBan(score, _misbehavior) ->
      "Automatic ban (score: " <> int.to_string(score) <> ")"
    ManualBan(description) -> "Manual: " <> description
    ImportedBan -> "Imported"
  }
}

/// Import bans from persistence
pub fn import_bans(
  manager: BanManager,
  exports: List(BanExport),
  current_time: Int,
) -> BanManager {
  list.fold(exports, manager, fn(mgr, export) {
    // Skip if already expired
    case current_time >= export.ban_time + export.duration {
      True -> mgr
      False -> {
        let entry = BanEntry(
          reason: ImportedBan,
          ban_time: export.ban_time,
          duration: export.duration,
          manual: export.manual,
        )
        case export.ban_type {
          PeerBan -> BanManager(
            ..mgr,
            peer_bans: dict.insert(mgr.peer_bans, export.identifier, entry),
          )
          IpBan -> BanManager(
            ..mgr,
            ip_bans: dict.insert(mgr.ip_bans, export.identifier, entry),
          )
          SubnetBan -> BanManager(
            ..mgr,
            subnet_bans: dict.insert(mgr.subnet_bans, export.identifier, entry),
          )
        }
      }
    }
  })
}
