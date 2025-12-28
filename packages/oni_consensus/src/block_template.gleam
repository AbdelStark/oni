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
import mempool.{type Mempool, type MempoolEntry}

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
  let coinbase_input = oni_bitcoin.TxIn(
    oni_bitcoin.outpoint_null(),
    create_coinbase_script(height),
    0xFFFFFFFF,
    [],
  )

  // Main output to miner
  let main_output = oni_bitcoin.TxOut(
    oni_bitcoin.sats(value),
    output_script,
  )

  // Outputs list
  let outputs = case witness_commitment {
    None -> [main_output]
    Some(commitment) -> {
      // Add witness commitment output (OP_RETURN)
      let witness_output = oni_bitcoin.TxOut(
        oni_bitcoin.sats(0),
        create_witness_commitment_script(commitment),
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

// ============================================================================
// Enhanced Transaction Selection (CPFP Aware)
// ============================================================================

/// Transaction package for ancestor-aware fee calculation
pub type TxPackage {
  TxPackage(
    /// Primary transaction
    tx: MempoolEntry,
    /// Ancestor transactions that must be included
    ancestors: List(MempoolEntry),
    /// Package fee rate (total fees / total vsize)
    package_fee_rate: Float,
    /// Total package size in vbytes
    package_vsize: Int,
    /// Total package fee
    package_fee: Int,
  )
}

/// Select transactions with CPFP (Child Pays For Parent) awareness
pub fn select_transactions_cpfp(
  entries: List(MempoolEntry),
  max_weight: Int,
) -> #(List(TemplateTransaction), Int, Int, Int) {
  // Build packages for each transaction
  let packages = build_tx_packages(entries)

  // Sort by package fee rate
  let sorted = list.sort(packages, fn(a, b) {
    float.compare(b.package_fee_rate, a.package_fee_rate)
  })

  // Select packages that fit
  select_packages(sorted, max_weight, [], set.new(), 0, 0, 0)
}

fn build_tx_packages(entries: List(MempoolEntry)) -> List(TxPackage) {
  let entry_by_key = list.fold(entries, dict.new(), fn(acc, entry) {
    let key = oni_bitcoin.txid_to_hex(entry.txid)
    dict.insert(acc, key, entry)
  })

  list.map(entries, fn(entry) {
    let ancestors = gather_ancestors(entry, entry_by_key)
    let total_fee = oni_bitcoin.amount_to_sats(entry.fee) +
      list.fold(ancestors, 0, fn(acc, anc) {
        acc + oni_bitcoin.amount_to_sats(anc.fee)
      })
    let total_vsize = entry.vsize + list.fold(ancestors, 0, fn(acc, anc) {
      acc + anc.vsize
    })
    let rate = case total_vsize > 0 {
      True -> int.to_float(total_fee) /. int.to_float(total_vsize)
      False -> 0.0
    }

    TxPackage(
      tx: entry,
      ancestors: ancestors,
      package_fee_rate: rate,
      package_vsize: total_vsize,
      package_fee: total_fee,
    )
  })
}

fn gather_ancestors(
  entry: MempoolEntry,
  all_entries: Dict(String, MempoolEntry),
) -> List(MempoolEntry) {
  set.to_list(entry.ancestors)
  |> list.filter_map(fn(key) {
    dict.get(all_entries, key)
  })
}

fn select_packages(
  packages: List(TxPackage),
  remaining_weight: Int,
  acc: List(TemplateTransaction),
  selected_keys: set.Set(String),
  weight_used: Int,
  sigops_used: Int,
  fees_used: Int,
) -> #(List(TemplateTransaction), Int, Int, Int) {
  case packages {
    [] -> #(list.reverse(acc), weight_used, sigops_used, fees_used)
    [pkg, ..rest] -> {
      let pkg_weight = pkg.package_vsize * 4
      let tx_key = oni_bitcoin.txid_to_hex(pkg.tx.txid)

      // Skip if already selected
      case set.contains(selected_keys, tx_key) {
        True -> select_packages(rest, remaining_weight, acc, selected_keys,
          weight_used, sigops_used, fees_used)
        False -> {
          // Check if fits
          case pkg_weight <= remaining_weight {
            False -> select_packages(rest, remaining_weight, acc, selected_keys,
              weight_used, sigops_used, fees_used)
            True -> {
              // Add ancestors first
              let #(acc2, keys2, w2, s2, f2) = add_ancestors(
                pkg.ancestors, acc, selected_keys, weight_used, sigops_used, fees_used
              )

              // Add the transaction
              let template_tx = mempool_entry_to_template(pkg.tx)
              let tx_sigops = estimate_sigops(pkg.tx.tx)
              let tx_fee = oni_bitcoin.amount_to_sats(pkg.tx.fee)

              let new_keys = set.insert(keys2, tx_key)
              let new_weight = w2 + pkg.tx.vsize * 4
              let new_sigops = s2 + tx_sigops
              let new_fees = f2 + tx_fee

              select_packages(rest, remaining_weight - pkg_weight,
                [template_tx, ..acc2], new_keys, new_weight, new_sigops, new_fees)
            }
          }
        }
      }
    }
  }
}

fn add_ancestors(
  ancestors: List(MempoolEntry),
  acc: List(TemplateTransaction),
  selected: set.Set(String),
  weight: Int,
  sigops: Int,
  fees: Int,
) -> #(List(TemplateTransaction), set.Set(String), Int, Int, Int) {
  case ancestors {
    [] -> #(acc, selected, weight, sigops, fees)
    [anc, ..rest] -> {
      let key = oni_bitcoin.txid_to_hex(anc.txid)
      case set.contains(selected, key) {
        True -> add_ancestors(rest, acc, selected, weight, sigops, fees)
        False -> {
          let template_tx = mempool_entry_to_template(anc)
          let tx_sigops = estimate_sigops(anc.tx)
          let tx_fee = oni_bitcoin.amount_to_sats(anc.fee)

          add_ancestors(rest,
            [template_tx, ..acc],
            set.insert(selected, key),
            weight + anc.vsize * 4,
            sigops + tx_sigops,
            fees + tx_fee
          )
        }
      }
    }
  }
}

fn mempool_entry_to_template(entry: MempoolEntry) -> TemplateTransaction {
  TemplateTransaction(
    data: encode_transaction(entry.tx),
    txid: entry.txid,
    hash: entry.txid.hash,
    fee: oni_bitcoin.amount_to_sats(entry.fee),
    sigops: estimate_sigops(entry.tx),
    weight: entry.vsize * 4,
    depends: [],
  )
}

// ============================================================================
// Enhanced Coinbase with Extra Nonce
// ============================================================================

/// Coinbase extra nonce size
pub const extra_nonce_size = 8

/// Create coinbase with extra nonce space for mining hardware
pub fn create_coinbase_with_extra_nonce(
  height: Int,
  value: Int,
  output_script: Script,
  witness_commitment: Option(BitArray),
  extra_data: BitArray,
) -> #(Transaction, Int, Int) {
  // Create coinbase script with height and extra nonce placeholder
  let height_script = encode_height(height)
  let extra_nonce_placeholder = <<0:64>>  // 8 bytes for extra nonce
  let coinbase_script = bit_array.concat([
    height_script,
    extra_data,
    extra_nonce_placeholder,
  ])

  // Calculate extra nonce range
  let extra_nonce_start = bit_array.byte_size(height_script) + bit_array.byte_size(extra_data)
  let extra_nonce_len = extra_nonce_size

  let coinbase_input = oni_bitcoin.TxIn(
    prevout: oni_bitcoin.outpoint_null(),
    script_sig: oni_bitcoin.Script(coinbase_script),
    sequence: 0xFFFFFFFF,
    witness: [<<0:256>>],  // Witness reserved value
  )

  let main_output = oni_bitcoin.TxOut(
    value: oni_bitcoin.sats(value),
    script_pubkey: output_script,
  )

  let outputs = case witness_commitment {
    None -> [main_output]
    Some(commitment) -> {
      let witness_output = oni_bitcoin.TxOut(
        value: oni_bitcoin.sats(0),
        script_pubkey: create_witness_commitment_script(commitment),
      )
      [main_output, witness_output]
    }
  }

  let tx = oni_bitcoin.Transaction(
    version: 2,
    inputs: [coinbase_input],
    outputs: outputs,
    lock_time: 0,
  )

  #(tx, extra_nonce_start, extra_nonce_len)
}

// ============================================================================
// Block Assembly
// ============================================================================

/// Assemble a complete block from template and coinbase
pub fn assemble_block(
  template: BlockTemplate,
  coinbase: Transaction,
  nonce: Int,
  timestamp: Int,
) -> Block {
  // Calculate merkle root
  let coinbase_txid = oni_bitcoin.txid_from_tx(coinbase)
  let merkle_root = calculate_template_merkle_root(
    coinbase_txid,
    template.transactions
  )

  // Create header
  let header = oni_bitcoin.BlockHeader(
    version: template.version,
    prev_block: template.prev_block_hash,
    merkle_root: merkle_root,
    timestamp: timestamp,
    bits: template.bits,
    nonce: nonce,
  )

  // Assemble transactions
  let transactions = [coinbase, ..list.map(template.transactions, fn(t) {
    decode_template_tx(t.data)
  })]

  oni_bitcoin.Block(
    header: header,
    transactions: transactions,
  )
}

fn decode_template_tx(data: BitArray) -> Transaction {
  case oni_bitcoin.decode_tx(data) {
    Ok(#(tx, _rest)) -> tx
    Error(_) -> panic as "Invalid template transaction data"
  }
}

// ============================================================================
// Template Validation
// ============================================================================

/// Validate a block template
pub fn validate_template(template: BlockTemplate) -> Result(Nil, TemplateError) {
  // Check weight limit
  case template.weight_used > max_block_weight {
    True -> Error(WeightExceeded(template.weight_used))
    False -> {
      // Check sigops limit
      case template.sigops_used > max_block_sigops {
        True -> Error(SigopsExceeded(template.sigops_used))
        False -> {
          // Check coinbase value
          let expected_subsidy = calculate_subsidy(template.height)
          let max_coinbase = expected_subsidy + template.total_fees
          case template.coinbase_value > max_coinbase {
            True -> Error(InvalidCoinbaseValue)
            False -> Ok(Nil)
          }
        }
      }
    }
  }
}

/// Template validation errors
pub type TemplateError {
  WeightExceeded(Int)
  SigopsExceeded(Int)
  InvalidCoinbaseValue
  InvalidMerkleRoot
  InvalidWitnessCommitment
}

// ============================================================================
// Template Update Detection
// ============================================================================

/// Check if template needs to be updated
pub type TemplateUpdateReason {
  /// New transactions available with higher fees
  NewHighFeeTransactions
  /// Previous block changed
  NewPrevBlock
  /// Time drift requires update
  TimeDrift
  /// No update needed
  NoUpdateNeeded
}

/// Check if template should be updated
pub fn should_update_template(
  current: BlockTemplate,
  new_prev_hash: BlockHash,
  new_time: Int,
  mempool_updated: Bool,
) -> TemplateUpdateReason {
  // Check if previous block changed
  case current.prev_block_hash.hash.bytes != new_prev_hash.hash.bytes {
    True -> NewPrevBlock
    False -> {
      // Check time drift (update if more than 30 seconds old)
      case new_time - current.cur_time > 30 {
        True -> TimeDrift
        False -> {
          // Check if mempool has new high-fee transactions
          case mempool_updated {
            True -> NewHighFeeTransactions
            False -> NoUpdateNeeded
          }
        }
      }
    }
  }
}

// ============================================================================
// Mining Job Support
// ============================================================================

/// Mining job for getwork-style mining
pub type MiningJob {
  MiningJob(
    job_id: String,
    prev_hash: BitArray,
    coinbase1: BitArray,
    coinbase2: BitArray,
    merkle_branches: List(BitArray),
    version: Int,
    nbits: Int,
    ntime: Int,
    clean_jobs: Bool,
  )
}

/// Create mining job from template
pub fn create_mining_job(
  template: BlockTemplate,
  job_id: String,
  coinbase_output_script: Script,
  extra_nonce_size_1: Int,
  extra_nonce_size_2: Int,
) -> MiningJob {
  // Calculate witness commitment
  let zero_hash = oni_bitcoin.Hash256(<<0:256>>)
  let witness_commitment = calculate_witness_commitment(zero_hash, template.transactions)

  // Create coinbase parts
  let #(coinbase1, coinbase2) = create_coinbase_parts(
    template.height,
    template.coinbase_value,
    coinbase_output_script,
    Some(witness_commitment),
    extra_nonce_size_1,
    extra_nonce_size_2,
  )

  // Calculate merkle branches
  let txids = list.map(template.transactions, fn(t) { t.txid.hash.bytes })
  let merkle_branches = calculate_merkle_branches(txids)

  MiningJob(
    job_id: job_id,
    prev_hash: reverse_bytes(template.prev_block_hash.hash.bytes),
    coinbase1: coinbase1,
    coinbase2: coinbase2,
    merkle_branches: merkle_branches,
    version: template.version,
    nbits: template.bits,
    ntime: template.cur_time,
    clean_jobs: True,
  )
}

fn create_coinbase_parts(
  height: Int,
  value: Int,
  output_script: Script,
  witness_commitment: Option(BitArray),
  extra_nonce_size_1: Int,
  extra_nonce_size_2: Int,
) -> #(BitArray, BitArray) {
  // Part 1: version + input count + prevout + scriptsig length + scriptsig before extra nonce
  let version = <<2:32-little>>
  let input_count = <<1:8>>
  let prevout = <<0:256, 0xFFFFFFFF:32-little>>
  let height_script = encode_height(height)
  let script_len = bit_array.byte_size(height_script) + extra_nonce_size_1 + extra_nonce_size_2
  let len_byte = oni_bitcoin.compact_size_encode(script_len)

  let coinbase1 = bit_array.concat([
    version,
    <<0:8, 1:8>>,  // SegWit marker + flag
    input_count,
    prevout,
    len_byte,
    height_script,
  ])

  // Part 2: sequence + outputs + witness + locktime
  let sequence = <<0xFFFFFFFF:32-little>>
  let output_data = create_outputs_data(value, output_script, witness_commitment)
  let witness = <<1:8, 32:8, 0:256>>  // 1 witness item, 32 bytes, all zeros
  let locktime = <<0:32-little>>

  let coinbase2 = bit_array.concat([
    sequence,
    output_data,
    witness,
    locktime,
  ])

  #(coinbase1, coinbase2)
}

fn create_outputs_data(
  value: Int,
  output_script: Script,
  witness_commitment: Option(BitArray),
) -> BitArray {
  let script_bytes = oni_bitcoin.script_to_bytes(output_script)
  let main_output = bit_array.concat([
    <<value:64-little>>,
    oni_bitcoin.compact_size_encode(bit_array.byte_size(script_bytes)),
    script_bytes,
  ])

  case witness_commitment {
    None -> {
      bit_array.concat([
        <<1:8>>,  // Output count
        main_output,
      ])
    }
    Some(commitment) -> {
      let witness_script = bit_array.concat([
        <<0x6a, 0x24>>,
        witness_commitment_header,
        commitment,
      ])
      let witness_output = bit_array.concat([
        <<0:64-little>>,  // Zero value
        oni_bitcoin.compact_size_encode(bit_array.byte_size(witness_script)),
        witness_script,
      ])
      bit_array.concat([
        <<2:8>>,  // Output count
        main_output,
        witness_output,
      ])
    }
  }
}

/// Calculate merkle branches for stratum mining
fn calculate_merkle_branches(txids: List(BitArray)) -> List(BitArray) {
  case txids {
    [] -> []
    _ -> calculate_branches_recursive(txids, [])
  }
}

fn calculate_branches_recursive(
  hashes: List(BitArray),
  acc: List(BitArray),
) -> List(BitArray) {
  case hashes {
    [] -> list.reverse(acc)
    [_single] -> list.reverse(acc)
    [first, ..rest] -> {
      // Take first hash as the branch
      let branch = first

      // Combine remaining pairs
      let next_level = combine_hash_pairs(rest, [])

      calculate_branches_recursive(next_level, [branch, ..acc])
    }
  }
}

fn combine_hash_pairs(hashes: List(BitArray), acc: List(BitArray)) -> List(BitArray) {
  case hashes {
    [] -> list.reverse(acc)
    [single] -> list.reverse([single, ..acc])
    [h1, h2, ..rest] -> {
      let combined = oni_bitcoin.hash256_digest(bit_array.append(h1, h2))
      combine_hash_pairs(rest, [combined.bytes, ..acc])
    }
  }
}

fn reverse_bytes(data: BitArray) -> BitArray {
  reverse_bytes_acc(data, <<>>)
}

fn reverse_bytes_acc(data: BitArray, acc: BitArray) -> BitArray {
  case data {
    <<>> -> acc
    <<byte:8, rest:bits>> -> reverse_bytes_acc(rest, <<byte:8, acc:bits>>)
    // Handle partial bytes at end
    _ -> acc
  }
}
