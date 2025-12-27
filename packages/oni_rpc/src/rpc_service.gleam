// rpc_service.gleam - Integrated RPC service with node state
//
// This module provides an RPC service that connects to the node's
// chainstate, mempool, and sync actors to return real data.
// It acts as the bridge between external RPC requests and
// the internal node state.
//
// Usage:
//   1. Create adapter handles using node_rpc.create_rpc_handles()
//   2. Create the RPC service with new_with_handles()
//   3. Or start as an actor with start()
//
// The service registers stateful handlers that query actual node state.

import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import oni_bitcoin
import oni_rpc.{
  type MethodHandler, type RpcConfig, type RpcContext, type RpcError,
  type RpcParams, type RpcRequest, type RpcResponse, type RpcServer,
  type RpcValue, Internal, InvalidParams, ParamsArray, ParamsNone,
  RpcArray, RpcBool, RpcFloat, RpcInt, RpcNull, RpcObject, RpcString,
}

// ============================================================================
// Service Types
// ============================================================================

/// Message types for the RPC service actor
pub type RpcServiceMsg {
  /// Handle an RPC request
  HandleRequest(
    request: RpcRequest,
    ctx: RpcContext,
    reply: Subject(RpcResponse),
  )
  /// Get service statistics
  GetStats(reply: Subject(ServiceStats))
  /// Shutdown the service
  Shutdown
}

/// RPC service statistics
pub type ServiceStats {
  ServiceStats(
    requests_handled: Int,
    requests_failed: Int,
    uptime_seconds: Int,
  )
}

/// Node handles for accessing actors (provided by node_rpc adapters)
pub type NodeHandles {
  NodeHandles(
    chainstate: Subject(ChainstateQuery),
    mempool: Subject(MempoolQuery),
    sync: Subject(SyncQuery),
  )
}

/// Chainstate query messages
/// These are sent to the chainstate adapter actor
pub type ChainstateQuery {
  QueryTip(reply: Subject(Option(oni_bitcoin.BlockHash)))
  QueryHeight(reply: Subject(Int))
  QueryNetwork(reply: Subject(oni_bitcoin.Network))
}

/// Mempool query messages
/// These are sent to the mempool adapter actor
pub type MempoolQuery {
  QueryMempoolSize(reply: Subject(Int))
  QueryMempoolTxids(reply: Subject(List(oni_bitcoin.Txid)))
}

/// Sync query messages
/// These are sent to the sync adapter actor
pub type SyncQuery {
  QuerySyncState(reply: Subject(SyncState))
}

/// Sync state info returned from sync adapter
pub type SyncState {
  SyncState(
    state: String,
    headers_height: Int,
    blocks_height: Int,
    is_syncing: Bool,
  )
}

/// RPC service state
pub type RpcServiceState {
  RpcServiceState(
    server: RpcServer,
    handles: Option(NodeHandles),
    start_time: Int,
    requests_handled: Int,
    requests_failed: Int,
  )
}

// ============================================================================
// Service Creation
// ============================================================================

/// Create a new RPC service without node handles (standalone mode)
pub fn new_standalone(config: RpcConfig) -> RpcServiceState {
  RpcServiceState(
    server: oni_rpc.server_new(config),
    handles: None,
    start_time: get_timestamp(),
    requests_handled: 0,
    requests_failed: 0,
  )
}

/// Create a new RPC service with node handles
pub fn new_with_handles(
  config: RpcConfig,
  handles: NodeHandles,
) -> RpcServiceState {
  let base_server = oni_rpc.server_new(config)

  // Register handlers that use actual node state
  let server = register_stateful_handlers(base_server, handles)

  RpcServiceState(
    server: server,
    handles: Some(handles),
    start_time: get_timestamp(),
    requests_handled: 0,
    requests_failed: 0,
  )
}

/// Start the RPC service as an actor
pub fn start(
  config: RpcConfig,
  handles: Option(NodeHandles),
) -> Result(Subject(RpcServiceMsg), actor.StartError) {
  let initial_state = case handles {
    Some(h) -> new_with_handles(config, h)
    None -> new_standalone(config)
  }

  actor.start(initial_state, handle_message)
}

// ============================================================================
// Message Handling
// ============================================================================

fn handle_message(
  msg: RpcServiceMsg,
  state: RpcServiceState,
) -> actor.Next(RpcServiceMsg, RpcServiceState) {
  case msg {
    HandleRequest(request, ctx, reply) -> {
      let #(new_server, response) =
        oni_rpc.server_handle_request(state.server, request, ctx)

      // Track success/failure
      let #(handled, failed) = case response {
        oni_rpc.RpcSuccess(_, _, _) ->
          #(state.requests_handled + 1, state.requests_failed)
        oni_rpc.RpcFailure(_, _, _) ->
          #(state.requests_handled + 1, state.requests_failed + 1)
      }

      process.send(reply, response)

      actor.continue(RpcServiceState(
        ..state,
        server: new_server,
        requests_handled: handled,
        requests_failed: failed,
      ))
    }

    GetStats(reply) -> {
      let stats = ServiceStats(
        requests_handled: state.requests_handled,
        requests_failed: state.requests_failed,
        uptime_seconds: get_timestamp() - state.start_time,
      )
      process.send(reply, stats)
      actor.continue(state)
    }

    Shutdown -> {
      actor.Stop(process.Normal)
    }
  }
}

// ============================================================================
// Stateful Handler Registration
// ============================================================================

/// Register handlers that query actual node state
fn register_stateful_handlers(
  server: RpcServer,
  handles: NodeHandles,
) -> RpcServer {
  // Create closures that capture the handles
  let chainstate = handles.chainstate
  let mempool = handles.mempool
  let sync = handles.sync

  server
  |> oni_rpc.server_register("getblockcount", create_getblockcount_handler(chainstate))
  |> oni_rpc.server_register("getbestblockhash", create_getbestblockhash_handler(chainstate))
  |> oni_rpc.server_register("getblockchaininfo", create_getblockchaininfo_handler(chainstate, sync))
  |> oni_rpc.server_register("getmempoolinfo", create_getmempoolinfo_handler(mempool))
  |> oni_rpc.server_register("getrawmempool", create_getrawmempool_handler(mempool))
}

// ============================================================================
// Stateful Handlers
// ============================================================================

/// Create handler for getblockcount that queries chainstate
fn create_getblockcount_handler(
  chainstate: Subject(ChainstateQuery),
) -> MethodHandler {
  fn(_params: RpcParams, _ctx: RpcContext) -> Result(RpcValue, RpcError) {
    let height = query_chainstate_height(chainstate)
    Ok(RpcInt(height))
  }
}

/// Create handler for getbestblockhash that queries chainstate
fn create_getbestblockhash_handler(
  chainstate: Subject(ChainstateQuery),
) -> MethodHandler {
  fn(_params: RpcParams, _ctx: RpcContext) -> Result(RpcValue, RpcError) {
    case query_chainstate_tip(chainstate) {
      Some(hash) -> Ok(RpcString(oni_bitcoin.block_hash_to_hex(hash)))
      None -> Error(Internal("No tip available"))
    }
  }
}

/// Create handler for getblockchaininfo that queries chainstate and sync
fn create_getblockchaininfo_handler(
  chainstate: Subject(ChainstateQuery),
  sync: Subject(SyncQuery),
) -> MethodHandler {
  fn(_params: RpcParams, _ctx: RpcContext) -> Result(RpcValue, RpcError) {
    let height = query_chainstate_height(chainstate)
    let tip = query_chainstate_tip(chainstate)
    let network = query_chainstate_network(chainstate)
    let sync_state = query_sync_state(sync)

    let chain_name = case network {
      oni_bitcoin.Mainnet -> "main"
      oni_bitcoin.Testnet -> "test"
      oni_bitcoin.Regtest -> "regtest"
      oni_bitcoin.Signet -> "signet"
    }

    let tip_hex = case tip {
      Some(hash) -> oni_bitcoin.block_hash_to_hex(hash)
      None -> "0000000000000000000000000000000000000000000000000000000000000000"
    }

    let ibd = sync_state.is_syncing || height == 0

    let result = dict.new()
      |> dict.insert("chain", RpcString(chain_name))
      |> dict.insert("blocks", RpcInt(height))
      |> dict.insert("headers", RpcInt(sync_state.headers_height))
      |> dict.insert("bestblockhash", RpcString(tip_hex))
      |> dict.insert("difficulty", RpcFloat(1.0))
      |> dict.insert("time", RpcInt(0))
      |> dict.insert("mediantime", RpcInt(0))
      |> dict.insert("verificationprogress", RpcFloat(
        case sync_state.headers_height > 0 {
          True -> int.to_float(height) /. int.to_float(sync_state.headers_height)
          False -> 0.0
        }
      ))
      |> dict.insert("initialblockdownload", RpcBool(ibd))
      |> dict.insert("chainwork", RpcString("0000000000000000000000000000000000000000000000000000000000000000"))
      |> dict.insert("size_on_disk", RpcInt(0))
      |> dict.insert("pruned", RpcBool(False))
      |> dict.insert("warnings", RpcString(""))

    Ok(RpcObject(result))
  }
}

/// Create handler for getmempoolinfo that queries mempool
fn create_getmempoolinfo_handler(
  mempool: Subject(MempoolQuery),
) -> MethodHandler {
  fn(_params: RpcParams, _ctx: RpcContext) -> Result(RpcValue, RpcError) {
    let size = query_mempool_size(mempool)

    let result = dict.new()
      |> dict.insert("loaded", RpcBool(True))
      |> dict.insert("size", RpcInt(size))
      |> dict.insert("bytes", RpcInt(size * 250))  // Estimate ~250 bytes per tx
      |> dict.insert("usage", RpcInt(size * 500))  // Memory overhead
      |> dict.insert("total_fee", RpcFloat(0.0))
      |> dict.insert("maxmempool", RpcInt(300_000_000))
      |> dict.insert("mempoolminfee", RpcFloat(0.00001))
      |> dict.insert("minrelaytxfee", RpcFloat(0.00001))
      |> dict.insert("incrementalrelayfee", RpcFloat(0.00001))
      |> dict.insert("unbroadcastcount", RpcInt(0))

    Ok(RpcObject(result))
  }
}

/// Create handler for getrawmempool that queries mempool
fn create_getrawmempool_handler(
  mempool: Subject(MempoolQuery),
) -> MethodHandler {
  fn(params: RpcParams, _ctx: RpcContext) -> Result(RpcValue, RpcError) {
    let verbose = case params {
      ParamsArray([RpcBool(v), ..]) -> v
      _ -> False
    }

    let txids = query_mempool_txids(mempool)

    case verbose {
      False -> {
        // Return array of txid strings
        let txid_strings = list.map(txids, fn(txid) {
          RpcString(oni_bitcoin.txid_to_hex(txid))
        })
        Ok(RpcArray(txid_strings))
      }
      True -> {
        // Return object with txid -> info
        let entries = list.map(txids, fn(txid) {
          let info = dict.new()
            |> dict.insert("vsize", RpcInt(250))
            |> dict.insert("weight", RpcInt(1000))
            |> dict.insert("time", RpcInt(0))
            |> dict.insert("height", RpcInt(0))
            |> dict.insert("descendantcount", RpcInt(1))
            |> dict.insert("descendantsize", RpcInt(250))
            |> dict.insert("ancestorcount", RpcInt(1))
            |> dict.insert("ancestorsize", RpcInt(250))
            |> dict.insert("depends", RpcArray([]))
          #(oni_bitcoin.txid_to_hex(txid), RpcObject(info))
        })
        Ok(RpcObject(dict.from_list(entries)))
      }
    }
  }
}

// ============================================================================
// Query Helpers
// ============================================================================

/// Query chainstate for current height
fn query_chainstate_height(chainstate: Subject(ChainstateQuery)) -> Int {
  process.call(chainstate, QueryHeight, 5000)
}

/// Query chainstate for current tip
fn query_chainstate_tip(
  chainstate: Subject(ChainstateQuery),
) -> Option(oni_bitcoin.BlockHash) {
  process.call(chainstate, QueryTip, 5000)
}

/// Query chainstate for network
fn query_chainstate_network(
  chainstate: Subject(ChainstateQuery),
) -> oni_bitcoin.Network {
  process.call(chainstate, QueryNetwork, 5000)
}

/// Query mempool for size
fn query_mempool_size(mempool: Subject(MempoolQuery)) -> Int {
  process.call(mempool, QueryMempoolSize, 5000)
}

/// Query mempool for txids
fn query_mempool_txids(
  mempool: Subject(MempoolQuery),
) -> List(oni_bitcoin.Txid) {
  process.call(mempool, QueryMempoolTxids, 5000)
}

/// Query sync state
fn query_sync_state(sync: Subject(SyncQuery)) -> SyncState {
  process.call(sync, QuerySyncState, 5000)
}

// ============================================================================
// Utility
// ============================================================================

/// Get current Unix timestamp (placeholder - would use erlang:system_time)
fn get_timestamp() -> Int {
  // In real implementation: erlang.system_time(second)
  0
}

// ============================================================================
// Convenience Functions
// ============================================================================

/// Handle a raw request string synchronously
pub fn handle_request_sync(
  service: Subject(RpcServiceMsg),
  request_json: String,
  authenticated: Bool,
) -> String {
  case oni_rpc.parse_request_string(request_json) {
    Error(err) -> {
      let response = oni_rpc.error_response(oni_rpc.IdNull, err)
      oni_rpc.serialize_response(response)
    }
    Ok(request) -> {
      let ctx = oni_rpc.RpcContext(
        authenticated: authenticated,
        remote_addr: None,
        request_time: 0,
      )

      let response = process.call(
        service,
        HandleRequest(request, ctx, _),
        30_000,
      )

      oni_rpc.serialize_response(response)
    }
  }
}

/// Get service statistics synchronously
pub fn get_stats_sync(service: Subject(RpcServiceMsg)) -> ServiceStats {
  process.call(service, GetStats, 5000)
}

/// Shutdown the service
pub fn shutdown(service: Subject(RpcServiceMsg)) -> Nil {
  process.send(service, Shutdown)
}
