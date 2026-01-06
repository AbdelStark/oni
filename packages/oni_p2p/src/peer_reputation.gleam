// peer_reputation.gleam - Advanced Peer Reputation and Quality Tracking
//
// This module extends the basic ban_manager with:
// - Positive reputation tracking (good behavior rewards)
// - Network quality metrics (latency, bandwidth, reliability)
// - Peer selection based on reputation scores
// - Historical performance tracking
// - Eviction policies for connection slot management
//
// The system maintains a comprehensive score that includes:
// - Misbehavior penalties (from ban_manager)
// - Positive contributions (blocks, txs relayed)
// - Network quality (latency, uptime)
// - Historical reliability

import ban_manager.{type BanManager, type Misbehavior}
import gleam/dict.{type Dict}
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}

// ============================================================================
// Constants
// ============================================================================

/// Default starting reputation for new peers
pub const default_reputation = 1000

/// Maximum reputation score
pub const max_reputation = 10_000

/// Minimum reputation score (below this = banned)
pub const min_reputation = 0

/// Reputation decay per hour for inactive peers
pub const hourly_decay = 5

/// Maximum number of peers to track
pub const max_tracked_peers = 10_000

/// Reputation threshold for "trusted" peers
pub const trusted_threshold = 5000

/// Reputation threshold for "reliable" peers
pub const reliable_threshold = 2000

// ============================================================================
// Peer Quality Metrics
// ============================================================================

/// Network quality metrics for a peer
pub type QualityMetrics {
  QualityMetrics(
    /// Average round-trip latency in milliseconds
    avg_latency_ms: Int,
    /// Minimum observed latency
    min_latency_ms: Int,
    /// Maximum observed latency
    max_latency_ms: Int,
    /// Latency sample count
    latency_samples: Int,
    /// Average bandwidth in bytes/second
    avg_bandwidth_bps: Int,
    /// Total bytes received from this peer
    bytes_received: Int,
    /// Total bytes sent to this peer
    bytes_sent: Int,
    /// Connection uptime in seconds
    uptime_seconds: Int,
    /// Number of successful connections
    connection_count: Int,
    /// Number of failed connection attempts
    failed_connections: Int,
    /// Last seen timestamp
    last_seen: Int,
    /// First seen timestamp
    first_seen: Int,
  )
}

/// Create default quality metrics
pub fn quality_metrics_new(current_time: Int) -> QualityMetrics {
  QualityMetrics(
    avg_latency_ms: 0,
    min_latency_ms: 0,
    max_latency_ms: 0,
    latency_samples: 0,
    avg_bandwidth_bps: 0,
    bytes_received: 0,
    bytes_sent: 0,
    uptime_seconds: 0,
    connection_count: 0,
    failed_connections: 0,
    last_seen: current_time,
    first_seen: current_time,
  )
}

/// Record a latency sample
pub fn record_latency(
  metrics: QualityMetrics,
  latency_ms: Int,
) -> QualityMetrics {
  let new_samples = metrics.latency_samples + 1
  let new_avg = case metrics.latency_samples {
    0 -> latency_ms
    _ -> {
      let total = metrics.avg_latency_ms * metrics.latency_samples + latency_ms
      total / new_samples
    }
  }

  let new_min = case metrics.min_latency_ms {
    0 -> latency_ms
    m -> int.min(m, latency_ms)
  }

  let new_max = int.max(metrics.max_latency_ms, latency_ms)

  QualityMetrics(
    ..metrics,
    avg_latency_ms: new_avg,
    min_latency_ms: new_min,
    max_latency_ms: new_max,
    latency_samples: new_samples,
  )
}

/// Record bytes transferred
pub fn record_transfer(
  metrics: QualityMetrics,
  bytes_in: Int,
  bytes_out: Int,
) -> QualityMetrics {
  QualityMetrics(
    ..metrics,
    bytes_received: metrics.bytes_received + bytes_in,
    bytes_sent: metrics.bytes_sent + bytes_out,
  )
}

/// Update connection status
pub fn record_connection(
  metrics: QualityMetrics,
  success: Bool,
  current_time: Int,
) -> QualityMetrics {
  case success {
    True ->
      QualityMetrics(
        ..metrics,
        connection_count: metrics.connection_count + 1,
        last_seen: current_time,
      )
    False ->
      QualityMetrics(
        ..metrics,
        failed_connections: metrics.failed_connections + 1,
      )
  }
}

/// Calculate connection reliability percentage
pub fn connection_reliability(metrics: QualityMetrics) -> Float {
  let total = metrics.connection_count + metrics.failed_connections
  case total {
    0 -> 0.0
    _ -> int.to_float(metrics.connection_count * 100) /. int.to_float(total)
  }
}

// ============================================================================
// Positive Behavior Tracking
// ============================================================================

/// Types of positive behavior that earn reputation
pub type PositiveBehavior {
  /// Successfully relayed a valid block
  RelayedBlock
  /// Successfully relayed valid transactions
  RelayedTransactions(count: Int)
  /// Provided valid headers during sync
  ProvidedHeaders(count: Int)
  /// Responded to ping quickly
  FastPingResponse(latency_ms: Int)
  /// Successfully completed handshake
  SuccessfulHandshake
  /// Provided address information
  ProvidedAddresses(count: Int)
  /// Maintained stable connection
  StableConnection(duration_hours: Int)
  /// Sent compact blocks efficiently
  CompactBlockRelay
  /// Custom bonus
  CustomBonus(amount: Int, reason: String)
}

/// Get reputation bonus for positive behavior
pub fn positive_behavior_bonus(behavior: PositiveBehavior) -> Int {
  case behavior {
    RelayedBlock -> 50
    RelayedTransactions(count) -> int.min(count, 10)
    // Max 10 per batch
    ProvidedHeaders(count) -> count / 100
    // 1 point per 100 headers
    FastPingResponse(latency_ms) -> {
      case latency_ms {
        ms if ms < 50 -> 5
        ms if ms < 100 -> 3
        ms if ms < 200 -> 1
        _ -> 0
      }
    }
    SuccessfulHandshake -> 10
    ProvidedAddresses(count) -> int.min(count / 10, 5)
    StableConnection(duration_hours) -> int.min(duration_hours, 24)
    CompactBlockRelay -> 30
    CustomBonus(amount, _) -> amount
  }
}

// ============================================================================
// Peer Reputation Entry
// ============================================================================

/// Complete reputation profile for a peer
pub type PeerReputation {
  PeerReputation(
    /// Current reputation score
    score: Int,
    /// Quality metrics
    quality: QualityMetrics,
    /// Last score update time
    last_update: Int,
    /// Total positive contributions
    positive_contributions: Int,
    /// Total misbehavior incidents (from ban_manager)
    misbehavior_incidents: Int,
    /// Peer classification
    classification: PeerClass,
    /// Whether peer is currently connected
    connected: Bool,
    /// Services advertised by peer
    services: Int,
    /// Protocol version
    version: Int,
    /// User agent
    user_agent: String,
  )
}

/// Peer classification based on reputation
pub type PeerClass {
  /// New peer, not yet evaluated
  ClassNew
  /// Peer with low reputation
  ClassUntrusted
  /// Normal peer with average reputation
  ClassNormal
  /// Peer with high reputation
  ClassReliable
  /// Peer with very high reputation
  ClassTrusted
  /// Peer that has been banned
  ClassBanned
}

/// Create a new peer reputation entry
pub fn peer_reputation_new(current_time: Int) -> PeerReputation {
  PeerReputation(
    score: default_reputation,
    quality: quality_metrics_new(current_time),
    last_update: current_time,
    positive_contributions: 0,
    misbehavior_incidents: 0,
    classification: ClassNew,
    connected: False,
    services: 0,
    version: 0,
    user_agent: "",
  )
}

/// Apply a positive behavior bonus
pub fn apply_positive(
  rep: PeerReputation,
  behavior: PositiveBehavior,
  current_time: Int,
) -> PeerReputation {
  let bonus = positive_behavior_bonus(behavior)
  let new_score = int.min(rep.score + bonus, max_reputation)

  PeerReputation(
    ..rep,
    score: new_score,
    last_update: current_time,
    positive_contributions: rep.positive_contributions + 1,
    classification: classify_score(new_score),
  )
}

/// Apply a misbehavior penalty
pub fn apply_misbehavior(
  rep: PeerReputation,
  misbehavior: Misbehavior,
  current_time: Int,
) -> PeerReputation {
  let penalty = ban_manager.misbehavior_penalty(misbehavior)
  let new_score = int.max(rep.score - penalty, min_reputation)

  PeerReputation(
    ..rep,
    score: new_score,
    last_update: current_time,
    misbehavior_incidents: rep.misbehavior_incidents + 1,
    classification: case new_score <= min_reputation {
      True -> ClassBanned
      False -> classify_score(new_score)
    },
  )
}

/// Apply time-based reputation decay
pub fn apply_decay(rep: PeerReputation, current_time: Int) -> PeerReputation {
  let hours_elapsed = { current_time - rep.last_update } / 3600
  case hours_elapsed > 0 {
    False -> rep
    True -> {
      let decay = hours_elapsed * hourly_decay
      let new_score = int.max(rep.score - decay, default_reputation / 2)
      PeerReputation(
        ..rep,
        score: new_score,
        last_update: current_time,
        classification: classify_score(new_score),
      )
    }
  }
}

/// Classify a peer based on score
fn classify_score(score: Int) -> PeerClass {
  case score {
    s if s <= min_reputation -> ClassBanned
    s if s < reliable_threshold / 2 -> ClassUntrusted
    s if s < reliable_threshold -> ClassNormal
    s if s < trusted_threshold -> ClassReliable
    _ -> ClassTrusted
  }
}

/// Check if peer is trusted
pub fn is_trusted(rep: PeerReputation) -> Bool {
  rep.score >= trusted_threshold
}

/// Check if peer is reliable
pub fn is_reliable(rep: PeerReputation) -> Bool {
  rep.score >= reliable_threshold
}

/// Check if peer should be banned
pub fn should_ban(rep: PeerReputation) -> Bool {
  rep.score <= min_reputation
}

// ============================================================================
// Reputation Manager
// ============================================================================

/// Manages reputation for all known peers
pub type ReputationManager {
  ReputationManager(
    /// Reputation entries by peer ID
    peers: Dict(String, PeerReputation),
    /// Ban manager integration
    ban_manager: BanManager,
    /// Statistics
    stats: ReputationStats,
    /// Configuration
    config: ReputationConfig,
  )
}

/// Reputation manager configuration
pub type ReputationConfig {
  ReputationConfig(
    /// Maximum peers to track
    max_peers: Int,
    /// Enable reputation decay
    decay_enabled: Bool,
    /// Hours between decay applications
    decay_interval_hours: Int,
    /// Minimum score to maintain connection
    min_connection_score: Int,
  )
}

/// Default configuration
pub fn default_config() -> ReputationConfig {
  ReputationConfig(
    max_peers: max_tracked_peers,
    decay_enabled: True,
    decay_interval_hours: 24,
    min_connection_score: reliable_threshold / 4,
  )
}

/// Reputation statistics
pub type ReputationStats {
  ReputationStats(
    /// Total peers tracked
    total_peers: Int,
    /// Peers by classification
    trusted_count: Int,
    reliable_count: Int,
    normal_count: Int,
    untrusted_count: Int,
    banned_count: Int,
    /// Total positive behaviors recorded
    total_positive: Int,
    /// Total misbehaviors recorded
    total_misbehavior: Int,
  )
}

/// Create a new reputation manager
pub fn reputation_manager_new(config: ReputationConfig) -> ReputationManager {
  ReputationManager(
    peers: dict.new(),
    ban_manager: ban_manager.ban_manager_new(),
    stats: ReputationStats(
      total_peers: 0,
      trusted_count: 0,
      reliable_count: 0,
      normal_count: 0,
      untrusted_count: 0,
      banned_count: 0,
      total_positive: 0,
      total_misbehavior: 0,
    ),
    config: config,
  )
}

/// Get or create reputation for a peer
pub fn get_or_create(
  manager: ReputationManager,
  peer_id: String,
  current_time: Int,
) -> #(ReputationManager, PeerReputation) {
  case dict.get(manager.peers, peer_id) {
    Ok(rep) -> #(manager, rep)
    Error(_) -> {
      let rep = peer_reputation_new(current_time)
      let new_peers = dict.insert(manager.peers, peer_id, rep)
      let new_stats =
        ReputationStats(
          ..manager.stats,
          total_peers: manager.stats.total_peers + 1,
        )
      #(ReputationManager(..manager, peers: new_peers, stats: new_stats), rep)
    }
  }
}

/// Record positive behavior
pub fn record_positive(
  manager: ReputationManager,
  peer_id: String,
  behavior: PositiveBehavior,
  current_time: Int,
) -> ReputationManager {
  let #(mgr, rep) = get_or_create(manager, peer_id, current_time)
  let new_rep = apply_positive(rep, behavior, current_time)
  let new_peers = dict.insert(mgr.peers, peer_id, new_rep)
  let new_stats =
    ReputationStats(..mgr.stats, total_positive: mgr.stats.total_positive + 1)

  update_classification_counts(
    ReputationManager(..mgr, peers: new_peers, stats: new_stats),
    rep.classification,
    new_rep.classification,
  )
}

/// Record misbehavior (integrates with ban_manager)
pub fn record_misbehavior(
  manager: ReputationManager,
  peer_id: String,
  misbehavior: Misbehavior,
  current_time: Int,
) -> #(ReputationManager, Bool) {
  // Update reputation
  let #(mgr, rep) = get_or_create(manager, peer_id, current_time)
  let new_rep = apply_misbehavior(rep, misbehavior, current_time)
  let new_peers = dict.insert(mgr.peers, peer_id, new_rep)

  // Also record in ban_manager
  let #(new_ban_mgr, _action) =
    ban_manager.record_misbehavior(
      mgr.ban_manager,
      peer_id,
      misbehavior,
      current_time,
    )

  let new_stats =
    ReputationStats(
      ..mgr.stats,
      total_misbehavior: mgr.stats.total_misbehavior + 1,
    )

  let updated_mgr =
    update_classification_counts(
      ReputationManager(
        ..mgr,
        peers: new_peers,
        ban_manager: new_ban_mgr,
        stats: new_stats,
      ),
      rep.classification,
      new_rep.classification,
    )

  #(updated_mgr, should_ban(new_rep))
}

/// Record quality metrics
pub fn record_quality(
  manager: ReputationManager,
  peer_id: String,
  latency_ms: Option(Int),
  bytes_in: Int,
  bytes_out: Int,
  current_time: Int,
) -> ReputationManager {
  let #(mgr, rep) = get_or_create(manager, peer_id, current_time)

  let new_quality =
    case latency_ms {
      Some(latency) -> record_latency(rep.quality, latency)
      None -> rep.quality
    }
    |> record_transfer(bytes_in, bytes_out)

  let new_rep =
    PeerReputation(..rep, quality: new_quality, last_update: current_time)

  let new_peers = dict.insert(mgr.peers, peer_id, new_rep)
  ReputationManager(..mgr, peers: new_peers)
}

/// Record connection event for a peer in the manager
pub fn manager_record_connection(
  manager: ReputationManager,
  peer_id: String,
  success: Bool,
  services: Int,
  version: Int,
  user_agent: String,
  current_time: Int,
) -> ReputationManager {
  let #(mgr, rep) = get_or_create(manager, peer_id, current_time)

  let new_quality =
    ban_manager.peer_score_new()
    |> fn(_) { record_connection(rep.quality, success, current_time) }

  let new_rep = case success {
    True -> {
      let bonus_rep = apply_positive(rep, SuccessfulHandshake, current_time)
      PeerReputation(
        ..bonus_rep,
        quality: new_quality,
        connected: True,
        services: services,
        version: version,
        user_agent: user_agent,
      )
    }
    False -> PeerReputation(..rep, quality: new_quality)
  }

  let new_peers = dict.insert(mgr.peers, peer_id, new_rep)
  ReputationManager(..mgr, peers: new_peers)
}

/// Record disconnection
pub fn record_disconnection(
  manager: ReputationManager,
  peer_id: String,
  current_time: Int,
) -> ReputationManager {
  case dict.get(manager.peers, peer_id) {
    Error(_) -> manager
    Ok(rep) -> {
      // Calculate uptime and award bonus if stable
      let uptime_hours = { current_time - rep.quality.first_seen } / 3600
      let new_rep =
        case uptime_hours >= 1 {
          True ->
            apply_positive(rep, StableConnection(uptime_hours), current_time)
          False -> rep
        }
        |> fn(r) { PeerReputation(..r, connected: False) }

      let new_peers = dict.insert(manager.peers, peer_id, new_rep)
      ReputationManager(..manager, peers: new_peers)
    }
  }
}

/// Update classification counts when a peer's class changes
fn update_classification_counts(
  manager: ReputationManager,
  old_class: PeerClass,
  new_class: PeerClass,
) -> ReputationManager {
  case old_class == new_class {
    True -> manager
    False -> {
      let stats = manager.stats

      // Decrement old class
      let s1 = case old_class {
        ClassTrusted ->
          ReputationStats(..stats, trusted_count: stats.trusted_count - 1)
        ClassReliable ->
          ReputationStats(..stats, reliable_count: stats.reliable_count - 1)
        ClassNormal ->
          ReputationStats(..stats, normal_count: stats.normal_count - 1)
        ClassUntrusted ->
          ReputationStats(..stats, untrusted_count: stats.untrusted_count - 1)
        ClassBanned ->
          ReputationStats(..stats, banned_count: stats.banned_count - 1)
        ClassNew -> stats
      }

      // Increment new class
      let s2 = case new_class {
        ClassTrusted ->
          ReputationStats(..s1, trusted_count: s1.trusted_count + 1)
        ClassReliable ->
          ReputationStats(..s1, reliable_count: s1.reliable_count + 1)
        ClassNormal -> ReputationStats(..s1, normal_count: s1.normal_count + 1)
        ClassUntrusted ->
          ReputationStats(..s1, untrusted_count: s1.untrusted_count + 1)
        ClassBanned -> ReputationStats(..s1, banned_count: s1.banned_count + 1)
        ClassNew -> s1
      }

      ReputationManager(..manager, stats: s2)
    }
  }
}

// ============================================================================
// Peer Selection
// ============================================================================

/// Criteria for selecting peers
pub type SelectionCriteria {
  SelectionCriteria(
    /// Minimum reputation score
    min_score: Int,
    /// Required services (bitmask)
    required_services: Int,
    /// Prefer low latency
    prefer_low_latency: Bool,
    /// Maximum results
    max_results: Int,
    /// Exclude currently connected
    exclude_connected: Bool,
  )
}

/// Default selection criteria
pub fn default_selection() -> SelectionCriteria {
  SelectionCriteria(
    min_score: reliable_threshold / 2,
    required_services: 0,
    prefer_low_latency: True,
    max_results: 10,
    exclude_connected: True,
  )
}

/// Select peers based on criteria
pub fn select_peers(
  manager: ReputationManager,
  criteria: SelectionCriteria,
) -> List(#(String, PeerReputation)) {
  manager.peers
  |> dict.to_list
  |> list.filter(fn(pair) {
    let #(_id, rep) = pair

    // Check minimum score
    rep.score >= criteria.min_score
    // Check services
    && {
      criteria.required_services == 0
      || int.bitwise_and(rep.services, criteria.required_services)
      == criteria.required_services
    }
    // Check connected status
    && { !criteria.exclude_connected || !rep.connected }
    // Not banned
    && rep.classification != ClassBanned
  })
  |> list.sort(fn(a, b) {
    let #(_id_a, rep_a) = a
    let #(_id_b, rep_b) = b

    case criteria.prefer_low_latency {
      True -> {
        // Sort by latency first, then score
        case
          int.compare(
            rep_a.quality.avg_latency_ms,
            rep_b.quality.avg_latency_ms,
          )
        {
          order.Eq -> int.compare(rep_b.score, rep_a.score)
          other -> other
        }
      }
      False -> {
        // Sort by score
        int.compare(rep_b.score, rep_a.score)
      }
    }
  })
  |> list.take(criteria.max_results)
}

/// Select best peers for sync (highest reputation, full node services)
pub fn select_sync_peers(
  manager: ReputationManager,
  count: Int,
) -> List(#(String, PeerReputation)) {
  select_peers(
    manager,
    SelectionCriteria(
      min_score: reliable_threshold,
      required_services: 1,
      // NODE_NETWORK
      prefer_low_latency: False,
      // Prefer reputation for sync
      max_results: count,
      exclude_connected: False,
    ),
  )
}

/// Select peers for eviction (lowest reputation among connected)
pub fn select_eviction_candidates(
  manager: ReputationManager,
  count: Int,
) -> List(#(String, PeerReputation)) {
  manager.peers
  |> dict.to_list
  |> list.filter(fn(pair) {
    let #(_id, rep) = pair
    rep.connected
  })
  |> list.sort(fn(a, b) {
    let #(_id_a, rep_a) = a
    let #(_id_b, rep_b) = b
    // Sort by score ascending (lowest first for eviction)
    int.compare(rep_a.score, rep_b.score)
  })
  |> list.take(count)
}

// ============================================================================
// Maintenance
// ============================================================================

/// Apply decay to all peers
pub fn apply_global_decay(
  manager: ReputationManager,
  current_time: Int,
) -> ReputationManager {
  case manager.config.decay_enabled {
    False -> manager
    True -> {
      let new_peers =
        dict.map_values(manager.peers, fn(_id, rep) {
          apply_decay(rep, current_time)
        })
      ReputationManager(..manager, peers: new_peers)
    }
  }
}

/// Clean up low-value entries to stay under max_peers limit
pub fn cleanup(
  manager: ReputationManager,
  current_time: Int,
) -> ReputationManager {
  case dict.size(manager.peers) > manager.config.max_peers {
    False -> manager
    True -> {
      // Sort by score and last_seen, remove lowest
      let to_remove = dict.size(manager.peers) - manager.config.max_peers

      let sorted_peers =
        manager.peers
        |> dict.to_list
        |> list.sort(fn(a, b) {
          let #(_id_a, rep_a) = a
          let #(_id_b, rep_b) = b
          // Sort by score first, then last_seen
          case int.compare(rep_a.score, rep_b.score) {
            order.Eq ->
              int.compare(rep_a.quality.last_seen, rep_b.quality.last_seen)
            other -> other
          }
        })

      let to_remove_ids =
        sorted_peers
        |> list.take(to_remove)
        |> list.map(fn(pair) {
          let #(id, _) = pair
          id
        })

      let new_peers =
        list.fold(to_remove_ids, manager.peers, fn(peers, id) {
          dict.delete(peers, id)
        })

      ReputationManager(
        ..manager,
        peers: new_peers,
        stats: ReputationStats(
          ..manager.stats,
          total_peers: dict.size(new_peers),
        ),
      )
    }
  }
}

/// Get statistics
pub fn get_stats(manager: ReputationManager) -> ReputationStats {
  manager.stats
}

/// Get reputation for a specific peer
pub fn get_reputation(
  manager: ReputationManager,
  peer_id: String,
) -> Option(PeerReputation) {
  case dict.get(manager.peers, peer_id) {
    Ok(rep) -> Some(rep)
    Error(_) -> None
  }
}

/// Check if peer is banned
pub fn is_banned(
  manager: ReputationManager,
  peer_id: String,
  current_time: Int,
) -> Bool {
  case dict.get(manager.peers, peer_id) {
    Ok(rep) -> rep.classification == ClassBanned
    Error(_) ->
      ban_manager.is_peer_banned(manager.ban_manager, peer_id, current_time)
  }
}

// Import order module for sorting
import gleam/order
