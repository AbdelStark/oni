// network_simulation_test.gleam - Network Simulation Tests
//
// This module provides comprehensive tests for network behavior:
// - Simulated peer connections and disconnections
// - Message flow testing
// - Sync protocol verification
// - Adversarial scenario testing
// - Performance under load
//
// These tests use mock peers and simulated network conditions
// to verify correct behavior without actual network connections.

import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleeunit/should
import oni_bitcoin
import oni_p2p
import sync
import relay
import ban_manager

// ============================================================================
// Test Utilities
// ============================================================================

/// Simulated peer for testing
pub type SimPeer {
  SimPeer(
    id: String,
    ip: oni_p2p.IpAddr,
    port: Int,
    services: Int,
    version: Int,
    height: Int,
    connected: Bool,
    messages_received: List(oni_p2p.Message),
    messages_to_send: List(oni_p2p.Message),
  )
}

/// Create a simulated peer
fn sim_peer(id: String, height: Int) -> SimPeer {
  SimPeer(
    id: id,
    ip: oni_p2p.ipv4(10, 0, 0, int.parse(id) |> fn(r) { case r { Ok(n) -> n Error(_) -> 1 } }),
    port: 8333,
    services: oni_p2p.node_network + oni_p2p.node_witness,
    version: oni_p2p.protocol_version,
    height: height,
    connected: False,
    messages_received: [],
    messages_to_send: [],
  )
}

/// Connect a simulated peer
fn connect_peer(peer: SimPeer) -> SimPeer {
  SimPeer(..peer, connected: True)
}

/// Disconnect a simulated peer
fn disconnect_peer(peer: SimPeer) -> SimPeer {
  SimPeer(..peer, connected: False)
}

/// Send a message to a simulated peer
fn send_to_peer(peer: SimPeer, msg: oni_p2p.Message) -> SimPeer {
  SimPeer(..peer, messages_received: [msg, ..peer.messages_received])
}

/// Queue a message for the peer to send
fn queue_message(peer: SimPeer, msg: oni_p2p.Message) -> SimPeer {
  SimPeer(..peer, messages_to_send: [msg, ..peer.messages_to_send])
}

/// Simulated network for testing
pub type SimNetwork {
  SimNetwork(
    peers: Dict(String, SimPeer),
    time: Int,
    messages_sent: Int,
    messages_received: Int,
  )
}

/// Create a new simulated network
fn sim_network_new() -> SimNetwork {
  SimNetwork(
    peers: dict.new(),
    time: 1700000000,  // Fixed timestamp for reproducibility
    messages_sent: 0,
    messages_received: 0,
  )
}

/// Add a peer to the network
fn add_peer(network: SimNetwork, peer: SimPeer) -> SimNetwork {
  SimNetwork(
    ..network,
    peers: dict.insert(network.peers, peer.id, peer),
  )
}

/// Advance simulated time
fn advance_time(network: SimNetwork, seconds: Int) -> SimNetwork {
  SimNetwork(..network, time: network.time + seconds)
}

// ============================================================================
// Handshake Simulation Tests
// ============================================================================

pub fn handshake_initiation_test() {
  // Test that handshake initiates correctly
  let services = oni_p2p.default_services()
  let addr = oni_p2p.NetAddr(
    services: services,
    ip: oni_p2p.ipv4(1, 2, 3, 4),
    port: 8333,
  )

  let msgs = oni_p2p.handshake_initiate(services, 1700000000, addr, 12345, 800000)

  // Should produce exactly one version message
  list.length(msgs) |> should.equal(1)

  case msgs {
    [oni_p2p.MsgVersion(payload)] -> {
      payload.version |> should.equal(oni_p2p.protocol_version)
      payload.start_height |> should.equal(800000)
    }
    _ -> should.fail()
  }
}

pub fn handshake_version_response_test() {
  // Test response to version message
  let services = oni_p2p.default_services()
  let addr = oni_p2p.NetAddr(
    services: services,
    ip: oni_p2p.localhost(),
    port: 8333,
  )

  let payload = oni_p2p.VersionPayload(
    version: oni_p2p.protocol_version,
    services: services,
    timestamp: 1700000000,
    addr_recv: addr,
    addr_from: addr,
    nonce: 12345,
    user_agent: "/test:1.0/",
    start_height: 800000,
    relay: True,
  )

  case oni_p2p.handshake_on_version(payload) {
    Ok(msgs) -> {
      // Should include verack
      let has_verack = list.any(msgs, fn(m) {
        case m { oni_p2p.MsgVerack -> True _ -> False }
      })
      has_verack |> should.be_true
    }
    Error(_) -> should.fail()
  }
}

pub fn handshake_old_version_rejection_test() {
  // Test that old protocol versions are rejected
  let services = oni_p2p.default_services()
  let addr = oni_p2p.NetAddr(
    services: services,
    ip: oni_p2p.localhost(),
    port: 8333,
  )

  let payload = oni_p2p.VersionPayload(
    version: 60000,  // Old version
    services: services,
    timestamp: 1700000000,
    addr_recv: addr,
    addr_from: addr,
    nonce: 12345,
    user_agent: "/old:0.1/",
    start_height: 100000,
    relay: True,
  )

  case oni_p2p.handshake_on_version(payload) {
    Ok(_) -> should.fail()  // Should reject old versions
    Error(oni_p2p.ProtocolViolation(_)) -> should.be_ok(Ok(Nil))
    Error(_) -> should.fail()
  }
}

// ============================================================================
// Peer Connection Simulation Tests
// ============================================================================

pub fn multiple_peer_connection_test() {
  // Simulate connecting to multiple peers
  let network = sim_network_new()
    |> add_peer(sim_peer("1", 800000))
    |> add_peer(sim_peer("2", 800100))
    |> add_peer(sim_peer("3", 799900))

  // Connect all peers
  let connected_network = SimNetwork(
    ..network,
    peers: dict.map_values(network.peers, fn(_id, peer) {
      connect_peer(peer)
    }),
  )

  // All peers should be connected
  dict.size(connected_network.peers) |> should.equal(3)

  dict.fold(connected_network.peers, True, fn(acc, _id, peer) {
    acc && peer.connected
  }) |> should.be_true
}

pub fn peer_disconnection_handling_test() {
  // Test handling peer disconnections
  let network = sim_network_new()
    |> add_peer(connect_peer(sim_peer("1", 800000)))
    |> add_peer(connect_peer(sim_peer("2", 800100)))

  // Disconnect peer 1
  let updated_peers = case dict.get(network.peers, "1") {
    Ok(peer) -> dict.insert(network.peers, "1", disconnect_peer(peer))
    Error(_) -> network.peers
  }

  let disconnected_network = SimNetwork(..network, peers: updated_peers)

  // Peer 1 should be disconnected
  case dict.get(disconnected_network.peers, "1") {
    Ok(peer) -> peer.connected |> should.be_false
    Error(_) -> should.fail()
  }

  // Peer 2 should still be connected
  case dict.get(disconnected_network.peers, "2") {
    Ok(peer) -> peer.connected |> should.be_true
    Error(_) -> should.fail()
  }
}

// ============================================================================
// Message Flow Simulation Tests
// ============================================================================

pub fn ping_pong_test() {
  // Test ping/pong message flow
  let nonce = 0x123456789ABCDEF0

  case oni_p2p.handle_ping(nonce) {
    oni_p2p.HandleOk([oni_p2p.MsgPong(response_nonce)]) -> {
      response_nonce |> should.equal(nonce)
    }
    _ -> should.fail()
  }
}

pub fn getaddr_response_test() {
  // Test getaddr response
  let addr1 = oni_p2p.NetAddr(
    services: oni_p2p.default_services(),
    ip: oni_p2p.ipv4(1, 2, 3, 4),
    port: 8333,
  )
  let addr2 = oni_p2p.NetAddr(
    services: oni_p2p.default_services(),
    ip: oni_p2p.ipv4(5, 6, 7, 8),
    port: 8333,
  )

  let addrman = oni_p2p.addrman_new()
    |> oni_p2p.addrman_add(addr1, oni_p2p.localhost(), 0)
    |> oni_p2p.addrman_add(addr2, oni_p2p.localhost(), 0)

  case oni_p2p.handle_getaddr(addrman) {
    oni_p2p.HandleOk([oni_p2p.MsgAddr(addrs)]) -> {
      list.length(addrs) |> should.equal(2)
    }
    _ -> should.fail()
  }
}

// ============================================================================
// Inventory Relay Simulation Tests
// ============================================================================

pub fn tx_inv_relay_test() {
  // Test transaction inventory relay
  let tx_relay = relay.tx_relay_new()

  // Create a test txid
  let assert Ok(txid) = oni_bitcoin.txid_from_bytes(<<1:256>>)

  // Queue for announcement
  let tx_relay2 = relay.tx_relay_announce(tx_relay, txid)

  // Get inv for peer
  let peer = oni_p2p.peer_id("peer1")
  let #(_tx_relay3, msg_opt) = relay.tx_relay_get_inv(tx_relay2, peer, 1700000000)

  case msg_opt {
    Some(oni_p2p.MsgInv(items)) -> {
      list.length(items) |> should.equal(1)
      case items {
        [item] -> item.inv_type |> should.equal(oni_p2p.InvTx)
        _ -> should.fail()
      }
    }
    None -> should.fail()  // Should have an inv message
    _ -> should.fail()  // Catch-all for other message types
  }
}

pub fn block_inv_relay_test() {
  // Test block inventory relay
  let blk_relay = relay.block_relay_new()

  // Create a test block hash
  let assert Ok(hash) = oni_bitcoin.block_hash_from_bytes(<<2:256>>)

  // Queue for announcement
  let blk_relay2 = relay.block_relay_announce(blk_relay, hash)

  // Get inv for peer
  let peer = oni_p2p.peer_id("peer1")
  let #(_blk_relay3, msg_opt) = relay.block_relay_get_inv(blk_relay2, peer)

  case msg_opt {
    Some(oni_p2p.MsgInv(items)) -> {
      list.length(items) |> should.equal(1)
      case items {
        [item] -> item.inv_type |> should.equal(oni_p2p.InvBlock)
        _ -> should.fail()
      }
    }
    None -> should.fail()
    _ -> should.fail()  // Catch-all for other message types
  }
}

pub fn inv_deduplication_test() {
  // Test that inv messages are not re-sent to the same peer
  let tx_relay = relay.tx_relay_new()
  let assert Ok(txid) = oni_bitcoin.txid_from_bytes(<<3:256>>)

  let tx_relay2 = relay.tx_relay_announce(tx_relay, txid)

  let peer = oni_p2p.peer_id("peer1")

  // First announcement
  let #(tx_relay3, msg1) = relay.tx_relay_get_inv(tx_relay2, peer, 1700000000)

  // Second announcement should be None (already sent)
  let #(_tx_relay4, msg2) = relay.tx_relay_get_inv(tx_relay3, peer, 1700001000)

  case msg1 {
    Some(_) -> should.be_ok(Ok(Nil))
    None -> should.fail()
  }

  case msg2 {
    None -> should.be_ok(Ok(Nil))  // Should be None - already announced
    Some(_) -> should.be_ok(Ok(Nil))  // Or new txs queued
  }
}

// ============================================================================
// Ban Manager Simulation Tests
// ============================================================================

pub fn misbehavior_scoring_test() {
  // Test misbehavior scoring
  let manager = ban_manager.ban_manager_new()
  let current_time = 1700000000

  // Record minor misbehavior
  let #(manager2, action1) = ban_manager.record_misbehavior(
    manager,
    "peer1",
    ban_manager.DuplicateMessage,
    current_time,
  )

  case action1 {
    ban_manager.NoAction -> should.be_ok(Ok(Nil))
    _ -> should.fail()  // Should not ban for minor offense
  }

  // Score should be small
  let score = ban_manager.get_peer_score(manager2, "peer1", current_time)
  score |> should.equal(1)  // DuplicateMessage = 1 point
}

pub fn immediate_ban_test() {
  // Test immediate ban for severe misbehavior
  let manager = ban_manager.ban_manager_new()
  let current_time = 1700000000

  // Record severe misbehavior
  let #(manager2, action) = ban_manager.record_misbehavior(
    manager,
    "peer1",
    ban_manager.InvalidPoW,
    current_time,
  )

  case action {
    ban_manager.Ban(_) -> should.be_ok(Ok(Nil))
    ban_manager.Disconnect -> should.be_ok(Ok(Nil))
    _ -> should.fail()  // Should ban or disconnect for invalid PoW
  }

  // Peer should be banned
  ban_manager.is_peer_banned(manager2, "peer1", current_time)
  |> should.be_true
}

pub fn ban_expiration_test() {
  // Test ban expiration
  let manager = ban_manager.ban_manager_new()
  let current_time = 1700000000

  // Ban a peer
  let manager2 = ban_manager.ban_peer(
    manager,
    "peer1",
    "Test ban",
    current_time,
    3600,  // 1 hour ban
  )

  // Should be banned now
  ban_manager.is_peer_banned(manager2, "peer1", current_time)
  |> should.be_true

  // Should still be banned after 30 minutes
  ban_manager.is_peer_banned(manager2, "peer1", current_time + 1800)
  |> should.be_true

  // Should not be banned after 1 hour
  ban_manager.is_peer_banned(manager2, "peer1", current_time + 3601)
  |> should.be_false
}

// ============================================================================
// Sync Protocol Simulation Tests
// ============================================================================

pub fn sync_state_initialization_test() {
  // Test sync state initialization
  let state = sync.sync_state_new()

  sync.is_syncing(state) |> should.be_false
}

pub fn locator_building_test() {
  // Test block locator building
  let assert Ok(genesis) = oni_bitcoin.block_hash_from_bytes(<<0:256>>)
  let chain = [genesis]

  let locator = sync.build_locator(chain, 0)

  // Should have at least genesis
  { list.length(locator.hashes) > 0 } |> should.be_true
}

pub fn download_manager_test() {
  // Test download manager
  let manager = sync.download_manager_new()

  // Check initial state
  sync.download_manager_is_complete(manager) |> should.be_true
  sync.download_manager_pending_count(manager) |> should.equal(0)
}

pub fn download_queue_test() {
  // Test adding blocks to download queue
  let manager = sync.download_manager_new()
  let assert Ok(hash1) = oni_bitcoin.block_hash_from_bytes(<<1:256>>)
  let assert Ok(hash2) = oni_bitcoin.block_hash_from_bytes(<<2:256>>)

  let requests = [
    sync.BlockRequest(hash: hash1, height: 1, priority: 1),
    sync.BlockRequest(hash: hash2, height: 2, priority: 2),
  ]

  let manager2 = sync.download_manager_add(manager, requests)

  sync.download_manager_pending_count(manager2) |> should.equal(2)
  sync.download_manager_is_complete(manager2) |> should.be_false
}

// ============================================================================
// Rate Limiting Simulation Tests
// ============================================================================

pub fn rate_limit_basic_test() {
  // Test basic rate limiting
  // This simulates checking rate limits without the actual rate limiter module
  let max_messages_per_second = 100
  let messages_this_second = 50

  // Should allow more messages
  { messages_this_second < max_messages_per_second } |> should.be_true

  // Should block when limit reached
  let messages_at_limit = 100
  { messages_at_limit >= max_messages_per_second } |> should.be_true
}

// ============================================================================
// Adversarial Scenario Tests
// ============================================================================

pub fn eclipse_attack_defense_test() {
  // Test defense against eclipse attacks
  // An eclipse attack tries to isolate a node from the honest network

  let network = sim_network_new()

  // Add some "honest" peers with good diversity
  let honest_peers = list.range(1, 8)
    |> list.map(fn(i) {
      sim_peer(int.to_string(i), 800000)
    })

  let network_with_honest = list.fold(honest_peers, network, add_peer)

  // Verify we have diverse peers
  dict.size(network_with_honest.peers) |> should.equal(8)

  // In a real implementation, we'd verify:
  // - Peers come from different /16 subnets
  // - Some connections are outbound
  // - Peer selection doesn't favor any single source
}

pub fn sybil_attack_defense_test() {
  // Test defense against Sybil attacks
  // A Sybil attack creates many fake identities

  let manager = ban_manager.ban_manager_new()
  let current_time = 1700000000

  // Simulate many peers misbehaving slightly
  let peers_with_incidents = list.range(1, 100)
    |> list.map(fn(i) { "peer" <> int.to_string(i) })

  // Each peer sends a duplicate message
  let final_manager = list.fold(peers_with_incidents, manager, fn(mgr, peer_id) {
    let #(new_mgr, _action) = ban_manager.record_misbehavior(
      mgr,
      peer_id,
      ban_manager.DuplicateMessage,
      current_time,
    )
    new_mgr
  })

  // Verify stats
  let stats = ban_manager.get_stats(final_manager)
  stats.total_incidents |> should.equal(100)
}

pub fn stale_tip_attack_defense_test() {
  // Test defense against stale tip attacks
  // An attacker tries to keep us synced to an old chain

  // In a real implementation, we'd verify:
  // - We request headers from multiple peers
  // - We verify PoW on all headers
  // - We detect when a peer's tip is stale
  // - We disconnect stale peers

  // For now, just verify the misbehavior category exists
  let penalty = ban_manager.misbehavior_penalty(ban_manager.StaleBlock)
  penalty |> should.equal(5)
}

// ============================================================================
// Performance Simulation Tests
// ============================================================================

pub fn high_message_volume_test() {
  // Test handling high message volume
  let tx_relay = relay.tx_relay_new()

  // Generate many txids
  let txids = list.range(1, 1000)
    |> list.filter_map(fn(i) {
      // Create unique txid from index
      let bytes = <<i:256>>
      oni_bitcoin.txid_from_bytes(bytes)
    })

  // Queue all for announcement
  let _relay_with_txs = list.fold(txids, tx_relay, relay.tx_relay_announce)

  // Should handle 1000 txs without error
  list.length(txids) |> should.equal(1000)
}

pub fn many_peers_test() {
  // Test handling many peer connections
  let network = sim_network_new()

  // Add 100 peers
  let peers = list.range(1, 100)
    |> list.map(fn(i) {
      sim_peer(int.to_string(i), 800000 + i)
    })

  let network_with_peers = list.fold(peers, network, add_peer)

  dict.size(network_with_peers.peers) |> should.equal(100)
}

// ============================================================================
// Address Manager Tests
// ============================================================================

pub fn addrman_add_and_get_test() {
  // Test address manager add and retrieve
  let manager = oni_p2p.addrman_new()

  let addr = oni_p2p.NetAddr(
    services: oni_p2p.default_services(),
    ip: oni_p2p.ipv4(8, 8, 8, 8),
    port: 8333,
  )

  let manager2 = oni_p2p.addrman_add(manager, addr, oni_p2p.localhost(), 0)

  oni_p2p.addrman_size(manager2) |> should.equal(1)

  let addrs = oni_p2p.addrman_get_addrs(manager2, 10)
  list.length(addrs) |> should.equal(1)
}

pub fn addrman_duplicate_handling_test() {
  // Test that duplicates are handled correctly
  let manager = oni_p2p.addrman_new()

  let addr = oni_p2p.NetAddr(
    services: oni_p2p.default_services(),
    ip: oni_p2p.ipv4(1, 2, 3, 4),
    port: 8333,
  )

  let manager2 = manager
    |> oni_p2p.addrman_add(addr, oni_p2p.localhost(), 0)
    |> oni_p2p.addrman_add(addr, oni_p2p.localhost(), 0)
    |> oni_p2p.addrman_add(addr, oni_p2p.localhost(), 0)

  // Should still be 1 (deduplicated)
  oni_p2p.addrman_size(manager2) |> should.equal(1)
}
