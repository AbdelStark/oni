// ban_manager_test.gleam - Tests for peer misbehavior scoring and ban management

import gleam/dict
import gleam/list
import gleeunit
import gleeunit/should
import oni_p2p/ban_manager

pub fn main() {
  gleeunit.main()
}

// ============================================================================
// Misbehavior Penalty Tests
// ============================================================================

pub fn misbehavior_penalty_immediate_ban_test() {
  // These should all result in immediate ban (penalty >= 100)
  ban_manager.misbehavior_penalty(ban_manager.InvalidBlockHeader)
  |> should.equal(100)

  ban_manager.misbehavior_penalty(ban_manager.InvalidBlock)
  |> should.equal(100)

  ban_manager.misbehavior_penalty(ban_manager.InvalidPoW)
  |> should.equal(100)

  ban_manager.misbehavior_penalty(ban_manager.InvalidSignature)
  |> should.equal(100)

  ban_manager.misbehavior_penalty(ban_manager.DoubleSpend)
  |> should.equal(100)
}

pub fn misbehavior_penalty_minor_test() {
  // Minor offenses should have lower penalties
  ban_manager.misbehavior_penalty(ban_manager.DuplicateMessage)
  |> should.equal(1)

  ban_manager.misbehavior_penalty(ban_manager.UnrequestedData)
  |> should.equal(5)

  ban_manager.misbehavior_penalty(ban_manager.InvalidTransaction)
  |> should.equal(10)
}

pub fn misbehavior_penalty_custom_test() {
  ban_manager.misbehavior_penalty(ban_manager.Other(42))
  |> should.equal(42)
}

pub fn is_immediate_disconnect_test() {
  ban_manager.is_immediate_disconnect(ban_manager.InvalidBlockHeader)
  |> should.equal(True)

  ban_manager.is_immediate_disconnect(ban_manager.DuplicateMessage)
  |> should.equal(False)

  ban_manager.is_immediate_disconnect(ban_manager.MessageRateExceeded)
  |> should.equal(False)
}

// ============================================================================
// Peer Score Tests
// ============================================================================

pub fn peer_score_new_test() {
  let score = ban_manager.peer_score_new()

  score.score |> should.equal(0)
  score.incident_count |> should.equal(0)
  score.recent_incidents |> should.equal([])
}

pub fn peer_score_add_single_test() {
  let score = ban_manager.peer_score_new()
  let new_score = ban_manager.peer_score_add(
    score,
    ban_manager.InvalidTransaction,
    1000,
  )

  new_score.score |> should.equal(10)
  new_score.incident_count |> should.equal(1)
  new_score.last_update |> should.equal(1000)
}

pub fn peer_score_add_multiple_test() {
  let score = ban_manager.peer_score_new()
    |> ban_manager.peer_score_add(ban_manager.InvalidTransaction, 1000)
    |> ban_manager.peer_score_add(ban_manager.MalformedMessage, 1001)
    |> ban_manager.peer_score_add(ban_manager.MessageRateExceeded, 1002)

  // 10 + 20 + 25 = 55
  score.score |> should.equal(55)
  score.incident_count |> should.equal(3)
}

pub fn peer_score_decay_test() {
  let score = ban_manager.peer_score_new()
    |> ban_manager.peer_score_add(ban_manager.MessageRateExceeded, 1000)

  // Score should be 25 at time 1000
  score.score |> should.equal(25)

  // After 10 seconds, score should decay by 10
  let current = ban_manager.peer_score_current(score, 1010)
  current |> should.equal(15)

  // After 30 seconds, score should be 0
  let current2 = ban_manager.peer_score_current(score, 1030)
  current2 |> should.equal(0)
}

pub fn peer_score_should_ban_test() {
  let score = ban_manager.peer_score_new()
    |> ban_manager.peer_score_add(ban_manager.InvalidBlockHeader, 1000)

  // Single critical offense should trigger ban
  ban_manager.peer_score_should_ban(score) |> should.equal(True)
}

pub fn peer_score_should_not_ban_test() {
  let score = ban_manager.peer_score_new()
    |> ban_manager.peer_score_add(ban_manager.InvalidTransaction, 1000)

  // Single minor offense should not trigger ban
  ban_manager.peer_score_should_ban(score) |> should.equal(False)
}

pub fn peer_score_max_cap_test() {
  let score = ban_manager.peer_score_new()
    |> ban_manager.peer_score_add(ban_manager.InvalidBlockHeader, 1000)
    |> ban_manager.peer_score_add(ban_manager.InvalidBlock, 1001)
    |> ban_manager.peer_score_add(ban_manager.InvalidPoW, 1002)

  // Score should be capped at max_score (200)
  score.score |> should.equal(ban_manager.max_score)
}

// ============================================================================
// Ban Entry Tests
// ============================================================================

pub fn ban_entry_auto_test() {
  let score = ban_manager.peer_score_new()
    |> ban_manager.peer_score_add(ban_manager.InvalidBlockHeader, 1000)

  let entry = ban_manager.ban_entry_auto(
    score,
    ban_manager.InvalidBlockHeader,
    1000,
  )

  entry.ban_time |> should.equal(1000)
  entry.duration |> should.equal(ban_manager.default_ban_duration)
  entry.manual |> should.equal(False)
}

pub fn ban_entry_manual_test() {
  let entry = ban_manager.ban_entry_manual(
    "Suspicious activity",
    2000,
    3600,
  )

  entry.ban_time |> should.equal(2000)
  entry.duration |> should.equal(3600)
  entry.manual |> should.equal(True)
}

pub fn ban_entry_expired_test() {
  let entry = ban_manager.ban_entry_manual("Test", 1000, 3600)

  // Not expired at 2000
  ban_manager.ban_entry_expired(entry, 2000) |> should.equal(False)

  // Expired at 5000
  ban_manager.ban_entry_expired(entry, 5000) |> should.equal(True)

  // Exactly at expiry
  ban_manager.ban_entry_expired(entry, 4600) |> should.equal(True)
}

pub fn ban_entry_remaining_test() {
  let entry = ban_manager.ban_entry_manual("Test", 1000, 3600)

  // 2600 seconds remaining at time 2000
  ban_manager.ban_entry_remaining(entry, 2000) |> should.equal(2600)

  // 0 seconds remaining after expiry
  ban_manager.ban_entry_remaining(entry, 5000) |> should.equal(0)
}

// ============================================================================
// Ban Manager Tests
// ============================================================================

pub fn ban_manager_new_test() {
  let manager = ban_manager.ban_manager_new()

  let stats = ban_manager.get_stats(manager)
  stats.total_incidents |> should.equal(0)
  stats.auto_bans |> should.equal(0)
  stats.manual_bans |> should.equal(0)
  stats.active_bans |> should.equal(0)
}

pub fn record_misbehavior_no_ban_test() {
  let manager = ban_manager.ban_manager_new()

  let #(new_manager, action) = ban_manager.record_misbehavior(
    manager,
    "peer1",
    ban_manager.DuplicateMessage,
    1000,
  )

  case action {
    ban_manager.NoAction -> should.be_true(True)
    _ -> should.fail()
  }

  ban_manager.get_peer_score(new_manager, "peer1", 1000)
  |> should.equal(1)
}

pub fn record_misbehavior_disconnect_test() {
  let manager = ban_manager.ban_manager_new()

  let #(_new_manager, action) = ban_manager.record_misbehavior(
    manager,
    "peer1",
    ban_manager.InvalidBlockHeader,
    1000,
  )

  // Should disconnect and ban due to immediate disconnect
  case action {
    ban_manager.Ban(_) -> should.be_true(True)
    _ -> should.fail()
  }
}

pub fn record_misbehavior_ban_test() {
  let manager = ban_manager.ban_manager_new()

  // Accumulate enough misbehavior to trigger ban
  let #(m1, _) = ban_manager.record_misbehavior(manager, "peer1", ban_manager.MessageRateExceeded, 1000)
  let #(m2, _) = ban_manager.record_misbehavior(m1, "peer1", ban_manager.MessageRateExceeded, 1001)
  let #(m3, _) = ban_manager.record_misbehavior(m2, "peer1", ban_manager.MessageRateExceeded, 1002)
  let #(m4, action) = ban_manager.record_misbehavior(m3, "peer1", ban_manager.MessageRateExceeded, 1003)

  // 25 * 4 = 100, should trigger ban
  case action {
    ban_manager.Ban(_) -> should.be_true(True)
    _ -> should.fail()
  }

  ban_manager.is_peer_banned(m4, "peer1", 1003) |> should.equal(True)
}

pub fn is_peer_banned_test() {
  let manager = ban_manager.ban_manager_new()
    |> ban_manager.ban_peer("peer1", "Test ban", 1000, 3600)

  // Banned at time 2000
  ban_manager.is_peer_banned(manager, "peer1", 2000) |> should.equal(True)

  // Not banned at time 5000 (expired)
  ban_manager.is_peer_banned(manager, "peer1", 5000) |> should.equal(False)

  // Different peer is not banned
  ban_manager.is_peer_banned(manager, "peer2", 2000) |> should.equal(False)
}

pub fn is_ip_banned_test() {
  let manager = ban_manager.ban_manager_new()
    |> ban_manager.ban_ip("192.168.1.1", "Test ban", 1000, 3600)

  // Banned at time 2000
  ban_manager.is_ip_banned(manager, "192.168.1.1", 2000) |> should.equal(True)

  // Different IP is not banned
  ban_manager.is_ip_banned(manager, "192.168.1.2", 2000) |> should.equal(False)
}

pub fn unban_peer_test() {
  let manager = ban_manager.ban_manager_new()
    |> ban_manager.ban_peer("peer1", "Test ban", 1000, 3600)

  // Initially banned
  ban_manager.is_peer_banned(manager, "peer1", 2000) |> should.equal(True)

  // After unbanning
  let unbanned = ban_manager.unban_peer(manager, "peer1")
  ban_manager.is_peer_banned(unbanned, "peer1", 2000) |> should.equal(False)
}

pub fn unban_ip_test() {
  let manager = ban_manager.ban_manager_new()
    |> ban_manager.ban_ip("192.168.1.1", "Test ban", 1000, 3600)

  // Initially banned
  ban_manager.is_ip_banned(manager, "192.168.1.1", 2000) |> should.equal(True)

  // After unbanning
  let unbanned = ban_manager.unban_ip(manager, "192.168.1.1")
  ban_manager.is_ip_banned(unbanned, "192.168.1.1", 2000) |> should.equal(False)
}

pub fn cleanup_expired_bans_test() {
  let manager = ban_manager.ban_manager_new()
    |> ban_manager.ban_peer("peer1", "Short ban", 1000, 100)
    |> ban_manager.ban_peer("peer2", "Long ban", 1000, 10000)

  // At time 1500, peer1's ban has expired but peer2's hasn't
  let cleaned = ban_manager.cleanup_expired_bans(manager, 1500)

  ban_manager.is_peer_banned(cleaned, "peer1", 1500) |> should.equal(False)
  ban_manager.is_peer_banned(cleaned, "peer2", 1500) |> should.equal(True)

  let stats = ban_manager.get_stats(cleaned)
  stats.expired_bans |> should.equal(1)
}

pub fn get_active_bans_test() {
  let manager = ban_manager.ban_manager_new()
    |> ban_manager.ban_peer("peer1", "Ban 1", 1000, 3600)
    |> ban_manager.ban_ip("192.168.1.1", "Ban 2", 1000, 3600)

  let active = ban_manager.get_active_bans(manager, 2000)
  list.length(active) |> should.equal(2)
}

pub fn get_stats_test() {
  let manager = ban_manager.ban_manager_new()
    |> ban_manager.ban_peer("peer1", "Manual", 1000, 3600)

  let #(m2, _) = ban_manager.record_misbehavior(
    manager,
    "peer2",
    ban_manager.InvalidBlockHeader,
    1000,
  )

  let stats = ban_manager.get_stats(m2)
  stats.total_incidents |> should.equal(1)
  stats.auto_bans |> should.equal(1)
  // Note: manual ban was on original manager, not m2
}

// ============================================================================
// Export/Import Tests
// ============================================================================

pub fn export_import_bans_test() {
  let manager = ban_manager.ban_manager_new()
    |> ban_manager.ban_peer("peer1", "Test", 1000, 3600)
    |> ban_manager.ban_ip("192.168.1.1", "Test2", 1000, 7200)

  // Export at time 2000
  let exports = ban_manager.export_bans(manager, 2000)
  list.length(exports) |> should.equal(2)

  // Import into new manager
  let new_manager = ban_manager.ban_manager_new()
  let imported = ban_manager.import_bans(new_manager, exports, 2000)

  // Bans should be restored
  ban_manager.is_peer_banned(imported, "peer1", 2000) |> should.equal(True)
  ban_manager.is_ip_banned(imported, "192.168.1.1", 2000) |> should.equal(True)
}

pub fn export_skips_expired_test() {
  let manager = ban_manager.ban_manager_new()
    |> ban_manager.ban_peer("peer1", "Short", 1000, 100)
    |> ban_manager.ban_peer("peer2", "Long", 1000, 10000)

  // Export at time 2000 - peer1's ban has expired
  let exports = ban_manager.export_bans(manager, 2000)
  list.length(exports) |> should.equal(1)

  // Only peer2 should be exported
  case list.first(exports) {
    Ok(export) -> export.identifier |> should.equal("peer2")
    Error(_) -> should.fail()
  }
}

pub fn import_skips_expired_test() {
  let exports = [
    ban_manager.BanExport(
      identifier: "peer1",
      ban_type: ban_manager.PeerBan,
      ban_time: 1000,
      duration: 100,  // Already expired at import time
      reason: "Expired",
      manual: True,
    ),
    ban_manager.BanExport(
      identifier: "peer2",
      ban_type: ban_manager.PeerBan,
      ban_time: 1000,
      duration: 10000,  // Still active
      reason: "Active",
      manual: True,
    ),
  ]

  let manager = ban_manager.ban_manager_new()
  let imported = ban_manager.import_bans(manager, exports, 2000)

  // Only peer2 should be banned
  ban_manager.is_peer_banned(imported, "peer1", 2000) |> should.equal(False)
  ban_manager.is_peer_banned(imported, "peer2", 2000) |> should.equal(True)
}
