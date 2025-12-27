// Tests for HTTP transport layer

import gleeunit
import gleeunit/should
import gleam/dict
import gleam/bit_array
import http_transport
import oni_rpc

pub fn main() {
  gleeunit.main()
}

// ============================================================================
// HTTP Method Tests
// ============================================================================

pub fn parse_method_test() {
  http_transport.parse_method("GET") |> should.equal(http_transport.Get)
  http_transport.parse_method("POST") |> should.equal(http_transport.Post)
  http_transport.parse_method("OPTIONS") |> should.equal(http_transport.Options)
  http_transport.parse_method("put") |> should.equal(http_transport.Put)
}

pub fn parse_method_unknown_test() {
  case http_transport.parse_method("INVALID") {
    http_transport.Unknown(_) -> True
    _ -> False
  }
  |> should.be_true
}

pub fn method_to_string_test() {
  http_transport.method_to_string(http_transport.Get) |> should.equal("GET")
  http_transport.method_to_string(http_transport.Post) |> should.equal("POST")
  http_transport.method_to_string(http_transport.Options) |> should.equal("OPTIONS")
}

// ============================================================================
// HTTP Request Parsing Tests
// ============================================================================

pub fn parse_simple_request_test() {
  let request_text = "GET / HTTP/1.1\r\nHost: localhost\r\n\r\n"
  let bytes = bit_array.from_string(request_text)

  case http_transport.parse_request(bytes) {
    Ok(req) -> {
      req.method |> should.equal(http_transport.Get)
      req.path |> should.equal("/")
      req.version |> should.equal("HTTP/1.1")
    }
    Error(_) -> should.fail()
  }
}

pub fn parse_post_request_test() {
  let request_text = "POST /rpc HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n{}"
  let bytes = bit_array.from_string(request_text)

  case http_transport.parse_request(bytes) {
    Ok(req) -> {
      req.method |> should.equal(http_transport.Post)
      req.path |> should.equal("/rpc")
    }
    Error(_) -> should.fail()
  }
}

pub fn parse_request_with_body_test() {
  let body = "{\"method\":\"getblockcount\"}"
  let request_text = "POST / HTTP/1.1\r\nContent-Length: " <> int_to_string(string_length(body)) <> "\r\n\r\n" <> body
  let bytes = bit_array.from_string(request_text)

  case http_transport.parse_request(bytes) {
    Ok(req) -> {
      case bit_array.to_string(req.body) {
        Ok(body_str) -> body_str |> should.equal(body)
        Error(_) -> should.fail()
      }
    }
    Error(_) -> should.fail()
  }
}

pub fn parse_empty_request_fails_test() {
  let bytes = <<>>
  case http_transport.parse_request(bytes) {
    Ok(_) -> should.fail()
    Error(_) -> True |> should.be_true
  }
}

// ============================================================================
// Header Access Tests
// ============================================================================

pub fn get_header_test() {
  let request_text = "GET / HTTP/1.1\r\nHost: example.com\r\nContent-Type: application/json\r\n\r\n"
  let bytes = bit_array.from_string(request_text)

  case http_transport.parse_request(bytes) {
    Ok(req) -> {
      case http_transport.get_header(req, "Host") {
        option.Some(value) -> value |> should.equal("example.com")
        option.None -> should.fail()
      }
    }
    Error(_) -> should.fail()
  }
}

pub fn get_header_case_insensitive_test() {
  let request_text = "GET / HTTP/1.1\r\nContent-Type: application/json\r\n\r\n"
  let bytes = bit_array.from_string(request_text)

  case http_transport.parse_request(bytes) {
    Ok(req) -> {
      // Should match regardless of case
      case http_transport.get_header(req, "CONTENT-TYPE") {
        option.Some(value) -> value |> should.equal("application/json")
        option.None -> should.fail()
      }
    }
    Error(_) -> should.fail()
  }
}

pub fn is_json_content_type_test() {
  let request_text = "POST / HTTP/1.1\r\nContent-Type: application/json\r\n\r\n"
  let bytes = bit_array.from_string(request_text)

  case http_transport.parse_request(bytes) {
    Ok(req) -> {
      http_transport.is_json_content_type(req) |> should.be_true
    }
    Error(_) -> should.fail()
  }
}

pub fn is_not_json_content_type_test() {
  let request_text = "POST / HTTP/1.1\r\nContent-Type: text/plain\r\n\r\n"
  let bytes = bit_array.from_string(request_text)

  case http_transport.parse_request(bytes) {
    Ok(req) -> {
      http_transport.is_json_content_type(req) |> should.be_false
    }
    Error(_) -> should.fail()
  }
}

// ============================================================================
// HTTP Response Tests
// ============================================================================

pub fn response_creation_test() {
  let body = bit_array.from_string("{\"result\":1}")
  let resp = http_transport.response(200, body)

  resp.status_code |> should.equal(200)
  resp.status_text |> should.equal("OK")
  resp.body |> should.equal(body)
}

pub fn json_response_test() {
  let resp = http_transport.json_response(200, "{\"result\":1}")

  resp.status_code |> should.equal(200)

  case dict.get(resp.headers, "content-type") {
    Ok(ct) -> ct |> should.equal("application/json")
    Error(_) -> should.fail()
  }
}

pub fn error_response_test() {
  let resp = http_transport.error_response(http_transport.HttpNotFound)

  resp.status_code |> should.equal(404)
}

pub fn serialize_response_test() {
  let resp = http_transport.json_response(200, "{}")
  let bytes = http_transport.serialize_response(resp)

  case bit_array.to_string(bytes) {
    Ok(text) -> {
      // Should start with HTTP/1.1 200
      { string_contains(text, "HTTP/1.1 200") } |> should.be_true
      // Should contain body
      { string_contains(text, "{}") } |> should.be_true
    }
    Error(_) -> should.fail()
  }
}

// ============================================================================
// Authentication Tests
// ============================================================================

pub fn parse_basic_auth_not_provided_test() {
  let request_text = "GET / HTTP/1.1\r\n\r\n"
  let bytes = bit_array.from_string(request_text)

  case http_transport.parse_request(bytes) {
    Ok(req) -> {
      case http_transport.parse_basic_auth(req) {
        http_transport.AuthNotProvided -> True |> should.be_true
        _ -> should.fail()
      }
    }
    Error(_) -> should.fail()
  }
}

// ============================================================================
// Connection State Tests
// ============================================================================

pub fn connection_new_test() {
  let conn = http_transport.connection_new()

  conn.keep_alive |> should.be_true
  conn.request_count |> should.equal(0)
  conn.bytes_recv |> should.equal(0)
  conn.bytes_sent |> should.equal(0)
}

pub fn connection_receive_test() {
  let conn = http_transport.connection_new()
  let data = <<1, 2, 3, 4>>

  let updated = http_transport.connection_receive(conn, data)

  updated.bytes_recv |> should.equal(4)
}

pub fn connection_sent_test() {
  let conn = http_transport.connection_new()

  let updated = http_transport.connection_sent(conn, 100)

  updated.bytes_sent |> should.equal(100)
}

// ============================================================================
// HTTP Stats Tests
// ============================================================================

pub fn stats_new_test() {
  let stats = http_transport.stats_new()

  stats.total_requests |> should.equal(0)
  stats.total_errors |> should.equal(0)
  stats.active_connections |> should.equal(0)
}

pub fn stats_request_test() {
  let stats = http_transport.stats_new()
  let updated = http_transport.stats_request(stats)

  updated.total_requests |> should.equal(1)
}

pub fn stats_error_test() {
  let stats = http_transport.stats_new()
  let updated = http_transport.stats_error(stats)

  updated.total_errors |> should.equal(1)
}

pub fn stats_connection_opened_test() {
  let stats = http_transport.stats_new()
  let updated = http_transport.stats_connection_opened(stats)

  updated.active_connections |> should.equal(1)
}

pub fn stats_connection_closed_test() {
  let stats = http_transport.stats_new()
    |> http_transport.stats_connection_opened

  let updated = http_transport.stats_connection_closed(stats)

  updated.active_connections |> should.equal(0)
}

// ============================================================================
// Handler Config Tests
// ============================================================================

pub fn default_handler_config_test() {
  let config = http_transport.default_handler_config()

  config.allow_anonymous |> should.be_true
  config.username |> should.equal("")
  config.password |> should.equal("")
}

// ============================================================================
// Helpers
// ============================================================================

import gleam/string

fn string_length(s: String) -> Int {
  string.length(s)
}

fn int_to_string(n: Int) -> String {
  case n {
    0 -> "0"
    _ -> do_int_to_string(n, "")
  }
}

fn do_int_to_string(n: Int, acc: String) -> String {
  case n {
    0 -> acc
    _ -> {
      let digit = n % 10
      let rest = n / 10
      do_int_to_string(rest, string_from_digit(digit) <> acc)
    }
  }
}

fn string_from_digit(d: Int) -> String {
  case d {
    0 -> "0"
    1 -> "1"
    2 -> "2"
    3 -> "3"
    4 -> "4"
    5 -> "5"
    6 -> "6"
    7 -> "7"
    8 -> "8"
    9 -> "9"
    _ -> ""
  }
}

fn string_contains(haystack: String, needle: String) -> Bool {
  string.contains(haystack, needle)
}

import gleam/option
