// network_sim.gleam - Network Simulation and Adversary Testing
//
// This module provides infrastructure for testing P2P robustness:
// - Simulated network with configurable topology
// - Adversary node behaviors (eclipse, sybil, selfish mining)
// - Network condition simulation (latency, partition, drops)
// - Invariant checking during simulation
// - Chaos testing framework
//
// Purpose: Validate network resilience and security properties

import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import oni_bitcoin

// ============================================================================
// Constants
// ============================================================================

/// Maximum simulated nodes
pub const max_sim_nodes = 1000

/// Default simulation tick interval (ms)
pub const tick_interval_ms = 100

/// Default network latency (ms)
pub const default_latency_ms = 50

/// Packet drop probability for unstable connections
pub const unstable_drop_rate = 0.1

// ============================================================================
// Core Types
// ============================================================================

/// Simulation configuration
pub type SimConfig {
  SimConfig(
    /// Number of honest nodes
    honest_nodes: Int,
    /// Number of adversary nodes
    adversary_nodes: Int,
    /// Network topology
    topology: Topology,
    /// Base latency in milliseconds
    base_latency_ms: Int,
    /// Latency variance
    latency_variance: Float,
    /// Simulation duration (ticks)
    duration_ticks: Int,
    /// Random seed for reproducibility
    seed: Int,
    /// Adversary strategy
    adversary_strategy: AdversaryStrategy,
    /// Network conditions
    conditions: NetworkConditions,
  )
}

/// Network topology types
pub type Topology {
  /// Random connections (Erdos-Renyi)
  RandomGraph(connection_probability: Float)
  /// Small-world network (Watts-Strogatz)
  SmallWorld(k: Int, rewire_probability: Float)
  /// Scale-free network (Barabasi-Albert)
  ScaleFree(initial_connections: Int)
  /// Bitcoin-like (limited outbound, more inbound)
  BitcoinLike(outbound: Int, max_inbound: Int)
  /// Fully connected (for small tests)
  FullMesh
}

/// Adversary strategies
pub type AdversaryStrategy {
  /// No adversary behavior
  Honest
  /// Eclipse attack - isolate target nodes
  Eclipse(targets: List(Int))
  /// Sybil attack - create fake identities
  Sybil(fake_nodes: Int)
  /// Selfish mining
  SelfishMining(hashpower_fraction: Float)
  /// Double spend attempt
  DoubleSpend(target_confirmations: Int)
  /// Block withholding
  BlockWithholding(withhold_probability: Float)
  /// Tx censorship
  TxCensorship(censor_txids: List(String))
  /// Combined attacks
  Combined(strategies: List(AdversaryStrategy))
}

/// Network conditions for chaos testing
pub type NetworkConditions {
  NetworkConditions(
    /// Packet drop rate (0.0 - 1.0)
    drop_rate: Float,
    /// Latency multiplier
    latency_multiplier: Float,
    /// Network partitions (list of node groups)
    partitions: List(List(Int)),
    /// Bandwidth limit (bytes/sec, 0 = unlimited)
    bandwidth_limit: Int,
    /// Jitter (latency variance)
    jitter: Float,
  )
}

/// Simulated node
pub type SimNode {
  SimNode(
    id: Int,
    is_adversary: Bool,
    connections: List(Int),
    state: NodeState,
    inbox: List(SimMessage),
    outbox: List(SimMessage),
    metrics: NodeMetrics,
  )
}

/// Node state in simulation
pub type NodeState {
  NodeState(
    /// Best block height
    height: Int,
    /// Best block hash
    best_block: String,
    /// Known transactions
    mempool: Dict(String, SimTx),
    /// Blocks received
    blocks_received: Int,
    /// Is synced with network
    is_synced: Bool,
  )
}

/// Node metrics
pub type NodeMetrics {
  NodeMetrics(
    messages_sent: Int,
    messages_received: Int,
    blocks_mined: Int,
    blocks_orphaned: Int,
    reorgs_experienced: Int,
    eclipse_duration_ticks: Int,
  )
}

/// Simulated message
pub type SimMessage {
  SimMessage(
    from: Int,
    to: Int,
    msg_type: MessageType,
    payload: BitArray,
    delay_ticks: Int,
  )
}

/// Message types for simulation
pub type MessageType {
  MsgBlock
  MsgTx
  MsgInv
  MsgGetData
  MsgHeaders
  MsgGetHeaders
  MsgPing
  MsgPong
  MsgAddr
  MsgVersion
  MsgVerack
}

/// Simulated transaction
pub type SimTx {
  SimTx(
    txid: String,
    fee: Int,
    size: Int,
    created_tick: Int,
    confirmed_tick: Option(Int),
  )
}

/// Simulated block
pub type SimBlock {
  SimBlock(
    hash: String,
    prev_hash: String,
    height: Int,
    miner: Int,
    txids: List(String),
    timestamp: Int,
  )
}

/// Simulation state
pub type SimState {
  SimState(
    config: SimConfig,
    nodes: Dict(Int, SimNode),
    pending_messages: List(SimMessage),
    current_tick: Int,
    blocks: Dict(String, SimBlock),
    chain_tips: List(String),
    events: List(SimEvent),
    invariant_violations: List(InvariantViolation),
    rng_state: Int,
  )
}

/// Simulation events for analysis
pub type SimEvent {
  BlockMined(tick: Int, miner: Int, hash: String, height: Int)
  BlockReceived(tick: Int, node: Int, hash: String)
  TxBroadcast(tick: Int, node: Int, txid: String)
  TxConfirmed(tick: Int, txid: String, block: String)
  Reorg(tick: Int, node: Int, old_tip: String, new_tip: String, depth: Int)
  Eclipse(tick: Int, target: Int, isolated: Bool)
  DoubleSpendAttempt(tick: Int, original: String, double: String)
  Partition(tick: Int, groups: List(List(Int)))
}

/// Invariant violations
pub type InvariantViolation {
  InvariantViolation(
    tick: Int,
    invariant: String,
    details: String,
    severity: Severity,
  )
}

/// Severity levels
pub type Severity {
  Critical
  High
  Medium
  Low
}

// ============================================================================
// Simulation Creation
// ============================================================================

/// Create a new simulation
pub fn create_simulation(config: SimConfig) -> SimState {
  let nodes = create_nodes(config)
  let connected_nodes = connect_nodes(nodes, config.topology, config.seed)

  SimState(
    config: config,
    nodes: connected_nodes,
    pending_messages: [],
    current_tick: 0,
    blocks: dict.insert(dict.new(), "genesis", genesis_block()),
    chain_tips: ["genesis"],
    events: [],
    invariant_violations: [],
    rng_state: config.seed,
  )
}

fn create_nodes(config: SimConfig) -> Dict(Int, SimNode) {
  let total = config.honest_nodes + config.adversary_nodes

  list.range(0, total - 1)
  |> list.fold(dict.new(), fn(acc, id) {
    let is_adversary = id >= config.honest_nodes
    let node = SimNode(
      id: id,
      is_adversary: is_adversary,
      connections: [],
      state: initial_node_state(),
      inbox: [],
      outbox: [],
      metrics: initial_metrics(),
    )
    dict.insert(acc, id, node)
  })
}

fn initial_node_state() -> NodeState {
  NodeState(
    height: 0,
    best_block: "genesis",
    mempool: dict.new(),
    blocks_received: 0,
    is_synced: False,
  )
}

fn initial_metrics() -> NodeMetrics {
  NodeMetrics(
    messages_sent: 0,
    messages_received: 0,
    blocks_mined: 0,
    blocks_orphaned: 0,
    reorgs_experienced: 0,
    eclipse_duration_ticks: 0,
  )
}

fn genesis_block() -> SimBlock {
  SimBlock(
    hash: "genesis",
    prev_hash: "",
    height: 0,
    miner: -1,
    txids: [],
    timestamp: 0,
  )
}

fn connect_nodes(
  nodes: Dict(Int, SimNode),
  topology: Topology,
  seed: Int,
) -> Dict(Int, SimNode) {
  case topology {
    BitcoinLike(outbound, _max_inbound) ->
      connect_bitcoin_like(nodes, outbound, seed)
    RandomGraph(prob) ->
      connect_random(nodes, prob, seed)
    FullMesh ->
      connect_full_mesh(nodes)
    _ ->
      connect_bitcoin_like(nodes, 8, seed)  // Default to Bitcoin-like
  }
}

fn connect_bitcoin_like(
  nodes: Dict(Int, SimNode),
  outbound: Int,
  seed: Int,
) -> Dict(Int, SimNode) {
  let node_ids = dict.keys(nodes)
  let count = list.length(node_ids)

  dict.map_values(nodes, fn(id, node) {
    // Select random outbound peers
    let peers = select_random_peers(node_ids, id, outbound, seed + id)
    SimNode(..node, connections: peers)
  })
}

fn connect_random(
  nodes: Dict(Int, SimNode),
  probability: Float,
  seed: Int,
) -> Dict(Int, SimNode) {
  let node_ids = dict.keys(nodes)

  dict.map_values(nodes, fn(id, node) {
    let peers = list.filter(node_ids, fn(other) {
      other != id && random_bool(seed + id + other, probability)
    })
    SimNode(..node, connections: peers)
  })
}

fn connect_full_mesh(nodes: Dict(Int, SimNode)) -> Dict(Int, SimNode) {
  let node_ids = dict.keys(nodes)

  dict.map_values(nodes, fn(id, node) {
    let peers = list.filter(node_ids, fn(other) { other != id })
    SimNode(..node, connections: peers)
  })
}

fn select_random_peers(
  all_ids: List(Int),
  exclude: Int,
  count: Int,
  seed: Int,
) -> List(Int) {
  let candidates = list.filter(all_ids, fn(id) { id != exclude })
  shuffle_and_take(candidates, count, seed)
}

// ============================================================================
// Simulation Execution
// ============================================================================

/// Run simulation for configured duration
pub fn run(state: SimState) -> SimState {
  run_until(state, state.config.duration_ticks)
}

/// Run simulation until specific tick
pub fn run_until(state: SimState, target_tick: Int) -> SimState {
  case state.current_tick >= target_tick {
    True -> state
    False -> {
      let new_state = tick(state)
      run_until(new_state, target_tick)
    }
  }
}

/// Execute one simulation tick
pub fn tick(state: SimState) -> SimState {
  let state = state
    |> deliver_messages()
    |> process_node_actions()
    |> simulate_mining()
    |> apply_adversary_actions()
    |> check_invariants()
    |> advance_tick()

  state
}

fn advance_tick(state: SimState) -> SimState {
  SimState(..state, current_tick: state.current_tick + 1)
}

/// Deliver pending messages with delay
fn deliver_messages(state: SimState) -> SimState {
  let #(ready, pending) = list.partition(state.pending_messages, fn(msg) {
    msg.delay_ticks <= 0
  })

  // Deliver ready messages to nodes
  let nodes = list.fold(ready, state.nodes, fn(nodes, msg) {
    case dict.get(nodes, msg.to) {
      Error(_) -> nodes
      Ok(node) -> {
        let updated = SimNode(
          ..node,
          inbox: [msg, ..node.inbox],
          metrics: NodeMetrics(
            ..node.metrics,
            messages_received: node.metrics.messages_received + 1,
          ),
        )
        dict.insert(nodes, msg.to, updated)
      }
    }
  })

  // Decrement delay on pending messages
  let pending = list.map(pending, fn(msg) {
    SimMessage(..msg, delay_ticks: msg.delay_ticks - 1)
  })

  SimState(..state, nodes: nodes, pending_messages: pending)
}

/// Process actions for all nodes
fn process_node_actions(state: SimState) -> SimState {
  let #(nodes, new_messages, events) = dict.fold(
    state.nodes,
    #(dict.new(), [], state.events),
    fn(acc, id, node) {
      let #(nodes_acc, msgs_acc, events_acc) = acc
      let #(updated_node, node_msgs, node_events) = process_node(node, state)
      #(
        dict.insert(nodes_acc, id, updated_node),
        list.append(msgs_acc, node_msgs),
        list.append(events_acc, node_events),
      )
    },
  )

  SimState(
    ..state,
    nodes: nodes,
    pending_messages: list.append(state.pending_messages, new_messages),
    events: events,
  )
}

fn process_node(
  node: SimNode,
  state: SimState,
) -> #(SimNode, List(SimMessage), List(SimEvent)) {
  // Process inbox messages
  let #(new_state, msgs, events) = list.fold(
    node.inbox,
    #(node.state, [], []),
    fn(acc, msg) {
      let #(node_state, msgs_acc, events_acc) = acc
      let #(new_node_state, response_msgs, new_events) =
        handle_message(node, node_state, msg, state)
      #(new_node_state, list.append(msgs_acc, response_msgs), list.append(events_acc, new_events))
    },
  )

  let updated_node = SimNode(
    ..node,
    state: new_state,
    inbox: [],  // Clear processed inbox
    metrics: NodeMetrics(
      ..node.metrics,
      messages_sent: node.metrics.messages_sent + list.length(msgs),
    ),
  )

  #(updated_node, msgs, events)
}

fn handle_message(
  node: SimNode,
  node_state: NodeState,
  msg: SimMessage,
  sim_state: SimState,
) -> #(NodeState, List(SimMessage), List(SimEvent)) {
  case msg.msg_type {
    MsgBlock -> handle_block(node, node_state, msg, sim_state)
    MsgTx -> handle_tx(node, node_state, msg, sim_state)
    MsgInv -> handle_inv(node, node_state, msg, sim_state)
    _ -> #(node_state, [], [])
  }
}

fn handle_block(
  node: SimNode,
  node_state: NodeState,
  msg: SimMessage,
  sim_state: SimState,
) -> #(NodeState, List(SimMessage), List(SimEvent)) {
  // Decode block hash from payload
  let block_hash = bit_array_to_string(msg.payload)

  case dict.get(sim_state.blocks, block_hash) {
    Error(_) -> #(node_state, [], [])
    Ok(block) -> {
      // Check if this extends our chain
      case block.prev_hash == node_state.best_block {
        True -> {
          // Extend chain
          let new_state = NodeState(
            ..node_state,
            height: block.height,
            best_block: block_hash,
            blocks_received: node_state.blocks_received + 1,
            is_synced: True,
          )

          let event = BlockReceived(sim_state.current_tick, node.id, block_hash)

          // Relay to peers
          let relay_msgs = relay_to_peers(node, MsgBlock, msg.payload, sim_state.config)

          #(new_state, relay_msgs, [event])
        }
        False -> {
          // Potential reorg or stale block
          #(node_state, [], [])
        }
      }
    }
  }
}

fn handle_tx(
  node: SimNode,
  node_state: NodeState,
  msg: SimMessage,
  sim_state: SimState,
) -> #(NodeState, List(SimMessage), List(SimEvent)) {
  let txid = bit_array_to_string(msg.payload)

  // Add to mempool if not already known
  case dict.has_key(node_state.mempool, txid) {
    True -> #(node_state, [], [])
    False -> {
      let tx = SimTx(
        txid: txid,
        fee: 1000,  // Placeholder
        size: 250,
        created_tick: sim_state.current_tick,
        confirmed_tick: None,
      )

      let new_mempool = dict.insert(node_state.mempool, txid, tx)
      let new_state = NodeState(..node_state, mempool: new_mempool)

      // Relay to peers
      let relay_msgs = relay_to_peers(node, MsgTx, msg.payload, sim_state.config)

      let event = TxBroadcast(sim_state.current_tick, node.id, txid)

      #(new_state, relay_msgs, [event])
    }
  }
}

fn handle_inv(
  _node: SimNode,
  node_state: NodeState,
  _msg: SimMessage,
  _sim_state: SimState,
) -> #(NodeState, List(SimMessage), List(SimEvent)) {
  // Request unknown inventory items
  #(node_state, [], [])
}

fn relay_to_peers(
  node: SimNode,
  msg_type: MessageType,
  payload: BitArray,
  config: SimConfig,
) -> List(SimMessage) {
  list.map(node.connections, fn(peer_id) {
    let delay = calculate_delay(config)
    SimMessage(
      from: node.id,
      to: peer_id,
      msg_type: msg_type,
      payload: payload,
      delay_ticks: delay,
    )
  })
}

fn calculate_delay(config: SimConfig) -> Int {
  let base = config.base_latency_ms / tick_interval_ms
  let variance = float.truncate(
    int.to_float(base) *. config.latency_variance *. config.conditions.latency_multiplier
  )
  int.max(1, base + variance)
}

/// Simulate block mining
fn simulate_mining(state: SimState) -> SimState {
  // Simplified mining: random node mines a block
  let miner = random_int(state.rng_state, dict.size(state.nodes))

  case dict.get(state.nodes, miner) {
    Error(_) -> state
    Ok(node) -> {
      // Only mine occasionally and if node is synced
      case node.state.is_synced && random_bool(state.rng_state + state.current_tick, 0.01) {
        False -> state
        True -> mine_block(state, node)
      }
    }
  }
}

fn mine_block(state: SimState, miner: SimNode) -> SimState {
  let block_hash = generate_block_hash(state.current_tick, miner.id)

  let block = SimBlock(
    hash: block_hash,
    prev_hash: miner.state.best_block,
    height: miner.state.height + 1,
    miner: miner.id,
    txids: [],  // Would include mempool txs
    timestamp: state.current_tick,
  )

  // Add block to global state
  let blocks = dict.insert(state.blocks, block_hash, block)
  let events = [BlockMined(state.current_tick, miner.id, block_hash, block.height), ..state.events]

  // Update miner's state
  let miner_state = NodeState(
    ..miner.state,
    height: block.height,
    best_block: block_hash,
  )
  let updated_miner = SimNode(
    ..miner,
    state: miner_state,
    metrics: NodeMetrics(..miner.metrics, blocks_mined: miner.metrics.blocks_mined + 1),
  )
  let nodes = dict.insert(state.nodes, miner.id, updated_miner)

  // Broadcast block
  let broadcast_msgs = list.map(miner.connections, fn(peer_id) {
    SimMessage(
      from: miner.id,
      to: peer_id,
      msg_type: MsgBlock,
      payload: string_to_bit_array(block_hash),
      delay_ticks: calculate_delay(state.config),
    )
  })

  SimState(
    ..state,
    nodes: nodes,
    blocks: blocks,
    chain_tips: [block_hash],
    events: events,
    pending_messages: list.append(state.pending_messages, broadcast_msgs),
    rng_state: state.rng_state + 1,
  )
}

/// Apply adversary actions based on strategy
fn apply_adversary_actions(state: SimState) -> SimState {
  case state.config.adversary_strategy {
    Honest -> state
    Eclipse(targets) -> apply_eclipse(state, targets)
    SelfishMining(hashpower) -> apply_selfish_mining(state, hashpower)
    DoubleSpend(confs) -> apply_double_spend(state, confs)
    TxCensorship(txids) -> apply_tx_censorship(state, txids)
    _ -> state
  }
}

fn apply_eclipse(state: SimState, targets: List(Int)) -> SimState {
  // Disconnect targets from honest nodes
  let nodes = dict.map_values(state.nodes, fn(id, node) {
    case list.contains(targets, id) {
      True -> {
        // Target: only connected to adversary nodes
        let adversary_connections = list.filter(node.connections, fn(peer) {
          case dict.get(state.nodes, peer) {
            Ok(peer_node) -> peer_node.is_adversary
            Error(_) -> False
          }
        })
        let metrics = NodeMetrics(
          ..node.metrics,
          eclipse_duration_ticks: node.metrics.eclipse_duration_ticks + 1,
        )
        SimNode(..node, connections: adversary_connections, metrics: metrics)
      }
      False -> node
    }
  })

  let events = list.map(targets, fn(target) {
    Eclipse(state.current_tick, target, True)
  })

  SimState(..state, nodes: nodes, events: list.append(state.events, events))
}

fn apply_selfish_mining(state: SimState, _hashpower: Float) -> SimState {
  // Adversary nodes withhold mined blocks
  state  // Placeholder
}

fn apply_double_spend(state: SimState, _confirmations: Int) -> SimState {
  // Attempt double spend after confirmations
  state  // Placeholder
}

fn apply_tx_censorship(state: SimState, _txids: List(String)) -> SimState {
  // Adversary nodes drop specified transactions
  state  // Placeholder
}

// ============================================================================
// Invariant Checking
// ============================================================================

/// Check simulation invariants
fn check_invariants(state: SimState) -> SimState {
  let violations = []
    |> check_chain_consistency(state)
    |> check_no_permanent_partitions(state)
    |> check_liveness(state)

  SimState(..state, invariant_violations: list.append(state.invariant_violations, violations))
}

fn check_chain_consistency(
  violations: List(InvariantViolation),
  state: SimState,
) -> List(InvariantViolation) {
  // All synced nodes should be on the same chain tip (eventually)
  let tips = dict.values(state.nodes)
    |> list.filter(fn(n) { n.state.is_synced })
    |> list.map(fn(n) { n.state.best_block })
    |> list.unique

  case list.length(tips) > 1 {
    True -> {
      let violation = InvariantViolation(
        tick: state.current_tick,
        invariant: "chain_consistency",
        details: "Multiple chain tips: " <> int.to_string(list.length(tips)),
        severity: Medium,
      )
      [violation, ..violations]
    }
    False -> violations
  }
}

fn check_no_permanent_partitions(
  violations: List(InvariantViolation),
  state: SimState,
) -> List(InvariantViolation) {
  // Check if any node has been eclipsed for too long
  let eclipsed = dict.values(state.nodes)
    |> list.filter(fn(n) { n.metrics.eclipse_duration_ticks > 100 })

  case eclipsed {
    [] -> violations
    _ -> {
      let violation = InvariantViolation(
        tick: state.current_tick,
        invariant: "no_permanent_eclipse",
        details: int.to_string(list.length(eclipsed)) <> " nodes eclipsed",
        severity: High,
      )
      [violation, ..violations]
    }
  }
}

fn check_liveness(
  violations: List(InvariantViolation),
  state: SimState,
) -> List(InvariantViolation) {
  // Check if blocks are being produced
  let recent_blocks = list.filter(state.events, fn(e) {
    case e {
      BlockMined(tick, _, _, _) -> tick > state.current_tick - 100
      _ -> False
    }
  })

  case state.current_tick > 100 && list.is_empty(recent_blocks) {
    True -> {
      let violation = InvariantViolation(
        tick: state.current_tick,
        invariant: "liveness",
        details: "No blocks mined in last 100 ticks",
        severity: Critical,
      )
      [violation, ..violations]
    }
    False -> violations
  }
}

// ============================================================================
// Analysis and Reporting
// ============================================================================

/// Simulation results
pub type SimResults {
  SimResults(
    total_ticks: Int,
    blocks_mined: Int,
    transactions_processed: Int,
    reorgs: Int,
    max_reorg_depth: Int,
    average_propagation_ticks: Float,
    eclipse_events: Int,
    invariant_violations: List(InvariantViolation),
    final_chain_height: Int,
    node_metrics: List(NodeMetrics),
  )
}

/// Analyze simulation results
pub fn analyze(state: SimState) -> SimResults {
  let block_events = list.filter(state.events, fn(e) {
    case e { BlockMined(_, _, _, _) -> True _ -> False }
  })

  let reorg_events = list.filter(state.events, fn(e) {
    case e { Reorg(_, _, _, _, _) -> True _ -> False }
  })

  let eclipse_events = list.filter(state.events, fn(e) {
    case e { Eclipse(_, _, _) -> True _ -> False }
  })

  let node_metrics = dict.values(state.nodes) |> list.map(fn(n) { n.metrics })

  let max_height = dict.values(state.nodes)
    |> list.map(fn(n) { n.state.height })
    |> list.fold(0, int.max)

  SimResults(
    total_ticks: state.current_tick,
    blocks_mined: list.length(block_events),
    transactions_processed: count_processed_txs(state),
    reorgs: list.length(reorg_events),
    max_reorg_depth: max_reorg_depth(reorg_events),
    average_propagation_ticks: 0.0,  // Would calculate from events
    eclipse_events: list.length(eclipse_events),
    invariant_violations: state.invariant_violations,
    final_chain_height: max_height,
    node_metrics: node_metrics,
  )
}

fn count_processed_txs(state: SimState) -> Int {
  list.filter(state.events, fn(e) {
    case e { TxConfirmed(_, _, _) -> True _ -> False }
  })
  |> list.length
}

fn max_reorg_depth(reorgs: List(SimEvent)) -> Int {
  list.fold(reorgs, 0, fn(acc, e) {
    case e {
      Reorg(_, _, _, _, depth) -> int.max(acc, depth)
      _ -> acc
    }
  })
}

/// Generate text report
pub fn generate_report(results: SimResults) -> String {
  "Network Simulation Report\n" <>
  "========================\n\n" <>
  "Duration: " <> int.to_string(results.total_ticks) <> " ticks\n" <>
  "Blocks mined: " <> int.to_string(results.blocks_mined) <> "\n" <>
  "Final chain height: " <> int.to_string(results.final_chain_height) <> "\n" <>
  "Transactions: " <> int.to_string(results.transactions_processed) <> "\n" <>
  "Reorgs: " <> int.to_string(results.reorgs) <> "\n" <>
  "Max reorg depth: " <> int.to_string(results.max_reorg_depth) <> "\n" <>
  "Eclipse events: " <> int.to_string(results.eclipse_events) <> "\n" <>
  "Invariant violations: " <> int.to_string(list.length(results.invariant_violations)) <> "\n"
}

// ============================================================================
// Utility Functions
// ============================================================================

fn random_int(seed: Int, max: Int) -> Int {
  case max <= 0 {
    True -> 0
    False -> int.modulo(seed * 1103515245 + 12345, max) |> result.unwrap(0)
  }
}

fn random_bool(seed: Int, probability: Float) -> Bool {
  let r = int.to_float(random_int(seed, 1000)) /. 1000.0
  r <. probability
}

fn shuffle_and_take(list: List(a), n: Int, seed: Int) -> List(a) {
  // Simple shuffle simulation
  let indexed = list.index_map(list, fn(item, i) { #(item, i) })
  let sorted = list.sort(indexed, fn(a, b) {
    let #(_, ia) = a
    let #(_, ib) = b
    int.compare(random_int(seed + ia, 1000), random_int(seed + ib, 1000))
  })
  sorted
  |> list.take(n)
  |> list.map(fn(pair) { pair.0 })
}

fn generate_block_hash(tick: Int, miner: Int) -> String {
  "block_" <> int.to_string(tick) <> "_" <> int.to_string(miner)
}

fn bit_array_to_string(data: BitArray) -> String {
  case bit_array.to_string(data) {
    Ok(s) -> s
    Error(_) -> ""
  }
}

fn string_to_bit_array(s: String) -> BitArray {
  <<s:utf8>>
}

// ============================================================================
// Preset Scenarios
// ============================================================================

/// Preset: Normal network operation
pub fn scenario_normal(num_nodes: Int) -> SimConfig {
  SimConfig(
    honest_nodes: num_nodes,
    adversary_nodes: 0,
    topology: BitcoinLike(8, 117),
    base_latency_ms: 50,
    latency_variance: 0.2,
    duration_ticks: 1000,
    seed: 42,
    adversary_strategy: Honest,
    conditions: normal_conditions(),
  )
}

/// Preset: Eclipse attack scenario
pub fn scenario_eclipse(num_honest: Int, num_adversary: Int, targets: List(Int)) -> SimConfig {
  SimConfig(
    honest_nodes: num_honest,
    adversary_nodes: num_adversary,
    topology: BitcoinLike(8, 117),
    base_latency_ms: 50,
    latency_variance: 0.2,
    duration_ticks: 2000,
    seed: 42,
    adversary_strategy: Eclipse(targets),
    conditions: normal_conditions(),
  )
}

/// Preset: Network partition
pub fn scenario_partition(num_nodes: Int) -> SimConfig {
  SimConfig(
    honest_nodes: num_nodes,
    adversary_nodes: 0,
    topology: BitcoinLike(8, 117),
    base_latency_ms: 50,
    latency_variance: 0.2,
    duration_ticks: 1000,
    seed: 42,
    adversary_strategy: Honest,
    conditions: NetworkConditions(
      drop_rate: 0.0,
      latency_multiplier: 1.0,
      partitions: [[0, 1, 2, 3, 4], [5, 6, 7, 8, 9]],
      bandwidth_limit: 0,
      jitter: 0.0,
    ),
  )
}

fn normal_conditions() -> NetworkConditions {
  NetworkConditions(
    drop_rate: 0.0,
    latency_multiplier: 1.0,
    partitions: [],
    bandwidth_limit: 0,
    jitter: 0.0,
  )
}
