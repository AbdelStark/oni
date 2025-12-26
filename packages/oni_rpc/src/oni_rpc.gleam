// oni_rpc - JSON-RPC interface for oni Bitcoin node
//
// This module implements a Bitcoin Core compatible JSON-RPC interface:
// - JSON-RPC 2.0 protocol
// - Authentication (username/password)
// - Method routing and dispatch
// - Standard Bitcoin RPC methods
// - Health and metrics endpoints
//
// Phase 9 Implementation

import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/float
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import oni_bitcoin

// ============================================================================
// Constants
// ============================================================================

/// RPC protocol version
pub const rpc_version = "2.0"

/// Default RPC timeout in milliseconds
pub const rpc_timeout_ms = 30_000

/// Maximum request size in bytes
pub const max_request_size = 10_000_000  // 10 MB

/// Rate limit (requests per minute per IP)
pub const rate_limit_per_minute = 100

// ============================================================================
// RPC Error Codes
// ============================================================================

/// Standard JSON-RPC error codes
pub const err_parse = -32700

pub const err_invalid_request = -32600

pub const err_method_not_found = -32601

pub const err_invalid_params = -32602

pub const err_internal = -32603

/// Bitcoin-specific error codes
pub const err_misc = -1

pub const err_type = -3

pub const err_wallet_error = -4

pub const err_invalid_address = -5

pub const err_insufficient_funds = -6

pub const err_database_error = -20

pub const err_deserialization = -22

pub const err_verify_error = -25

pub const err_verify_rejected = -26

pub const err_verify_already_in_chain = -27

pub const err_in_warmup = -28

// ============================================================================
// RPC Types
// ============================================================================

/// RPC error type
pub type RpcError {
  Unauthorized
  InvalidRequest(String)
  MethodNotFound(String)
  InvalidParams(String)
  Internal(String)
  ParseError(String)
  RateLimited
  Timeout
}

/// Get error code for RpcError
pub fn error_code(err: RpcError) -> Int {
  case err {
    Unauthorized -> err_misc
    InvalidRequest(_) -> err_invalid_request
    MethodNotFound(_) -> err_method_not_found
    InvalidParams(_) -> err_invalid_params
    Internal(_) -> err_internal
    ParseError(_) -> err_parse
    RateLimited -> err_misc
    Timeout -> err_misc
  }
}

/// Get error message for RpcError
pub fn error_message(err: RpcError) -> String {
  case err {
    Unauthorized -> "Unauthorized"
    InvalidRequest(msg) -> "Invalid request: " <> msg
    MethodNotFound(method) -> "Method not found: " <> method
    InvalidParams(msg) -> "Invalid params: " <> msg
    Internal(msg) -> "Internal error: " <> msg
    ParseError(msg) -> "Parse error: " <> msg
    RateLimited -> "Rate limit exceeded"
    Timeout -> "Request timeout"
  }
}

/// JSON-RPC request
pub type RpcRequest {
  RpcRequest(
    jsonrpc: String,
    id: RpcId,
    method: String,
    params: RpcParams,
  )
}

/// JSON-RPC request ID (can be string, number, or null)
pub type RpcId {
  IdString(String)
  IdInt(Int)
  IdNull
}

/// JSON-RPC parameters (positional or named)
pub type RpcParams {
  ParamsArray(List(RpcValue))
  ParamsObject(Dict(String, RpcValue))
  ParamsNone
}

/// JSON-RPC response
pub type RpcResponse {
  RpcSuccess(
    jsonrpc: String,
    id: RpcId,
    result: RpcValue,
  )
  RpcFailure(
    jsonrpc: String,
    id: RpcId,
    error: RpcErrorObject,
  )
}

/// JSON-RPC error object
pub type RpcErrorObject {
  RpcErrorObject(
    code: Int,
    message: String,
    data: Option(RpcValue),
  )
}

/// JSON value types for RPC
pub type RpcValue {
  RpcNull
  RpcBool(Bool)
  RpcInt(Int)
  RpcFloat(Float)
  RpcString(String)
  RpcArray(List(RpcValue))
  RpcObject(Dict(String, RpcValue))
}

// ============================================================================
// RPC Value Helpers
// ============================================================================

/// Convert RpcValue to string (for simple cases)
pub fn value_to_string(val: RpcValue) -> Option(String) {
  case val {
    RpcString(s) -> Some(s)
    RpcInt(n) -> Some(int.to_string(n))
    _ -> None
  }
}

/// Convert RpcValue to int
pub fn value_to_int(val: RpcValue) -> Option(Int) {
  case val {
    RpcInt(n) -> Some(n)
    _ -> None
  }
}

/// Convert RpcValue to bool
pub fn value_to_bool(val: RpcValue) -> Option(Bool) {
  case val {
    RpcBool(b) -> Some(b)
    _ -> None
  }
}

/// Get array element at index
pub fn value_get_array_element(val: RpcValue, idx: Int) -> Option(RpcValue) {
  case val {
    RpcArray(arr) -> list_at(arr, idx)
    _ -> None
  }
}

fn list_at(lst: List(a), idx: Int) -> Option(a) {
  case lst, idx {
    [], _ -> None
    [head, ..], 0 -> Some(head)
    [_, ..tail], n if n > 0 -> list_at(tail, n - 1)
    _, _ -> None
  }
}

/// Get object field
pub fn value_get_field(val: RpcValue, field: String) -> Option(RpcValue) {
  case val {
    RpcObject(obj) -> {
      case dict.get(obj, field) {
        Ok(v) -> Some(v)
        Error(_) -> None
      }
    }
    _ -> None
  }
}

// ============================================================================
// Request Parsing
// ============================================================================

/// Parse RPC request from raw bytes
/// Note: This is a simplified parser - production would use proper JSON library
pub fn parse_request(data: BitArray) -> Result(RpcRequest, RpcError) {
  case bit_array.to_string(data) {
    Error(_) -> Error(ParseError("Invalid UTF-8"))
    Ok(json_str) -> parse_request_string(json_str)
  }
}

/// Parse RPC request from string
pub fn parse_request_string(json: String) -> Result(RpcRequest, RpcError) {
  // This is a simplified JSON parser for demonstration
  // A real implementation would use a proper JSON library
  let trimmed = string.trim(json)

  // Basic validation
  case string.starts_with(trimmed, "{") && string.ends_with(trimmed, "}") {
    False -> Error(ParseError("Invalid JSON object"))
    True -> {
      // Extract method name (simplified)
      case extract_json_string(trimmed, "method") {
        Error(_) -> Error(InvalidRequest("Missing method field"))
        Ok(method) -> {
          // Extract id
          let id = extract_json_id(trimmed)

          // For now, accept minimal request
          Ok(RpcRequest(
            jsonrpc: rpc_version,
            id: id,
            method: method,
            params: ParamsNone,
          ))
        }
      }
    }
  }
}

fn extract_json_string(json: String, field: String) -> Result(String, Nil) {
  // Very simplified JSON string extraction
  let pattern = "\"" <> field <> "\""
  case string.contains(json, pattern) {
    False -> Error(Nil)
    True -> {
      // Find the value after the field
      case string.split(json, pattern) {
        [_, rest, ..] -> {
          case string.split(rest, "\"") {
            [_, value, ..] -> Ok(value)
            _ -> Error(Nil)
          }
        }
        _ -> Error(Nil)
      }
    }
  }
}

fn extract_json_id(json: String) -> RpcId {
  case extract_json_string(json, "id") {
    Ok(id_str) -> IdString(id_str)
    Error(_) -> IdNull
  }
}

// ============================================================================
// Response Building
// ============================================================================

/// Create a success response
pub fn success_response(id: RpcId, result: RpcValue) -> RpcResponse {
  RpcSuccess(jsonrpc: rpc_version, id: id, result: result)
}

/// Create an error response
pub fn error_response(id: RpcId, err: RpcError) -> RpcResponse {
  RpcFailure(
    jsonrpc: rpc_version,
    id: id,
    error: RpcErrorObject(
      code: error_code(err),
      message: error_message(err),
      data: None,
    ),
  )
}

/// Serialize response to JSON string
pub fn serialize_response(response: RpcResponse) -> String {
  case response {
    RpcSuccess(_, id, result) -> {
      "{\"jsonrpc\":\"" <> rpc_version <> "\"" <>
      ",\"id\":" <> serialize_id(id) <>
      ",\"result\":" <> serialize_value(result) <>
      "}"
    }
    RpcFailure(_, id, error) -> {
      "{\"jsonrpc\":\"" <> rpc_version <> "\"" <>
      ",\"id\":" <> serialize_id(id) <>
      ",\"error\":{\"code\":" <> int.to_string(error.code) <>
      ",\"message\":\"" <> error.message <> "\"}" <>
      "}"
    }
  }
}

fn serialize_id(id: RpcId) -> String {
  case id {
    IdString(s) -> "\"" <> s <> "\""
    IdInt(n) -> int.to_string(n)
    IdNull -> "null"
  }
}

fn serialize_value(val: RpcValue) -> String {
  case val {
    RpcNull -> "null"
    RpcBool(True) -> "true"
    RpcBool(False) -> "false"
    RpcInt(n) -> int.to_string(n)
    RpcFloat(f) -> float.to_string(f)
    RpcString(s) -> "\"" <> escape_json_string(s) <> "\""
    RpcArray(arr) -> {
      let items = list.map(arr, serialize_value)
      "[" <> string.join(items, ",") <> "]"
    }
    RpcObject(obj) -> {
      let pairs = dict.to_list(obj)
      let items = list.map(pairs, fn(pair) {
        let #(key, value) = pair
        "\"" <> key <> "\":" <> serialize_value(value)
      })
      "{" <> string.join(items, ",") <> "}"
    }
  }
}

fn escape_json_string(s: String) -> String {
  // Simple escaping - production would be more thorough
  s
  |> string.replace("\\", "\\\\")
  |> string.replace("\"", "\\\"")
  |> string.replace("\n", "\\n")
  |> string.replace("\r", "\\r")
  |> string.replace("\t", "\\t")
}

// ============================================================================
// Method Handler Types
// ============================================================================

/// RPC method handler function type
pub type MethodHandler =
  fn(RpcParams, RpcContext) -> Result(RpcValue, RpcError)

/// RPC context passed to handlers
pub type RpcContext {
  RpcContext(
    /// Is request authenticated
    authenticated: Bool,
    /// Remote address
    remote_addr: Option(String),
    /// Request timestamp
    request_time: Int,
  )
}

// ============================================================================
// RPC Server
// ============================================================================

/// RPC server configuration
pub type RpcConfig {
  RpcConfig(
    /// Bind address
    bind_addr: String,
    /// Port number
    port: Int,
    /// Username for auth (empty = no auth)
    username: String,
    /// Password for auth
    password: String,
    /// Whether to allow unauthenticated requests
    allow_anonymous: Bool,
    /// Enabled methods (empty = all)
    enabled_methods: List(String),
    /// Rate limiting enabled
    rate_limit_enabled: Bool,
  )
}

/// Default RPC configuration
pub fn default_config() -> RpcConfig {
  RpcConfig(
    bind_addr: "127.0.0.1",
    port: 8332,
    username: "",
    password: "",
    allow_anonymous: True,
    enabled_methods: [],
    rate_limit_enabled: True,
  )
}

/// RPC server state
pub type RpcServer {
  RpcServer(
    config: RpcConfig,
    handlers: Dict(String, MethodHandler),
    rate_limits: Dict(String, RateLimitEntry),
    request_count: Int,
    error_count: Int,
  )
}

/// Rate limit tracking entry
pub type RateLimitEntry {
  RateLimitEntry(
    count: Int,
    window_start: Int,
  )
}

/// Create a new RPC server
pub fn server_new(config: RpcConfig) -> RpcServer {
  let handlers = register_default_handlers(dict.new())

  RpcServer(
    config: config,
    handlers: handlers,
    rate_limits: dict.new(),
    request_count: 0,
    error_count: 0,
  )
}

/// Register a method handler
pub fn server_register(
  server: RpcServer,
  method: String,
  handler: MethodHandler,
) -> RpcServer {
  RpcServer(
    ..server,
    handlers: dict.insert(server.handlers, method, handler),
  )
}

/// Handle an RPC request
pub fn server_handle_request(
  server: RpcServer,
  request: RpcRequest,
  ctx: RpcContext,
) -> #(RpcServer, RpcResponse) {
  let new_count = server.request_count + 1
  let server_with_count = RpcServer(..server, request_count: new_count)

  // Check authentication if required
  case server.config.allow_anonymous || ctx.authenticated {
    False -> {
      let err_server = RpcServer(..server_with_count, error_count: server.error_count + 1)
      #(err_server, error_response(request.id, Unauthorized))
    }
    True -> {
      // Check if method is enabled
      case is_method_enabled(server.config, request.method) {
        False -> {
          let err_server = RpcServer(..server_with_count, error_count: server.error_count + 1)
          #(err_server, error_response(request.id, MethodNotFound(request.method)))
        }
        True -> {
          // Find and execute handler
          case dict.get(server.handlers, request.method) {
            Error(_) -> {
              let err_server = RpcServer(..server_with_count, error_count: server.error_count + 1)
              #(err_server, error_response(request.id, MethodNotFound(request.method)))
            }
            Ok(handler) -> {
              case handler(request.params, ctx) {
                Error(err) -> {
                  let err_server = RpcServer(..server_with_count, error_count: server.error_count + 1)
                  #(err_server, error_response(request.id, err))
                }
                Ok(result) -> {
                  #(server_with_count, success_response(request.id, result))
                }
              }
            }
          }
        }
      }
    }
  }
}

fn is_method_enabled(config: RpcConfig, method: String) -> Bool {
  case list.is_empty(config.enabled_methods) {
    True -> True  // All methods enabled
    False -> list.contains(config.enabled_methods, method)
  }
}

// ============================================================================
// Standard RPC Methods
// ============================================================================

fn register_default_handlers(handlers: Dict(String, MethodHandler)) -> Dict(String, MethodHandler) {
  handlers
  |> dict.insert("getblockchaininfo", handle_getblockchaininfo)
  |> dict.insert("getnetworkinfo", handle_getnetworkinfo)
  |> dict.insert("getmininginfo", handle_getmininginfo)
  |> dict.insert("getmempoolinfo", handle_getmempoolinfo)
  |> dict.insert("getpeerinfo", handle_getpeerinfo)
  |> dict.insert("getconnectioncount", handle_getconnectioncount)
  |> dict.insert("getbestblockhash", handle_getbestblockhash)
  |> dict.insert("getblockcount", handle_getblockcount)
  |> dict.insert("getblockhash", handle_getblockhash)
  |> dict.insert("getblock", handle_getblock)
  |> dict.insert("getblockheader", handle_getblockheader)
  |> dict.insert("getdifficulty", handle_getdifficulty)
  |> dict.insert("uptime", handle_uptime)
  |> dict.insert("help", handle_help)
  |> dict.insert("stop", handle_stop)
  |> dict.insert("echo", handle_echo)
  |> dict.insert("validateaddress", handle_validateaddress)
  |> dict.insert("verifymessage", handle_verifymessage)
  |> dict.insert("decoderawtransaction", handle_decoderawtransaction)
  |> dict.insert("decodescript", handle_decodescript)
  |> dict.insert("getrawtransaction", handle_getrawtransaction)
  |> dict.insert("getrawmempool", handle_getrawmempool)
  |> dict.insert("sendrawtransaction", handle_sendrawtransaction)
  |> dict.insert("gettxout", handle_gettxout)
  |> dict.insert("getblocktemplate", handle_getblocktemplate)
}

// Blockchain info
fn handle_getblockchaininfo(_params: RpcParams, _ctx: RpcContext) -> Result(RpcValue, RpcError) {
  let result = dict.new()
    |> dict.insert("chain", RpcString("main"))
    |> dict.insert("blocks", RpcInt(0))
    |> dict.insert("headers", RpcInt(0))
    |> dict.insert("bestblockhash", RpcString("0000000000000000000000000000000000000000000000000000000000000000"))
    |> dict.insert("difficulty", RpcFloat(1.0))
    |> dict.insert("time", RpcInt(0))
    |> dict.insert("mediantime", RpcInt(0))
    |> dict.insert("verificationprogress", RpcFloat(0.0))
    |> dict.insert("initialblockdownload", RpcBool(True))
    |> dict.insert("chainwork", RpcString("0000000000000000000000000000000000000000000000000000000000000000"))
    |> dict.insert("size_on_disk", RpcInt(0))
    |> dict.insert("pruned", RpcBool(False))
    |> dict.insert("warnings", RpcString(""))

  Ok(RpcObject(result))
}

// Network info
fn handle_getnetworkinfo(_params: RpcParams, _ctx: RpcContext) -> Result(RpcValue, RpcError) {
  let result = dict.new()
    |> dict.insert("version", RpcInt(250000))
    |> dict.insert("subversion", RpcString("/oni:0.1.0/"))
    |> dict.insert("protocolversion", RpcInt(70016))
    |> dict.insert("localservices", RpcString("000000000000040d"))
    |> dict.insert("localservicesnames", RpcArray([
      RpcString("NETWORK"),
      RpcString("WITNESS"),
      RpcString("NETWORK_LIMITED"),
    ]))
    |> dict.insert("localrelay", RpcBool(True))
    |> dict.insert("timeoffset", RpcInt(0))
    |> dict.insert("networkactive", RpcBool(True))
    |> dict.insert("connections", RpcInt(0))
    |> dict.insert("connections_in", RpcInt(0))
    |> dict.insert("connections_out", RpcInt(0))
    |> dict.insert("networks", RpcArray([]))
    |> dict.insert("relayfee", RpcFloat(0.00001))
    |> dict.insert("incrementalfee", RpcFloat(0.00001))
    |> dict.insert("localaddresses", RpcArray([]))
    |> dict.insert("warnings", RpcString(""))

  Ok(RpcObject(result))
}

// Mining info
fn handle_getmininginfo(_params: RpcParams, _ctx: RpcContext) -> Result(RpcValue, RpcError) {
  let result = dict.new()
    |> dict.insert("blocks", RpcInt(0))
    |> dict.insert("difficulty", RpcFloat(1.0))
    |> dict.insert("networkhashps", RpcFloat(0.0))
    |> dict.insert("pooledtx", RpcInt(0))
    |> dict.insert("chain", RpcString("main"))
    |> dict.insert("warnings", RpcString(""))

  Ok(RpcObject(result))
}

// Mempool info
fn handle_getmempoolinfo(_params: RpcParams, _ctx: RpcContext) -> Result(RpcValue, RpcError) {
  let result = dict.new()
    |> dict.insert("loaded", RpcBool(True))
    |> dict.insert("size", RpcInt(0))
    |> dict.insert("bytes", RpcInt(0))
    |> dict.insert("usage", RpcInt(0))
    |> dict.insert("total_fee", RpcFloat(0.0))
    |> dict.insert("maxmempool", RpcInt(300000000))
    |> dict.insert("mempoolminfee", RpcFloat(0.00001))
    |> dict.insert("minrelaytxfee", RpcFloat(0.00001))
    |> dict.insert("incrementalrelayfee", RpcFloat(0.00001))
    |> dict.insert("unbroadcastcount", RpcInt(0))

  Ok(RpcObject(result))
}

// Peer info
fn handle_getpeerinfo(_params: RpcParams, _ctx: RpcContext) -> Result(RpcValue, RpcError) {
  Ok(RpcArray([]))
}

// Connection count
fn handle_getconnectioncount(_params: RpcParams, _ctx: RpcContext) -> Result(RpcValue, RpcError) {
  Ok(RpcInt(0))
}

// Best block hash
fn handle_getbestblockhash(_params: RpcParams, _ctx: RpcContext) -> Result(RpcValue, RpcError) {
  let genesis = oni_bitcoin.mainnet_params().genesis_hash
  Ok(RpcString(oni_bitcoin.block_hash_to_hex(genesis)))
}

// Block count
fn handle_getblockcount(_params: RpcParams, _ctx: RpcContext) -> Result(RpcValue, RpcError) {
  Ok(RpcInt(0))
}

// Difficulty
fn handle_getdifficulty(_params: RpcParams, _ctx: RpcContext) -> Result(RpcValue, RpcError) {
  Ok(RpcFloat(1.0))
}

// Uptime
fn handle_uptime(_params: RpcParams, _ctx: RpcContext) -> Result(RpcValue, RpcError) {
  Ok(RpcInt(0))
}

// Help
fn handle_help(_params: RpcParams, _ctx: RpcContext) -> Result(RpcValue, RpcError) {
  let help_text = "
== Blockchain ==
getbestblockhash
getblock \"blockhash\" ( verbosity )
getblockchaininfo
getblockcount
getblockhash height
getblockheader \"blockhash\" ( verbose )
getblocktemplate ( \"template_request\" )
getdifficulty
gettxout \"txid\" n ( include_mempool )

== Network ==
getconnectioncount
getnetworkinfo
getpeerinfo

== Mining ==
getblocktemplate ( \"template_request\" )
getmininginfo

== Mempool ==
getmempoolinfo
getrawmempool ( verbose mempool_sequence )

== Rawtransactions ==
decoderawtransaction \"hexstring\" ( iswitness )
decodescript \"hexstring\"
getrawtransaction \"txid\" ( verbose \"blockhash\" )
sendrawtransaction \"hexstring\" ( maxfeerate )

== Util ==
validateaddress \"address\"
verifymessage \"address\" \"signature\" \"message\"

== Control ==
echo \"message\" ...
help ( \"command\" )
stop
uptime
"

  Ok(RpcString(help_text))
}

// Stop node
fn handle_stop(_params: RpcParams, _ctx: RpcContext) -> Result(RpcValue, RpcError) {
  Ok(RpcString("oni stopping"))
}

// Echo (for testing)
fn handle_echo(params: RpcParams, _ctx: RpcContext) -> Result(RpcValue, RpcError) {
  case params {
    ParamsArray(arr) -> Ok(RpcArray(arr))
    ParamsObject(obj) -> Ok(RpcObject(obj))
    ParamsNone -> Ok(RpcNull)
  }
}

// Validate address
fn handle_validateaddress(params: RpcParams, _ctx: RpcContext) -> Result(RpcValue, RpcError) {
  case params {
    ParamsArray([RpcString(address), ..]) -> {
      // Basic validation - real implementation would check address format
      let is_valid = string.length(address) >= 26 && string.length(address) <= 90
      let result = dict.new()
        |> dict.insert("isvalid", RpcBool(is_valid))
        |> dict.insert("address", RpcString(address))

      Ok(RpcObject(result))
    }
    _ -> Error(InvalidParams("validateaddress \"address\""))
  }
}

// Verify message
fn handle_verifymessage(_params: RpcParams, _ctx: RpcContext) -> Result(RpcValue, RpcError) {
  // Placeholder - would verify Bitcoin signed message
  Ok(RpcBool(False))
}

// Decode raw transaction
fn handle_decoderawtransaction(params: RpcParams, _ctx: RpcContext) -> Result(RpcValue, RpcError) {
  case params {
    ParamsArray([RpcString(hex), ..]) -> {
      case oni_bitcoin.hex_decode(hex) {
        Error(_) -> Error(InvalidParams("Invalid hex string"))
        Ok(bytes) -> {
          case oni_bitcoin.decode_tx(bytes) {
            Error(_) -> Error(InvalidParams("TX decode failed"))
            Ok(#(tx, _)) -> {
              let txid = oni_bitcoin.txid_from_tx(tx)
              let result = dict.new()
                |> dict.insert("txid", RpcString(oni_bitcoin.txid_to_hex(txid)))
                |> dict.insert("version", RpcInt(tx.version))
                |> dict.insert("locktime", RpcInt(tx.lock_time))
                |> dict.insert("vin", encode_tx_inputs(tx.inputs))
                |> dict.insert("vout", encode_tx_outputs(tx.outputs))

              Ok(RpcObject(result))
            }
          }
        }
      }
    }
    _ -> Error(InvalidParams("decoderawtransaction \"hexstring\""))
  }
}

fn encode_tx_inputs(inputs: List(oni_bitcoin.TxIn)) -> RpcValue {
  RpcArray(list.index_map(inputs, fn(input, _idx) {
    let obj = dict.new()
      |> dict.insert("txid", RpcString(oni_bitcoin.txid_to_hex(input.prevout.txid)))
      |> dict.insert("vout", RpcInt(input.prevout.vout))
      |> dict.insert("sequence", RpcInt(input.sequence))
    RpcObject(obj)
  }))
}

fn encode_tx_outputs(outputs: List(oni_bitcoin.TxOut)) -> RpcValue {
  RpcArray(list.index_map(outputs, fn(output, idx) {
    let obj = dict.new()
      |> dict.insert("value", RpcFloat(int.to_float(oni_bitcoin.amount_to_sats(output.value)) /. 100_000_000.0))
      |> dict.insert("n", RpcInt(idx))
    RpcObject(obj)
  }))
}

// Decode script
fn handle_decodescript(params: RpcParams, _ctx: RpcContext) -> Result(RpcValue, RpcError) {
  case params {
    ParamsArray([RpcString(hex), ..]) -> {
      case oni_bitcoin.hex_decode(hex) {
        Error(_) -> Error(InvalidParams("Invalid hex string"))
        Ok(_bytes) -> {
          let result = dict.new()
            |> dict.insert("asm", RpcString(""))
            |> dict.insert("desc", RpcString("raw(" <> hex <> ")"))
            |> dict.insert("type", RpcString("nonstandard"))

          Ok(RpcObject(result))
        }
      }
    }
    _ -> Error(InvalidParams("decodescript \"hexstring\""))
  }
}

// Get raw mempool
fn handle_getrawmempool(_params: RpcParams, _ctx: RpcContext) -> Result(RpcValue, RpcError) {
  Ok(RpcArray([]))
}

// Send raw transaction
fn handle_sendrawtransaction(params: RpcParams, _ctx: RpcContext) -> Result(RpcValue, RpcError) {
  case params {
    ParamsArray([RpcString(hex), ..]) -> {
      case oni_bitcoin.hex_decode(hex) {
        Error(_) -> Error(InvalidParams("Invalid hex string"))
        Ok(bytes) -> {
          case oni_bitcoin.decode_tx(bytes) {
            Error(_) -> Error(InvalidParams("TX decode failed"))
            Ok(#(tx, _)) -> {
              let txid = oni_bitcoin.txid_from_tx(tx)
              Ok(RpcString(oni_bitcoin.txid_to_hex(txid)))
            }
          }
        }
      }
    }
    _ -> Error(InvalidParams("sendrawtransaction \"hexstring\""))
  }
}

// Get block hash by height
fn handle_getblockhash(params: RpcParams, _ctx: RpcContext) -> Result(RpcValue, RpcError) {
  case params {
    ParamsArray([RpcInt(height), ..]) -> {
      // In a real implementation, we would look up the block hash at this height
      // For now, return genesis for height 0, error otherwise
      case height {
        0 -> {
          let genesis = oni_bitcoin.mainnet_params().genesis_hash
          Ok(RpcString(oni_bitcoin.block_hash_to_hex(genesis)))
        }
        _ -> Error(Internal("Block not found"))
      }
    }
    _ -> Error(InvalidParams("getblockhash height"))
  }
}

// Get block data
fn handle_getblock(params: RpcParams, _ctx: RpcContext) -> Result(RpcValue, RpcError) {
  case params {
    ParamsArray([RpcString(blockhash), ..rest]) -> {
      // Determine verbosity level (0=hex, 1=json, 2=json+tx)
      let verbosity = case rest {
        [RpcInt(v), ..] -> v
        _ -> 1
      }

      // Validate block hash
      case string.length(blockhash) == 64 {
        False -> Error(InvalidParams("Invalid block hash"))
        True -> {
          // Return block info based on verbosity
          case verbosity {
            0 -> {
              // Return raw hex - placeholder
              Ok(RpcString(""))
            }
            _ -> {
              // Return JSON object
              let result = dict.new()
                |> dict.insert("hash", RpcString(blockhash))
                |> dict.insert("confirmations", RpcInt(1))
                |> dict.insert("height", RpcInt(0))
                |> dict.insert("version", RpcInt(1))
                |> dict.insert("versionHex", RpcString("00000001"))
                |> dict.insert("merkleroot", RpcString("0000000000000000000000000000000000000000000000000000000000000000"))
                |> dict.insert("time", RpcInt(0))
                |> dict.insert("mediantime", RpcInt(0))
                |> dict.insert("nonce", RpcInt(0))
                |> dict.insert("bits", RpcString("1d00ffff"))
                |> dict.insert("difficulty", RpcFloat(1.0))
                |> dict.insert("chainwork", RpcString("0000000000000000000000000000000000000000000000000000000000000000"))
                |> dict.insert("nTx", RpcInt(1))
                |> dict.insert("tx", RpcArray([]))

              Ok(RpcObject(result))
            }
          }
        }
      }
    }
    _ -> Error(InvalidParams("getblock \"blockhash\" ( verbosity )"))
  }
}

// Get block header
fn handle_getblockheader(params: RpcParams, _ctx: RpcContext) -> Result(RpcValue, RpcError) {
  case params {
    ParamsArray([RpcString(blockhash), ..rest]) -> {
      // Determine if verbose (default true)
      let verbose = case rest {
        [RpcBool(v), ..] -> v
        _ -> True
      }

      // Validate block hash
      case string.length(blockhash) == 64 {
        False -> Error(InvalidParams("Invalid block hash"))
        True -> {
          case verbose {
            False -> {
              // Return raw hex header (80 bytes)
              Ok(RpcString(""))
            }
            True -> {
              // Return JSON object
              let result = dict.new()
                |> dict.insert("hash", RpcString(blockhash))
                |> dict.insert("confirmations", RpcInt(1))
                |> dict.insert("height", RpcInt(0))
                |> dict.insert("version", RpcInt(1))
                |> dict.insert("versionHex", RpcString("00000001"))
                |> dict.insert("merkleroot", RpcString("0000000000000000000000000000000000000000000000000000000000000000"))
                |> dict.insert("time", RpcInt(0))
                |> dict.insert("mediantime", RpcInt(0))
                |> dict.insert("nonce", RpcInt(0))
                |> dict.insert("bits", RpcString("1d00ffff"))
                |> dict.insert("difficulty", RpcFloat(1.0))
                |> dict.insert("chainwork", RpcString("0000000000000000000000000000000000000000000000000000000000000000"))
                |> dict.insert("nTx", RpcInt(1))

              Ok(RpcObject(result))
            }
          }
        }
      }
    }
    _ -> Error(InvalidParams("getblockheader \"blockhash\" ( verbose )"))
  }
}

// Get raw transaction
fn handle_getrawtransaction(params: RpcParams, _ctx: RpcContext) -> Result(RpcValue, RpcError) {
  case params {
    ParamsArray([RpcString(txid), ..rest]) -> {
      // Determine verbosity
      let verbose = case rest {
        [RpcBool(v), ..] -> v
        [RpcInt(v), ..] -> v != 0
        _ -> False
      }

      // Validate txid
      case string.length(txid) == 64 {
        False -> Error(InvalidParams("Invalid txid"))
        True -> {
          case verbose {
            False -> {
              // Return raw hex
              Ok(RpcString(""))
            }
            True -> {
              // Return JSON object
              let result = dict.new()
                |> dict.insert("txid", RpcString(txid))
                |> dict.insert("hash", RpcString(txid))
                |> dict.insert("version", RpcInt(1))
                |> dict.insert("size", RpcInt(0))
                |> dict.insert("vsize", RpcInt(0))
                |> dict.insert("weight", RpcInt(0))
                |> dict.insert("locktime", RpcInt(0))
                |> dict.insert("vin", RpcArray([]))
                |> dict.insert("vout", RpcArray([]))

              Ok(RpcObject(result))
            }
          }
        }
      }
    }
    _ -> Error(InvalidParams("getrawtransaction \"txid\" ( verbose \"blockhash\" )"))
  }
}

// Get transaction output
fn handle_gettxout(params: RpcParams, _ctx: RpcContext) -> Result(RpcValue, RpcError) {
  case params {
    ParamsArray([RpcString(txid), RpcInt(n), ..]) -> {
      // Validate txid
      case string.length(txid) == 64 {
        False -> Error(InvalidParams("Invalid txid"))
        True -> {
          // In real implementation, look up UTXO
          // For now, return null (not found)
          let _ = n
          Ok(RpcNull)
        }
      }
    }
    _ -> Error(InvalidParams("gettxout \"txid\" n ( include_mempool )"))
  }
}

// Get block template (for mining)
fn handle_getblocktemplate(_params: RpcParams, _ctx: RpcContext) -> Result(RpcValue, RpcError) {
  // Return a basic block template
  let result = dict.new()
    |> dict.insert("version", RpcInt(536870912))  // BIP9 versionbits
    |> dict.insert("previousblockhash", RpcString("0000000000000000000000000000000000000000000000000000000000000000"))
    |> dict.insert("transactions", RpcArray([]))
    |> dict.insert("coinbaseaux", RpcObject(dict.new()))
    |> dict.insert("coinbasevalue", RpcInt(625_000_000))  // 6.25 BTC subsidy
    |> dict.insert("target", RpcString("00000000ffff0000000000000000000000000000000000000000000000000000"))
    |> dict.insert("mintime", RpcInt(0))
    |> dict.insert("mutable", RpcArray([RpcString("time"), RpcString("transactions"), RpcString("prevblock")]))
    |> dict.insert("noncerange", RpcString("00000000ffffffff"))
    |> dict.insert("sigoplimit", RpcInt(80000))
    |> dict.insert("sizelimit", RpcInt(4000000))
    |> dict.insert("weightlimit", RpcInt(4000000))
    |> dict.insert("curtime", RpcInt(0))
    |> dict.insert("bits", RpcString("1d00ffff"))
    |> dict.insert("height", RpcInt(0))

  Ok(RpcObject(result))
}

// ============================================================================
// RPC Server Statistics
// ============================================================================

/// RPC server statistics
pub type RpcStats {
  RpcStats(
    request_count: Int,
    error_count: Int,
    active_connections: Int,
    uptime_seconds: Int,
  )
}

/// Get server statistics
pub fn server_stats(server: RpcServer) -> RpcStats {
  RpcStats(
    request_count: server.request_count,
    error_count: server.error_count,
    active_connections: 0,
    uptime_seconds: 0,
  )
}
