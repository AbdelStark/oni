// health.gleam - Health checks and monitoring for oni node
//
// Provides:
// - Liveness checks (is the process alive?)
// - Readiness checks (is the node ready to serve requests?)
// - Component health status
// - Metrics aggregation for monitoring systems

import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

// ============================================================================
// Health Status Types
// ============================================================================

/// Overall health status
pub type HealthStatus {
  /// All systems operational
  Healthy
  /// Some non-critical issues
  Degraded
  /// Critical issues, node not fully functional
  Unhealthy
}

/// Convert health status to string
pub fn health_status_to_string(status: HealthStatus) -> String {
  case status {
    Healthy -> "healthy"
    Degraded -> "degraded"
    Unhealthy -> "unhealthy"
  }
}

/// Component health check result
pub type ComponentHealth {
  ComponentHealth(
    name: String,
    status: HealthStatus,
    message: Option(String),
    last_check: Int,
    latency_ms: Option(Int),
  )
}

/// Create a healthy component result
pub fn component_healthy(name: String, now: Int) -> ComponentHealth {
  ComponentHealth(
    name: name,
    status: Healthy,
    message: None,
    last_check: now,
    latency_ms: None,
  )
}

/// Create a degraded component result
pub fn component_degraded(name: String, message: String, now: Int) -> ComponentHealth {
  ComponentHealth(
    name: name,
    status: Degraded,
    message: Some(message),
    last_check: now,
    latency_ms: None,
  )
}

/// Create an unhealthy component result
pub fn component_unhealthy(name: String, message: String, now: Int) -> ComponentHealth {
  ComponentHealth(
    name: name,
    status: Unhealthy,
    message: Some(message),
    last_check: now,
    latency_ms: None,
  )
}

// ============================================================================
// Health Check Registry
// ============================================================================

/// Health check function signature
pub type HealthCheck =
  fn(Int) -> ComponentHealth

/// Health check registry
pub type HealthRegistry {
  HealthRegistry(
    checks: Dict(String, HealthCheck),
    results: Dict(String, ComponentHealth),
    last_full_check: Int,
  )
}

/// Create a new health registry
pub fn registry_new() -> HealthRegistry {
  HealthRegistry(
    checks: dict.new(),
    results: dict.new(),
    last_full_check: 0,
  )
}

/// Register a health check
pub fn register_check(
  registry: HealthRegistry,
  name: String,
  check: HealthCheck,
) -> HealthRegistry {
  HealthRegistry(
    ..registry,
    checks: dict.insert(registry.checks, name, check),
  )
}

/// Run all health checks
pub fn run_all_checks(registry: HealthRegistry, now: Int) -> HealthRegistry {
  let new_results = dict.fold(registry.checks, dict.new(), fn(acc, name, check) {
    let result = check(now)
    dict.insert(acc, name, result)
  })

  HealthRegistry(
    ..registry,
    results: new_results,
    last_full_check: now,
  )
}

/// Get a specific check result
pub fn get_check_result(
  registry: HealthRegistry,
  name: String,
) -> Option(ComponentHealth) {
  case dict.get(registry.results, name) {
    Ok(result) -> Some(result)
    Error(_) -> None
  }
}

/// Get overall health status
pub fn overall_status(registry: HealthRegistry) -> HealthStatus {
  let results = dict.values(registry.results)

  let has_unhealthy = list.any(results, fn(r) {
    case r.status {
      Unhealthy -> True
      _ -> False
    }
  })

  let has_degraded = list.any(results, fn(r) {
    case r.status {
      Degraded -> True
      _ -> False
    }
  })

  case has_unhealthy, has_degraded {
    True, _ -> Unhealthy
    False, True -> Degraded
    False, False -> Healthy
  }
}

// ============================================================================
// Standard Health Checks
// ============================================================================

/// Check if database is accessible
pub fn database_check(
  is_connected: Bool,
  last_write_time: Int,
  now: Int,
) -> ComponentHealth {
  case is_connected {
    False -> component_unhealthy("database", "Database connection lost", now)
    True -> {
      // Check if writes are stale (more than 5 minutes)
      let stale_threshold = 300_000  // 5 minutes in ms
      case now - last_write_time > stale_threshold {
        True -> component_degraded("database", "No recent writes", now)
        False -> component_healthy("database", now)
      }
    }
  }
}

/// Check P2P network health
pub fn network_check(
  connected_peers: Int,
  min_peers: Int,
  now: Int,
) -> ComponentHealth {
  case connected_peers {
    0 -> component_unhealthy("network", "No connected peers", now)
    n if n < min_peers -> component_degraded(
      "network",
      "Low peer count: " <> int.to_string(n),
      now,
    )
    _ -> component_healthy("network", now)
  }
}

/// Check sync status
pub fn sync_check(
  is_syncing: Bool,
  current_height: Int,
  best_known_height: Int,
  now: Int,
) -> ComponentHealth {
  case is_syncing {
    True -> {
      let behind = best_known_height - current_height
      component_degraded(
        "sync",
        "Syncing, " <> int.to_string(behind) <> " blocks behind",
        now,
      )
    }
    False -> {
      // Check if we're significantly behind
      case best_known_height - current_height > 10 {
        True -> component_degraded(
          "sync",
          "Behind by " <> int.to_string(best_known_height - current_height) <> " blocks",
          now,
        )
        False -> component_healthy("sync", now)
      }
    }
  }
}

/// Check mempool health
pub fn mempool_check(
  size_mb: Int,
  max_size_mb: Int,
  now: Int,
) -> ComponentHealth {
  let usage_percent = size_mb * 100 / max_size_mb
  case usage_percent {
    p if p > 95 -> component_degraded(
      "mempool",
      "Mempool nearly full: " <> int.to_string(p) <> "%",
      now,
    )
    p if p > 80 -> component_degraded(
      "mempool",
      "Mempool high usage: " <> int.to_string(p) <> "%",
      now,
    )
    _ -> component_healthy("mempool", now)
  }
}

/// Check RPC server health
pub fn rpc_check(
  is_running: Bool,
  active_connections: Int,
  max_connections: Int,
  now: Int,
) -> ComponentHealth {
  case is_running {
    False -> component_unhealthy("rpc", "RPC server not running", now)
    True -> {
      let usage_percent = active_connections * 100 / max_connections
      case usage_percent > 90 {
        True -> component_degraded(
          "rpc",
          "RPC connections at " <> int.to_string(usage_percent) <> "%",
          now,
        )
        False -> component_healthy("rpc", now)
      }
    }
  }
}

// ============================================================================
// Health Report
// ============================================================================

/// Complete health report
pub type HealthReport {
  HealthReport(
    status: HealthStatus,
    components: List(ComponentHealth),
    uptime_secs: Int,
    version: String,
    timestamp: Int,
  )
}

/// Generate a health report
pub fn generate_report(
  registry: HealthRegistry,
  uptime_secs: Int,
  version: String,
  now: Int,
) -> HealthReport {
  let components = dict.values(registry.results)
  HealthReport(
    status: overall_status(registry),
    components: components,
    uptime_secs: uptime_secs,
    version: version,
    timestamp: now,
  )
}

/// Serialize health report to JSON string
pub fn report_to_json(report: HealthReport) -> String {
  let components_json = report.components
    |> list.map(component_to_json)
    |> string.join(",")

  "{" <>
  "\"status\":\"" <> health_status_to_string(report.status) <> "\"," <>
  "\"uptime_secs\":" <> int.to_string(report.uptime_secs) <> "," <>
  "\"version\":\"" <> report.version <> "\"," <>
  "\"timestamp\":" <> int.to_string(report.timestamp) <> "," <>
  "\"components\":[" <> components_json <> "]" <>
  "}"
}

fn component_to_json(component: ComponentHealth) -> String {
  let message_json = case component.message {
    Some(msg) -> ",\"message\":\"" <> escape_json_string(msg) <> "\""
    None -> ""
  }

  let latency_json = case component.latency_ms {
    Some(ms) -> ",\"latency_ms\":" <> int.to_string(ms)
    None -> ""
  }

  "{" <>
  "\"name\":\"" <> component.name <> "\"," <>
  "\"status\":\"" <> health_status_to_string(component.status) <> "\"," <>
  "\"last_check\":" <> int.to_string(component.last_check) <>
  message_json <>
  latency_json <>
  "}"
}

fn escape_json_string(s: String) -> String {
  s
  |> string.replace("\\", "\\\\")
  |> string.replace("\"", "\\\"")
  |> string.replace("\n", "\\n")
  |> string.replace("\r", "\\r")
  |> string.replace("\t", "\\t")
}

// ============================================================================
// Metrics
// ============================================================================

/// Metric type
pub type MetricType {
  Counter
  Gauge
  Histogram
}

/// A single metric value
pub type Metric {
  Metric(
    name: String,
    metric_type: MetricType,
    value: Float,
    labels: Dict(String, String),
    help: String,
  )
}

/// Metrics collector
pub type MetricsCollector {
  MetricsCollector(
    metrics: Dict(String, Metric),
    prefix: String,
  )
}

/// Create a new metrics collector
pub fn metrics_new(prefix: String) -> MetricsCollector {
  MetricsCollector(
    metrics: dict.new(),
    prefix: prefix,
  )
}

/// Record a counter metric
pub fn counter(
  collector: MetricsCollector,
  name: String,
  value: Float,
  help: String,
) -> MetricsCollector {
  let metric = Metric(
    name: collector.prefix <> "_" <> name,
    metric_type: Counter,
    value: value,
    labels: dict.new(),
    help: help,
  )
  MetricsCollector(
    ..collector,
    metrics: dict.insert(collector.metrics, name, metric),
  )
}

/// Record a gauge metric
pub fn gauge(
  collector: MetricsCollector,
  name: String,
  value: Float,
  help: String,
) -> MetricsCollector {
  let metric = Metric(
    name: collector.prefix <> "_" <> name,
    metric_type: Gauge,
    value: value,
    labels: dict.new(),
    help: help,
  )
  MetricsCollector(
    ..collector,
    metrics: dict.insert(collector.metrics, name, metric),
  )
}

/// Standard oni node metrics
pub fn collect_node_metrics(
  collector: MetricsCollector,
  block_height: Int,
  peer_count: Int,
  mempool_size: Int,
  mempool_bytes: Int,
  uptime_secs: Int,
  rpc_requests_total: Int,
  blocks_validated: Int,
  txs_validated: Int,
) -> MetricsCollector {
  collector
  |> gauge("block_height", int_to_float(block_height), "Current block height")
  |> gauge("peer_count", int_to_float(peer_count), "Number of connected peers")
  |> gauge("mempool_size", int_to_float(mempool_size), "Number of transactions in mempool")
  |> gauge("mempool_bytes", int_to_float(mempool_bytes), "Size of mempool in bytes")
  |> gauge("uptime_seconds", int_to_float(uptime_secs), "Node uptime in seconds")
  |> counter("rpc_requests_total", int_to_float(rpc_requests_total), "Total RPC requests processed")
  |> counter("blocks_validated_total", int_to_float(blocks_validated), "Total blocks validated")
  |> counter("txs_validated_total", int_to_float(txs_validated), "Total transactions validated")
}

/// Export metrics in Prometheus format
pub fn export_prometheus(collector: MetricsCollector) -> String {
  collector.metrics
  |> dict.values
  |> list.map(metric_to_prometheus)
  |> string.join("\n")
}

fn metric_to_prometheus(metric: Metric) -> String {
  let type_str = case metric.metric_type {
    Counter -> "counter"
    Gauge -> "gauge"
    Histogram -> "histogram"
  }

  "# HELP " <> metric.name <> " " <> metric.help <> "\n" <>
  "# TYPE " <> metric.name <> " " <> type_str <> "\n" <>
  metric.name <> " " <> float_to_string(metric.value)
}

// ============================================================================
// Liveness and Readiness Probes
// ============================================================================

/// Liveness probe result
pub type LivenessResult {
  Live
  NotLive(reason: String)
}

/// Readiness probe result
pub type ReadinessResult {
  Ready
  NotReady(reason: String)
}

/// Check if node is live (basic process health)
pub fn liveness_probe(
  process_running: Bool,
  last_heartbeat: Int,
  now: Int,
) -> LivenessResult {
  case process_running {
    False -> NotLive("Process not running")
    True -> {
      // Check if heartbeat is recent (within 30 seconds)
      let heartbeat_timeout = 30_000
      case now - last_heartbeat > heartbeat_timeout {
        True -> NotLive("Heartbeat timeout")
        False -> Live
      }
    }
  }
}

/// Check if node is ready to serve requests
pub fn readiness_probe(
  is_synced: Bool,
  has_peers: Bool,
  db_connected: Bool,
) -> ReadinessResult {
  case db_connected {
    False -> NotReady("Database not connected")
    True -> case has_peers {
      False -> NotReady("No peer connections")
      True -> case is_synced {
        False -> NotReady("Still syncing")
        True -> Ready
      }
    }
  }
}

/// HTTP response for liveness probe
pub fn liveness_response(result: LivenessResult) -> #(Int, String) {
  case result {
    Live -> #(200, "{\"status\":\"live\"}")
    NotLive(reason) -> #(503, "{\"status\":\"not_live\",\"reason\":\"" <> reason <> "\"}")
  }
}

/// HTTP response for readiness probe
pub fn readiness_response(result: ReadinessResult) -> #(Int, String) {
  case result {
    Ready -> #(200, "{\"status\":\"ready\"}")
    NotReady(reason) -> #(503, "{\"status\":\"not_ready\",\"reason\":\"" <> reason <> "\"}")
  }
}

// ============================================================================
// Helper Functions
// ============================================================================

fn int_to_float(n: Int) -> Float {
  case n >= 0 {
    True -> do_int_to_float_pos(n, 0.0)
    False -> 0.0 -. do_int_to_float_pos(0 - n, 0.0)
  }
}

fn do_int_to_float_pos(n: Int, acc: Float) -> Float {
  case n {
    0 -> acc
    _ -> do_int_to_float_pos(n - 1, acc +. 1.0)
  }
}

fn float_to_string(f: Float) -> String {
  // Simple integer representation for now
  let int_part = float_to_int(f)
  int.to_string(int_part)
}

fn float_to_int(f: Float) -> Int {
  // Truncate to integer
  do_float_to_int(f, 0)
}

fn do_float_to_int(f: Float, acc: Int) -> Int {
  case f <. 1.0 {
    True -> acc
    False -> do_float_to_int(f -. 1.0, acc + 1)
  }
}
