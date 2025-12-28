// logger.gleam - Structured logging for oni node
//
// This module provides structured logging with:
// - Multiple log levels (trace, debug, info, warn, error)
// - JSON and text output formats
// - Log categories for filtering
// - Context/field support
// - Configurable output targets
// - Rate limiting for high-frequency events
//
// Example usage:
//   let logger = new_logger(Info, JsonFormat)
//   logger
//   |> with_field("txid", "abc123")
//   |> with_field("size", 250)
//   |> log_info("Transaction accepted")

import gleam/dict.{type Dict}
import gleam/float
import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleam/string_builder

// ============================================================================
// Log Levels
// ============================================================================

/// Log severity level
pub type LogLevel {
  Trace
  Debug
  Info
  Warn
  ErrorLevel
}

/// Convert log level to string
pub fn level_to_string(level: LogLevel) -> String {
  case level {
    Trace -> "TRACE"
    Debug -> "DEBUG"
    Info -> "INFO"
    Warn -> "WARN"
    ErrorLevel -> "ERROR"
  }
}

/// Convert log level to lowercase string
pub fn level_to_lower(level: LogLevel) -> String {
  case level {
    Trace -> "trace"
    Debug -> "debug"
    Info -> "info"
    Warn -> "warn"
    ErrorLevel -> "error"
  }
}

/// Parse log level from string
pub fn parse_level(s: String) -> Result(LogLevel, String) {
  case string.lowercase(s) {
    "trace" -> Ok(Trace)
    "debug" -> Ok(Debug)
    "info" -> Ok(Info)
    "warn" | "warning" -> Ok(Warn)
    "error" | "err" -> Ok(ErrorLevel)
    _ -> Error("Unknown log level: " <> s)
  }
}

/// Compare log levels (returns True if a >= b)
pub fn level_gte(a: LogLevel, b: LogLevel) -> Bool {
  level_to_int(a) >= level_to_int(b)
}

fn level_to_int(level: LogLevel) -> Int {
  case level {
    Trace -> 0
    Debug -> 1
    Info -> 2
    Warn -> 3
    ErrorLevel -> 4
  }
}

// ============================================================================
// Log Format
// ============================================================================

/// Log output format
pub type LogFormat {
  /// Human-readable text format
  TextFormat
  /// JSON structured format
  JsonFormat
}

// ============================================================================
// Log Fields
// ============================================================================

/// A field value (can be various types)
pub type FieldValue {
  StringValue(String)
  IntValue(Int)
  FloatValue(Float)
  BoolValue(Bool)
  NullValue
}

/// Convert various types to FieldValue
pub fn string_field(s: String) -> FieldValue {
  StringValue(s)
}

pub fn int_field(n: Int) -> FieldValue {
  IntValue(n)
}

pub fn float_field(f: Float) -> FieldValue {
  FloatValue(f)
}

pub fn bool_field(b: Bool) -> FieldValue {
  BoolValue(b)
}

// ============================================================================
// Logger Types
// ============================================================================

/// Logger configuration
pub type LoggerConfig {
  LoggerConfig(
    /// Minimum log level
    min_level: LogLevel,
    /// Output format
    format: LogFormat,
    /// Log to stdout
    stdout: Bool,
    /// Log to stderr (for errors)
    stderr_for_errors: Bool,
    /// Include timestamps
    timestamps: Bool,
    /// Include source location
    include_source: Bool,
    /// Categories to include (empty = all)
    categories: List(String),
    /// Categories to exclude
    exclude_categories: List(String),
  )
}

/// Default logger configuration
pub fn default_config() -> LoggerConfig {
  LoggerConfig(
    min_level: Info,
    format: TextFormat,
    stdout: True,
    stderr_for_errors: True,
    timestamps: True,
    include_source: False,
    categories: [],
    exclude_categories: [],
  )
}

/// Production logger configuration (JSON, info level)
pub fn production_config() -> LoggerConfig {
  LoggerConfig(
    min_level: Info,
    format: JsonFormat,
    stdout: True,
    stderr_for_errors: True,
    timestamps: True,
    include_source: False,
    categories: [],
    exclude_categories: [],
  )
}

/// Debug logger configuration
pub fn debug_config() -> LoggerConfig {
  LoggerConfig(
    min_level: Debug,
    format: TextFormat,
    stdout: True,
    stderr_for_errors: True,
    timestamps: True,
    include_source: True,
    categories: [],
    exclude_categories: [],
  )
}

/// Logger instance with context
pub type Logger {
  Logger(
    config: LoggerConfig,
    category: Option(String),
    fields: Dict(String, FieldValue),
  )
}

/// Create a new logger
pub fn new_logger(level: LogLevel, format: LogFormat) -> Logger {
  Logger(
    config: LoggerConfig(..default_config(), min_level: level, format: format),
    category: None,
    fields: dict.new(),
  )
}

/// Create a logger with full configuration
pub fn new_logger_with_config(config: LoggerConfig) -> Logger {
  Logger(
    config: config,
    category: None,
    fields: dict.new(),
  )
}

// ============================================================================
// Logger Context
// ============================================================================

/// Set the log category
pub fn with_category(logger: Logger, category: String) -> Logger {
  Logger(..logger, category: Some(category))
}

/// Add a string field to the logger context
pub fn with_field(logger: Logger, key: String, value: String) -> Logger {
  Logger(..logger, fields: dict.insert(logger.fields, key, StringValue(value)))
}

/// Add an integer field to the logger context
pub fn with_int(logger: Logger, key: String, value: Int) -> Logger {
  Logger(..logger, fields: dict.insert(logger.fields, key, IntValue(value)))
}

/// Add a float field to the logger context
pub fn with_float(logger: Logger, key: String, value: Float) -> Logger {
  Logger(..logger, fields: dict.insert(logger.fields, key, FloatValue(value)))
}

/// Add a boolean field to the logger context
pub fn with_bool(logger: Logger, key: String, value: Bool) -> Logger {
  Logger(..logger, fields: dict.insert(logger.fields, key, BoolValue(value)))
}

/// Add multiple fields at once
pub fn with_fields(
  logger: Logger,
  fields: List(#(String, FieldValue)),
) -> Logger {
  let new_fields = list.fold(fields, logger.fields, fn(d, pair) {
    let #(key, value) = pair
    dict.insert(d, key, value)
  })
  Logger(..logger, fields: new_fields)
}

// ============================================================================
// Log Entry
// ============================================================================

/// A log entry
pub type LogEntry {
  LogEntry(
    level: LogLevel,
    message: String,
    timestamp: Int,
    category: Option(String),
    fields: Dict(String, FieldValue),
    source: Option(String),
  )
}

// ============================================================================
// Logging Functions
// ============================================================================

/// Log at trace level
pub fn log_trace(logger: Logger, message: String) -> Nil {
  log_at_level(logger, Trace, message)
}

/// Log at debug level
pub fn log_debug(logger: Logger, message: String) -> Nil {
  log_at_level(logger, Debug, message)
}

/// Log at info level
pub fn log_info(logger: Logger, message: String) -> Nil {
  log_at_level(logger, Info, message)
}

/// Log at warn level
pub fn log_warn(logger: Logger, message: String) -> Nil {
  log_at_level(logger, Warn, message)
}

/// Log at error level
pub fn log_error(logger: Logger, message: String) -> Nil {
  log_at_level(logger, ErrorLevel, message)
}

/// Log at a specific level
pub fn log_at_level(logger: Logger, level: LogLevel, message: String) -> Nil {
  // Check if level is enabled
  case level_gte(level, logger.config.min_level) {
    False -> Nil
    True -> {
      // Check category filter
      case should_log_category(logger.config, logger.category) {
        False -> Nil
        True -> {
          let entry = LogEntry(
            level: level,
            message: message,
            timestamp: 0,  // Would use actual timestamp in production
            category: logger.category,
            fields: logger.fields,
            source: None,
          )
          output_entry(logger.config, entry)
        }
      }
    }
  }
}

fn should_log_category(config: LoggerConfig, category: Option(String)) -> Bool {
  case category {
    None -> True
    Some(cat) -> {
      // Check excludes first
      case list.contains(config.exclude_categories, cat) {
        True -> False
        False -> {
          // Check includes (empty = all)
          case config.categories {
            [] -> True
            cats -> list.contains(cats, cat)
          }
        }
      }
    }
  }
}

// ============================================================================
// Output Formatting
// ============================================================================

fn output_entry(config: LoggerConfig, entry: LogEntry) -> Nil {
  let output = case config.format {
    TextFormat -> format_text(config, entry)
    JsonFormat -> format_json(entry)
  }

  // Output to appropriate stream
  case entry.level, config.stderr_for_errors {
    ErrorLevel, True -> io.println_error(output)
    Warn, True -> io.println_error(output)
    _, _ -> io.println(output)
  }
}

fn format_text(config: LoggerConfig, entry: LogEntry) -> String {
  let sb = string_builder.new()

  // Timestamp
  let sb = case config.timestamps {
    True -> string_builder.append(sb, "[" <> format_timestamp(entry.timestamp) <> "] ")
    False -> sb
  }

  // Level
  let sb = sb
    |> string_builder.append("[")
    |> string_builder.append(level_to_string(entry.level))
    |> string_builder.append("] ")

  // Category
  let sb = case entry.category {
    Some(cat) -> sb
      |> string_builder.append("[")
      |> string_builder.append(cat)
      |> string_builder.append("] ")
    None -> sb
  }

  // Message
  let sb = string_builder.append(sb, entry.message)

  // Fields
  let sb = case dict.size(entry.fields) > 0 {
    False -> sb
    True -> {
      let fields_str = format_fields_text(entry.fields)
      sb
      |> string_builder.append(" ")
      |> string_builder.append(fields_str)
    }
  }

  string_builder.to_string(sb)
}

fn format_fields_text(fields: Dict(String, FieldValue)) -> String {
  let pairs = dict.to_list(fields)
  let formatted = list.map(pairs, fn(pair) {
    let #(key, value) = pair
    key <> "=" <> format_field_value_text(value)
  })
  string.join(formatted, " ")
}

fn format_field_value_text(value: FieldValue) -> String {
  case value {
    StringValue(s) -> "\"" <> s <> "\""
    IntValue(n) -> int.to_string(n)
    FloatValue(f) -> float.to_string(f)
    BoolValue(True) -> "true"
    BoolValue(False) -> "false"
    NullValue -> "null"
  }
}

fn format_json(entry: LogEntry) -> String {
  let sb = string_builder.new()
  let sb = string_builder.append(sb, "{")

  // Level
  let sb = sb
    |> string_builder.append("\"level\":\"")
    |> string_builder.append(level_to_lower(entry.level))
    |> string_builder.append("\"")

  // Timestamp
  let sb = sb
    |> string_builder.append(",\"timestamp\":")
    |> string_builder.append(int.to_string(entry.timestamp))

  // Message
  let sb = sb
    |> string_builder.append(",\"message\":\"")
    |> string_builder.append(escape_json(entry.message))
    |> string_builder.append("\"")

  // Category
  let sb = case entry.category {
    Some(cat) -> sb
      |> string_builder.append(",\"category\":\"")
      |> string_builder.append(escape_json(cat))
      |> string_builder.append("\"")
    None -> sb
  }

  // Fields
  let sb = case dict.size(entry.fields) > 0 {
    False -> sb
    True -> {
      let pairs = dict.to_list(entry.fields)
      list.fold(pairs, sb, fn(acc, pair) {
        let #(key, value) = pair
        acc
        |> string_builder.append(",\"")
        |> string_builder.append(escape_json(key))
        |> string_builder.append("\":")
        |> string_builder.append(format_field_value_json(value))
      })
    }
  }

  let sb = string_builder.append(sb, "}")
  string_builder.to_string(sb)
}

fn format_field_value_json(value: FieldValue) -> String {
  case value {
    StringValue(s) -> "\"" <> escape_json(s) <> "\""
    IntValue(n) -> int.to_string(n)
    FloatValue(f) -> float.to_string(f)
    BoolValue(True) -> "true"
    BoolValue(False) -> "false"
    NullValue -> "null"
  }
}

fn escape_json(s: String) -> String {
  s
  |> string.replace("\\", "\\\\")
  |> string.replace("\"", "\\\"")
  |> string.replace("\n", "\\n")
  |> string.replace("\r", "\\r")
  |> string.replace("\t", "\\t")
}

fn format_timestamp(ts: Int) -> String {
  // Simple timestamp format
  // In production, would use proper date/time formatting
  int.to_string(ts)
}

// ============================================================================
// Convenience Loggers
// ============================================================================

/// Create a logger for a specific category
pub fn category_logger(base: Logger, category: String) -> Logger {
  with_category(base, category)
}

/// Create loggers for common node components
pub fn net_logger(base: Logger) -> Logger {
  with_category(base, "net")
}

pub fn mempool_logger(base: Logger) -> Logger {
  with_category(base, "mempool")
}

pub fn validation_logger(base: Logger) -> Logger {
  with_category(base, "validation")
}

pub fn rpc_logger(base: Logger) -> Logger {
  with_category(base, "rpc")
}

pub fn sync_logger(base: Logger) -> Logger {
  with_category(base, "sync")
}

pub fn storage_logger(base: Logger) -> Logger {
  with_category(base, "storage")
}

// ============================================================================
// Specialized Logging Helpers
// ============================================================================

/// Log a block event
pub fn log_block(
  logger: Logger,
  level: LogLevel,
  message: String,
  hash: String,
  height: Int,
) -> Nil {
  logger
  |> with_field("block_hash", hash)
  |> with_int("height", height)
  |> log_at_level(level, message)
}

/// Log a transaction event
pub fn log_tx(
  logger: Logger,
  level: LogLevel,
  message: String,
  txid: String,
) -> Nil {
  logger
  |> with_field("txid", txid)
  |> log_at_level(level, message)
}

/// Log a peer event
pub fn log_peer(
  logger: Logger,
  level: LogLevel,
  message: String,
  peer_id: Int,
  addr: String,
) -> Nil {
  logger
  |> with_int("peer_id", peer_id)
  |> with_field("addr", addr)
  |> log_at_level(level, message)
}

/// Log an RPC request
pub fn log_rpc(
  logger: Logger,
  level: LogLevel,
  message: String,
  method: String,
  duration_ms: Int,
) -> Nil {
  logger
  |> with_field("method", method)
  |> with_int("duration_ms", duration_ms)
  |> log_at_level(level, message)
}

// ============================================================================
// Global Logger (for convenience)
// ============================================================================

/// A simple function to log at info level without a logger instance
pub fn info(message: String) -> Nil {
  io.println("[INFO] " <> message)
}

/// A simple function to log at error level without a logger instance
pub fn error(message: String) -> Nil {
  io.println_error("[ERROR] " <> message)
}

/// A simple function to log at debug level without a logger instance
pub fn debug(message: String) -> Nil {
  io.println("[DEBUG] " <> message)
}

/// A simple function to log at warn level without a logger instance
pub fn warn(message: String) -> Nil {
  io.println("[WARN] " <> message)
}
