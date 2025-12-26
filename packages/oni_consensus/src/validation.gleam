// validation.gleam - Transaction and block validation (Phase 4)
//
// This module provides complete transaction and block validation including:
// - Stateless validation (structure, amounts, sizes)
// - Contextual validation (UTXO availability, maturity, locktime)
// - Sighash computation (legacy, SegWit v0, Taproot)
// - Block validation (merkle root, witness commitment, weight)

import gleam/bit_array
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import oni_bitcoin.{
  type Amount, type Block, type Hash256, type OutPoint, type Script,
  type Transaction, type TxIn, type TxOut,
}
import oni_storage.{type Coin, type UtxoView}
import oni_consensus.{
  type ConsensusError, BlockBadCoinbase, BlockDuplicateTx, BlockInvalidMerkleRoot,
  BlockInvalidWitnessCommitment, BlockWeightExceeded, TxDuplicateInputs,
  TxEmptyInputs, TxEmptyOutputs, TxInputNotFound, TxInvalidAmount,
  TxLockTimeNotMet, TxOutputValueOverflow, TxOversized, TxPrematureCoinbaseSpend,
  TxSequenceLockNotMet,
}

// ============================================================================
// Validation Constants
// ============================================================================

/// Maximum transaction size (legacy, 1MB)
pub const max_tx_size = 1_000_000

/// Maximum transaction weight (4M weight units)
pub const max_tx_weight = 4_000_000

/// Maximum standard transaction size (100KB for relay)
pub const max_standard_tx_size = 100_000

/// Maximum number of signature operations per transaction
pub const max_tx_sigops = 80_000

/// Maximum number of signature operations per block
pub const max_block_sigops = 80_000

/// Maximum block weight (4M weight units)
pub const max_block_weight = 4_000_000

/// Coinbase maturity (100 blocks)
pub const coinbase_maturity = 100

/// Witness scale factor
pub const witness_scale_factor = 4

/// Locktime threshold (if >= this, it's a timestamp, otherwise block height)
pub const locktime_threshold = 500_000_000

/// BIP68 sequence lock time type flag (1 << 22)
pub const sequence_locktime_type_flag = 4_194_304

/// BIP68 sequence lock time mask
pub const sequence_locktime_mask = 0x0000FFFF

/// BIP68 disable flag (1 << 31)
pub const sequence_locktime_disable_flag = 2_147_483_648

/// Witness commitment header (OP_RETURN + 36 bytes)
pub const witness_commitment_header_hex = "6a24aa21a9ed"

// ============================================================================
// Validation Context
// ============================================================================

/// Context for contextual validation
pub type ValidationContext {
  ValidationContext(
    utxos: UtxoView,
    block_height: Int,
    block_time: Int,
    median_time_past: Int,
    flags: ValidationFlags,
  )
}

/// Validation flags for soft fork activation
pub type ValidationFlags {
  ValidationFlags(
    bip16: Bool,     // P2SH
    bip34: Bool,     // Height in coinbase
    bip65: Bool,     // CHECKLOCKTIMEVERIFY
    bip66: Bool,     // Strict DER signatures
    bip68: Bool,     // Relative lock-time
    bip112: Bool,    // CHECKSEQUENCEVERIFY
    bip141: Bool,    // SegWit
    bip143: Bool,    // SegWit sighash
    bip341: Bool,    // Taproot
  )
}

/// Default flags for modern mainnet (all activated)
pub fn default_validation_flags() -> ValidationFlags {
  ValidationFlags(
    bip16: True,
    bip34: True,
    bip65: True,
    bip66: True,
    bip68: True,
    bip112: True,
    bip141: True,
    bip143: True,
    bip341: True,
  )
}

// ============================================================================
// Transaction Validation
// ============================================================================

/// Complete stateless transaction validation
pub fn validate_tx_stateless(tx: Transaction) -> Result(Nil, ConsensusError) {
  // Check non-empty inputs
  use _ <- result.try(case list.is_empty(tx.inputs) {
    True -> Error(TxEmptyInputs)
    False -> Ok(Nil)
  })

  // Check non-empty outputs
  use _ <- result.try(case list.is_empty(tx.outputs) {
    True -> Error(TxEmptyOutputs)
    False -> Ok(Nil)
  })

  // Check for duplicate inputs
  use _ <- result.try(case has_duplicate_inputs(tx) {
    True -> Error(TxDuplicateInputs)
    False -> Ok(Nil)
  })

  // Validate output amounts
  use _ <- result.try(validate_output_amounts(tx.outputs))

  // Check transaction weight
  use _ <- result.try(case calculate_tx_weight(tx) > max_tx_weight {
    True -> Error(TxOversized)
    False -> Ok(Nil)
  })

  Ok(Nil)
}

/// Contextual transaction validation with UTXO view
pub fn validate_tx_contextual(
  tx: Transaction,
  ctx: ValidationContext,
) -> Result(Int, ConsensusError) {
  // Skip coinbase (different rules)
  case is_coinbase(tx) {
    True -> Ok(0)
    False -> do_validate_tx_contextual(tx, ctx)
  }
}

fn do_validate_tx_contextual(
  tx: Transaction,
  ctx: ValidationContext,
) -> Result(Int, ConsensusError) {
  // Check locktime
  use _ <- result.try(validate_locktime(tx, ctx))

  // Check inputs and collect input values
  use input_sum <- result.try(validate_inputs(tx.inputs, ctx))

  // Calculate output sum
  let output_sum = sum_outputs(tx.outputs)

  // Check fee (input_sum >= output_sum)
  use _ <- result.try(case input_sum >= output_sum {
    True -> Ok(Nil)
    False -> Error(TxInvalidAmount)
  })

  // Return fee
  let fee = input_sum - output_sum
  Ok(fee)
}

/// Validate transaction locktime
fn validate_locktime(
  tx: Transaction,
  ctx: ValidationContext,
) -> Result(Nil, ConsensusError) {
  // If locktime is 0 or all inputs are final, skip check
  case tx.lock_time == 0 || all_inputs_final(tx.inputs) {
    True -> Ok(Nil)
    False -> {
      // Determine if locktime is height or time based
      case tx.lock_time >= locktime_threshold {
        True -> {
          // Time-based: compare against median time past
          case tx.lock_time <= ctx.median_time_past {
            True -> Ok(Nil)
            False -> Error(TxLockTimeNotMet)
          }
        }
        False -> {
          // Height-based: compare against block height
          case tx.lock_time <= ctx.block_height {
            True -> Ok(Nil)
            False -> Error(TxLockTimeNotMet)
          }
        }
      }
    }
  }
}

/// Check if all inputs have final sequence
fn all_inputs_final(inputs: List(TxIn)) -> Bool {
  list.all(inputs, fn(input) { input.sequence == oni_bitcoin.sequence_final })
}

/// Validate inputs and return total input value
fn validate_inputs(
  inputs: List(TxIn),
  ctx: ValidationContext,
) -> Result(Int, ConsensusError) {
  list.fold(inputs, Ok(0), fn(acc, input) {
    case acc {
      Error(e) -> Error(e)
      Ok(sum) -> {
        use coin <- result.try(lookup_coin(input.prevout, ctx))
        use _ <- result.try(validate_coin_maturity(coin, ctx))
        use _ <- result.try(validate_sequence_lock(input, coin, ctx))
        let value = oni_bitcoin.amount_to_sats(coin.output.value)
        Ok(sum + value)
      }
    }
  })
}

/// Lookup a coin in the UTXO view
fn lookup_coin(
  outpoint: OutPoint,
  ctx: ValidationContext,
) -> Result(Coin, ConsensusError) {
  case oni_storage.utxo_get(ctx.utxos, outpoint) {
    Some(coin) -> Ok(coin)
    None -> Error(TxInputNotFound)
  }
}

/// Validate coinbase maturity
fn validate_coin_maturity(
  coin: Coin,
  ctx: ValidationContext,
) -> Result(Nil, ConsensusError) {
  case coin.is_coinbase {
    False -> Ok(Nil)
    True -> {
      case ctx.block_height - coin.height >= coinbase_maturity {
        True -> Ok(Nil)
        False -> Error(TxPrematureCoinbaseSpend)
      }
    }
  }
}

/// Validate BIP68 sequence lock
fn validate_sequence_lock(
  input: TxIn,
  coin: Coin,
  ctx: ValidationContext,
) -> Result(Nil, ConsensusError) {
  // Check if sequence lock is disabled
  case int.bitwise_and(input.sequence, sequence_locktime_disable_flag) != 0 {
    True -> Ok(Nil)
    False -> {
      case ctx.flags.bip68 {
        False -> Ok(Nil)
        True -> {
          let masked = int.bitwise_and(input.sequence, sequence_locktime_mask)
          let is_time = int.bitwise_and(input.sequence, sequence_locktime_type_flag) != 0

          case is_time {
            True -> {
              // Time-based lock (512 second granularity)
              let required_time = coin.height * 512 + masked * 512
              case ctx.median_time_past >= required_time {
                True -> Ok(Nil)
                False -> Error(TxSequenceLockNotMet)
              }
            }
            False -> {
              // Height-based lock
              let required_height = coin.height + masked
              case ctx.block_height >= required_height {
                True -> Ok(Nil)
                False -> Error(TxSequenceLockNotMet)
              }
            }
          }
        }
      }
    }
  }
}

// ============================================================================
// Block Validation
// ============================================================================

/// Complete block validation
pub fn validate_block(
  block: Block,
  ctx: ValidationContext,
) -> Result(Nil, ConsensusError) {
  // Validate weight
  use _ <- result.try(validate_block_weight(block))

  // Validate merkle root
  use _ <- result.try(validate_merkle_root(block))

  // Check for duplicate transactions
  use _ <- result.try(validate_no_duplicate_txs(block))

  // Validate coinbase
  use _ <- result.try(validate_coinbase(block, ctx))

  // Validate witness commitment if SegWit
  use _ <- result.try(case ctx.flags.bip141 {
    True -> validate_witness_commitment(block)
    False -> Ok(Nil)
  })

  // Validate all transactions
  use _ <- result.try(validate_block_transactions(block, ctx))

  Ok(Nil)
}

/// Validate block weight
fn validate_block_weight(block: Block) -> Result(Nil, ConsensusError) {
  let weight = calculate_block_weight(block)
  case weight <= max_block_weight {
    True -> Ok(Nil)
    False -> Error(BlockWeightExceeded)
  }
}

/// Calculate block weight
pub fn calculate_block_weight(block: Block) -> Int {
  let base_size = 80 + calculate_tx_list_base_size(block.transactions)
  let witness_size = calculate_tx_list_witness_size(block.transactions)
  base_size * witness_scale_factor + witness_size
}

fn calculate_tx_list_base_size(txs: List(Transaction)) -> Int {
  list.fold(txs, 0, fn(acc, tx) { acc + calculate_tx_base_size(tx) })
}

fn calculate_tx_list_witness_size(txs: List(Transaction)) -> Int {
  list.fold(txs, 0, fn(acc, tx) { acc + calculate_tx_witness_size(tx) })
}

/// Validate merkle root
fn validate_merkle_root(block: Block) -> Result(Nil, ConsensusError) {
  let txids = list.map(block.transactions, compute_txid)
  let computed_root = oni_consensus.compute_merkle_root(txids)
  case computed_root == block.header.merkle_root {
    True -> Ok(Nil)
    False -> Error(BlockInvalidMerkleRoot)
  }
}

/// Check for duplicate transactions
fn validate_no_duplicate_txs(block: Block) -> Result(Nil, ConsensusError) {
  let txids = list.map(block.transactions, compute_txid)
  let unique = list.unique(txids)
  case list.length(txids) == list.length(unique) {
    True -> Ok(Nil)
    False -> Error(BlockDuplicateTx)
  }
}

/// Validate coinbase transaction
fn validate_coinbase(
  block: Block,
  ctx: ValidationContext,
) -> Result(Nil, ConsensusError) {
  case block.transactions {
    [] -> Error(BlockBadCoinbase)
    [first, ..rest] -> {
      // First tx must be coinbase
      use _ <- result.try(case is_coinbase(first) {
        True -> Ok(Nil)
        False -> Error(BlockBadCoinbase)
      })

      // No other tx can be coinbase
      use _ <- result.try(case list.any(rest, is_coinbase) {
        True -> Error(BlockBadCoinbase)
        False -> Ok(Nil)
      })

      // BIP34: height in coinbase
      case ctx.flags.bip34 {
        False -> Ok(Nil)
        True -> validate_coinbase_height(first, ctx.block_height)
      }
    }
  }
}

/// Validate BIP34 coinbase height
fn validate_coinbase_height(
  tx: Transaction,
  expected_height: Int,
) -> Result(Nil, ConsensusError) {
  case tx.inputs {
    [input, ..] -> {
      let script_bytes = oni_bitcoin.script_to_bytes(input.script_sig)
      case parse_coinbase_height(script_bytes) {
        Ok(height) if height == expected_height -> Ok(Nil)
        _ -> Error(BlockBadCoinbase)
      }
    }
    _ -> Error(BlockBadCoinbase)
  }
}

/// Parse height from coinbase script
fn parse_coinbase_height(script: BitArray) -> Result(Int, Nil) {
  case script {
    <<len:8, rest:bits>> if len >= 1 && len <= 4 -> {
      case bit_array.slice(rest, 0, len) {
        Ok(height_bytes) -> decode_little_endian(height_bytes)
        Error(_) -> Error(Nil)
      }
    }
    _ -> Error(Nil)
  }
}

fn decode_little_endian(bytes: BitArray) -> Result(Int, Nil) {
  case bytes {
    <<a:8>> -> Ok(a)
    <<a:8, b:8>> -> Ok(a + b * 256)
    <<a:8, b:8, c:8>> -> Ok(a + b * 256 + c * 65536)
    <<a:8, b:8, c:8, d:8>> -> Ok(a + b * 256 + c * 65536 + d * 16777216)
    _ -> Error(Nil)
  }
}

/// Validate witness commitment
fn validate_witness_commitment(block: Block) -> Result(Nil, ConsensusError) {
  // Get coinbase
  case block.transactions {
    [] -> Ok(Nil)
    [coinbase, ..] -> {
      // Check if any tx has witness
      let has_witness = list.any(block.transactions, oni_bitcoin.transaction_has_witness)
      case has_witness {
        False -> Ok(Nil)
        True -> {
          // Find witness commitment in coinbase outputs
          case find_witness_commitment(coinbase.outputs) {
            None -> Error(BlockInvalidWitnessCommitment)
            Some(commitment) -> {
              // Get witness nonce from coinbase witness
              case get_witness_nonce(coinbase) {
                None -> Error(BlockInvalidWitnessCommitment)
                Some(nonce) -> {
                  // Compute expected commitment
                  let wtxids = compute_wtxid_list(block.transactions)
                  let wtxid_root = oni_consensus.compute_merkle_root(wtxids)
                  let expected = oni_consensus.compute_witness_commitment(wtxid_root, nonce)
                  case commitment == expected {
                    True -> Ok(Nil)
                    False -> Error(BlockInvalidWitnessCommitment)
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}

/// Find witness commitment in outputs
fn find_witness_commitment(outputs: List(TxOut)) -> Option(Hash256) {
  // Search outputs in reverse order (last matching wins)
  let reversed = list.reverse(outputs)
  find_commitment_in_outputs(reversed)
}

fn find_commitment_in_outputs(outputs: List(TxOut)) -> Option(Hash256) {
  case outputs {
    [] -> None
    [output, ..rest] -> {
      let script = oni_bitcoin.script_to_bytes(output.script_pubkey)
      case script {
        // OP_RETURN (0x6a) + push 36 bytes (0x24) + commitment header (aa21a9ed) + 32 byte hash
        <<0x6a:8, 0x24:8, 0xaa:8, 0x21:8, 0xa9:8, 0xed:8, hash:256-bits>> -> {
          Some(oni_bitcoin.Hash256(<<hash:256-bits>>))
        }
        _ -> find_commitment_in_outputs(rest)
      }
    }
  }
}

/// Get witness nonce from coinbase
fn get_witness_nonce(coinbase: Transaction) -> Option(BitArray) {
  case coinbase.inputs {
    [input, ..] -> {
      case input.witness {
        [nonce] if bit_array.byte_size(nonce) == 32 -> Some(nonce)
        _ -> None
      }
    }
    _ -> None
  }
}

/// Compute wtxid list for block
fn compute_wtxid_list(txs: List(Transaction)) -> List(Hash256) {
  case txs {
    [] -> []
    [_coinbase, ..rest] -> {
      // Coinbase wtxid is all zeros
      let null_hash = oni_bitcoin.Hash256(<<0:256>>)
      [null_hash, ..list.map(rest, compute_wtxid)]
    }
  }
}

/// Validate all transactions in block
fn validate_block_transactions(
  block: Block,
  ctx: ValidationContext,
) -> Result(Nil, ConsensusError) {
  case block.transactions {
    [] -> Ok(Nil)
    [_coinbase, ..rest] -> {
      // Validate non-coinbase transactions
      validate_tx_list(rest, ctx)
    }
  }
}

fn validate_tx_list(
  txs: List(Transaction),
  ctx: ValidationContext,
) -> Result(Nil, ConsensusError) {
  case txs {
    [] -> Ok(Nil)
    [tx, ..rest] -> {
      use _ <- result.try(validate_tx_stateless(tx))
      use _ <- result.try(validate_tx_contextual(tx, ctx))
      validate_tx_list(rest, ctx)
    }
  }
}

// ============================================================================
// Sighash Computation
// ============================================================================

/// Sighash types
pub type SighashType {
  SighashAll
  SighashNone
  SighashSingle
  SighashAnyoneCanPay(SighashType)
}

/// Parse sighash type from byte
pub fn sighash_type_from_byte(b: Int) -> SighashType {
  let base = int.bitwise_and(b, 0x1F)
  let anyonecanpay = int.bitwise_and(b, 0x80) != 0

  let base_type = case base {
    0x02 -> SighashNone
    0x03 -> SighashSingle
    _ -> SighashAll
  }

  case anyonecanpay {
    True -> SighashAnyoneCanPay(base_type)
    False -> base_type
  }
}

/// Compute legacy sighash (pre-SegWit)
pub fn sighash_legacy(
  tx: Transaction,
  input_index: Int,
  script_code: Script,
  sighash_type: Int,
) -> Hash256 {
  // Create a copy of the transaction
  let modified_tx = prepare_legacy_sighash_tx(tx, input_index, script_code, sighash_type)

  // Serialize and hash
  let serialized = serialize_tx_legacy(modified_tx)
  let with_type = bit_array.append(serialized, <<sighash_type:32-little>>)
  oni_bitcoin.hash256_digest(with_type)
}

fn prepare_legacy_sighash_tx(
  tx: Transaction,
  input_index: Int,
  script_code: Script,
  sighash_type: Int,
) -> Transaction {
  let base_type = int.bitwise_and(sighash_type, 0x1F)
  let anyonecanpay = int.bitwise_and(sighash_type, 0x80) != 0

  // Modify inputs
  let inputs = case anyonecanpay {
    True -> {
      // Only the signing input
      case list_nth(tx.inputs, input_index) {
        Ok(input) -> [oni_bitcoin.TxIn(..input, script_sig: script_code)]
        Error(_) -> tx.inputs
      }
    }
    False -> {
      // All inputs, but clear scripts except for signing input
      list.index_map(tx.inputs, fn(input, i) {
        case i == input_index {
          True -> oni_bitcoin.TxIn(..input, script_sig: script_code)
          False -> oni_bitcoin.TxIn(..input, script_sig: oni_bitcoin.script_from_bytes(<<>>))
        }
      })
    }
  }

  // Modify outputs based on sighash type
  let outputs = case base_type {
    0x02 -> []  // SIGHASH_NONE: no outputs
    0x03 -> {   // SIGHASH_SINGLE: only matching output
      case list_nth(tx.outputs, input_index) {
        Ok(out) -> {
          // Fill with empty outputs up to input_index
          // Bitcoin uses -1 (0xFFFFFFFFFFFFFFFF) as the value for blank outputs
          let blank_amount = oni_bitcoin.Amount(sats: -1)
          list.range(0, input_index - 1)
          |> list.map(fn(_) {
            oni_bitcoin.TxOut(
              value: blank_amount,
              script_pubkey: oni_bitcoin.script_from_bytes(<<>>),
            )
          })
          |> list.append([out])
        }
        Error(_) -> tx.outputs
      }
    }
    _ -> tx.outputs  // SIGHASH_ALL: all outputs
  }

  // Clear sequences for NONE and SINGLE (except signing input)
  let final_inputs = case base_type == 0x02 || base_type == 0x03 {
    True -> {
      list.index_map(inputs, fn(input, i) {
        case i == input_index {
          True -> input
          False -> oni_bitcoin.TxIn(..input, sequence: 0)
        }
      })
    }
    False -> inputs
  }

  oni_bitcoin.Transaction(
    version: tx.version,
    inputs: final_inputs,
    outputs: outputs,
    lock_time: tx.lock_time,
  )
}

/// Compute BIP143 SegWit v0 sighash
pub fn sighash_segwit_v0(
  tx: Transaction,
  input_index: Int,
  script_code: Script,
  value: Amount,
  sighash_type: Int,
) -> Hash256 {
  let base_type = int.bitwise_and(sighash_type, 0x1F)
  let anyonecanpay = int.bitwise_and(sighash_type, 0x80) != 0

  // Compute prevouts hash
  let hash_prevouts = case anyonecanpay {
    True -> oni_bitcoin.Hash256(<<0:256>>)
    False -> hash_prevouts(tx.inputs)
  }

  // Compute sequence hash
  let hash_sequence = case anyonecanpay || base_type == 0x02 || base_type == 0x03 {
    True -> oni_bitcoin.Hash256(<<0:256>>)
    False -> hash_sequences(tx.inputs)
  }

  // Compute outputs hash
  let hash_outputs = case base_type {
    0x02 -> oni_bitcoin.Hash256(<<0:256>>)  // NONE
    0x03 -> {  // SINGLE
      case list_nth(tx.outputs, input_index) {
        Ok(out) -> oni_bitcoin.hash256_digest(serialize_output(out))
        Error(_) -> oni_bitcoin.Hash256(<<0:256>>)
      }
    }
    _ -> hash_outputs(tx.outputs)  // ALL
  }

  // Get the input
  case list_nth(tx.inputs, input_index) {
    Error(_) -> oni_bitcoin.Hash256(<<0:256>>)
    Ok(input) -> {
      // Build preimage
      let script_bytes = oni_bitcoin.script_to_bytes(script_code)
      let script_len = oni_bitcoin.compact_size_encode(bit_array.byte_size(script_bytes))
      let value_sats = oni_bitcoin.amount_to_sats(value)

      let preimage = bit_array.concat([
        <<tx.version:32-little>>,
        hash_prevouts.bytes,
        hash_sequence.bytes,
        serialize_outpoint(input.prevout),
        script_len,
        script_bytes,
        <<value_sats:64-little>>,
        <<input.sequence:32-little>>,
        hash_outputs.bytes,
        <<tx.lock_time:32-little>>,
        <<sighash_type:32-little>>,
      ])

      oni_bitcoin.hash256_digest(preimage)
    }
  }
}

/// Compute BIP341 Taproot sighash
pub fn sighash_taproot(
  tx: Transaction,
  input_index: Int,
  prevouts: List(TxOut),
  sighash_type: Int,
  ext_flag: Int,
  annex_hash: Option(Hash256),
) -> Hash256 {
  let base_type = int.bitwise_and(sighash_type, 0x1F)
  let anyonecanpay = int.bitwise_and(sighash_type, 0x80) != 0

  // Common signature message
  let epoch = <<0x00:8>>

  // Hash type
  let hash_type_byte = case sighash_type {
    0x00 -> <<0x00:8>>  // Default = ALL
    _ -> <<sighash_type:8>>
  }

  // Build the signature message
  let mut_parts = [
    epoch,
    hash_type_byte,
    <<tx.version:32-little>>,
    <<tx.lock_time:32-little>>,
  ]

  // Add prevouts data if not ANYONECANPAY
  let with_prevouts = case anyonecanpay {
    True -> mut_parts
    False -> {
      list.append(mut_parts, [
        hash_prevouts(tx.inputs).bytes,
        hash_amounts(prevouts).bytes,
        hash_script_pubkeys(prevouts).bytes,
        hash_sequences(tx.inputs).bytes,
      ])
    }
  }

  // Add outputs if not NONE or SINGLE
  let with_outputs = case base_type {
    0x02 | 0x03 -> with_prevouts
    _ -> list.append(with_prevouts, [hash_outputs(list.map(prevouts, fn(_) {
      // Use actual outputs, not prevouts
      oni_bitcoin.TxOut(
        value: oni_bitcoin.Amount(sats: 0),
        script_pubkey: oni_bitcoin.script_from_bytes(<<>>),
      )
    })).bytes])
  }

  // Add spend type
  let spend_type = int.bitwise_or(
    int.bitwise_shift_left(ext_flag, 1),
    case annex_hash {
      Some(_) -> 1
      None -> 0
    },
  )

  let with_spend_type = list.append(with_outputs, [<<spend_type:8>>])

  // Input-specific data
  let final_parts = case anyonecanpay {
    True -> {
      case list_nth(tx.inputs, input_index), list_nth(prevouts, input_index) {
        Ok(input), Ok(prevout) -> {
          list.append(with_spend_type, [
            serialize_outpoint(input.prevout),
            <<oni_bitcoin.amount_to_sats(prevout.value):64-little>>,
            oni_bitcoin.compact_size_encode(bit_array.byte_size(
              oni_bitcoin.script_to_bytes(prevout.script_pubkey),
            )),
            oni_bitcoin.script_to_bytes(prevout.script_pubkey),
            <<input.sequence:32-little>>,
          ])
        }
        _, _ -> with_spend_type
      }
    }
    False -> list.append(with_spend_type, [<<input_index:32-little>>])
  }

  // Add annex hash if present
  let with_annex = case annex_hash {
    Some(hash) -> list.append(final_parts, [hash.bytes])
    None -> final_parts
  }

  // Tagged hash
  let message = bit_array.concat(with_annex)
  oni_bitcoin.Hash256(oni_bitcoin.tagged_hash("TapSighash", message))
}

// ============================================================================
// Helper Functions
// ============================================================================

/// Check if transaction is coinbase
pub fn is_coinbase(tx: Transaction) -> Bool {
  case tx.inputs {
    [input] -> oni_bitcoin.outpoint_is_null(input.prevout)
    _ -> False
  }
}

/// Check for duplicate inputs
fn has_duplicate_inputs(tx: Transaction) -> Bool {
  let outpoints = list.map(tx.inputs, fn(input) {
    oni_bitcoin.txid_to_hex(input.prevout.txid) <> ":" <> int.to_string(input.prevout.vout)
  })
  let unique = list.unique(outpoints)
  list.length(outpoints) != list.length(unique)
}

/// Validate output amounts
fn validate_output_amounts(outputs: List(TxOut)) -> Result(Nil, ConsensusError) {
  list.fold(outputs, Ok(0), fn(acc, output) {
    case acc {
      Error(e) -> Error(e)
      Ok(sum) -> {
        let sats = oni_bitcoin.amount_to_sats(output.value)
        case sats >= 0 && sats <= oni_bitcoin.max_satoshis {
          False -> Error(TxInvalidAmount)
          True -> {
            let new_sum = sum + sats
            case new_sum > oni_bitcoin.max_satoshis {
              True -> Error(TxOutputValueOverflow)
              False -> Ok(new_sum)
            }
          }
        }
      }
    }
  })
  |> result.map(fn(_) { Nil })
}

/// Sum output values
fn sum_outputs(outputs: List(TxOut)) -> Int {
  list.fold(outputs, 0, fn(acc, output) {
    acc + oni_bitcoin.amount_to_sats(output.value)
  })
}

/// Calculate transaction weight
pub fn calculate_tx_weight(tx: Transaction) -> Int {
  let base = calculate_tx_base_size(tx)
  let witness = calculate_tx_witness_size(tx)
  base * witness_scale_factor + witness
}

/// Calculate base size (non-witness)
fn calculate_tx_base_size(tx: Transaction) -> Int {
  // version (4) + input count + inputs + output count + outputs + locktime (4)
  4 + compact_size_len(list.length(tx.inputs))
    + sum_input_sizes(tx.inputs)
    + compact_size_len(list.length(tx.outputs))
    + sum_output_sizes(tx.outputs)
    + 4
}

fn sum_input_sizes(inputs: List(TxIn)) -> Int {
  list.fold(inputs, 0, fn(acc, input) {
    let script_size = bit_array.byte_size(oni_bitcoin.script_to_bytes(input.script_sig))
    // outpoint (36) + script varint + script + sequence (4)
    acc + 36 + compact_size_len(script_size) + script_size + 4
  })
}

fn sum_output_sizes(outputs: List(TxOut)) -> Int {
  list.fold(outputs, 0, fn(acc, output) {
    let script_size = bit_array.byte_size(oni_bitcoin.script_to_bytes(output.script_pubkey))
    // value (8) + script varint + script
    acc + 8 + compact_size_len(script_size) + script_size
  })
}

/// Calculate witness size
fn calculate_tx_witness_size(tx: Transaction) -> Int {
  case oni_bitcoin.transaction_has_witness(tx) {
    False -> 0
    True -> {
      // marker (1) + flag (1) + witness data
      2 + list.fold(tx.inputs, 0, fn(acc, input) {
        acc + compact_size_len(list.length(input.witness))
          + list.fold(input.witness, 0, fn(wacc, item) {
              wacc + compact_size_len(bit_array.byte_size(item)) + bit_array.byte_size(item)
            })
      })
    }
  }
}

fn compact_size_len(n: Int) -> Int {
  case n {
    _ if n < 0xFD -> 1
    _ if n <= 0xFFFF -> 3
    _ if n <= 0xFFFFFFFF -> 5
    _ -> 9
  }
}

/// Compute txid
pub fn compute_txid(tx: Transaction) -> Hash256 {
  let serialized = serialize_tx_legacy(tx)
  oni_bitcoin.hash256_digest(serialized)
}

/// Compute wtxid
pub fn compute_wtxid(tx: Transaction) -> Hash256 {
  case oni_bitcoin.transaction_has_witness(tx) {
    False -> compute_txid(tx)
    True -> {
      let serialized = serialize_tx_witness(tx)
      oni_bitcoin.hash256_digest(serialized)
    }
  }
}

/// Serialize transaction without witness
fn serialize_tx_legacy(tx: Transaction) -> BitArray {
  bit_array.concat([
    <<tx.version:32-little>>,
    oni_bitcoin.compact_size_encode(list.length(tx.inputs)),
    serialize_inputs(tx.inputs),
    oni_bitcoin.compact_size_encode(list.length(tx.outputs)),
    serialize_outputs(tx.outputs),
    <<tx.lock_time:32-little>>,
  ])
}

/// Serialize transaction with witness
fn serialize_tx_witness(tx: Transaction) -> BitArray {
  bit_array.concat([
    <<tx.version:32-little>>,
    <<0x00:8, 0x01:8>>,  // marker + flag
    oni_bitcoin.compact_size_encode(list.length(tx.inputs)),
    serialize_inputs(tx.inputs),
    oni_bitcoin.compact_size_encode(list.length(tx.outputs)),
    serialize_outputs(tx.outputs),
    serialize_witnesses(tx.inputs),
    <<tx.lock_time:32-little>>,
  ])
}

fn serialize_inputs(inputs: List(TxIn)) -> BitArray {
  list.fold(inputs, <<>>, fn(acc, input) {
    bit_array.append(acc, serialize_input(input))
  })
}

fn serialize_input(input: TxIn) -> BitArray {
  let script = oni_bitcoin.script_to_bytes(input.script_sig)
  bit_array.concat([
    serialize_outpoint(input.prevout),
    oni_bitcoin.compact_size_encode(bit_array.byte_size(script)),
    script,
    <<input.sequence:32-little>>,
  ])
}

fn serialize_outpoint(outpoint: OutPoint) -> BitArray {
  bit_array.concat([
    outpoint.txid.hash.bytes,
    <<outpoint.vout:32-little>>,
  ])
}

fn serialize_outputs(outputs: List(TxOut)) -> BitArray {
  list.fold(outputs, <<>>, fn(acc, output) {
    bit_array.append(acc, serialize_output(output))
  })
}

fn serialize_output(output: TxOut) -> BitArray {
  let script = oni_bitcoin.script_to_bytes(output.script_pubkey)
  bit_array.concat([
    <<oni_bitcoin.amount_to_sats(output.value):64-little>>,
    oni_bitcoin.compact_size_encode(bit_array.byte_size(script)),
    script,
  ])
}

fn serialize_witnesses(inputs: List(TxIn)) -> BitArray {
  list.fold(inputs, <<>>, fn(acc, input) {
    let witness_data = bit_array.concat([
      oni_bitcoin.compact_size_encode(list.length(input.witness)),
      ..list.map(input.witness, fn(item) {
        bit_array.concat([
          oni_bitcoin.compact_size_encode(bit_array.byte_size(item)),
          item,
        ])
      })
    ])
    bit_array.append(acc, witness_data)
  })
}

/// Hash all prevouts
fn hash_prevouts(inputs: List(TxIn)) -> Hash256 {
  let data = list.fold(inputs, <<>>, fn(acc, input) {
    bit_array.append(acc, serialize_outpoint(input.prevout))
  })
  oni_bitcoin.hash256_digest(data)
}

/// Hash all sequences
fn hash_sequences(inputs: List(TxIn)) -> Hash256 {
  let data = list.fold(inputs, <<>>, fn(acc, input) {
    bit_array.append(acc, <<input.sequence:32-little>>)
  })
  oni_bitcoin.hash256_digest(data)
}

/// Hash all outputs
fn hash_outputs(outputs: List(TxOut)) -> Hash256 {
  let data = serialize_outputs(outputs)
  oni_bitcoin.hash256_digest(data)
}

/// Hash all amounts (for Taproot)
fn hash_amounts(outputs: List(TxOut)) -> Hash256 {
  let data = list.fold(outputs, <<>>, fn(acc, output) {
    bit_array.append(acc, <<oni_bitcoin.amount_to_sats(output.value):64-little>>)
  })
  oni_bitcoin.hash256_digest(data)
}

/// Hash all script pubkeys (for Taproot)
fn hash_script_pubkeys(outputs: List(TxOut)) -> Hash256 {
  let data = list.fold(outputs, <<>>, fn(acc, output) {
    let script = oni_bitcoin.script_to_bytes(output.script_pubkey)
    bit_array.concat([
      acc,
      oni_bitcoin.compact_size_encode(bit_array.byte_size(script)),
      script,
    ])
  })
  oni_bitcoin.hash256_digest(data)
}

/// List nth helper
fn list_nth(lst: List(a), n: Int) -> Result(a, Nil) {
  case lst, n {
    [], _ -> Error(Nil)
    [head, ..], 0 -> Ok(head)
    [_, ..tail], _ -> list_nth(tail, n - 1)
  }
}
