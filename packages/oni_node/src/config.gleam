// config.gleam - Production configuration management for oni node
//
// This module provides:
// - Environment-based configuration
// - Validation of configuration values
// - Default configurations for different environments
// - Configuration file loading helpers

import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import oni_bitcoin

// ============================================================================
// Environment Types
// ============================================================================

/// Runtime environment
pub type Environment {
  /// Local development
  Development
  /// Automated testing
  Testing
  /// Pre-production staging
  Staging
  /// Production deployment
  Production
}

/// Parse environment from string
pub fn parse_environment(s: String) -> Result(Environment, String) {
  case string.lowercase(s) {
    "development" | "dev" -> Ok(Development)
    "testing" | "test" -> Ok(Testing)
    "staging" | "stage" -> Ok(Staging)
    "production" | "prod" -> Ok(Production)
    _ -> Error("Unknown environment: " <> s)
  }
}

/// Convert environment to string
pub fn environment_to_string(env: Environment) -> String {
  case env {
    Development -> "development"
    Testing -> "testing"
    Staging -> "staging"
    Production -> "production"
  }
}

// ============================================================================
// Configuration Structure
// ============================================================================

/// Complete node configuration
pub type NodeConfig {
  NodeConfig(
    /// Runtime environment
    environment: Environment,
    /// Bitcoin network
    network: oni_bitcoin.Network,
    /// Network configuration
    network_config: NetworkConfig,
    /// Storage configuration
    storage_config: StorageConfig,
    /// RPC configuration
    rpc_config: RpcConfig,
    /// Mempool configuration
    mempool_config: MempoolConfig,
    /// Logging configuration
    logging_config: LoggingConfig,
    /// Performance tuning
    performance_config: PerformanceConfig,
  )
}

/// Network/P2P configuration
pub type NetworkConfig {
  NetworkConfig(
    /// P2P listen port
    listen_port: Int,
    /// P2P bind address
    bind_address: String,
    /// Maximum inbound connections
    max_inbound: Int,
    /// Maximum outbound connections
    max_outbound: Int,
    /// Connection timeout in milliseconds
    connect_timeout_ms: Int,
    /// DNS seeds to use
    dns_seeds: List(String),
    /// Static peers to always connect to
    addnodes: List(String),
    /// Only connect to specified nodes
    connect_only: Bool,
    /// Listen for incoming connections
    listen: Bool,
    /// Enable UPnP port mapping
    upnp: Bool,
    /// Ban duration in seconds
    ban_duration_secs: Int,
  )
}

/// Storage configuration
pub type StorageConfig {
  StorageConfig(
    /// Data directory path
    data_dir: String,
    /// Block database path (relative to data_dir)
    blocks_dir: String,
    /// Chainstate database path
    chainstate_dir: String,
    /// Maximum database cache size in MB
    db_cache_mb: Int,
    /// Prune mode: keep only N blocks (0 = no pruning)
    prune_target_blocks: Int,
    /// Enable transaction index
    txindex: Bool,
    /// Flush interval in seconds
    flush_interval_secs: Int,
  )
}

/// RPC configuration
pub type RpcConfig {
  RpcConfig(
    /// Enable RPC server
    enabled: Bool,
    /// RPC listen port
    port: Int,
    /// RPC bind address
    bind_address: String,
    /// RPC username (required in production)
    username: Option(String),
    /// RPC password (required in production)
    password: Option(String),
    /// Allow unauthenticated requests
    allow_anonymous: Bool,
    /// Maximum concurrent RPC connections
    max_connections: Int,
    /// Request timeout in milliseconds
    timeout_ms: Int,
    /// Enable CORS
    cors_enabled: Bool,
    /// CORS allowed origins
    cors_origins: List(String),
  )
}

/// Mempool configuration
pub type MempoolConfig {
  MempoolConfig(
    /// Maximum mempool size in MB
    max_size_mb: Int,
    /// Maximum transaction age in hours
    max_age_hours: Int,
    /// Minimum relay fee in satoshis per vbyte
    min_relay_fee_sat_vb: Int,
    /// Enable Replace-By-Fee
    enable_rbf: Bool,
    /// Maximum orphan transactions
    max_orphans: Int,
    /// Orphan expiry time in seconds
    orphan_expiry_secs: Int,
  )
}

/// Logging configuration
pub type LoggingConfig {
  LoggingConfig(
    /// Minimum log level
    level: LogLevel,
    /// Log output format
    format: LogFormat,
    /// Log to file
    log_to_file: Bool,
    /// Log file path
    log_file_path: String,
    /// Maximum log file size in MB
    max_log_size_mb: Int,
    /// Number of log files to keep
    max_log_files: Int,
    /// Include timestamps
    timestamps: Bool,
    /// Log category filters
    categories: List(String),
  )
}

/// Log level
pub type LogLevel {
  LogTrace
  LogDebug
  LogInfo
  LogWarn
  LogError
}

/// Log format
pub type LogFormat {
  /// Human-readable text format
  LogText
  /// JSON structured logging
  LogJson
}

/// Performance tuning configuration
pub type PerformanceConfig {
  PerformanceConfig(
    /// Signature cache size (number of entries)
    sig_cache_size: Int,
    /// Script cache size
    script_cache_size: Int,
    /// Block index cache size
    block_index_cache_size: Int,
    /// Number of parallel validation threads
    validation_threads: Int,
    /// Download window size (parallel block downloads)
    download_window: Int,
    /// Enable checkpoints for faster IBD
    use_checkpoints: Bool,
    /// Assume valid block hash (skip script validation before this)
    assume_valid: Option(String),
  )
}

// ============================================================================
// Default Configurations
// ============================================================================

/// Default network configuration
pub fn default_network_config() -> NetworkConfig {
  NetworkConfig(
    listen_port: 8333,
    bind_address: "0.0.0.0",
    max_inbound: 117,
    max_outbound: 11,
    connect_timeout_ms: 5000,
    dns_seeds: [
      "seed.bitcoin.sipa.be",
      "dnsseed.bluematt.me",
      "dnsseed.bitcoin.dashjr-list-of-hierarchical-deterministic-wallets.org",
      "seed.bitcoinstats.com",
      "seed.bitcoin.jonasschnelli.ch",
      "seed.btc.petertodd.net",
      "seed.bitcoin.sprovoost.nl",
      "dnsseed.emzy.de",
      "seed.bitcoin.wiz.biz",
    ],
    addnodes: [],
    connect_only: False,
    listen: True,
    upnp: False,
    ban_duration_secs: 86_400,
  )
}

/// Default storage configuration
pub fn default_storage_config() -> StorageConfig {
  StorageConfig(
    data_dir: "~/.oni",
    blocks_dir: "blocks",
    chainstate_dir: "chainstate",
    db_cache_mb: 450,
    prune_target_blocks: 0,
    txindex: False,
    flush_interval_secs: 60,
  )
}

/// Default RPC configuration
pub fn default_rpc_config() -> RpcConfig {
  RpcConfig(
    enabled: True,
    port: 8332,
    bind_address: "127.0.0.1",
    username: None,
    password: None,
    allow_anonymous: True,
    max_connections: 100,
    timeout_ms: 60_000,
    cors_enabled: False,
    cors_origins: [],
  )
}

/// Default mempool configuration
pub fn default_mempool_config() -> MempoolConfig {
  MempoolConfig(
    max_size_mb: 300,
    max_age_hours: 336,  // 14 days
    min_relay_fee_sat_vb: 1,
    enable_rbf: True,
    max_orphans: 100,
    orphan_expiry_secs: 1200,  // 20 minutes
  )
}

/// Default logging configuration
pub fn default_logging_config() -> LoggingConfig {
  LoggingConfig(
    level: LogInfo,
    format: LogText,
    log_to_file: False,
    log_file_path: "debug.log",
    max_log_size_mb: 100,
    max_log_files: 5,
    timestamps: True,
    categories: ["net", "mempool", "validation", "rpc"],
  )
}

/// Default performance configuration
pub fn default_performance_config() -> PerformanceConfig {
  PerformanceConfig(
    sig_cache_size: 100_000,
    script_cache_size: 100_000,
    block_index_cache_size: 10_000,
    validation_threads: 0,  // 0 = auto-detect
    download_window: 1024,
    use_checkpoints: True,
    assume_valid: None,
  )
}

/// Development environment configuration
pub fn development_config() -> NodeConfig {
  NodeConfig(
    environment: Development,
    network: oni_bitcoin.Regtest,
    network_config: NetworkConfig(
      ..default_network_config(),
      listen_port: 18444,
      max_inbound: 8,
      max_outbound: 4,
      dns_seeds: [],
    ),
    storage_config: StorageConfig(
      ..default_storage_config(),
      data_dir: "./data-dev",
      db_cache_mb: 100,
    ),
    rpc_config: RpcConfig(
      ..default_rpc_config(),
      port: 18443,
      allow_anonymous: True,
    ),
    mempool_config: MempoolConfig(
      ..default_mempool_config(),
      max_size_mb: 50,
    ),
    logging_config: LoggingConfig(
      ..default_logging_config(),
      level: LogDebug,
    ),
    performance_config: PerformanceConfig(
      ..default_performance_config(),
      sig_cache_size: 10_000,
      use_checkpoints: False,
    ),
  )
}

/// Testing environment configuration
pub fn testing_config() -> NodeConfig {
  NodeConfig(
    environment: Testing,
    network: oni_bitcoin.Regtest,
    network_config: NetworkConfig(
      ..default_network_config(),
      listen_port: 18555,
      max_inbound: 4,
      max_outbound: 2,
      dns_seeds: [],
      listen: False,
    ),
    storage_config: StorageConfig(
      ..default_storage_config(),
      data_dir: "./data-test",
      db_cache_mb: 50,
    ),
    rpc_config: RpcConfig(
      ..default_rpc_config(),
      port: 18554,
      enabled: False,
    ),
    mempool_config: MempoolConfig(
      ..default_mempool_config(),
      max_size_mb: 10,
    ),
    logging_config: LoggingConfig(
      ..default_logging_config(),
      level: LogWarn,
      log_to_file: False,
    ),
    performance_config: PerformanceConfig(
      ..default_performance_config(),
      sig_cache_size: 1000,
      script_cache_size: 1000,
    ),
  )
}

/// Production mainnet configuration
pub fn production_config() -> NodeConfig {
  NodeConfig(
    environment: Production,
    network: oni_bitcoin.Mainnet,
    network_config: default_network_config(),
    storage_config: StorageConfig(
      ..default_storage_config(),
      data_dir: "/var/lib/oni",
      db_cache_mb: 4096,  // 4GB cache for production
    ),
    rpc_config: RpcConfig(
      ..default_rpc_config(),
      allow_anonymous: False,  // Require auth in production
      cors_enabled: False,
    ),
    mempool_config: default_mempool_config(),
    logging_config: LoggingConfig(
      ..default_logging_config(),
      level: LogInfo,
      format: LogJson,  // Structured logging for production
      log_to_file: True,
      log_file_path: "/var/log/oni/oni.log",
    ),
    performance_config: PerformanceConfig(
      ..default_performance_config(),
      sig_cache_size: 500_000,
      script_cache_size: 500_000,
      block_index_cache_size: 50_000,
    ),
  )
}

/// Get configuration for environment
pub fn config_for_environment(env: Environment) -> NodeConfig {
  case env {
    Development -> development_config()
    Testing -> testing_config()
    Staging -> production_config()  // Staging uses prod config with staging network
    Production -> production_config()
  }
}

// ============================================================================
// Configuration Validation
// ============================================================================

/// Configuration validation error
pub type ConfigError {
  ConfigError(field: String, message: String)
}

/// Validate a complete configuration
pub fn validate_config(config: NodeConfig) -> Result(NodeConfig, List(ConfigError)) {
  let errors = []
    |> validate_network_config(config.network_config)
    |> validate_storage_config(config.storage_config)
    |> validate_rpc_config(config.rpc_config, config.environment)
    |> validate_mempool_config(config.mempool_config)
    |> validate_performance_config(config.performance_config)

  case errors {
    [] -> Ok(config)
    _ -> Error(list.reverse(errors))
  }
}

fn validate_network_config(
  errors: List(ConfigError),
  config: NetworkConfig,
) -> List(ConfigError) {
  errors
  |> check_port("network.listen_port", config.listen_port)
  |> check_positive("network.max_inbound", config.max_inbound)
  |> check_positive("network.max_outbound", config.max_outbound)
  |> check_positive("network.connect_timeout_ms", config.connect_timeout_ms)
}

fn validate_storage_config(
  errors: List(ConfigError),
  config: StorageConfig,
) -> List(ConfigError) {
  errors
  |> check_non_empty("storage.data_dir", config.data_dir)
  |> check_positive("storage.db_cache_mb", config.db_cache_mb)
  |> check_non_negative("storage.prune_target_blocks", config.prune_target_blocks)
}

fn validate_rpc_config(
  errors: List(ConfigError),
  config: RpcConfig,
  env: Environment,
) -> List(ConfigError) {
  let base_errors = errors
    |> check_port("rpc.port", config.port)
    |> check_positive("rpc.max_connections", config.max_connections)
    |> check_positive("rpc.timeout_ms", config.timeout_ms)

  // In production, require authentication
  case env, config.enabled, config.allow_anonymous {
    Production, True, True -> [
      ConfigError(
        field: "rpc.allow_anonymous",
        message: "Anonymous RPC access not allowed in production",
      ),
      ..base_errors
    ]
    _, _, _ -> base_errors
  }
}

fn validate_mempool_config(
  errors: List(ConfigError),
  config: MempoolConfig,
) -> List(ConfigError) {
  errors
  |> check_positive("mempool.max_size_mb", config.max_size_mb)
  |> check_positive("mempool.max_age_hours", config.max_age_hours)
  |> check_non_negative("mempool.min_relay_fee_sat_vb", config.min_relay_fee_sat_vb)
}

fn validate_performance_config(
  errors: List(ConfigError),
  config: PerformanceConfig,
) -> List(ConfigError) {
  errors
  |> check_positive("performance.sig_cache_size", config.sig_cache_size)
  |> check_positive("performance.script_cache_size", config.script_cache_size)
  |> check_non_negative("performance.validation_threads", config.validation_threads)
  |> check_positive("performance.download_window", config.download_window)
}

// Validation helpers

fn check_port(errors: List(ConfigError), field: String, value: Int) -> List(ConfigError) {
  case value >= 1 && value <= 65535 {
    True -> errors
    False -> [ConfigError(field: field, message: "Port must be between 1 and 65535"), ..errors]
  }
}

fn check_positive(errors: List(ConfigError), field: String, value: Int) -> List(ConfigError) {
  case value > 0 {
    True -> errors
    False -> [ConfigError(field: field, message: "Value must be positive"), ..errors]
  }
}

fn check_non_negative(errors: List(ConfigError), field: String, value: Int) -> List(ConfigError) {
  case value >= 0 {
    True -> errors
    False -> [ConfigError(field: field, message: "Value must be non-negative"), ..errors]
  }
}

fn check_non_empty(errors: List(ConfigError), field: String, value: String) -> List(ConfigError) {
  case string.length(value) > 0 {
    True -> errors
    False -> [ConfigError(field: field, message: "Value must not be empty"), ..errors]
  }
}

// ============================================================================
// Configuration Serialization
// ============================================================================

/// Serialize log level to string
pub fn log_level_to_string(level: LogLevel) -> String {
  case level {
    LogTrace -> "trace"
    LogDebug -> "debug"
    LogInfo -> "info"
    LogWarn -> "warn"
    LogError -> "error"
  }
}

/// Parse log level from string
pub fn parse_log_level(s: String) -> Result(LogLevel, String) {
  case string.lowercase(s) {
    "trace" -> Ok(LogTrace)
    "debug" -> Ok(LogDebug)
    "info" -> Ok(LogInfo)
    "warn" | "warning" -> Ok(LogWarn)
    "error" -> Ok(LogError)
    _ -> Error("Unknown log level: " <> s)
  }
}

/// Get configuration summary for logging
pub fn config_summary(config: NodeConfig) -> String {
  let network_name = case config.network {
    oni_bitcoin.Mainnet -> "mainnet"
    oni_bitcoin.Testnet -> "testnet"
    oni_bitcoin.Signet -> "signet"
    oni_bitcoin.Regtest -> "regtest"
  }

  "Environment: " <> environment_to_string(config.environment) <> "\n" <>
  "Network: " <> network_name <> "\n" <>
  "P2P Port: " <> int.to_string(config.network_config.listen_port) <> "\n" <>
  "RPC Port: " <> int.to_string(config.rpc_config.port) <> "\n" <>
  "Data Dir: " <> config.storage_config.data_dir <> "\n" <>
  "DB Cache: " <> int.to_string(config.storage_config.db_cache_mb) <> " MB\n" <>
  "Sig Cache: " <> int.to_string(config.performance_config.sig_cache_size) <> " entries"
}
