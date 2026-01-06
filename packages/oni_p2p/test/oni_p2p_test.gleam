import gleeunit
import gleeunit/should
import oni_bitcoin
import oni_p2p

pub fn main() {
  gleeunit.main()
}

// ============================================================================
// Peer ID Tests
// ============================================================================

pub fn peer_id_test() {
  oni_p2p.peer_id("peer1")
  |> should.equal(oni_p2p.PeerId("peer1"))
}

pub fn peer_id_from_addr_test() {
  let ip = oni_p2p.ipv4(192, 168, 1, 1)
  let id = oni_p2p.peer_id_from_addr(ip, 8333)
  oni_p2p.peer_id_to_string(id)
  |> should.equal("192.168.1.1:8333")
}

// ============================================================================
// IP Address Tests
// ============================================================================

pub fn ipv4_test() {
  let ip = oni_p2p.ipv4(127, 0, 0, 1)
  oni_p2p.ip_to_string(ip)
  |> should.equal("127.0.0.1")
}

pub fn localhost_test() {
  let ip = oni_p2p.localhost()
  oni_p2p.ip_to_string(ip)
  |> should.equal("127.0.0.1")
}

pub fn ip_encode_decode_ipv4_test() {
  let ip = oni_p2p.ipv4(192, 168, 1, 100)
  let encoded = oni_p2p.encode_ip(ip)

  // IPv4-mapped IPv6 should be 16 bytes
  let size = encoded |> get_byte_size
  size |> should.equal(16)

  // Decode should give back same IP
  case oni_p2p.decode_ip(encoded) {
    Ok(decoded) ->
      oni_p2p.ip_to_string(decoded) |> should.equal("192.168.1.100")
    Error(_) -> should.fail()
  }
}

// ============================================================================
// Service Flags Tests
// ============================================================================

pub fn service_flags_test() {
  let flags = oni_p2p.service_flags_from_int(0)
  oni_p2p.service_flags_to_int(flags)
  |> should.equal(0)
}

pub fn service_flags_has_test() {
  let flags =
    oni_p2p.service_flags_from_int(oni_p2p.node_network + oni_p2p.node_witness)

  oni_p2p.service_flags_has(flags, oni_p2p.node_network)
  |> should.be_true

  oni_p2p.service_flags_has(flags, oni_p2p.node_witness)
  |> should.be_true

  oni_p2p.service_flags_has(flags, oni_p2p.node_bloom)
  |> should.be_false
}

pub fn service_flags_add_test() {
  let flags = oni_p2p.service_flags_from_int(oni_p2p.node_network)
  let updated = oni_p2p.service_flags_add(flags, oni_p2p.node_witness)

  oni_p2p.service_flags_has(updated, oni_p2p.node_network)
  |> should.be_true

  oni_p2p.service_flags_has(updated, oni_p2p.node_witness)
  |> should.be_true
}

pub fn default_services_test() {
  let services = oni_p2p.default_services()

  oni_p2p.service_flags_has(services, oni_p2p.node_network)
  |> should.be_true

  oni_p2p.service_flags_has(services, oni_p2p.node_witness)
  |> should.be_true
}

// ============================================================================
// Inventory Type Tests
// ============================================================================

pub fn inv_type_roundtrip_test() {
  // Test each inventory type
  [
    #(oni_p2p.InvError, 0),
    #(oni_p2p.InvTx, 1),
    #(oni_p2p.InvBlock, 2),
    #(oni_p2p.InvFilteredBlock, 3),
    #(oni_p2p.InvCmpctBlock, 4),
    #(oni_p2p.InvWitnessTx, 0x40000001),
    #(oni_p2p.InvWitnessBlock, 0x40000002),
  ]
  |> check_inv_types
}

fn check_inv_types(pairs: List(#(oni_p2p.InvType, Int))) -> Nil {
  case pairs {
    [] -> Nil
    [#(inv_type, expected_int), ..rest] -> {
      oni_p2p.inv_type_to_int(inv_type) |> should.equal(expected_int)
      oni_p2p.inv_type_from_int(expected_int) |> should.equal(inv_type)
      check_inv_types(rest)
    }
  }
}

// ============================================================================
// Network Magic Tests
// ============================================================================

pub fn network_magic_mainnet_test() {
  oni_p2p.network_magic(oni_bitcoin.Mainnet)
  |> should.equal(0xD9B4BEF9)
}

pub fn network_magic_testnet_test() {
  oni_p2p.network_magic(oni_bitcoin.Testnet)
  |> should.equal(0x0709110B)
}

pub fn network_magic_regtest_test() {
  oni_p2p.network_magic(oni_bitcoin.Regtest)
  |> should.equal(0xDAB5BFFA)
}

pub fn network_magic_signet_test() {
  oni_p2p.network_magic(oni_bitcoin.Signet)
  |> should.equal(0x40CF030A)
}

// ============================================================================
// Peer State Tests
// ============================================================================

pub fn peer_info_new_test() {
  let ip = oni_p2p.ipv4(10, 0, 0, 1)
  let addr =
    oni_p2p.NetAddr(services: oni_p2p.default_services(), ip: ip, port: 8333)
  let id = oni_p2p.peer_id("test-peer")
  let peer = oni_p2p.peer_info_new(id, addr, False)

  peer.state |> should.equal(oni_p2p.Connecting)
  peer.inbound |> should.be_false
  peer.misbehavior_score |> should.equal(0)
}

pub fn peer_set_state_test() {
  let ip = oni_p2p.localhost()
  let addr =
    oni_p2p.NetAddr(services: oni_p2p.default_services(), ip: ip, port: 8333)
  let id = oni_p2p.peer_id("test")
  let peer = oni_p2p.peer_info_new(id, addr, True)

  let updated = oni_p2p.peer_set_state(peer, oni_p2p.Ready)
  updated.state |> should.equal(oni_p2p.Ready)
}

pub fn peer_misbehaving_test() {
  let ip = oni_p2p.localhost()
  let addr =
    oni_p2p.NetAddr(services: oni_p2p.default_services(), ip: ip, port: 8333)
  let id = oni_p2p.peer_id("test")
  let peer = oni_p2p.peer_info_new(id, addr, False)

  // Add misbehavior score
  let updated = oni_p2p.peer_misbehaving(peer, 50)
  updated.misbehavior_score |> should.equal(50)
  oni_p2p.peer_is_banned(updated) |> should.be_false

  // Add more to exceed threshold
  let banned = oni_p2p.peer_misbehaving(updated, 50)
  banned.misbehavior_score |> should.equal(100)
  oni_p2p.peer_is_banned(banned) |> should.be_true
}

// ============================================================================
// Address Manager Tests
// ============================================================================

pub fn addrman_new_test() {
  let manager = oni_p2p.addrman_new()
  oni_p2p.addrman_size(manager) |> should.equal(0)
}

pub fn addrman_add_test() {
  let manager = oni_p2p.addrman_new()

  let addr =
    oni_p2p.NetAddr(
      services: oni_p2p.default_services(),
      ip: oni_p2p.ipv4(1, 2, 3, 4),
      port: 8333,
    )
  let source = oni_p2p.localhost()

  let updated = oni_p2p.addrman_add(manager, addr, source, 0)
  oni_p2p.addrman_size(updated) |> should.equal(1)

  // Adding same address again should not increase count
  let updated2 = oni_p2p.addrman_add(updated, addr, source, 0)
  oni_p2p.addrman_size(updated2) |> should.equal(1)
}

pub fn addrman_multiple_addrs_test() {
  let manager = oni_p2p.addrman_new()
  let source = oni_p2p.localhost()

  let addr1 =
    oni_p2p.NetAddr(
      services: oni_p2p.default_services(),
      ip: oni_p2p.ipv4(1, 1, 1, 1),
      port: 8333,
    )
  let addr2 =
    oni_p2p.NetAddr(
      services: oni_p2p.default_services(),
      ip: oni_p2p.ipv4(2, 2, 2, 2),
      port: 8333,
    )
  let addr3 =
    oni_p2p.NetAddr(
      services: oni_p2p.default_services(),
      ip: oni_p2p.ipv4(3, 3, 3, 3),
      port: 8333,
    )

  let m1 = oni_p2p.addrman_add(manager, addr1, source, 0)
  let m2 = oni_p2p.addrman_add(m1, addr2, source, 0)
  let m3 = oni_p2p.addrman_add(m2, addr3, source, 0)

  oni_p2p.addrman_size(m3) |> should.equal(3)
}

// ============================================================================
// Handshake Tests
// ============================================================================

pub fn handshake_initiate_test() {
  let services = oni_p2p.default_services()
  let addr =
    oni_p2p.NetAddr(
      services: services,
      ip: oni_p2p.ipv4(1, 2, 3, 4),
      port: 8333,
    )

  let msgs =
    oni_p2p.handshake_initiate(services, 1_234_567_890, addr, 12_345, 800_000)

  // Should contain exactly one version message
  case msgs {
    [oni_p2p.MsgVersion(_)] -> should.be_ok(Ok(Nil))
    _ -> should.fail()
  }
}

pub fn handshake_on_version_test() {
  let services = oni_p2p.default_services()
  let addr =
    oni_p2p.NetAddr(services: services, ip: oni_p2p.localhost(), port: 8333)

  let payload =
    oni_p2p.VersionPayload(
      version: oni_p2p.protocol_version,
      services: services,
      timestamp: 1_234_567_890,
      addr_recv: addr,
      addr_from: addr,
      nonce: 12_345,
      user_agent: "/test:1.0/",
      start_height: 800_000,
      relay: True,
    )

  case oni_p2p.handshake_on_version(payload) {
    Ok(msgs) -> {
      // Should include verack
      case has_verack(msgs) {
        True -> should.be_ok(Ok(Nil))
        False -> should.fail()
      }
    }
    Error(_) -> should.fail()
  }
}

pub fn handshake_old_version_rejected_test() {
  let services = oni_p2p.default_services()
  let addr =
    oni_p2p.NetAddr(services: services, ip: oni_p2p.localhost(), port: 8333)

  // Old protocol version should be rejected
  let payload =
    oni_p2p.VersionPayload(
      version: 60_000,
      // Too old
      services: services,
      timestamp: 1_234_567_890,
      addr_recv: addr,
      addr_from: addr,
      nonce: 12_345,
      user_agent: "/old:0.1/",
      start_height: 800_000,
      relay: True,
    )

  case oni_p2p.handshake_on_version(payload) {
    Ok(_) -> should.fail()
    Error(oni_p2p.ProtocolViolation(_)) -> should.be_ok(Ok(Nil))
    Error(_) -> should.fail()
  }
}

fn has_verack(msgs: List(oni_p2p.Message)) -> Bool {
  case msgs {
    [] -> False
    [oni_p2p.MsgVerack, ..] -> True
    [_, ..rest] -> has_verack(rest)
  }
}

// ============================================================================
// Message Handler Tests
// ============================================================================

pub fn handle_ping_test() {
  case oni_p2p.handle_ping(42) {
    oni_p2p.HandleOk([oni_p2p.MsgPong(42)]) -> should.be_ok(Ok(Nil))
    _ -> should.fail()
  }
}

pub fn handle_pong_test() {
  case oni_p2p.handle_pong(42) {
    oni_p2p.HandleOk([]) -> should.be_ok(Ok(Nil))
    _ -> should.fail()
  }
}

pub fn handle_sendheaders_test() {
  case oni_p2p.handle_sendheaders() {
    oni_p2p.HandleOk([]) -> should.be_ok(Ok(Nil))
    _ -> should.fail()
  }
}

// ============================================================================
// Inventory Creation Tests
// ============================================================================

pub fn create_block_inv_test() {
  let assert Ok(hash) = oni_bitcoin.block_hash_from_bytes(<<0:256>>)

  case oni_p2p.create_block_inv([hash]) {
    oni_p2p.MsgInv([item]) -> {
      item.inv_type |> should.equal(oni_p2p.InvBlock)
    }
    _ -> should.fail()
  }
}

pub fn create_tx_inv_test() {
  let assert Ok(txid) = oni_bitcoin.txid_from_bytes(<<0:256>>)

  case oni_p2p.create_tx_inv([txid]) {
    oni_p2p.MsgInv([item]) -> {
      item.inv_type |> should.equal(oni_p2p.InvTx)
    }
    _ -> should.fail()
  }
}

pub fn create_getdata_txs_witness_test() {
  let assert Ok(txid) = oni_bitcoin.txid_from_bytes(<<0:256>>)

  case oni_p2p.create_getdata_txs([txid], True) {
    oni_p2p.MsgGetData([item]) -> {
      item.inv_type |> should.equal(oni_p2p.InvWitnessTx)
    }
    _ -> should.fail()
  }
}

// ============================================================================
// Connection Config Tests
// ============================================================================

pub fn default_conn_config_test() {
  let config = oni_p2p.default_conn_config()

  config.max_inbound |> should.equal(117)
  config.max_outbound |> should.equal(11)
  config.listen_port |> should.equal(8333)
}

pub fn conn_stats_new_test() {
  let stats = oni_p2p.conn_stats_new()

  stats.num_inbound |> should.equal(0)
  stats.num_outbound |> should.equal(0)
  stats.bytes_sent |> should.equal(0)
  stats.bytes_recv |> should.equal(0)
}

// ============================================================================
// Helper Functions
// ============================================================================

fn get_byte_size(data: BitArray) -> Int {
  do_byte_size(data, 0)
}

fn do_byte_size(data: BitArray, acc: Int) -> Int {
  case data {
    <<_:8, rest:bits>> -> do_byte_size(rest, acc + 1)
    _ -> acc
  }
}
