// regtest_miner.gleam - Regtest block mining for local development
//
// This module provides CPU mining functionality for regtest mode:
// - Simple proof-of-work mining with low difficulty
// - Block template creation with mempool transactions
// - Coinbase transaction generation
// - Mining to specific addresses
//
// This is NOT for mainnet/testnet mining - only for local development!

import gleam/bit_array
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import oni_bitcoin

// ============================================================================
// Constants
// ============================================================================

/// Regtest minimum difficulty bits
pub const regtest_bits = 0x207fffff

/// Maximum nonce value
pub const max_nonce = 0xffffffff

/// Maximum extra nonce value (for coinbase)
pub const max_extra_nonce = 0xffffffff

/// Default coinbase script prefix
pub const coinbase_prefix = "/oni/"

/// Block subsidy halving interval
pub const halving_interval = 210_000

/// Initial block subsidy (50 BTC in satoshis)
pub const initial_subsidy = 5_000_000_000

// ============================================================================
// Types
// ============================================================================

/// Mining configuration
pub type MiningConfig {
  MiningConfig(
    /// Network (should be regtest)
    network: oni_bitcoin.Network,
    /// Address to pay coinbase reward to
    coinbase_address: Option(String),
    /// Script to use for coinbase output
    coinbase_script: BitArray,
    /// Extra data to include in coinbase
    coinbase_message: String,
  )
}

/// Mining result
pub type MiningResult {
  /// Successfully mined a block
  MinedBlock(oni_bitcoin.Block)
  /// Mining was interrupted
  Interrupted
  /// Mining failed
  MiningError(String)
}

/// Block template for mining
pub type BlockTemplate {
  BlockTemplate(
    /// Previous block hash
    prev_block: oni_bitcoin.BlockHash,
    /// Current height
    height: Int,
    /// Difficulty bits
    bits: Int,
    /// Block time
    time: Int,
    /// Block version
    version: Int,
    /// Transactions to include (excluding coinbase)
    transactions: List(oni_bitcoin.Transaction),
    /// Total fees from transactions
    total_fees: Int,
  )
}

// ============================================================================
// Default Configuration
// ============================================================================

/// Create default mining configuration for regtest
pub fn default_config() -> MiningConfig {
  // P2PKH script for a dummy address (used if no address specified)
  let dummy_script = <<
    0x76,
    // OP_DUP
    0xa9,
    // OP_HASH160
    0x14,
    // Push 20 bytes
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x88,
    // OP_EQUALVERIFY
    0xac,
    // OP_CHECKSIG
  >>

  MiningConfig(
    network: oni_bitcoin.Regtest,
    coinbase_address: None,
    coinbase_script: dummy_script,
    coinbase_message: coinbase_prefix,
  )
}

// ============================================================================
// Block Subsidy Calculation
// ============================================================================

/// Calculate block subsidy for a given height
pub fn calculate_subsidy(height: Int) -> Int {
  let halvings = height / halving_interval

  case halvings >= 64 {
    True -> 0
    False -> {
      int.bitwise_shift_right(initial_subsidy, halvings)
    }
  }
}

// ============================================================================
// Coinbase Transaction Creation
// ============================================================================

/// Create coinbase transaction for mining
pub fn create_coinbase(
  config: MiningConfig,
  height: Int,
  total_fees: Int,
  extra_nonce: Int,
) -> oni_bitcoin.Transaction {
  let subsidy = calculate_subsidy(height)
  let reward = subsidy + total_fees

  // Create coinbase input script (BIP34 height + extra nonce + message)
  let height_script = encode_height(height)
  let extra_nonce_bytes = <<extra_nonce:little-size(32)>>
  let message_bytes = bit_array.from_string(config.coinbase_message)

  let script_sig_bytes =
    bit_array.concat([height_script, extra_nonce_bytes, message_bytes])

  // Coinbase input (null prevout)
  let coinbase_input =
    oni_bitcoin.TxIn(
      prevout: oni_bitcoin.OutPoint(
        txid: oni_bitcoin.Txid(hash: oni_bitcoin.Hash256(bytes: <<0:256>>)),
        vout: 0xffffffff,
      ),
      script_sig: oni_bitcoin.Script(bytes: script_sig_bytes),
      sequence: 0xffffffff,
      witness: [],
    )

  // Coinbase output
  let coinbase_output =
    oni_bitcoin.TxOut(
      value: oni_bitcoin.Amount(sats: reward),
      script_pubkey: oni_bitcoin.Script(bytes: config.coinbase_script),
    )

  oni_bitcoin.Transaction(
    version: 1,
    inputs: [coinbase_input],
    outputs: [coinbase_output],
    lock_time: 0,
  )
}

/// Encode block height for coinbase (BIP34)
fn encode_height(height: Int) -> BitArray {
  case height {
    0 -> <<1, 0>>
    // OP_0
    n if n < 17 -> {
      let opcode = n + 0x50
      // OP_1 through OP_16
      <<opcode>>
    }
    n if n < 128 -> <<1, n>>
    // 1 byte
    n if n < 32_768 -> <<2, n:little-size(16)>>
    // 2 bytes
    n if n < 8_388_608 -> <<3, n:little-size(24)>>
    // 3 bytes
    n -> <<4, n:little-size(32)>>
    // 4 bytes
  }
}

// ============================================================================
// Merkle Root Calculation
// ============================================================================

/// Calculate merkle root from transaction list
pub fn calculate_merkle_root(txs: List(oni_bitcoin.Transaction)) -> BitArray {
  let txids =
    list.map(txs, fn(tx) {
      let txid = oni_bitcoin.txid_from_tx(tx)
      txid.hash.bytes
    })

  merkle_root(txids)
}

fn merkle_root(hashes: List(BitArray)) -> BitArray {
  case hashes {
    [] -> <<0:256>>
    [single] -> single
    _ -> {
      let pairs = pair_hashes(hashes)
      let next_level =
        list.map(pairs, fn(pair) {
          let #(left, right) = pair
          oni_bitcoin.sha256d(bit_array.concat([left, right]))
        })
      merkle_root(next_level)
    }
  }
}

fn pair_hashes(hashes: List(BitArray)) -> List(#(BitArray, BitArray)) {
  case hashes {
    [] -> []
    [single] -> [#(single, single)]
    // Duplicate last if odd
    [a, b, ..rest] -> [#(a, b), ..pair_hashes(rest)]
  }
}

// ============================================================================
// Block Mining
// ============================================================================

/// Mine a single block with given template
pub fn mine_block(config: MiningConfig, template: BlockTemplate) -> MiningResult {
  // Try with different extra nonces
  mine_with_extra_nonce(config, template, 0)
}

fn mine_with_extra_nonce(
  config: MiningConfig,
  template: BlockTemplate,
  extra_nonce: Int,
) -> MiningResult {
  case extra_nonce > max_extra_nonce {
    True -> MiningError("Exhausted search space")
    False -> {
      // Create coinbase with this extra nonce
      let coinbase =
        create_coinbase(
          config,
          template.height,
          template.total_fees,
          extra_nonce,
        )

      // Build transaction list
      let all_txs = [coinbase, ..template.transactions]

      // Calculate merkle root
      let merkle = calculate_merkle_root(all_txs)

      // Create block header
      let header =
        oni_bitcoin.BlockHeader(
          version: template.version,
          prev_block: template.prev_block,
          merkle_root: oni_bitcoin.Hash256(bytes: merkle),
          timestamp: template.time,
          bits: template.bits,
          nonce: 0,
        )

      // Try mining with this coinbase
      case mine_header(header, template.bits) {
        Some(mined_header) -> {
          MinedBlock(oni_bitcoin.Block(
            header: mined_header,
            transactions: all_txs,
          ))
        }
        None -> {
          // Try next extra nonce
          mine_with_extra_nonce(config, template, extra_nonce + 1)
        }
      }
    }
  }
}

/// Mine a block header by finding valid nonce
fn mine_header(
  header: oni_bitcoin.BlockHeader,
  bits: Int,
) -> Option(oni_bitcoin.BlockHeader) {
  let target = bits_to_target(bits)
  mine_nonce(header, 0, target)
}

fn mine_nonce(
  header: oni_bitcoin.BlockHeader,
  nonce: Int,
  target: BitArray,
) -> Option(oni_bitcoin.BlockHeader) {
  case nonce > max_nonce {
    True -> None
    False -> {
      let candidate = oni_bitcoin.BlockHeader(..header, nonce: nonce)
      let hash = hash_header(candidate)

      case compare_hash_to_target(hash, target) {
        True -> Some(candidate)
        False -> mine_nonce(header, nonce + 1, target)
      }
    }
  }
}

/// Hash a block header (double SHA256)
fn hash_header(header: oni_bitcoin.BlockHeader) -> BitArray {
  let bytes = oni_bitcoin.encode_block_header(header)
  oni_bitcoin.sha256d(bytes)
}

/// Convert difficulty bits to target threshold
fn bits_to_target(bits: Int) -> BitArray {
  let exponent = int.bitwise_shift_right(bits, 24)
  let mantissa = int.bitwise_and(bits, 0x007fffff)

  // Handle negative bit
  let mantissa = case int.bitwise_and(bits, 0x00800000) != 0 {
    True -> -mantissa
    False -> mantissa
  }

  // Calculate target: mantissa * 2^(8*(exponent-3))
  let shift = 8 * { exponent - 3 }
  case shift >= 0 {
    True -> {
      let target_int = int.bitwise_shift_left(mantissa, shift)
      int_to_32_bytes(target_int)
    }
    False -> {
      let target_int = int.bitwise_shift_right(mantissa, -shift)
      int_to_32_bytes(target_int)
    }
  }
}

fn int_to_32_bytes(n: Int) -> BitArray {
  // Convert integer to 32-byte big-endian representation
  let bytes = int_to_bytes(n, [])
  let padding_needed = 32 - list.length(bytes)
  let padding = list.repeat(0, padding_needed)
  list.fold(list.append(padding, bytes), <<>>, fn(acc, b) {
    bit_array.concat([acc, <<b>>])
  })
}

fn int_to_bytes(n: Int, acc: List(Int)) -> List(Int) {
  case n <= 0 {
    True ->
      case acc {
        [] -> [0]
        _ -> acc
      }
    False -> {
      let byte = int.bitwise_and(n, 0xff)
      int_to_bytes(int.bitwise_shift_right(n, 8), [byte, ..acc])
    }
  }
}

/// Compare hash to target (hash must be <= target)
fn compare_hash_to_target(hash: BitArray, target: BitArray) -> Bool {
  // Hash is in little-endian, target in big-endian
  // Reverse hash for comparison
  let reversed_hash = reverse_bytes_acc(hash, <<>>)
  compare_bytes(reversed_hash, target)
}

fn reverse_bytes_acc(input: BitArray, acc: BitArray) -> BitArray {
  case input {
    <<>> -> acc
    <<b:size(8), rest:bytes>> -> reverse_bytes_acc(rest, <<b, acc:bits>>)
    _ -> acc
  }
}

fn compare_bytes(a: BitArray, b: BitArray) -> Bool {
  case a, b {
    <<>>, <<>> -> True
    // Equal
    <<ab:size(8), arest:bytes>>, <<bb:size(8), brest:bytes>> -> {
      case ab < bb {
        True -> True
        False ->
          case ab > bb {
            True -> False
            False -> compare_bytes(arest, brest)
          }
      }
    }
    _, _ -> False
  }
}

// ============================================================================
// Generate Multiple Blocks
// ============================================================================

/// Generate multiple blocks in sequence
pub fn generate_blocks(
  config: MiningConfig,
  prev_block: oni_bitcoin.BlockHash,
  height: Int,
  count: Int,
  base_time: Int,
) -> Result(List(oni_bitcoin.Block), String) {
  generate_blocks_loop(config, prev_block, height, count, base_time, [])
}

fn generate_blocks_loop(
  config: MiningConfig,
  prev_block: oni_bitcoin.BlockHash,
  height: Int,
  remaining: Int,
  time: Int,
  acc: List(oni_bitcoin.Block),
) -> Result(List(oni_bitcoin.Block), String) {
  case remaining <= 0 {
    True -> Ok(list.reverse(acc))
    False -> {
      let template =
        BlockTemplate(
          prev_block: prev_block,
          height: height,
          bits: regtest_bits,
          time: time,
          version: 0x20000000,
          // BIP9 version bits
          transactions: [],
          total_fees: 0,
        )

      case mine_block(config, template) {
        MinedBlock(block) -> {
          let block_hash = oni_bitcoin.block_hash_from_header(block.header)
          generate_blocks_loop(
            config,
            block_hash,
            height + 1,
            remaining - 1,
            time + 600,
            // 10 minutes between blocks
            [block, ..acc],
          )
        }
        MiningError(err) -> Error(err)
        Interrupted -> Error("Mining interrupted")
      }
    }
  }
}

// ============================================================================
// RPC Integration Types
// ============================================================================

/// Result of generateblock RPC call
pub type GenerateBlockResult {
  GenerateBlockResult(hash: oni_bitcoin.BlockHash, height: Int)
}

/// Result of generatetoaddress RPC call
pub type GenerateToAddressResult {
  GenerateToAddressResult(hashes: List(oni_bitcoin.BlockHash))
}

// ============================================================================
// Witness Commitment (SegWit)
// ============================================================================

/// Calculate witness commitment for SegWit blocks
pub fn calculate_witness_commitment(
  txs: List(oni_bitcoin.Transaction),
) -> BitArray {
  // Calculate witness merkle root
  let wtxids =
    list.map(txs, fn(tx) {
      let wtxid = oni_bitcoin.wtxid_from_tx(tx)
      wtxid.hash.bytes
    })

  // First wtxid (coinbase) is 0x00...00
  let wtxids = case wtxids {
    [_, ..rest] -> [<<0:256>>, ..rest]
    [] -> [<<0:256>>]
  }

  let witness_merkle = merkle_root(wtxids)

  // Commitment = SHA256d(witness_merkle_root || witness_reserved_value)
  let witness_reserved_value = <<0:256>>
  oni_bitcoin.sha256d(
    bit_array.concat([witness_merkle, witness_reserved_value]),
  )
}

/// Create witness commitment output script
pub fn witness_commitment_script(commitment: BitArray) -> BitArray {
  // OP_RETURN followed by the commitment
  bit_array.concat([
    <<0x6a, 0x24, 0xaa, 0x21, 0xa9, 0xed>>,
    // OP_RETURN PUSH36 WITNESS_MAGIC
    commitment,
  ])
}

/// Add witness commitment to coinbase
pub fn add_witness_commitment(
  coinbase: oni_bitcoin.Transaction,
  other_txs: List(oni_bitcoin.Transaction),
) -> oni_bitcoin.Transaction {
  let commitment = calculate_witness_commitment([coinbase, ..other_txs])
  let commit_script = witness_commitment_script(commitment)

  let commit_output =
    oni_bitcoin.TxOut(
      value: oni_bitcoin.Amount(sats: 0),
      script_pubkey: oni_bitcoin.Script(bytes: commit_script),
    )

  oni_bitcoin.Transaction(
    ..coinbase,
    outputs: list.append(coinbase.outputs, [commit_output]),
  )
}
