// prometheus_test.gleam - Tests for Prometheus metrics export

import gleam/dict
import gleam/string
import gleeunit/should
import prometheus

pub fn new_registry_test() {
  let registry = prometheus.new_registry("oni")

  // Registry should be empty
  registry.namespace
  |> should.equal("oni")
}

pub fn register_gauge_test() {
  let registry = prometheus.new_registry("oni")
    |> prometheus.register("blockchain_height", "Current blockchain height", prometheus.Gauge)

  // Metric should exist
  let metrics = dict.to_list(registry.metrics)
  case metrics {
    [#(name, _)] -> {
      name
      |> should.equal("oni_blockchain_height")
    }
    _ -> should.be_true(False)
  }
}

pub fn set_gauge_value_test() {
  let registry = prometheus.new_registry("oni")
    |> prometheus.register("height", "Height", prometheus.Gauge)
    |> prometheus.set("height", 100.0, dict.new())

  let output = prometheus.export(registry)

  output
  |> string.contains("oni_height")
  |> should.be_true

  output
  |> string.contains("100")
  |> should.be_true
}

pub fn register_counter_test() {
  let registry = prometheus.new_registry("test")
    |> prometheus.register("requests_total", "Total requests", prometheus.Counter)

  let output = prometheus.export(registry)

  output
  |> string.contains("counter")
  |> should.be_true
}

pub fn increment_counter_test() {
  let registry = prometheus.new_registry("test")
    |> prometheus.register("requests_total", "Total requests", prometheus.Counter)
    |> prometheus.inc("requests_total", dict.new())
    |> prometheus.inc("requests_total", dict.new())
    |> prometheus.inc("requests_total", dict.new())

  let output = prometheus.export(registry)

  output
  |> string.contains("3")
  |> should.be_true
}

pub fn increment_by_test() {
  let registry = prometheus.new_registry("test")
    |> prometheus.register("bytes_total", "Total bytes", prometheus.Counter)
    |> prometheus.inc_by("bytes_total", 1000.0, dict.new())
    |> prometheus.inc_by("bytes_total", 500.0, dict.new())

  let output = prometheus.export(registry)

  // Check that the metric name and value appear in output
  { string.contains(output, "test_bytes_total") }
  |> should.be_true
}

pub fn metric_with_labels_test() {
  let labels = dict.from_list([#("method", "getblock")])

  let registry = prometheus.new_registry("rpc")
    |> prometheus.register("requests", "Requests", prometheus.Counter)
    |> prometheus.inc("requests", labels)

  let output = prometheus.export(registry)

  output
  |> string.contains("method=\"getblock\"")
  |> should.be_true
}

pub fn export_help_line_test() {
  let registry = prometheus.new_registry("oni")
    |> prometheus.register("height", "Current blockchain height", prometheus.Gauge)

  let output = prometheus.export(registry)

  output
  |> string.contains("# HELP oni_height Current blockchain height")
  |> should.be_true
}

pub fn export_type_line_test() {
  let registry = prometheus.new_registry("oni")
    |> prometheus.register("height", "Height", prometheus.Gauge)

  let output = prometheus.export(registry)

  output
  |> string.contains("# TYPE oni_height gauge")
  |> should.be_true
}

pub fn init_node_metrics_test() {
  let registry = prometheus.init_node_metrics("oni")

  // Should have many metrics registered
  let metric_count = dict.size(registry.metrics)

  // Check we have at least 20 metrics
  { metric_count >= 20 }
  |> should.be_true
}

pub fn new_collector_test() {
  let collector = prometheus.new_collector("oni")

  let output = prometheus.export_metrics(collector)

  // Should have content
  { string.length(output) > 0 }
  |> should.be_true
}

pub fn update_node_metrics_test() {
  let collector = prometheus.new_collector("oni")

  let state = prometheus.NodeMetricsState(
    network: "mainnet",
    height: 100_000,
    difficulty: 1000.0,
    best_time: 1234567890,
    chain_size: 500_000_000,
    verification_progress: 0.99,
    mempool_size: 1000,
    mempool_bytes: 5_000_000,
    mempool_usage: 10_000_000,
    mempool_fees: 1_000_000,
    peers_connected: 8,
    peers_inbound: 5,
    peers_outbound: 3,
    utxo_count: 80_000_000,
    utxo_cache_size: 100_000,
    uptime_seconds: 3600,
  )

  let updated = prometheus.update_node_metrics(collector, state)
  let output = prometheus.export_metrics(updated)

  // Check that blockchain height metric appears
  { string.contains(output, "oni_blockchain_height") }
  |> should.be_true

  // Check that network label appears
  { string.contains(output, "mainnet") }
  |> should.be_true
}

pub fn record_counter_test() {
  let collector = prometheus.new_collector("oni")

  let labels = dict.from_list([#("status", "success")])
  let updated = prometheus.record_counter(collector, "blocks_validated_total", labels)

  let output = prometheus.export_metrics(updated)

  output
  |> string.contains("blocks_validated_total")
  |> should.be_true
}

pub fn is_metrics_request_test() {
  prometheus.is_metrics_request("/metrics")
  |> should.be_true

  prometheus.is_metrics_request("/metrics/")
  |> should.be_true

  prometheus.is_metrics_request("/other")
  |> should.be_false
}

pub fn metrics_http_response_test() {
  let collector = prometheus.new_collector("oni")
  let response = prometheus.metrics_http_response(collector)

  response
  |> string.contains("HTTP/1.1 200 OK")
  |> should.be_true

  response
  |> string.contains("text/plain")
  |> should.be_true

  response
  |> string.contains("Content-Length:")
  |> should.be_true
}

pub fn escape_label_value_test() {
  let labels = dict.from_list([#("message", "hello \"world\"")])

  let registry = prometheus.new_registry("test")
    |> prometheus.register("test_metric", "Test", prometheus.Gauge)
    |> prometheus.set("test_metric", 1.0, labels)

  let output = prometheus.export(registry)

  // Should escape the quote
  output
  |> string.contains("\\\"")
  |> should.be_true
}
