// metrics.gleam - Prometheus metrics for oni node
//
// This module provides Prometheus-compatible metrics collection and export.
// Metrics are exposed in the Prometheus text format for scraping.
//
// Metric types:
// - Counter: monotonically increasing values (requests, errors)
// - Gauge: values that can go up and down (connections, memory)
// - Histogram: distributions with configurable buckets (latencies)
//
// Usage:
//   1. Create a metrics registry with registry_new()
//   2. Register metrics using counter_new(), gauge_new(), histogram_new()
//   3. Update metrics using counter_inc(), gauge_set(), histogram_observe()
//   4. Export with export_prometheus()

import gleam/dict.{type Dict}
import gleam/float
import gleam/int
import gleam/list
import gleam/string

// ============================================================================
// Metric Types
// ============================================================================

/// A Prometheus counter (monotonically increasing)
pub type Counter {
  Counter(name: String, help: String, labels: Dict(String, String), value: Int)
}

/// A Prometheus gauge (can increase or decrease)
pub type Gauge {
  Gauge(name: String, help: String, labels: Dict(String, String), value: Float)
}

/// A Prometheus histogram bucket
pub type HistogramBucket {
  HistogramBucket(upper_bound: Float, count: Int)
}

/// A Prometheus histogram
pub type Histogram {
  Histogram(
    name: String,
    help: String,
    labels: Dict(String, String),
    buckets: List(HistogramBucket),
    sum: Float,
    count: Int,
  )
}

/// Metric wrapper type
pub type Metric {
  MetricCounter(Counter)
  MetricGauge(Gauge)
  MetricHistogram(Histogram)
}

// ============================================================================
// Metrics Registry
// ============================================================================

/// Registry holding all metrics
pub type MetricsRegistry {
  MetricsRegistry(metrics: Dict(String, Metric), prefix: String)
}

/// Create a new metrics registry
pub fn registry_new(prefix: String) -> MetricsRegistry {
  MetricsRegistry(metrics: dict.new(), prefix: prefix)
}

/// Create default oni metrics registry
pub fn default_registry() -> MetricsRegistry {
  registry_new("oni")
}

// ============================================================================
// Counter Operations
// ============================================================================

/// Create a new counter
pub fn counter_new(name: String, help: String) -> Counter {
  Counter(name: name, help: help, labels: dict.new(), value: 0)
}

/// Create a counter with labels
pub fn counter_with_labels(
  name: String,
  help: String,
  labels: Dict(String, String),
) -> Counter {
  Counter(name: name, help: help, labels: labels, value: 0)
}

/// Increment a counter by 1
pub fn counter_inc(counter: Counter) -> Counter {
  Counter(..counter, value: counter.value + 1)
}

/// Increment a counter by a specific amount
pub fn counter_add(counter: Counter, amount: Int) -> Counter {
  case amount > 0 {
    True -> Counter(..counter, value: counter.value + amount)
    False -> counter
    // Counters can only increase
  }
}

/// Get counter value
pub fn counter_value(counter: Counter) -> Int {
  counter.value
}

// ============================================================================
// Gauge Operations
// ============================================================================

/// Create a new gauge
pub fn gauge_new(name: String, help: String) -> Gauge {
  Gauge(name: name, help: help, labels: dict.new(), value: 0.0)
}

/// Create a gauge with labels
pub fn gauge_with_labels(
  name: String,
  help: String,
  labels: Dict(String, String),
) -> Gauge {
  Gauge(name: name, help: help, labels: labels, value: 0.0)
}

/// Set gauge value
pub fn gauge_set(gauge: Gauge, value: Float) -> Gauge {
  Gauge(..gauge, value: value)
}

/// Increment gauge by 1
pub fn gauge_inc(gauge: Gauge) -> Gauge {
  Gauge(..gauge, value: gauge.value +. 1.0)
}

/// Decrement gauge by 1
pub fn gauge_dec(gauge: Gauge) -> Gauge {
  Gauge(..gauge, value: gauge.value -. 1.0)
}

/// Add to gauge
pub fn gauge_add(gauge: Gauge, amount: Float) -> Gauge {
  Gauge(..gauge, value: gauge.value +. amount)
}

/// Get gauge value
pub fn gauge_value(gauge: Gauge) -> Float {
  gauge.value
}

// ============================================================================
// Histogram Operations
// ============================================================================

/// Default histogram buckets (for latency in seconds)
pub const default_buckets = [
  0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0,
]

/// Create a new histogram with default buckets
pub fn histogram_new(name: String, help: String) -> Histogram {
  histogram_with_buckets(name, help, default_buckets)
}

/// Create a histogram with custom buckets
pub fn histogram_with_buckets(
  name: String,
  help: String,
  bucket_bounds: List(Float),
) -> Histogram {
  let buckets =
    list.map(bucket_bounds, fn(bound) {
      HistogramBucket(upper_bound: bound, count: 0)
    })

  Histogram(
    name: name,
    help: help,
    labels: dict.new(),
    buckets: buckets,
    sum: 0.0,
    count: 0,
  )
}

/// Observe a value in the histogram
pub fn histogram_observe(histogram: Histogram, value: Float) -> Histogram {
  // Update buckets
  let new_buckets =
    list.map(histogram.buckets, fn(bucket) {
      case value <=. bucket.upper_bound {
        True -> HistogramBucket(..bucket, count: bucket.count + 1)
        False -> bucket
      }
    })

  Histogram(
    ..histogram,
    buckets: new_buckets,
    sum: histogram.sum +. value,
    count: histogram.count + 1,
  )
}

/// Get histogram count
pub fn histogram_count(histogram: Histogram) -> Int {
  histogram.count
}

/// Get histogram sum
pub fn histogram_sum(histogram: Histogram) -> Float {
  histogram.sum
}

// ============================================================================
// Registry Operations
// ============================================================================

/// Register a counter in the registry
pub fn register_counter(
  registry: MetricsRegistry,
  counter: Counter,
) -> MetricsRegistry {
  let key = registry.prefix <> "_" <> counter.name
  MetricsRegistry(
    ..registry,
    metrics: dict.insert(registry.metrics, key, MetricCounter(counter)),
  )
}

/// Register a gauge in the registry
pub fn register_gauge(
  registry: MetricsRegistry,
  gauge: Gauge,
) -> MetricsRegistry {
  let key = registry.prefix <> "_" <> gauge.name
  MetricsRegistry(
    ..registry,
    metrics: dict.insert(registry.metrics, key, MetricGauge(gauge)),
  )
}

/// Register a histogram in the registry
pub fn register_histogram(
  registry: MetricsRegistry,
  histogram: Histogram,
) -> MetricsRegistry {
  let key = registry.prefix <> "_" <> histogram.name
  MetricsRegistry(
    ..registry,
    metrics: dict.insert(registry.metrics, key, MetricHistogram(histogram)),
  )
}

/// Update a counter in the registry
pub fn update_counter(
  registry: MetricsRegistry,
  name: String,
  f: fn(Counter) -> Counter,
) -> MetricsRegistry {
  let key = registry.prefix <> "_" <> name
  case dict.get(registry.metrics, key) {
    Ok(MetricCounter(counter)) -> {
      let new_counter = f(counter)
      MetricsRegistry(
        ..registry,
        metrics: dict.insert(registry.metrics, key, MetricCounter(new_counter)),
      )
    }
    _ -> registry
  }
}

/// Update a gauge in the registry
pub fn update_gauge(
  registry: MetricsRegistry,
  name: String,
  f: fn(Gauge) -> Gauge,
) -> MetricsRegistry {
  let key = registry.prefix <> "_" <> name
  case dict.get(registry.metrics, key) {
    Ok(MetricGauge(gauge)) -> {
      let new_gauge = f(gauge)
      MetricsRegistry(
        ..registry,
        metrics: dict.insert(registry.metrics, key, MetricGauge(new_gauge)),
      )
    }
    _ -> registry
  }
}

/// Update a histogram in the registry
pub fn update_histogram(
  registry: MetricsRegistry,
  name: String,
  f: fn(Histogram) -> Histogram,
) -> MetricsRegistry {
  let key = registry.prefix <> "_" <> name
  case dict.get(registry.metrics, key) {
    Ok(MetricHistogram(histogram)) -> {
      let new_histogram = f(histogram)
      MetricsRegistry(
        ..registry,
        metrics: dict.insert(
          registry.metrics,
          key,
          MetricHistogram(new_histogram),
        ),
      )
    }
    _ -> registry
  }
}

// ============================================================================
// Prometheus Export
// ============================================================================

/// Export all metrics in Prometheus text format
pub fn export_prometheus(registry: MetricsRegistry) -> String {
  let entries = dict.to_list(registry.metrics)

  let lines =
    list.flat_map(entries, fn(entry) {
      let #(key, metric) = entry
      export_metric(key, metric)
    })

  string.join(lines, "\n")
}

/// Export a single metric
fn export_metric(name: String, metric: Metric) -> List(String) {
  case metric {
    MetricCounter(counter) -> export_counter(name, counter)
    MetricGauge(gauge) -> export_gauge(name, gauge)
    MetricHistogram(histogram) -> export_histogram(name, histogram)
  }
}

/// Export a counter
fn export_counter(name: String, counter: Counter) -> List(String) {
  let help_line = "# HELP " <> name <> " " <> counter.help
  let type_line = "# TYPE " <> name <> " counter"
  let value_line =
    format_metric_line(name, counter.labels, int.to_string(counter.value))

  [help_line, type_line, value_line]
}

/// Export a gauge
fn export_gauge(name: String, gauge: Gauge) -> List(String) {
  let help_line = "# HELP " <> name <> " " <> gauge.help
  let type_line = "# TYPE " <> name <> " gauge"
  let value_line =
    format_metric_line(name, gauge.labels, float.to_string(gauge.value))

  [help_line, type_line, value_line]
}

/// Export a histogram
fn export_histogram(name: String, histogram: Histogram) -> List(String) {
  let help_line = "# HELP " <> name <> " " <> histogram.help
  let type_line = "# TYPE " <> name <> " histogram"

  // Bucket lines
  let bucket_lines =
    list.map(histogram.buckets, fn(bucket) {
      let labels =
        dict.insert(histogram.labels, "le", float.to_string(bucket.upper_bound))
      format_metric_line(name <> "_bucket", labels, int.to_string(bucket.count))
    })

  // +Inf bucket (total count)
  let inf_labels = dict.insert(histogram.labels, "le", "+Inf")
  let inf_line =
    format_metric_line(
      name <> "_bucket",
      inf_labels,
      int.to_string(histogram.count),
    )

  // Sum and count lines
  let sum_line =
    format_metric_line(
      name <> "_sum",
      histogram.labels,
      float.to_string(histogram.sum),
    )
  let count_line =
    format_metric_line(
      name <> "_count",
      histogram.labels,
      int.to_string(histogram.count),
    )

  list.flatten([
    [help_line, type_line],
    bucket_lines,
    [inf_line, sum_line, count_line],
  ])
}

/// Format a single metric line with labels
fn format_metric_line(
  name: String,
  labels: Dict(String, String),
  value: String,
) -> String {
  case dict.size(labels) == 0 {
    True -> name <> " " <> value
    False -> {
      let label_pairs = dict.to_list(labels)
      let label_str =
        list.map(label_pairs, fn(pair) {
          let #(k, v) = pair
          k <> "=\"" <> escape_label_value(v) <> "\""
        })
        |> string.join(",")

      name <> "{" <> label_str <> "} " <> value
    }
  }
}

/// Escape label value for Prometheus format
fn escape_label_value(value: String) -> String {
  value
  |> string.replace("\\", "\\\\")
  |> string.replace("\"", "\\\"")
  |> string.replace("\n", "\\n")
}

// ============================================================================
// Predefined Metrics
// ============================================================================

/// Create a standard node metrics registry with common metrics
pub fn standard_node_metrics() -> MetricsRegistry {
  default_registry()
  // Blockchain metrics
  |> register_gauge(gauge_new("block_height", "Current blockchain height"))
  |> register_gauge(gauge_new("block_time", "Timestamp of the latest block"))
  |> register_gauge(gauge_new("difficulty", "Current mining difficulty"))
  |> register_gauge(gauge_new("chain_work", "Total accumulated proof of work"))
  // Mempool metrics
  |> register_gauge(gauge_new(
    "mempool_size",
    "Number of transactions in mempool",
  ))
  |> register_gauge(gauge_new(
    "mempool_bytes",
    "Total size of transactions in mempool",
  ))
  |> register_gauge(gauge_new("mempool_usage", "Memory usage of mempool"))
  |> register_counter(counter_new(
    "mempool_accepted_total",
    "Total transactions accepted to mempool",
  ))
  |> register_counter(counter_new(
    "mempool_rejected_total",
    "Total transactions rejected from mempool",
  ))
  // Network metrics
  |> register_gauge(gauge_new("peers_connected", "Number of connected peers"))
  |> register_gauge(gauge_new(
    "peers_inbound",
    "Number of inbound peer connections",
  ))
  |> register_gauge(gauge_new(
    "peers_outbound",
    "Number of outbound peer connections",
  ))
  |> register_counter(counter_new(
    "bytes_sent_total",
    "Total bytes sent to peers",
  ))
  |> register_counter(counter_new(
    "bytes_received_total",
    "Total bytes received from peers",
  ))
  |> register_counter(counter_new(
    "messages_sent_total",
    "Total P2P messages sent",
  ))
  |> register_counter(counter_new(
    "messages_received_total",
    "Total P2P messages received",
  ))
  // Sync metrics
  |> register_gauge(gauge_new("headers_height", "Height of headers chain"))
  |> register_gauge(gauge_new("sync_progress", "IBD sync progress (0.0-1.0)"))
  |> register_gauge(gauge_new("blocks_behind", "Number of blocks behind tip"))
  // RPC metrics
  |> register_counter(counter_new("rpc_requests_total", "Total RPC requests"))
  |> register_counter(counter_new("rpc_errors_total", "Total RPC errors"))
  |> register_histogram(histogram_new(
    "rpc_request_duration_seconds",
    "RPC request latency",
  ))
  // Validation metrics
  |> register_counter(counter_new(
    "blocks_validated_total",
    "Total blocks validated",
  ))
  |> register_counter(counter_new(
    "transactions_validated_total",
    "Total transactions validated",
  ))
  |> register_histogram(histogram_new(
    "block_validation_duration_seconds",
    "Block validation latency",
  ))
  |> register_histogram(histogram_new(
    "tx_validation_duration_seconds",
    "Transaction validation latency",
  ))
  // Cache metrics
  |> register_gauge(gauge_new("sig_cache_size", "Size of signature cache"))
  |> register_gauge(gauge_new("sig_cache_hit_rate", "Signature cache hit rate"))
  |> register_gauge(gauge_new("script_cache_size", "Size of script cache"))
  |> register_gauge(gauge_new("script_cache_hit_rate", "Script cache hit rate"))
  // Process metrics
  |> register_gauge(gauge_new("uptime_seconds", "Node uptime in seconds"))
  |> register_gauge(gauge_new("process_memory_bytes", "Memory usage in bytes"))
  |> register_gauge(gauge_new(
    "process_open_fds",
    "Number of open file descriptors",
  ))
}

// ============================================================================
// Metric Snapshot
// ============================================================================

/// Snapshot of current metrics for reporting
pub type MetricsSnapshot {
  MetricsSnapshot(
    block_height: Int,
    mempool_size: Int,
    peers_connected: Int,
    sync_progress: Float,
    uptime_seconds: Int,
    rpc_requests: Int,
    blocks_validated: Int,
    sig_cache_hit_rate: Float,
  )
}

/// Create an empty snapshot
pub fn empty_snapshot() -> MetricsSnapshot {
  MetricsSnapshot(
    block_height: 0,
    mempool_size: 0,
    peers_connected: 0,
    sync_progress: 0.0,
    uptime_seconds: 0,
    rpc_requests: 0,
    blocks_validated: 0,
    sig_cache_hit_rate: 0.0,
  )
}

/// Format snapshot as JSON-like string
pub fn snapshot_to_json(snapshot: MetricsSnapshot) -> String {
  "{"
  <> "\"block_height\":"
  <> int.to_string(snapshot.block_height)
  <> ","
  <> "\"mempool_size\":"
  <> int.to_string(snapshot.mempool_size)
  <> ","
  <> "\"peers_connected\":"
  <> int.to_string(snapshot.peers_connected)
  <> ","
  <> "\"sync_progress\":"
  <> float.to_string(snapshot.sync_progress)
  <> ","
  <> "\"uptime_seconds\":"
  <> int.to_string(snapshot.uptime_seconds)
  <> ","
  <> "\"rpc_requests\":"
  <> int.to_string(snapshot.rpc_requests)
  <> ","
  <> "\"blocks_validated\":"
  <> int.to_string(snapshot.blocks_validated)
  <> ","
  <> "\"sig_cache_hit_rate\":"
  <> float.to_string(snapshot.sig_cache_hit_rate)
  <> "}"
}
