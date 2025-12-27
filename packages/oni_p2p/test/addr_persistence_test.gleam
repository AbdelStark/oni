// addr_persistence_test.gleam - Tests for address manager persistence

import gleam/dict
import gleam/int
import gleam/list
import gleam/string
import gleeunit
import gleeunit/should
import oni_p2p
import oni_p2p/addr_persistence

pub fn main() {
  gleeunit.main()
}

// ============================================================================
// Helper Functions
// ============================================================================

fn make_ipv4(a: Int, b: Int, c: Int, d: Int) -> oni_p2p.IpAddr {
  oni_p2p.IPv4(a, b, c, d)
}

fn make_addr(ip: oni_p2p.IpAddr, port: Int) -> oni_p2p.NetAddr {
  oni_p2p.NetAddr(
    services: oni_p2p.service_flags_from_int(1),
    ip: ip,
    port: port,
  )
}

fn make_entry(
  ip: oni_p2p.IpAddr,
  port: Int,
  last_success: Int,
) -> oni_p2p.AddrEntry {
  oni_p2p.AddrEntry(
    addr: make_addr(ip, port),
    last_try: 1000,
    last_success: last_success,
    attempts: 0,
    ref_count: 1,
  )
}

fn make_manager_with_entries(entries: List(oni_p2p.AddrEntry)) -> oni_p2p.AddrManager {
  let addrs = list.fold(entries, dict.new(), fn(acc, entry) {
    let key = oni_p2p.ip_to_string(entry.addr.ip) <> ":" <>
      int.to_string(entry.addr.port)
    dict.insert(acc, key, entry)
  })

  oni_p2p.AddrManager(
    addrs: addrs,
    tried: [],
    new_addrs: [],
    last_cleanup: 0,
  )
}

// ============================================================================
// Serialization Tests
// ============================================================================

pub fn serialize_empty_manager_test() {
  let manager = oni_p2p.addrman_new()
  let serialized = addr_persistence.serialize(manager)

  // Should have at least magic + version + count
  should.be_true(bit_array.byte_size(serialized) >= 17)
}

pub fn serialize_deserialize_roundtrip_test() {
  let entries = [
    make_entry(make_ipv4(192, 168, 1, 1), 8333, 5000),
    make_entry(make_ipv4(10, 0, 0, 1), 8333, 4000),
    make_entry(make_ipv4(8, 8, 8, 8), 8333, 6000),
  ]

  let manager = make_manager_with_entries(entries)
  let serialized = addr_persistence.serialize(manager)

  case addr_persistence.deserialize(serialized) {
    Error(e) -> {
      should.fail()
    }
    Ok(loaded) -> {
      // Should have all entries
      oni_p2p.addrman_size(loaded) |> should.equal(3)
    }
  }
}

pub fn deserialize_invalid_magic_test() {
  let invalid_data = <<"INVALID__":utf8, 1:32-little, 0:32-little>>

  case addr_persistence.deserialize(invalid_data) {
    Error(addr_persistence.InvalidMagic) -> should.be_true(True)
    _ -> should.fail()
  }
}

pub fn deserialize_empty_data_test() {
  case addr_persistence.deserialize(<<>>) {
    Error(_) -> should.be_true(True)
    Ok(_) -> should.fail()
  }
}

pub fn deserialize_unsupported_version_test() {
  // Magic + wrong version
  let data = <<"ONIADDRV1":utf8, 99:32-little, 0:32-little>>

  case addr_persistence.deserialize(data) {
    Error(addr_persistence.UnsupportedVersion(99)) -> should.be_true(True)
    _ -> should.fail()
  }
}

// ============================================================================
// Text Export/Import Tests
// ============================================================================

pub fn export_text_empty_test() {
  let manager = oni_p2p.addrman_new()
  let text = addr_persistence.export_text(manager)

  text |> should.equal("")
}

pub fn export_text_format_test() {
  let entry = make_entry(make_ipv4(192, 168, 1, 1), 8333, 5000)
  let manager = make_manager_with_entries([entry])

  let text = addr_persistence.export_text(manager)

  // Should contain the address
  should.be_true(string.contains(text, "192.168.1.1:8333"))
}

pub fn import_text_roundtrip_test() {
  let entries = [
    make_entry(make_ipv4(192, 168, 1, 1), 8333, 5000),
    make_entry(make_ipv4(10, 0, 0, 1), 18333, 4000),
  ]

  let manager = make_manager_with_entries(entries)
  let text = addr_persistence.export_text(manager)

  case addr_persistence.import_text(text) {
    Error(_) -> should.fail()
    Ok(loaded) -> {
      oni_p2p.addrman_size(loaded) |> should.equal(2)
    }
  }
}

pub fn import_text_empty_test() {
  case addr_persistence.import_text("") {
    Ok(manager) -> {
      oni_p2p.addrman_size(manager) |> should.equal(0)
    }
    Error(_) -> should.fail()
  }
}

pub fn import_text_with_blank_lines_test() {
  let text = "192.168.1.1:8333,1,5000,1000,0\n\n10.0.0.1:8333,1,4000,1000,0\n"

  case addr_persistence.import_text(text) {
    Ok(manager) -> {
      oni_p2p.addrman_size(manager) |> should.equal(2)
    }
    Error(_) -> should.fail()
  }
}

// ============================================================================
// Filtering Tests
// ============================================================================

pub fn filter_removes_high_attempt_entries_test() {
  let good_entry = oni_p2p.AddrEntry(
    addr: make_addr(make_ipv4(8, 8, 8, 8), 8333),
    last_try: 1000,
    last_success: 5000,
    attempts: 0,
    ref_count: 1,
  )

  let bad_entry = oni_p2p.AddrEntry(
    addr: make_addr(make_ipv4(1, 1, 1, 1), 8333),
    last_try: 1000,
    last_success: 0,
    attempts: 15,  // Too many attempts
    ref_count: 1,
  )

  let manager = make_manager_with_entries([good_entry, bad_entry])
  let filtered = addr_persistence.filter_for_persistence(manager)

  oni_p2p.addrman_size(filtered) |> should.equal(1)
}

pub fn filter_removes_private_addresses_test() {
  let public_entry = make_entry(make_ipv4(8, 8, 8, 8), 8333, 5000)
  let private_10 = make_entry(make_ipv4(10, 0, 0, 1), 8333, 5000)
  let private_172 = make_entry(make_ipv4(172, 16, 0, 1), 8333, 5000)
  let private_192 = make_entry(make_ipv4(192, 168, 1, 1), 8333, 5000)
  let loopback = make_entry(make_ipv4(127, 0, 0, 1), 8333, 5000)

  let manager = make_manager_with_entries([
    public_entry, private_10, private_172, private_192, loopback,
  ])

  let filtered = addr_persistence.filter_for_persistence(manager)

  // Only public address should remain
  oni_p2p.addrman_size(filtered) |> should.equal(1)
}

// ============================================================================
// Statistics Tests
// ============================================================================

pub fn stats_empty_manager_test() {
  let manager = oni_p2p.addrman_new()
  let stats = addr_persistence.get_stats(manager, 10000)

  stats.total_count |> should.equal(0)
  stats.with_success |> should.equal(0)
  stats.ipv4_count |> should.equal(0)
  stats.ipv6_count |> should.equal(0)
}

pub fn stats_with_entries_test() {
  let entries = [
    make_entry(make_ipv4(8, 8, 8, 8), 8333, 5000),
    make_entry(make_ipv4(1, 1, 1, 1), 8333, 6000),
    make_entry(make_ipv4(4, 4, 4, 4), 8333, 0),  // No success
  ]

  let manager = make_manager_with_entries(entries)
  let stats = addr_persistence.get_stats(manager, 10000)

  stats.total_count |> should.equal(3)
  stats.with_success |> should.equal(2)
  stats.ipv4_count |> should.equal(3)
  stats.ipv6_count |> should.equal(0)
  should.be_true(stats.serialized_size > 0)
}

pub fn stats_recent_success_test() {
  let current_time = 1_000_000
  let recent_threshold = current_time - 86_400 * 7  // 7 days

  let entries = [
    make_entry(make_ipv4(8, 8, 8, 8), 8333, current_time - 1000),  // Recent
    make_entry(make_ipv4(1, 1, 1, 1), 8333, current_time - 100_000),  // Old
  ]

  let manager = make_manager_with_entries(entries)
  let stats = addr_persistence.get_stats(manager, current_time)

  stats.with_recent_success |> should.equal(1)
}

// ============================================================================
// Error Handling Tests
// ============================================================================

pub fn error_to_string_test() {
  addr_persistence.error_to_string(addr_persistence.InvalidMagic)
  |> should.equal("Invalid file magic")

  addr_persistence.error_to_string(addr_persistence.UnsupportedVersion(5))
  |> should.equal("Unsupported version: 5")

  addr_persistence.error_to_string(addr_persistence.IoError("test"))
  |> should.equal("IO error: test")
}

// ============================================================================
// IPv6 Tests
// ============================================================================

pub fn serialize_ipv6_address_test() {
  let ipv6_bytes = <<0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1>>
  let entry = oni_p2p.AddrEntry(
    addr: oni_p2p.NetAddr(
      services: oni_p2p.service_flags_from_int(1),
      ip: oni_p2p.IPv6(ipv6_bytes),
      port: 8333,
    ),
    last_try: 1000,
    last_success: 5000,
    attempts: 0,
    ref_count: 1,
  )

  let manager = make_manager_with_entries([entry])
  let serialized = addr_persistence.serialize(manager)

  case addr_persistence.deserialize(serialized) {
    Error(_) -> should.fail()
    Ok(loaded) -> {
      oni_p2p.addrman_size(loaded) |> should.equal(1)
    }
  }
}

// ============================================================================
// Large Dataset Tests
// ============================================================================

pub fn serialize_many_entries_test() {
  // Create 100 entries
  let entries = list.map(list.range(1, 100), fn(n) {
    make_entry(make_ipv4(n, n, n, n), 8333, n * 1000)
  })

  let manager = make_manager_with_entries(entries)
  let serialized = addr_persistence.serialize(manager)

  case addr_persistence.deserialize(serialized) {
    Error(_) -> should.fail()
    Ok(loaded) -> {
      oni_p2p.addrman_size(loaded) |> should.equal(100)
    }
  }
}
