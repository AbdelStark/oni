// prometheus.gleam - Prometheus metrics export for oni node
//
// This module provides Prometheus-compatible metrics export:
// - /metrics HTTP endpoint
// - Standard metric types (counter, gauge, histogram)
// - Node operational metrics
// - Blockchain metrics
// - P2P network metrics
// - RPC metrics
//
// Metrics follow Prometheus naming conventions:
// https://prometheus.io/docs/practices/naming/

import gleam/dict.{type Dict}
import gleam/float
import gleam/int
import gleam/list
import gleam/string
import gleam/string_builder.{type StringBuilder}

// ============================================================================
// Metric Types
// ============================================================================

/// Metric type
pub type MetricType {
  Counter
  Gauge
  Histogram
  Summary
}

/// A single metric with optional labels
pub type Metric {
  Metric(
    name: String,
    help: String,
    metric_type: MetricType,
    values: List(MetricValue),
  )
}

/// A metric value with optional labels
pub type MetricValue {
  MetricValue(
    labels: Dict(String, String),
    value: Float,
  )
}

/// Histogram bucket
pub type HistogramBucket {
  HistogramBucket(
    le: Float,
    count: Int,
  )
}

/// Histogram metric value
pub type HistogramValue {
  HistogramValue(
    labels: Dict(String, String),
    buckets: List(HistogramBucket),
    sum: Float,
    count: Int,
  )
}

// ============================================================================
// Metric Registry
// ============================================================================

/// Metrics registry
pub type MetricsRegistry {
  MetricsRegistry(
    metrics: Dict(String, Metric),
    namespace: String,
  )
}

/// Create a new metrics registry
pub fn new_registry(namespace: String) -> MetricsRegistry {
  MetricsRegistry(
    metrics: dict.new(),
    namespace: namespace,
  )
}

/// Register a metric
pub fn register(
  registry: MetricsRegistry,
  name: String,
  help: String,
  metric_type: MetricType,
) -> MetricsRegistry {
  let full_name = registry.namespace <> "_" <> name
  let metric = Metric(
    name: full_name,
    help: help,
    metric_type: metric_type,
    values: [],
  )
  MetricsRegistry(
    ..registry,
    metrics: dict.insert(registry.metrics, full_name, metric),
  )
}

/// Set a metric value
pub fn set(
  registry: MetricsRegistry,
  name: String,
  value: Float,
  labels: Dict(String, String),
) -> MetricsRegistry {
  let full_name = registry.namespace <> "_" <> name
  case dict.get(registry.metrics, full_name) {
    Error(_) -> registry
    Ok(metric) -> {
      let new_value = MetricValue(labels: labels, value: value)
      let updated = Metric(..metric, values: [new_value])
      MetricsRegistry(
        ..registry,
        metrics: dict.insert(registry.metrics, full_name, updated),
      )
    }
  }
}

/// Increment a counter
pub fn inc(
  registry: MetricsRegistry,
  name: String,
  labels: Dict(String, String),
) -> MetricsRegistry {
  inc_by(registry, name, 1.0, labels)
}

/// Increment a counter by a specific amount
pub fn inc_by(
  registry: MetricsRegistry,
  name: String,
  amount: Float,
  labels: Dict(String, String),
) -> MetricsRegistry {
  let full_name = registry.namespace <> "_" <> name
  case dict.get(registry.metrics, full_name) {
    Error(_) -> registry
    Ok(metric) -> {
      let current = get_value(metric.values, labels)
      let new_value = MetricValue(labels: labels, value: current +. amount)
      let updated = Metric(..metric, values: update_value(metric.values, new_value))
      MetricsRegistry(
        ..registry,
        metrics: dict.insert(registry.metrics, full_name, updated),
      )
    }
  }
}

fn get_value(values: List(MetricValue), labels: Dict(String, String)) -> Float {
  case list.find(values, fn(v) { v.labels == labels }) {
    Ok(v) -> v.value
    Error(_) -> 0.0
  }
}

fn update_value(
  values: List(MetricValue),
  new_value: MetricValue,
) -> List(MetricValue) {
  case list.find(values, fn(v) { v.labels == new_value.labels }) {
    Ok(_) -> {
      list.map(values, fn(v) {
        case v.labels == new_value.labels {
          True -> new_value
          False -> v
        }
      })
    }
    Error(_) -> [new_value, ..values]
  }
}

// ============================================================================
// Prometheus Text Format Export
// ============================================================================

/// Export all metrics in Prometheus text format
pub fn export(registry: MetricsRegistry) -> String {
  let metrics_list = dict.to_list(registry.metrics)
  let sb = string_builder.new()

  list.fold(metrics_list, sb, fn(acc, pair) {
    let #(_, metric) = pair
    export_metric(acc, metric)
  })
  |> string_builder.to_string
}

fn export_metric(sb: StringBuilder, metric: Metric) -> StringBuilder {
  // Add HELP line
  let sb = sb
    |> string_builder.append("# HELP ")
    |> string_builder.append(metric.name)
    |> string_builder.append(" ")
    |> string_builder.append(metric.help)
    |> string_builder.append("\n")

  // Add TYPE line
  let type_str = case metric.metric_type {
    Counter -> "counter"
    Gauge -> "gauge"
    Histogram -> "histogram"
    Summary -> "summary"
  }
  let sb = sb
    |> string_builder.append("# TYPE ")
    |> string_builder.append(metric.name)
    |> string_builder.append(" ")
    |> string_builder.append(type_str)
    |> string_builder.append("\n")

  // Add metric values
  list.fold(metric.values, sb, fn(acc, value) {
    export_value(acc, metric.name, value)
  })
}

fn export_value(
  sb: StringBuilder,
  name: String,
  value: MetricValue,
) -> StringBuilder {
  let labels_str = format_labels(value.labels)

  sb
  |> string_builder.append(name)
  |> string_builder.append(labels_str)
  |> string_builder.append(" ")
  |> string_builder.append(format_float(value.value))
  |> string_builder.append("\n")
}

fn format_labels(labels: Dict(String, String)) -> String {
  let pairs = dict.to_list(labels)
  case pairs {
    [] -> ""
    _ -> {
      let formatted = list.map(pairs, fn(pair) {
        let #(key, value) = pair
        key <> "=\"" <> escape_label_value(value) <> "\""
      })
      "{" <> string.join(formatted, ",") <> "}"
    }
  }
}

fn escape_label_value(value: String) -> String {
  value
  |> string.replace("\\", "\\\\")
  |> string.replace("\"", "\\\"")
  |> string.replace("\n", "\\n")
}

fn format_float(f: Float) -> String {
  // Format float without trailing zeros
  let s = float.to_string(f)
  case string.ends_with(s, ".0") {
    True -> string.drop_right(s, 2)
    False -> s
  }
}

// ============================================================================
// Default Node Metrics
// ============================================================================

/// Initialize default node metrics
pub fn init_node_metrics(namespace: String) -> MetricsRegistry {
  new_registry(namespace)
  // Blockchain metrics
  |> register("blockchain_height", "Current blockchain height", Gauge)
  |> register("blockchain_difficulty", "Current mining difficulty", Gauge)
  |> register("blockchain_best_time", "Timestamp of best block", Gauge)
  |> register("blockchain_size_bytes", "Size of blockchain on disk", Gauge)
  |> register("blockchain_verification_progress", "Sync verification progress", Gauge)

  // Block validation metrics
  |> register("blocks_validated_total", "Total blocks validated", Counter)
  |> register("blocks_connected_total", "Total blocks connected to chain", Counter)
  |> register("blocks_rejected_total", "Total blocks rejected", Counter)
  |> register("block_validation_seconds", "Block validation duration", Histogram)

  // Transaction metrics
  |> register("txs_validated_total", "Total transactions validated", Counter)
  |> register("txs_accepted_total", "Total transactions accepted to mempool", Counter)
  |> register("txs_rejected_total", "Total transactions rejected", Counter)

  // Mempool metrics
  |> register("mempool_size", "Number of transactions in mempool", Gauge)
  |> register("mempool_bytes", "Total size of mempool in bytes", Gauge)
  |> register("mempool_usage_bytes", "Memory usage of mempool", Gauge)
  |> register("mempool_total_fee_sats", "Total fees in mempool", Gauge)
  |> register("mempool_min_fee_per_kb", "Minimum fee rate in mempool", Gauge)

  // P2P network metrics
  |> register("peers_connected", "Number of connected peers", Gauge)
  |> register("peers_inbound", "Number of inbound connections", Gauge)
  |> register("peers_outbound", "Number of outbound connections", Gauge)
  |> register("peers_banned", "Number of banned peers", Gauge)
  |> register("network_bytes_recv_total", "Total bytes received", Counter)
  |> register("network_bytes_sent_total", "Total bytes sent", Counter)
  |> register("network_messages_recv_total", "Total messages received", Counter)
  |> register("network_messages_sent_total", "Total messages sent", Counter)

  // RPC metrics
  |> register("rpc_requests_total", "Total RPC requests", Counter)
  |> register("rpc_errors_total", "Total RPC errors", Counter)
  |> register("rpc_request_duration_seconds", "RPC request duration", Histogram)
  |> register("rpc_active_connections", "Active RPC connections", Gauge)

  // UTXO set metrics
  |> register("utxo_count", "Number of UTXOs in the set", Gauge)
  |> register("utxo_db_size_bytes", "UTXO database size", Gauge)
  |> register("utxo_cache_size", "UTXO cache entries", Gauge)
  |> register("utxo_cache_hits_total", "UTXO cache hits", Counter)
  |> register("utxo_cache_misses_total", "UTXO cache misses", Counter)

  // Signature cache metrics
  |> register("sigcache_size", "Signature cache entries", Gauge)
  |> register("sigcache_hits_total", "Signature cache hits", Counter)
  |> register("sigcache_misses_total", "Signature cache misses", Counter)

  // System metrics
  |> register("uptime_seconds", "Node uptime in seconds", Counter)
  |> register("process_cpu_seconds_total", "CPU time used", Counter)
  |> register("process_resident_memory_bytes", "Resident memory size", Gauge)
  |> register("process_virtual_memory_bytes", "Virtual memory size", Gauge)

  // IBD metrics
  |> register("ibd_progress", "Initial block download progress", Gauge)
  |> register("ibd_headers_synced", "Headers synced during IBD", Gauge)
  |> register("ibd_blocks_synced", "Blocks synced during IBD", Gauge)
}

// ============================================================================
// Metrics Collector
// ============================================================================

/// Metrics collector state
pub type MetricsCollector {
  MetricsCollector(
    registry: MetricsRegistry,
    start_time: Int,
  )
}

/// Create a new metrics collector
pub fn new_collector(namespace: String) -> MetricsCollector {
  MetricsCollector(
    registry: init_node_metrics(namespace),
    start_time: 0,
  )
}

/// Update node metrics from current state
pub fn update_node_metrics(
  collector: MetricsCollector,
  state: NodeMetricsState,
) -> MetricsCollector {
  let labels = dict.new()
  let network_labels = dict.from_list([#("network", state.network)])

  let registry = collector.registry
    // Blockchain
    |> set("blockchain_height", int.to_float(state.height), network_labels)
    |> set("blockchain_difficulty", state.difficulty, network_labels)
    |> set("blockchain_best_time", int.to_float(state.best_time), network_labels)
    |> set("blockchain_size_bytes", int.to_float(state.chain_size), labels)
    |> set("blockchain_verification_progress", state.verification_progress, labels)

    // Mempool
    |> set("mempool_size", int.to_float(state.mempool_size), labels)
    |> set("mempool_bytes", int.to_float(state.mempool_bytes), labels)
    |> set("mempool_usage_bytes", int.to_float(state.mempool_usage), labels)
    |> set("mempool_total_fee_sats", int.to_float(state.mempool_fees), labels)

    // P2P
    |> set("peers_connected", int.to_float(state.peers_connected), labels)
    |> set("peers_inbound", int.to_float(state.peers_inbound), labels)
    |> set("peers_outbound", int.to_float(state.peers_outbound), labels)

    // UTXO
    |> set("utxo_count", int.to_float(state.utxo_count), labels)
    |> set("utxo_cache_size", int.to_float(state.utxo_cache_size), labels)

    // Uptime
    |> set("uptime_seconds", int.to_float(state.uptime_seconds), labels)

  MetricsCollector(..collector, registry: registry)
}

/// State used to update metrics
pub type NodeMetricsState {
  NodeMetricsState(
    network: String,
    height: Int,
    difficulty: Float,
    best_time: Int,
    chain_size: Int,
    verification_progress: Float,
    mempool_size: Int,
    mempool_bytes: Int,
    mempool_usage: Int,
    mempool_fees: Int,
    peers_connected: Int,
    peers_inbound: Int,
    peers_outbound: Int,
    utxo_count: Int,
    utxo_cache_size: Int,
    uptime_seconds: Int,
  )
}

/// Record a counter event
pub fn record_counter(
  collector: MetricsCollector,
  name: String,
  labels: Dict(String, String),
) -> MetricsCollector {
  MetricsCollector(
    ..collector,
    registry: inc(collector.registry, name, labels),
  )
}

/// Export metrics
pub fn export_metrics(collector: MetricsCollector) -> String {
  export(collector.registry)
}

// ============================================================================
// HTTP Endpoint Handler
// ============================================================================

/// Generate HTTP response for /metrics endpoint
pub fn metrics_http_response(collector: MetricsCollector) -> String {
  let body = export_metrics(collector)
  let content_length = string.length(body)

  "HTTP/1.1 200 OK\r\n" <>
  "Content-Type: text/plain; version=0.0.4; charset=utf-8\r\n" <>
  "Content-Length: " <> int.to_string(content_length) <> "\r\n" <>
  "\r\n" <>
  body
}

/// Check if request is for metrics endpoint
pub fn is_metrics_request(path: String) -> Bool {
  path == "/metrics" || path == "/metrics/"
}
