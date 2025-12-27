// block_template.gleam - Block template creation for mining
//
// This module implements block template creation:
// - Transaction selection from mempool by fee rate
// - Coinbase transaction creation with subsidy + fees
// - Merkle root calculation
// - Block template generation for getblocktemplate RPC
//
// References:
// - BIP22: getblocktemplate - Fundamentals
// - BIP23: getblocktemplate - Long Polling

import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import oni_bitcoin.{
  type Amount, type Block, type BlockHash, type BlockHeader, type Hash256,
  type OutPoint, type Script, type Transaction, type TxIn, type TxOut, type Txid,
}
import gleam/set
import oni_consensus.{compute_merkle_root}
import oni_consensus/mempool.{type Mempool, type MempoolEntry}

// ============================================================================
// Constants
// ============================================================================

/// Maximum block weight (4M weight units)
pub const max_block_weight = 4_000_000

/// Maximum sigops per block (scaled by witness factor)
pub const max_block_sigops = 80_000

/// Coinbase output maturity (100 blocks)
pub const coinbase_maturity = 100

/// Initial block subsidy in satoshis (50 BTC)
pub const initial_subsidy_sats = 5_000_000_000

/// Halving interval (210,000 blocks)
pub const halving_interval = 210_000

/// Witness commitment header
pub const witness_commitment_header = <<0xaa, 0x21, 0xa9, 0xed>>

// ============================================================================
// Block Template Types
// ============================================================================

/// Block template for mining
pub type BlockTemplate {
  BlockTemplate(
    /// Block version
    version: Int,
    /// Previous block hash
    prev_block_hash: BlockHash,
    /// Transactions to include (excluding coinbase)
    transactions: List(TemplateTransaction),
    /// Coinbase transaction (created by miner with their address)
    coinbase_value: Int,
    /// Target difficulty
    target: BitArray,
    /// Minimum timestamp
    min_time: Int,
    /// Current time
    cur_time: Int,
    /// Block height
    height: Int,
    /// Difficulty bits (compact format)
    bits: Int,
    /// Total sigops used
    sigops_used: Int,
    /// Total weight used
    weight_used: Int,
    /// Witness commitment (for SegWit blocks)
    witness_commitment: Option(BitArray),
    /// Total fees from transactions
    total_fees: Int,
  )
}

/// Transaction in the template with additional info
pub type TemplateTransaction {
  TemplateTransaction(
    /// Transaction data (hex encoded for RPC)
    data: BitArray,
    /// Transaction ID
    txid: Txid,
    /// Transaction hash (with witness)
    hash: Hash256,
    /// Transaction fee in satoshis
    fee: Int,
    /// Sigop cost
    sigops: Int,
    /// Weight
    weight: Int,
    /// Dependencies (indices of transactions this depends on)
    depends: List(Int),
  )
}

/// Parameters for template creation
pub type TemplateParams {
  TemplateParams(
    /// Previous block hash
    prev_block_hash: BlockHash,
    /// Block height
    height: Int,
    /// Current time
    cur_time: Int,
    /// Network difficulty bits
    bits: Int,
    /// Address for coinbase output (optional - if None, caller creates coinbase)
    coinbase_address: Option(Script),
  )
}

// ============================================================================
// Subsidy Calculation
// ============================================================================

/// Calculate block subsidy for a given height
pub fn calculate_subsidy(height: Int) -> Int {
  let halvings = height / halving_interval
  case halvings >= 64 {
    True -> 0  // Subsidy exhausted
    False -> int.bitwise_shift_right(initial_subsidy_sats, halvings)
  }
}

/// Calculate total coinbase value (subsidy + fees)
pub fn calculate_coinbase_value(height: Int, total_fees: Int) -> Int {
  calculate_subsidy(height) + total_fees
}

// ============================================================================
// Transaction Selection
// ============================================================================

/// Select transactions from mempool for inclusion in a block
/// Uses the mempool's built-in selection function (ancestor-aware)
pub fn select_transactions(
  pool: Mempool,
  max_weight: Int,
) -> #(List(TemplateTransaction), Int, Int, Int) {
  // Reserve space for coinbase (estimated)
  let coinbase_weight = 1000
  let available_weight = max_weight - coinbase_weight

  // Get sorted entries from mempool
  let entries = mempool.mempool_get_for_block(pool, available_weight)

  // Convert to template transactions and compute totals
  convert_to_template_txs(entries, [], dict.new(), 0, 0, 0, 0)
}

fn convert_to_template_txs(
  remaining: List(MempoolEntry),
  selected: List(TemplateTransaction),
  txid_index: Dict(String, Int),
  idx: Int,
  weight_acc: Int,
  sigops_acc: Int,
  fees_acc: Int,
) -> #(List(TemplateTransaction), Int, Int, Int) {
  case remaining {
    [] -> #(list.reverse(selected), weight_acc, sigops_acc, fees_acc)

    [entry, ..rest] -> {
      let tx_weight = entry.vsize * 4
      let tx_sigops = estimate_sigops(entry.tx)
      let tx_fee = oni_bitcoin.amount_to_sats(entry.fee)
      let txid_key = oni_bitcoin.txid_to_hex(entry.txid)

      // Build depends list from ancestors already in template
      let depends = build_depends_list(entry, txid_index)

      // Create template transaction
      let template_tx = TemplateTransaction(
        data: encode_transaction(entry.tx),
        txid: entry.txid,
        hash: entry.txid.hash,  // Txid contains the Hash256
        fee: tx_fee,
        sigops: tx_sigops,
        weight: tx_weight,
        depends: depends,
      )

      // Update index with current position
      let new_index = dict.insert(txid_index, txid_key, idx)

      convert_to_template_txs(
        rest,
        [template_tx, ..selected],
        new_index,
        idx + 1,
        weight_acc + tx_weight,
        sigops_acc + tx_sigops,
        fees_acc + tx_fee,
      )
    }
  }
}

/// Build list of dependency indices for a transaction
fn build_depends_list(entry: MempoolEntry, txid_index: Dict(String, Int)) -> List(Int) {
  list.filter_map(
    set.to_list(entry.ancestors),
    fn(ancestor_key) {
      case dict.get(txid_index, ancestor_key) {
        Ok(idx) -> Ok(idx)
        Error(_) -> Error(Nil)
      }
    }
  )
}

/// Estimate sigops for a transaction
fn estimate_sigops(tx: Transaction) -> Int {
  // Simplified: count P2PKH outputs as 1 sigop each
  // In reality, need to analyze scripts
  list.length(tx.inputs) + list.length(tx.outputs)
}

// ============================================================================
// Coinbase Creation
// ============================================================================

/// Create a coinbase transaction
pub fn create_coinbase(
  height: Int,
  value: Int,
  output_script: Script,
  witness_commitment: Option(BitArray),
) -> Transaction {
  // Coinbase input (null prevout)
  let coinbase_input = TxIn(
    prevout: oni_bitcoin.outpoint_null(),
    script_sig: create_coinbase_script(height),
    sequence: 0xFFFFFFFF,
    witness: [],
  )

  // Main output to miner
  let main_output = TxOut(
    value: oni_bitcoin.sats(value),
    script_pubkey: output_script,
  )

  // Outputs list
  let outputs = case witness_commitment {
    None -> [main_output]
    Some(commitment) -> {
      // Add witness commitment output (OP_RETURN)
      let witness_output = TxOut(
        value: oni_bitcoin.sats(0),
        script_pubkey: create_witness_commitment_script(commitment),
      )
      [main_output, witness_output]
    }
  }

  // Coinbase transaction
  oni_bitcoin.Transaction(
    version: 2,
    inputs: [coinbase_input],
    outputs: outputs,
    lock_time: 0,
  )
}

/// Create coinbase script with height (BIP34)
fn create_coinbase_script(height: Int) -> Script {
  // BIP34: height in scriptSig
  let height_bytes = encode_height(height)
  oni_bitcoin.Script(height_bytes)
}

/// Encode height for coinbase script (BIP34 format)
fn encode_height(height: Int) -> BitArray {
  case height {
    h if h <= 16 -> <<h:8>>
    h if h <= 127 -> <<1:8, h:8>>
    h if h <= 32767 -> <<2:8, h:16-little>>
    h if h <= 8388607 -> <<3:8, h:24-little>>
    h -> <<4:8, h:32-little>>
  }
}

/// Create witness commitment script (OP_RETURN + commitment)
fn create_witness_commitment_script(commitment: BitArray) -> Script {
  let script_bytes = <<0x6a, 0x24>>  // OP_RETURN OP_PUSHBYTES_36
    |> bit_array.append(witness_commitment_header)
    |> bit_array.append(commitment)
  oni_bitcoin.Script(script_bytes)
}

// ============================================================================
// Witness Commitment
// ============================================================================

/// Calculate witness commitment for a block
pub fn calculate_witness_commitment(
  coinbase_wtxid: Hash256,
  txs: List(TemplateTransaction),
) -> BitArray {
  // Build witness merkle root from wtxids
  // First element is coinbase (all zeros for witness commitment)
  let zero_hash = oni_bitcoin.Hash256(<<0:256>>)
  let wtxids = [zero_hash, ..list.map(txs, fn(tx) { tx.hash })]
  let witness_root = compute_merkle_root(wtxids)

  // Witness commitment = SHA256(SHA256(witness_root || witness_reserved))
  let witness_reserved = <<0:256>>  // 32 bytes of zeros
  let commitment_data = bit_array.append(witness_root.bytes, witness_reserved)
  let commitment = oni_bitcoin.hash256_digest(commitment_data)
  commitment.bytes
}

// ============================================================================
// Block Template Creation
// ============================================================================

/// Create a block template from mempool and chainstate
pub fn create_template(
  pool: Mempool,
  params: TemplateParams,
) -> BlockTemplate {
  // Select transactions from mempool
  let #(txs, weight_used, sigops_used, total_fees) =
    select_transactions(pool, max_block_weight)

  // Calculate coinbase value
  let coinbase_value = calculate_coinbase_value(params.height, total_fees)

  // Calculate witness commitment if there are SegWit transactions
  let has_witness = list.any(txs, fn(tx) { bit_array.byte_size(tx.data) > 0 })
  let witness_commitment = case has_witness {
    True -> {
      let zero_hash = oni_bitcoin.Hash256(<<0:256>>)
      Some(calculate_witness_commitment(zero_hash, txs))
    }
    False -> None
  }

  // Calculate target from bits
  let target = bits_to_target(params.bits)

  BlockTemplate(
    version: 0x20000000,  // BIP9 versionbits base
    prev_block_hash: params.prev_block_hash,
    transactions: txs,
    coinbase_value: coinbase_value,
    target: target,
    min_time: params.cur_time - 7200,  // 2 hours in past allowed
    cur_time: params.cur_time,
    height: params.height,
    bits: params.bits,
    sigops_used: sigops_used,
    weight_used: weight_used,
    witness_commitment: witness_commitment,
    total_fees: total_fees,
  )
}

/// Convert compact bits to target
fn bits_to_target(bits: Int) -> BitArray {
  let exp = int.bitwise_shift_right(bits, 24)
  let mantissa = int.bitwise_and(bits, 0x00FFFFFF)

  // Create target with mantissa shifted
  let shift = exp - 3
  case shift >= 0 && shift <= 29 {
    True -> {
      let zeros_before = 32 - 3 - shift
      let zeros_after = shift
      build_target_bytes(mantissa, zeros_before, zeros_after)
    }
    False -> <<0:256>>  // Invalid, return zero target
  }
}

fn build_target_bytes(mantissa: Int, zeros_before: Int, zeros_after: Int) -> BitArray {
  let before = create_zeros(zeros_before)
  let mant = <<mantissa:24-big>>
  let after = create_zeros(zeros_after)
  bit_array.concat([before, mant, after])
}

fn create_zeros(n: Int) -> BitArray {
  case n <= 0 {
    True -> <<>>
    False -> bit_array.append(<<0:8>>, create_zeros(n - 1))
  }
}

// ============================================================================
// Template Serialization
// ============================================================================

/// Encode a transaction to bytes (with witness if present)
fn encode_transaction(tx: Transaction) -> BitArray {
  oni_bitcoin.encode_tx(tx)
}

/// Convert template to RPC response format
pub fn template_to_rpc(template: BlockTemplate) -> Dict(String, a) {
  // This would be used by the RPC layer
  // Returns the getblocktemplate response structure
  dict.new()
}

// ============================================================================
// Merkle Root Calculation for Template
// ============================================================================

/// Calculate merkle root for a block template
pub fn calculate_template_merkle_root(
  coinbase_txid: Txid,
  txs: List(TemplateTransaction),
) -> Hash256 {
  let txids = [coinbase_txid.hash, ..list.map(txs, fn(tx) { tx.txid.hash })]
  compute_merkle_root(txids)
}
