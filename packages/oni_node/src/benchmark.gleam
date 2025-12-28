// benchmark.gleam - Performance benchmarking infrastructure
//
// This module provides infrastructure for measuring and tracking performance
// of critical node operations. It enables:
// - Microbenchmarks for individual functions
// - Throughput measurement for validation pipelines
// - Latency histograms for RPC endpoints
// - Comparative benchmarks for optimization validation
//
// Usage:
//   1. Wrap operations with bench_operation to capture timing
//   2. Use bench_suite to run a set of benchmarks
//   3. Export results for analysis

import gleam/dict.{type Dict}
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}

// ============================================================================
// Types
// ============================================================================

/// A single benchmark result
pub type BenchResult {
  BenchResult(
    /// Name of the benchmark
    name: String,
    /// Number of iterations run
    iterations: Int,
    /// Total time in microseconds
    total_us: Int,
    /// Mean time per iteration in microseconds
    mean_us: Float,
    /// Minimum time in microseconds
    min_us: Int,
    /// Maximum time in microseconds
    max_us: Int,
    /// Standard deviation in microseconds
    std_dev_us: Float,
    /// Percentile timings (p50, p90, p99)
    percentiles: Percentiles,
    /// Operations per second
    ops_per_sec: Float,
  )
}

/// Percentile breakdown
pub type Percentiles {
  Percentiles(
    p50: Int,
    p90: Int,
    p95: Int,
    p99: Int,
  )
}

/// Benchmark suite containing multiple benchmarks
pub type BenchSuite {
  BenchSuite(
    /// Suite name
    name: String,
    /// Individual benchmark results
    results: List(BenchResult),
    /// Total suite duration in microseconds
    total_duration_us: Int,
    /// Timestamp when suite was run
    timestamp: Int,
  )
}

/// Configuration for running benchmarks
pub type BenchConfig {
  BenchConfig(
    /// Number of warmup iterations (not counted)
    warmup_iterations: Int,
    /// Number of measured iterations
    iterations: Int,
    /// Minimum time to run in microseconds (overrides iterations)
    min_time_us: Int,
  )
}

/// Default benchmark configuration
pub fn default_config() -> BenchConfig {
  BenchConfig(
    warmup_iterations: 100,
    iterations: 1000,
    min_time_us: 1_000_000,  // 1 second minimum
  )
}

/// Quick benchmark configuration for development
pub fn quick_config() -> BenchConfig {
  BenchConfig(
    warmup_iterations: 10,
    iterations: 100,
    min_time_us: 100_000,  // 100ms minimum
  )
}

/// Throughput tracker for continuous operations
pub type ThroughputTracker {
  ThroughputTracker(
    /// Name of the operation being tracked
    name: String,
    /// Start time in microseconds
    start_us: Int,
    /// Number of operations completed
    operations: Int,
    /// Bytes processed (if applicable)
    bytes_processed: Int,
    /// Last sample time
    last_sample_us: Int,
    /// Samples of ops/sec over time
    samples: List(Float),
  )
}

/// Latency histogram for tracking response times
pub type LatencyHistogram {
  LatencyHistogram(
    /// Name of the operation
    name: String,
    /// Bucket boundaries in microseconds
    buckets: List(Int),
    /// Count in each bucket
    counts: List(Int),
    /// Total observations
    total_count: Int,
    /// Sum of all values
    sum_us: Int,
  )
}

// ============================================================================
// Benchmarking Functions
// ============================================================================

/// Run a single benchmark
pub fn run_bench(
  name: String,
  config: BenchConfig,
  operation: fn() -> a,
) -> BenchResult {
  // Warmup
  run_iterations(operation, config.warmup_iterations)

  // Measure
  let timings = measure_iterations(operation, config.iterations)

  // Calculate statistics
  calculate_stats(name, timings)
}

/// Run multiple iterations and collect timings
fn measure_iterations(
  operation: fn() -> a,
  count: Int,
) -> List(Int) {
  measure_iterations_loop(operation, count, [])
}

fn measure_iterations_loop(
  operation: fn() -> a,
  remaining: Int,
  acc: List(Int),
) -> List(Int) {
  case remaining <= 0 {
    True -> acc
    False -> {
      let start = monotonic_time_us()
      let _ = operation()
      let end = monotonic_time_us()
      let elapsed = end - start
      measure_iterations_loop(operation, remaining - 1, [elapsed, ..acc])
    }
  }
}

/// Run iterations without timing (for warmup)
fn run_iterations(operation: fn() -> a, count: Int) -> Nil {
  case count <= 0 {
    True -> Nil
    False -> {
      let _ = operation()
      run_iterations(operation, count - 1)
    }
  }
}

/// Calculate statistics from timing samples
fn calculate_stats(name: String, timings: List(Int)) -> BenchResult {
  let count = list.length(timings)
  let total = list.fold(timings, 0, fn(acc, t) { acc + t })
  let sorted = list.sort(timings, int.compare)

  let mean = case count > 0 {
    True -> int.to_float(total) /. int.to_float(count)
    False -> 0.0
  }

  let min_val = case sorted {
    [first, ..] -> first
    [] -> 0
  }

  let max_val = case list.last(sorted) {
    Ok(last) -> last
    Error(_) -> 0
  }

  let variance = case count > 1 {
    True -> {
      let sum_sq = list.fold(timings, 0.0, fn(acc, t) {
        let diff = int.to_float(t) -. mean
        acc +. diff *. diff
      })
      sum_sq /. int.to_float(count - 1)
    }
    False -> 0.0
  }

  let std_dev = float_sqrt(variance)

  let percentiles = calculate_percentiles(sorted, count)

  let ops_per_sec = case total > 0 {
    True -> int.to_float(count) /. { int.to_float(total) /. 1_000_000.0 }
    False -> 0.0
  }

  BenchResult(
    name: name,
    iterations: count,
    total_us: total,
    mean_us: mean,
    min_us: min_val,
    max_us: max_val,
    std_dev_us: std_dev,
    percentiles: percentiles,
    ops_per_sec: ops_per_sec,
  )
}

/// Calculate percentiles from sorted list
fn calculate_percentiles(sorted: List(Int), count: Int) -> Percentiles {
  let p50_idx = count * 50 / 100
  let p90_idx = count * 90 / 100
  let p95_idx = count * 95 / 100
  let p99_idx = count * 99 / 100

  Percentiles(
    p50: get_at_index(sorted, p50_idx),
    p90: get_at_index(sorted, p90_idx),
    p95: get_at_index(sorted, p95_idx),
    p99: get_at_index(sorted, p99_idx),
  )
}

/// Get element at index (0-based)
fn get_at_index(list: List(Int), index: Int) -> Int {
  get_at_index_loop(list, index)
}

fn get_at_index_loop(list: List(Int), index: Int) -> Int {
  case list {
    [] -> 0
    [head, ..tail] -> {
      case index <= 0 {
        True -> head
        False -> get_at_index_loop(tail, index - 1)
      }
    }
  }
}

// ============================================================================
// Benchmark Suite
// ============================================================================

/// Run a suite of benchmarks
pub fn run_suite(
  name: String,
  config: BenchConfig,
  benchmarks: List(#(String, fn() -> a)),
) -> BenchSuite {
  let start = monotonic_time_us()

  let results = list.map(benchmarks, fn(bench) {
    let #(bench_name, operation) = bench
    run_bench(bench_name, config, operation)
  })

  let end = monotonic_time_us()

  BenchSuite(
    name: name,
    results: results,
    total_duration_us: end - start,
    timestamp: wall_clock_time_seconds(),
  )
}

// ============================================================================
// Throughput Tracking
// ============================================================================

/// Create a new throughput tracker
pub fn throughput_start(name: String) -> ThroughputTracker {
  let now = monotonic_time_us()
  ThroughputTracker(
    name: name,
    start_us: now,
    operations: 0,
    bytes_processed: 0,
    last_sample_us: now,
    samples: [],
  )
}

/// Record an operation completion
pub fn throughput_record(
  tracker: ThroughputTracker,
  bytes: Int,
) -> ThroughputTracker {
  ThroughputTracker(
    ..tracker,
    operations: tracker.operations + 1,
    bytes_processed: tracker.bytes_processed + bytes,
  )
}

/// Sample current throughput
pub fn throughput_sample(tracker: ThroughputTracker) -> ThroughputTracker {
  let now = monotonic_time_us()
  let elapsed_us = now - tracker.last_sample_us

  case elapsed_us > 0 {
    False -> tracker
    True -> {
      let ops_per_sec = int.to_float(tracker.operations) /. { int.to_float(elapsed_us) /. 1_000_000.0 }
      ThroughputTracker(
        ..tracker,
        last_sample_us: now,
        samples: [ops_per_sec, ..tracker.samples],
      )
    }
  }
}

/// Get final throughput stats
pub fn throughput_finish(tracker: ThroughputTracker) -> ThroughputStats {
  let now = monotonic_time_us()
  let total_us = now - tracker.start_us

  let ops_per_sec = case total_us > 0 {
    True -> int.to_float(tracker.operations) /. { int.to_float(total_us) /. 1_000_000.0 }
    False -> 0.0
  }

  let bytes_per_sec = case total_us > 0 {
    True -> int.to_float(tracker.bytes_processed) /. { int.to_float(total_us) /. 1_000_000.0 }
    False -> 0.0
  }

  ThroughputStats(
    name: tracker.name,
    total_operations: tracker.operations,
    total_bytes: tracker.bytes_processed,
    duration_us: total_us,
    ops_per_sec: ops_per_sec,
    bytes_per_sec: bytes_per_sec,
    mb_per_sec: bytes_per_sec /. 1_000_000.0,
  )
}

/// Throughput statistics
pub type ThroughputStats {
  ThroughputStats(
    name: String,
    total_operations: Int,
    total_bytes: Int,
    duration_us: Int,
    ops_per_sec: Float,
    bytes_per_sec: Float,
    mb_per_sec: Float,
  )
}

// ============================================================================
// Latency Histogram
// ============================================================================

/// Create a latency histogram with default buckets
pub fn histogram_new(name: String) -> LatencyHistogram {
  // Default buckets: 1us, 10us, 100us, 1ms, 10ms, 100ms, 1s, 10s
  let buckets = [1, 10, 100, 1000, 10_000, 100_000, 1_000_000, 10_000_000]
  let counts = list.map(buckets, fn(_) { 0 })

  LatencyHistogram(
    name: name,
    buckets: buckets,
    counts: [0, ..counts],  // +1 for overflow bucket
    total_count: 0,
    sum_us: 0,
  )
}

/// Create a histogram with custom buckets
pub fn histogram_with_buckets(name: String, buckets: List(Int)) -> LatencyHistogram {
  let counts = list.map([0, ..buckets], fn(_) { 0 })

  LatencyHistogram(
    name: name,
    buckets: buckets,
    counts: counts,
    total_count: 0,
    sum_us: 0,
  )
}

/// Observe a value
pub fn histogram_observe(
  histogram: LatencyHistogram,
  value_us: Int,
) -> LatencyHistogram {
  let bucket_idx = find_bucket_index(histogram.buckets, value_us, 0)
  let new_counts = increment_at_index(histogram.counts, bucket_idx)

  LatencyHistogram(
    ..histogram,
    counts: new_counts,
    total_count: histogram.total_count + 1,
    sum_us: histogram.sum_us + value_us,
  )
}

fn find_bucket_index(buckets: List(Int), value: Int, index: Int) -> Int {
  case buckets {
    [] -> index
    [bound, ..rest] -> {
      case value <= bound {
        True -> index
        False -> find_bucket_index(rest, value, index + 1)
      }
    }
  }
}

fn increment_at_index(list: List(Int), index: Int) -> List(Int) {
  increment_at_index_loop(list, index, [])
}

fn increment_at_index_loop(
  list: List(Int),
  index: Int,
  acc: List(Int),
) -> List(Int) {
  case list {
    [] -> list.reverse(acc)
    [head, ..tail] -> {
      case index == 0 {
        True -> list.append(list.reverse([head + 1, ..acc]), tail)
        False -> increment_at_index_loop(tail, index - 1, [head, ..acc])
      }
    }
  }
}

/// Get histogram statistics
pub fn histogram_stats(histogram: LatencyHistogram) -> HistogramStats {
  let mean = case histogram.total_count > 0 {
    True -> int.to_float(histogram.sum_us) /. int.to_float(histogram.total_count)
    False -> 0.0
  }

  HistogramStats(
    name: histogram.name,
    count: histogram.total_count,
    sum_us: histogram.sum_us,
    mean_us: mean,
    buckets: list.zip(histogram.buckets, list.drop(histogram.counts, 1)),
  )
}

/// Histogram statistics
pub type HistogramStats {
  HistogramStats(
    name: String,
    count: Int,
    sum_us: Int,
    mean_us: Float,
    buckets: List(#(Int, Int)),  // (bucket_bound, count)
  )
}

// ============================================================================
// Comparison Benchmarks
// ============================================================================

/// Compare two implementations
pub fn compare(
  name: String,
  config: BenchConfig,
  baseline: fn() -> a,
  candidate: fn() -> b,
) -> Comparison {
  let baseline_result = run_bench(name <> "_baseline", config, baseline)
  let candidate_result = run_bench(name <> "_candidate", config, candidate)

  let speedup = case candidate_result.mean_us > 0.0 {
    True -> baseline_result.mean_us /. candidate_result.mean_us
    False -> 0.0
  }

  Comparison(
    name: name,
    baseline: baseline_result,
    candidate: candidate_result,
    speedup: speedup,
    improvement_percent: { speedup -. 1.0 } *. 100.0,
  )
}

/// Comparison result between two implementations
pub type Comparison {
  Comparison(
    name: String,
    baseline: BenchResult,
    candidate: BenchResult,
    /// Speedup factor (>1 means candidate is faster)
    speedup: Float,
    /// Improvement percentage ((speedup - 1) * 100)
    improvement_percent: Float,
  )
}

// ============================================================================
// Result Formatting
// ============================================================================

/// Format a benchmark result for display
pub fn format_result(result: BenchResult) -> String {
  result.name <> ":\n" <>
  "  iterations: " <> int.to_string(result.iterations) <> "\n" <>
  "  mean: " <> format_duration_us(float.round(result.mean_us)) <> "\n" <>
  "  min: " <> format_duration_us(result.min_us) <> "\n" <>
  "  max: " <> format_duration_us(result.max_us) <> "\n" <>
  "  std_dev: " <> format_duration_us(float.round(result.std_dev_us)) <> "\n" <>
  "  p50: " <> format_duration_us(result.percentiles.p50) <> "\n" <>
  "  p99: " <> format_duration_us(result.percentiles.p99) <> "\n" <>
  "  ops/sec: " <> float_to_string_2dp(result.ops_per_sec)
}

/// Format a suite result
pub fn format_suite(suite: BenchSuite) -> String {
  let header = "=== " <> suite.name <> " ===\n" <>
    "Total duration: " <> format_duration_us(suite.total_duration_us) <> "\n\n"

  let results_str = list.map(suite.results, format_result)
    |> list.intersperse("\n")
    |> list.fold("", fn(acc, s) { acc <> s })

  header <> results_str
}

/// Format a comparison result
pub fn format_comparison(comp: Comparison) -> String {
  "=== " <> comp.name <> " Comparison ===\n" <>
  "Baseline: " <> format_duration_us(float.round(comp.baseline.mean_us)) <> " (mean)\n" <>
  "Candidate: " <> format_duration_us(float.round(comp.candidate.mean_us)) <> " (mean)\n" <>
  "Speedup: " <> float_to_string_2dp(comp.speedup) <> "x\n" <>
  "Improvement: " <> float_to_string_2dp(comp.improvement_percent) <> "%"
}

/// Format duration in microseconds for display
pub fn format_duration_us(us: Int) -> String {
  case us {
    u if u < 1000 -> int.to_string(u) <> "us"
    u if u < 1_000_000 -> int.to_string(u / 1000) <> "ms"
    u -> int.to_string(u / 1_000_000) <> "s"
  }
}

/// Format float to 2 decimal places
fn float_to_string_2dp(f: Float) -> String {
  let whole = float.truncate(f)
  let frac = float.truncate({ f -. int.to_float(whole) } *. 100.0)
  int.to_string(whole) <> "." <> pad_left(int.to_string(frac), 2, "0")
}

fn pad_left(s: String, len: Int, pad: String) -> String {
  case string_length(s) >= len {
    True -> s
    False -> pad_left(pad <> s, len, pad)
  }
}

// ============================================================================
// FFI / External Functions
// ============================================================================

/// Get monotonic time in microseconds
@external(erlang, "benchmark_ffi", "monotonic_time_us")
fn monotonic_time_us() -> Int

/// Get wall clock time in seconds
@external(erlang, "benchmark_ffi", "wall_clock_time_seconds")
fn wall_clock_time_seconds() -> Int

/// Calculate square root
@external(erlang, "math", "sqrt")
fn float_sqrt(x: Float) -> Float

/// Get string length
@external(erlang, "erlang", "length")
fn string_length(s: String) -> Int
