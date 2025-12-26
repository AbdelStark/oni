// ratelimit.gleam - Rate limiting and DoS protection for P2P layer
//
// This module provides defense mechanisms against resource exhaustion attacks:
// - Token bucket rate limiting for messages per peer
// - Connection rate limiting per IP subnet
// - Bandwidth throttling
// - Misbehavior tracking and banning
//
// Design principles:
// - Fail-safe defaults (rate limit if unsure)
// - Per-peer isolation (one bad peer doesn't affect others)
// - Gradual degradation under load
// - Observable metrics for tuning

import gleam/dict.{type Dict}
import gleam/list
import gleam/option.{type Option, None, Some}
import oni_p2p

// ============================================================================
// Token Bucket Rate Limiter
// ============================================================================

/// Token bucket for rate limiting
pub type TokenBucket {
  TokenBucket(
    /// Current number of tokens
    tokens: Float,
    /// Maximum tokens (burst capacity)
    max_tokens: Float,
    /// Tokens added per second
    refill_rate: Float,
    /// Last refill timestamp (ms)
    last_refill: Int,
  )
}

/// Create a new token bucket
pub fn token_bucket_new(max_tokens: Float, refill_rate: Float, now: Int) -> TokenBucket {
  TokenBucket(
    tokens: max_tokens,  // Start full
    max_tokens: max_tokens,
    refill_rate: refill_rate,
    last_refill: now,
  )
}

/// Try to consume tokens from the bucket
/// Returns updated bucket and whether consumption succeeded
pub fn token_bucket_try_consume(
  bucket: TokenBucket,
  amount: Float,
  now: Int,
) -> #(TokenBucket, Bool) {
  // First refill based on elapsed time
  let refilled = token_bucket_refill(bucket, now)

  case refilled.tokens >=. amount {
    True -> {
      let updated = TokenBucket(
        ..refilled,
        tokens: refilled.tokens -. amount,
      )
      #(updated, True)
    }
    False -> #(refilled, False)
  }
}

/// Refill tokens based on elapsed time
fn token_bucket_refill(bucket: TokenBucket, now: Int) -> TokenBucket {
  let elapsed_ms = now - bucket.last_refill
  case elapsed_ms > 0 {
    True -> {
      let elapsed_secs = int_to_float(elapsed_ms) /. 1000.0
      let new_tokens = bucket.tokens +. bucket.refill_rate *. elapsed_secs
      let capped = float_min(new_tokens, bucket.max_tokens)
      TokenBucket(
        ..bucket,
        tokens: capped,
        last_refill: now,
      )
    }
    False -> bucket
  }
}

// ============================================================================
// Peer Rate Limiter
// ============================================================================

/// Rate limits for different message types
pub type MessageRateLimits {
  MessageRateLimits(
    /// INV messages per minute
    inv_per_min: Int,
    /// GETDATA messages per minute
    getdata_per_min: Int,
    /// ADDR messages per minute
    addr_per_min: Int,
    /// TX messages per minute
    tx_per_min: Int,
    /// BLOCK messages per hour
    block_per_hour: Int,
    /// PING messages per minute
    ping_per_min: Int,
    /// Generic messages per second
    generic_per_sec: Int,
  )
}

/// Default rate limits (conservative)
pub fn default_rate_limits() -> MessageRateLimits {
  MessageRateLimits(
    inv_per_min: 500,
    getdata_per_min: 200,
    addr_per_min: 100,
    tx_per_min: 100,
    block_per_hour: 200,
    ping_per_min: 10,
    generic_per_sec: 50,
  )
}

/// Rate limiter state for a single peer
pub type PeerRateLimiter {
  PeerRateLimiter(
    peer_id: oni_p2p.PeerId,
    /// Token bucket for general messages
    general: TokenBucket,
    /// Per-message-type counters
    inv_count: Int,
    getdata_count: Int,
    addr_count: Int,
    tx_count: Int,
    block_count: Int,
    /// Last reset timestamp
    last_reset: Int,
    /// Total blocked count
    blocked_count: Int,
  )
}

/// Create a rate limiter for a peer
pub fn peer_rate_limiter_new(peer_id: oni_p2p.PeerId, now: Int) -> PeerRateLimiter {
  let limits = default_rate_limits()
  PeerRateLimiter(
    peer_id: peer_id,
    general: token_bucket_new(
      int_to_float(limits.generic_per_sec * 10),  // 10 second burst
      int_to_float(limits.generic_per_sec),
      now,
    ),
    inv_count: 0,
    getdata_count: 0,
    addr_count: 0,
    tx_count: 0,
    block_count: 0,
    last_reset: now,
    blocked_count: 0,
  )
}

/// Message category for rate limiting
pub type MessageCategory {
  CatInv
  CatGetData
  CatAddr
  CatTx
  CatBlock
  CatPing
  CatOther
}

/// Check if a message should be allowed
pub fn peer_rate_check(
  limiter: PeerRateLimiter,
  category: MessageCategory,
  now: Int,
) -> #(PeerRateLimiter, Bool) {
  let limits = default_rate_limits()

  // Reset counters every minute
  let limiter_reset = case now - limiter.last_reset > 60_000 {
    True -> PeerRateLimiter(
      ..limiter,
      inv_count: 0,
      getdata_count: 0,
      addr_count: 0,
      tx_count: 0,
      block_count: 0,
      last_reset: now,
    )
    False -> limiter
  }

  // Check general rate limit first
  let #(new_general, general_ok) = token_bucket_try_consume(
    limiter_reset.general,
    1.0,
    now,
  )

  case general_ok {
    False -> {
      let blocked = PeerRateLimiter(
        ..limiter_reset,
        general: new_general,
        blocked_count: limiter_reset.blocked_count + 1,
      )
      #(blocked, False)
    }
    True -> {
      // Check category-specific limit
      let #(updated, allowed) = case category {
        CatInv -> {
          case limiter_reset.inv_count < limits.inv_per_min {
            True -> #(
              PeerRateLimiter(..limiter_reset, inv_count: limiter_reset.inv_count + 1),
              True,
            )
            False -> #(limiter_reset, False)
          }
        }
        CatGetData -> {
          case limiter_reset.getdata_count < limits.getdata_per_min {
            True -> #(
              PeerRateLimiter(..limiter_reset, getdata_count: limiter_reset.getdata_count + 1),
              True,
            )
            False -> #(limiter_reset, False)
          }
        }
        CatAddr -> {
          case limiter_reset.addr_count < limits.addr_per_min {
            True -> #(
              PeerRateLimiter(..limiter_reset, addr_count: limiter_reset.addr_count + 1),
              True,
            )
            False -> #(limiter_reset, False)
          }
        }
        CatTx -> {
          case limiter_reset.tx_count < limits.tx_per_min {
            True -> #(
              PeerRateLimiter(..limiter_reset, tx_count: limiter_reset.tx_count + 1),
              True,
            )
            False -> #(limiter_reset, False)
          }
        }
        CatBlock -> {
          // Blocks are rate limited hourly, not per minute
          // Simplified: allow if under limit
          case limiter_reset.block_count < limits.block_per_hour {
            True -> #(
              PeerRateLimiter(..limiter_reset, block_count: limiter_reset.block_count + 1),
              True,
            )
            False -> #(limiter_reset, False)
          }
        }
        CatPing -> #(limiter_reset, True)  // Always allow pings
        CatOther -> #(limiter_reset, True)  // Allow other with just general limit
      }

      case allowed {
        True -> #(PeerRateLimiter(..updated, general: new_general), True)
        False -> #(
          PeerRateLimiter(
            ..updated,
            general: new_general,
            blocked_count: updated.blocked_count + 1,
          ),
          False,
        )
      }
    }
  }
}

// ============================================================================
// Connection Rate Limiter
// ============================================================================

/// Per-subnet connection tracking
pub type SubnetTracker {
  SubnetTracker(
    /// Connections per /16 subnet (first 2 octets for IPv4)
    by_subnet: Dict(Int, Int),
    /// Maximum connections per subnet
    max_per_subnet: Int,
    /// Total connection attempts
    total_attempts: Int,
    /// Blocked attempts
    blocked_attempts: Int,
  )
}

/// Create a new subnet tracker
pub fn subnet_tracker_new(max_per_subnet: Int) -> SubnetTracker {
  SubnetTracker(
    by_subnet: dict.new(),
    max_per_subnet: max_per_subnet,
    total_attempts: 0,
    blocked_attempts: 0,
  )
}

/// Default max connections per /16 subnet
pub const default_max_per_subnet = 8

/// Create subnet tracker with defaults
pub fn subnet_tracker_default() -> SubnetTracker {
  subnet_tracker_new(default_max_per_subnet)
}

/// Extract /16 subnet key from IP
fn subnet_key(ip: oni_p2p.IpAddr) -> Int {
  case ip {
    oni_p2p.IPv4(a, b, _, _) -> a * 256 + b
    oni_p2p.IPv6(a, b, _, _, _, _, _, _) -> a * 65536 + b
  }
}

/// Check if a new connection from IP should be allowed
pub fn subnet_check_connection(
  tracker: SubnetTracker,
  ip: oni_p2p.IpAddr,
) -> #(SubnetTracker, Bool) {
  let key = subnet_key(ip)
  let current = case dict.get(tracker.by_subnet, key) {
    Ok(count) -> count
    Error(_) -> 0
  }

  let new_tracker = SubnetTracker(
    ..tracker,
    total_attempts: tracker.total_attempts + 1,
  )

  case current < tracker.max_per_subnet {
    True -> {
      let updated = SubnetTracker(
        ..new_tracker,
        by_subnet: dict.insert(tracker.by_subnet, key, current + 1),
      )
      #(updated, True)
    }
    False -> {
      let blocked = SubnetTracker(
        ..new_tracker,
        blocked_attempts: tracker.blocked_attempts + 1,
      )
      #(blocked, False)
    }
  }
}

/// Remove a connection from tracking
pub fn subnet_remove_connection(
  tracker: SubnetTracker,
  ip: oni_p2p.IpAddr,
) -> SubnetTracker {
  let key = subnet_key(ip)
  case dict.get(tracker.by_subnet, key) {
    Ok(count) if count > 1 -> {
      SubnetTracker(
        ..tracker,
        by_subnet: dict.insert(tracker.by_subnet, key, count - 1),
      )
    }
    Ok(_) -> {
      SubnetTracker(
        ..tracker,
        by_subnet: dict.delete(tracker.by_subnet, key),
      )
    }
    Error(_) -> tracker
  }
}

// ============================================================================
// Bandwidth Throttler
// ============================================================================

/// Bandwidth throttling configuration
pub type BandwidthConfig {
  BandwidthConfig(
    /// Maximum upload bytes per second
    max_upload_bps: Int,
    /// Maximum download bytes per second
    max_download_bps: Int,
    /// Burst multiplier (allow short bursts above limit)
    burst_multiplier: Float,
  )
}

/// Default bandwidth config (10 MB/s each way)
pub fn default_bandwidth_config() -> BandwidthConfig {
  BandwidthConfig(
    max_upload_bps: 10_000_000,
    max_download_bps: 10_000_000,
    burst_multiplier: 2.0,
  )
}

/// Bandwidth throttler state
pub type BandwidthThrottler {
  BandwidthThrottler(
    config: BandwidthConfig,
    /// Upload token bucket
    upload: TokenBucket,
    /// Download token bucket
    download: TokenBucket,
    /// Total bytes uploaded
    total_uploaded: Int,
    /// Total bytes downloaded
    total_downloaded: Int,
  )
}

/// Create a new bandwidth throttler
pub fn bandwidth_throttler_new(config: BandwidthConfig, now: Int) -> BandwidthThrottler {
  let upload_burst = int_to_float(config.max_upload_bps) *. config.burst_multiplier
  let download_burst = int_to_float(config.max_download_bps) *. config.burst_multiplier

  BandwidthThrottler(
    config: config,
    upload: token_bucket_new(upload_burst, int_to_float(config.max_upload_bps), now),
    download: token_bucket_new(download_burst, int_to_float(config.max_download_bps), now),
    total_uploaded: 0,
    total_downloaded: 0,
  )
}

/// Check if upload of given size should be allowed
pub fn bandwidth_check_upload(
  throttler: BandwidthThrottler,
  bytes: Int,
  now: Int,
) -> #(BandwidthThrottler, Bool) {
  let #(new_bucket, allowed) = token_bucket_try_consume(
    throttler.upload,
    int_to_float(bytes),
    now,
  )

  let updated = case allowed {
    True -> BandwidthThrottler(
      ..throttler,
      upload: new_bucket,
      total_uploaded: throttler.total_uploaded + bytes,
    )
    False -> BandwidthThrottler(..throttler, upload: new_bucket)
  }

  #(updated, allowed)
}

/// Check if download of given size should be allowed
pub fn bandwidth_check_download(
  throttler: BandwidthThrottler,
  bytes: Int,
  now: Int,
) -> #(BandwidthThrottler, Bool) {
  let #(new_bucket, allowed) = token_bucket_try_consume(
    throttler.download,
    int_to_float(bytes),
    now,
  )

  let updated = case allowed {
    True -> BandwidthThrottler(
      ..throttler,
      download: new_bucket,
      total_downloaded: throttler.total_downloaded + bytes,
    )
    False -> BandwidthThrottler(..throttler, download: new_bucket)
  }

  #(updated, allowed)
}

// ============================================================================
// Ban Manager
// ============================================================================

/// Reason for banning a peer
pub type BanReason {
  /// Too many protocol violations
  ProtocolViolations
  /// Exceeded rate limits repeatedly
  RateLimitAbuse
  /// Sent invalid data
  InvalidData
  /// Manual ban by operator
  ManualBan
}

/// Ban entry
pub type BanEntry {
  BanEntry(
    ip: oni_p2p.IpAddr,
    reason: BanReason,
    /// Ban start time (unix timestamp)
    banned_at: Int,
    /// Ban duration in seconds
    duration: Int,
  )
}

/// Ban manager for tracking banned IPs
pub type BanManager {
  BanManager(
    /// Banned IPs with expiry
    bans: Dict(Int, BanEntry),
    /// Default ban duration in seconds (24 hours)
    default_duration: Int,
  )
}

/// Create a new ban manager
pub fn ban_manager_new() -> BanManager {
  BanManager(
    bans: dict.new(),
    default_duration: 86_400,  // 24 hours
  )
}

/// Check if an IP is banned
pub fn is_banned(manager: BanManager, ip: oni_p2p.IpAddr, now: Int) -> Bool {
  let key = ip_to_key(ip)
  case dict.get(manager.bans, key) {
    Ok(entry) -> {
      let expires_at = entry.banned_at + entry.duration
      now < expires_at
    }
    Error(_) -> False
  }
}

/// Ban an IP address
pub fn ban_ip(
  manager: BanManager,
  ip: oni_p2p.IpAddr,
  reason: BanReason,
  now: Int,
) -> BanManager {
  let entry = BanEntry(
    ip: ip,
    reason: reason,
    banned_at: now,
    duration: manager.default_duration,
  )
  let key = ip_to_key(ip)
  BanManager(
    ..manager,
    bans: dict.insert(manager.bans, key, entry),
  )
}

/// Unban an IP address
pub fn unban_ip(manager: BanManager, ip: oni_p2p.IpAddr) -> BanManager {
  let key = ip_to_key(ip)
  BanManager(
    ..manager,
    bans: dict.delete(manager.bans, key),
  )
}

/// Clean up expired bans
pub fn cleanup_expired_bans(manager: BanManager, now: Int) -> BanManager {
  let active_bans = dict.filter(manager.bans, fn(_key, entry) {
    let expires_at = entry.banned_at + entry.duration
    now < expires_at
  })
  BanManager(..manager, bans: active_bans)
}

/// Get list of currently banned IPs
pub fn list_bans(manager: BanManager, now: Int) -> List(BanEntry) {
  manager.bans
  |> dict.to_list
  |> list.filter_map(fn(pair) {
    let #(_, entry) = pair
    let expires_at = entry.banned_at + entry.duration
    case now < expires_at {
      True -> Ok(entry)
      False -> Error(Nil)
    }
  })
}

// ============================================================================
// Combined DoS Protection
// ============================================================================

/// Combined DoS protection state
pub type DoSProtection {
  DoSProtection(
    /// Per-peer rate limiters
    peer_limiters: Dict(String, PeerRateLimiter),
    /// Subnet connection tracker
    subnet_tracker: SubnetTracker,
    /// Bandwidth throttler
    bandwidth: BandwidthThrottler,
    /// Ban manager
    ban_manager: BanManager,
    /// Statistics
    stats: DoSStats,
  )
}

/// DoS protection statistics
pub type DoSStats {
  DoSStats(
    messages_allowed: Int,
    messages_blocked: Int,
    connections_allowed: Int,
    connections_blocked: Int,
    bytes_throttled: Int,
    peers_banned: Int,
  )
}

/// Create new DoS protection with defaults
pub fn dos_protection_new(now: Int) -> DoSProtection {
  DoSProtection(
    peer_limiters: dict.new(),
    subnet_tracker: subnet_tracker_default(),
    bandwidth: bandwidth_throttler_new(default_bandwidth_config(), now),
    ban_manager: ban_manager_new(),
    stats: DoSStats(
      messages_allowed: 0,
      messages_blocked: 0,
      connections_allowed: 0,
      connections_blocked: 0,
      bytes_throttled: 0,
      peers_banned: 0,
    ),
  )
}

/// Check if a message from peer should be allowed
pub fn check_message(
  protection: DoSProtection,
  peer_id: oni_p2p.PeerId,
  category: MessageCategory,
  now: Int,
) -> #(DoSProtection, Bool) {
  let oni_p2p.PeerId(id_str) = peer_id

  // Get or create peer limiter
  let limiter = case dict.get(protection.peer_limiters, id_str) {
    Ok(l) -> l
    Error(_) -> peer_rate_limiter_new(peer_id, now)
  }

  let #(new_limiter, allowed) = peer_rate_check(limiter, category, now)
  let new_limiters = dict.insert(protection.peer_limiters, id_str, new_limiter)

  let new_stats = case allowed {
    True -> DoSStats(
      ..protection.stats,
      messages_allowed: protection.stats.messages_allowed + 1,
    )
    False -> DoSStats(
      ..protection.stats,
      messages_blocked: protection.stats.messages_blocked + 1,
    )
  }

  #(
    DoSProtection(
      ..protection,
      peer_limiters: new_limiters,
      stats: new_stats,
    ),
    allowed,
  )
}

/// Check if a new connection should be allowed
pub fn check_connection(
  protection: DoSProtection,
  ip: oni_p2p.IpAddr,
  now: Int,
) -> #(DoSProtection, Bool) {
  // First check ban list
  case is_banned(protection.ban_manager, ip, now) {
    True -> #(protection, False)
    False -> {
      // Check subnet limits
      let #(new_tracker, allowed) = subnet_check_connection(
        protection.subnet_tracker,
        ip,
      )

      let new_stats = case allowed {
        True -> DoSStats(
          ..protection.stats,
          connections_allowed: protection.stats.connections_allowed + 1,
        )
        False -> DoSStats(
          ..protection.stats,
          connections_blocked: protection.stats.connections_blocked + 1,
        )
      }

      #(
        DoSProtection(
          ..protection,
          subnet_tracker: new_tracker,
          stats: new_stats,
        ),
        allowed,
      )
    }
  }
}

/// Get DoS protection statistics
pub fn get_stats(protection: DoSProtection) -> DoSStats {
  protection.stats
}

// ============================================================================
// Helper Functions
// ============================================================================

fn ip_to_key(ip: oni_p2p.IpAddr) -> Int {
  case ip {
    oni_p2p.IPv4(a, b, c, d) -> a * 16777216 + b * 65536 + c * 256 + d
    oni_p2p.IPv6(a, b, c, d, _, _, _, _) -> a * 16777216 + b * 65536 + c * 256 + d
  }
}

fn int_to_float(n: Int) -> Float {
  case n {
    0 -> 0.0
    _ -> do_int_to_float(n, 0.0)
  }
}

fn do_int_to_float(n: Int, acc: Float) -> Float {
  case n {
    0 -> acc
    _ -> do_int_to_float(n - 1, acc +. 1.0)
  }
}

fn float_min(a: Float, b: Float) -> Float {
  case a <. b {
    True -> a
    False -> b
  }
}
