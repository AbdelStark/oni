// Tests for fee estimation module

import gleeunit
import gleeunit/should
import fees

pub fn main() {
  gleeunit.main()
}

// ============================================================================
// Fee Rate Tests
// ============================================================================

pub fn fee_rate_creation_test() {
  let rate = fees.fee_rate(10.0)
  fees.fee_rate_sat_vb(rate) |> should.equal(10.0)
}

pub fn fee_rate_negative_clamp_test() {
  // Negative rates should be clamped to 0
  let rate = fees.fee_rate(-5.0)
  fees.fee_rate_sat_vb(rate) |> should.equal(0.0)
}

pub fn fee_rate_btc_kvb_test() {
  // 1 sat/vB = 0.00001 BTC/kvB
  let rate = fees.fee_rate(1.0)
  let btc_kvb = fees.fee_rate_btc_kvb(rate)

  // Should be 0.00001
  { btc_kvb >. 0.0 && btc_kvb <. 0.0001 } |> should.be_true
}

pub fn calculate_fee_test() {
  // 10 sat/vB for 100 vB transaction = 1000 sats
  let rate = fees.fee_rate(10.0)
  let fee = fees.calculate_fee(rate, 100)

  fee |> should.equal(1000)
}

pub fn calculate_fee_ceiling_test() {
  // Fractional fees should be rounded up
  let rate = fees.fee_rate(1.5)
  let fee = fees.calculate_fee(rate, 3)

  // 1.5 * 3 = 4.5, ceiling = 5
  fee |> should.equal(5)
}

pub fn fee_rate_compare_test() {
  let low = fees.fee_rate(5.0)
  let high = fees.fee_rate(10.0)

  fees.fee_rate_compare(low, high) |> should.equal(-1)
  fees.fee_rate_compare(high, low) |> should.equal(1)
  fees.fee_rate_compare(low, low) |> should.equal(0)
}

pub fn min_relay_fee_test() {
  let min_fee = fees.min_relay_fee()
  let sat_vb = fees.fee_rate_sat_vb(min_fee)

  // Should be at least 1 sat/vB
  { sat_vb >=. 1.0 } |> should.be_true
}

// ============================================================================
// Fee Estimator Tests
// ============================================================================

pub fn estimator_new_test() {
  let estimator = fees.estimator_new()

  // Should have empty history
  estimator.history_size |> should.equal(0)
}

pub fn record_confirmed_test() {
  let estimator = fees.estimator_new()
  let rate = fees.fee_rate(50.0)

  let updated = fees.record_confirmed(estimator, rate, 1)

  // Estimator should be updated (history not changed since this is per-tx)
  updated.history_size |> should.equal(0)
}

pub fn record_failed_test() {
  let estimator = fees.estimator_new()
  let rate = fees.fee_rate(10.0)

  let updated = fees.record_failed(estimator, rate, 6)

  // Should not crash
  updated.history_size |> should.equal(0)
}

pub fn decay_data_test() {
  let estimator = fees.estimator_new()
  let decayed = fees.decay_data(estimator)

  // History size should increase
  decayed.history_size |> should.equal(1)
}

// ============================================================================
// Fee Estimation Tests
// ============================================================================

pub fn estimate_smart_fee_default_test() {
  // With no data, should return a default estimate
  let estimator = fees.estimator_new()
  let estimate = fees.estimate_smart_fee(estimator, 6, fees.Conservative)

  // Should return a non-zero rate
  let rate = fees.fee_rate_sat_vb(estimate.fee_rate)
  { rate >. 0.0 } |> should.be_true

  // Confidence should be 0 (using defaults)
  estimate.confidence |> should.equal(0.0)
}

pub fn estimate_smart_fee_short_target_test() {
  let estimator = fees.estimator_new()

  // Short target (1-2 blocks) should give higher fee
  let short_est = fees.estimate_smart_fee(estimator, 1, fees.Conservative)
  let long_est = fees.estimate_smart_fee(estimator, 144, fees.Conservative)

  let short_rate = fees.fee_rate_sat_vb(short_est.fee_rate)
  let long_rate = fees.fee_rate_sat_vb(long_est.fee_rate)

  // Shorter target should have higher fee (or equal for defaults)
  { short_rate >=. long_rate } |> should.be_true
}

pub fn estimate_mode_affects_fee_test() {
  let estimator = fees.estimator_new()

  let conservative = fees.estimate_smart_fee(estimator, 6, fees.Conservative)
  let economical = fees.estimate_smart_fee(estimator, 6, fees.Economical)

  // Both should return valid estimates
  let cons_rate = fees.fee_rate_sat_vb(conservative.fee_rate)
  let econ_rate = fees.fee_rate_sat_vb(economical.fee_rate)

  { cons_rate >. 0.0 } |> should.be_true
  { econ_rate >. 0.0 } |> should.be_true
}

// ============================================================================
// Fee Histogram Tests
// ============================================================================

pub fn build_histogram_empty_test() {
  let histogram = fees.build_histogram([])

  // Should return empty buckets
  histogram |> should.not_equal([])
}

pub fn build_histogram_with_txs_test() {
  // Create some test transactions (fee in sats, vsize)
  let txs = [
    #(1000, 100),   // 10 sat/vB
    #(2000, 100),   // 20 sat/vB
    #(5000, 100),   // 50 sat/vB
    #(10000, 100),  // 100 sat/vB
  ]

  let histogram = fees.build_histogram(txs)

  // Should have multiple buckets
  histogram |> should.not_equal([])
}

// ============================================================================
// Mempool Stats Tests
// ============================================================================

pub fn calculate_mempool_stats_empty_test() {
  let stats = fees.calculate_mempool_stats([])

  stats.tx_count |> should.equal(0)
  stats.total_fees |> should.equal(0)
  stats.total_vsize |> should.equal(0)
}

pub fn calculate_mempool_stats_test() {
  let txs = [
    #(1000, 100),   // 10 sat/vB
    #(2000, 200),   // 10 sat/vB
    #(3000, 100),   // 30 sat/vB
  ]

  let stats = fees.calculate_mempool_stats(txs)

  stats.tx_count |> should.equal(3)
  stats.total_fees |> should.equal(6000)
  stats.total_vsize |> should.equal(400)
}

pub fn calculate_mempool_stats_min_max_test() {
  let txs = [
    #(100, 100),    // 1 sat/vB (min)
    #(1000, 100),   // 10 sat/vB
    #(5000, 100),   // 50 sat/vB (max)
  ]

  let stats = fees.calculate_mempool_stats(txs)

  let min_rate = fees.fee_rate_sat_vb(stats.min_fee_rate)
  let max_rate = fees.fee_rate_sat_vb(stats.max_fee_rate)

  { min_rate >=. 1.0 && min_rate <=. 2.0 } |> should.be_true
  { max_rate >=. 49.0 && max_rate <=. 51.0 } |> should.be_true
}

// ============================================================================
// Estimate Mode Tests
// ============================================================================

pub fn parse_estimate_mode_test() {
  fees.parse_estimate_mode("economical") |> should.equal(fees.Economical)
  fees.parse_estimate_mode("ECONOMICAL") |> should.equal(fees.Economical)
  fees.parse_estimate_mode("conservative") |> should.equal(fees.Conservative)
  fees.parse_estimate_mode("CONSERVATIVE") |> should.equal(fees.Conservative)
  fees.parse_estimate_mode("unknown") |> should.equal(fees.Unset)
}

pub fn estimate_mode_to_string_test() {
  fees.estimate_mode_to_string(fees.Economical) |> should.equal("ECONOMICAL")
  fees.estimate_mode_to_string(fees.Conservative) |> should.equal("CONSERVATIVE")
  fees.estimate_mode_to_string(fees.Unset) |> should.equal("UNSET")
}
