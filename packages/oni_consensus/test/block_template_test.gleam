// block_template_test.gleam - Tests for block template creation
//
// Tests verify:
// - Subsidy calculation across halvings
// - Coinbase transaction creation
// - Transaction selection from mempool
// - Template creation

import block_template
import gleam/option.{None, Some}
import gleeunit
import gleeunit/should
import mempool
import oni_bitcoin

pub fn main() {
  gleeunit.main()
}

// ============================================================================
// Subsidy Calculation Tests
// ============================================================================

pub fn subsidy_genesis_test() {
  // Genesis block (height 0) should have 50 BTC
  let subsidy = block_template.calculate_subsidy(0)
  should.equal(subsidy, 5_000_000_000)
  // 50 BTC in satoshis
}

pub fn subsidy_before_first_halving_test() {
  // Block before first halving should have 50 BTC
  let subsidy = block_template.calculate_subsidy(209_999)
  should.equal(subsidy, 5_000_000_000)
}

pub fn subsidy_first_halving_test() {
  // First halving (height 210000) should have 25 BTC
  let subsidy = block_template.calculate_subsidy(210_000)
  should.equal(subsidy, 2_500_000_000)
  // 25 BTC
}

pub fn subsidy_second_halving_test() {
  // Second halving (height 420000) should have 12.5 BTC
  let subsidy = block_template.calculate_subsidy(420_000)
  should.equal(subsidy, 1_250_000_000)
  // 12.5 BTC
}

pub fn subsidy_third_halving_test() {
  // Third halving (height 630000) should have 6.25 BTC
  let subsidy = block_template.calculate_subsidy(630_000)
  should.equal(subsidy, 625_000_000)
  // 6.25 BTC
}

pub fn subsidy_fourth_halving_test() {
  // Fourth halving (height 840000) should have 3.125 BTC
  let subsidy = block_template.calculate_subsidy(840_000)
  should.equal(subsidy, 312_500_000)
  // 3.125 BTC
}

pub fn subsidy_exhausted_test() {
  // After 64 halvings, subsidy should be 0
  let subsidy = block_template.calculate_subsidy(64 * 210_000)
  should.equal(subsidy, 0)
}

pub fn subsidy_very_high_block_test() {
  // Very high block number should have 0 subsidy
  let subsidy = block_template.calculate_subsidy(100_000_000)
  should.equal(subsidy, 0)
}

// ============================================================================
// Coinbase Value Tests
// ============================================================================

pub fn coinbase_value_no_fees_test() {
  // Coinbase with no fees should equal subsidy
  let value = block_template.calculate_coinbase_value(0, 0)
  should.equal(value, 5_000_000_000)
  // 50 BTC
}

pub fn coinbase_value_with_fees_test() {
  // Coinbase should include fees
  let fees = 100_000
  // 0.001 BTC
  let value = block_template.calculate_coinbase_value(0, fees)
  should.equal(value, 5_000_000_000 + 100_000)
  // 50.001 BTC
}

pub fn coinbase_value_halving_with_fees_test() {
  // After halving, coinbase should be subsidy + fees
  let fees = 50_000_000
  // 0.5 BTC in fees
  let value = block_template.calculate_coinbase_value(210_000, fees)
  should.equal(value, 2_500_000_000 + 50_000_000)
  // 25.5 BTC
}

pub fn coinbase_value_exhausted_subsidy_test() {
  // When subsidy is exhausted, only fees
  let fees = 1_000_000
  let value = block_template.calculate_coinbase_value(100_000_000, fees)
  should.equal(value, 1_000_000)
  // Only fees
}

// ============================================================================
// Coinbase Transaction Tests
// ============================================================================

pub fn create_coinbase_basic_test() {
  let output_script = oni_bitcoin.Script(<<0x76, 0xa9, 0x14>>)
  // P2PKH start
  let coinbase =
    block_template.create_coinbase(
      100,
      // height
      5_000_000_000,
      // 50 BTC
      output_script,
      None,
      // no witness commitment
    )

  // Should have one input (coinbase)
  should.equal(list.length(coinbase.inputs), 1)

  // Should have one output (no witness commitment)
  should.equal(list.length(coinbase.outputs), 1)

  // Input should be null prevout
  case coinbase.inputs {
    [input] -> {
      should.be_true(oni_bitcoin.outpoint_is_null(input.prevout))
    }
    _ -> should.fail()
  }

  // Output should have correct value
  case coinbase.outputs {
    [output] -> {
      let value = oni_bitcoin.amount_to_sats(output.value)
      should.equal(value, 5_000_000_000)
    }
    _ -> should.fail()
  }
}

pub fn create_coinbase_with_witness_commitment_test() {
  let output_script = oni_bitcoin.Script(<<0x76, 0xa9, 0x14>>)
  let commitment = <<1:256>>
  // Fake witness commitment

  let coinbase =
    block_template.create_coinbase(
      100,
      5_000_000_000,
      output_script,
      Some(commitment),
    )

  // Should have two outputs (main + witness commitment)
  should.equal(list.length(coinbase.outputs), 2)

  // Second output should be OP_RETURN with 0 value
  case coinbase.outputs {
    [_main_output, witness_output] -> {
      let value = oni_bitcoin.amount_to_sats(witness_output.value)
      should.equal(value, 0)
    }
    _ -> should.fail()
  }
}

pub fn create_coinbase_version_test() {
  let output_script = oni_bitcoin.Script(<<>>)
  let coinbase = block_template.create_coinbase(100, 1000, output_script, None)

  // Should be version 2 (BIP34)
  should.equal(coinbase.version, 2)
}

// ============================================================================
// Transaction Selection Tests
// ============================================================================

pub fn select_transactions_empty_mempool_test() {
  let pool = mempool.mempool_new()

  let #(txs, weight, sigops, fees) =
    block_template.select_transactions(pool, 4_000_000)

  should.equal(txs, [])
  should.equal(weight, 0)
  should.equal(sigops, 0)
  should.equal(fees, 0)
}

// ============================================================================
// Template Creation Tests
// ============================================================================

pub fn create_template_empty_mempool_test() {
  let pool = mempool.mempool_new()

  // Create minimal genesis hash for testing
  let genesis_hash = oni_bitcoin.BlockHash(oni_bitcoin.Hash256(<<0:256>>))

  let params =
    block_template.TemplateParams(
      prev_block_hash: genesis_hash,
      height: 1,
      cur_time: 1_234_567_890,
      bits: 0x1d00ffff,
      // Genesis difficulty
      coinbase_address: None,
    )

  let template = block_template.create_template(pool, params)

  // Should have correct height
  should.equal(template.height, 1)

  // Should have no transactions (empty mempool)
  should.equal(template.transactions, [])

  // Should have coinbase value = subsidy (no fees)
  should.equal(template.coinbase_value, 5_000_000_000)

  // Total fees should be 0
  should.equal(template.total_fees, 0)
}

pub fn create_template_version_test() {
  let pool = mempool.mempool_new()
  let genesis_hash = oni_bitcoin.BlockHash(oni_bitcoin.Hash256(<<0:256>>))

  let params =
    block_template.TemplateParams(
      prev_block_hash: genesis_hash,
      height: 100,
      cur_time: 0,
      bits: 0x1d00ffff,
      coinbase_address: None,
    )

  let template = block_template.create_template(pool, params)

  // Version should be BIP9 versionbits base
  should.equal(template.version, 0x20000000)
}

pub fn create_template_prev_hash_test() {
  let pool = mempool.mempool_new()
  let prev_hash = oni_bitcoin.BlockHash(oni_bitcoin.Hash256(<<1:256>>))

  let params =
    block_template.TemplateParams(
      prev_block_hash: prev_hash,
      height: 500,
      cur_time: 0,
      bits: 0x1d00ffff,
      coinbase_address: None,
    )

  let template = block_template.create_template(pool, params)

  // Should preserve prev hash
  should.equal(template.prev_block_hash.hash.bytes, prev_hash.hash.bytes)
}

pub fn create_template_halved_subsidy_test() {
  let pool = mempool.mempool_new()
  let genesis_hash = oni_bitcoin.BlockHash(oni_bitcoin.Hash256(<<0:256>>))

  let params =
    block_template.TemplateParams(
      prev_block_hash: genesis_hash,
      height: 210_000,
      // First halving
      cur_time: 0,
      bits: 0x1d00ffff,
      coinbase_address: None,
    )

  let template = block_template.create_template(pool, params)

  // Coinbase should be 25 BTC (halved)
  should.equal(template.coinbase_value, 2_500_000_000)
}

// ============================================================================
// Helper Import
// ============================================================================

import gleam/list
