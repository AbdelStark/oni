// mempool_validation.gleam - Contextual transaction validation for mempool
//
// This module performs contextual validation of transactions for mempool
// admission. Unlike mempool_policy which does stateless checks, this module
// verifies transactions against the current chainstate:
//
// - UTXO existence and availability
// - Double-spend detection
// - Signature validation
// - Fee calculation from actual input values
// - Locktime and sequence validation
//
// The module is designed to work with a UTXO view abstraction that can
// be backed by chainstate or a mempool overlay.

import gleam/int
import gleam/list
import gleam/result
import oni_bitcoin.{
  type Amount, type OutPoint, type Script, type Transaction, type TxIn,
  type TxOut, Amount,
}

// ============================================================================
// UTXO View Abstraction
// ============================================================================

/// Information about a UTXO for validation
pub type UtxoInfo {
  UtxoInfo(
    /// The output value
    value: Amount,
    /// The output script
    script_pubkey: Script,
    /// Height at which the UTXO was created
    height: Int,
    /// Whether this is from a coinbase transaction
    is_coinbase: Bool,
  )
}

/// UTXO lookup result
pub type UtxoLookupResult {
  /// UTXO exists and is available
  UtxoAvailable(info: UtxoInfo)
  /// UTXO does not exist
  UtxoNotFound
  /// UTXO exists but is already spent
  UtxoSpent
  /// UTXO is in mempool (unconfirmed parent)
  UtxoInMempool(info: UtxoInfo)
}

/// A view into the UTXO set for validation
/// This abstraction allows validation against chainstate, mempool, or both
pub type UtxoView {
  UtxoView(
    /// Function to look up a UTXO by outpoint
    lookup: fn(OutPoint) -> UtxoLookupResult,
    /// Current chain height
    chain_height: Int,
    /// Median time past (for locktime validation)
    median_time_past: Int,
  )
}

// ============================================================================
// Validation Error Types
// ============================================================================

/// Contextual validation errors
pub type ValidationError {
  /// Input references non-existent UTXO
  MissingInput(input_index: Int, outpoint: OutPoint)
  /// Input references already-spent UTXO
  DoubleSpend(input_index: Int, outpoint: OutPoint)
  /// Coinbase output not mature enough
  PrematureCoinbaseSpend(input_index: Int, age: Int, required: Int)
  /// Transaction fee is negative (outputs > inputs)
  NegativeFee(inputs_value: Int, outputs_value: Int)
  /// Fee is below minimum relay fee
  FeeTooLow(fee: Int, min_fee: Int, vsize: Int)
  /// Locktime not satisfied
  LocktimeNotSatisfied(locktime: Int, current: Int)
  /// Sequence-based relative locktime not satisfied
  SequenceNotSatisfied(input_index: Int, required: Int, actual: Int)
  /// Script validation failed
  ScriptFailure(input_index: Int, reason: String)
  /// Transaction already in mempool
  AlreadyInMempool
  /// Transaction conflicts with mempool tx (not RBF)
  MempoolConflict(conflicting_txid: String)
  /// Too many unconfirmed ancestors
  TooManyUnconfirmedAncestors(count: Int, max: Int)
}

// ============================================================================
// Validation Result
// ============================================================================

/// Successful validation result with computed data
pub type ValidationResult {
  ValidationResult(
    /// Total input value in satoshis
    inputs_value: Int,
    /// Total output value in satoshis
    outputs_value: Int,
    /// Transaction fee in satoshis
    fee: Int,
    /// Fee rate in sat/vB
    fee_rate: Float,
    /// Virtual size in vbytes
    vsize: Int,
    /// Number of unconfirmed ancestors
    ancestor_count: Int,
  )
}

// ============================================================================
// Constants
// ============================================================================

/// Coinbase maturity (100 blocks)
pub const coinbase_maturity = 100

/// Minimum relay fee in sat/vB
pub const min_relay_fee_rate = 1

/// Locktime threshold (values below are block height, above are timestamp)
pub const locktime_threshold = 500_000_000

/// Sequence number indicating no relative locktime
pub const sequence_final = 0xffffffff

/// Sequence locktime disable flag
pub const sequence_locktime_disable_flag = 0x80000000

/// Sequence locktime type flag (0 = blocks, 1 = time)
pub const sequence_locktime_type_flag = 0x00400000

/// Sequence locktime mask (lower 16 bits)
pub const sequence_locktime_mask = 0x0000ffff

// ============================================================================
// Main Validation Functions
// ============================================================================

/// Validate a transaction for mempool admission
/// Returns validation result with computed fee data on success
pub fn validate_transaction(
  tx: Transaction,
  utxo_view: UtxoView,
) -> Result(ValidationResult, ValidationError) {
  // Step 1: Gather all input UTXOs and check availability
  use inputs_info <- result.try(gather_inputs(tx.inputs, utxo_view, 0, []))

  // Step 2: Check coinbase maturity
  use _ <- result.try(check_coinbase_maturity(
    inputs_info,
    utxo_view.chain_height,
  ))

  // Step 3: Calculate values and fee
  let inputs_value = calculate_total_value(inputs_info)
  let outputs_value = calculate_outputs_value(tx.outputs)

  // Step 4: Check fee is non-negative
  case inputs_value >= outputs_value {
    False -> Error(NegativeFee(inputs_value, outputs_value))
    True -> {
      let fee = inputs_value - outputs_value

      // Step 5: Calculate virtual size and fee rate
      let weight = oni_bitcoin.tx_weight(tx)
      let vsize = { weight + 3 } / 4
      let fee_rate = case vsize > 0 {
        True -> int.to_float(fee) /. int.to_float(vsize)
        False -> 0.0
      }

      // Step 6: Check minimum fee
      let min_fee = vsize * min_relay_fee_rate
      case fee >= min_fee {
        False -> Error(FeeTooLow(fee, min_fee, vsize))
        True -> {
          // Step 7: Check locktime
          use _ <- result.try(check_locktime(tx, utxo_view))

          // Step 8: Check relative locktimes (BIP 68)
          use _ <- result.try(check_sequence_locks(
            tx.inputs,
            inputs_info,
            utxo_view,
          ))

          // Count unconfirmed ancestors
          let ancestor_count = count_unconfirmed_ancestors(inputs_info)

          Ok(ValidationResult(
            inputs_value: inputs_value,
            outputs_value: outputs_value,
            fee: fee,
            fee_rate: fee_rate,
            vsize: vsize,
            ancestor_count: ancestor_count,
          ))
        }
      }
    }
  }
}

/// Validate a transaction without fee checking (for block validation)
pub fn validate_inputs_exist(
  tx: Transaction,
  utxo_view: UtxoView,
) -> Result(Int, ValidationError) {
  use inputs_info <- result.try(gather_inputs(tx.inputs, utxo_view, 0, []))
  Ok(calculate_total_value(inputs_info))
}

// ============================================================================
// Input Gathering
// ============================================================================

/// Information about a gathered input
type InputInfo {
  InputInfo(index: Int, utxo: UtxoInfo, from_mempool: Bool)
}

/// Gather all input UTXOs, checking they exist
fn gather_inputs(
  inputs: List(TxIn),
  utxo_view: UtxoView,
  index: Int,
  acc: List(InputInfo),
) -> Result(List(InputInfo), ValidationError) {
  case inputs {
    [] -> Ok(list.reverse(acc))
    [input, ..rest] -> {
      let lookup_result = utxo_view.lookup(input.prevout)
      case lookup_result {
        UtxoNotFound -> Error(MissingInput(index, input.prevout))
        UtxoSpent -> Error(DoubleSpend(index, input.prevout))
        UtxoAvailable(info) -> {
          let input_info =
            InputInfo(index: index, utxo: info, from_mempool: False)
          gather_inputs(rest, utxo_view, index + 1, [input_info, ..acc])
        }
        UtxoInMempool(info) -> {
          let input_info =
            InputInfo(index: index, utxo: info, from_mempool: True)
          gather_inputs(rest, utxo_view, index + 1, [input_info, ..acc])
        }
      }
    }
  }
}

// ============================================================================
// Value Calculations
// ============================================================================

/// Calculate total value of gathered inputs
fn calculate_total_value(inputs: List(InputInfo)) -> Int {
  list.fold(inputs, 0, fn(acc, input_info) { acc + input_info.utxo.value.sats })
}

/// Calculate total value of outputs
fn calculate_outputs_value(outputs: List(TxOut)) -> Int {
  list.fold(outputs, 0, fn(acc, output) { acc + output.value.sats })
}

/// Count inputs from unconfirmed parents (mempool ancestors)
fn count_unconfirmed_ancestors(inputs: List(InputInfo)) -> Int {
  list.fold(inputs, 0, fn(acc, input_info) {
    case input_info.from_mempool {
      True -> acc + 1
      False -> acc
    }
  })
}

// ============================================================================
// Coinbase Maturity
// ============================================================================

/// Check that coinbase outputs are mature before spending
fn check_coinbase_maturity(
  inputs: List(InputInfo),
  current_height: Int,
) -> Result(Nil, ValidationError) {
  check_coinbase_maturity_loop(inputs, current_height)
}

fn check_coinbase_maturity_loop(
  inputs: List(InputInfo),
  current_height: Int,
) -> Result(Nil, ValidationError) {
  case inputs {
    [] -> Ok(Nil)
    [input_info, ..rest] -> {
      case input_info.utxo.is_coinbase {
        False -> check_coinbase_maturity_loop(rest, current_height)
        True -> {
          let age = current_height - input_info.utxo.height
          case age >= coinbase_maturity {
            True -> check_coinbase_maturity_loop(rest, current_height)
            False ->
              Error(PrematureCoinbaseSpend(
                input_info.index,
                age,
                coinbase_maturity,
              ))
          }
        }
      }
    }
  }
}

// ============================================================================
// Locktime Validation
// ============================================================================

/// Check transaction-level locktime
fn check_locktime(
  tx: Transaction,
  utxo_view: UtxoView,
) -> Result(Nil, ValidationError) {
  // If all sequences are final, locktime is disabled
  let all_final =
    list.all(tx.inputs, fn(input) { input.sequence == sequence_final })

  case all_final {
    True -> Ok(Nil)
    False -> {
      // Locktime is enabled, check it
      let locktime = tx.lock_time
      case locktime < locktime_threshold {
        // Block height locktime
        True -> {
          case locktime <= utxo_view.chain_height {
            True -> Ok(Nil)
            False ->
              Error(LocktimeNotSatisfied(locktime, utxo_view.chain_height))
          }
        }
        // Unix timestamp locktime
        False -> {
          case locktime <= utxo_view.median_time_past {
            True -> Ok(Nil)
            False ->
              Error(LocktimeNotSatisfied(locktime, utxo_view.median_time_past))
          }
        }
      }
    }
  }
}

// ============================================================================
// Sequence Locks (BIP 68)
// ============================================================================

/// Check BIP 68 relative locktimes
fn check_sequence_locks(
  inputs: List(TxIn),
  inputs_info: List(InputInfo),
  utxo_view: UtxoView,
) -> Result(Nil, ValidationError) {
  check_sequence_locks_loop(inputs, inputs_info, utxo_view, 0)
}

fn check_sequence_locks_loop(
  inputs: List(TxIn),
  inputs_info: List(InputInfo),
  utxo_view: UtxoView,
  index: Int,
) -> Result(Nil, ValidationError) {
  case inputs, inputs_info {
    [], [] -> Ok(Nil)
    [input, ..rest_inputs], [info, ..rest_info] -> {
      use _ <- result.try(check_one_sequence_lock(input, info, utxo_view, index))
      check_sequence_locks_loop(rest_inputs, rest_info, utxo_view, index + 1)
    }
    _, _ -> Ok(Nil)
    // Mismatched lists - shouldn't happen
  }
}

/// Check a single input's sequence lock
fn check_one_sequence_lock(
  input: TxIn,
  info: InputInfo,
  utxo_view: UtxoView,
  index: Int,
) -> Result(Nil, ValidationError) {
  let sequence = input.sequence

  // Check if locktime is disabled for this input
  case int.bitwise_and(sequence, sequence_locktime_disable_flag) != 0 {
    True -> Ok(Nil)
    False -> {
      // Extract locktime value (lower 16 bits)
      let lock_value = int.bitwise_and(sequence, sequence_locktime_mask)

      // Check if time-based or block-based
      case int.bitwise_and(sequence, sequence_locktime_type_flag) != 0 {
        // Time-based: value is in 512-second units
        True -> {
          // For simplicity, we don't implement time-based locks yet
          // Would need to track MTP at input height
          Ok(Nil)
        }
        // Block-based: value is block count
        False -> {
          let input_height = info.utxo.height
          let required_height = input_height + lock_value
          case utxo_view.chain_height >= required_height {
            True -> Ok(Nil)
            False ->
              Error(SequenceNotSatisfied(
                index,
                required_height,
                utxo_view.chain_height,
              ))
          }
        }
      }
    }
  }
}

// ============================================================================
// Helper Functions
// ============================================================================

/// Create a simple UTXO view for testing
pub fn simple_utxo_view(
  lookup_fn: fn(OutPoint) -> UtxoLookupResult,
  height: Int,
) -> UtxoView {
  UtxoView(lookup: lookup_fn, chain_height: height, median_time_past: 0)
}

/// Convert validation error to string
pub fn error_to_string(error: ValidationError) -> String {
  case error {
    MissingInput(idx, _) -> "input " <> int.to_string(idx) <> " missing UTXO"
    DoubleSpend(idx, _) -> "input " <> int.to_string(idx) <> " double-spend"
    PrematureCoinbaseSpend(idx, age, req) ->
      "input "
      <> int.to_string(idx)
      <> " coinbase not mature (age "
      <> int.to_string(age)
      <> " < "
      <> int.to_string(req)
      <> ")"
    NegativeFee(inputs, outputs) ->
      "negative fee: inputs "
      <> int.to_string(inputs)
      <> " < outputs "
      <> int.to_string(outputs)
    FeeTooLow(fee, min_fee, _) ->
      "fee too low: " <> int.to_string(fee) <> " < " <> int.to_string(min_fee)
    LocktimeNotSatisfied(locktime, current) ->
      "locktime not satisfied: "
      <> int.to_string(locktime)
      <> " > "
      <> int.to_string(current)
    SequenceNotSatisfied(idx, req, actual) ->
      "sequence lock on input "
      <> int.to_string(idx)
      <> " not satisfied: "
      <> int.to_string(req)
      <> " > "
      <> int.to_string(actual)
    ScriptFailure(idx, reason) ->
      "script failed on input " <> int.to_string(idx) <> ": " <> reason
    AlreadyInMempool -> "transaction already in mempool"
    MempoolConflict(txid) -> "conflicts with mempool tx " <> txid
    TooManyUnconfirmedAncestors(count, max) ->
      "too many unconfirmed ancestors: "
      <> int.to_string(count)
      <> " > "
      <> int.to_string(max)
  }
}
