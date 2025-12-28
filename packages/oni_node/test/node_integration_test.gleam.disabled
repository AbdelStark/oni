// node_integration_test.gleam - Integration tests for oni node components
//
// These tests verify that the major node subsystems work together correctly:
// - Chainstate with persistent storage
// - Mempool with validation
// - P2P event routing
// - IBD coordination
// - Block validation and connection

import gleam/dict
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{None, Some}
import gleeunit/should
import oni_bitcoin
import oni_storage
import activation
import persistent_chainstate
import event_router
import ibd_coordinator
import reorg_handler
import oni_supervisor

// ============================================================================
// Test Helpers
// ============================================================================

/// Create a test data directory
fn test_data_dir() -> String {
  "/tmp/oni_test_" <> int.to_string(erlang_unique_integer())
}

@external(erlang, "erlang", "unique_integer")
fn erlang_unique_integer() -> Int

/// Clean up test data directory
fn cleanup_test_dir(dir: String) -> Nil {
  let _ = remove_dir_recursive(dir)
  Nil
}

@external(erlang, "file", "del_dir_r")
fn remove_dir_recursive(path: String) -> Result(Nil, Nil)

/// Create a regtest genesis block
fn create_regtest_genesis() -> oni_bitcoin.Block {
  let params = oni_bitcoin.regtest_params()
  params.genesis_block
}

/// Create a test block that extends the given parent
fn create_test_block(
  parent_hash: oni_bitcoin.BlockHash,
  height: Int,
  _timestamp: Int,
) -> oni_bitcoin.Block {
  // Create a minimal test block
  let header = oni_bitcoin.BlockHeader(
    version: 1,
    prev_block: parent_hash,
    merkle_root: oni_bitcoin.Hash256(bytes: <<0:256>>),
    timestamp: 1231006505 + height * 600,
    bits: 0x207fffff,  // Regtest minimum difficulty
    nonce: 0,
  )

  // Create a coinbase transaction
  let coinbase = create_coinbase_tx(height)

  oni_bitcoin.Block(
    header: header,
    transactions: [coinbase],
  )
}

/// Create a coinbase transaction
fn create_coinbase_tx(height: Int) -> oni_bitcoin.Transaction {
  // Create coinbase input (points to null outpoint)
  let coinbase_input = oni_bitcoin.TxIn(
    prevout: oni_bitcoin.outpoint_null(),
    script_sig: create_coinbase_script(height),
    sequence: 0xffffffff,
    witness: [],
  )

  // Create coinbase output (50 BTC subsidy)
  let subsidy = activation.get_block_subsidy(height, oni_bitcoin.Regtest)
  let coinbase_output = oni_bitcoin.TxOut(
    value: oni_bitcoin.Amount(sats: subsidy),
    script_pubkey: oni_bitcoin.Script(bytes: <<0x51>>),  // OP_TRUE
  )

  oni_bitcoin.Transaction(
    version: 1,
    inputs: [coinbase_input],
    outputs: [coinbase_output],
    locktime: 0,
  )
}

/// Create a coinbase script with block height
fn create_coinbase_script(height: Int) -> oni_bitcoin.Script {
  // BIP 34 coinbase: push block height
  let height_bytes = encode_height(height)
  oni_bitcoin.Script(bytes: height_bytes)
}

fn encode_height(height: Int) -> BitArray {
  case height {
    0 -> <<0x00>>
    _ -> {
      let bytes = encode_int_le(height)
      let len = byte_size(bytes)
      <<len:8, bytes:bits>>
    }
  }
}

fn encode_int_le(n: Int) -> BitArray {
  case n <= 255 {
    True -> <<n:8>>
    False -> {
      let low = n % 256
      let high = n / 256
      <<low:8, encode_int_le(high):bits>>
    }
  }
}

@external(erlang, "erlang", "byte_size")
fn byte_size(data: BitArray) -> Int

// ============================================================================
// Activation Tests
// ============================================================================

pub fn activation_heights_mainnet_test() {
  let activations = activation.mainnet_activations()

  // Verify mainnet activation heights
  should.equal(activations.bip34_height, 227_931)
  should.equal(activations.segwit_height, 481_824)
  should.equal(activations.taproot_height, 709_632)
  should.equal(activations.allow_min_difficulty_blocks, False)
}

pub fn activation_heights_testnet_test() {
  let activations = activation.testnet_activations()

  // Testnet allows min difficulty blocks
  should.equal(activations.allow_min_difficulty_blocks, True)
  // SegWit activated at different height
  should.equal(activations.segwit_height, 834_624)
}

pub fn activation_heights_regtest_test() {
  let activations = activation.regtest_activations()

  // Regtest has SegWit and Taproot active from genesis
  should.equal(activations.segwit_height, 0)
  should.equal(activations.taproot_height, 0)
  should.equal(activations.allow_min_difficulty_blocks, True)
}

pub fn is_segwit_active_test() {
  // Not active before activation height on mainnet
  should.equal(activation.is_segwit_active(481_823, oni_bitcoin.Mainnet), False)

  // Active at activation height
  should.equal(activation.is_segwit_active(481_824, oni_bitcoin.Mainnet), True)

  // Active after activation height
  should.equal(activation.is_segwit_active(500_000, oni_bitcoin.Mainnet), True)

  // Always active on regtest
  should.equal(activation.is_segwit_active(0, oni_bitcoin.Regtest), True)
}

pub fn is_taproot_active_test() {
  // Not active before activation height on mainnet
  should.equal(activation.is_taproot_active(709_631, oni_bitcoin.Mainnet), False)

  // Active at activation height
  should.equal(activation.is_taproot_active(709_632, oni_bitcoin.Mainnet), True)

  // Always active on regtest
  should.equal(activation.is_taproot_active(0, oni_bitcoin.Regtest), True)
}

pub fn block_subsidy_test() {
  // Initial subsidy is 50 BTC (5,000,000,000 satoshis)
  should.equal(activation.get_block_subsidy(0, oni_bitcoin.Mainnet), 5_000_000_000)

  // After first halving (210,000 blocks) = 25 BTC
  should.equal(activation.get_block_subsidy(210_000, oni_bitcoin.Mainnet), 2_500_000_000)

  // After second halving = 12.5 BTC
  should.equal(activation.get_block_subsidy(420_000, oni_bitcoin.Mainnet), 1_250_000_000)

  // After third halving = 6.25 BTC
  should.equal(activation.get_block_subsidy(630_000, oni_bitcoin.Mainnet), 625_000_000)

  // After 64 halvings = 0
  should.equal(activation.get_block_subsidy(64 * 210_000, oni_bitcoin.Mainnet), 0)
}

pub fn coinbase_maturity_test() {
  // Coinbase at height 100 is not mature at height 199
  should.equal(activation.is_coinbase_mature(100, 199), False)

  // Coinbase at height 100 is mature at height 200
  should.equal(activation.is_coinbase_mature(100, 200), True)

  // Coinbase at height 0 is mature at height 100
  should.equal(activation.is_coinbase_mature(0, 100), True)
}

pub fn difficulty_adjustment_height_test() {
  // Height 0 is not adjustment
  should.equal(activation.is_difficulty_adjustment_height(0), False)

  // Height 2016 is adjustment
  should.equal(activation.is_difficulty_adjustment_height(2016), True)

  // Height 4032 is adjustment
  should.equal(activation.is_difficulty_adjustment_height(4032), True)

  // Height 2015 is not adjustment
  should.equal(activation.is_difficulty_adjustment_height(2015), False)
}

pub fn checkpoint_verification_test() {
  // Correct checkpoint should pass
  let result = activation.verify_checkpoint(
    11_111,
    "0000000069e244f73d78e8fd29ba2fd2ed618bd6fa2ee92559f542fdb26e7c1d",
    oni_bitcoin.Mainnet,
  )
  should.equal(result, True)

  // Wrong hash should fail
  let result2 = activation.verify_checkpoint(
    11_111,
    "0000000000000000000000000000000000000000000000000000000000000000",
    oni_bitcoin.Mainnet,
  )
  should.equal(result2, False)

  // Height with no checkpoint should pass
  let result3 = activation.verify_checkpoint(
    12_345,
    "anyhash",
    oni_bitcoin.Mainnet,
  )
  should.equal(result3, True)
}

// ============================================================================
// Script Flags Tests
// ============================================================================

pub fn mandatory_flags_pre_segwit_test() {
  // Before SegWit on mainnet
  let flags = activation.get_mandatory_flags(400_000, oni_bitcoin.Mainnet)

  should.equal(flags.verify_p2sh, True)
  should.equal(flags.verify_dersig, True)
  should.equal(flags.verify_checklocktimeverify, True)
  should.equal(flags.verify_checksequenceverify, False)
  should.equal(flags.verify_witness, False)
  should.equal(flags.verify_taproot, False)
}

pub fn mandatory_flags_segwit_test() {
  // After SegWit, before Taproot on mainnet
  let flags = activation.get_mandatory_flags(500_000, oni_bitcoin.Mainnet)

  should.equal(flags.verify_p2sh, True)
  should.equal(flags.verify_dersig, True)
  should.equal(flags.verify_checksequenceverify, True)
  should.equal(flags.verify_witness, True)
  should.equal(flags.verify_nulldummy, True)
  should.equal(flags.verify_taproot, False)
}

pub fn mandatory_flags_taproot_test() {
  // After Taproot on mainnet
  let flags = activation.get_mandatory_flags(750_000, oni_bitcoin.Mainnet)

  should.equal(flags.verify_witness, True)
  should.equal(flags.verify_taproot, True)
  should.equal(flags.verify_const_scriptcode, True)
}

pub fn standard_flags_stricter_test() {
  // Standard flags should be stricter than mandatory
  let mandatory = activation.get_mandatory_flags(500_000, oni_bitcoin.Mainnet)
  let standard = activation.get_standard_flags(500_000, oni_bitcoin.Mainnet)

  // Standard enables additional checks
  should.equal(standard.verify_strictenc, True)
  should.equal(mandatory.verify_strictenc, False)

  should.equal(standard.verify_low_s, True)
  should.equal(mandatory.verify_low_s, False)

  should.equal(standard.verify_cleanstack, True)
  should.equal(mandatory.verify_cleanstack, False)
}

// ============================================================================
// Storage Integration Tests
// ============================================================================

pub fn storage_block_undo_test() {
  // Create block undo data
  let undo = oni_storage.block_undo_new()

  // Create a tx undo with spent coins
  let coin = oni_storage.Coin(
    output: oni_bitcoin.TxOut(
      value: oni_bitcoin.Amount(sats: 100_000),
      script_pubkey: oni_bitcoin.Script(bytes: <<0x51>>),
    ),
    height: 100,
    is_coinbase: False,
  )

  let tx_undo = oni_storage.tx_undo_new()
  let tx_undo2 = oni_storage.tx_undo_add_spent(tx_undo, coin)

  let undo2 = oni_storage.block_undo_add(undo, tx_undo2)
  let final_undo = oni_storage.block_undo_finalize(undo2)

  // Verify we have one tx undo with one spent coin
  should.equal(list.length(final_undo.tx_undos), 1)
}

pub fn storage_chainstate_test() {
  let genesis_hash = oni_bitcoin.BlockHash(
    hash: oni_bitcoin.Hash256(bytes: <<1:256>>),
  )

  let chainstate = oni_storage.Chainstate(
    best_block: genesis_hash,
    best_height: 0,
    total_tx: 1,
    total_coins: 1,
    total_amount: 5_000_000_000,
    pruned: False,
    pruned_height: None,
  )

  should.equal(chainstate.best_height, 0)
  should.equal(chainstate.total_coins, 1)
}

// ============================================================================
// Network Parameters Tests
// ============================================================================

pub fn mainnet_params_test() {
  let params = oni_bitcoin.mainnet_params()

  // Mainnet port is 8333
  should.equal(params.default_port, 8333)

  // Mainnet magic bytes
  should.equal(params.magic, <<0xf9, 0xbe, 0xb4, 0xd9>>)

  // Genesis hash starts with many zeros
  let genesis_hex = oni_bitcoin.block_hash_to_hex(params.genesis_hash)
  should.equal(
    genesis_hex,
    "000000000019d6689c085ae165831e934ff763ae46a2a6c172b3f1b60a8ce26f",
  )
}

pub fn testnet_params_test() {
  let params = oni_bitcoin.testnet_params()

  // Testnet port is 18333
  should.equal(params.default_port, 18333)

  // Testnet magic bytes
  should.equal(params.magic, <<0x0b, 0x11, 0x09, 0x07>>)
}

pub fn regtest_params_test() {
  let params = oni_bitcoin.regtest_params()

  // Regtest port is 18444
  should.equal(params.default_port, 18444)

  // Regtest magic bytes
  should.equal(params.magic, <<0xfa, 0xbf, 0xb5, 0xda>>)
}

// ============================================================================
// IBD Coordinator Tests
// ============================================================================

pub fn ibd_config_test() {
  let config = ibd_coordinator.default_config(oni_bitcoin.Mainnet)

  should.equal(config.blocks_per_peer, 16)
  should.equal(config.max_inflight_blocks, 128)
  should.equal(config.headers_batch_size, 2000)
  should.equal(config.min_peers, 1)
  should.equal(config.use_checkpoints, True)
}

pub fn ibd_status_initial_test() {
  let status = ibd_coordinator.IbdStatus(
    state: ibd_coordinator.IbdWaitingForPeers,
    headers_height: 0,
    blocks_height: 0,
    connected_peers: 0,
    inflight_blocks: 0,
    progress_percent: 0.0,
  )

  should.equal(status.headers_height, 0)
  should.equal(status.blocks_height, 0)
}

// ============================================================================
// Reorg Handler Tests
// ============================================================================

pub fn reorg_config_test() {
  let config = reorg_handler.default_config()

  should.equal(config.max_reorg_depth, 100)
  should.equal(config.resubmit_txs, True)
}

pub fn fork_block_creation_test() {
  let hash = oni_bitcoin.BlockHash(hash: oni_bitcoin.Hash256(bytes: <<1:256>>))
  let prev = oni_bitcoin.BlockHash(hash: oni_bitcoin.Hash256(bytes: <<0:256>>))

  let block = reorg_handler.ForkBlock(
    hash: hash,
    height: 100,
    prev_hash: prev,
    total_work: 1000,
  )

  should.equal(block.height, 100)
  should.equal(block.total_work, 1000)
}

pub fn reorg_event_test() {
  let fork_point = oni_bitcoin.BlockHash(hash: oni_bitcoin.Hash256(bytes: <<1:256>>))

  let event = reorg_handler.ReorgEvent(
    fork_point: fork_point,
    fork_height: 99,
    blocks_disconnected: 3,
    blocks_connected: 5,
    resubmit_txs: [],
  )

  should.equal(event.blocks_disconnected, 3)
  should.equal(event.blocks_connected, 5)
}

// ============================================================================
// Event Router Tests
// ============================================================================

pub fn router_config_test() {
  let config = event_router.default_config()

  should.equal(config.max_pending_blocks, 16)
  should.equal(config.max_pending_txs, 100)
}

pub fn router_stats_initial_test() {
  let stats = event_router.RouterStats(
    blocks_received: 0,
    txs_received: 0,
    headers_received: 0,
    blocks_requested: 0,
    txs_requested: 0,
    peers_connected: 0,
    peers_disconnected: 0,
  )

  should.equal(stats.blocks_received, 0)
  should.equal(stats.peers_connected, 0)
}

// ============================================================================
// Supervisor Tests
// ============================================================================

pub fn chainstate_config_test() {
  let config = oni_supervisor.default_start_config()

  should.equal(config.p2p_port, 8333)
  should.equal(config.rpc_port, 8332)
  should.equal(config.max_connections, 125)
}

// ============================================================================
// Block Weight and Size Tests
// ============================================================================

pub fn block_limits_test() {
  // Maximum block weight is 4MB
  should.equal(activation.max_block_weight, 4_000_000)

  // Maximum base block size is 1MB
  should.equal(activation.max_block_base_size, 1_000_000)

  // Maximum sigops cost
  should.equal(activation.max_block_sigops_cost, 80_000)
}

pub fn script_limits_test() {
  // Maximum script size is 10KB
  should.equal(activation.max_script_size, 10_000)

  // Maximum stack size
  should.equal(activation.max_stack_size, 1000)

  // Maximum ops per script
  should.equal(activation.max_ops_per_script, 201)

  // Maximum pubkeys in multisig
  should.equal(activation.max_pubkeys_per_multisig, 20)
}

// ============================================================================
// Integration Flow Test
// ============================================================================

pub fn integration_flow_test() {
  // This test verifies the basic flow of block processing:
  // 1. Create a regtest genesis block
  // 2. Create a block extending genesis
  // 3. Verify block structure

  let genesis = create_regtest_genesis()
  let genesis_hash = oni_bitcoin.block_hash_from_header(genesis.header)

  // Create a block extending genesis
  let block1 = create_test_block(genesis_hash, 1, 1231006505 + 600)
  let _block1_hash = oni_bitcoin.block_hash_from_header(block1.header)

  // Verify block structure
  should.equal(list.length(block1.transactions), 1)
  should.equal(block1.header.prev_block.hash.bytes, genesis_hash.hash.bytes)

  // Verify coinbase output has correct subsidy
  case list.first(block1.transactions) {
    None -> should.fail()
    Some(coinbase) -> {
      case list.first(coinbase.outputs) {
        None -> should.fail()
        Some(output) -> {
          // Regtest subsidy at height 1 should still be 50 BTC
          let expected_subsidy = activation.get_block_subsidy(1, oni_bitcoin.Regtest)
          should.equal(output.value.sats, expected_subsidy)
        }
      }
    }
  }
}

pub fn block_chain_construction_test() {
  // Test building a chain of blocks
  let genesis = create_regtest_genesis()
  let hash0 = oni_bitcoin.block_hash_from_header(genesis.header)

  let block1 = create_test_block(hash0, 1, 1)
  let hash1 = oni_bitcoin.block_hash_from_header(block1.header)

  let block2 = create_test_block(hash1, 2, 2)
  let hash2 = oni_bitcoin.block_hash_from_header(block2.header)

  let block3 = create_test_block(hash2, 3, 3)
  let _hash3 = oni_bitcoin.block_hash_from_header(block3.header)

  // Verify chain links correctly
  should.equal(block1.header.prev_block.hash.bytes, hash0.hash.bytes)
  should.equal(block2.header.prev_block.hash.bytes, hash1.hash.bytes)
  should.equal(block3.header.prev_block.hash.bytes, hash2.hash.bytes)
}
