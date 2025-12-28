// addr_persistence.gleam - Address manager persistence
//
// This module handles saving and loading peer addresses to disk for:
// - Fast peer discovery on restart
// - Preserving reputation/quality information
// - Maintaining connection history
//
// The format is designed to be compact and easily extensible.

import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/result
import gleam/string
import oni_p2p.{
  type AddrEntry, type AddrManager, type IpAddr, type NetAddr,
  AddrEntry, AddrManager, IPv4, IPv6, NetAddr,
}

// ============================================================================
// Constants
// ============================================================================

/// Magic bytes to identify the file format
const file_magic = "ONIADDRV1"

/// Current format version
pub const format_version = 1

/// Maximum file size (10MB)
pub const max_file_size = 10_000_000

/// Maximum number of addresses to persist
pub const max_persisted_addrs = 50_000

// ============================================================================
// Serialization Format
// ============================================================================

/// Serialize address manager to binary format
pub fn serialize(manager: AddrManager) -> BitArray {
  let entries = dict.values(manager.addrs)

  // Limit to max persisted addresses, prioritizing recent successful connections
  let sorted = list.sort(entries, fn(a, b) {
    // Higher last_success first
    int.compare(b.last_success, a.last_success)
  })
  let limited = list.take(sorted, max_persisted_addrs)

  // Build header
  let magic = string.to_utf_codepoints(file_magic)
    |> list.map(string.utf_codepoint_to_int)
    |> list.fold(<<>>, fn(acc, cp) { bit_array.append(acc, <<cp:8>>) })

  let entry_count = list.length(limited)

  // Serialize entries
  let entries_data = list.fold(limited, <<>>, fn(acc, entry) {
    bit_array.append(acc, serialize_entry(entry))
  })

  bit_array.concat([
    magic,
    <<format_version:32-little>>,
    <<entry_count:32-little>>,
    entries_data,
  ])
}

/// Serialize a single address entry
fn serialize_entry(entry: AddrEntry) -> BitArray {
  let services = oni_p2p.service_flags_to_int(entry.addr.services)
  let ip_data = serialize_ip(entry.addr.ip)
  let port = entry.addr.port

  bit_array.concat([
    <<services:64-little>>,
    ip_data,
    <<port:16-big>>,
    <<entry.last_try:64-little>>,
    <<entry.last_success:64-little>>,
    <<entry.attempts:32-little>>,
    <<entry.ref_count:32-little>>,
  ])
}

/// Serialize IP address
fn serialize_ip(ip: IpAddr) -> BitArray {
  case ip {
    IPv4(a, b, c, d) -> {
      // IPv4 as IPv4-mapped IPv6: ::ffff:a.b.c.d
      <<0:80, 0xffff:16, a:8, b:8, c:8, d:8>>
    }
    IPv6(bytes) -> {
      case bit_array.byte_size(bytes) == 16 {
        True -> bytes
        False -> <<0:128>>  // Invalid, use zeros
      }
    }
  }
}

/// Deserialize address manager from binary format
pub fn deserialize(data: BitArray) -> Result(AddrManager, PersistenceError) {
  // Check file size
  case bit_array.byte_size(data) > max_file_size {
    True -> Error(FileTooLarge)
    False -> do_deserialize(data)
  }
}

fn do_deserialize(data: BitArray) -> Result(AddrManager, PersistenceError) {
  // Parse magic
  let magic_len = string.length(file_magic)
  case bit_array.slice(data, 0, magic_len) {
    Error(_) -> Error(InvalidFormat)
    Ok(magic_bytes) -> {
      case check_magic(magic_bytes) {
        False -> Error(InvalidMagic)
        True -> {
          // Parse header
          case bit_array.slice(data, magic_len, 8) {
            Error(_) -> Error(InvalidFormat)
            Ok(header) -> {
              case header {
                <<version:32-little, count:32-little>> -> {
                  case version != format_version {
                    True -> Error(UnsupportedVersion(version))
                    False -> {
                      // Parse entries
                      let entries_offset = magic_len + 8
                      case bit_array.slice(data, entries_offset, bit_array.byte_size(data) - entries_offset) {
                        Error(_) -> Error(InvalidFormat)
                        Ok(entries_data) ->
                          parse_entries(entries_data, count, dict.new())
                      }
                    }
                  }
                }
                _ -> Error(InvalidFormat)
              }
            }
          }
        }
      }
    }
  }
}

fn check_magic(bytes: BitArray) -> Bool {
  let expected = string.to_utf_codepoints(file_magic)
    |> list.map(string.utf_codepoint_to_int)
    |> list.fold(<<>>, fn(acc, cp) { bit_array.append(acc, <<cp:8>>) })
  bytes == expected
}

/// Entry size in bytes (fixed)
/// 8 (timestamp) + 16 (ip) + 2 (port) + 8 (services) + 8 (last_connect) + 4 (attempts) + 4 (success) = 50 bytes
const entry_size = 50

fn parse_entries(
  data: BitArray,
  remaining: Int,
  acc: Dict(String, AddrEntry),
) -> Result(AddrManager, PersistenceError) {
  case remaining <= 0 {
    True -> {
      let _tried = dict.keys(acc) |> list.take(100)
      Ok(AddrManager(
        addrs: acc,
        tried: [],
        new_addrs: [],
        num_tried: dict.size(acc),
        num_new: 0,
        rand_seed: 0,
      ))
    }
    False -> {
      case parse_single_entry(data) {
        Error(e) -> Error(e)
        Ok(#(entry, rest)) -> {
          let key = oni_p2p.ip_to_string(entry.addr.ip) <> ":" <>
            int.to_string(entry.addr.port)
          let new_acc = dict.insert(acc, key, entry)
          parse_entries(rest, remaining - 1, new_acc)
        }
      }
    }
  }
}

fn parse_single_entry(
  data: BitArray,
) -> Result(#(AddrEntry, BitArray), PersistenceError) {
  case data {
    <<services:64-little, ip_bytes:128-bits, port:16-big,
      last_try:64-little, last_success:64-little,
      attempts:32-little, ref_count:32-little, rest:bits>> -> {
      let ip = parse_ip(<<ip_bytes:128-bits>>)
      let entry = AddrEntry(
        addr: NetAddr(
          services: oni_p2p.service_flags_from_int(services),
          ip: ip,
          port: port,
        ),
        source: ip,  // Use same IP as source for persisted entries
        last_success: last_success,
        last_try: last_try,
        attempts: attempts,
        ref_count: ref_count,
      )
      Ok(#(entry, rest))
    }
    _ -> Error(InvalidFormat)
  }
}

fn parse_ip(data: BitArray) -> IpAddr {
  case data {
    // Check for IPv4-mapped IPv6
    <<0:80, 0xffff:16, a:8, b:8, c:8, d:8>> -> IPv4(a, b, c, d)
    // IPv6
    <<bytes:128-bits>> -> IPv6(<<bytes:128-bits>>)
    _ -> IPv4(0, 0, 0, 0)
  }
}

// ============================================================================
// Error Types
// ============================================================================

pub type PersistenceError {
  InvalidMagic
  InvalidFormat
  UnsupportedVersion(Int)
  FileTooLarge
  IoError(String)
  CorruptData
}

/// Convert error to string
pub fn error_to_string(err: PersistenceError) -> String {
  case err {
    InvalidMagic -> "Invalid file magic"
    InvalidFormat -> "Invalid file format"
    UnsupportedVersion(v) -> "Unsupported version: " <> int.to_string(v)
    FileTooLarge -> "File too large"
    IoError(msg) -> "IO error: " <> msg
    CorruptData -> "Corrupt data"
  }
}

// ============================================================================
// Text Export/Import (Human Readable)
// ============================================================================

/// Export addresses to human-readable text format (one per line)
/// Format: ip:port,services,last_success,last_try,attempts
pub fn export_text(manager: AddrManager) -> String {
  let entries = dict.values(manager.addrs)
  list.map(entries, entry_to_text)
  |> string.join("\n")
}

fn entry_to_text(entry: AddrEntry) -> String {
  let addr_str = oni_p2p.ip_to_string(entry.addr.ip) <> ":" <>
    int.to_string(entry.addr.port)
  let services = int.to_string(oni_p2p.service_flags_to_int(entry.addr.services))

  string.concat([
    addr_str,
    ",",
    services,
    ",",
    int.to_string(entry.last_success),
    ",",
    int.to_string(entry.last_try),
    ",",
    int.to_string(entry.attempts),
  ])
}

/// Import addresses from text format
pub fn import_text(text: String) -> Result(AddrManager, PersistenceError) {
  let lines = string.split(text, "\n")
    |> list.filter(fn(line) { string.length(string.trim(line)) > 0 })

  let entries = list.filter_map(lines, fn(line) {
    case parse_text_line(line) {
      Ok(entry) -> Ok(entry)
      Error(_) -> Error(Nil)
    }
  })

  let addrs = list.fold(entries, dict.new(), fn(acc, entry) {
    let key = oni_p2p.ip_to_string(entry.addr.ip) <> ":" <>
      int.to_string(entry.addr.port)
    dict.insert(acc, key, entry)
  })

  Ok(AddrManager(
    addrs: addrs,
    tried: [],
    new_addrs: [],
    num_tried: dict.size(addrs),
    num_new: 0,
    rand_seed: 0,
  ))
}

fn parse_text_line(line: String) -> Result(AddrEntry, Nil) {
  let parts = string.split(string.trim(line), ",")
  case parts {
    [addr_str, services_str, last_success_str, last_try_str, attempts_str] -> {
      use addr <- result.try(parse_addr_str(addr_str))
      use services <- result.try(parse_int(services_str))
      use last_success <- result.try(parse_int(last_success_str))
      use last_try <- result.try(parse_int(last_try_str))
      use attempts <- result.try(parse_int(attempts_str))

      Ok(AddrEntry(
        addr: NetAddr(
          services: oni_p2p.service_flags_from_int(services),
          ip: addr.ip,
          port: addr.port,
        ),
        source: addr.ip,
        last_success: last_success,
        last_try: last_try,
        attempts: attempts,
        ref_count: 1,
      ))
    }
    _ -> Error(Nil)
  }
}

fn parse_addr_str(addr: String) -> Result(NetAddr, Nil) {
  // Split by last colon (for IPv6 support)
  case string.split(addr, ":") {
    [] -> Error(Nil)
    parts -> {
      let port_str = list.last(parts) |> result.unwrap("0")
      let ip_parts = list.take(parts, list.length(parts) - 1)
      let ip_str = string.join(ip_parts, ":")

      use ip <- result.try(parse_ip_str(ip_str))
      use port <- result.try(parse_int(port_str))

      Ok(NetAddr(
        services: oni_p2p.service_flags_from_int(0),
        ip: ip,
        port: port,
      ))
    }
  }
}

fn parse_ip_str(ip: String) -> Result(IpAddr, Nil) {
  let octets = string.split(ip, ".")
  case octets {
    [a, b, c, d] -> {
      use a_int <- result.try(parse_int(a))
      use b_int <- result.try(parse_int(b))
      use c_int <- result.try(parse_int(c))
      use d_int <- result.try(parse_int(d))

      case a_int >= 0 && a_int <= 255 &&
           b_int >= 0 && b_int <= 255 &&
           c_int >= 0 && c_int <= 255 &&
           d_int >= 0 && d_int <= 255 {
        True -> Ok(IPv4(a_int, b_int, c_int, d_int))
        False -> Error(Nil)
      }
    }
    _ -> Error(Nil)  // IPv6 parsing would go here
  }
}

fn parse_int(s: String) -> Result(Int, Nil) {
  int.parse(string.trim(s))
}

// ============================================================================
// Filtering and Cleanup
// ============================================================================

/// Filter addresses before persisting
pub fn filter_for_persistence(manager: AddrManager) -> AddrManager {
  // Remove addresses that:
  // - Have too many failed attempts
  // - Are too old without success
  // - Are private/local addresses

  let filtered = dict.filter(manager.addrs, fn(_key, entry) {
    let too_many_attempts = entry.attempts > 10
    let is_private = is_private_ip(entry.addr.ip)

    !too_many_attempts && !is_private
  })

  AddrManager(..manager, addrs: filtered)
}

/// Check if an IP is private/local
fn is_private_ip(ip: IpAddr) -> Bool {
  case ip {
    IPv4(10, _, _, _) -> True  // 10.0.0.0/8
    IPv4(172, b, _, _) if b >= 16 && b <= 31 -> True  // 172.16.0.0/12
    IPv4(192, 168, _, _) -> True  // 192.168.0.0/16
    IPv4(127, _, _, _) -> True  // Loopback
    IPv4(0, _, _, _) -> True  // 0.0.0.0/8
    IPv4(169, 254, _, _) -> True  // Link-local
    IPv4(224, _, _, _) -> True  // Multicast
    _ -> False
  }
}

// ============================================================================
// Statistics
// ============================================================================

/// Statistics about persisted addresses
pub type PersistenceStats {
  PersistenceStats(
    total_count: Int,
    with_success: Int,
    with_recent_success: Int,
    ipv4_count: Int,
    ipv6_count: Int,
    serialized_size: Int,
  )
}

/// Calculate persistence statistics
pub fn get_stats(manager: AddrManager, current_time: Int) -> PersistenceStats {
  let entries = dict.values(manager.addrs)
  let recent_threshold = current_time - 86_400 * 7  // 7 days

  let with_success = list.filter(entries, fn(e) { e.last_success > 0 }) |> list.length
  let with_recent = list.filter(entries, fn(e) { e.last_success > recent_threshold }) |> list.length

  let #(ipv4, ipv6) = list.fold(entries, #(0, 0), fn(acc, e) {
    let #(v4, v6) = acc
    case e.addr.ip {
      IPv4(_, _, _, _) -> #(v4 + 1, v6)
      IPv6(_) -> #(v4, v6 + 1)
    }
  })

  // Estimate serialized size
  let header_size = string.length(file_magic) + 8
  let data_size = list.length(entries) * entry_size

  PersistenceStats(
    total_count: list.length(entries),
    with_success: with_success,
    with_recent_success: with_recent,
    ipv4_count: ipv4,
    ipv6_count: ipv6,
    serialized_size: header_size + data_size,
  )
}
