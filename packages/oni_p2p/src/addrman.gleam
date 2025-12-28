// addrman.gleam - Address Manager v2 with ASMAP Support
//
// This module provides advanced peer address management:
// - Address storage and lookup with bucketing
// - ASMAP-based AS (Autonomous System) grouping for diversity
// - New/tried table separation for eclipse attack resistance
// - Eviction policies and anchor connections
// - Address source tracking and scoring
//
// The design follows Bitcoin Core's addrman with improvements from:
// - BIP155 (addr v2 with Tor v3, I2P, CJDNS support)
// - ASMAP bucketing for network topology awareness
//
// Reference: https://github.com/bitcoin/bitcoin/blob/master/src/addrman.h

import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/order
import gleam/result
import gleam/string

// ============================================================================
// Constants
// ============================================================================

/// Number of "new" address buckets
pub const new_bucket_count = 1024

/// Number of "tried" address buckets
pub const tried_bucket_count = 256

/// Maximum addresses per bucket
pub const bucket_size = 64

/// Maximum addresses in "new" table (1024 * 64)
pub const max_new_addresses = 65_536

/// Maximum addresses in "tried" table (256 * 64)
pub const max_tried_addresses = 16_384

/// Default lifetime of addresses (30 days in seconds = 30 * 24 * 60 * 60)
pub const address_lifetime_sec = 2_592_000

/// Time between retries after failed connection (seconds)
pub const retry_interval_sec = 600

/// Maximum connection attempts before marking unreachable
pub const max_connection_attempts = 3

/// Default ASMAP bucket diversity target
pub const asmap_diversity_target = 4

// ============================================================================
// Core Types
// ============================================================================

/// Network address types (BIP155)
pub type NetworkType {
  /// IPv4
  IPv4
  /// IPv6
  IPv6
  /// Tor v2 (deprecated)
  TorV2
  /// Tor v3 (.onion)
  TorV3
  /// I2P
  I2P
  /// CJDNS
  CJDNS
  /// Unknown network
  Unknown
}

/// Network address with metadata
pub type NetAddress {
  NetAddress(
    /// Network type
    network: NetworkType,
    /// Address bytes (length depends on network type)
    addr: BitArray,
    /// Port number
    port: Int,
    /// Services offered
    services: Int,
    /// Last seen timestamp
    last_seen: Int,
    /// Last connection attempt
    last_attempt: Int,
    /// Number of connection attempts
    attempts: Int,
    /// Source of this address (who sent it)
    source: Option(BitArray),
    /// Reference count (how many times received)
    ref_count: Int,
    /// Random key for bucketing
    random_key: Int,
    /// Is address currently connected
    is_connected: Bool,
    /// AS number (from ASMAP)
    asn: Option(Int),
  )
}

/// Address info for external API
pub type AddressInfo {
  AddressInfo(
    addr: String,
    port: Int,
    services: Int,
    last_seen: Int,
    source: String,
    network: String,
    is_tried: Bool,
  )
}

/// Address table type
pub type TableType {
  NewTable
  TriedTable
}

/// ASMAP data for AS number lookups
pub type ASMap {
  ASMap(
    /// Version
    version: Int,
    /// Number of entries
    entries: Int,
    /// Compressed trie data
    data: BitArray,
    /// Cached lookups for performance
    cache: Dict(BitArray, Int),
  )
}

/// Address manager state
pub type AddressManager {
  AddressManager(
    /// "New" address buckets
    new_buckets: Dict(Int, Dict(String, NetAddress)),
    /// "Tried" address buckets
    tried_buckets: Dict(Int, Dict(String, NetAddress)),
    /// All addresses by key (for O(1) lookup)
    all_addresses: Dict(String, NetAddress),
    /// ASMAP for AS bucketing
    asmap: Option(ASMap),
    /// Random nonce for bucket placement
    nonce: BitArray,
    /// Statistics
    stats: AddressManagerStats,
  )
}

/// Address manager statistics
pub type AddressManagerStats {
  AddressManagerStats(
    /// Total addresses in new table
    new_count: Int,
    /// Total addresses in tried table
    tried_count: Int,
    /// Addresses added
    added_count: Int,
    /// Addresses evicted
    evicted_count: Int,
    /// Successful connections
    successful_connections: Int,
    /// Failed connections
    failed_connections: Int,
    /// Unique AS numbers seen
    unique_asns: Int,
  )
}

// ============================================================================
// Address Manager Creation
// ============================================================================

/// Create a new address manager
pub fn new() -> AddressManager {
  AddressManager(
    new_buckets: init_buckets(new_bucket_count),
    tried_buckets: init_buckets(tried_bucket_count),
    all_addresses: dict.new(),
    asmap: None,
    nonce: generate_nonce(),
    stats: AddressManagerStats(
      new_count: 0,
      tried_count: 0,
      added_count: 0,
      evicted_count: 0,
      successful_connections: 0,
      failed_connections: 0,
      unique_asns: 0,
    ),
  )
}

/// Create address manager with ASMAP
pub fn new_with_asmap(asmap: ASMap) -> AddressManager {
  AddressManager(..new(), asmap: Some(asmap))
}

fn init_buckets(count: Int) -> Dict(Int, Dict(String, NetAddress)) {
  init_buckets_recursive(0, count, dict.new())
}

fn init_buckets_recursive(
  current: Int,
  count: Int,
  acc: Dict(Int, Dict(String, NetAddress)),
) -> Dict(Int, Dict(String, NetAddress)) {
  case current >= count {
    True -> acc
    False -> {
      let new_acc = dict.insert(acc, current, dict.new())
      init_buckets_recursive(current + 1, count, new_acc)
    }
  }
}

fn generate_nonce() -> BitArray {
  // In production, use cryptographically secure random
  <<0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde, 0xf0,
    0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88>>
}

// ============================================================================
// Address Operations
// ============================================================================

/// Add a new address
pub fn add_address(
  manager: AddressManager,
  addr: NetAddress,
  source: Option(BitArray),
  current_time: Int,
) -> AddressManager {
  let key = address_key(addr)

  // Check if address already exists
  case dict.get(manager.all_addresses, key) {
    Ok(existing) -> {
      // Update existing address
      let updated = NetAddress(
        ..existing,
        last_seen: int.max(existing.last_seen, addr.last_seen),
        ref_count: existing.ref_count + 1,
        services: int.bitwise_or(existing.services, addr.services),
      )
      let new_all = dict.insert(manager.all_addresses, key, updated)
      AddressManager(..manager, all_addresses: new_all)
    }
    Error(_) -> {
      // New address - add to new table
      let addr_with_meta = NetAddress(
        ..addr,
        source: source,
        last_seen: current_time,
        random_key: hash_for_random(key, manager.nonce),
        asn: lookup_asn(manager.asmap, addr),
      )

      // Calculate bucket for new table
      let bucket = new_bucket(addr_with_meta, source, manager.nonce)

      // Add to bucket (with eviction if needed)
      let #(new_buckets, evicted) = add_to_bucket(
        manager.new_buckets,
        bucket,
        key,
        addr_with_meta,
      )

      // Update all_addresses
      let new_all = dict.insert(manager.all_addresses, key, addr_with_meta)
      let new_all = case evicted {
        Some(evicted_key) -> dict.delete(new_all, evicted_key)
        None -> new_all
      }

      let new_stats = AddressManagerStats(
        ..manager.stats,
        new_count: manager.stats.new_count + 1,
        added_count: manager.stats.added_count + 1,
        evicted_count: manager.stats.evicted_count + case evicted {
          Some(_) -> 1
          None -> 0
        },
      )

      AddressManager(
        ..manager,
        new_buckets: new_buckets,
        all_addresses: new_all,
        stats: new_stats,
      )
    }
  }
}

/// Mark address as successfully connected (move to tried)
pub fn mark_good(
  manager: AddressManager,
  addr: NetAddress,
  current_time: Int,
) -> AddressManager {
  let key = address_key(addr)

  case dict.get(manager.all_addresses, key) {
    Error(_) -> manager  // Unknown address
    Ok(existing) -> {
      // Update address
      let updated = NetAddress(
        ..existing,
        last_seen: current_time,
        last_attempt: current_time,
        attempts: 0,
        is_connected: True,
      )

      // Move to tried table
      move_to_tried(manager, key, updated)
    }
  }
}

/// Mark address as connection failed
pub fn mark_bad(
  manager: AddressManager,
  addr: NetAddress,
  current_time: Int,
) -> AddressManager {
  let key = address_key(addr)

  case dict.get(manager.all_addresses, key) {
    Error(_) -> manager
    Ok(existing) -> {
      let updated = NetAddress(
        ..existing,
        last_attempt: current_time,
        attempts: existing.attempts + 1,
        is_connected: False,
      )

      // Remove if too many failures
      case updated.attempts >= max_connection_attempts {
        True -> remove_address(manager, key)
        False -> {
          let new_all = dict.insert(manager.all_addresses, key, updated)
          let new_stats = AddressManagerStats(
            ..manager.stats,
            failed_connections: manager.stats.failed_connections + 1,
          )
          AddressManager(..manager, all_addresses: new_all, stats: new_stats)
        }
      }
    }
  }
}

/// Remove an address
fn remove_address(manager: AddressManager, key: String) -> AddressManager {
  // Remove from all tables
  let new_all = dict.delete(manager.all_addresses, key)

  // Remove from new buckets
  let new_buckets = remove_from_all_buckets(manager.new_buckets, key)

  // Remove from tried buckets
  let tried_buckets = remove_from_all_buckets(manager.tried_buckets, key)

  AddressManager(
    ..manager,
    new_buckets: new_buckets,
    tried_buckets: tried_buckets,
    all_addresses: new_all,
  )
}

fn remove_from_all_buckets(
  buckets: Dict(Int, Dict(String, NetAddress)),
  key: String,
) -> Dict(Int, Dict(String, NetAddress)) {
  dict.map_values(buckets, fn(_bucket_id, bucket) {
    dict.delete(bucket, key)
  })
}

/// Move address from new to tried table
fn move_to_tried(
  manager: AddressManager,
  key: String,
  addr: NetAddress,
) -> AddressManager {
  // Remove from new table
  let new_buckets = remove_from_all_buckets(manager.new_buckets, key)

  // Calculate tried bucket
  let bucket = tried_bucket(addr, manager.nonce)

  // Add to tried bucket
  let #(tried_buckets, evicted) = add_to_bucket(
    manager.tried_buckets,
    bucket,
    key,
    addr,
  )

  // Handle eviction (move evicted back to new)
  let #(new_buckets, all_addresses) = case evicted {
    None -> #(new_buckets, dict.insert(manager.all_addresses, key, addr))
    Some(evicted_key) -> {
      case dict.get(manager.all_addresses, evicted_key) {
        Error(_) -> #(new_buckets, dict.insert(manager.all_addresses, key, addr))
        Ok(evicted_addr) -> {
          // Move evicted to new table
          let evicted_bucket = new_bucket(evicted_addr, evicted_addr.source, manager.nonce)
          let #(updated_new, _) = add_to_bucket(new_buckets, evicted_bucket, evicted_key, evicted_addr)
          let updated_all = dict.insert(manager.all_addresses, key, addr)
          #(updated_new, updated_all)
        }
      }
    }
  }

  let new_stats = AddressManagerStats(
    ..manager.stats,
    tried_count: manager.stats.tried_count + 1,
    new_count: int.max(0, manager.stats.new_count - 1),
    successful_connections: manager.stats.successful_connections + 1,
  )

  AddressManager(
    ..manager,
    new_buckets: new_buckets,
    tried_buckets: tried_buckets,
    all_addresses: all_addresses,
    stats: new_stats,
  )
}

// ============================================================================
// Address Selection
// ============================================================================

/// Select an address to connect to
pub fn select(
  manager: AddressManager,
  current_time: Int,
  new_only: Bool,
) -> Option(NetAddress) {
  // Prefer tried addresses (70% of the time) unless new_only
  let prefer_tried = !new_only && hash_to_percent(manager.nonce) < 70

  case prefer_tried {
    True -> {
      case select_from_tried(manager, current_time) {
        Some(addr) -> Some(addr)
        None -> select_from_new(manager, current_time)
      }
    }
    False -> {
      case select_from_new(manager, current_time) {
        Some(addr) -> Some(addr)
        None -> {
          case new_only {
            True -> None
            False -> select_from_tried(manager, current_time)
          }
        }
      }
    }
  }
}

/// Select address from new table
fn select_from_new(
  manager: AddressManager,
  current_time: Int,
) -> Option(NetAddress) {
  select_from_table(manager.new_buckets, manager.nonce, current_time)
}

/// Select address from tried table
fn select_from_tried(
  manager: AddressManager,
  current_time: Int,
) -> Option(NetAddress) {
  select_from_table(manager.tried_buckets, manager.nonce, current_time)
}

fn select_from_table(
  buckets: Dict(Int, Dict(String, NetAddress)),
  nonce: BitArray,
  current_time: Int,
) -> Option(NetAddress) {
  let bucket_count = dict.size(buckets)
  case bucket_count {
    0 -> None
    _ -> {
      // Select random bucket
      let bucket_id = hash_to_int(nonce, current_time) % bucket_count

      case dict.get(buckets, bucket_id) {
        Error(_) -> None
        Ok(bucket) -> {
          let candidates = dict.values(bucket)
            |> list.filter(fn(addr) { is_selectable(addr, current_time) })

          case candidates {
            [] -> None
            [first, ..] -> Some(first)
          }
        }
      }
    }
  }
}

/// Check if address is selectable for connection
fn is_selectable(addr: NetAddress, current_time: Int) -> Bool {
  // Not already connected
  !addr.is_connected
  // Not recently attempted
  && current_time - addr.last_attempt >= retry_interval_sec
  // Not stale
  && current_time - addr.last_seen < address_lifetime_sec
}

/// Select multiple diverse addresses
pub fn select_diverse(
  manager: AddressManager,
  count: Int,
  current_time: Int,
) -> List(NetAddress) {
  select_diverse_impl(manager, count, current_time, [], dict.new())
}

fn select_diverse_impl(
  manager: AddressManager,
  remaining: Int,
  current_time: Int,
  selected: List(NetAddress),
  seen_asns: Dict(Int, Int),
) -> List(NetAddress) {
  case remaining <= 0 {
    True -> list.reverse(selected)
    False -> {
      case select(manager, current_time, False) {
        None -> list.reverse(selected)
        Some(addr) -> {
          // Check ASN diversity
          let should_add = case addr.asn {
            None -> True
            Some(asn) -> {
              case dict.get(seen_asns, asn) {
                Error(_) -> True
                Ok(count) -> count < asmap_diversity_target
              }
            }
          }

          case should_add {
            False -> select_diverse_impl(manager, remaining, current_time + 1, selected, seen_asns)
            True -> {
              let new_seen = case addr.asn {
                None -> seen_asns
                Some(asn) -> {
                  let current_count = result.unwrap(dict.get(seen_asns, asn), 0)
                  dict.insert(seen_asns, asn, current_count + 1)
                }
              }
              select_diverse_impl(manager, remaining - 1, current_time + 1, [addr, ..selected], new_seen)
            }
          }
        }
      }
    }
  }
}

// ============================================================================
// ASMAP Operations
// ============================================================================

/// Load ASMAP from file data
pub fn load_asmap(data: BitArray) -> Result(ASMap, String) {
  case data {
    <<version:32-little, entries:32-little, rest:bits>> -> {
      Ok(ASMap(
        version: version,
        entries: entries,
        data: rest,
        cache: dict.new(),
      ))
    }
    _ -> Error("Invalid ASMAP format")
  }
}

/// Lookup AS number for an address
fn lookup_asn(asmap: Option(ASMap), addr: NetAddress) -> Option(Int) {
  case asmap {
    None -> None
    Some(map) -> {
      // Only IPv4/IPv6 have AS numbers
      case addr.network {
        IPv4 | IPv6 -> lookup_asn_impl(map, addr.addr)
        _ -> None
      }
    }
  }
}

fn lookup_asn_impl(asmap: ASMap, addr: BitArray) -> Option(Int) {
  // Check cache first
  case dict.get(asmap.cache, addr) {
    Ok(asn) -> Some(asn)
    Error(_) -> {
      // Lookup in trie (simplified)
      case decode_asn_from_trie(asmap.data, addr) {
        Error(_) -> None
        Ok(asn) -> Some(asn)
      }
    }
  }
}

fn decode_asn_from_trie(_trie_data: BitArray, _addr: BitArray) -> Result(Int, Nil) {
  // Simplified - in production would walk the compressed trie
  // Return a hash-based ASN for simulation
  Error(Nil)
}

/// Get AS diversity statistics
pub fn get_as_diversity(manager: AddressManager) -> Dict(Int, Int) {
  dict.fold(manager.all_addresses, dict.new(), fn(acc, _key, addr) {
    case addr.asn {
      None -> acc
      Some(asn) -> {
        let count = result.unwrap(dict.get(acc, asn), 0)
        dict.insert(acc, asn, count + 1)
      }
    }
  })
}

// ============================================================================
// Bucket Calculations
// ============================================================================

/// Calculate new table bucket for an address
fn new_bucket(
  addr: NetAddress,
  source: Option(BitArray),
  nonce: BitArray,
) -> Int {
  // Use source group and address group for bucketing
  let source_group = case source {
    None -> <<0, 0, 0, 0>>
    Some(s) -> s
  }
  let addr_group = address_group(addr)

  let hash_input = bit_array.concat([nonce, source_group, addr_group])
  let hash = simple_hash(hash_input)

  int.modulo(hash, new_bucket_count)
  |> result.unwrap(0)
}

/// Calculate tried table bucket for an address
fn tried_bucket(addr: NetAddress, nonce: BitArray) -> Int {
  let addr_group = address_group(addr)
  let hash_input = bit_array.concat([nonce, addr_group])
  let hash = simple_hash(hash_input)

  int.modulo(hash, tried_bucket_count)
  |> result.unwrap(0)
}

/// Get address group (for bucketing)
fn address_group(addr: NetAddress) -> BitArray {
  case addr.network {
    IPv4 -> {
      // /16 prefix for IPv4
      case addr.addr {
        <<a:8, b:8, _:bits>> -> <<a, b>>
        _ -> <<0, 0>>
      }
    }
    IPv6 -> {
      // /32 prefix for IPv6
      case addr.addr {
        <<a:8, b:8, c:8, d:8, _:bits>> -> <<a, b, c, d>>
        _ -> <<0, 0, 0, 0>>
      }
    }
    TorV3 -> {
      // First 4 bytes of onion address
      case addr.addr {
        <<a:8, b:8, c:8, d:8, _:bits>> -> <<a, b, c, d>>
        _ -> <<0, 0, 0, 0>>
      }
    }
    _ -> <<0, 0, 0, 0>>
  }
}

// ============================================================================
// Bucket Operations
// ============================================================================

/// Add address to bucket with eviction
fn add_to_bucket(
  buckets: Dict(Int, Dict(String, NetAddress)),
  bucket_id: Int,
  key: String,
  addr: NetAddress,
) -> #(Dict(Int, Dict(String, NetAddress)), Option(String)) {
  case dict.get(buckets, bucket_id) {
    Error(_) -> {
      // Create new bucket
      let new_bucket = dict.insert(dict.new(), key, addr)
      #(dict.insert(buckets, bucket_id, new_bucket), None)
    }
    Ok(bucket) -> {
      case dict.size(bucket) >= bucket_size {
        False -> {
          // Room in bucket
          let new_bucket = dict.insert(bucket, key, addr)
          #(dict.insert(buckets, bucket_id, new_bucket), None)
        }
        True -> {
          // Need to evict
          let evicted = select_for_eviction(bucket)
          case evicted {
            None -> #(buckets, None)  // Can't evict, don't add
            Some(evicted_key) -> {
              let new_bucket = dict.delete(bucket, evicted_key)
              let new_bucket = dict.insert(new_bucket, key, addr)
              #(dict.insert(buckets, bucket_id, new_bucket), Some(evicted_key))
            }
          }
        }
      }
    }
  }
}

/// Select address for eviction from a full bucket
fn select_for_eviction(bucket: Dict(String, NetAddress)) -> Option(String) {
  let entries = dict.to_list(bucket)

  // Sort by last_seen (oldest first)
  let sorted = list.sort(entries, fn(a, b) {
    let #(_, addr_a) = a
    let #(_, addr_b) = b
    int.compare(addr_a.last_seen, addr_b.last_seen)
  })

  case sorted {
    [] -> None
    [#(key, _), ..] -> Some(key)
  }
}

// ============================================================================
// Persistence
// ============================================================================

/// Serialize address manager for persistence
pub fn serialize(manager: AddressManager) -> BitArray {
  let addresses = dict.values(manager.all_addresses)
  let count = list.length(addresses)

  let header = <<count:32-little>>

  let addr_data = list.fold(addresses, <<>>, fn(acc, addr) {
    bit_array.concat([acc, serialize_address(addr)])
  })

  bit_array.concat([header, manager.nonce, addr_data])
}

fn serialize_address(addr: NetAddress) -> BitArray {
  let network_byte = network_to_byte(addr.network)
  let addr_len = bit_array.byte_size(addr.addr)

  <<
    network_byte:8,
    addr_len:8,
    addr.addr:bits,
    addr.port:16-little,
    addr.services:64-little,
    addr.last_seen:64-little,
    addr.last_attempt:64-little,
    addr.attempts:32-little,
    addr.ref_count:32-little,
  >>
}

/// Deserialize address manager from persistence
pub fn deserialize(data: BitArray) -> Result(AddressManager, String) {
  case data {
    <<count:32-little, nonce:bytes-size(16), rest:bits>> -> {
      case deserialize_addresses(rest, count, []) {
        Error(e) -> Error(e)
        Ok(addresses) -> {
          let manager = AddressManager(..new(), nonce: nonce)

          // Add all addresses
          let final_manager = list.fold(addresses, manager, fn(mgr, addr) {
            add_address(mgr, addr, None, addr.last_seen)
          })

          Ok(final_manager)
        }
      }
    }
    _ -> Error("Invalid address manager data")
  }
}

fn deserialize_addresses(
  data: BitArray,
  remaining: Int,
  acc: List(NetAddress),
) -> Result(List(NetAddress), String) {
  case remaining {
    0 -> Ok(list.reverse(acc))
    _ -> {
      case deserialize_single_address(data) {
        Error(e) -> Error(e)
        Ok(#(addr, rest)) -> {
          deserialize_addresses(rest, remaining - 1, [addr, ..acc])
        }
      }
    }
  }
}

fn deserialize_single_address(data: BitArray) -> Result(#(NetAddress, BitArray), String) {
  case data {
    <<network_byte:8, addr_len:8, rest:bits>> -> {
      case extract_bytes(rest, addr_len) {
        Error(_) -> Error("Invalid address data")
        Ok(#(addr_bytes, rest2)) -> {
          case rest2 {
            <<port:16-little, services:64-little,
              last_seen:64-little, last_attempt:64-little,
              attempts:32-little, ref_count:32-little,
              remaining:bits>> -> {
              let addr = NetAddress(
                network: byte_to_network(network_byte),
                addr: addr_bytes,
                port: port,
                services: services,
                last_seen: last_seen,
                last_attempt: last_attempt,
                attempts: attempts,
                source: None,
                ref_count: ref_count,
                random_key: 0,
                is_connected: False,
                asn: None,
              )
              Ok(#(addr, remaining))
            }
            _ -> Error("Invalid address metadata")
          }
        }
      }
    }
    _ -> Error("Invalid address header")
  }
}

// ============================================================================
// Utility Functions
// ============================================================================

/// Get address string key
fn address_key(addr: NetAddress) -> String {
  let addr_hex = bit_array_to_hex(addr.addr)
  addr_hex <> ":" <> int.to_string(addr.port)
}

/// Get address info for display
pub fn get_address_info(addr: NetAddress, is_tried: Bool) -> AddressInfo {
  AddressInfo(
    addr: format_address(addr),
    port: addr.port,
    services: addr.services,
    last_seen: addr.last_seen,
    source: case addr.source {
      None -> ""
      Some(s) -> bit_array_to_hex(s)
    },
    network: network_to_string(addr.network),
    is_tried: is_tried,
  )
}

fn format_address(addr: NetAddress) -> String {
  case addr.network {
    IPv4 -> format_ipv4(addr.addr)
    IPv6 -> format_ipv6(addr.addr)
    TorV3 -> format_onion(addr.addr) <> ".onion"
    _ -> bit_array_to_hex(addr.addr)
  }
}

fn format_ipv4(addr: BitArray) -> String {
  case addr {
    <<a:8, b:8, c:8, d:8>> ->
      int.to_string(a) <> "." <> int.to_string(b) <> "." <>
      int.to_string(c) <> "." <> int.to_string(d)
    _ -> "0.0.0.0"
  }
}

fn format_ipv6(addr: BitArray) -> String {
  // Simplified IPv6 formatting
  bit_array_to_hex(addr)
}

fn format_onion(addr: BitArray) -> String {
  // Base32 encode for onion address
  bit_array_to_hex(addr)
}

fn network_to_string(network: NetworkType) -> String {
  case network {
    IPv4 -> "ipv4"
    IPv6 -> "ipv6"
    TorV2 -> "torv2"
    TorV3 -> "torv3"
    I2P -> "i2p"
    CJDNS -> "cjdns"
    Unknown -> "unknown"
  }
}

fn network_to_byte(network: NetworkType) -> Int {
  case network {
    IPv4 -> 1
    IPv6 -> 2
    TorV2 -> 3
    TorV3 -> 4
    I2P -> 5
    CJDNS -> 6
    Unknown -> 0
  }
}

fn byte_to_network(b: Int) -> NetworkType {
  case b {
    1 -> IPv4
    2 -> IPv6
    3 -> TorV2
    4 -> TorV3
    5 -> I2P
    6 -> CJDNS
    _ -> Unknown
  }
}

fn simple_hash(data: BitArray) -> Int {
  // Simple hash for bucketing
  hash_impl(data, 0)
}

fn hash_impl(data: BitArray, acc: Int) -> Int {
  case data {
    <<byte:8, rest:bits>> -> {
      let new_acc = int.bitwise_exclusive_or(acc * 31, byte)
      hash_impl(rest, new_acc)
    }
    _ -> int.absolute_value(acc)
  }
}

fn hash_for_random(key: String, nonce: BitArray) -> Int {
  let key_bytes = <<key:utf8>>
  simple_hash(bit_array.concat([nonce, key_bytes]))
}

fn hash_to_percent(nonce: BitArray) -> Int {
  int.modulo(simple_hash(nonce), 100)
  |> result.unwrap(50)
}

fn hash_to_int(nonce: BitArray, extra: Int) -> Int {
  simple_hash(bit_array.concat([nonce, <<extra:32>>]))
}

fn extract_bytes(data: BitArray, n: Int) -> Result(#(BitArray, BitArray), Nil) {
  case bit_array.slice(data, 0, n) {
    Error(_) -> Error(Nil)
    Ok(extracted) -> {
      let remaining = bit_array.byte_size(data) - n
      case remaining > 0 {
        True -> {
          case bit_array.slice(data, n, remaining) {
            Error(_) -> Ok(#(extracted, <<>>))
            Ok(rest) -> Ok(#(extracted, rest))
          }
        }
        False -> Ok(#(extracted, <<>>))
      }
    }
  }
}

fn bit_array_to_hex(data: BitArray) -> String {
  bit_array_to_hex_impl(data, "")
}

fn bit_array_to_hex_impl(data: BitArray, acc: String) -> String {
  case data {
    <<byte:8, rest:bits>> -> {
      let hex = int.to_base16(byte)
      let padded = case string.length(hex) {
        1 -> "0" <> hex
        _ -> hex
      }
      bit_array_to_hex_impl(rest, acc <> padded)
    }
    _ -> acc
  }
}

// ============================================================================
// Statistics
// ============================================================================

/// Get address manager statistics
pub fn get_stats(manager: AddressManager) -> AddressManagerStats {
  manager.stats
}

/// Get total address count
pub fn count(manager: AddressManager) -> Int {
  dict.size(manager.all_addresses)
}

/// Get count by network type
pub fn count_by_network(manager: AddressManager) -> Dict(String, Int) {
  dict.fold(manager.all_addresses, dict.new(), fn(acc, _key, addr) {
    let network = network_to_string(addr.network)
    let count = result.unwrap(dict.get(acc, network), 0)
    dict.insert(acc, network, count + 1)
  })
}

/// List all addresses for debugging
pub fn list_all(manager: AddressManager) -> List(AddressInfo) {
  dict.to_list(manager.all_addresses)
  |> list.map(fn(pair) {
    let #(_key, addr) = pair
    let is_tried = is_in_tried(manager, addr)
    get_address_info(addr, is_tried)
  })
}

fn is_in_tried(manager: AddressManager, addr: NetAddress) -> Bool {
  let key = address_key(addr)
  dict.fold(manager.tried_buckets, False, fn(acc, _bucket_id, bucket) {
    acc || dict.has_key(bucket, key)
  })
}
