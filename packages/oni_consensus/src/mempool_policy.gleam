// mempool_policy.gleam - Transaction mempool policy enforcement
//
// This module implements Bitcoin Core-compatible mempool policy rules.
// Policy rules are stricter than consensus rules and help protect
// the network from spam and DoS attacks.
//
// Policy checks include:
// - Transaction size limits
// - Script standardness
// - Dust output detection
// - Fee rate validation
// - Input validation
// - Output validation
//
// Note: Policy is separate from consensus. A transaction can be valid
// by consensus but rejected by policy.

import gleam/bit_array
import gleam/int
import gleam/list
import gleam/result
import oni_bitcoin.{
  type OutPoint, type Transaction, type TxIn, type TxOut,
}

// ============================================================================
// Constants
// ============================================================================

/// Maximum standard transaction weight (400,000 WU = 100kB equivalent)
pub const max_standard_tx_weight = 400_000

/// Maximum number of sigops in a standard transaction
pub const max_standard_tx_sigops = 16_000

/// Maximum size of a standard scriptSig
pub const max_standard_scriptsig_size = 1650

/// Maximum size of a standard output script
pub const max_standard_scriptpubkey_size = 10_000

/// Minimum relay fee in satoshis per virtual byte
pub const min_relay_fee_sat_per_vbyte = 1

/// Dust threshold for P2PKH outputs (in satoshis)
/// This is the minimum value where it's economical to spend the output
pub const dust_threshold_p2pkh = 546

/// Dust threshold for P2WPKH outputs (lower due to cheaper spend)
pub const dust_threshold_p2wpkh = 294

/// Dust threshold for P2SH outputs
pub const dust_threshold_p2sh = 540

/// Maximum number of ancestors in mempool
pub const max_ancestor_count = 25

/// Maximum total size of ancestors
pub const max_ancestor_size = 101_000

/// Maximum number of descendants in mempool
pub const max_descendant_count = 25

/// Maximum total size of descendants
pub const max_descendant_size = 101_000

// ============================================================================
// Policy Error Types
// ============================================================================

/// Policy rejection reasons
pub type PolicyError {
  /// Transaction too large
  TxTooLarge(weight: Int)
  /// Too many sigops
  TooManySigops(count: Int)
  /// Non-standard transaction version
  NonStandardVersion(version: Int)
  /// Non-standard input script
  NonStandardInput(input_index: Int, reason: String)
  /// Non-standard output script
  NonStandardOutput(output_index: Int, reason: String)
  /// Output below dust threshold
  DustOutput(output_index: Int, value: Int, threshold: Int)
  /// Fee below minimum
  InsufficientFee(fee: Int, required: Int)
  /// Invalid fee (negative or overflow)
  InvalidFee
  /// Duplicate input
  DuplicateInput(outpoint: OutPoint)
  /// Empty inputs
  EmptyInputs
  /// Empty outputs
  EmptyOutputs
  /// Script too large
  ScriptTooLarge(size: Int)
  /// Too many ancestors in mempool
  TooManyAncestors
  /// Too many descendants in mempool
  TooManyDescendants
  /// Multi-OP_RETURN outputs
  MultipleOpReturn
  /// Bare multisig not allowed
  BareMultisig
  /// Invalid witness
  InvalidWitness(reason: String)
}

/// Convert policy error to string
pub fn error_to_string(err: PolicyError) -> String {
  case err {
    TxTooLarge(weight) ->
      "Transaction weight " <> int.to_string(weight) <> " exceeds limit"
    TooManySigops(count) ->
      "Too many sigops: " <> int.to_string(count)
    NonStandardVersion(version) ->
      "Non-standard version: " <> int.to_string(version)
    NonStandardInput(idx, reason) ->
      "Non-standard input " <> int.to_string(idx) <> ": " <> reason
    NonStandardOutput(idx, reason) ->
      "Non-standard output " <> int.to_string(idx) <> ": " <> reason
    DustOutput(idx, value, threshold) ->
      "Dust output " <> int.to_string(idx) <> ": " <>
      int.to_string(value) <> " < " <> int.to_string(threshold)
    InsufficientFee(fee, required) ->
      "Insufficient fee: " <> int.to_string(fee) <>
      " < required " <> int.to_string(required)
    InvalidFee -> "Invalid fee calculation"
    DuplicateInput(_) -> "Duplicate input"
    EmptyInputs -> "Transaction has no inputs"
    EmptyOutputs -> "Transaction has no outputs"
    ScriptTooLarge(size) ->
      "Script too large: " <> int.to_string(size) <> " bytes"
    TooManyAncestors -> "Too many unconfirmed ancestors"
    TooManyDescendants -> "Too many unconfirmed descendants"
    MultipleOpReturn -> "Only one OP_RETURN output allowed"
    BareMultisig -> "Bare multisig not accepted"
    InvalidWitness(reason) -> "Invalid witness: " <> reason
  }
}

// ============================================================================
// Policy Configuration
// ============================================================================

/// Policy configuration options
pub type PolicyConfig {
  PolicyConfig(
    /// Minimum relay fee in satoshis per virtual byte
    min_relay_fee_sat_vbyte: Int,
    /// Allow bare multisig outputs
    permit_bare_multisig: Bool,
    /// Maximum data carrier size for OP_RETURN
    max_data_carrier_size: Int,
    /// Accept non-standard transactions
    accept_non_standard: Bool,
    /// Dust relay fee (sat/vB) for dust calculation
    dust_relay_fee_sat_vbyte: Int,
  )
}

/// Default policy configuration (Bitcoin Core defaults)
pub fn default_policy_config() -> PolicyConfig {
  PolicyConfig(
    min_relay_fee_sat_vbyte: 1,
    permit_bare_multisig: False,
    max_data_carrier_size: 83,  // OP_RETURN data limit
    accept_non_standard: False,
    dust_relay_fee_sat_vbyte: 3,  // Used for dust threshold calculation
  )
}

// ============================================================================
// Main Policy Checks
// ============================================================================

/// Check a transaction against policy rules
pub fn check_transaction(
  tx: Transaction,
  config: PolicyConfig,
) -> Result(Nil, PolicyError) {
  // Check basic structure
  use _ <- result.try(check_not_empty(tx))

  // Check version
  use _ <- result.try(check_version(tx, config))

  // Check weight
  use _ <- result.try(check_weight(tx))

  // Check for duplicate inputs
  use _ <- result.try(check_duplicate_inputs(tx))

  // Check inputs are standard
  use _ <- result.try(check_inputs_standard(tx, config))

  // Check outputs are standard
  use _ <- result.try(check_outputs_standard(tx, config))

  // Check for dust outputs
  use _ <- result.try(check_dust_outputs(tx, config))

  // Check OP_RETURN policy
  use _ <- result.try(check_op_return_policy(tx, config))

  Ok(Nil)
}

/// Check transaction with fee validation
pub fn check_transaction_with_fee(
  tx: Transaction,
  input_value: Int,
  config: PolicyConfig,
) -> Result(Nil, PolicyError) {
  // Run basic policy checks
  use _ <- result.try(check_transaction(tx, config))

  // Calculate fee
  let output_value = calculate_output_value(tx)

  case input_value < output_value {
    True -> Error(InvalidFee)
    False -> {
      let fee = input_value - output_value
      let vsize = calculate_vsize(tx)
      let required_fee = vsize * config.min_relay_fee_sat_vbyte

      case fee < required_fee {
        True -> Error(InsufficientFee(fee, required_fee))
        False -> Ok(Nil)
      }
    }
  }
}

// ============================================================================
// Individual Policy Checks
// ============================================================================

/// Check transaction is not empty
fn check_not_empty(tx: Transaction) -> Result(Nil, PolicyError) {
  case list.is_empty(tx.inputs) {
    True -> Error(EmptyInputs)
    False -> {
      case list.is_empty(tx.outputs) {
        True -> Error(EmptyOutputs)
        False -> Ok(Nil)
      }
    }
  }
}

/// Check transaction version is standard
fn check_version(tx: Transaction, config: PolicyConfig) -> Result(Nil, PolicyError) {
  case config.accept_non_standard {
    True -> Ok(Nil)
    False -> {
      // Standard versions are 1 and 2
      case tx.version >= 1 && tx.version <= 2 {
        True -> Ok(Nil)
        False -> Error(NonStandardVersion(tx.version))
      }
    }
  }
}

/// Check transaction weight is within limits
fn check_weight(tx: Transaction) -> Result(Nil, PolicyError) {
  let weight = calculate_weight(tx)
  case weight > max_standard_tx_weight {
    True -> Error(TxTooLarge(weight))
    False -> Ok(Nil)
  }
}

/// Check for duplicate inputs
fn check_duplicate_inputs(tx: Transaction) -> Result(Nil, PolicyError) {
  check_duplicate_inputs_acc(tx.inputs, [])
}

fn check_duplicate_inputs_acc(
  inputs: List(TxIn),
  seen: List(OutPoint),
) -> Result(Nil, PolicyError) {
  case inputs {
    [] -> Ok(Nil)
    [input, ..rest] -> {
      case list.any(seen, fn(op) { outpoint_equal(op, input.prevout) }) {
        True -> Error(DuplicateInput(input.prevout))
        False ->
          check_duplicate_inputs_acc(rest, [input.prevout, ..seen])
      }
    }
  }
}

fn outpoint_equal(a: OutPoint, b: OutPoint) -> Bool {
  oni_bitcoin.txid_to_hex(a.txid) == oni_bitcoin.txid_to_hex(b.txid) &&
    a.vout == b.vout
}

/// Check all inputs are standard
fn check_inputs_standard(
  tx: Transaction,
  config: PolicyConfig,
) -> Result(Nil, PolicyError) {
  case config.accept_non_standard {
    True -> Ok(Nil)
    False -> check_inputs_standard_acc(tx.inputs, 0)
  }
}

fn check_inputs_standard_acc(
  inputs: List(TxIn),
  idx: Int,
) -> Result(Nil, PolicyError) {
  case inputs {
    [] -> Ok(Nil)
    [input, ..rest] -> {
      case is_input_standard(input) {
        Error(reason) -> Error(NonStandardInput(idx, reason))
        Ok(_) -> check_inputs_standard_acc(rest, idx + 1)
      }
    }
  }
}

/// Check if an input is standard
fn is_input_standard(input: TxIn) -> Result(Nil, String) {
  let script_bytes = input.script_sig.bytes
  let script_sig_size = bit_array.byte_size(script_bytes)

  // Check scriptSig size
  case script_sig_size > max_standard_scriptsig_size {
    True -> Error("scriptSig too large")
    False -> {
      // Check scriptSig is push-only for standard transactions
      case is_push_only(script_bytes) {
        False -> Error("scriptSig is not push-only")
        True -> Ok(Nil)
      }
    }
  }
}

/// Check if a script contains only push operations
fn is_push_only(script: BitArray) -> Bool {
  check_push_only_acc(script)
}

fn check_push_only_acc(script: BitArray) -> Bool {
  case bit_array.byte_size(script) {
    0 -> True
    _ -> {
      case script {
        <<opcode:8, rest:bits>> -> {
          case opcode {
            // OP_0 through OP_16 and direct pushes are push operations
            op if op <= 0x60 -> {
              case get_push_size(opcode, rest) {
                Error(_) -> False
                Ok(#(_data, remaining)) -> check_push_only_acc(remaining)
              }
            }
            // OP_1NEGATE
            0x4F -> check_push_only_acc(rest)
            // OP_RESERVED is not a push
            0x50 -> False
            // OP_1 through OP_16
            op if op >= 0x51 && op <= 0x60 -> check_push_only_acc(rest)
            _ -> False
          }
        }
        _ -> True
      }
    }
  }
}

/// Get push size for direct push opcodes
fn get_push_size(
  opcode: Int,
  data: BitArray,
) -> Result(#(BitArray, BitArray), Nil) {
  case opcode {
    // OP_0 - push empty
    0x00 -> Ok(#(<<>>, data))
    // Direct push 1-75 bytes
    n if n >= 0x01 && n <= 0x4B -> {
      case bit_array.byte_size(data) >= n {
        False -> Error(Nil)
        True -> {
          let push_data = bit_array.slice(data, 0, n)
          let remaining = bit_array.slice(data, n, bit_array.byte_size(data) - n)
          case push_data, remaining {
            Ok(pd), Ok(rem) -> Ok(#(pd, rem))
            _, _ -> Error(Nil)
          }
        }
      }
    }
    // OP_PUSHDATA1
    0x4C -> {
      case data {
        <<size:8, rest:bits>> -> {
          case bit_array.byte_size(rest) >= size {
            False -> Error(Nil)
            True -> {
              let push_data = bit_array.slice(rest, 0, size)
              let remaining = bit_array.slice(rest, size, bit_array.byte_size(rest) - size)
              case push_data, remaining {
                Ok(pd), Ok(rem) -> Ok(#(pd, rem))
                _, _ -> Error(Nil)
              }
            }
          }
        }
        _ -> Error(Nil)
      }
    }
    // OP_PUSHDATA2
    0x4D -> {
      case data {
        <<size:16-little, rest:bits>> -> {
          case bit_array.byte_size(rest) >= size {
            False -> Error(Nil)
            True -> {
              let push_data = bit_array.slice(rest, 0, size)
              let remaining = bit_array.slice(rest, size, bit_array.byte_size(rest) - size)
              case push_data, remaining {
                Ok(pd), Ok(rem) -> Ok(#(pd, rem))
                _, _ -> Error(Nil)
              }
            }
          }
        }
        _ -> Error(Nil)
      }
    }
    // OP_PUSHDATA4
    0x4E -> {
      case data {
        <<size:32-little, rest:bits>> -> {
          case bit_array.byte_size(rest) >= size {
            False -> Error(Nil)
            True -> {
              let push_data = bit_array.slice(rest, 0, size)
              let remaining = bit_array.slice(rest, size, bit_array.byte_size(rest) - size)
              case push_data, remaining {
                Ok(pd), Ok(rem) -> Ok(#(pd, rem))
                _, _ -> Error(Nil)
              }
            }
          }
        }
        _ -> Error(Nil)
      }
    }
    _ -> Error(Nil)
  }
}

/// Check all outputs are standard
fn check_outputs_standard(
  tx: Transaction,
  config: PolicyConfig,
) -> Result(Nil, PolicyError) {
  case config.accept_non_standard {
    True -> Ok(Nil)
    False -> check_outputs_standard_acc(tx.outputs, 0, config)
  }
}

fn check_outputs_standard_acc(
  outputs: List(TxOut),
  idx: Int,
  config: PolicyConfig,
) -> Result(Nil, PolicyError) {
  case outputs {
    [] -> Ok(Nil)
    [output, ..rest] -> {
      case is_output_standard(output, config) {
        Error(reason) -> Error(NonStandardOutput(idx, reason))
        Ok(_) -> check_outputs_standard_acc(rest, idx + 1, config)
      }
    }
  }
}

/// Check if an output is standard
fn is_output_standard(output: TxOut, config: PolicyConfig) -> Result(Nil, String) {
  let script_bytes = output.script_pubkey.bytes
  let script_size = bit_array.byte_size(script_bytes)

  // Check script size
  case script_size > max_standard_scriptpubkey_size {
    True -> Error("scriptPubKey too large")
    False -> {
      // Classify the output type
      case classify_output_type(script_bytes) {
        OutputP2PKH -> Ok(Nil)
        OutputP2SH -> Ok(Nil)
        OutputP2WPKH -> Ok(Nil)
        OutputP2WSH -> Ok(Nil)
        OutputP2TR -> Ok(Nil)
        OutputOpReturn -> Ok(Nil)  // OP_RETURN is standard but has count limits
        OutputBareMultisig -> {
          case config.permit_bare_multisig {
            True -> Ok(Nil)
            False -> Error("Bare multisig not permitted")
          }
        }
        OutputNonStandard -> Error("Non-standard script")
        OutputWitnessUnknown -> Ok(Nil)  // Future witness versions are standard
      }
    }
  }
}

/// Output script types
pub type OutputType {
  OutputP2PKH
  OutputP2SH
  OutputP2WPKH
  OutputP2WSH
  OutputP2TR
  OutputOpReturn
  OutputBareMultisig
  OutputWitnessUnknown
  OutputNonStandard
}

/// Classify output script type
pub fn classify_output_type(script: BitArray) -> OutputType {
  case script {
    // P2PKH: OP_DUP OP_HASH160 <20 bytes> OP_EQUALVERIFY OP_CHECKSIG
    <<0x76, 0xA9, 0x14, _hash:160-bits, 0x88, 0xAC>> -> OutputP2PKH

    // P2SH: OP_HASH160 <20 bytes> OP_EQUAL
    <<0xA9, 0x14, _hash:160-bits, 0x87>> -> OutputP2SH

    // P2WPKH: OP_0 <20 bytes>
    <<0x00, 0x14, _hash:160-bits>> -> OutputP2WPKH

    // P2WSH: OP_0 <32 bytes>
    <<0x00, 0x20, _hash:256-bits>> -> OutputP2WSH

    // P2TR: OP_1 <32 bytes>
    <<0x51, 0x20, _hash:256-bits>> -> OutputP2TR

    // OP_RETURN data carrier
    <<0x6A, _rest:bits>> -> OutputOpReturn

    // Future witness versions (OP_2 through OP_16 + push)
    <<version:8, size:8, _data:bits>> if version >= 0x52 && version <= 0x60 && size >= 2 && size <= 40 ->
      OutputWitnessUnknown

    // Check for bare multisig pattern (simplified)
    _ -> {
      case is_bare_multisig(script) {
        True -> OutputBareMultisig
        False -> OutputNonStandard
      }
    }
  }
}

/// Check if script is bare multisig
fn is_bare_multisig(script: BitArray) -> Bool {
  // Simplified check: starts with OP_1-OP_16 and ends with OP_CHECKMULTISIG
  case script {
    <<first:8, _middle:bits>> if first >= 0x51 && first <= 0x60 -> {
      let size = bit_array.byte_size(script)
      case bit_array.slice(script, size - 1, 1) {
        Ok(<<0xAE>>) -> True  // OP_CHECKMULTISIG
        _ -> False
      }
    }
    _ -> False
  }
}

/// Check for dust outputs
fn check_dust_outputs(
  tx: Transaction,
  config: PolicyConfig,
) -> Result(Nil, PolicyError) {
  check_dust_outputs_acc(tx.outputs, 0, config)
}

fn check_dust_outputs_acc(
  outputs: List(TxOut),
  idx: Int,
  config: PolicyConfig,
) -> Result(Nil, PolicyError) {
  case outputs {
    [] -> Ok(Nil)
    [output, ..rest] -> {
      let script_bytes = output.script_pubkey.bytes
      let output_type = classify_output_type(script_bytes)
      let value_sats = output.value.sats

      // OP_RETURN outputs are exempt from dust check
      case output_type {
        OutputOpReturn -> check_dust_outputs_acc(rest, idx + 1, config)
        _ -> {
          let threshold = get_dust_threshold(output_type, config)
          case value_sats < threshold {
            True -> Error(DustOutput(idx, value_sats, threshold))
            False -> check_dust_outputs_acc(rest, idx + 1, config)
          }
        }
      }
    }
  }
}

/// Get dust threshold for output type
fn get_dust_threshold(output_type: OutputType, config: PolicyConfig) -> Int {
  // Calculate based on the size needed to spend the output
  // Dust = (input_size + 32 + 4 + 1 + 107 + 4) * dust_relay_fee / 1000
  // Where 107 is the typical P2PKH scriptSig size
  let base_spend_size = case output_type {
    OutputP2PKH -> 148  // 32+4+1+107+4
    OutputP2SH -> 91    // Depends on redeemScript, use typical
    OutputP2WPKH -> 68  // Witness discount
    OutputP2WSH -> 104  // Larger witness
    OutputP2TR -> 58    // Schnorr signature is smaller
    _ -> 148  // Default to P2PKH size
  }

  // Dust threshold = size * 3 (default dustRelayFee)
  base_spend_size * config.dust_relay_fee_sat_vbyte
}

/// Check OP_RETURN policy (only one allowed)
fn check_op_return_policy(
  tx: Transaction,
  _config: PolicyConfig,
) -> Result(Nil, PolicyError) {
  let op_return_count = list.fold(tx.outputs, 0, fn(count, output) {
    case classify_output_type(output.script_pubkey.bytes) {
      OutputOpReturn -> count + 1
      _ -> count
    }
  })

  case op_return_count > 1 {
    True -> Error(MultipleOpReturn)
    False -> Ok(Nil)
  }
}

// ============================================================================
// Fee and Size Calculations
// ============================================================================

/// Calculate transaction weight
pub fn calculate_weight(tx: Transaction) -> Int {
  // Weight = base_size * 3 + total_size
  // For non-segwit: weight = size * 4
  let base_size = calculate_base_size(tx)
  let witness_size = calculate_witness_size(tx)

  case witness_size > 0 {
    True -> base_size * 3 + base_size + witness_size + 2  // +2 for marker and flag
    False -> base_size * 4
  }
}

/// Calculate virtual size (vbytes)
pub fn calculate_vsize(tx: Transaction) -> Int {
  let weight = calculate_weight(tx)
  // Round up: (weight + 3) / 4
  { weight + 3 } / 4
}

/// Calculate base transaction size (without witness)
fn calculate_base_size(tx: Transaction) -> Int {
  // Version (4) + input count (varint) + inputs + output count (varint) + outputs + locktime (4)
  let input_size = list.fold(tx.inputs, 0, fn(acc, input) {
    let script_size = bit_array.byte_size(input.script_sig.bytes)
    // Previous outpoint (36) + script length (varint) + script + sequence (4)
    acc + 36 + varint_size(script_size) + script_size + 4
  })

  let output_size = list.fold(tx.outputs, 0, fn(acc, output) {
    let script_size = bit_array.byte_size(output.script_pubkey.bytes)
    // Value (8) + script length (varint) + script
    acc + 8 + varint_size(script_size) + script_size
  })

  4 + varint_size(list.length(tx.inputs)) + input_size +
    varint_size(list.length(tx.outputs)) + output_size + 4
}

/// Calculate witness data size
fn calculate_witness_size(tx: Transaction) -> Int {
  list.fold(tx.inputs, 0, fn(acc, input) {
    case input.witness {
      [] -> acc
      witness_stack -> {
        let stack_size = list.fold(witness_stack, 0, fn(wacc, item) {
          wacc + varint_size(bit_array.byte_size(item)) + bit_array.byte_size(item)
        })
        acc + varint_size(list.length(witness_stack)) + stack_size
      }
    }
  })
}

/// Calculate varint encoding size
fn varint_size(n: Int) -> Int {
  case n {
    _ if n < 0xFD -> 1
    _ if n <= 0xFFFF -> 3
    _ if n <= 0xFFFFFFFF -> 5
    _ -> 9
  }
}

/// Calculate total output value
fn calculate_output_value(tx: Transaction) -> Int {
  list.fold(tx.outputs, 0, fn(acc, output) { acc + output.value.sats })
}
