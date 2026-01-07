// oni_p2p - Bitcoin P2P networking layer
//
// This module provides the P2P networking foundation for the oni node:
// - Message framing and codec layer
// - Handshake (version/verack)
// - Peer lifecycle management
// - Basic inv/getdata for blocks and txs
// - Address manager with persistence
//
// Phase 6 Implementation

import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import oni_bitcoin.{
  type Block, type BlockHash, type Hash256, type Transaction, type Txid,
}

// ============================================================================
// Constants
// ============================================================================

/// Protocol version (70016 = BIP339 wtxid relay)
pub const protocol_version = 70_016

/// Minimum supported protocol version
pub const min_protocol_version = 70_015

/// User agent string
pub const user_agent = "/oni:0.1.0/"

/// Default connection timeout in milliseconds
pub const connection_timeout_ms = 60_000

/// Default ping interval in milliseconds
pub const ping_interval_ms = 120_000

/// Maximum message payload size (32MB)
pub const max_message_size = 33_554_432

/// Maximum number of inventory items per message
pub const max_inv_size = 50_000

/// Maximum number of addresses per message
pub const max_addr_size = 1000

/// Maximum number of headers per message
pub const max_headers_size = 2000

/// Maximum number of locators per getheaders message
pub const max_locator_size = 101

// ============================================================================
// P2P Errors
// ============================================================================

/// P2P operation errors
pub type P2PError {
  ConnectionFailed(String)
  ConnectionTimeout
  ConnectionClosed
  HandshakeFailed(String)
  InvalidMessage(String)
  InvalidChecksum
  MessageTooLarge
  UnknownCommand(String)
  ProtocolViolation(String)
  PeerBanned
  PeerMisbehaving(Int)
  InternalError(String)
}

// ============================================================================
// Service Flags (BIP37, BIP111, BIP144, BIP155, BIP157, BIP339)
// ============================================================================

/// Service flags advertised by nodes
pub type ServiceFlags {
  ServiceFlags(value: Int)
}

/// NODE_NETWORK - full node, can serve full blocks
pub const node_network = 1

/// NODE_GETUTXO - BIP64 (deprecated)
pub const node_getutxo = 2

/// NODE_BLOOM - BIP111 bloom filters
pub const node_bloom = 4

/// NODE_WITNESS - BIP144 segregated witness
pub const node_witness = 8

/// NODE_XTHIN - Xtreme Thinblocks (not used)
pub const node_xthin = 16

/// NODE_COMPACT_FILTERS - BIP157 compact block filters
pub const node_compact_filters = 64

/// NODE_NETWORK_LIMITED - BIP159 pruned node
pub const node_network_limited = 1024

/// Create service flags from an integer
pub fn service_flags_from_int(value: Int) -> ServiceFlags {
  ServiceFlags(value)
}

/// Get the integer value of service flags
pub fn service_flags_to_int(flags: ServiceFlags) -> Int {
  flags.value
}

/// Check if a service flag is set
pub fn service_flags_has(flags: ServiceFlags, flag: Int) -> Bool {
  int.bitwise_and(flags.value, flag) != 0
}

/// Combine service flags
pub fn service_flags_add(flags: ServiceFlags, flag: Int) -> ServiceFlags {
  ServiceFlags(int.bitwise_or(flags.value, flag))
}

/// Default services for a full node
pub fn default_services() -> ServiceFlags {
  ServiceFlags(int.bitwise_or(
    int.bitwise_or(node_network, node_witness),
    node_bloom,
  ))
}

// ============================================================================
// Network Address
// ============================================================================

/// Network address with services and port
pub type NetAddr {
  NetAddr(services: ServiceFlags, ip: IpAddr, port: Int)
}

/// Timestamped network address (for addr messages)
pub type TimestampedAddr {
  TimestampedAddr(time: Int, services: ServiceFlags, ip: IpAddr, port: Int)
}

/// IP address (IPv4 or IPv6)
pub type IpAddr {
  IPv4(a: Int, b: Int, c: Int, d: Int)
  IPv6(bytes: BitArray)
}

/// Create an IPv4 address
pub fn ipv4(a: Int, b: Int, c: Int, d: Int) -> IpAddr {
  IPv4(a, b, c, d)
}

/// Create a localhost IPv4 address
pub fn localhost() -> IpAddr {
  IPv4(127, 0, 0, 1)
}

/// Convert IP address to string
pub fn ip_to_string(ip: IpAddr) -> String {
  case ip {
    IPv4(a, b, c, d) ->
      int.to_string(a)
      <> "."
      <> int.to_string(b)
      <> "."
      <> int.to_string(c)
      <> "."
      <> int.to_string(d)
    IPv6(bytes) -> "IPv6(" <> oni_bitcoin.hex_encode(bytes) <> ")"
  }
}

/// Encode IP address for network (IPv6-mapped IPv4)
pub fn encode_ip(ip: IpAddr) -> BitArray {
  case ip {
    IPv4(a, b, c, d) ->
      // IPv4-mapped IPv6 address: ::ffff:a.b.c.d
      <<0:80, 0xFF:8, 0xFF:8, a:8, b:8, c:8, d:8>>
    IPv6(bytes) -> bytes
  }
}

/// Decode IP address from network bytes
pub fn decode_ip(bytes: BitArray) -> Result(IpAddr, String) {
  case bytes {
    // IPv4-mapped IPv6
    <<0:80, 0xFF:8, 0xFF:8, a:8, b:8, c:8, d:8>> -> Ok(IPv4(a, b, c, d))
    // Pure IPv6
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
    >> ->
      Ok(
        IPv6(<<
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
        >>),
      )
    _ -> Error("Invalid IP address bytes")
  }
}

/// Encode a network address (without timestamp)
pub fn encode_netaddr(addr: NetAddr) -> BitArray {
  <<
    service_flags_to_int(addr.services):64-little,
    { encode_ip(addr.ip) }:bits,
    addr.port:16-big,
  >>
}

/// Decode a network address (without timestamp)
pub fn decode_netaddr(bytes: BitArray) -> Result(#(NetAddr, BitArray), String) {
  case bytes {
    <<services:64-little, ip:128-bits, port:16-big, rest:bits>> -> {
      case decode_ip(<<ip:128-bits>>) {
        Ok(ip_addr) -> {
          let addr =
            NetAddr(
              services: service_flags_from_int(services),
              ip: ip_addr,
              port: port,
            )
          Ok(#(addr, rest))
        }
        Error(e) -> Error(e)
      }
    }
    _ -> Error("Insufficient bytes for network address")
  }
}

// ============================================================================
// Peer Identity
// ============================================================================

/// Peer identifier
pub type PeerId {
  PeerId(String)
}

/// Create a peer ID from a string
pub fn peer_id(name: String) -> PeerId {
  PeerId(name)
}

/// Create a peer ID from address and port
pub fn peer_id_from_addr(ip: IpAddr, port: Int) -> PeerId {
  PeerId(ip_to_string(ip) <> ":" <> int.to_string(port))
}

/// Get peer ID as string
pub fn peer_id_to_string(id: PeerId) -> String {
  case id {
    PeerId(s) -> s
  }
}

// ============================================================================
// Inventory Types
// ============================================================================

/// Inventory item type
pub type InvType {
  InvError
  InvTx
  InvBlock
  InvFilteredBlock
  InvCmpctBlock
  InvWitnessTx
  InvWitnessBlock
  InvWitnessFilteredBlock
}

/// Inventory item
pub type InvItem {
  InvItem(inv_type: InvType, hash: Hash256)
}

/// Convert inventory type to integer
pub fn inv_type_to_int(t: InvType) -> Int {
  case t {
    InvError -> 0
    InvTx -> 1
    InvBlock -> 2
    InvFilteredBlock -> 3
    InvCmpctBlock -> 4
    InvWitnessTx -> 0x40000001
    InvWitnessBlock -> 0x40000002
    InvWitnessFilteredBlock -> 0x40000003
  }
}

/// Convert integer to inventory type
pub fn inv_type_from_int(n: Int) -> InvType {
  case n {
    0 -> InvError
    1 -> InvTx
    2 -> InvBlock
    3 -> InvFilteredBlock
    4 -> InvCmpctBlock
    0x40000001 -> InvWitnessTx
    0x40000002 -> InvWitnessBlock
    0x40000003 -> InvWitnessFilteredBlock
    _ -> InvError
  }
}

/// Encode an inventory item
pub fn encode_inv_item(item: InvItem) -> BitArray {
  <<{ inv_type_to_int(item.inv_type) }:32-little, item.hash.bytes:bits>>
}

/// Decode an inventory item
pub fn decode_inv_item(bytes: BitArray) -> Result(#(InvItem, BitArray), String) {
  case bytes {
    <<inv_type:32-little, hash:256-bits, rest:bits>> -> {
      let item =
        InvItem(
          inv_type: inv_type_from_int(inv_type),
          hash: oni_bitcoin.Hash256(<<hash:256-bits>>),
        )
      Ok(#(item, rest))
    }
    _ -> Error("Insufficient bytes for inventory item")
  }
}

/// Encode a list of inventory items
pub fn encode_inv_list(items: List(InvItem)) -> BitArray {
  let count = oni_bitcoin.compact_size_encode(list.length(items))
  let items_data =
    list.fold(items, <<>>, fn(acc, item) {
      bit_array.append(acc, encode_inv_item(item))
    })
  bit_array.append(count, items_data)
}

/// Decode a list of inventory items
pub fn decode_inv_list(
  bytes: BitArray,
) -> Result(#(List(InvItem), BitArray), String) {
  case oni_bitcoin.compact_size_decode(bytes) {
    Error(e) -> Error(e)
    Ok(#(count, rest)) -> {
      case count > max_inv_size {
        True -> Error("Too many inventory items")
        False -> decode_inv_items(rest, count, [])
      }
    }
  }
}

fn decode_inv_items(
  bytes: BitArray,
  remaining: Int,
  acc: List(InvItem),
) -> Result(#(List(InvItem), BitArray), String) {
  case remaining {
    0 -> Ok(#(list.reverse(acc), bytes))
    _ -> {
      case decode_inv_item(bytes) {
        Error(e) -> Error(e)
        Ok(#(item, rest)) ->
          decode_inv_items(rest, remaining - 1, [item, ..acc])
      }
    }
  }
}

// ============================================================================
// P2P Message Types
// ============================================================================

/// Bitcoin P2P protocol messages
pub type Message {
  // Handshake
  MsgVersion(VersionPayload)
  MsgVerack

  // Control
  MsgPing(nonce: Int)
  MsgPong(nonce: Int)
  MsgSendHeaders
  MsgSendCmpct(announce: Bool, version: Int)
  MsgFeeFilter(fee_rate: Int)
  MsgWtxidRelay
  MsgSendAddrV2

  // Address
  MsgAddr(addrs: List(TimestampedAddr))
  MsgAddrV2(addrs: List(TimestampedAddr))
  MsgGetAddr

  // Inventory
  MsgInv(items: List(InvItem))
  MsgGetData(items: List(InvItem))
  MsgNotFound(items: List(InvItem))

  // Blocks
  MsgGetBlocks(locators: List(BlockHash), stop_hash: BlockHash)
  MsgGetHeaders(locators: List(BlockHash), stop_hash: BlockHash)
  MsgHeaders(headers: List(BlockHeaderNet))
  MsgBlock(block: Block)

  // Transactions
  MsgTx(tx: Transaction)
  MsgMempool

  // Reject (deprecated but still used)
  MsgReject(message: String, code: Int, reason: String, data: BitArray)

  // BIP152 Compact Blocks
  MsgCmpctBlock(
    header: BlockHeaderNet,
    nonce: Int,
    short_ids: List(BitArray),
    prefilled_txs: List(PrefilledTx),
  )
  MsgGetBlockTxn(block_hash: BlockHash, indexes: List(Int))
  MsgBlockTxn(block_hash: BlockHash, txs: List(Transaction))

  // Unknown/raw message
  MsgUnknown(command: String, payload: BitArray)
}

/// Block header in network format (80 bytes)
pub type BlockHeaderNet {
  BlockHeaderNet(
    version: Int,
    prev_block: BlockHash,
    merkle_root: Hash256,
    timestamp: Int,
    bits: Int,
    nonce: Int,
  )
}

/// Prefilled transaction for compact blocks
pub type PrefilledTx {
  PrefilledTx(index: Int, tx: Transaction)
}

/// Version message payload
pub type VersionPayload {
  VersionPayload(
    version: Int,
    services: ServiceFlags,
    timestamp: Int,
    addr_recv: NetAddr,
    addr_from: NetAddr,
    nonce: Int,
    user_agent: String,
    start_height: Int,
    relay: Bool,
  )
}

/// Create a version message
pub fn version_message(
  services: ServiceFlags,
  timestamp: Int,
  addr_recv: NetAddr,
  nonce: Int,
  start_height: Int,
) -> Message {
  MsgVersion(VersionPayload(
    version: protocol_version,
    services: services,
    timestamp: timestamp,
    addr_recv: addr_recv,
    addr_from: NetAddr(services, localhost(), 0),
    nonce: nonce,
    user_agent: user_agent,
    start_height: start_height,
    relay: True,
  ))
}

// ============================================================================
// Message Encoding
// ============================================================================

/// Message header structure
pub type MessageHeader {
  MessageHeader(magic: Int, command: String, length: Int, checksum: BitArray)
}

/// Network magic bytes (stored as little-endian integers)
/// These values, when encoded as <<X:32-little>>, produce the correct wire format.
/// Testnet4 wire bytes: 1C 16 3F 28 -> stored as 0x283F161C
pub fn network_magic(network: oni_bitcoin.Network) -> Int {
  case network {
    oni_bitcoin.Mainnet -> 0xD9B4BEF9
    oni_bitcoin.Testnet -> 0x0709110B
    oni_bitcoin.Testnet4 -> 0x283F161C
    oni_bitcoin.Regtest -> 0xDAB5BFFA
    oni_bitcoin.Signet -> 0x40CF030A
  }
}

/// Encode a command name (12 bytes, null-padded)
fn encode_command(command: String) -> BitArray {
  let cmd_bytes = bit_array.from_string(command)
  let len = bit_array.byte_size(cmd_bytes)
  let padding = create_zero_bytes(12 - len)
  bit_array.append(cmd_bytes, padding)
}

fn create_zero_bytes(n: Int) -> BitArray {
  case n <= 0 {
    True -> <<>>
    False -> bit_array.append(<<0:8>>, create_zero_bytes(n - 1))
  }
}

/// Decode a command name (strip null bytes)
fn decode_command(bytes: BitArray) -> String {
  bytes
  |> strip_null_bytes
  |> bit_array.to_string
  |> result.unwrap("")
}

fn strip_null_bytes(bytes: BitArray) -> BitArray {
  strip_null_bytes_acc(bytes, <<>>)
}

fn strip_null_bytes_acc(bytes: BitArray, acc: BitArray) -> BitArray {
  case bytes {
    <<0:8, _rest:bits>> -> acc
    <<b:8, rest:bits>> ->
      strip_null_bytes_acc(rest, bit_array.append(acc, <<b:8>>))
    _ -> acc
  }
}

/// Compute message checksum (first 4 bytes of double SHA256)
fn message_checksum(payload: BitArray) -> BitArray {
  let hash = oni_bitcoin.sha256d(payload)
  case bit_array.slice(hash, 0, 4) {
    Ok(cs) -> cs
    Error(_) -> <<0:32>>
  }
}

/// Get the command name for a message (for debugging)
pub fn message_command(msg: Message) -> String {
  case msg {
    MsgVersion(_) -> "version"
    MsgVerack -> "verack"
    MsgPing(_) -> "ping"
    MsgPong(_) -> "pong"
    MsgAddr(_) -> "addr"
    MsgAddrV2(_) -> "addrv2"
    MsgInv(_) -> "inv"
    MsgGetData(_) -> "getdata"
    MsgNotFound(_) -> "notfound"
    MsgGetBlocks(_, _) -> "getblocks"
    MsgGetHeaders(_, _) -> "getheaders"
    MsgHeaders(_) -> "headers"
    MsgBlock(_) -> "block"
    MsgTx(_) -> "tx"
    MsgReject(_, _, _, _) -> "reject"
    MsgMempool -> "mempool"
    MsgGetAddr -> "getaddr"
    MsgSendHeaders -> "sendheaders"
    MsgSendCmpct(_, _) -> "sendcmpct"
    MsgCmpctBlock(_, _, _, _) -> "cmpctblock"
    MsgGetBlockTxn(_, _) -> "getblocktxn"
    MsgBlockTxn(_, _) -> "blocktxn"
    MsgFeeFilter(_) -> "feefilter"
    MsgWtxidRelay -> "wtxidrelay"
    MsgSendAddrV2 -> "sendaddrv2"
    MsgUnknown(cmd, _) -> "unknown:" <> cmd
  }
}

/// Encode a complete message with header
pub fn encode_message(msg: Message, network: oni_bitcoin.Network) -> BitArray {
  let #(command, payload) = encode_message_payload(msg)
  let magic = network_magic(network)
  let checksum = message_checksum(payload)
  let length = bit_array.byte_size(payload)

  bit_array.concat([
    <<magic:32-little>>,
    encode_command(command),
    <<length:32-little>>,
    checksum,
    payload,
  ])
}

/// Encode message payload and return (command, payload)
fn encode_message_payload(msg: Message) -> #(String, BitArray) {
  case msg {
    MsgVersion(payload) -> #("version", encode_version_payload(payload))
    MsgVerack -> #("verack", <<>>)
    MsgPing(nonce) -> #("ping", <<nonce:64-little>>)
    MsgPong(nonce) -> #("pong", <<nonce:64-little>>)
    MsgSendHeaders -> #("sendheaders", <<>>)
    MsgSendCmpct(announce, version) -> {
      let flag = case announce {
        True -> 1
        False -> 0
      }
      #("sendcmpct", <<flag:8, version:64-little>>)
    }
    MsgFeeFilter(fee_rate) -> #("feefilter", <<fee_rate:64-little>>)
    MsgWtxidRelay -> #("wtxidrelay", <<>>)
    MsgSendAddrV2 -> #("sendaddrv2", <<>>)
    MsgGetAddr -> #("getaddr", <<>>)
    MsgAddr(addrs) -> #("addr", encode_addr_list(addrs))
    MsgAddrV2(addrs) -> #("addrv2", encode_addr_list(addrs))
    MsgInv(items) -> #("inv", encode_inv_list(items))
    MsgGetData(items) -> #("getdata", encode_inv_list(items))
    MsgNotFound(items) -> #("notfound", encode_inv_list(items))
    MsgGetBlocks(locators, stop) -> #(
      "getblocks",
      encode_get_blocks(locators, stop),
    )
    MsgGetHeaders(locators, stop) -> #(
      "getheaders",
      encode_get_blocks(locators, stop),
    )
    MsgHeaders(headers) -> #("headers", encode_headers(headers))
    MsgMempool -> #("mempool", <<>>)
    MsgReject(message, code, reason, data) -> #(
      "reject",
      encode_reject(message, code, reason, data),
    )
    MsgUnknown(command, payload) -> #(command, payload)
    // These require full block/tx encoding
    MsgBlock(_) -> #("block", <<>>)
    MsgTx(_) -> #("tx", <<>>)
    MsgCmpctBlock(_, _, _, _) -> #("cmpctblock", <<>>)
    MsgGetBlockTxn(_, _) -> #("getblocktxn", <<>>)
    MsgBlockTxn(_, _) -> #("blocktxn", <<>>)
  }
}

/// Encode version message payload
fn encode_version_payload(v: VersionPayload) -> BitArray {
  let ua_bytes = bit_array.from_string(v.user_agent)
  let ua_len = oni_bitcoin.compact_size_encode(bit_array.byte_size(ua_bytes))
  let relay_byte = case v.relay {
    True -> 1
    False -> 0
  }

  bit_array.concat([
    <<v.version:32-little>>,
    <<service_flags_to_int(v.services):64-little>>,
    <<v.timestamp:64-little>>,
    encode_netaddr(v.addr_recv),
    encode_netaddr(v.addr_from),
    <<v.nonce:64-little>>,
    ua_len,
    ua_bytes,
    <<v.start_height:32-little>>,
    <<relay_byte:8>>,
  ])
}

/// Encode timestamped address list
fn encode_addr_list(addrs: List(TimestampedAddr)) -> BitArray {
  let count = oni_bitcoin.compact_size_encode(list.length(addrs))
  let addrs_data =
    list.fold(addrs, <<>>, fn(acc, addr) {
      bit_array.append(acc, encode_timestamped_addr(addr))
    })
  bit_array.append(count, addrs_data)
}

fn encode_timestamped_addr(addr: TimestampedAddr) -> BitArray {
  <<
    addr.time:32-little,
    service_flags_to_int(addr.services):64-little,
    { encode_ip(addr.ip) }:bits,
    addr.port:16-big,
  >>
}

/// Encode getblocks/getheaders payload
fn encode_get_blocks(
  locators: List(BlockHash),
  stop_hash: BlockHash,
) -> BitArray {
  let version = <<protocol_version:32-little>>
  let count = oni_bitcoin.compact_size_encode(list.length(locators))
  let locators_data =
    list.fold(locators, <<>>, fn(acc, hash) {
      bit_array.append(acc, hash.hash.bytes)
    })
  bit_array.concat([version, count, locators_data, stop_hash.hash.bytes])
}

/// Encode headers message
fn encode_headers(headers: List(BlockHeaderNet)) -> BitArray {
  let count = oni_bitcoin.compact_size_encode(list.length(headers))
  let headers_data =
    list.fold(headers, <<>>, fn(acc, header) {
      let encoded = <<
        header.version:32-little,
        header.prev_block.hash.bytes:bits,
        header.merkle_root.bytes:bits,
        header.timestamp:32-little,
        header.bits:32-little,
        header.nonce:32-little,
        0:8,
        // tx_count (always 0 in headers message)
      >>
      bit_array.append(acc, encoded)
    })
  bit_array.append(count, headers_data)
}

/// Encode reject message
fn encode_reject(
  message: String,
  code: Int,
  reason: String,
  data: BitArray,
) -> BitArray {
  let msg_bytes = bit_array.from_string(message)
  let msg_len = oni_bitcoin.compact_size_encode(bit_array.byte_size(msg_bytes))
  let reason_bytes = bit_array.from_string(reason)
  let reason_len =
    oni_bitcoin.compact_size_encode(bit_array.byte_size(reason_bytes))
  bit_array.concat([
    msg_len,
    msg_bytes,
    <<code:8>>,
    reason_len,
    reason_bytes,
    data,
  ])
}

// ============================================================================
// Message Decoding
// ============================================================================

/// Decode a complete message from bytes
pub fn decode_message(
  bytes: BitArray,
  network: oni_bitcoin.Network,
) -> Result(#(Message, BitArray), P2PError) {
  let expected_magic = network_magic(network)

  case bytes {
    <<
      magic:32-little,
      command:96-bits,
      length:32-little,
      checksum:32-bits,
      rest:bits,
    >> -> {
      // Check magic
      case magic == expected_magic {
        False -> Error(InvalidMessage("Wrong network magic"))
        True -> {
          // Check payload size
          case length > max_message_size {
            True -> Error(MessageTooLarge)
            False -> {
              // Extract payload
              case bit_array.byte_size(rest) >= length {
                False -> Error(InvalidMessage("Insufficient payload"))
                True -> {
                  case bit_array.slice(rest, 0, length) {
                    Error(_) ->
                      Error(InvalidMessage("Failed to extract payload"))
                    Ok(payload) -> {
                      // Verify checksum
                      let expected_checksum = message_checksum(payload)
                      case <<checksum:32-bits>> == expected_checksum {
                        False -> Error(InvalidChecksum)
                        True -> {
                          // Parse command
                          let cmd = decode_command(<<command:96-bits>>)
                          // Parse payload
                          case decode_message_payload(cmd, payload) {
                            Error(e) -> Error(e)
                            Ok(msg) -> {
                              // Calculate remaining bytes
                              let remaining_size =
                                bit_array.byte_size(rest) - length
                              case
                                bit_array.slice(rest, length, remaining_size)
                              {
                                Error(_) -> Ok(#(msg, <<>>))
                                Ok(remaining) -> Ok(#(msg, remaining))
                              }
                            }
                          }
                        }
                      }
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
    _ -> Error(InvalidMessage("Insufficient bytes for header"))
  }
}

/// Decode message payload based on command
fn decode_message_payload(
  command: String,
  payload: BitArray,
) -> Result(Message, P2PError) {
  case command {
    "version" -> decode_version_message(payload)
    "verack" -> Ok(MsgVerack)
    "ping" -> decode_ping(payload)
    "pong" -> decode_pong(payload)
    "sendheaders" -> Ok(MsgSendHeaders)
    "sendcmpct" -> decode_sendcmpct(payload)
    "feefilter" -> decode_feefilter(payload)
    "wtxidrelay" -> Ok(MsgWtxidRelay)
    "sendaddrv2" -> Ok(MsgSendAddrV2)
    "getaddr" -> Ok(MsgGetAddr)
    "addr" -> decode_addr(payload)
    "addrv2" -> decode_addr(payload)
    "inv" -> decode_inv(payload)
    "getdata" -> decode_getdata(payload)
    "notfound" -> decode_notfound(payload)
    "getblocks" -> decode_getblocks(payload)
    "getheaders" -> decode_getheaders(payload)
    "headers" -> decode_headers_msg(payload)
    "mempool" -> Ok(MsgMempool)
    "reject" -> decode_reject(payload)
    "block" -> decode_block_msg(payload)
    "tx" -> decode_tx_msg(payload)
    _ -> Ok(MsgUnknown(command, payload))
  }
}

fn decode_version_message(payload: BitArray) -> Result(Message, P2PError) {
  case payload {
    <<version:32-little, services:64-little, timestamp:64-little, rest:bits>> -> {
      case decode_netaddr(rest) {
        Error(e) -> Error(InvalidMessage(e))
        Ok(#(addr_recv, rest2)) -> {
          case decode_netaddr(rest2) {
            Error(e) -> Error(InvalidMessage(e))
            Ok(#(addr_from, rest3)) -> {
              case rest3 {
                <<nonce:64-little, rest4:bits>> -> {
                  case decode_varstr(rest4) {
                    Error(e) -> Error(InvalidMessage(e))
                    Ok(#(user_agent_str, rest5)) -> {
                      case rest5 {
                        <<start_height:32-little>> -> {
                          Ok(
                            MsgVersion(VersionPayload(
                              version: version,
                              services: service_flags_from_int(services),
                              timestamp: timestamp,
                              addr_recv: addr_recv,
                              addr_from: addr_from,
                              nonce: nonce,
                              user_agent: user_agent_str,
                              start_height: start_height,
                              relay: True,
                            )),
                          )
                        }
                        <<start_height:32-little, relay:8, _rest:bits>> -> {
                          Ok(
                            MsgVersion(VersionPayload(
                              version: version,
                              services: service_flags_from_int(services),
                              timestamp: timestamp,
                              addr_recv: addr_recv,
                              addr_from: addr_from,
                              nonce: nonce,
                              user_agent: user_agent_str,
                              start_height: start_height,
                              relay: relay != 0,
                            )),
                          )
                        }
                        _ -> Error(InvalidMessage("Invalid version payload"))
                      }
                    }
                  }
                }
                _ -> Error(InvalidMessage("Invalid version payload"))
              }
            }
          }
        }
      }
    }
    _ -> Error(InvalidMessage("Invalid version payload"))
  }
}

fn decode_varstr(bytes: BitArray) -> Result(#(String, BitArray), String) {
  case oni_bitcoin.compact_size_decode(bytes) {
    Error(e) -> Error(e)
    Ok(#(len, rest)) -> {
      case bit_array.slice(rest, 0, len) {
        Error(_) -> Error("Insufficient bytes for string")
        Ok(str_bytes) -> {
          case bit_array.to_string(str_bytes) {
            Error(_) -> Error("Invalid UTF-8 string")
            Ok(s) -> {
              let remaining_size = bit_array.byte_size(rest) - len
              case bit_array.slice(rest, len, remaining_size) {
                Error(_) -> Ok(#(s, <<>>))
                Ok(remaining) -> Ok(#(s, remaining))
              }
            }
          }
        }
      }
    }
  }
}

fn decode_ping(payload: BitArray) -> Result(Message, P2PError) {
  case payload {
    <<nonce:64-little, _rest:bits>> -> Ok(MsgPing(nonce))
    <<>> -> Ok(MsgPing(0))
    // Old clients may send empty ping
    _ -> Error(InvalidMessage("Invalid ping payload"))
  }
}

fn decode_pong(payload: BitArray) -> Result(Message, P2PError) {
  case payload {
    <<nonce:64-little, _rest:bits>> -> Ok(MsgPong(nonce))
    _ -> Error(InvalidMessage("Invalid pong payload"))
  }
}

fn decode_sendcmpct(payload: BitArray) -> Result(Message, P2PError) {
  case payload {
    <<announce:8, version:64-little, _rest:bits>> ->
      Ok(MsgSendCmpct(announce != 0, version))
    _ -> Error(InvalidMessage("Invalid sendcmpct payload"))
  }
}

fn decode_feefilter(payload: BitArray) -> Result(Message, P2PError) {
  case payload {
    <<fee_rate:64-little, _rest:bits>> -> Ok(MsgFeeFilter(fee_rate))
    _ -> Error(InvalidMessage("Invalid feefilter payload"))
  }
}

fn decode_addr(payload: BitArray) -> Result(Message, P2PError) {
  case oni_bitcoin.compact_size_decode(payload) {
    Error(e) -> Error(InvalidMessage(e))
    Ok(#(count, rest)) -> {
      case count > max_addr_size {
        True -> Error(InvalidMessage("Too many addresses"))
        False -> {
          case decode_timestamped_addrs(rest, count, []) {
            Error(e) -> Error(InvalidMessage(e))
            Ok(addrs) -> Ok(MsgAddr(addrs))
          }
        }
      }
    }
  }
}

fn decode_timestamped_addrs(
  bytes: BitArray,
  remaining: Int,
  acc: List(TimestampedAddr),
) -> Result(List(TimestampedAddr), String) {
  case remaining {
    0 -> Ok(list.reverse(acc))
    _ -> {
      case bytes {
        <<
          time:32-little,
          services:64-little,
          ip:128-bits,
          port:16-big,
          rest:bits,
        >> -> {
          case decode_ip(<<ip:128-bits>>) {
            Error(e) -> Error(e)
            Ok(ip_addr) -> {
              let addr =
                TimestampedAddr(
                  time: time,
                  services: service_flags_from_int(services),
                  ip: ip_addr,
                  port: port,
                )
              decode_timestamped_addrs(rest, remaining - 1, [addr, ..acc])
            }
          }
        }
        _ -> Error("Insufficient bytes for address")
      }
    }
  }
}

fn decode_inv(payload: BitArray) -> Result(Message, P2PError) {
  case decode_inv_list(payload) {
    Error(e) -> Error(InvalidMessage(e))
    Ok(#(items, _rest)) -> Ok(MsgInv(items))
  }
}

fn decode_getdata(payload: BitArray) -> Result(Message, P2PError) {
  case decode_inv_list(payload) {
    Error(e) -> Error(InvalidMessage(e))
    Ok(#(items, _rest)) -> Ok(MsgGetData(items))
  }
}

fn decode_notfound(payload: BitArray) -> Result(Message, P2PError) {
  case decode_inv_list(payload) {
    Error(e) -> Error(InvalidMessage(e))
    Ok(#(items, _rest)) -> Ok(MsgNotFound(items))
  }
}

fn decode_getblocks(payload: BitArray) -> Result(Message, P2PError) {
  case payload {
    <<_version:32-little, rest:bits>> -> {
      case oni_bitcoin.compact_size_decode(rest) {
        Error(e) -> Error(InvalidMessage(e))
        Ok(#(count, rest2)) -> {
          case count > max_locator_size {
            True -> Error(InvalidMessage("Too many locators"))
            False -> {
              case decode_block_hashes(rest2, count, []) {
                Error(e) -> Error(InvalidMessage(e))
                Ok(#(locators, rest3)) -> {
                  case rest3 {
                    <<stop_hash:256-bits, _rest:bits>> -> {
                      Ok(MsgGetBlocks(
                        locators,
                        oni_bitcoin.BlockHash(
                          oni_bitcoin.Hash256(<<stop_hash:256-bits>>),
                        ),
                      ))
                    }
                    _ -> Error(InvalidMessage("Missing stop hash"))
                  }
                }
              }
            }
          }
        }
      }
    }
    _ -> Error(InvalidMessage("Invalid getblocks payload"))
  }
}

fn decode_getheaders(payload: BitArray) -> Result(Message, P2PError) {
  case payload {
    <<_version:32-little, rest:bits>> -> {
      case oni_bitcoin.compact_size_decode(rest) {
        Error(e) -> Error(InvalidMessage(e))
        Ok(#(count, rest2)) -> {
          case count > max_locator_size {
            True -> Error(InvalidMessage("Too many locators"))
            False -> {
              case decode_block_hashes(rest2, count, []) {
                Error(e) -> Error(InvalidMessage(e))
                Ok(#(locators, rest3)) -> {
                  case rest3 {
                    <<stop_hash:256-bits, _rest:bits>> -> {
                      Ok(MsgGetHeaders(
                        locators,
                        oni_bitcoin.BlockHash(
                          oni_bitcoin.Hash256(<<stop_hash:256-bits>>),
                        ),
                      ))
                    }
                    _ -> Error(InvalidMessage("Missing stop hash"))
                  }
                }
              }
            }
          }
        }
      }
    }
    _ -> Error(InvalidMessage("Invalid getheaders payload"))
  }
}

fn decode_block_hashes(
  bytes: BitArray,
  remaining: Int,
  acc: List(BlockHash),
) -> Result(#(List(BlockHash), BitArray), String) {
  case remaining {
    0 -> Ok(#(list.reverse(acc), bytes))
    _ -> {
      case bytes {
        <<hash:256-bits, rest:bits>> -> {
          let block_hash =
            oni_bitcoin.BlockHash(oni_bitcoin.Hash256(<<hash:256-bits>>))
          decode_block_hashes(rest, remaining - 1, [block_hash, ..acc])
        }
        _ -> Error("Insufficient bytes for block hash")
      }
    }
  }
}

fn decode_headers_msg(payload: BitArray) -> Result(Message, P2PError) {
  case oni_bitcoin.compact_size_decode(payload) {
    Error(e) -> Error(InvalidMessage(e))
    Ok(#(count, rest)) -> {
      case count > max_headers_size {
        True -> Error(InvalidMessage("Too many headers"))
        False -> {
          case decode_headers_list(rest, count, []) {
            Error(e) -> Error(InvalidMessage(e))
            Ok(headers) -> Ok(MsgHeaders(headers))
          }
        }
      }
    }
  }
}

fn decode_headers_list(
  bytes: BitArray,
  remaining: Int,
  acc: List(BlockHeaderNet),
) -> Result(List(BlockHeaderNet), String) {
  case remaining {
    0 -> Ok(list.reverse(acc))
    _ -> {
      case bytes {
        <<
          version:32-little,
          prev_block:256-bits,
          merkle_root:256-bits,
          timestamp:32-little,
          bits:32-little,
          nonce:32-little,
          _tx_count:8,
          rest:bits,
        >> -> {
          let header =
            BlockHeaderNet(
              version: version,
              prev_block: oni_bitcoin.BlockHash(
                oni_bitcoin.Hash256(<<prev_block:256-bits>>),
              ),
              merkle_root: oni_bitcoin.Hash256(<<merkle_root:256-bits>>),
              timestamp: timestamp,
              bits: bits,
              nonce: nonce,
            )
          decode_headers_list(rest, remaining - 1, [header, ..acc])
        }
        _ -> Error("Invalid header bytes")
      }
    }
  }
}

fn decode_reject(payload: BitArray) -> Result(Message, P2PError) {
  case decode_varstr(payload) {
    Error(e) -> Error(InvalidMessage(e))
    Ok(#(message, rest)) -> {
      case rest {
        <<code:8, rest2:bits>> -> {
          case decode_varstr(rest2) {
            Error(e) -> Error(InvalidMessage(e))
            Ok(#(reason, data)) -> Ok(MsgReject(message, code, reason, data))
          }
        }
        _ -> Error(InvalidMessage("Invalid reject payload"))
      }
    }
  }
}

/// Decode a block message
fn decode_block_msg(payload: BitArray) -> Result(Message, P2PError) {
  case oni_bitcoin.decode_block(payload) {
    Error(e) -> Error(InvalidMessage("Failed to decode block: " <> e))
    Ok(#(block, _remaining)) -> Ok(MsgBlock(block))
  }
}

/// Decode a transaction message
fn decode_tx_msg(payload: BitArray) -> Result(Message, P2PError) {
  case oni_bitcoin.decode_tx(payload) {
    Error(e) -> Error(InvalidMessage("Failed to decode tx: " <> e))
    Ok(#(tx, _remaining)) -> Ok(MsgTx(tx))
  }
}

// ============================================================================
// Peer Connection State
// ============================================================================

/// Peer connection state
pub type PeerState {
  Connecting
  Connected
  Handshaking
  Ready
  Disconnecting
  Disconnected
}

/// Reason for disconnection
pub type DisconnectReason {
  DisconnectRequested
  DisconnectTimeout
  DisconnectProtocolError
  DisconnectMisbehavior
  DisconnectBanned
  DisconnectNoServices
  DisconnectDuplicate
  DisconnectOther(String)
}

/// Peer connection information
pub type PeerInfo {
  PeerInfo(
    id: PeerId,
    addr: NetAddr,
    state: PeerState,
    inbound: Bool,
    version: Option(Int),
    user_agent: Option(String),
    services: ServiceFlags,
    start_height: Option(Int),
    ping_time: Option(Int),
    last_send: Int,
    last_recv: Int,
    bytes_sent: Int,
    bytes_recv: Int,
    misbehavior_score: Int,
    wtxid_relay: Bool,
    send_compact: Bool,
    addr_v2: Bool,
  )
}

/// Create new peer info
pub fn peer_info_new(id: PeerId, addr: NetAddr, inbound: Bool) -> PeerInfo {
  PeerInfo(
    id: id,
    addr: addr,
    state: Connecting,
    inbound: inbound,
    version: None,
    user_agent: None,
    services: ServiceFlags(0),
    start_height: None,
    ping_time: None,
    last_send: 0,
    last_recv: 0,
    bytes_sent: 0,
    bytes_recv: 0,
    misbehavior_score: 0,
    wtxid_relay: False,
    send_compact: False,
    addr_v2: False,
  )
}

/// Update peer state
pub fn peer_set_state(peer: PeerInfo, state: PeerState) -> PeerInfo {
  PeerInfo(..peer, state: state)
}

/// Update peer after version message
pub fn peer_set_version(
  peer: PeerInfo,
  version: Int,
  user_agent: String,
  services: ServiceFlags,
  start_height: Int,
) -> PeerInfo {
  PeerInfo(
    ..peer,
    version: Some(version),
    user_agent: Some(user_agent),
    services: services,
    start_height: Some(start_height),
  )
}

/// Increment misbehavior score
pub fn peer_misbehaving(peer: PeerInfo, score: Int) -> PeerInfo {
  PeerInfo(..peer, misbehavior_score: peer.misbehavior_score + score)
}

/// Check if peer is banned (score >= 100)
pub fn peer_is_banned(peer: PeerInfo) -> Bool {
  peer.misbehavior_score >= 100
}

/// Check if peer supports a service
pub fn peer_has_service(peer: PeerInfo, service: Int) -> Bool {
  service_flags_has(peer.services, service)
}

// ============================================================================
// Address Manager
// ============================================================================

/// Address entry in the address manager
pub type AddrEntry {
  AddrEntry(
    addr: NetAddr,
    source: IpAddr,
    last_success: Int,
    last_try: Int,
    attempts: Int,
    ref_count: Int,
  )
}

/// Address manager for tracking known peer addresses
pub type AddrManager {
  AddrManager(
    addrs: Dict(String, AddrEntry),
    tried: List(String),
    new_addrs: List(String),
    num_tried: Int,
    num_new: Int,
    rand_seed: Int,
  )
}

/// Create a new address manager
pub fn addrman_new() -> AddrManager {
  AddrManager(
    addrs: dict.new(),
    tried: [],
    new_addrs: [],
    num_tried: 0,
    num_new: 0,
    rand_seed: 0,
  )
}

/// Add an address to the manager
pub fn addrman_add(
  manager: AddrManager,
  addr: NetAddr,
  source: IpAddr,
  time_penalty: Int,
) -> AddrManager {
  let key = addr_to_key(addr)
  case dict.get(manager.addrs, key) {
    Ok(_existing) -> {
      // Already exists, update ref count
      manager
    }
    Error(_) -> {
      let entry =
        AddrEntry(
          addr: addr,
          source: source,
          last_success: 0,
          last_try: 0 - time_penalty,
          attempts: 0,
          ref_count: 1,
        )
      AddrManager(
        ..manager,
        addrs: dict.insert(manager.addrs, key, entry),
        new_addrs: [key, ..manager.new_addrs],
        num_new: manager.num_new + 1,
      )
    }
  }
}

/// Mark an address as good (successful connection)
pub fn addrman_good(
  manager: AddrManager,
  addr: NetAddr,
  time: Int,
) -> AddrManager {
  let key = addr_to_key(addr)
  case dict.get(manager.addrs, key) {
    Error(_) -> manager
    Ok(entry) -> {
      let updated = AddrEntry(..entry, last_success: time, attempts: 0)
      AddrManager(..manager, addrs: dict.insert(manager.addrs, key, updated))
    }
  }
}

/// Mark an address as attempted
pub fn addrman_attempt(
  manager: AddrManager,
  addr: NetAddr,
  time: Int,
) -> AddrManager {
  let key = addr_to_key(addr)
  case dict.get(manager.addrs, key) {
    Error(_) -> manager
    Ok(entry) -> {
      let updated =
        AddrEntry(..entry, last_try: time, attempts: entry.attempts + 1)
      AddrManager(..manager, addrs: dict.insert(manager.addrs, key, updated))
    }
  }
}

/// Get addresses for sending to peers
pub fn addrman_get_addrs(
  manager: AddrManager,
  max: Int,
) -> List(TimestampedAddr) {
  manager.addrs
  |> dict.values
  |> list.take(max)
  |> list.map(fn(entry) {
    TimestampedAddr(
      time: entry.last_success,
      services: entry.addr.services,
      ip: entry.addr.ip,
      port: entry.addr.port,
    )
  })
}

/// Get address count
pub fn addrman_size(manager: AddrManager) -> Int {
  dict.size(manager.addrs)
}

/// Create a key from address
fn addr_to_key(addr: NetAddr) -> String {
  ip_to_string(addr.ip) <> ":" <> int.to_string(addr.port)
}

// ============================================================================
// Connection Manager
// ============================================================================

/// Connection manager configuration
pub type ConnConfig {
  ConnConfig(
    max_inbound: Int,
    max_outbound: Int,
    max_outbound_full_relay: Int,
    max_outbound_block_relay: Int,
    listen_port: Int,
    bind_address: Option(IpAddr),
  )
}

/// Default connection configuration
pub fn default_conn_config() -> ConnConfig {
  ConnConfig(
    max_inbound: 117,
    max_outbound: 11,
    max_outbound_full_relay: 8,
    max_outbound_block_relay: 2,
    listen_port: 8333,
    bind_address: None,
  )
}

/// Connection statistics
pub type ConnStats {
  ConnStats(
    num_inbound: Int,
    num_outbound: Int,
    bytes_sent: Int,
    bytes_recv: Int,
    connect_attempts: Int,
    disconnects: Int,
  )
}

/// Initial connection stats
pub fn conn_stats_new() -> ConnStats {
  ConnStats(
    num_inbound: 0,
    num_outbound: 0,
    bytes_sent: 0,
    bytes_recv: 0,
    connect_attempts: 0,
    disconnects: 0,
  )
}

// ============================================================================
// Handshake Protocol
// ============================================================================

/// Handshake state
pub type HandshakeState {
  AwaitingVersion
  AwaitingVerack
  HandshakeComplete
}

/// Perform outbound handshake sequence
/// Returns the messages to send
pub fn handshake_initiate(
  services: ServiceFlags,
  timestamp: Int,
  remote_addr: NetAddr,
  nonce: Int,
  start_height: Int,
) -> List(Message) {
  [version_message(services, timestamp, remote_addr, nonce, start_height)]
}

/// Handle incoming version message during handshake
pub fn handshake_on_version(
  payload: VersionPayload,
) -> Result(List(Message), P2PError) {
  // Check protocol version
  case payload.version >= min_protocol_version {
    False -> Error(ProtocolViolation("Protocol version too old"))
    True -> {
      // Send verack and any feature negotiation messages
      let msgs = [MsgVerack, MsgWtxidRelay, MsgSendAddrV2, MsgSendHeaders]
      Ok(msgs)
    }
  }
}

/// Handle incoming verack message
pub fn handshake_on_verack() -> Result(HandshakeState, P2PError) {
  Ok(HandshakeComplete)
}

// ============================================================================
// Message Handlers
// ============================================================================

/// Result of handling a message
pub type HandleResult {
  HandleOk(messages: List(Message))
  HandleIgnore
  HandleBan(reason: String)
  HandleDisconnect(reason: DisconnectReason)
}

/// Handle a ping message
pub fn handle_ping(nonce: Int) -> HandleResult {
  HandleOk([MsgPong(nonce)])
}

/// Handle a pong message (update ping time)
pub fn handle_pong(_nonce: Int) -> HandleResult {
  HandleOk([])
}

/// Handle a getaddr message
pub fn handle_getaddr(addrman: AddrManager) -> HandleResult {
  let addrs = addrman_get_addrs(addrman, max_addr_size)
  HandleOk([MsgAddr(addrs)])
}

/// Handle sendheaders message
pub fn handle_sendheaders() -> HandleResult {
  HandleOk([])
}

/// Handle wtxidrelay message
pub fn handle_wtxidrelay() -> HandleResult {
  HandleOk([])
}

/// Create inventory items for blocks
pub fn create_block_inv(hashes: List(BlockHash)) -> Message {
  let items = list.map(hashes, fn(hash) { InvItem(InvBlock, hash.hash) })
  MsgInv(items)
}

/// Create inventory items for transactions
pub fn create_tx_inv(txids: List(Txid)) -> Message {
  let items = list.map(txids, fn(txid) { InvItem(InvTx, txid.hash) })
  MsgInv(items)
}

/// Create getdata for blocks (requests witness blocks for segwit compatibility)
/// Since SegWit activation (2017), almost all blocks contain witness data.
/// Peers will not respond to MSG_BLOCK (type 2) requests for witness blocks;
/// we must use MSG_WITNESS_BLOCK (type 0x40000002) to receive full block data.
pub fn create_getdata_blocks(hashes: List(BlockHash)) -> Message {
  let items = list.map(hashes, fn(hash) { InvItem(InvWitnessBlock, hash.hash) })
  MsgGetData(items)
}

/// Create getdata for transactions (with witness)
pub fn create_getdata_txs(txids: List(Txid), witness: Bool) -> Message {
  let inv_type = case witness {
    True -> InvWitnessTx
    False -> InvTx
  }
  let items = list.map(txids, fn(txid) { InvItem(inv_type, txid.hash) })
  MsgGetData(items)
}

// ============================================================================
// DNS Seeds
// ============================================================================

/// DNS seeds for mainnet peer discovery
pub const mainnet_dns_seeds = [
  "seed.bitcoin.sipa.be", "dnsseed.bluematt.me",
  "dnsseed.bitcoin.dashjr-list-of-hierarchical-deterministic-seeds.today",
  "seed.bitcoinstats.com", "seed.bitcoin.jonasschnelli.ch",
  "seed.btc.petertodd.net", "seed.bitcoin.sprovoost.nl", "dnsseed.emzy.de",
  "seed.bitcoin.wiz.biz",
]

/// DNS seeds for testnet peer discovery
pub const testnet_dns_seeds = [
  "testnet-seed.bitcoin.jonasschnelli.ch", "seed.tbtc.petertodd.net",
  "testnet-seed.bluematt.me",
]

/// DNS seeds for signet peer discovery
pub const signet_dns_seeds = ["seed.signet.bitcoin.sprovoost.nl"]

/// DNS seeds for testnet4 peer discovery (BIP-94)
pub const testnet4_dns_seeds = [
  "seed.testnet4.bitcoin.sprovoost.nl", "seed.testnet4.wiz.biz",
]

/// Network type for DNS seed selection
pub type Network {
  Mainnet
  Testnet
  Testnet4
  Signet
  Regtest
}

/// Get DNS seeds for a network
pub fn get_dns_seeds(network: Network) -> List(String) {
  case network {
    Mainnet -> mainnet_dns_seeds
    Testnet -> testnet_dns_seeds
    Testnet4 -> testnet4_dns_seeds
    Signet -> signet_dns_seeds
    Regtest -> []
    // No DNS seeds for regtest
  }
}

/// Get default port for a network
pub fn get_default_port(network: Network) -> Int {
  case network {
    Mainnet -> 8333
    Testnet -> 18_333
    Testnet4 -> 48_333
    Signet -> 38_333
    Regtest -> 18_444
  }
}

/// Peer address discovered from DNS
pub type DnsAddress {
  DnsAddress(ip: String, port: Int, source_seed: String)
}

/// DNS lookup result (placeholder - actual implementation needs native code)
pub type DnsResult {
  DnsOk(addresses: List(DnsAddress))
  DnsError(reason: String)
  DnsTimeout
}

/// Query a single DNS seed using native DNS resolution
@external(erlang, "p2p_network_ffi", "dns_lookup")
pub fn query_dns_seed(seed: String, port: Int) -> DnsResult

/// Query all DNS seeds for a network and collect addresses
pub fn discover_peers_dns(network: Network) -> List(DnsAddress) {
  let seeds = get_dns_seeds(network)
  let port = get_default_port(network)
  query_all_seeds(seeds, port, [])
}

fn query_all_seeds(
  seeds: List(String),
  port: Int,
  acc: List(DnsAddress),
) -> List(DnsAddress) {
  case seeds {
    [] -> acc
    [seed, ..rest] -> {
      let new_addrs = case query_dns_seed(seed, port) {
        DnsOk(addrs) -> addrs
        DnsError(_) -> []
        DnsTimeout -> []
      }
      query_all_seeds(rest, port, list.append(acc, new_addrs))
    }
  }
}

/// Get network magic bytes
pub fn get_network_magic(network: Network) -> BitArray {
  case network {
    Mainnet -> <<0xF9, 0xBE, 0xB4, 0xD9>>
    Testnet -> <<0x0B, 0x11, 0x09, 0x07>>
    Testnet4 -> <<0x1C, 0x16, 0x3F, 0x28>>
    Signet -> <<0x0A, 0x03, 0xCF, 0x40>>
    Regtest -> <<0xFA, 0xBF, 0xB5, 0xDA>>
  }
}

/// Get network name
pub fn network_to_string(network: Network) -> String {
  case network {
    Mainnet -> "mainnet"
    Testnet -> "testnet"
    Testnet4 -> "testnet4"
    Signet -> "signet"
    Regtest -> "regtest"
  }
}

/// Parse network from string
pub fn network_from_string(s: String) -> Result(Network, String) {
  case s {
    "mainnet" | "main" -> Ok(Mainnet)
    "testnet" | "test" | "testnet3" -> Ok(Testnet)
    "testnet4" -> Ok(Testnet4)
    "signet" -> Ok(Signet)
    "regtest" -> Ok(Regtest)
    _ -> Error("Unknown network: " <> s)
  }
}

// ============================================================================
// Peer Selection
// ============================================================================

/// Peer quality score
pub type PeerScore {
  PeerScore(
    /// Base score
    score: Int,
    /// Whether peer supports services we need
    has_required_services: Bool,
    /// Latency in milliseconds
    latency_ms: Int,
    /// Number of successful connections
    connection_count: Int,
    /// Last connection timestamp
    last_connected: Int,
    /// Number of times peer misbehaved
    misbehavior_count: Int,
  )
}

/// Calculate peer priority score
pub fn calculate_peer_score(score: PeerScore) -> Int {
  let base = score.score

  // Bonus for required services
  let service_bonus = case score.has_required_services {
    True -> 100
    False -> 0
  }

  // Penalty for high latency
  let latency_penalty = case score.latency_ms {
    ms if ms < 100 -> 0
    ms if ms < 500 -> -10
    ms if ms < 1000 -> -30
    _ -> -50
  }

  // Bonus for reliable peers
  let reliability_bonus = int.min(score.connection_count * 5, 50)

  // Penalty for misbehavior
  let misbehavior_penalty = score.misbehavior_count * 20

  base
  + service_bonus
  + latency_penalty
  + reliability_bonus
  - misbehavior_penalty
}

/// Default peer score for new peer
pub fn default_peer_score() -> PeerScore {
  PeerScore(
    score: 50,
    has_required_services: False,
    latency_ms: 0,
    connection_count: 0,
    last_connected: 0,
    misbehavior_count: 0,
  )
}

/// Update score when peer connects successfully
pub fn peer_score_on_connect(score: PeerScore, timestamp: Int) -> PeerScore {
  PeerScore(
    ..score,
    connection_count: score.connection_count + 1,
    last_connected: timestamp,
  )
}

/// Update score when peer misbehaves
pub fn peer_score_on_misbehavior(score: PeerScore, severity: Int) -> PeerScore {
  PeerScore(
    ..score,
    misbehavior_count: score.misbehavior_count + 1,
    score: score.score - severity,
  )
}

/// Update score with measured latency
pub fn peer_score_set_latency(score: PeerScore, latency_ms: Int) -> PeerScore {
  PeerScore(..score, latency_ms: latency_ms)
}

/// Check if peer should be banned based on score
pub fn peer_should_ban(score: PeerScore) -> Bool {
  score.score < -100 || score.misbehavior_count > 10
}

// ============================================================================
// Connection Slots
// ============================================================================

/// Connection slot manager for outbound connections
pub type ConnectionSlots {
  ConnectionSlots(
    /// Maximum outbound connections
    max_outbound: Int,
    /// Current outbound count
    current_outbound: Int,
    /// Maximum inbound connections
    max_inbound: Int,
    /// Current inbound count
    current_inbound: Int,
    /// Reserved slots for specific purposes
    reserved_feeler: Int,
    reserved_block_relay: Int,
  )
}

/// Create default connection slots
pub fn connection_slots_new() -> ConnectionSlots {
  ConnectionSlots(
    max_outbound: 10,
    current_outbound: 0,
    max_inbound: 125,
    current_inbound: 0,
    reserved_feeler: 1,
    reserved_block_relay: 2,
  )
}

/// Check if we can make a new outbound connection
pub fn can_connect_outbound(slots: ConnectionSlots) -> Bool {
  slots.current_outbound < slots.max_outbound
}

/// Check if we can accept a new inbound connection
pub fn can_accept_inbound(slots: ConnectionSlots) -> Bool {
  slots.current_inbound < slots.max_inbound
}

/// Register new outbound connection
pub fn slots_add_outbound(slots: ConnectionSlots) -> ConnectionSlots {
  ConnectionSlots(..slots, current_outbound: slots.current_outbound + 1)
}

/// Register new inbound connection
pub fn slots_add_inbound(slots: ConnectionSlots) -> ConnectionSlots {
  ConnectionSlots(..slots, current_inbound: slots.current_inbound + 1)
}

/// Remove outbound connection
pub fn slots_remove_outbound(slots: ConnectionSlots) -> ConnectionSlots {
  ConnectionSlots(
    ..slots,
    current_outbound: int.max(0, slots.current_outbound - 1),
  )
}

/// Remove inbound connection
pub fn slots_remove_inbound(slots: ConnectionSlots) -> ConnectionSlots {
  ConnectionSlots(
    ..slots,
    current_inbound: int.max(0, slots.current_inbound - 1),
  )
}

/// Get total connection count
pub fn slots_total_connections(slots: ConnectionSlots) -> Int {
  slots.current_outbound + slots.current_inbound
}
