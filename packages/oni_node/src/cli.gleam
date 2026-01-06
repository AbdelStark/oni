// cli.gleam - Command-line interface for oni Bitcoin node
//
// This module provides:
// - Command-line argument parsing
// - Network selection (mainnet/testnet/signet/regtest)
// - Configuration from environment and files
// - Daemon mode and control commands
//
// Usage:
//   oni --mainnet                  Start mainnet node
//   oni --testnet                  Start testnet node
//   oni --regtest                  Start regtest node
//   oni --datadir=/path/to/data    Set data directory
//   oni --rpcport=8332             Set RPC port
//   oni --help                     Show help

import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import node_rpc
import oni_bitcoin
import oni_node
import rpc_service

// ============================================================================
// CLI Types
// ============================================================================

/// Command to execute
pub type Command {
  /// Start the node daemon
  StartDaemon
  /// Show version information
  ShowVersion
  /// Show help message
  ShowHelp
  /// Generate block (regtest only)
  GenerateBlock(count: Int, address: Option(String))
  /// Stop the running daemon
  StopDaemon
  /// Get blockchain info
  GetInfo
}

/// Parsed CLI arguments
pub type CliArgs {
  CliArgs(
    command: Command,
    network: oni_bitcoin.Network,
    data_dir: Option(String),
    rpc_port: Option(Int),
    rpc_bind: Option(String),
    rpc_user: Option(String),
    rpc_password: Option(String),
    p2p_port: Option(Int),
    p2p_bind: Option(String),
    max_connections: Option(Int),
    debug: Bool,
    daemon: Bool,
    prune: Option(Int),
    txindex: Bool,
    listen: Bool,
    discover: Bool,
    addnode: List(String),
    connect: List(String),
  )
}

/// CLI parsing error
pub type CliError {
  UnknownOption(String)
  InvalidValue(option: String, value: String)
  MissingValue(String)
  InvalidCommand(String)
}

// ============================================================================
// Default Arguments
// ============================================================================

/// Create default CLI arguments
pub fn default_args() -> CliArgs {
  CliArgs(
    command: StartDaemon,
    network: oni_bitcoin.Mainnet,
    data_dir: None,
    rpc_port: None,
    rpc_bind: None,
    rpc_user: None,
    rpc_password: None,
    p2p_port: None,
    p2p_bind: None,
    max_connections: None,
    debug: False,
    daemon: False,
    prune: None,
    txindex: False,
    listen: True,
    discover: True,
    addnode: [],
    connect: [],
  )
}

// ============================================================================
// Argument Parsing
// ============================================================================

/// Parse command-line arguments
pub fn parse_args(args: List(String)) -> Result(CliArgs, CliError) {
  parse_args_loop(args, default_args())
}

fn parse_args_loop(
  args: List(String),
  acc: CliArgs,
) -> Result(CliArgs, CliError) {
  case args {
    [] -> Ok(acc)
    [arg, ..rest] -> {
      case parse_single_arg(arg, rest, acc) {
        Error(err) -> Error(err)
        Ok(#(new_acc, remaining)) -> parse_args_loop(remaining, new_acc)
      }
    }
  }
}

fn parse_single_arg(
  arg: String,
  rest: List(String),
  acc: CliArgs,
) -> Result(#(CliArgs, List(String)), CliError) {
  case arg {
    // Help and version
    "--help" | "-h" | "-?" -> Ok(#(CliArgs(..acc, command: ShowHelp), rest))
    "--version" | "-v" -> Ok(#(CliArgs(..acc, command: ShowVersion), rest))

    // Network selection
    "--mainnet" -> Ok(#(CliArgs(..acc, network: oni_bitcoin.Mainnet), rest))
    "--testnet" | "--testnet3" ->
      Ok(#(CliArgs(..acc, network: oni_bitcoin.Testnet), rest))
    "--signet" -> Ok(#(CliArgs(..acc, network: oni_bitcoin.Signet), rest))
    "--regtest" -> Ok(#(CliArgs(..acc, network: oni_bitcoin.Regtest), rest))

    // Boolean flags
    "--daemon" | "-daemon" -> Ok(#(CliArgs(..acc, daemon: True), rest))
    "--debug" -> Ok(#(CliArgs(..acc, debug: True), rest))
    "--txindex" -> Ok(#(CliArgs(..acc, txindex: True), rest))
    "--nolisten" | "--listen=0" -> Ok(#(CliArgs(..acc, listen: False), rest))
    "--listen" | "--listen=1" -> Ok(#(CliArgs(..acc, listen: True), rest))
    "--nodiscover" | "--discover=0" ->
      Ok(#(CliArgs(..acc, discover: False), rest))
    "--discover" | "--discover=1" -> Ok(#(CliArgs(..acc, discover: True), rest))

    // Commands
    "stop" -> Ok(#(CliArgs(..acc, command: StopDaemon), rest))
    "getinfo" | "getblockchaininfo" ->
      Ok(#(CliArgs(..acc, command: GetInfo), rest))

    // Options with values
    _ -> parse_option_with_value(arg, rest, acc)
  }
}

fn parse_option_with_value(
  arg: String,
  rest: List(String),
  acc: CliArgs,
) -> Result(#(CliArgs, List(String)), CliError) {
  // Handle --option=value format
  case string.split_once(arg, "=") {
    Ok(#(opt, value)) -> parse_valued_option(opt, value, rest, acc)
    Error(_) -> {
      // Handle --option value format
      case string.starts_with(arg, "--") || string.starts_with(arg, "-") {
        True -> {
          case rest {
            [value, ..remaining] -> {
              // Check if value is actually another option
              case string.starts_with(value, "-") {
                True -> Error(MissingValue(arg))
                False -> parse_valued_option(arg, value, remaining, acc)
              }
            }
            _ -> Error(MissingValue(arg))
          }
        }
        False -> Error(UnknownOption(arg))
      }
    }
  }
}

fn parse_valued_option(
  opt: String,
  value: String,
  rest: List(String),
  acc: CliArgs,
) -> Result(#(CliArgs, List(String)), CliError) {
  case opt {
    // Data directory
    "--datadir" | "-datadir" ->
      Ok(#(CliArgs(..acc, data_dir: Some(value)), rest))

    // RPC options
    "--rpcport" | "-rpcport" -> {
      case int.parse(value) {
        Ok(port) -> Ok(#(CliArgs(..acc, rpc_port: Some(port)), rest))
        Error(_) -> Error(InvalidValue(option: opt, value: value))
      }
    }
    "--rpcbind" | "-rpcbind" ->
      Ok(#(CliArgs(..acc, rpc_bind: Some(value)), rest))
    "--rpcuser" | "-rpcuser" ->
      Ok(#(CliArgs(..acc, rpc_user: Some(value)), rest))
    "--rpcpassword" | "-rpcpassword" ->
      Ok(#(CliArgs(..acc, rpc_password: Some(value)), rest))

    // P2P options
    "--port" | "-port" -> {
      case int.parse(value) {
        Ok(port) -> Ok(#(CliArgs(..acc, p2p_port: Some(port)), rest))
        Error(_) -> Error(InvalidValue(option: opt, value: value))
      }
    }
    "--bind" | "-bind" -> Ok(#(CliArgs(..acc, p2p_bind: Some(value)), rest))
    "--maxconnections" | "-maxconnections" -> {
      case int.parse(value) {
        Ok(n) -> Ok(#(CliArgs(..acc, max_connections: Some(n)), rest))
        Error(_) -> Error(InvalidValue(option: opt, value: value))
      }
    }

    // Peer connection options
    "--addnode" | "-addnode" ->
      Ok(#(CliArgs(..acc, addnode: [value, ..acc.addnode]), rest))
    "--connect" | "-connect" ->
      Ok(#(CliArgs(..acc, connect: [value, ..acc.connect]), rest))

    // Pruning
    "--prune" | "-prune" -> {
      case int.parse(value) {
        Ok(mb) -> Ok(#(CliArgs(..acc, prune: Some(mb)), rest))
        Error(_) -> Error(InvalidValue(option: opt, value: value))
      }
    }

    // Generate blocks (regtest)
    "--generate" | "generate" -> {
      case int.parse(value) {
        Ok(count) ->
          Ok(#(CliArgs(..acc, command: GenerateBlock(count, None)), rest))
        Error(_) -> Error(InvalidValue(option: opt, value: value))
      }
    }

    _ -> Error(UnknownOption(opt))
  }
}

// ============================================================================
// Configuration Building
// ============================================================================

/// Build node configuration from CLI arguments
pub fn build_config(args: CliArgs) -> oni_node.NodeConfig {
  // Start with network-specific defaults
  let base = case args.network {
    oni_bitcoin.Mainnet -> oni_node.default_config()
    oni_bitcoin.Testnet -> oni_node.testnet_config()
    oni_bitcoin.Signet -> oni_node.testnet_config()
    // Use testnet config for signet
    oni_bitcoin.Regtest -> oni_node.regtest_config()
  }

  // Apply CLI overrides
  oni_node.NodeConfig(
    network: args.network,
    data_dir: option.unwrap(args.data_dir, base.data_dir),
    rpc_port: option.unwrap(args.rpc_port, base.rpc_port),
    rpc_bind: option.unwrap(args.rpc_bind, base.rpc_bind),
    p2p_port: option.unwrap(args.p2p_port, base.p2p_port),
    p2p_bind: option.unwrap(args.p2p_bind, base.p2p_bind),
    max_inbound: option.unwrap(args.max_connections, base.max_inbound),
    max_outbound: base.max_outbound,
    mempool_max_size: base.mempool_max_size,
    rpc_user: case args.rpc_user {
      Some(u) -> Some(u)
      None -> base.rpc_user
    },
    rpc_password: case args.rpc_password {
      Some(p) -> Some(p)
      None -> base.rpc_password
    },
    enable_rpc: True,
    enable_p2p: args.listen,
  )
}

// ============================================================================
// CLI Execution
// ============================================================================

/// Main CLI entry point
pub fn run(args: List(String)) -> Nil {
  case parse_args(args) {
    Error(err) -> {
      print_error(err)
      print_usage()
    }
    Ok(cli_args) -> execute_command(cli_args)
  }
}

fn execute_command(args: CliArgs) -> Nil {
  case args.command {
    ShowHelp -> print_help()
    ShowVersion -> print_version()
    StopDaemon -> stop_daemon(args)
    GetInfo -> get_info(args)
    GenerateBlock(count, address) -> generate_blocks(args, count, address)
    StartDaemon -> start_daemon(args)
  }
}

fn start_daemon(args: CliArgs) -> Nil {
  let config = build_config(args)

  print_startup_banner()
  print_network_info(config)

  case oni_node.start_with_config(config) {
    Ok(node) -> {
      io.println("")
      io.println("Node started successfully!")
      io.println("")
      print_rpc_info(config)
      io.println("")
      io.println("Press Ctrl+C to stop.")

      // Keep running
      process.sleep_forever()

      // Cleanup on exit
      oni_node.stop(node)
    }
    Error(err) -> {
      io.println("Error starting node: " <> err)
    }
  }
}

fn stop_daemon(_args: CliArgs) -> Nil {
  io.println("Sending stop signal to oni daemon...")
  // In a real implementation, this would connect to the RPC
  // and call the stop method
  io.println("(RPC client not yet implemented - use Ctrl+C)")
}

fn get_info(_args: CliArgs) -> Nil {
  io.println("Getting blockchain info...")
  // In a real implementation, this would connect to the RPC
  io.println("(RPC client not yet implemented)")
}

fn generate_blocks(args: CliArgs, count: Int, address: Option(String)) -> Nil {
  case args.network {
    oni_bitcoin.Regtest -> {
      io.println("Generating " <> int.to_string(count) <> " blocks...")

      // Start node components for mining
      case node_rpc.start_node_with_rpc(oni_bitcoin.Regtest, 100_000) {
        Error(err) -> {
          io.println("Error starting node: " <> err)
        }
        Ok(#(_node_handles, rpc_handles)) -> {
          // Perform mining via RPC handles
          let reply = process.new_subject()
          let mining_msg = case address {
            Some(addr) ->
              rpc_service.MineToAddress(count, addr, 1_000_000, reply)
            None -> rpc_service.MineBlocks(count, 1_000_000, reply)
          }

          // Send mining request to chainstate adapter
          process.send(rpc_handles.chainstate, mining_msg)

          // Wait for result with timeout
          case process.receive(reply, 300_000) {
            Ok(rpc_service.GenerateSuccess(hashes)) -> {
              io.println(
                "Successfully mined "
                <> int.to_string(list.length(hashes))
                <> " blocks:",
              )
              list.each(hashes, fn(hash) { io.println("  " <> hash) })
            }
            Ok(rpc_service.GenerateError(err)) -> {
              io.println("Mining failed: " <> err)
            }
            Error(_) -> {
              io.println("Mining timed out")
            }
          }
        }
      }
    }
    _ -> {
      io.println("Error: Block generation is only available in regtest mode")
    }
  }
}

// ============================================================================
// Output Formatting
// ============================================================================

fn print_error(err: CliError) -> Nil {
  case err {
    UnknownOption(opt) -> io.println("Error: Unknown option '" <> opt <> "'")
    InvalidValue(opt, val) ->
      io.println(
        "Error: Invalid value '" <> val <> "' for option '" <> opt <> "'",
      )
    MissingValue(opt) ->
      io.println("Error: Missing value for option '" <> opt <> "'")
    InvalidCommand(cmd) -> io.println("Error: Unknown command '" <> cmd <> "'")
  }
}

fn print_usage() -> Nil {
  io.println("")
  io.println("Usage: oni [options] [command]")
  io.println("Run 'oni --help' for more information.")
}

fn print_help() -> Nil {
  io.println("oni - A Bitcoin Full Node Implementation in Gleam")
  io.println("")
  io.println("Usage: oni [options] [command]")
  io.println("")
  io.println("Commands:")
  io.println("  (none)              Start the node daemon")
  io.println("  stop                Stop the running daemon")
  io.println("  getinfo             Get blockchain information")
  io.println("  generate <n>        Generate n blocks (regtest only)")
  io.println("")
  io.println("Network Selection:")
  io.println("  --mainnet           Use the main Bitcoin network (default)")
  io.println("  --testnet           Use the test network (testnet3)")
  io.println("  --signet            Use the signet network")
  io.println("  --regtest           Use regression test mode")
  io.println("")
  io.println("General Options:")
  io.println("  -h, --help          Show this help message")
  io.println("  -v, --version       Show version information")
  io.println("  --datadir=<dir>     Specify data directory")
  io.println("  --daemon            Run in the background as a daemon")
  io.println("  --debug             Enable debug output")
  io.println("")
  io.println("Connection Options:")
  io.println(
    "  --port=<port>       Listen for connections on <port> (default: 8333)",
  )
  io.println("  --bind=<addr>       Bind to given address (default: 0.0.0.0)")
  io.println("  --maxconnections=<n>  Maximum number of connections")
  io.println("  --addnode=<ip>      Add a node to connect to")
  io.println("  --connect=<ip>      Connect only to the specified node(s)")
  io.println("  --nolisten          Don't accept connections from outside")
  io.println("  --nodiscover        Don't discover peers")
  io.println("")
  io.println("RPC Server Options:")
  io.println("  --rpcport=<port>    Listen for RPC on <port> (default: 8332)")
  io.println(
    "  --rpcbind=<addr>    Bind RPC to given address (default: 127.0.0.1)",
  )
  io.println("  --rpcuser=<user>    Username for RPC authentication")
  io.println("  --rpcpassword=<pw>  Password for RPC authentication")
  io.println("")
  io.println("Storage Options:")
  io.println("  --txindex           Maintain a full transaction index")
  io.println("  --prune=<n>         Reduce storage by pruning (in MiB)")
  io.println("")
  io.println("Examples:")
  io.println("  oni --mainnet                     Start mainnet node")
  io.println("  oni --testnet --debug             Start testnet with debug")
  io.println("  oni --regtest --rpcport=18443     Start regtest node")
  io.println("  oni --datadir=/data/oni           Use custom data directory")
  io.println("")
  io.println("For more information, see: https://github.com/anthropics/oni")
}

fn print_version() -> Nil {
  io.println("oni version " <> oni_node.version)
  io.println("")
  io.println("Copyright (c) 2024 The oni Developers")
  io.println("License: MIT")
  io.println("")
  io.println("Built with Gleam for the Erlang/OTP runtime")
  io.println("Protocol version: 70016")
}

fn print_startup_banner() -> Nil {
  io.println("")
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
    "║   Bitcoin Full Node - Version "
    <> oni_node.version
    <> "                          ║",
  )
  io.println(
    "║                                                               ║",
  )
  io.println(
    "╚═══════════════════════════════════════════════════════════════╝",
  )
  io.println("")
}

fn print_network_info(config: oni_node.NodeConfig) -> Nil {
  let network_name = case config.network {
    oni_bitcoin.Mainnet -> "mainnet"
    oni_bitcoin.Testnet -> "testnet3"
    oni_bitcoin.Signet -> "signet"
    oni_bitcoin.Regtest -> "regtest"
  }

  let params = case config.network {
    oni_bitcoin.Mainnet -> oni_bitcoin.mainnet_params()
    oni_bitcoin.Testnet -> oni_bitcoin.testnet_params()
    // Signet uses testnet params as a base (signet-specific params not yet implemented)
    oni_bitcoin.Signet -> oni_bitcoin.testnet_params()
    oni_bitcoin.Regtest -> oni_bitcoin.regtest_params()
  }

  io.println("Network Configuration:")
  io.println("  Network:      " <> network_name)
  io.println("  Data Dir:     " <> config.data_dir)
  io.println("  P2P Port:     " <> int.to_string(config.p2p_port))
  io.println("  RPC Port:     " <> int.to_string(config.rpc_port))
  io.println(
    "  Genesis:      " <> oni_bitcoin.block_hash_to_hex(params.genesis_hash),
  )
  io.println("")
}

fn print_rpc_info(config: oni_node.NodeConfig) -> Nil {
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
  io.println("  curl -s --user user:pass -X POST \\")
  io.println("    -H 'Content-Type: application/json' \\")
  io.println(
    "    -d '{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"getblockchaininfo\"}' \\",
  )
  io.println(
    "    http://"
    <> config.rpc_bind
    <> ":"
    <> int.to_string(config.rpc_port)
    <> "/",
  )
}

// ============================================================================
// Main Entry Point
// ============================================================================

/// Main entry point - called from oni_node.main() or directly
pub fn main() -> Nil {
  // In a real implementation, we would get args from the Erlang runtime
  // For now, start with default mainnet configuration
  run([])
}
