import gleam/dict
import gleam/option.{None, Some}
import gleam/string
import gleeunit
import gleeunit/should
import oni_rpc

pub fn main() {
  gleeunit.main()
}

// ============================================================================
// RPC Value Tests
// ============================================================================

pub fn value_to_string_test() {
  oni_rpc.value_to_string(oni_rpc.RpcString("hello"))
  |> should.equal(Some("hello"))
}

pub fn value_to_string_int_test() {
  oni_rpc.value_to_string(oni_rpc.RpcInt(42))
  |> should.equal(Some("42"))
}

pub fn value_to_string_null_test() {
  oni_rpc.value_to_string(oni_rpc.RpcNull)
  |> should.equal(None)
}

pub fn value_to_int_test() {
  oni_rpc.value_to_int(oni_rpc.RpcInt(123))
  |> should.equal(Some(123))
}

pub fn value_to_int_from_string_test() {
  oni_rpc.value_to_int(oni_rpc.RpcString("123"))
  |> should.equal(None)
}

pub fn value_to_bool_test() {
  oni_rpc.value_to_bool(oni_rpc.RpcBool(True))
  |> should.equal(Some(True))
}

pub fn value_get_array_element_test() {
  let arr =
    oni_rpc.RpcArray([
      oni_rpc.RpcInt(1),
      oni_rpc.RpcInt(2),
      oni_rpc.RpcInt(3),
    ])

  case oni_rpc.value_get_array_element(arr, 1) {
    Some(oni_rpc.RpcInt(2)) -> should.be_ok(Ok(Nil))
    _ -> should.fail()
  }
}

pub fn value_get_field_test() {
  let obj =
    oni_rpc.RpcObject(
      dict.new()
      |> dict.insert("name", oni_rpc.RpcString("test")),
    )

  case oni_rpc.value_get_field(obj, "name") {
    Some(oni_rpc.RpcString("test")) -> should.be_ok(Ok(Nil))
    _ -> should.fail()
  }
}

// ============================================================================
// Error Code Tests
// ============================================================================

pub fn error_code_parse_test() {
  oni_rpc.error_code(oni_rpc.ParseError("test"))
  |> should.equal(oni_rpc.err_parse)
}

pub fn error_code_invalid_request_test() {
  oni_rpc.error_code(oni_rpc.InvalidRequest("test"))
  |> should.equal(oni_rpc.err_invalid_request)
}

pub fn error_code_method_not_found_test() {
  oni_rpc.error_code(oni_rpc.MethodNotFound("test"))
  |> should.equal(oni_rpc.err_method_not_found)
}

pub fn error_code_invalid_params_test() {
  oni_rpc.error_code(oni_rpc.InvalidParams("test"))
  |> should.equal(oni_rpc.err_invalid_params)
}

pub fn error_code_internal_test() {
  oni_rpc.error_code(oni_rpc.Internal("test"))
  |> should.equal(oni_rpc.err_internal)
}

// ============================================================================
// Response Tests
// ============================================================================

pub fn success_response_test() {
  let response =
    oni_rpc.success_response(oni_rpc.IdInt(1), oni_rpc.RpcString("result"))

  case response {
    oni_rpc.RpcSuccess(_, oni_rpc.IdInt(1), oni_rpc.RpcString("result")) ->
      should.be_ok(Ok(Nil))
    _ -> should.fail()
  }
}

pub fn error_response_test() {
  let response =
    oni_rpc.error_response(oni_rpc.IdInt(1), oni_rpc.MethodNotFound("foo"))

  case response {
    oni_rpc.RpcFailure(_, oni_rpc.IdInt(1), err) -> {
      err.code |> should.equal(oni_rpc.err_method_not_found)
    }
    _ -> should.fail()
  }
}

pub fn serialize_success_response_test() {
  let response = oni_rpc.success_response(oni_rpc.IdInt(1), oni_rpc.RpcInt(42))

  let json = oni_rpc.serialize_response(response)

  // Check that it contains expected parts
  case string.contains(json, "\"result\":42") {
    True -> should.be_ok(Ok(Nil))
    False -> should.fail()
  }
}

pub fn serialize_error_response_test() {
  let response =
    oni_rpc.error_response(
      oni_rpc.IdString("test"),
      oni_rpc.ParseError("bad json"),
    )

  let json = oni_rpc.serialize_response(response)

  case string.contains(json, "\"error\"") {
    True -> should.be_ok(Ok(Nil))
    False -> should.fail()
  }
}

// ============================================================================
// Server Tests
// ============================================================================

pub fn server_new_test() {
  let config = oni_rpc.default_config()
  let server = oni_rpc.server_new(config)

  let stats = oni_rpc.server_stats(server)
  stats.request_count |> should.equal(0)
  stats.error_count |> should.equal(0)
}

pub fn server_handle_unknown_method_test() {
  let config = oni_rpc.default_config()
  let server = oni_rpc.server_new(config)

  let request =
    oni_rpc.RpcRequest(
      jsonrpc: "2.0",
      id: oni_rpc.IdInt(1),
      method: "unknownmethod12345",
      params: oni_rpc.ParamsNone,
    )

  let ctx =
    oni_rpc.RpcContext(authenticated: True, remote_addr: None, request_time: 0)

  let #(_new_server, response) =
    oni_rpc.server_handle_request(server, request, ctx)

  case response {
    oni_rpc.RpcFailure(_, _, err) -> {
      err.code |> should.equal(oni_rpc.err_method_not_found)
    }
    _ -> should.fail()
  }
}

pub fn server_handle_getblockcount_test() {
  let config = oni_rpc.default_config()
  let server = oni_rpc.server_new(config)

  let request =
    oni_rpc.RpcRequest(
      jsonrpc: "2.0",
      id: oni_rpc.IdInt(1),
      method: "getblockcount",
      params: oni_rpc.ParamsNone,
    )

  let ctx =
    oni_rpc.RpcContext(authenticated: True, remote_addr: None, request_time: 0)

  let #(_new_server, response) =
    oni_rpc.server_handle_request(server, request, ctx)

  case response {
    oni_rpc.RpcSuccess(_, _, oni_rpc.RpcInt(0)) -> should.be_ok(Ok(Nil))
    _ -> should.fail()
  }
}

pub fn server_handle_help_test() {
  let config = oni_rpc.default_config()
  let server = oni_rpc.server_new(config)

  let request =
    oni_rpc.RpcRequest(
      jsonrpc: "2.0",
      id: oni_rpc.IdInt(1),
      method: "help",
      params: oni_rpc.ParamsNone,
    )

  let ctx =
    oni_rpc.RpcContext(authenticated: True, remote_addr: None, request_time: 0)

  let #(_new_server, response) =
    oni_rpc.server_handle_request(server, request, ctx)

  case response {
    oni_rpc.RpcSuccess(_, _, oni_rpc.RpcString(_)) -> should.be_ok(Ok(Nil))
    _ -> should.fail()
  }
}

pub fn server_handle_unauthorized_test() {
  let config =
    oni_rpc.RpcConfig(..oni_rpc.default_config(), allow_anonymous: False)
  let server = oni_rpc.server_new(config)

  let request =
    oni_rpc.RpcRequest(
      jsonrpc: "2.0",
      id: oni_rpc.IdInt(1),
      method: "getblockcount",
      params: oni_rpc.ParamsNone,
    )

  let ctx =
    oni_rpc.RpcContext(
      authenticated: False,
      // Not authenticated
      remote_addr: None,
      request_time: 0,
    )

  let #(_new_server, response) =
    oni_rpc.server_handle_request(server, request, ctx)

  case response {
    oni_rpc.RpcFailure(_, _, _) -> should.be_ok(Ok(Nil))
    _ -> should.fail()
  }
}

pub fn server_stats_increment_test() {
  let config = oni_rpc.default_config()
  let server = oni_rpc.server_new(config)

  let request =
    oni_rpc.RpcRequest(
      jsonrpc: "2.0",
      id: oni_rpc.IdInt(1),
      method: "getblockcount",
      params: oni_rpc.ParamsNone,
    )

  let ctx =
    oni_rpc.RpcContext(authenticated: True, remote_addr: None, request_time: 0)

  let #(server1, _) = oni_rpc.server_handle_request(server, request, ctx)
  let #(server2, _) = oni_rpc.server_handle_request(server1, request, ctx)

  let stats = oni_rpc.server_stats(server2)
  stats.request_count |> should.equal(2)
}

// ============================================================================
// Config Tests
// ============================================================================

pub fn default_config_test() {
  let config = oni_rpc.default_config()

  config.port |> should.equal(8332)
  config.bind_addr |> should.equal("127.0.0.1")
  config.allow_anonymous |> should.be_true
}
