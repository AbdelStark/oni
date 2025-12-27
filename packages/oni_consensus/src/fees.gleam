// fees.gleam - Fee estimation for Bitcoin transactions
//
// This module provides fee estimation functionality:
// - Fee rate tracking from confirmed transactions
// - Smart fee estimation based on target confirmation time
// - Fee histogram for mempool analysis
// - Minimum relay fee handling

import gleam/dict.{type Dict}
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}

// ============================================================================
// Constants
// ============================================================================

/// Minimum relay fee in satoshis per vbyte
pub const min_relay_fee_sat_vb = 1

/// Default fee rate if no estimate is available (sat/vB)
pub const default_fee_rate = 10

/// Maximum target blocks for estimation
pub const max_target_blocks = 1008

/// Minimum target blocks for estimation
pub const min_target_blocks = 1

/// Number of buckets for fee tracking
const num_fee_buckets = 40

/// Bucket boundary multiplier
const bucket_multiplier = 1.1

/// Decay rate for old data (per block)
const decay_rate = 0.998

/// Minimum successful data points for estimation
const min_data_points = 10

// ============================================================================
// Types
// ============================================================================

/// Fee rate in satoshis per virtual byte
pub type FeeRate {
  FeeRate(sat_per_vbyte: Float)
}

/// Fee estimation result
pub type FeeEstimate {
  FeeEstimate(
    /// Estimated fee rate (sat/vB)
    fee_rate: FeeRate,
    /// Confidence level (0.0 to 1.0)
    confidence: Float,
    /// Data points used for estimation
    data_points: Int,
    /// Target confirmation blocks
    target_blocks: Int,
  )
}

/// Fee estimation mode
pub type EstimateMode {
  /// Economical - lower fee, longer confirmation time
  Economical
  /// Conservative - higher fee, shorter confirmation time
  Conservative
  /// Unset - use default behavior
  Unset
}

/// Fee bucket for tracking transaction confirmations
pub type FeeBucket {
  FeeBucket(
    /// Lower bound of fee rate for this bucket
    start_range: Float,
    /// Upper bound of fee rate for this bucket
    end_range: Float,
    /// Weighted sum of transactions that confirmed
    confirmed: Float,
    /// Weighted sum of transactions that failed to confirm
    failed: Float,
    /// Number of data points
    data_points: Int,
  )
}

/// Fee estimator state
pub type FeeEstimator {
  FeeEstimator(
    /// Buckets for each target confirmation level
    /// Key: target blocks, Value: list of fee buckets
    buckets: Dict(Int, List(FeeBucket)),
    /// Current block height
    current_height: Int,
    /// Number of historical blocks processed
    history_size: Int,
    /// Last updated timestamp
    last_updated: Int,
  )
}

// ============================================================================
// Fee Rate Operations
// ============================================================================

/// Create a fee rate from sat/vB
pub fn fee_rate(sat_per_vbyte: Float) -> FeeRate {
  let clamped = case sat_per_vbyte <. 0.0 {
    True -> 0.0
    False -> sat_per_vbyte
  }
  FeeRate(clamped)
}

/// Create a fee rate from sat/byte (convert to vB)
pub fn fee_rate_from_sat_byte(sat_per_byte: Float) -> FeeRate {
  // For non-segwit txs, vbyte = byte
  // For segwit, vbyte < byte, so sat/vB > sat/byte
  FeeRate(sat_per_byte)
}

/// Get fee rate as sat/vB
pub fn fee_rate_sat_vb(rate: FeeRate) -> Float {
  rate.sat_per_vbyte
}

/// Get fee rate as BTC/kvB
pub fn fee_rate_btc_kvb(rate: FeeRate) -> Float {
  rate.sat_per_vbyte *. 1000.0 /. 100_000_000.0
}

/// Calculate fee for a transaction of given vsize
pub fn calculate_fee(rate: FeeRate, vsize: Int) -> Int {
  let fee = rate.sat_per_vbyte *. int.to_float(vsize)
  float.ceiling(fee) |> float.truncate
}

/// Compare two fee rates
pub fn fee_rate_compare(a: FeeRate, b: FeeRate) -> Int {
  case a.sat_per_vbyte <. b.sat_per_vbyte {
    True -> -1
    False -> {
      case a.sat_per_vbyte >. b.sat_per_vbyte {
        True -> 1
        False -> 0
      }
    }
  }
}

/// Get minimum relay fee rate
pub fn min_relay_fee() -> FeeRate {
  FeeRate(int.to_float(min_relay_fee_sat_vb))
}

// ============================================================================
// Fee Estimator Operations
// ============================================================================

/// Create a new fee estimator
pub fn estimator_new() -> FeeEstimator {
  // Initialize buckets for common target confirmations
  let targets = [1, 2, 3, 4, 5, 6, 10, 12, 24, 48, 144, 504, 1008]

  let buckets = list.fold(targets, dict.new(), fn(acc, target) {
    dict.insert(acc, target, create_fee_buckets())
  })

  FeeEstimator(
    buckets: buckets,
    current_height: 0,
    history_size: 0,
    last_updated: 0,
  )
}

/// Create initial fee buckets
fn create_fee_buckets() -> List(FeeBucket) {
  create_buckets_recursive(1.0, num_fee_buckets, [])
}

fn create_buckets_recursive(
  start: Float,
  remaining: Int,
  acc: List(FeeBucket),
) -> List(FeeBucket) {
  case remaining {
    0 -> list.reverse(acc)
    _ -> {
      let end = start *. bucket_multiplier
      let bucket = FeeBucket(
        start_range: start,
        end_range: end,
        confirmed: 0.0,
        failed: 0.0,
        data_points: 0,
      )
      create_buckets_recursive(end, remaining - 1, [bucket, ..acc])
    }
  }
}

/// Record a confirmed transaction
pub fn record_confirmed(
  estimator: FeeEstimator,
  fee_rate: FeeRate,
  confirmation_blocks: Int,
) -> FeeEstimator {
  let rate = fee_rate.sat_per_vbyte

  // Update all applicable target buckets
  let new_buckets = dict.fold(estimator.buckets, estimator.buckets, fn(acc, target, buckets) {
    case confirmation_blocks <= target {
      True -> {
        // This tx confirmed within target, record success
        let updated = update_bucket_confirmed(buckets, rate)
        dict.insert(acc, target, updated)
      }
      False -> acc
    }
  })

  FeeEstimator(..estimator, buckets: new_buckets)
}

fn update_bucket_confirmed(
  buckets: List(FeeBucket),
  rate: Float,
) -> List(FeeBucket) {
  list.map(buckets, fn(bucket) {
    case rate >=. bucket.start_range && rate <. bucket.end_range {
      True -> FeeBucket(
        ..bucket,
        confirmed: bucket.confirmed +. 1.0,
        data_points: bucket.data_points + 1,
      )
      False -> bucket
    }
  })
}

/// Record a failed transaction (didn't confirm in expected time)
pub fn record_failed(
  estimator: FeeEstimator,
  fee_rate: FeeRate,
  target_blocks: Int,
) -> FeeEstimator {
  let rate = fee_rate.sat_per_vbyte

  case dict.get(estimator.buckets, target_blocks) {
    Error(_) -> estimator
    Ok(buckets) -> {
      let updated = update_bucket_failed(buckets, rate)
      let new_buckets = dict.insert(estimator.buckets, target_blocks, updated)
      FeeEstimator(..estimator, buckets: new_buckets)
    }
  }
}

fn update_bucket_failed(
  buckets: List(FeeBucket),
  rate: Float,
) -> List(FeeBucket) {
  list.map(buckets, fn(bucket) {
    case rate >=. bucket.start_range && rate <. bucket.end_range {
      True -> FeeBucket(..bucket, failed: bucket.failed +. 1.0)
      False -> bucket
    }
  })
}

/// Apply decay to historical data (called on each new block)
pub fn decay_data(estimator: FeeEstimator) -> FeeEstimator {
  let new_buckets = dict.map_values(estimator.buckets, fn(_target, buckets) {
    list.map(buckets, fn(bucket) {
      FeeBucket(
        ..bucket,
        confirmed: bucket.confirmed *. decay_rate,
        failed: bucket.failed *. decay_rate,
      )
    })
  })

  FeeEstimator(
    ..estimator,
    buckets: new_buckets,
    history_size: estimator.history_size + 1,
  )
}

/// Estimate fee for target confirmation blocks
pub fn estimate_fee(
  estimator: FeeEstimator,
  target_blocks: Int,
  mode: EstimateMode,
) -> Option(FeeEstimate) {
  // Clamp target to valid range
  let clamped_target = case target_blocks < min_target_blocks {
    True -> min_target_blocks
    False -> {
      case target_blocks > max_target_blocks {
        True -> max_target_blocks
        False -> target_blocks
      }
    }
  }

  // Find the closest target we have data for
  let actual_target = find_closest_target(estimator, clamped_target)

  case dict.get(estimator.buckets, actual_target) {
    Error(_) -> None
    Ok(buckets) -> {
      // Find the bucket with good confirmation rate at desired confidence
      let confidence_threshold = case mode {
        Conservative -> 0.95
        Economical -> 0.85
        Unset -> 0.90
      }

      find_estimate_in_buckets(buckets, confidence_threshold, clamped_target)
    }
  }
}

fn find_closest_target(estimator: FeeEstimator, target: Int) -> Int {
  let targets = dict.keys(estimator.buckets)
  find_closest_in_list(targets, target, target)
}

fn find_closest_in_list(list: List(Int), target: Int, best: Int) -> Int {
  case list {
    [] -> best
    [head, ..tail] -> {
      let current_diff = int.absolute_value(head - target)
      let best_diff = int.absolute_value(best - target)
      let new_best = case current_diff < best_diff {
        True -> head
        False -> best
      }
      find_closest_in_list(tail, target, new_best)
    }
  }
}

fn find_estimate_in_buckets(
  buckets: List(FeeBucket),
  confidence: Float,
  target: Int,
) -> Option(FeeEstimate) {
  // Start from highest fee bucket and work down
  let sorted = list.sort(buckets, fn(a, b) {
    case a.start_range >. b.start_range {
      True -> -1
      False -> {
        case a.start_range <. b.start_range {
          True -> 1
          False -> 0
        }
      }
    }
  })

  find_estimate_recursive(sorted, confidence, target)
}

fn find_estimate_recursive(
  buckets: List(FeeBucket),
  min_confidence: Float,
  target: Int,
) -> Option(FeeEstimate) {
  case buckets {
    [] -> None
    [bucket, ..rest] -> {
      let total = bucket.confirmed +. bucket.failed
      let data_points = bucket.data_points

      case data_points >= min_data_points {
        False -> find_estimate_recursive(rest, min_confidence, target)
        True -> {
          let conf_rate = case total >. 0.0 {
            True -> bucket.confirmed /. total
            False -> 0.0
          }

          case conf_rate >=. min_confidence {
            True -> {
              // Found a bucket with sufficient confidence
              let mid_rate = { bucket.start_range +. bucket.end_range } /. 2.0
              Some(FeeEstimate(
                fee_rate: FeeRate(mid_rate),
                confidence: conf_rate,
                data_points: data_points,
                target_blocks: target,
              ))
            }
            False -> find_estimate_recursive(rest, min_confidence, target)
          }
        }
      }
    }
  }
}

/// Get smart fee estimate (fallback to defaults if no data)
pub fn estimate_smart_fee(
  estimator: FeeEstimator,
  target_blocks: Int,
  mode: EstimateMode,
) -> FeeEstimate {
  case estimate_fee(estimator, target_blocks, mode) {
    Some(estimate) -> estimate
    None -> {
      // Return a default estimate based on target
      let rate = case target_blocks {
        n if n <= 2 -> 50.0
        n if n <= 6 -> 30.0
        n if n <= 24 -> 15.0
        n if n <= 144 -> 5.0
        _ -> 2.0
      }

      FeeEstimate(
        fee_rate: FeeRate(rate),
        confidence: 0.0,  // No confidence - using defaults
        data_points: 0,
        target_blocks: target_blocks,
      )
    }
  }
}

// ============================================================================
// Fee Histogram
// ============================================================================

/// Entry in fee histogram
pub type HistogramEntry {
  HistogramEntry(
    fee_rate: FeeRate,
    count: Int,
    total_vsize: Int,
  )
}

/// Build a fee histogram from mempool data
pub fn build_histogram(
  tx_fees: List(#(Int, Int)),  // List of (fee_in_sats, vsize)
) -> List(HistogramEntry) {
  // Define histogram buckets (sat/vB ranges)
  let bucket_ranges = [1.0, 2.0, 5.0, 10.0, 20.0, 50.0, 100.0, 200.0, 500.0, 1000.0]

  build_histogram_recursive(tx_fees, bucket_ranges, [])
}

fn build_histogram_recursive(
  txs: List(#(Int, Int)),
  ranges: List(Float),
  acc: List(HistogramEntry),
) -> List(HistogramEntry) {
  case ranges {
    [] -> list.reverse(acc)
    [range, ..rest] -> {
      // Count transactions in this fee range
      let #(count, vsize) = count_in_range(txs, range)
      let entry = HistogramEntry(
        fee_rate: FeeRate(range),
        count: count,
        total_vsize: vsize,
      )
      build_histogram_recursive(txs, rest, [entry, ..acc])
    }
  }
}

fn count_in_range(
  txs: List(#(Int, Int)),
  min_rate: Float,
) -> #(Int, Int) {
  list.fold(txs, #(0, 0), fn(acc, tx) {
    let #(fee, vsize) = tx
    let rate = int.to_float(fee) /. int.to_float(vsize)
    case rate >=. min_rate {
      True -> #(acc.0 + 1, acc.1 + vsize)
      False -> acc
    }
  })
}

// ============================================================================
// Mempool Fee Analysis
// ============================================================================

/// Mempool fee statistics
pub type MempoolFeeStats {
  MempoolFeeStats(
    /// Minimum fee rate in mempool
    min_fee_rate: FeeRate,
    /// Maximum fee rate in mempool
    max_fee_rate: FeeRate,
    /// Median fee rate
    median_fee_rate: FeeRate,
    /// Mean fee rate
    mean_fee_rate: FeeRate,
    /// Total fees in satoshis
    total_fees: Int,
    /// Total vsize
    total_vsize: Int,
    /// Number of transactions
    tx_count: Int,
  )
}

/// Calculate fee statistics from mempool transactions
pub fn calculate_mempool_stats(
  tx_fees: List(#(Int, Int)),  // (fee, vsize)
) -> MempoolFeeStats {
  case tx_fees {
    [] -> MempoolFeeStats(
      min_fee_rate: FeeRate(0.0),
      max_fee_rate: FeeRate(0.0),
      median_fee_rate: FeeRate(0.0),
      mean_fee_rate: FeeRate(0.0),
      total_fees: 0,
      total_vsize: 0,
      tx_count: 0,
    )
    _ -> {
      // Calculate rates for each tx
      let rates = list.map(tx_fees, fn(tx) {
        let #(fee, vsize) = tx
        int.to_float(fee) /. int.to_float(vsize)
      })

      let sorted_rates = list.sort(rates, float.compare)

      let min_rate = case list.first(sorted_rates) {
        Ok(r) -> r
        Error(_) -> 0.0
      }

      let max_rate = case list.last(sorted_rates) {
        Ok(r) -> r
        Error(_) -> 0.0
      }

      let n = list.length(sorted_rates)
      let median_rate = case list.drop(sorted_rates, n / 2) {
        [m, ..] -> m
        [] -> 0.0
      }

      let sum_rates = list.fold(rates, 0.0, fn(acc, r) { acc +. r })
      let mean_rate = sum_rates /. int.to_float(n)

      let total_fees = list.fold(tx_fees, 0, fn(acc, tx) { acc + tx.0 })
      let total_vsize = list.fold(tx_fees, 0, fn(acc, tx) { acc + tx.1 })

      MempoolFeeStats(
        min_fee_rate: FeeRate(min_rate),
        max_fee_rate: FeeRate(max_rate),
        median_fee_rate: FeeRate(median_rate),
        mean_fee_rate: FeeRate(mean_rate),
        total_fees: total_fees,
        total_vsize: total_vsize,
        tx_count: n,
      )
    }
  }
}

// ============================================================================
// Parse Estimate Mode
// ============================================================================

/// Parse estimate mode from string
pub fn parse_estimate_mode(s: String) -> EstimateMode {
  case s {
    "economical" | "ECONOMICAL" -> Economical
    "conservative" | "CONSERVATIVE" -> Conservative
    _ -> Unset
  }
}

/// Estimate mode to string
pub fn estimate_mode_to_string(mode: EstimateMode) -> String {
  case mode {
    Economical -> "ECONOMICAL"
    Conservative -> "CONSERVATIVE"
    Unset -> "UNSET"
  }
}
