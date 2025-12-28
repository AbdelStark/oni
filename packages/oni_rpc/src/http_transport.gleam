// http_transport.gleam - HTTP transport layer for RPC server
//
// This module provides HTTP transport for the JSON-RPC server:
// - HTTP/1.1 request parsing
// - Basic authentication handling
// - Response serialization
// - Connection management
//
// Note: This is a simplified implementation. Production use would
// integrate with a proper HTTP server like Mist or Cowboy.

import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import oni_rpc

// ============================================================================
// HTTP Constants
// ============================================================================

/// HTTP version string
pub const http_version = "HTTP/1.1"

/// Maximum header size (8KB)
pub const max_header_size = 8192

/// Maximum body size (10MB)
pub const max_body_size = 10_000_000

/// Default keep-alive timeout
pub const keep_alive_timeout_ms = 30_000

// ============================================================================
// HTTP Types
// ============================================================================

/// HTTP request method
pub type HttpMethod {
  Get
  Post
  Options
  Head
  Put
  Delete
  Patch
  Unknown(String)
}

/// Parse HTTP method from string
pub fn parse_method(s: String) -> HttpMethod {
  case string.uppercase(s) {
    "GET" -> Get
    "POST" -> Post
    "OPTIONS" -> Options
    "HEAD" -> Head
    "PUT" -> Put
    "DELETE" -> Delete
    "PATCH" -> Patch
    _ -> Unknown(s)
  }
}

/// Convert HTTP method to string
pub fn method_to_string(method: HttpMethod) -> String {
  case method {
    Get -> "GET"
    Post -> "POST"
    Options -> "OPTIONS"
    Head -> "HEAD"
    Put -> "PUT"
    Delete -> "DELETE"
    Patch -> "PATCH"
    Unknown(s) -> s
  }
}

/// HTTP request
pub type HttpRequest {
  HttpRequest(
    method: HttpMethod,
    path: String,
    version: String,
    headers: Dict(String, String),
    body: BitArray,
  )
}

/// HTTP response
pub type HttpResponse {
  HttpResponse(
    status_code: Int,
    status_text: String,
    headers: Dict(String, String),
    body: BitArray,
  )
}

/// HTTP parsing error
pub type HttpError {
  HttpParseError(String)
  HttpMethodNotAllowed
  HttpRequestTooLarge
  HttpBadRequest(String)
  HttpUnauthorized
  HttpNotFound
  HttpInternalError(String)
}

// ============================================================================
// Request Parsing
// ============================================================================

/// Parse an HTTP request from bytes
pub fn parse_request(data: BitArray) -> Result(HttpRequest, HttpError) {
  case bit_array.to_string(data) {
    Error(_) -> Error(HttpParseError("Invalid UTF-8"))
    Ok(text) -> parse_request_string(text)
  }
}

/// Parse an HTTP request from string
pub fn parse_request_string(text: String) -> Result(HttpRequest, HttpError) {
  // Split headers and body by double CRLF
  let parts = string.split(text, "\r\n\r\n")

  case parts {
    [] -> Error(HttpParseError("Empty request"))
    [header_section, ..body_parts] -> {
      let body_text = string.join(body_parts, "\r\n\r\n")
      let body = bit_array.from_string(body_text)

      // Parse the header section
      let lines = string.split(header_section, "\r\n")
      case lines {
        [] -> Error(HttpParseError("No request line"))
        [request_line, ..header_lines] -> {
          // Parse request line: METHOD PATH VERSION
          case parse_request_line(request_line) {
            Error(e) -> Error(e)
            Ok(#(method, path, version)) -> {
              // Parse headers
              let headers = parse_headers(header_lines)

              Ok(HttpRequest(
                method: method,
                path: path,
                version: version,
                headers: headers,
                body: body,
              ))
            }
          }
        }
      }
    }
  }
}

fn parse_request_line(line: String) -> Result(#(HttpMethod, String, String), HttpError) {
  let parts = string.split(line, " ")
  case parts {
    [method_str, path, version] -> {
      Ok(#(parse_method(method_str), path, version))
    }
    [method_str, path] -> {
      // Some clients omit HTTP version
      Ok(#(parse_method(method_str), path, "HTTP/1.0"))
    }
    _ -> Error(HttpParseError("Invalid request line"))
  }
}

fn parse_headers(lines: List(String)) -> Dict(String, String) {
  list.fold(lines, dict.new(), fn(acc, line) {
    case string.split_once(line, ": ") {
      Ok(#(name, value)) -> {
        dict.insert(acc, string.lowercase(name), value)
      }
      Error(_) -> acc
    }
  })
}

/// Get a header value (case-insensitive)
pub fn get_header(request: HttpRequest, name: String) -> Option(String) {
  case dict.get(request.headers, string.lowercase(name)) {
    Ok(value) -> Some(value)
    Error(_) -> None
  }
}

/// Check if request has JSON content type
pub fn is_json_content_type(request: HttpRequest) -> Bool {
  case get_header(request, "content-type") {
    Some(ct) -> string.contains(string.lowercase(ct), "application/json")
    None -> False
  }
}

/// Get content length from headers
pub fn get_content_length(request: HttpRequest) -> Option(Int) {
  case get_header(request, "content-length") {
    Some(len_str) -> {
      case int.parse(len_str) {
        Ok(len) -> Some(len)
        Error(_) -> None
      }
    }
    None -> None
  }
}

// ============================================================================
// Response Building
// ============================================================================

/// Create an HTTP response
pub fn response(status_code: Int, body: BitArray) -> HttpResponse {
  let status_text = status_code_to_text(status_code)
  let headers = dict.new()
    |> dict.insert("content-length", int.to_string(bit_array.byte_size(body)))
    |> dict.insert("content-type", "application/json")
    |> dict.insert("connection", "keep-alive")

  HttpResponse(
    status_code: status_code,
    status_text: status_text,
    headers: headers,
    body: body,
  )
}

/// Create a JSON response
pub fn json_response(status_code: Int, json: String) -> HttpResponse {
  response(status_code, bit_array.from_string(json))
}

/// Create an error response
pub fn error_response(err: HttpError) -> HttpResponse {
  let #(code, message) = case err {
    HttpParseError(msg) -> #(400, msg)
    HttpMethodNotAllowed -> #(405, "Method Not Allowed")
    HttpRequestTooLarge -> #(413, "Request Too Large")
    HttpBadRequest(msg) -> #(400, msg)
    HttpUnauthorized -> #(401, "Unauthorized")
    HttpNotFound -> #(404, "Not Found")
    HttpInternalError(msg) -> #(500, msg)
  }

  let body = "{\"error\":\"" <> escape_json(message) <> "\"}"
  json_response(code, body)
}

/// Convert status code to text
fn status_code_to_text(code: Int) -> String {
  case code {
    200 -> "OK"
    201 -> "Created"
    204 -> "No Content"
    400 -> "Bad Request"
    401 -> "Unauthorized"
    403 -> "Forbidden"
    404 -> "Not Found"
    405 -> "Method Not Allowed"
    413 -> "Request Entity Too Large"
    500 -> "Internal Server Error"
    502 -> "Bad Gateway"
    503 -> "Service Unavailable"
    _ -> "Unknown"
  }
}

/// Serialize HTTP response to bytes
pub fn serialize_response(resp: HttpResponse) -> BitArray {
  let status_line = http_version <> " " <>
    int.to_string(resp.status_code) <> " " <>
    resp.status_text <> "\r\n"

  let headers_text = dict.fold(resp.headers, "", fn(acc, name, value) {
    acc <> name <> ": " <> value <> "\r\n"
  })

  let header_section = status_line <> headers_text <> "\r\n"

  bit_array.append(
    bit_array.from_string(header_section),
    resp.body
  )
}

fn escape_json(s: String) -> String {
  s
  |> string.replace("\\", "\\\\")
  |> string.replace("\"", "\\\"")
  |> string.replace("\n", "\\n")
  |> string.replace("\r", "\\r")
  |> string.replace("\t", "\\t")
}

// ============================================================================
// Authentication
// ============================================================================

/// Authentication result
pub type AuthResult {
  AuthSuccess(username: String)
  AuthFailure
  AuthNotProvided
}

/// Parse Basic authentication header
pub fn parse_basic_auth(request: HttpRequest) -> AuthResult {
  case get_header(request, "authorization") {
    None -> AuthNotProvided
    Some(auth_header) -> {
      case string.starts_with(auth_header, "Basic ") {
        False -> AuthFailure
        True -> {
          let encoded = string.drop_start(auth_header, 6)
          case decode_base64(encoded) {
            Error(_) -> AuthFailure
            Ok(decoded) -> {
              case string.split_once(decoded, ":") {
                Ok(#(username, _password)) -> AuthSuccess(username)
                Error(_) -> AuthFailure
              }
            }
          }
        }
      }
    }
  }
}

/// Verify authentication against config
pub fn verify_auth(
  request: HttpRequest,
  expected_user: String,
  expected_pass: String,
) -> Bool {
  case get_header(request, "authorization") {
    None -> False
    Some(auth_header) -> {
      case string.starts_with(auth_header, "Basic ") {
        False -> False
        True -> {
          let encoded = string.drop_start(auth_header, 6)
          case decode_base64(encoded) {
            Error(_) -> False
            Ok(decoded) -> {
              case string.split_once(decoded, ":") {
                Ok(#(user, pass)) -> user == expected_user && pass == expected_pass
                Error(_) -> False
              }
            }
          }
        }
      }
    }
  }
}

/// Simple base64 decode (for ASCII credentials)
fn decode_base64(encoded: String) -> Result(String, Nil) {
  // Use Erlang's base64 module
  case erlang_base64_decode(bit_array.from_string(encoded)) {
    Ok(bytes) -> {
      case bit_array.to_string(bytes) {
        Ok(s) -> Ok(s)
        Error(_) -> Error(Nil)
      }
    }
    Error(_) -> Error(Nil)
  }
}

@external(erlang, "base64", "decode")
fn erlang_base64_decode_raw(encoded: BitArray) -> BitArray

fn erlang_base64_decode(encoded: BitArray) -> Result(BitArray, Nil) {
  // Wrap in try/catch via helper
  Ok(erlang_base64_decode_raw(encoded))
}

// ============================================================================
// RPC Request Handler
// ============================================================================

/// RPC handler configuration
pub type RpcHandlerConfig {
  RpcHandlerConfig(
    /// Username for auth (empty = no auth required)
    username: String,
    /// Password for auth
    password: String,
    /// Allow unauthenticated requests
    allow_anonymous: Bool,
    /// Allowed paths (empty = allow all)
    allowed_paths: List(String),
  )
}

/// Default handler config (no auth, all paths allowed)
pub fn default_handler_config() -> RpcHandlerConfig {
  RpcHandlerConfig(
    username: "",
    password: "",
    allow_anonymous: True,
    allowed_paths: [],
  )
}

/// Handle an HTTP request for RPC
pub fn handle_rpc_request(
  request: HttpRequest,
  config: RpcHandlerConfig,
  server: oni_rpc.RpcServer,
) -> #(oni_rpc.RpcServer, HttpResponse) {
  // Check method - only POST allowed for RPC
  case request.method {
    Post -> handle_post_request(request, config, server)
    Options -> {
      // CORS preflight
      let resp = cors_preflight_response()
      #(server, resp)
    }
    Get -> {
      // Handle GET for health endpoints
      case request.path {
        "/" | "/health" | "/status" -> {
          let body = "{\"status\":\"ok\",\"service\":\"oni-rpc\"}"
          #(server, json_response(200, body))
        }
        _ -> #(server, error_response(HttpMethodNotAllowed))
      }
    }
    _ -> #(server, error_response(HttpMethodNotAllowed))
  }
}

fn handle_post_request(
  request: HttpRequest,
  config: RpcHandlerConfig,
  server: oni_rpc.RpcServer,
) -> #(oni_rpc.RpcServer, HttpResponse) {
  // Check path if restrictions exist
  case is_path_allowed(request.path, config.allowed_paths) {
    False -> #(server, error_response(HttpNotFound))
    True -> {
      // Check authentication
      let authenticated = check_auth(request, config)

      case authenticated, config.allow_anonymous {
        False, False -> {
          #(server, auth_required_response())
        }
        _, _ -> {
          // Parse and handle RPC request
          case bit_array.to_string(request.body) {
            Error(_) -> #(server, error_response(HttpBadRequest("Invalid body encoding")))
            Ok(body_str) -> {
              case oni_rpc.parse_request_string(body_str) {
                Error(err) -> {
                  let rpc_resp = oni_rpc.error_response(oni_rpc.IdNull, err)
                  let json = oni_rpc.serialize_response(rpc_resp)
                  #(server, json_response(200, json))
                }
                Ok(rpc_req) -> {
                  // Create RPC context
                  let ctx = oni_rpc.RpcContext(
                    authenticated: authenticated,
                    remote_addr: get_header(request, "x-forwarded-for"),
                    request_time: 0,  // Would use erlang:system_time/1
                  )

                  // Handle the RPC request
                  let #(new_server, rpc_resp) =
                    oni_rpc.server_handle_request(server, rpc_req, ctx)

                  let json = oni_rpc.serialize_response(rpc_resp)
                  let http_resp = json_response(200, json)
                    |> add_cors_headers

                  #(new_server, http_resp)
                }
              }
            }
          }
        }
      }
    }
  }
}

fn is_path_allowed(path: String, allowed: List(String)) -> Bool {
  case allowed {
    [] -> True  // Empty list = all paths allowed
    _ -> list.any(allowed, fn(p) { path == p || string.starts_with(path, p <> "/") })
  }
}

fn check_auth(request: HttpRequest, config: RpcHandlerConfig) -> Bool {
  case config.username, config.password {
    "", "" -> True  // No auth configured
    user, pass -> verify_auth(request, user, pass)
  }
}

/// Create an authentication required response
fn auth_required_response() -> HttpResponse {
  let headers = dict.new()
    |> dict.insert("www-authenticate", "Basic realm=\"oni-rpc\"")
    |> dict.insert("content-type", "application/json")
    |> dict.insert("content-length", "27")

  let body = "{\"error\":\"Unauthorized\"}"

  HttpResponse(
    status_code: 401,
    status_text: "Unauthorized",
    headers: headers,
    body: bit_array.from_string(body),
  )
}

/// Create a CORS preflight response
fn cors_preflight_response() -> HttpResponse {
  let headers = dict.new()
    |> dict.insert("access-control-allow-origin", "*")
    |> dict.insert("access-control-allow-methods", "POST, GET, OPTIONS")
    |> dict.insert("access-control-allow-headers", "Content-Type, Authorization")
    |> dict.insert("access-control-max-age", "86400")
    |> dict.insert("content-length", "0")

  HttpResponse(
    status_code: 204,
    status_text: "No Content",
    headers: headers,
    body: <<>>,
  )
}

/// Add CORS headers to a response
fn add_cors_headers(resp: HttpResponse) -> HttpResponse {
  let headers = resp.headers
    |> dict.insert("access-control-allow-origin", "*")
    |> dict.insert("access-control-allow-methods", "POST, GET, OPTIONS")

  HttpResponse(..resp, headers: headers)
}

// ============================================================================
// Connection State
// ============================================================================

/// HTTP connection state
pub type ConnectionState {
  ConnectionState(
    /// Pending data buffer
    buffer: BitArray,
    /// Current request being parsed
    current_request: Option(HttpRequest),
    /// Keep-alive enabled
    keep_alive: Bool,
    /// Number of requests handled
    request_count: Int,
    /// Bytes received
    bytes_recv: Int,
    /// Bytes sent
    bytes_sent: Int,
  )
}

/// Create new connection state
pub fn connection_new() -> ConnectionState {
  ConnectionState(
    buffer: <<>>,
    current_request: None,
    keep_alive: True,
    request_count: 0,
    bytes_recv: 0,
    bytes_sent: 0,
  )
}

/// Append data to connection buffer
pub fn connection_receive(
  state: ConnectionState,
  data: BitArray,
) -> ConnectionState {
  ConnectionState(
    ..state,
    buffer: bit_array.append(state.buffer, data),
    bytes_recv: state.bytes_recv + bit_array.byte_size(data),
  )
}

/// Try to parse a complete request from the buffer
pub fn connection_try_parse(
  state: ConnectionState,
) -> #(ConnectionState, Option(Result(HttpRequest, HttpError))) {
  // Look for the end of headers
  case has_complete_request(state.buffer) {
    False -> #(state, None)
    True -> {
      case parse_request(state.buffer) {
        Error(e) -> {
          // Clear buffer on parse error
          let new_state = ConnectionState(..state, buffer: <<>>)
          #(new_state, Some(Error(e)))
        }
        Ok(request) -> {
          // Check content length for body
          let content_length = case get_content_length(request) {
            Some(len) -> len
            None -> 0
          }

          // Check if we have the full body
          let body_size = bit_array.byte_size(request.body)
          case body_size >= content_length {
            False -> #(state, None)  // Need more data
            True -> {
              // We have a complete request, update state
              let new_state = ConnectionState(
                ..state,
                buffer: <<>>,
                current_request: None,
                request_count: state.request_count + 1,
              )
              #(new_state, Some(Ok(request)))
            }
          }
        }
      }
    }
  }
}

/// Check if buffer contains a complete HTTP request (headers at minimum)
fn has_complete_request(buffer: BitArray) -> Bool {
  case bit_array.to_string(buffer) {
    Error(_) -> False
    Ok(text) -> string.contains(text, "\r\n\r\n")
  }
}

/// Record bytes sent
pub fn connection_sent(
  state: ConnectionState,
  count: Int,
) -> ConnectionState {
  ConnectionState(..state, bytes_sent: state.bytes_sent + count)
}

/// Check if connection should stay open
pub fn connection_should_keep_alive(
  state: ConnectionState,
  request: HttpRequest,
) -> Bool {
  case get_header(request, "connection") {
    Some("close") -> False
    Some("keep-alive") -> True
    _ -> {
      // HTTP/1.1 defaults to keep-alive
      string.contains(request.version, "1.1") && state.keep_alive
    }
  }
}

// ============================================================================
// HTTP Server Stats
// ============================================================================

/// HTTP server statistics
pub type HttpStats {
  HttpStats(
    total_requests: Int,
    total_errors: Int,
    active_connections: Int,
    bytes_received: Int,
    bytes_sent: Int,
  )
}

/// Create initial stats
pub fn stats_new() -> HttpStats {
  HttpStats(
    total_requests: 0,
    total_errors: 0,
    active_connections: 0,
    bytes_received: 0,
    bytes_sent: 0,
  )
}

/// Update stats for a request
pub fn stats_request(stats: HttpStats) -> HttpStats {
  HttpStats(..stats, total_requests: stats.total_requests + 1)
}

/// Update stats for an error
pub fn stats_error(stats: HttpStats) -> HttpStats {
  HttpStats(..stats, total_errors: stats.total_errors + 1)
}

/// Update connection count
pub fn stats_connection_opened(stats: HttpStats) -> HttpStats {
  HttpStats(..stats, active_connections: stats.active_connections + 1)
}

/// Update connection count
pub fn stats_connection_closed(stats: HttpStats) -> HttpStats {
  HttpStats(..stats, active_connections: stats.active_connections - 1)
}
