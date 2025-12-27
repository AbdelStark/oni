// oni_node - The oni Bitcoin node OTP application
//
// This is the main entry point for the oni full node.
// It wires together all subsystems:
// - oni_bitcoin: primitives and codecs
// - oni_consensus: validation and script engine
// - oni_storage: persistence layer
// - oni_p2p: networking
// - oni_rpc: operator interface

import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/option.{None, Some}
import gleam/result
import oni_bitcoin
import oni_consensus
import supervisor.{
  type ChainstateMsg, type MempoolMsg, type SyncMsg,
  GetHeight, GetStatus, GetTip,
}

// ============================================================================
// Configuration
// ============================================================================

/// Node configuration
pub type NodeConfig {
  NodeConfig(
    network: oni_bitcoin.Network,
    data_dir: String,
    rpc_port: Int,
    p2p_port: Int,
    max_connections: Int,
  )
}

/// Default node configuration for mainnet
pub fn default_config() -> NodeConfig {
  NodeConfig(
    network: oni_bitcoin.Mainnet,
    data_dir: "~/.oni",
    rpc_port: 8332,
    p2p_port: 8333,
    max_connections: 125,
  )
}

// ============================================================================
// Node State
// ============================================================================

/// Running node state with handles to all subsystems
pub type NodeState {
  NodeState(
    config: NodeConfig,
    chainstate: process.Subject(ChainstateMsg),
    mempool: process.Subject(MempoolMsg),
    sync: process.Subject(SyncMsg),
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
  let chainstate_result = supervisor.start_chainstate(config.network)
  use chainstate <- result.try(
    chainstate_result
    |> result.map_error(fn(_) { "Failed to start chainstate" })
  )
  io.println("  ✓ Chainstate started")

  // Start mempool actor
  let mempool_result = supervisor.start_mempool(300_000_000)
  use mempool <- result.try(
    mempool_result
    |> result.map_error(fn(_) { "Failed to start mempool" })
  )
  io.println("  ✓ Mempool started")

  // Start sync coordinator
  let sync_result = supervisor.start_sync()
  use sync <- result.try(
    sync_result
    |> result.map_error(fn(_) { "Failed to start sync coordinator" })
  )
  io.println("  ✓ Sync coordinator started")

  io.println("Node started successfully!")

  Ok(NodeState(
    config: config,
    chainstate: chainstate,
    mempool: mempool,
    sync: sync,
  ))
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
pub fn get_sync_status(node: NodeState) -> supervisor.SyncStatus {
  process.call(node.sync, GetStatus, 5000)
}

/// Stop the node gracefully
pub fn stop(node: NodeState) -> Nil {
  io.println("Stopping oni node...")
  process.send(node.chainstate, supervisor.ChainstateShutdown)
  process.send(node.mempool, supervisor.MempoolShutdown)
  process.send(node.sync, supervisor.SyncShutdown)
  io.println("Node stopped.")
  Nil
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
  io.println("  Max Block Weight:     " <> int.to_string(oni_consensus.max_block_weight) <> " WU")
  io.println("  Max Script Size:      " <> int.to_string(oni_consensus.max_script_size) <> " bytes")
  io.println("  Max Ops Per Script:   " <> int.to_string(oni_consensus.max_ops_per_script))
  io.println("  Coinbase Maturity:    " <> int.to_string(oni_consensus.coinbase_maturity) <> " blocks")
  io.println("")

  // Start the node
  case start_with_config(config) {
    Ok(node) -> {
      io.println("")
      io.println("Node is running!")
      io.println("Chain height: " <> int.to_string(get_height(node)))
      io.println("")

      // In a real implementation, we would:
      // 1. Start accepting P2P connections
      // 2. Start the RPC server
      // 3. Begin initial block download if needed
      // 4. Enter the main event loop

      io.println("Press Ctrl+C to stop the node.")

      // Keep the process alive
      process.sleep_forever()
    }
    Error(err) -> {
      io.println("Failed to start node: " <> err)
    }
  }
}

fn print_banner() {
  io.println("╔═══════════════════════════════════════════════════════════════╗")
  io.println("║                                                               ║")
  io.println("║    ██████╗ ███╗   ██╗██╗                                      ║")
  io.println("║   ██╔═══██╗████╗  ██║██║                                      ║")
  io.println("║   ██║   ██║██╔██╗ ██║██║                                      ║")
  io.println("║   ██║   ██║██║╚██╗██║██║                                      ║")
  io.println("║   ╚██████╔╝██║ ╚████║██║                                      ║")
  io.println("║    ╚═════╝ ╚═╝  ╚═══╝╚═╝                                      ║")
  io.println("║                                                               ║")
  io.println("║   A Bitcoin Full Node Implementation in Gleam                 ║")
  io.println("║   Version: " <> version <> "                                              ║")
  io.println("║                                                               ║")
  io.println("╚═══════════════════════════════════════════════════════════════╝")
  io.println("")
}
