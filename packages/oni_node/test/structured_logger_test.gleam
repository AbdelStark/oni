// logger_test.gleam - Tests for structured logging

import gleam/dict
import gleeunit/should
import structured_logger

pub fn level_to_string_test() {
  structured_logger.level_to_string(structured_logger.Trace)
  |> should.equal("TRACE")

  structured_logger.level_to_string(structured_logger.Debug)
  |> should.equal("DEBUG")

  structured_logger.level_to_string(structured_logger.Info)
  |> should.equal("INFO")

  structured_logger.level_to_string(structured_logger.Warn)
  |> should.equal("WARN")

  structured_logger.level_to_string(structured_logger.ErrorLevel)
  |> should.equal("ERROR")
}

pub fn level_to_lower_test() {
  structured_logger.level_to_lower(structured_logger.Info)
  |> should.equal("info")

  structured_logger.level_to_lower(structured_logger.ErrorLevel)
  |> should.equal("error")
}

pub fn parse_level_test() {
  structured_logger.parse_level("trace")
  |> should.equal(Ok(structured_logger.Trace))

  structured_logger.parse_level("DEBUG")
  |> should.equal(Ok(structured_logger.Debug))

  structured_logger.parse_level("Info")
  |> should.be_ok

  structured_logger.parse_level("WARN")
  |> should.equal(Ok(structured_logger.Warn))

  structured_logger.parse_level("warning")
  |> should.equal(Ok(structured_logger.Warn))

  structured_logger.parse_level("error")
  |> should.equal(Ok(structured_logger.ErrorLevel))

  structured_logger.parse_level("err")
  |> should.equal(Ok(structured_logger.ErrorLevel))

  structured_logger.parse_level("invalid")
  |> should.be_error
}

pub fn level_gte_test() {
  structured_logger.level_gte(structured_logger.ErrorLevel, structured_logger.Trace)
  |> should.be_true

  structured_logger.level_gte(structured_logger.Info, structured_logger.Debug)
  |> should.be_true

  structured_logger.level_gte(structured_logger.Debug, structured_logger.Info)
  |> should.be_false

  structured_logger.level_gte(structured_logger.Info, structured_logger.Info)
  |> should.be_true
}

pub fn new_logger_test() {
  let log = structured_logger.new_logger(structured_logger.Info, structured_logger.TextFormat)

  log.config.min_level
  |> should.equal(structured_logger.Info)

  log.config.format
  |> should.equal(structured_logger.TextFormat)
}

pub fn new_logger_json_test() {
  let log = structured_logger.new_logger(structured_logger.Debug, structured_logger.JsonFormat)

  log.config.format
  |> should.equal(structured_logger.JsonFormat)
}

pub fn default_config_test() {
  let config = structured_logger.default_config()

  config.min_level
  |> should.equal(structured_logger.Info)

  config.stdout
  |> should.be_true

  config.timestamps
  |> should.be_true
}

pub fn production_config_test() {
  let config = structured_logger.production_config()

  config.format
  |> should.equal(structured_logger.JsonFormat)

  config.min_level
  |> should.equal(structured_logger.Info)
}

pub fn debug_config_test() {
  let config = structured_logger.debug_config()

  config.min_level
  |> should.equal(structured_logger.Debug)

  config.include_source
  |> should.be_true
}

pub fn with_category_test() {
  let log = structured_logger.new_logger(structured_logger.Info, structured_logger.TextFormat)
    |> structured_logger.with_category("net")

  log.category
  |> should.equal(option.Some("net"))
}

pub fn with_field_test() {
  let log = structured_logger.new_logger(structured_logger.Info, structured_logger.TextFormat)
    |> structured_logger.with_field("txid", "abc123")

  case dict.get(log.fields, "txid") {
    Ok(structured_logger.StringValue(v)) -> {
      v
      |> should.equal("abc123")
    }
    _ -> should.be_true(False)
  }
}

pub fn with_int_test() {
  let log = structured_logger.new_logger(structured_logger.Info, structured_logger.TextFormat)
    |> structured_logger.with_int("height", 100)

  case dict.get(log.fields, "height") {
    Ok(structured_logger.IntValue(n)) -> {
      n
      |> should.equal(100)
    }
    _ -> should.be_true(False)
  }
}

pub fn with_float_test() {
  let log = structured_logger.new_logger(structured_logger.Info, structured_logger.TextFormat)
    |> structured_logger.with_float("difficulty", 1.5)

  case dict.get(log.fields, "difficulty") {
    Ok(structured_logger.FloatValue(f)) -> {
      f
      |> should.equal(1.5)
    }
    _ -> should.be_true(False)
  }
}

pub fn with_bool_test() {
  let log = structured_logger.new_logger(structured_logger.Info, structured_logger.TextFormat)
    |> structured_logger.with_bool("success", True)

  case dict.get(log.fields, "success") {
    Ok(structured_logger.BoolValue(b)) -> {
      b
      |> should.be_true
    }
    _ -> should.be_true(False)
  }
}

pub fn with_fields_test() {
  let fields = [
    #("field1", structured_logger.StringValue("value1")),
    #("field2", structured_logger.IntValue(42)),
  ]

  let log = structured_logger.new_logger(structured_logger.Info, structured_logger.TextFormat)
    |> structured_logger.with_fields(fields)

  dict.size(log.fields)
  |> should.equal(2)
}

pub fn category_logger_test() {
  let base = structured_logger.new_logger(structured_logger.Info, structured_logger.TextFormat)
  let net_log = structured_logger.category_logger(base, "network")

  net_log.category
  |> should.equal(option.Some("network"))
}

pub fn net_logger_test() {
  let base = structured_logger.new_logger(structured_logger.Info, structured_logger.TextFormat)
  let log = structured_logger.net_logger(base)

  log.category
  |> should.equal(option.Some("net"))
}

pub fn mempool_logger_test() {
  let base = structured_logger.new_logger(structured_logger.Info, structured_logger.TextFormat)
  let log = structured_logger.mempool_logger(base)

  log.category
  |> should.equal(option.Some("mempool"))
}

pub fn validation_logger_test() {
  let base = structured_logger.new_logger(structured_logger.Info, structured_logger.TextFormat)
  let log = structured_logger.validation_logger(base)

  log.category
  |> should.equal(option.Some("validation"))
}

pub fn rpc_logger_test() {
  let base = structured_logger.new_logger(structured_logger.Info, structured_logger.TextFormat)
  let log = structured_logger.rpc_logger(base)

  log.category
  |> should.equal(option.Some("rpc"))
}

pub fn sync_logger_test() {
  let base = structured_logger.new_logger(structured_logger.Info, structured_logger.TextFormat)
  let log = structured_logger.sync_logger(base)

  log.category
  |> should.equal(option.Some("sync"))
}

pub fn storage_logger_test() {
  let base = structured_logger.new_logger(structured_logger.Info, structured_logger.TextFormat)
  let log = structured_logger.storage_logger(base)

  log.category
  |> should.equal(option.Some("storage"))
}

pub fn string_field_test() {
  let field = structured_logger.string_field("hello")

  field
  |> should.equal(structured_logger.StringValue("hello"))
}

pub fn int_field_test() {
  let field = structured_logger.int_field(42)

  field
  |> should.equal(structured_logger.IntValue(42))
}

pub fn float_field_test() {
  let field = structured_logger.float_field(3.14)

  field
  |> should.equal(structured_logger.FloatValue(3.14))
}

pub fn bool_field_test() {
  let field = structured_logger.bool_field(True)

  field
  |> should.equal(structured_logger.BoolValue(True))
}

pub fn chained_context_test() {
  let log = structured_logger.new_logger(structured_logger.Info, structured_logger.TextFormat)
    |> structured_logger.with_category("net")
    |> structured_logger.with_field("peer_id", "123")
    |> structured_logger.with_int("port", 8333)
    |> structured_logger.with_bool("inbound", True)

  log.category
  |> should.equal(option.Some("net"))

  dict.size(log.fields)
  |> should.equal(3)
}

import gleam/option
