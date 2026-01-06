// fuzz_test.gleam - Fuzzing and boundary tests for P2P message parsing
//
// This module provides security-critical tests for the P2P layer:
// - Malformed message handling (must never crash)
// - Boundary condition testing (max sizes, overflows)
// - Roundtrip encoding/decoding verification
// - Edge cases that commonly lead to vulnerabilities
//
// SECURITY: Network boundary parsing is a critical attack surface.
// All parsing must return Error, never crash.

import gleam/bit_array
import gleam/int
import gleam/list
import gleeunit/should
import oni_bitcoin
import oni_p2p

// ============================================================================
// Constants for testing
// ============================================================================

/// Maximum message size (32MB)
const max_message_size = 33_554_432

/// Maximum inventory items
const max_inv_size = 50_000

/// Maximum addresses
const max_addr_size = 1000

/// Maximum headers
const max_headers_size = 2000

/// Maximum locators
const max_locator_size = 101

// ============================================================================
// Message Framing Boundary Tests
// ============================================================================

pub fn empty_bytes_returns_error_test() {
  // Empty input should return error, not crash
  case oni_p2p.decode_message(<<>>, oni_bitcoin.Mainnet) {
    Error(_) -> should.be_ok(Ok(Nil))
    Ok(_) -> should.fail()
  }
}

pub fn partial_header_returns_error_test() {
  // Less than 24 bytes (header size) should error
  case oni_p2p.decode_message(<<0, 1, 2, 3, 4, 5>>, oni_bitcoin.Mainnet) {
    Error(_) -> should.be_ok(Ok(Nil))
    Ok(_) -> should.fail()
  }
}

pub fn wrong_network_magic_returns_error_test() {
  // Mainnet magic is 0xD9B4BEF9, use wrong magic
  let wrong_magic = <<0xDE, 0xAD, 0xBE, 0xEF>>
  let command = <<"ping", 0, 0, 0, 0, 0, 0, 0, 0>>
  // 12 bytes
  let length = <<8:32-little>>
  // 8 bytes payload
  let checksum = <<0, 0, 0, 0>>
  // Will fail anyway
  let payload = <<12_345:64-little>>
  // nonce

  let msg = bit_array.concat([wrong_magic, command, length, checksum, payload])

  case oni_p2p.decode_message(msg, oni_bitcoin.Mainnet) {
    Error(oni_p2p.InvalidMessage("Wrong network magic")) ->
      should.be_ok(Ok(Nil))
    Error(_) -> should.be_ok(Ok(Nil))
    // Any error is acceptable
    Ok(_) -> should.fail()
  }
}

pub fn invalid_checksum_returns_error_test() {
  // Valid magic but wrong checksum
  let magic = <<0xF9, 0xBE, 0xB4, 0xD9>>
  // Mainnet
  let command = <<"verack", 0, 0, 0, 0, 0, 0>>
  // 12 bytes
  let length = <<0:32-little>>
  // 0 bytes payload
  let checksum = <<0xFF, 0xFF, 0xFF, 0xFF>>
  // Wrong checksum

  let msg = bit_array.concat([magic, command, length, checksum])

  case oni_p2p.decode_message(msg, oni_bitcoin.Mainnet) {
    Error(oni_p2p.InvalidChecksum) -> should.be_ok(Ok(Nil))
    Error(_) -> should.be_ok(Ok(Nil))
    // Any error is acceptable
    Ok(_) -> should.fail()
  }
}

pub fn message_too_large_returns_error_test() {
  // Message claiming to be larger than max_message_size
  let magic = <<0xF9, 0xBE, 0xB4, 0xD9>>
  let command = <<"block", 0, 0, 0, 0, 0, 0, 0>>
  // Claim 64MB payload (larger than max 32MB)
  let length = <<67_108_864:32-little>>
  let checksum = <<0, 0, 0, 0>>

  let msg = bit_array.concat([magic, command, length, checksum])

  case oni_p2p.decode_message(msg, oni_bitcoin.Mainnet) {
    Error(oni_p2p.MessageTooLarge) -> should.be_ok(Ok(Nil))
    Error(_) -> should.be_ok(Ok(Nil))
    // Other errors acceptable too
    Ok(_) -> should.fail()
  }
}

pub fn truncated_payload_returns_error_test() {
  // Header claims 100 bytes payload but only 10 bytes provided
  let magic = <<0xF9, 0xBE, 0xB4, 0xD9>>
  let command = <<"ping", 0, 0, 0, 0, 0, 0, 0, 0>>
  let length = <<100:32-little>>
  // Claim 100 bytes
  let checksum = <<0, 0, 0, 0>>
  let payload = <<1, 2, 3, 4, 5, 6, 7, 8, 9, 10>>
  // Only 10 bytes

  let msg = bit_array.concat([magic, command, length, checksum, payload])

  case oni_p2p.decode_message(msg, oni_bitcoin.Mainnet) {
    Error(oni_p2p.InvalidMessage(_)) -> should.be_ok(Ok(Nil))
    Error(_) -> should.be_ok(Ok(Nil))
    Ok(_) -> should.fail()
  }
}

// ============================================================================
// Inventory Message Boundary Tests
// ============================================================================

pub fn inv_zero_items_test() {
  // Zero inventory items should be valid
  let payload = <<0>>
  // CompactSize 0
  let encoded = encode_with_header("inv", payload)

  case oni_p2p.decode_message(encoded, oni_bitcoin.Mainnet) {
    Ok(#(oni_p2p.MsgInv([]), _)) -> should.be_ok(Ok(Nil))
    _ -> should.fail()
  }
}

pub fn inv_max_items_boundary_test() {
  // Test at exactly max_inv_size boundary
  // This is a large test, so we just verify the count check works
  // by testing just above the limit
  let count = max_inv_size + 1
  // Encode count as varint (need 3 bytes for 50001)
  let count_bytes = encode_compact_size(count)
  // Don't need actual items, just trigger the count check
  let payload = count_bytes

  let encoded = encode_with_header("inv", payload)

  case oni_p2p.decode_message(encoded, oni_bitcoin.Mainnet) {
    Error(oni_p2p.InvalidMessage("Too many inventory items")) ->
      should.be_ok(Ok(Nil))
    Error(_) -> should.be_ok(Ok(Nil))
    Ok(_) -> should.fail()
  }
}

pub fn inv_truncated_item_test() {
  // One item claimed but not enough bytes
  let payload =
    bit_array.concat([
      <<1>>,
      // 1 item
      <<0, 0, 0, 0>>,
      // Only 4 bytes, need 36 (4 type + 32 hash)
    ])

  let encoded = encode_with_header("inv", payload)

  case oni_p2p.decode_message(encoded, oni_bitcoin.Mainnet) {
    Error(_) -> should.be_ok(Ok(Nil))
    Ok(_) -> should.fail()
  }
}

pub fn inv_item_roundtrip_test() {
  // Valid inventory item should roundtrip
  let hash = oni_bitcoin.Hash256(<<0:256>>)
  let item = oni_p2p.InvItem(oni_p2p.InvTx, hash)

  let encoded = oni_p2p.encode_inv_item(item)
  case oni_p2p.decode_inv_item(encoded) {
    Ok(#(decoded, <<>>)) -> {
      decoded.inv_type |> should.equal(oni_p2p.InvTx)
      decoded.hash |> should.equal(hash)
    }
    _ -> should.fail()
  }
}

pub fn inv_list_roundtrip_test() {
  // Multiple inventory items should roundtrip
  let items = [
    oni_p2p.InvItem(oni_p2p.InvTx, oni_bitcoin.Hash256(<<1:256>>)),
    oni_p2p.InvItem(oni_p2p.InvBlock, oni_bitcoin.Hash256(<<2:256>>)),
    oni_p2p.InvItem(oni_p2p.InvWitnessTx, oni_bitcoin.Hash256(<<3:256>>)),
  ]

  let encoded = oni_p2p.encode_inv_list(items)
  case oni_p2p.decode_inv_list(encoded) {
    Ok(#(decoded, <<>>)) -> {
      list.length(decoded) |> should.equal(3)
    }
    _ -> should.fail()
  }
}

// ============================================================================
// Address Message Boundary Tests
// ============================================================================

pub fn addr_zero_addresses_test() {
  // Zero addresses should be valid
  let payload = <<0>>
  let encoded = encode_with_header("addr", payload)

  case oni_p2p.decode_message(encoded, oni_bitcoin.Mainnet) {
    Ok(#(oni_p2p.MsgAddr([]), _)) -> should.be_ok(Ok(Nil))
    _ -> should.fail()
  }
}

pub fn addr_max_addresses_boundary_test() {
  // Test above max_addr_size
  let count = max_addr_size + 1
  let count_bytes = encode_compact_size(count)

  let encoded = encode_with_header("addr", count_bytes)

  case oni_p2p.decode_message(encoded, oni_bitcoin.Mainnet) {
    Error(oni_p2p.InvalidMessage("Too many addresses")) -> should.be_ok(Ok(Nil))
    Error(_) -> should.be_ok(Ok(Nil))
    Ok(_) -> should.fail()
  }
}

pub fn addr_truncated_address_test() {
  // One address claimed but not enough bytes
  let payload =
    bit_array.concat([
      <<1>>,
      // 1 address
      <<0, 0, 0, 0>>,
      // Only 4 bytes, need 30 (4 time + 8 services + 16 ip + 2 port)
    ])

  let encoded = encode_with_header("addr", payload)

  case oni_p2p.decode_message(encoded, oni_bitcoin.Mainnet) {
    Error(_) -> should.be_ok(Ok(Nil))
    Ok(_) -> should.fail()
  }
}

// ============================================================================
// Headers Message Boundary Tests
// ============================================================================

pub fn headers_zero_count_test() {
  // Zero headers should be valid
  let payload = <<0>>
  let encoded = encode_with_header("headers", payload)

  case oni_p2p.decode_message(encoded, oni_bitcoin.Mainnet) {
    Ok(#(oni_p2p.MsgHeaders([]), _)) -> should.be_ok(Ok(Nil))
    _ -> should.fail()
  }
}

pub fn headers_max_boundary_test() {
  // Test above max_headers_size
  let count = max_headers_size + 1
  let count_bytes = encode_compact_size(count)

  let encoded = encode_with_header("headers", count_bytes)

  case oni_p2p.decode_message(encoded, oni_bitcoin.Mainnet) {
    Error(oni_p2p.InvalidMessage("Too many headers")) -> should.be_ok(Ok(Nil))
    Error(_) -> should.be_ok(Ok(Nil))
    Ok(_) -> should.fail()
  }
}

pub fn headers_truncated_header_test() {
  // One header claimed but truncated
  let payload =
    bit_array.concat([
      <<1>>,
      // 1 header
      <<0:64>>,
      // Only 8 bytes, need 81 (80 header + 1 tx count)
    ])

  let encoded = encode_with_header("headers", payload)

  case oni_p2p.decode_message(encoded, oni_bitcoin.Mainnet) {
    Error(_) -> should.be_ok(Ok(Nil))
    Ok(_) -> should.fail()
  }
}

// ============================================================================
// Version Message Tests
// ============================================================================

pub fn version_truncated_test() {
  // Version message with truncated payload
  let payload = <<70_016:32-little, 0:64-little>>
  // Only version and services

  let encoded = encode_with_header("version", payload)

  case oni_p2p.decode_message(encoded, oni_bitcoin.Mainnet) {
    Error(_) -> should.be_ok(Ok(Nil))
    Ok(_) -> should.fail()
  }
}

pub fn version_invalid_user_agent_length_test() {
  // Version with user agent length larger than remaining bytes
  // Build a minimal valid version up to user_agent
  let version = 70_016
  let services = 1
  let timestamp = 1_234_567_890
  // addr_recv: services(8) + ip(16) + port(2) = 26 bytes
  let addr_recv = <<
    1:64-little,
    0:80,
    0xFF:8,
    0xFF:8,
    127:8,
    0:8,
    0:8,
    1:8,
    8333:16-big,
  >>
  // addr_from: same
  let addr_from = <<
    1:64-little,
    0:80,
    0xFF:8,
    0xFF:8,
    127:8,
    0:8,
    0:8,
    1:8,
    0:16-big,
  >>
  let nonce = 12_345
  // User agent with length claiming 255 bytes but only 5 provided
  let user_agent_len = <<255>>
  let user_agent_data = <<"hello">>

  let payload =
    bit_array.concat([
      <<version:32-little>>,
      <<services:64-little>>,
      <<timestamp:64-little>>,
      addr_recv,
      addr_from,
      <<nonce:64-little>>,
      user_agent_len,
      user_agent_data,
    ])

  let encoded = encode_with_header("version", payload)

  case oni_p2p.decode_message(encoded, oni_bitcoin.Mainnet) {
    Error(_) -> should.be_ok(Ok(Nil))
    Ok(_) -> should.fail()
  }
}

// ============================================================================
// Ping/Pong Message Tests
// ============================================================================

pub fn ping_valid_test() {
  let nonce = 0x123456789ABCDEF0
  let payload = <<nonce:64-little>>
  let encoded = encode_with_header("ping", payload)

  case oni_p2p.decode_message(encoded, oni_bitcoin.Mainnet) {
    Ok(#(oni_p2p.MsgPing(n), _)) -> n |> should.equal(nonce)
    _ -> should.fail()
  }
}

pub fn ping_empty_legacy_test() {
  // Old clients may send empty ping
  let encoded = encode_with_header("ping", <<>>)

  case oni_p2p.decode_message(encoded, oni_bitcoin.Mainnet) {
    Ok(#(oni_p2p.MsgPing(0), _)) -> should.be_ok(Ok(Nil))
    _ -> should.fail()
  }
}

pub fn pong_truncated_test() {
  // Pong with only 4 bytes (needs 8)
  let payload = <<1, 2, 3, 4>>
  let encoded = encode_with_header("pong", payload)

  case oni_p2p.decode_message(encoded, oni_bitcoin.Mainnet) {
    Error(_) -> should.be_ok(Ok(Nil))
    Ok(_) -> should.fail()
  }
}

// ============================================================================
// GetBlocks/GetHeaders Boundary Tests
// ============================================================================

pub fn getblocks_max_locators_test() {
  // Test above max_locator_size
  let version = <<70_016:32-little>>
  let count = max_locator_size + 1
  let count_bytes = encode_compact_size(count)

  let payload = bit_array.concat([version, count_bytes])
  let encoded = encode_with_header("getblocks", payload)

  case oni_p2p.decode_message(encoded, oni_bitcoin.Mainnet) {
    Error(oni_p2p.InvalidMessage("Too many locators")) -> should.be_ok(Ok(Nil))
    Error(_) -> should.be_ok(Ok(Nil))
    Ok(_) -> should.fail()
  }
}

pub fn getheaders_max_locators_test() {
  // Test above max_locator_size
  let version = <<70_016:32-little>>
  let count = max_locator_size + 1
  let count_bytes = encode_compact_size(count)

  let payload = bit_array.concat([version, count_bytes])
  let encoded = encode_with_header("getheaders", payload)

  case oni_p2p.decode_message(encoded, oni_bitcoin.Mainnet) {
    Error(oni_p2p.InvalidMessage("Too many locators")) -> should.be_ok(Ok(Nil))
    Error(_) -> should.be_ok(Ok(Nil))
    Ok(_) -> should.fail()
  }
}

pub fn getblocks_missing_stop_hash_test() {
  // Valid count but no stop hash
  let version = <<70_016:32-little>>
  let count = <<0>>
  // 0 locators
  // No stop hash follows

  let payload = bit_array.concat([version, count])
  let encoded = encode_with_header("getblocks", payload)

  case oni_p2p.decode_message(encoded, oni_bitcoin.Mainnet) {
    Error(oni_p2p.InvalidMessage("Missing stop hash")) -> should.be_ok(Ok(Nil))
    Error(_) -> should.be_ok(Ok(Nil))
    Ok(_) -> should.fail()
  }
}

// ============================================================================
// SendCmpct Message Tests
// ============================================================================

pub fn sendcmpct_valid_test() {
  let payload = <<1:8, 1:64-little>>
  // announce=true, version=1
  let encoded = encode_with_header("sendcmpct", payload)

  case oni_p2p.decode_message(encoded, oni_bitcoin.Mainnet) {
    Ok(#(oni_p2p.MsgSendCmpct(True, 1), _)) -> should.be_ok(Ok(Nil))
    _ -> should.fail()
  }
}

pub fn sendcmpct_truncated_test() {
  let payload = <<1>>
  // Only 1 byte, need 9
  let encoded = encode_with_header("sendcmpct", payload)

  case oni_p2p.decode_message(encoded, oni_bitcoin.Mainnet) {
    Error(_) -> should.be_ok(Ok(Nil))
    Ok(_) -> should.fail()
  }
}

// ============================================================================
// FeeFilter Message Tests
// ============================================================================

pub fn feefilter_valid_test() {
  let fee = 1000
  let payload = <<fee:64-little>>
  let encoded = encode_with_header("feefilter", payload)

  case oni_p2p.decode_message(encoded, oni_bitcoin.Mainnet) {
    Ok(#(oni_p2p.MsgFeeFilter(f), _)) -> f |> should.equal(fee)
    _ -> should.fail()
  }
}

pub fn feefilter_truncated_test() {
  let payload = <<1, 2, 3, 4>>
  // Only 4 bytes, need 8
  let encoded = encode_with_header("feefilter", payload)

  case oni_p2p.decode_message(encoded, oni_bitcoin.Mainnet) {
    Error(_) -> should.be_ok(Ok(Nil))
    Ok(_) -> should.fail()
  }
}

// ============================================================================
// Empty Payload Messages
// ============================================================================

pub fn verack_test() {
  let encoded = encode_with_header("verack", <<>>)

  case oni_p2p.decode_message(encoded, oni_bitcoin.Mainnet) {
    Ok(#(oni_p2p.MsgVerack, _)) -> should.be_ok(Ok(Nil))
    _ -> should.fail()
  }
}

pub fn sendheaders_test() {
  let encoded = encode_with_header("sendheaders", <<>>)

  case oni_p2p.decode_message(encoded, oni_bitcoin.Mainnet) {
    Ok(#(oni_p2p.MsgSendHeaders, _)) -> should.be_ok(Ok(Nil))
    _ -> should.fail()
  }
}

pub fn wtxidrelay_test() {
  let encoded = encode_with_header("wtxidrelay", <<>>)

  case oni_p2p.decode_message(encoded, oni_bitcoin.Mainnet) {
    Ok(#(oni_p2p.MsgWtxidRelay, _)) -> should.be_ok(Ok(Nil))
    _ -> should.fail()
  }
}

pub fn sendaddrv2_test() {
  let encoded = encode_with_header("sendaddrv2", <<>>)

  case oni_p2p.decode_message(encoded, oni_bitcoin.Mainnet) {
    Ok(#(oni_p2p.MsgSendAddrV2, _)) -> should.be_ok(Ok(Nil))
    _ -> should.fail()
  }
}

pub fn getaddr_test() {
  let encoded = encode_with_header("getaddr", <<>>)

  case oni_p2p.decode_message(encoded, oni_bitcoin.Mainnet) {
    Ok(#(oni_p2p.MsgGetAddr, _)) -> should.be_ok(Ok(Nil))
    _ -> should.fail()
  }
}

pub fn mempool_test() {
  let encoded = encode_with_header("mempool", <<>>)

  case oni_p2p.decode_message(encoded, oni_bitcoin.Mainnet) {
    Ok(#(oni_p2p.MsgMempool, _)) -> should.be_ok(Ok(Nil))
    _ -> should.fail()
  }
}

// ============================================================================
// Unknown Command Handling
// ============================================================================

pub fn unknown_command_test() {
  let payload = <<"some random data">>
  let encoded = encode_with_header("unknowncmd", payload)

  case oni_p2p.decode_message(encoded, oni_bitcoin.Mainnet) {
    Ok(#(oni_p2p.MsgUnknown("unknowncmd", _), _)) -> should.be_ok(Ok(Nil))
    _ -> should.fail()
  }
}

pub fn command_with_null_bytes_test() {
  // Command with embedded nulls should be handled
  let payload = <<>>
  let encoded = encode_with_header("ver\u{0000}ck", payload)

  // Should decode as "ver" (stopping at null)
  case oni_p2p.decode_message(encoded, oni_bitcoin.Mainnet) {
    Ok(#(oni_p2p.MsgUnknown("ver", _), _)) -> should.be_ok(Ok(Nil))
    Ok(_) -> should.be_ok(Ok(Nil))
    // Any valid parse is ok
    Error(_) -> should.be_ok(Ok(Nil))
    // Error is also acceptable
  }
}

// ============================================================================
// IP Address Boundary Tests
// ============================================================================

pub fn ip_decode_truncated_test() {
  // Less than 16 bytes should fail
  case oni_p2p.decode_ip(<<0, 0, 0, 0, 0, 0, 0, 0>>) {
    Error(_) -> should.be_ok(Ok(Nil))
    Ok(_) -> should.fail()
  }
}

pub fn ipv4_mapped_roundtrip_test() {
  let ip = oni_p2p.ipv4(192, 168, 1, 1)
  let encoded = oni_p2p.encode_ip(ip)

  case oni_p2p.decode_ip(encoded) {
    Ok(decoded) -> {
      oni_p2p.ip_to_string(decoded) |> should.equal("192.168.1.1")
    }
    Error(_) -> should.fail()
  }
}

pub fn ipv6_roundtrip_test() {
  // Create a non-mapped IPv6 address (first 10 bytes not all zero + ffff)
  let ipv6_bytes = <<
    0x20,
    0x01,
    0x0D,
    0xB8,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x00,
    0x01,
  >>

  case oni_p2p.decode_ip(ipv6_bytes) {
    Ok(oni_p2p.IPv6(_)) -> should.be_ok(Ok(Nil))
    Ok(oni_p2p.IPv4(_, _, _, _)) -> should.be_ok(Ok(Nil))
    // May decode as IPv4 depending on pattern
    Error(_) -> should.fail()
  }
}

// ============================================================================
// NetAddr Boundary Tests
// ============================================================================

pub fn netaddr_truncated_test() {
  // NetAddr needs 26 bytes, provide only 10
  case oni_p2p.decode_netaddr(<<0:80>>) {
    Error(_) -> should.be_ok(Ok(Nil))
    Ok(_) -> should.fail()
  }
}

pub fn netaddr_roundtrip_test() {
  let addr =
    oni_p2p.NetAddr(
      services: oni_p2p.default_services(),
      ip: oni_p2p.ipv4(8, 8, 8, 8),
      port: 8333,
    )

  let encoded = oni_p2p.encode_netaddr(addr)
  case oni_p2p.decode_netaddr(encoded) {
    Ok(#(decoded, <<>>)) -> {
      decoded.port |> should.equal(8333)
      oni_p2p.ip_to_string(decoded.ip) |> should.equal("8.8.8.8")
    }
    _ -> should.fail()
  }
}

// ============================================================================
// CompactSize Boundary Tests (via inv decoding)
// ============================================================================

pub fn compact_size_1_byte_max_test() {
  // 252 is max for 1-byte encoding
  let count = <<252>>
  let items = create_dummy_inv_items(252)
  let payload = bit_array.concat([count, items])
  let encoded = encode_with_header("inv", payload)

  case oni_p2p.decode_message(encoded, oni_bitcoin.Mainnet) {
    Ok(#(oni_p2p.MsgInv(decoded_items), _)) -> {
      list.length(decoded_items) |> should.equal(252)
    }
    _ -> should.fail()
  }
}

pub fn compact_size_3_byte_min_test() {
  // 253 requires 3-byte encoding: 0xFD + little-endian 16-bit
  let count = <<0xFD, 253:16-little>>
  let items = create_dummy_inv_items(253)
  let payload = bit_array.concat([count, items])
  let encoded = encode_with_header("inv", payload)

  case oni_p2p.decode_message(encoded, oni_bitcoin.Mainnet) {
    Ok(#(oni_p2p.MsgInv(decoded_items), _)) -> {
      list.length(decoded_items) |> should.equal(253)
    }
    _ -> should.fail()
  }
}

// ============================================================================
// Full Message Roundtrip Tests
// ============================================================================

pub fn ping_roundtrip_test() {
  let msg = oni_p2p.MsgPing(0xDEADBEEF12345678)
  let encoded = oni_p2p.encode_message(msg, oni_bitcoin.Mainnet)

  case oni_p2p.decode_message(encoded, oni_bitcoin.Mainnet) {
    Ok(#(oni_p2p.MsgPing(nonce), _)) ->
      nonce |> should.equal(0xDEADBEEF12345678)
    _ -> should.fail()
  }
}

pub fn pong_roundtrip_test() {
  let msg = oni_p2p.MsgPong(0x123456789ABCDEF0)
  let encoded = oni_p2p.encode_message(msg, oni_bitcoin.Mainnet)

  case oni_p2p.decode_message(encoded, oni_bitcoin.Mainnet) {
    Ok(#(oni_p2p.MsgPong(nonce), _)) ->
      nonce |> should.equal(0x123456789ABCDEF0)
    _ -> should.fail()
  }
}

pub fn inv_roundtrip_test() {
  let items = [
    oni_p2p.InvItem(oni_p2p.InvTx, oni_bitcoin.Hash256(<<1:256>>)),
    oni_p2p.InvItem(oni_p2p.InvBlock, oni_bitcoin.Hash256(<<2:256>>)),
  ]
  let msg = oni_p2p.MsgInv(items)
  let encoded = oni_p2p.encode_message(msg, oni_bitcoin.Mainnet)

  case oni_p2p.decode_message(encoded, oni_bitcoin.Mainnet) {
    Ok(#(oni_p2p.MsgInv(decoded), _)) -> {
      list.length(decoded) |> should.equal(2)
    }
    _ -> should.fail()
  }
}

pub fn getdata_roundtrip_test() {
  let items = [
    oni_p2p.InvItem(oni_p2p.InvWitnessTx, oni_bitcoin.Hash256(<<42:256>>)),
  ]
  let msg = oni_p2p.MsgGetData(items)
  let encoded = oni_p2p.encode_message(msg, oni_bitcoin.Mainnet)

  case oni_p2p.decode_message(encoded, oni_bitcoin.Mainnet) {
    Ok(#(oni_p2p.MsgGetData(decoded), _)) -> {
      list.length(decoded) |> should.equal(1)
    }
    _ -> should.fail()
  }
}

pub fn notfound_roundtrip_test() {
  let items = [
    oni_p2p.InvItem(oni_p2p.InvTx, oni_bitcoin.Hash256(<<99:256>>)),
  ]
  let msg = oni_p2p.MsgNotFound(items)
  let encoded = oni_p2p.encode_message(msg, oni_bitcoin.Mainnet)

  case oni_p2p.decode_message(encoded, oni_bitcoin.Mainnet) {
    Ok(#(oni_p2p.MsgNotFound(decoded), _)) -> {
      list.length(decoded) |> should.equal(1)
    }
    _ -> should.fail()
  }
}

pub fn feefilter_roundtrip_test() {
  let msg = oni_p2p.MsgFeeFilter(1000)
  let encoded = oni_p2p.encode_message(msg, oni_bitcoin.Mainnet)

  case oni_p2p.decode_message(encoded, oni_bitcoin.Mainnet) {
    Ok(#(oni_p2p.MsgFeeFilter(fee), _)) -> fee |> should.equal(1000)
    _ -> should.fail()
  }
}

pub fn sendcmpct_roundtrip_test() {
  let msg = oni_p2p.MsgSendCmpct(True, 2)
  let encoded = oni_p2p.encode_message(msg, oni_bitcoin.Mainnet)

  case oni_p2p.decode_message(encoded, oni_bitcoin.Mainnet) {
    Ok(#(oni_p2p.MsgSendCmpct(True, 2), _)) -> should.be_ok(Ok(Nil))
    _ -> should.fail()
  }
}

// ============================================================================
// Network Variation Tests
// ============================================================================

pub fn testnet_magic_test() {
  let msg = oni_p2p.MsgVerack
  let encoded = oni_p2p.encode_message(msg, oni_bitcoin.Testnet)

  // Should decode on testnet
  case oni_p2p.decode_message(encoded, oni_bitcoin.Testnet) {
    Ok(#(oni_p2p.MsgVerack, _)) -> should.be_ok(Ok(Nil))
    _ -> should.fail()
  }

  // Should fail on mainnet (wrong magic)
  case oni_p2p.decode_message(encoded, oni_bitcoin.Mainnet) {
    Error(_) -> should.be_ok(Ok(Nil))
    Ok(_) -> should.fail()
  }
}

pub fn regtest_magic_test() {
  let msg = oni_p2p.MsgVerack
  let encoded = oni_p2p.encode_message(msg, oni_bitcoin.Regtest)

  case oni_p2p.decode_message(encoded, oni_bitcoin.Regtest) {
    Ok(#(oni_p2p.MsgVerack, _)) -> should.be_ok(Ok(Nil))
    _ -> should.fail()
  }
}

// ============================================================================
// Multiple Messages in Stream Test
// ============================================================================

pub fn multiple_messages_in_buffer_test() {
  let msg1 = oni_p2p.MsgPing(111)
  let msg2 = oni_p2p.MsgPong(222)

  let encoded1 = oni_p2p.encode_message(msg1, oni_bitcoin.Mainnet)
  let encoded2 = oni_p2p.encode_message(msg2, oni_bitcoin.Mainnet)
  let combined = bit_array.concat([encoded1, encoded2])

  // First decode should return ping and remaining bytes
  case oni_p2p.decode_message(combined, oni_bitcoin.Mainnet) {
    Ok(#(oni_p2p.MsgPing(111), remaining)) -> {
      // Remaining should decode as pong
      case oni_p2p.decode_message(remaining, oni_bitcoin.Mainnet) {
        Ok(#(oni_p2p.MsgPong(222), <<>>)) -> should.be_ok(Ok(Nil))
        _ -> should.fail()
      }
    }
    _ -> should.fail()
  }
}

// ============================================================================
// Helper Functions
// ============================================================================

/// Encode a message with proper header (for testing payload parsing)
fn encode_with_header(command: String, payload: BitArray) -> BitArray {
  let magic = <<0xF9, 0xBE, 0xB4, 0xD9>>
  // Mainnet
  let cmd_bytes = pad_command(command)
  let length = <<bit_array.byte_size(payload):32-little>>
  let checksum = compute_checksum(payload)

  bit_array.concat([magic, cmd_bytes, length, checksum, payload])
}

/// Pad command to 12 bytes
fn pad_command(command: String) -> BitArray {
  let cmd = bit_array.from_string(command)
  let len = bit_array.byte_size(cmd)
  let padding = create_zeros(12 - len)
  bit_array.concat([cmd, padding])
}

/// Create n zero bytes
fn create_zeros(n: Int) -> BitArray {
  case n <= 0 {
    True -> <<>>
    False -> bit_array.concat([<<0>>, create_zeros(n - 1)])
  }
}

/// Compute message checksum (first 4 bytes of double SHA256)
fn compute_checksum(payload: BitArray) -> BitArray {
  let hash = oni_bitcoin.sha256d(payload)
  case bit_array.slice(hash, 0, 4) {
    Ok(cs) -> cs
    Error(_) -> <<0, 0, 0, 0>>
  }
}

/// Encode a compact size integer
fn encode_compact_size(n: Int) -> BitArray {
  case n {
    _ if n < 253 -> <<n:8>>
    _ if n < 65_536 -> <<0xFD, n:16-little>>
    _ if n < 4_294_967_296 -> <<0xFE, n:32-little>>
    _ -> <<0xFF, n:64-little>>
  }
}

/// Create n dummy inventory items (36 bytes each: 4 type + 32 hash)
fn create_dummy_inv_items(n: Int) -> BitArray {
  create_dummy_inv_items_acc(n, <<>>)
}

fn create_dummy_inv_items_acc(n: Int, acc: BitArray) -> BitArray {
  case n <= 0 {
    True -> acc
    False -> {
      // InvTx type (1) + 32 byte hash
      let item = <<1:32-little, 0:256>>
      create_dummy_inv_items_acc(n - 1, bit_array.concat([acc, item]))
    }
  }
}
