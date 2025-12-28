// cli_test.gleam - Tests for CLI argument parsing

import cli
import gleam/option.{Some}
import gleeunit/should
import oni_bitcoin

pub fn parse_empty_args_test() {
  let result = cli.parse_args([])
  should.be_ok(result)

  let args = case result {
    Ok(a) -> a
    Error(_) -> cli.default_args()
  }

  args.network
  |> should.equal(oni_bitcoin.Mainnet)
}

pub fn parse_mainnet_test() {
  let result = cli.parse_args(["--mainnet"])
  should.be_ok(result)

  let args = case result {
    Ok(a) -> a
    Error(_) -> cli.default_args()
  }

  args.network
  |> should.equal(oni_bitcoin.Mainnet)
}

pub fn parse_testnet_test() {
  let result = cli.parse_args(["--testnet"])
  should.be_ok(result)

  let args = case result {
    Ok(a) -> a
    Error(_) -> cli.default_args()
  }

  args.network
  |> should.equal(oni_bitcoin.Testnet)
}

pub fn parse_regtest_test() {
  let result = cli.parse_args(["--regtest"])
  should.be_ok(result)

  let args = case result {
    Ok(a) -> a
    Error(_) -> cli.default_args()
  }

  args.network
  |> should.equal(oni_bitcoin.Regtest)
}

pub fn parse_signet_test() {
  let result = cli.parse_args(["--signet"])
  should.be_ok(result)

  let args = case result {
    Ok(a) -> a
    Error(_) -> cli.default_args()
  }

  args.network
  |> should.equal(oni_bitcoin.Signet)
}

pub fn parse_help_test() {
  let result = cli.parse_args(["--help"])
  should.be_ok(result)

  let args = case result {
    Ok(a) -> a
    Error(_) -> cli.default_args()
  }

  case args.command {
    cli.ShowHelp -> should.be_true(True)
    _ -> should.be_true(False)
  }
}

pub fn parse_version_test() {
  let result = cli.parse_args(["--version"])
  should.be_ok(result)

  let args = case result {
    Ok(a) -> a
    Error(_) -> cli.default_args()
  }

  case args.command {
    cli.ShowVersion -> should.be_true(True)
    _ -> should.be_true(False)
  }
}

pub fn parse_datadir_test() {
  let result = cli.parse_args(["--datadir=/custom/path"])
  should.be_ok(result)

  let args = case result {
    Ok(a) -> a
    Error(_) -> cli.default_args()
  }

  args.data_dir
  |> should.equal(Some("/custom/path"))
}

pub fn parse_rpcport_test() {
  let result = cli.parse_args(["--rpcport=9999"])
  should.be_ok(result)

  let args = case result {
    Ok(a) -> a
    Error(_) -> cli.default_args()
  }

  args.rpc_port
  |> should.equal(Some(9999))
}

pub fn parse_port_test() {
  let result = cli.parse_args(["--port=8888"])
  should.be_ok(result)

  let args = case result {
    Ok(a) -> a
    Error(_) -> cli.default_args()
  }

  args.p2p_port
  |> should.equal(Some(8888))
}

pub fn parse_daemon_test() {
  let result = cli.parse_args(["--daemon"])
  should.be_ok(result)

  let args = case result {
    Ok(a) -> a
    Error(_) -> cli.default_args()
  }

  args.daemon
  |> should.be_true
}

pub fn parse_debug_test() {
  let result = cli.parse_args(["--debug"])
  should.be_ok(result)

  let args = case result {
    Ok(a) -> a
    Error(_) -> cli.default_args()
  }

  args.debug
  |> should.be_true
}

pub fn parse_txindex_test() {
  let result = cli.parse_args(["--txindex"])
  should.be_ok(result)

  let args = case result {
    Ok(a) -> a
    Error(_) -> cli.default_args()
  }

  args.txindex
  |> should.be_true
}

pub fn parse_nolisten_test() {
  let result = cli.parse_args(["--nolisten"])
  should.be_ok(result)

  let args = case result {
    Ok(a) -> a
    Error(_) -> cli.default_args()
  }

  args.listen
  |> should.be_false
}

pub fn parse_multiple_args_test() {
  let result = cli.parse_args([
    "--regtest",
    "--datadir=/data/regtest",
    "--rpcport=18443",
    "--port=18444",
    "--debug",
  ])
  should.be_ok(result)

  let args = case result {
    Ok(a) -> a
    Error(_) -> cli.default_args()
  }

  args.network
  |> should.equal(oni_bitcoin.Regtest)

  args.data_dir
  |> should.equal(Some("/data/regtest"))

  args.rpc_port
  |> should.equal(Some(18443))

  args.p2p_port
  |> should.equal(Some(18444))

  args.debug
  |> should.be_true
}

pub fn parse_rpc_auth_test() {
  let result = cli.parse_args([
    "--rpcuser=myuser",
    "--rpcpassword=mypassword",
  ])
  should.be_ok(result)

  let args = case result {
    Ok(a) -> a
    Error(_) -> cli.default_args()
  }

  args.rpc_user
  |> should.equal(Some("myuser"))

  args.rpc_password
  |> should.equal(Some("mypassword"))
}

pub fn parse_addnode_test() {
  let result = cli.parse_args([
    "--addnode=192.168.1.1:8333",
    "--addnode=192.168.1.2:8333",
  ])
  should.be_ok(result)

  let args = case result {
    Ok(a) -> a
    Error(_) -> cli.default_args()
  }

  // Addnode list should have 2 entries
  case args.addnode {
    [_, _] -> should.be_true(True)
    _ -> should.be_true(False)
  }
}

pub fn parse_stop_command_test() {
  let result = cli.parse_args(["stop"])
  should.be_ok(result)

  let args = case result {
    Ok(a) -> a
    Error(_) -> cli.default_args()
  }

  case args.command {
    cli.StopDaemon -> should.be_true(True)
    _ -> should.be_true(False)
  }
}

pub fn parse_getinfo_command_test() {
  let result = cli.parse_args(["getinfo"])
  should.be_ok(result)

  let args = case result {
    Ok(a) -> a
    Error(_) -> cli.default_args()
  }

  case args.command {
    cli.GetInfo -> should.be_true(True)
    _ -> should.be_true(False)
  }
}

pub fn parse_unknown_option_error_test() {
  let result = cli.parse_args(["--unknown-option"])
  should.be_error(result)
}

pub fn parse_invalid_port_error_test() {
  let result = cli.parse_args(["--rpcport=invalid"])
  should.be_error(result)
}

pub fn build_config_mainnet_test() {
  let args = cli.default_args()
  let config = cli.build_config(args)

  config.network
  |> should.equal(oni_bitcoin.Mainnet)

  config.rpc_port
  |> should.equal(8332)

  config.p2p_port
  |> should.equal(8333)
}

pub fn build_config_regtest_test() {
  let args = cli.CliArgs(..cli.default_args(), network: oni_bitcoin.Regtest)
  let config = cli.build_config(args)

  config.network
  |> should.equal(oni_bitcoin.Regtest)

  config.rpc_port
  |> should.equal(18443)

  config.p2p_port
  |> should.equal(18444)
}

pub fn build_config_with_overrides_test() {
  let args = cli.CliArgs(
    ..cli.default_args(),
    network: oni_bitcoin.Testnet,
    rpc_port: Some(9999),
    p2p_port: Some(8888),
    data_dir: Some("/custom/path"),
  )
  let config = cli.build_config(args)

  config.network
  |> should.equal(oni_bitcoin.Testnet)

  config.rpc_port
  |> should.equal(9999)

  config.p2p_port
  |> should.equal(8888)

  config.data_dir
  |> should.equal("/custom/path")
}
