/// RPC subsystem placeholder.
///
/// The full implementation will provide:
/// - JSON-RPC over HTTP
/// - auth + ACL + rate limiting
/// - health and metrics endpoints

pub type RpcError {
  Unauthorized
  InvalidRequest
  MethodNotFound
  Internal(String)
}

pub fn hello() -> String {
  "oni_rpc (scaffold)"
}
