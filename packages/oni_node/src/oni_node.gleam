// oni_node - The oni Bitcoin node OTP application
//
// This is the main entry point for the oni full node.
// It wires together all subsystems:
// - oni_bitcoin: primitives and codecs
// - oni_consensus: validation and script engine
// - oni_storage: persistence layer
// - oni_p2p: networking
// - oni_rpc: operator interface

import gleam/io
import oni_bitcoin
import oni_consensus

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

/// Node version
pub const version = "0.1.0"

/// Node user agent string
pub fn user_agent() -> String {
  "/oni:" <> version <> "/"
}

/// Main entry point
pub fn main() {
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

  // Display network information
  let config = default_config()
  let params = oni_bitcoin.mainnet_params()

  io.println("Network: Mainnet")
  io.println("Genesis: " <> oni_bitcoin.block_hash_to_hex(params.genesis_hash))
  io.println("P2P Port: " <> int_to_string(config.p2p_port))
  io.println("RPC Port: " <> int_to_string(config.rpc_port))
  io.println("User Agent: " <> user_agent())
  io.println("")

  // Display subsystem status
  io.println("Subsystems:")
  io.println("  ✓ oni_bitcoin  - Bitcoin primitives and codecs")
  io.println("  ✓ oni_consensus - Validation and script engine")
  io.println("  ✓ oni_storage   - Block store and chainstate")
  io.println("  ✓ oni_p2p       - P2P networking layer")
  io.println("  ✓ oni_rpc       - JSON-RPC interface")
  io.println("")

  // Display consensus constants
  io.println("Consensus Parameters:")
  io.println("  Max Block Weight:     " <> int_to_string(oni_consensus.max_block_weight) <> " WU")
  io.println("  Max Script Size:      " <> int_to_string(oni_consensus.max_script_size) <> " bytes")
  io.println("  Max Ops Per Script:   " <> int_to_string(oni_consensus.max_ops_per_script))
  io.println("  Coinbase Maturity:    " <> int_to_string(oni_consensus.coinbase_maturity) <> " blocks")
  io.println("")

  io.println("oni node initialized successfully!")
  io.println("(This is a development scaffold - full node functionality coming soon)")
}

/// Convert integer to string
fn int_to_string(n: Int) -> String {
  case n {
    0 -> "0"
    _ -> do_int_to_string(n, "")
  }
}

fn do_int_to_string(n: Int, acc: String) -> String {
  case n {
    0 -> acc
    _ -> {
      let digit = n % 10
      let char = case digit {
        0 -> "0"
        1 -> "1"
        2 -> "2"
        3 -> "3"
        4 -> "4"
        5 -> "5"
        6 -> "6"
        7 -> "7"
        8 -> "8"
        _ -> "9"
      }
      do_int_to_string(n / 10, char <> acc)
    }
  }
}
