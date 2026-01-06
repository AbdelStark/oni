// oni_node - The oni Bitcoin node OTP application
//
// This is the main entry point for the oni full node.
// It wires together all subsystems:
// - oni_bitcoin: primitives and codecs
// - oni_consensus: validation and script engine
// - oni_storage: persistence layer
// - oni_p2p: networking
// - oni_rpc: operator interface

import event_router.{type RouterMsg}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/io
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import http_server.{type ServerMsg, StartAccepting}
import node_rpc.{type RpcNodeHandles}
import oni_bitcoin
import oni_consensus
import oni_p2p
import oni_rpc
import oni_supervisor.{
  type ChainstateMsg, type MempoolMsg, type SyncMsg, GetHeight, GetStatus,
  GetTip,
}
import p2p_network.{type ListenerMsg, type PeerEvent}
import rpc_http
import rpc_service

// ============================================================================
// Configuration
// ============================================================================

/// Node configuration
pub type NodeConfig {
  NodeConfig(
    network: oni_bitcoin.Network,
    data_dir: String,
    rpc_port: Int,
    rpc_bind: String,
    p2p_port: Int,
    p2p_bind: String,
    max_inbound: Int,
    max_outbound: Int,
    mempool_max_size: Int,
    rpc_user: Option(String),
    rpc_password: Option(String),
    enable_rpc: Bool,
    enable_p2p: Bool,
  )
}

/// Default node configuration for mainnet
pub fn default_config() -> NodeConfig {
  NodeConfig(
    network: oni_bitcoin.Mainnet,
    data_dir: "~/.oni",
    rpc_port: 8332,
    rpc_bind: "127.0.0.1",
    p2p_port: 8333,
    p2p_bind: "0.0.0.0",
    max_inbound: 117,
    max_outbound: 11,
    mempool_max_size: 300_000_000,
    rpc_user: None,
    rpc_password: None,
    enable_rpc: True,
    enable_p2p: True,
  )
}

/// Configuration for regtest mode
pub fn regtest_config() -> NodeConfig {
  NodeConfig(
    network: oni_bitcoin.Regtest,
    data_dir: "~/.oni/regtest",
    rpc_port: 18_443,
    rpc_bind: "127.0.0.1",
    p2p_port: 18_444,
    p2p_bind: "127.0.0.1",
    max_inbound: 8,
    max_outbound: 4,
    mempool_max_size: 100_000_000,
    rpc_user: None,
    rpc_password: None,
    enable_rpc: True,
    enable_p2p: True,
  )
}

/// Configuration for testnet mode
pub fn testnet_config() -> NodeConfig {
  NodeConfig(
    network: oni_bitcoin.Testnet,
    data_dir: "~/.oni/testnet3",
    rpc_port: 18_332,
    rpc_bind: "127.0.0.1",
    p2p_port: 18_333,
    p2p_bind: "0.0.0.0",
    max_inbound: 117,
    max_outbound: 11,
    mempool_max_size: 300_000_000,
    rpc_user: None,
    rpc_password: None,
    enable_rpc: True,
    enable_p2p: True,
  )
}

// ============================================================================
// Node State
// ============================================================================

/// Running node state with handles to all subsystems
pub type NodeState {
  NodeState(
    config: NodeConfig,
    /// Core subsystem handles
    chainstate: Subject(ChainstateMsg),
    mempool: Subject(MempoolMsg),
    sync: Subject(SyncMsg),
    /// Event router for P2P message handling
    event_router: Option(Subject(RouterMsg)),
    /// P2P network listener (if enabled)
    p2p_listener: Option(Subject(ListenerMsg)),
    /// RPC HTTP server (if enabled)
    rpc_server: Option(Subject(ServerMsg)),
    /// RPC adapter handles for service queries
    rpc_handles: Option(RpcNodeHandles),
  )
}

// ============================================================================
// Public API
// ============================================================================

/// Node version
pub const version = "0.1.0"

/// Node user agent string
pub fn user_agent() -> String {
  "/oni:" <> version <> "/"
}

/// Start the node with default configuration
pub fn start() -> Result(NodeState, String) {
  start_with_config(default_config())
}

/// Start the node with custom configuration
pub fn start_with_config(config: NodeConfig) -> Result(NodeState, String) {
  io.println("Starting oni node v" <> version <> "...")

  // Start chainstate actor
  let chainstate_result = oni_supervisor.start_chainstate(config.network)
  use chainstate <- result.try(
    chainstate_result
    |> result.map_error(fn(_) { "Failed to start chainstate" }),
  )
  io.println("  ✓ Chainstate started")

  // Start mempool actor
  let mempool_result = oni_supervisor.start_mempool(config.mempool_max_size)
  use mempool <- result.try(
    mempool_result
    |> result.map_error(fn(_) { "Failed to start mempool" }),
  )
  io.println("  ✓ Mempool started")

  // Start sync coordinator
  let sync_result = oni_supervisor.start_sync()
  use sync <- result.try(
    sync_result
    |> result.map_error(fn(_) { "Failed to start sync coordinator" }),
  )
  io.println("  ✓ Sync coordinator started")

  // Create node handles for RPC adapters
  let node_handles =
    oni_supervisor.NodeHandles(
      chainstate: chainstate,
      mempool: mempool,
      sync: sync,
    )

  // Start RPC adapters and server if enabled
  let #(rpc_handles, rpc_server) = case config.enable_rpc {
    True -> {
      case start_rpc_server(config, node_handles) {
        Ok(#(handles, server)) -> {
          io.println(
            "  ✓ RPC server started on "
            <> config.rpc_bind
            <> ":"
            <> int.to_string(config.rpc_port),
          )
          #(Some(handles), Some(server))
        }
        Error(err) -> {
          io.println("  ✗ RPC server failed: " <> err)
          #(None, None)
        }
      }
    }
    False -> #(None, None)
  }

  // Start P2P listener and event router if enabled
  let #(event_router_handle, p2p_listener) = case config.enable_p2p {
    True -> {
      case start_p2p_with_router(config, chainstate, mempool, sync) {
        Ok(#(router, listener)) -> {
          io.println("  ✓ Event router started")
          io.println(
            "  ✓ P2P listener started on "
            <> config.p2p_bind
            <> ":"
            <> int.to_string(config.p2p_port),
          )
          #(Some(router), Some(listener))
        }
        Error(err) -> {
          io.println("  ✗ P2P startup failed: " <> err)
          #(None, None)
        }
      }
    }
    False -> #(None, None)
  }

  io.println("Node started successfully!")

  Ok(NodeState(
    config: config,
    chainstate: chainstate,
    mempool: mempool,
    sync: sync,
    event_router: event_router_handle,
    p2p_listener: p2p_listener,
    rpc_server: rpc_server,
    rpc_handles: rpc_handles,
  ))
}

/// Start the RPC server with adapters
fn start_rpc_server(
  config: NodeConfig,
  handles: oni_supervisor.NodeHandles,
) -> Result(#(RpcNodeHandles, Subject(ServerMsg)), String) {
  // Create RPC adapter handles
  use rpc_handles <- result.try(
    node_rpc.create_rpc_handles(handles)
    |> result.map_error(fn(_) { "Failed to create RPC adapters" }),
  )

  // Create RPC config
  let rpc_config =
    oni_rpc.RpcConfig(
      bind_addr: config.rpc_bind,
      port: config.rpc_port,
      username: option.unwrap(config.rpc_user, ""),
      password: option.unwrap(config.rpc_password, ""),
      allow_anonymous: option.is_none(config.rpc_user),
      enabled_methods: [],
      rate_limit_enabled: False,
    )

  // Create RPC service handles for stateful handlers
  let rpc_service_handles =
    rpc_service.NodeHandles(
      chainstate: rpc_handles.chainstate,
      mempool: rpc_handles.mempool,
      sync: rpc_handles.sync,
    )

  // Create RPC service state (contains the RpcServer with handlers)
  let rpc_service_state =
    rpc_service.new_with_handles(rpc_config, rpc_service_handles)

  // Configure HTTP server
  let http_config =
    http_server.HttpServerConfig(
      port: config.rpc_port,
      bind_address: config.rpc_bind,
      max_connections: 100,
      connection_timeout_ms: 30_000,
      request_timeout_ms: 60_000,
      rpc_config: rpc_http.default_handler_config(),
    )

  // Start HTTP server with the RpcServer from service state
  use server <- result.try(
    http_server.start(http_config, rpc_service_state.server)
    |> result.map_error(fn(_) { "Failed to start HTTP server" }),
  )

  // Tell the server to start accepting connections
  process.send(server, StartAccepting)

  Ok(#(rpc_handles, server))
}

/// Start the P2P listener with proper event routing
///
/// This function creates the full P2P integration:
/// 1. Starts the event router which connects chainstate, mempool, and sync
/// 2. Creates a P2P event handler that forwards events to the router
/// 3. Starts the P2P listener with the event handler
fn start_p2p_with_router(
  config: NodeConfig,
  chainstate: Subject(ChainstateMsg),
  mempool: Subject(MempoolMsg),
  sync: Subject(SyncMsg),
) -> Result(#(Subject(RouterMsg), Subject(ListenerMsg)), String) {
  let p2p_config =
    p2p_network.P2PConfig(
      network: config.network,
      listen_port: config.p2p_port,
      bind_address: config.p2p_bind,
      max_inbound: config.max_inbound,
      max_outbound: config.max_outbound,
      connect_timeout_ms: 5000,
      services: oni_p2p.default_services(),
      best_height: 0,
    )

  // First start the P2P listener with a temporary handler
  // We need the listener subject to pass to the event router
  case start_temp_listener(p2p_config) {
    Error(err) -> Error(err)
    Ok(#(listener, event_handler_subject)) -> {
      // Create router handles
      let router_handles =
        event_router.RouterHandles(
          chainstate: chainstate,
          mempool: mempool,
          sync: sync,
          p2p: listener,
        )

      // Start the event router
      let router_config =
        event_router.RouterConfig(
          max_pending_blocks: 16,
          max_pending_txs: 100,
          debug: False,
        )

      case event_router.start(router_config, router_handles) {
        Error(_) -> {
          // Stop the listener if router fails
          p2p_network.stop_listener(listener)
          Error("Failed to start event router")
        }
        Ok(router) -> {
          // Now update the event handler to forward to the router
          // We send a message to update the forwarding target
          process.send(event_handler_subject, SetRouterTarget(router))
          Ok(#(router, listener))
        }
      }
    }
  }
}

/// Message type for the forwarding event handler
type ForwardingHandlerMsg {
  /// Set the router target to forward events to
  SetRouterTarget(Subject(RouterMsg))
  /// Forward a P2P event
  ForwardEvent(PeerEvent)
}

/// State for the forwarding event handler
type ForwardingHandlerState {
  ForwardingHandlerState(
    router: Option(Subject(RouterMsg)),
    events_buffered: List(PeerEvent),
  )
}

/// Start a temporary P2P listener with a forwarding event handler
fn start_temp_listener(
  p2p_config: p2p_network.P2PConfig,
) -> Result(#(Subject(ListenerMsg), Subject(ForwardingHandlerMsg)), String) {
  // Start the forwarding handler actor
  case
    actor.start(
      ForwardingHandlerState(router: None, events_buffered: []),
      handle_forwarding_msg,
    )
  {
    Error(_) -> Error("Failed to start event handler")
    Ok(handler) -> {
      // Create a subject that converts PeerEvents to ForwardingHandlerMsg
      let event_adapter = create_event_adapter(handler)

      case event_adapter {
        Error(_) -> Error("Failed to create event adapter")
        Ok(adapter) -> {
          case p2p_network.start_listener(p2p_config, adapter) {
            Error(_) -> Error("Failed to start P2P listener")
            Ok(listener) -> Ok(#(listener, handler))
          }
        }
      }
    }
  }
}

/// Create an adapter that converts PeerEvent to ForwardingHandlerMsg
fn create_event_adapter(
  handler: Subject(ForwardingHandlerMsg),
) -> Result(Subject(PeerEvent), actor.StartError) {
  actor.start(handler, fn(event: PeerEvent, h: Subject(ForwardingHandlerMsg)) {
    process.send(h, ForwardEvent(event))
    actor.continue(h)
  })
}

/// Handle forwarding handler messages
fn handle_forwarding_msg(
  msg: ForwardingHandlerMsg,
  state: ForwardingHandlerState,
) -> actor.Next(ForwardingHandlerMsg, ForwardingHandlerState) {
  case msg {
    SetRouterTarget(router) -> {
      // Flush any buffered events to the router
      flush_buffered_events(state.events_buffered, router)
      actor.continue(
        ForwardingHandlerState(router: Some(router), events_buffered: []),
      )
    }

    ForwardEvent(event) -> {
      case state.router {
        Some(router) -> {
          // Forward to router
          process.send(router, event_router.ProcessEvent(event))
          actor.continue(state)
        }
        None -> {
          // Buffer the event until router is set
          actor.continue(
            ForwardingHandlerState(..state, events_buffered: [
              event,
              ..state.events_buffered
            ]),
          )
        }
      }
    }
  }
}

/// Flush buffered events to the router
fn flush_buffered_events(
  events: List(PeerEvent),
  router: Subject(RouterMsg),
) -> Nil {
  case events {
    [] -> Nil
    [event, ..rest] -> {
      flush_buffered_events(rest, router)
      process.send(router, event_router.ProcessEvent(event))
    }
  }
}

/// Get the current chain tip height
pub fn get_height(node: NodeState) -> Int {
  process.call(node.chainstate, GetHeight, 5000)
}

/// Get the current chain tip hash
pub fn get_tip(node: NodeState) -> option.Option(oni_bitcoin.BlockHash) {
  process.call(node.chainstate, GetTip, 5000)
}

/// Get sync status
pub fn get_sync_status(node: NodeState) -> oni_supervisor.SyncStatus {
  process.call(node.sync, GetStatus, 5000)
}

/// Stop the node gracefully
pub fn stop(node: NodeState) -> Nil {
  io.println("Stopping oni node...")

  // Stop RPC server first (stop accepting new requests)
  case node.rpc_server {
    Some(server) -> {
      http_server.stop(server)
      io.println("  ✓ RPC server stopped")
    }
    None -> Nil
  }

  // Stop P2P listener
  case node.p2p_listener {
    Some(listener) -> {
      p2p_network.stop_listener(listener)
      io.println("  ✓ P2P listener stopped")
    }
    None -> Nil
  }

  // Stop event router
  case node.event_router {
    Some(router) -> {
      process.send(router, event_router.Shutdown)
      io.println("  ✓ Event router stopped")
    }
    None -> Nil
  }

  // Stop core subsystems
  process.send(node.sync, oni_supervisor.SyncShutdown)
  io.println("  ✓ Sync coordinator stopped")

  process.send(node.mempool, oni_supervisor.MempoolShutdown)
  io.println("  ✓ Mempool stopped")

  process.send(node.chainstate, oni_supervisor.ChainstateShutdown)
  io.println("  ✓ Chainstate stopped")

  io.println("Node stopped.")
  Nil
}

/// Check if the node is fully operational
pub fn is_ready(node: NodeState) -> Bool {
  // Check all core components are running
  // For now, just check chainstate responds
  let height = get_height(node)
  height >= 0
}

/// Get the event router handle (for testing and debugging)
pub fn get_event_router(node: NodeState) -> Option(Subject(RouterMsg)) {
  node.event_router
}

/// Get event router statistics (for monitoring)
pub fn get_router_stats(node: NodeState) -> Option(event_router.RouterStats) {
  case node.event_router {
    Some(router) -> {
      Some(process.call(router, event_router.GetStats, 5000))
    }
    None -> None
  }
}

/// Get node info for debugging
pub fn get_info(node: NodeState) -> NodeInfo {
  let height = get_height(node)
  let tip = get_tip(node)
  let sync_status = get_sync_status(node)

  NodeInfo(
    version: version,
    network: node.config.network,
    height: height,
    tip: tip,
    sync_state: sync_status.state,
    rpc_enabled: option.is_some(node.rpc_server),
    p2p_enabled: option.is_some(node.p2p_listener),
  )
}

/// Node info for debugging and status
pub type NodeInfo {
  NodeInfo(
    version: String,
    network: oni_bitcoin.Network,
    height: Int,
    tip: Option(oni_bitcoin.BlockHash),
    sync_state: String,
    rpc_enabled: Bool,
    p2p_enabled: Bool,
  )
}

// ============================================================================
// Main Entry Point
// ============================================================================

/// Main entry point
pub fn main() {
  print_banner()

  // Display network information
  let config = default_config()
  let params = oni_bitcoin.mainnet_params()

  io.println("Network: Mainnet")
  io.println("Genesis: " <> oni_bitcoin.block_hash_to_hex(params.genesis_hash))
  io.println("P2P Port: " <> int.to_string(config.p2p_port))
  io.println("RPC Port: " <> int.to_string(config.rpc_port))
  io.println("User Agent: " <> user_agent())
  io.println("")

  // Display subsystem status
  io.println("Subsystems:")
  io.println("  ✓ oni_bitcoin   - Bitcoin primitives and codecs")
  io.println("  ✓ oni_consensus - Validation and script engine")
  io.println("  ✓ oni_storage   - Block store and chainstate")
  io.println("  ✓ oni_p2p       - P2P networking layer")
  io.println("  ✓ oni_rpc       - JSON-RPC interface")
  io.println("")

  // Display consensus constants
  io.println("Consensus Parameters:")
  io.println(
    "  Max Block Weight:     "
    <> int.to_string(oni_consensus.max_block_weight)
    <> " WU",
  )
  io.println(
    "  Max Script Size:      "
    <> int.to_string(oni_consensus.max_script_size)
    <> " bytes",
  )
  io.println(
    "  Max Ops Per Script:   "
    <> int.to_string(oni_consensus.max_ops_per_script),
  )
  io.println(
    "  Coinbase Maturity:    "
    <> int.to_string(oni_consensus.coinbase_maturity)
    <> " blocks",
  )
  io.println("")

  // Start the node
  case start_with_config(config) {
    Ok(node) -> {
      io.println("")
      io.println(
        "═══════════════════════════════════════════════════════════════",
      )
      io.println("Node is running!")
      io.println("")

      let info = get_info(node)
      io.println("Status:")
      io.println("  Chain height: " <> int.to_string(info.height))
      io.println("  Sync state:   " <> info.sync_state)
      io.println("  RPC enabled:  " <> bool_to_string(info.rpc_enabled))
      io.println("  P2P enabled:  " <> bool_to_string(info.p2p_enabled))
      io.println("")

      case info.tip {
        Some(tip) -> {
          io.println("  Best block:   " <> oni_bitcoin.block_hash_to_hex(tip))
        }
        None -> Nil
      }
      io.println("")

      io.println("RPC interface available at:")
      io.println(
        "  http://"
        <> config.rpc_bind
        <> ":"
        <> int.to_string(config.rpc_port)
        <> "/",
      )
      io.println("")
      io.println("Example commands:")
      io.println("  curl -X POST -H 'Content-Type: application/json' \\")
      io.println(
        "    -d '{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"getblockchaininfo\"}' \\",
      )
      io.println(
        "    http://127.0.0.1:" <> int.to_string(config.rpc_port) <> "/",
      )
      io.println("")
      io.println(
        "═══════════════════════════════════════════════════════════════",
      )
      io.println("Press Ctrl+C to stop the node.")
      io.println("")

      // Keep the process alive
      process.sleep_forever()
    }
    Error(err) -> {
      io.println("Failed to start node: " <> err)
    }
  }
}

fn bool_to_string(b: Bool) -> String {
  case b {
    True -> "yes"
    False -> "no"
  }
}

fn print_banner() {
  io.println(
    "╔═══════════════════════════════════════════════════════════════╗",
  )
  io.println(
    "║                                                               ║",
  )
  io.println(
    "║    ██████╗ ███╗   ██╗██╗                                      ║",
  )
  io.println(
    "║   ██╔═══██╗████╗  ██║██║                                      ║",
  )
  io.println(
    "║   ██║   ██║██╔██╗ ██║██║                                      ║",
  )
  io.println(
    "║   ██║   ██║██║╚██╗██║██║                                      ║",
  )
  io.println(
    "║   ╚██████╔╝██║ ╚████║██║                                      ║",
  )
  io.println(
    "║    ╚═════╝ ╚═╝  ╚═══╝╚═╝                                      ║",
  )
  io.println(
    "║                                                               ║",
  )
  io.println(
    "║   A Bitcoin Full Node Implementation in Gleam                 ║",
  )
  io.println(
    "║   Version: "
    <> version
    <> "                                              ║",
  )
  io.println(
    "║                                                               ║",
  )
  io.println(
    "╚═══════════════════════════════════════════════════════════════╝",
  )
  io.println("")
}
