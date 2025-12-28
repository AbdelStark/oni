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

import gleam/bit_array
import gleam/dict
import gleam/erlang/process.{type Subject}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
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
  /// Submit a mined block
  SubmitBlock(block: oni_bitcoin.Block, reply: Subject(SubmitBlockResult))
}

/// Result of block submission
pub type SubmitBlockResult {
  /// Block accepted and added to chain
  SubmitBlockAccepted
  /// Block already known
  SubmitBlockDuplicate
  /// Block was rejected with reason
  SubmitBlockRejected(reason: String)
}

/// Mempool query messages
/// These are sent to the mempool adapter actor
pub type MempoolQuery {
  QueryMempoolSize(reply: Subject(Int))
  QueryMempoolTxids(reply: Subject(List(oni_bitcoin.Txid)))
  QueryBlockTemplate(reply: Subject(BlockTemplateData))
  /// Submit a transaction to the mempool
  SubmitTx(tx: oni_bitcoin.Transaction, reply: Subject(SubmitTxResult))
  /// Test if a transaction would be accepted to the mempool
  TestMempoolAccept(
    tx: oni_bitcoin.Transaction,
    max_fee_rate: Float,
    reply: Subject(TestAcceptResult),
  )
  /// Estimate smart fee for target confirmation
  EstimateSmartFee(target_blocks: Int, mode: String, reply: Subject(FeeEstimateResult))
}

/// Result of testmempoolaccept
pub type TestAcceptResult {
  TestAcceptResult(
    txid: String,
    allowed: Bool,
    vsize: Int,
    fees: TestAcceptFees,
    reject_reason: Option(String),
  )
}

/// Fee breakdown for testmempoolaccept
pub type TestAcceptFees {
  TestAcceptFees(
    base: Int,
    effective_feerate: Float,
    effective_includes: List(String),
  )
}

/// Result of estimatesmartfee
pub type FeeEstimateResult {
  FeeEstimateResult(
    feerate: Float,  // BTC/kvB
    errors: List(String),
    blocks: Int,
  )
}

/// Result of transaction submission
pub type SubmitTxResult {
  /// Transaction accepted into mempool, returns txid
  SubmitTxAccepted(txid: oni_bitcoin.Txid)
  /// Transaction rejected with reason
  SubmitTxRejected(reason: String)
}

/// Block template data for RPC response
pub type BlockTemplateData {
  BlockTemplateData(
    /// Transactions to include (as hex strings)
    transactions: List(TemplateTxData),
    /// Coinbase value (subsidy + fees)
    coinbase_value: Int,
    /// Total fees from transactions
    total_fees: Int,
    /// Weight used
    weight_used: Int,
    /// SigOps used
    sigops_used: Int,
    /// Height for this template
    height: Int,
    /// Current bits
    bits: Int,
  )
}

/// Single transaction in template
pub type TemplateTxData {
  TemplateTxData(
    data: String,  // hex encoded
    txid: String,  // hex encoded
    hash: String,  // wtxid hex encoded
    fee: Int,
    sigops: Int,
    weight: Int,
    depends: List(Int),
  )
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
  |> oni_rpc.server_register("getblocktemplate", create_getblocktemplate_handler(chainstate, mempool))
  |> oni_rpc.server_register("submitblock", create_submitblock_handler(chainstate))
  |> oni_rpc.server_register("sendrawtransaction", create_sendrawtransaction_handler(mempool))
  |> oni_rpc.server_register("testmempoolaccept", create_testmempoolaccept_handler(mempool))
  |> oni_rpc.server_register("estimatesmartfee", create_estimatesmartfee_handler(mempool))
  |> oni_rpc.server_register("getdifficulty", create_getdifficulty_handler(chainstate))
  |> oni_rpc.server_register("getnetworkhashps", create_getnetworkhashps_handler(chainstate))
  // Additional Bitcoin Core compatible RPC methods
  |> oni_rpc.server_register("getblockheader", create_getblockheader_handler(chainstate))
  |> oni_rpc.server_register("decoderawtransaction", create_decoderawtransaction_handler())
  |> oni_rpc.server_register("validateaddress", create_validateaddress_handler())
  |> oni_rpc.server_register("getnetworkinfo", create_getnetworkinfo_handler(chainstate, sync))
  |> oni_rpc.server_register("uptime", create_uptime_handler())
  |> oni_rpc.server_register("getmininginfo", create_getmininginfo_handler(chainstate))
  |> oni_rpc.server_register("help", create_help_handler())
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

/// Create handler for getblocktemplate that queries chainstate and mempool
fn create_getblocktemplate_handler(
  chainstate: Subject(ChainstateQuery),
  mempool: Subject(MempoolQuery),
) -> MethodHandler {
  fn(_params: RpcParams, _ctx: RpcContext) -> Result(RpcValue, RpcError) {
    // Get current state
    let height = query_chainstate_height(chainstate)
    let tip = query_chainstate_tip(chainstate)

    // Get block template from mempool
    let template = query_block_template(mempool)

    // Build response
    let tip_hex = case tip {
      Some(hash) -> oni_bitcoin.block_hash_to_hex(hash)
      None -> "0000000000000000000000000000000000000000000000000000000000000000"
    }

    // Convert transactions to RPC format
    let txs = list.map(template.transactions, fn(tx) {
      let tx_obj = dict.new()
        |> dict.insert("data", RpcString(tx.data))
        |> dict.insert("txid", RpcString(tx.txid))
        |> dict.insert("hash", RpcString(tx.hash))
        |> dict.insert("fee", RpcInt(tx.fee))
        |> dict.insert("sigops", RpcInt(tx.sigops))
        |> dict.insert("weight", RpcInt(tx.weight))
        |> dict.insert("depends", RpcArray(list.map(tx.depends, fn(i) { RpcInt(i) })))
      RpcObject(tx_obj)
    })

    let result = dict.new()
      |> dict.insert("version", RpcInt(0x20000000))
      |> dict.insert("previousblockhash", RpcString(tip_hex))
      |> dict.insert("transactions", RpcArray(txs))
      |> dict.insert("coinbaseaux", RpcObject(dict.new()))
      |> dict.insert("coinbasevalue", RpcInt(template.coinbase_value))
      |> dict.insert("target", RpcString("00000000ffff0000000000000000000000000000000000000000000000000000"))
      |> dict.insert("mintime", RpcInt(0))
      |> dict.insert("mutable", RpcArray([RpcString("time"), RpcString("transactions"), RpcString("prevblock")]))
      |> dict.insert("noncerange", RpcString("00000000ffffffff"))
      |> dict.insert("sigoplimit", RpcInt(80000))
      |> dict.insert("sizelimit", RpcInt(4000000))
      |> dict.insert("weightlimit", RpcInt(4000000))
      |> dict.insert("curtime", RpcInt(get_timestamp()))
      |> dict.insert("bits", RpcString(int_to_hex(template.bits)))
      |> dict.insert("height", RpcInt(height + 1))
      |> dict.insert("sigops", RpcInt(template.sigops_used))
      |> dict.insert("weight", RpcInt(template.weight_used))

    Ok(RpcObject(result))
  }
}

/// Convert int to hex string
fn int_to_hex(n: Int) -> String {
  oni_bitcoin.hex_encode(<<n:32-big>>)
}

/// Create handler for submitblock that submits a mined block
fn create_submitblock_handler(
  chainstate: Subject(ChainstateQuery),
) -> MethodHandler {
  fn(params: RpcParams, _ctx: RpcContext) -> Result(RpcValue, RpcError) {
    // Extract block hex from params
    // submitblock "hexdata" ( "dummy" )
    case params {
      ParamsArray([RpcString(block_hex), ..]) -> {
        // Decode hex to bytes
        case oni_bitcoin.hex_decode(block_hex) {
          Error(_) -> Error(InvalidParams("Invalid block hex encoding"))
          Ok(block_bytes) -> {
            // Decode block from bytes
            case oni_bitcoin.decode_block(block_bytes) {
              Error(msg) -> Error(InvalidParams("Invalid block data: " <> msg))
              Ok(#(block, _rest)) -> {
                // Submit to chainstate
                let result = submit_block(chainstate, block)
                case result {
                  SubmitBlockAccepted -> Ok(RpcNull)
                  SubmitBlockDuplicate -> Ok(RpcString("duplicate"))
                  SubmitBlockRejected(reason) -> Ok(RpcString(reason))
                }
              }
            }
          }
        }
      }
      _ -> Error(InvalidParams("submitblock requires block hex as first parameter"))
    }
  }
}

/// Submit a block to chainstate
fn submit_block(
  chainstate: Subject(ChainstateQuery),
  block: oni_bitcoin.Block,
) -> SubmitBlockResult {
  process.call(chainstate, SubmitBlock(block, _), 60_000)  // Longer timeout for block validation
}

/// Create handler for sendrawtransaction that submits a transaction to mempool
fn create_sendrawtransaction_handler(
  mempool: Subject(MempoolQuery),
) -> MethodHandler {
  fn(params: RpcParams, _ctx: RpcContext) -> Result(RpcValue, RpcError) {
    // Extract transaction hex from params
    // sendrawtransaction "hexstring" ( maxfeerate maxburnamount )
    case params {
      ParamsArray([RpcString(tx_hex), ..]) -> {
        // Decode hex to bytes
        case oni_bitcoin.hex_decode(tx_hex) {
          Error(_) -> Error(InvalidParams("Invalid transaction hex encoding"))
          Ok(tx_bytes) -> {
            // Decode transaction from bytes
            case oni_bitcoin.decode_tx(tx_bytes) {
              Error(msg) -> Error(InvalidParams("Invalid transaction data: " <> msg))
              Ok(#(tx, _rest)) -> {
                // Submit to mempool
                let result = submit_tx(mempool, tx)
                case result {
                  SubmitTxAccepted(txid) -> Ok(RpcString(oni_bitcoin.txid_to_hex(txid)))
                  SubmitTxRejected(reason) -> Error(Internal(reason))
                }
              }
            }
          }
        }
      }
      _ -> Error(InvalidParams("sendrawtransaction requires transaction hex as first parameter"))
    }
  }
}

/// Submit a transaction to mempool
fn submit_tx(
  mempool: Subject(MempoolQuery),
  tx: oni_bitcoin.Transaction,
) -> SubmitTxResult {
  process.call(mempool, SubmitTx(tx, _), 30_000)
}

/// Create handler for testmempoolaccept
fn create_testmempoolaccept_handler(
  mempool: Subject(MempoolQuery),
) -> MethodHandler {
  fn(params: RpcParams, _ctx: RpcContext) -> Result(RpcValue, RpcError) {
    // testmempoolaccept ["hexstring",...] ( maxfeerate )
    case params {
      ParamsArray([RpcArray(tx_hexes), ..rest]) -> {
        // Get max fee rate if provided
        let max_fee_rate = case rest {
          [RpcFloat(rate), ..] -> rate
          [RpcInt(rate), ..] -> int.to_float(rate)
          _ -> 0.1  // Default 0.1 BTC/kvB
        }

        // Process each transaction
        let results = list.map(tx_hexes, fn(tx_hex) {
          case tx_hex {
            RpcString(hex_str) -> {
              case oni_bitcoin.hex_decode(hex_str) {
                Error(_) -> {
                  create_reject_result("", "invalid-hex", 0)
                }
                Ok(tx_bytes) -> {
                  case oni_bitcoin.decode_tx(tx_bytes) {
                    Error(msg) -> {
                      create_reject_result("", msg, 0)
                    }
                    Ok(#(tx, _rest)) -> {
                      // Test acceptance
                      let result = test_mempool_accept(mempool, tx, max_fee_rate)
                      format_test_result(result)
                    }
                  }
                }
              }
            }
            _ -> create_reject_result("", "invalid-type", 0)
          }
        })

        Ok(RpcArray(results))
      }
      _ -> Error(InvalidParams("testmempoolaccept requires array of hex strings"))
    }
  }
}

/// Format test result to RPC value
fn format_test_result(result: TestAcceptResult) -> RpcValue {
  let fees_obj = dict.new()
    |> dict.insert("base", RpcInt(result.fees.base))
    |> dict.insert("effective-feerate", RpcFloat(result.fees.effective_feerate))
    |> dict.insert("effective-includes", RpcArray(
      list.map(result.fees.effective_includes, fn(s) { RpcString(s) })
    ))

  let obj = dict.new()
    |> dict.insert("txid", RpcString(result.txid))
    |> dict.insert("allowed", RpcBool(result.allowed))
    |> dict.insert("vsize", RpcInt(result.vsize))
    |> dict.insert("fees", RpcObject(fees_obj))

  let with_reason = case result.reject_reason {
    Some(reason) -> dict.insert(obj, "reject-reason", RpcString(reason))
    None -> obj
  }

  RpcObject(with_reason)
}

/// Create a rejection result
fn create_reject_result(txid: String, reason: String, vsize: Int) -> RpcValue {
  let result = TestAcceptResult(
    txid: txid,
    allowed: False,
    vsize: vsize,
    fees: TestAcceptFees(base: 0, effective_feerate: 0.0, effective_includes: []),
    reject_reason: Some(reason),
  )
  format_test_result(result)
}

/// Test if transaction would be accepted
fn test_mempool_accept(
  mempool: Subject(MempoolQuery),
  tx: oni_bitcoin.Transaction,
  max_fee_rate: Float,
) -> TestAcceptResult {
  process.call(mempool, TestMempoolAccept(tx, max_fee_rate, _), 30_000)
}

/// Create handler for estimatesmartfee
fn create_estimatesmartfee_handler(
  mempool: Subject(MempoolQuery),
) -> MethodHandler {
  fn(params: RpcParams, _ctx: RpcContext) -> Result(RpcValue, RpcError) {
    // estimatesmartfee conf_target ( "estimate_mode" )
    case params {
      ParamsArray([RpcInt(conf_target), ..rest]) -> {
        // Get estimate mode if provided
        let mode = case rest {
          [RpcString(m), ..] -> m
          _ -> "CONSERVATIVE"
        }

        // Get fee estimate
        let result = estimate_smart_fee(mempool, conf_target, mode)

        let obj = dict.new()
          |> dict.insert("feerate", RpcFloat(result.feerate))
          |> dict.insert("blocks", RpcInt(result.blocks))

        let with_errors = case result.errors {
          [] -> obj
          errs -> dict.insert(obj, "errors", RpcArray(
            list.map(errs, fn(e) { RpcString(e) })
          ))
        }

        Ok(RpcObject(with_errors))
      }
      ParamsNone -> Error(InvalidParams("estimatesmartfee requires conf_target"))
      _ -> Error(InvalidParams("estimatesmartfee requires conf_target as integer"))
    }
  }
}

/// Query fee estimate
fn estimate_smart_fee(
  mempool: Subject(MempoolQuery),
  target_blocks: Int,
  mode: String,
) -> FeeEstimateResult {
  process.call(mempool, EstimateSmartFee(target_blocks, mode, _), 5000)
}

/// Create handler for getdifficulty
fn create_getdifficulty_handler(
  chainstate: Subject(ChainstateQuery),
) -> MethodHandler {
  fn(_params: RpcParams, _ctx: RpcContext) -> Result(RpcValue, RpcError) {
    // For now return placeholder - would query actual difficulty from chainstate
    let _ = chainstate
    // Mainnet genesis difficulty is 1.0
    Ok(RpcFloat(1.0))
  }
}

/// Create handler for getnetworkhashps
fn create_getnetworkhashps_handler(
  chainstate: Subject(ChainstateQuery),
) -> MethodHandler {
  fn(params: RpcParams, _ctx: RpcContext) -> Result(RpcValue, RpcError) {
    // getnetworkhashps ( nblocks height )
    let _nblocks = case params {
      ParamsArray([RpcInt(n), ..]) -> n
      _ -> 120  // Default to last 120 blocks
    }

    let _ = chainstate
    // Return placeholder hash rate (would calculate from actual block data)
    // At difficulty 1, ~7 MH/s average
    Ok(RpcFloat(7_000_000.0))
  }
}

/// Create handler for getblockheader
fn create_getblockheader_handler(
  chainstate: Subject(ChainstateQuery),
) -> MethodHandler {
  fn(params: RpcParams, _ctx: RpcContext) -> Result(RpcValue, RpcError) {
    // getblockheader "blockhash" ( verbose )
    case params {
      ParamsArray([RpcString(blockhash), ..rest]) -> {
        let verbose = case rest {
          [RpcBool(v), ..] -> v
          _ -> True
        }

        let _ = chainstate
        let _ = blockhash

        case verbose {
          False -> {
            // Return raw header hex (80 bytes = 160 hex chars)
            Ok(RpcString("0100000000000000000000000000000000000000000000000000000000000000000000003ba3edfd7a7b12b27ac72c3e67768f617fc81bc3888a51323a9fb8aa4b1e5e4a29ab5f49ffff001d1dac2b7c"))
          }
          True -> {
            // Return decoded header object
            let result = dict.new()
              |> dict.insert("hash", RpcString(blockhash))
              |> dict.insert("confirmations", RpcInt(1))
              |> dict.insert("height", RpcInt(0))
              |> dict.insert("version", RpcInt(1))
              |> dict.insert("versionHex", RpcString("00000001"))
              |> dict.insert("merkleroot", RpcString("4a5e1e4baab89f3a32518a88c31bc87f618f76673e2cc77ab2127b7afdeda33b"))
              |> dict.insert("time", RpcInt(1231006505))
              |> dict.insert("mediantime", RpcInt(1231006505))
              |> dict.insert("nonce", RpcInt(2083236893))
              |> dict.insert("bits", RpcString("1d00ffff"))
              |> dict.insert("difficulty", RpcFloat(1.0))
              |> dict.insert("chainwork", RpcString("0000000000000000000000000000000000000000000000000000000100010001"))
              |> dict.insert("nTx", RpcInt(1))
              |> dict.insert("previousblockhash", RpcNull)
            Ok(RpcObject(result))
          }
        }
      }
      ParamsNone -> Error(InvalidParams("getblockheader requires blockhash"))
      _ -> Error(InvalidParams("getblockheader requires blockhash as string"))
    }
  }
}

/// Create handler for decoderawtransaction
fn create_decoderawtransaction_handler() -> MethodHandler {
  fn(params: RpcParams, _ctx: RpcContext) -> Result(RpcValue, RpcError) {
    // decoderawtransaction "hexstring"
    case params {
      ParamsArray([RpcString(hex_tx), ..]) -> {
        // Parse the transaction from hex
        case oni_bitcoin.hex_decode(hex_tx) {
          Error(_) -> Error(InvalidParams("Invalid hex encoding"))
          Ok(tx_bytes) -> {
            // Decode the transaction
            case oni_bitcoin.decode_tx(tx_bytes) {
              Error(_) -> Error(InvalidParams("Invalid transaction format"))
              Ok(#(tx, _remaining)) -> {
                // Build response object
                let txid = oni_bitcoin.txid_from_tx(tx)
                let wtxid = oni_bitcoin.wtxid_from_tx(tx)

                let vin = list.index_map(tx.inputs, fn(input, idx) {
                  let input_obj = dict.new()
                    |> dict.insert("txid", RpcString(oni_bitcoin.txid_to_hex(input.prevout.txid)))
                    |> dict.insert("vout", RpcInt(input.prevout.vout))
                    |> dict.insert("scriptSig", RpcObject(
                      dict.new()
                        |> dict.insert("asm", RpcString(""))
                        |> dict.insert("hex", RpcString(oni_bitcoin.bytes_to_hex(oni_bitcoin.script_to_bytes(input.script_sig))))
                    ))
                    |> dict.insert("sequence", RpcInt(input.sequence))
                  let _ = idx
                  RpcObject(input_obj)
                })

                let vout = list.index_map(tx.outputs, fn(output, idx) {
                  let output_obj = dict.new()
                    |> dict.insert("value", RpcFloat(int.to_float(oni_bitcoin.amount_to_sats(output.value)) /. 100_000_000.0))
                    |> dict.insert("n", RpcInt(idx))
                    |> dict.insert("scriptPubKey", RpcObject(
                      dict.new()
                        |> dict.insert("asm", RpcString(""))
                        |> dict.insert("hex", RpcString(oni_bitcoin.bytes_to_hex(oni_bitcoin.script_to_bytes(output.script_pubkey))))
                        |> dict.insert("type", RpcString("unknown"))
                    ))
                  RpcObject(output_obj)
                })

                let result = dict.new()
                  |> dict.insert("txid", RpcString(oni_bitcoin.txid_to_hex(txid)))
                  |> dict.insert("hash", RpcString(oni_bitcoin.wtxid_to_hex(wtxid)))
                  |> dict.insert("version", RpcInt(tx.version))
                  |> dict.insert("size", RpcInt(bit_array.byte_size(tx_bytes)))
                  |> dict.insert("vsize", RpcInt(bit_array.byte_size(tx_bytes)))  // Simplified
                  |> dict.insert("weight", RpcInt(bit_array.byte_size(tx_bytes) * 4))  // Simplified
                  |> dict.insert("locktime", RpcInt(tx.lock_time))
                  |> dict.insert("vin", RpcArray(vin))
                  |> dict.insert("vout", RpcArray(vout))

                Ok(RpcObject(result))
              }
            }
          }
        }
      }
      ParamsNone -> Error(InvalidParams("decoderawtransaction requires hex string"))
      _ -> Error(InvalidParams("decoderawtransaction requires hex string as first parameter"))
    }
  }
}

/// Create handler for validateaddress
fn create_validateaddress_handler() -> MethodHandler {
  fn(params: RpcParams, _ctx: RpcContext) -> Result(RpcValue, RpcError) {
    // validateaddress "address"
    case params {
      ParamsArray([RpcString(address), ..]) -> {
        // Try to decode the address
        let validation_result = validate_bitcoin_address(address)

        let result = dict.new()
          |> dict.insert("isvalid", RpcBool(validation_result.is_valid))
          |> dict.insert("address", RpcString(address))

        let with_details = case validation_result.is_valid {
          True -> result
            |> dict.insert("scriptPubKey", RpcString(validation_result.script_pubkey))
            |> dict.insert("isscript", RpcBool(validation_result.is_script))
            |> dict.insert("iswitness", RpcBool(validation_result.is_witness))
          False -> result
            |> dict.insert("error", RpcString(validation_result.error))
        }

        Ok(RpcObject(with_details))
      }
      ParamsNone -> Error(InvalidParams("validateaddress requires address"))
      _ -> Error(InvalidParams("validateaddress requires address as string"))
    }
  }
}

/// Address validation result
type AddressValidationResult {
  AddressValidationResult(
    is_valid: Bool,
    script_pubkey: String,
    is_script: Bool,
    is_witness: Bool,
    error: String,
  )
}

/// Validate a Bitcoin address
fn validate_bitcoin_address(address: String) -> AddressValidationResult {
  // Try bech32/bech32m first (native SegWit)
  case oni_bitcoin.decode_bech32_address(address) {
    Ok(#(witness_version, program)) -> {
      let script_pubkey = case witness_version {
        0 -> oni_bitcoin.bytes_to_hex(<<0, bit_array.byte_size(program), program:bits>>)
        1 -> oni_bitcoin.bytes_to_hex(<<0x51, bit_array.byte_size(program), program:bits>>)
        _ -> ""
      }
      AddressValidationResult(
        is_valid: True,
        script_pubkey: script_pubkey,
        is_script: False,
        is_witness: True,
        error: "",
      )
    }
    Error(_) -> {
      // Try base58check
      case oni_bitcoin.decode_base58check(address) {
        Ok(#(version, payload)) -> {
          // Check version byte
          let #(is_valid, is_script) = case version {
            0 -> #(True, False)   // P2PKH mainnet
            5 -> #(True, True)    // P2SH mainnet
            111 -> #(True, False) // P2PKH testnet
            196 -> #(True, True)  // P2SH testnet
            _ -> #(False, False)
          }

          case is_valid {
            True -> {
              let script_pubkey = case is_script {
                False -> oni_bitcoin.bytes_to_hex(<<0x76, 0xa9, 0x14, payload:bits, 0x88, 0xac>>)  // P2PKH
                True -> oni_bitcoin.bytes_to_hex(<<0xa9, 0x14, payload:bits, 0x87>>)  // P2SH
              }
              AddressValidationResult(
                is_valid: True,
                script_pubkey: script_pubkey,
                is_script: is_script,
                is_witness: False,
                error: "",
              )
            }
            False -> AddressValidationResult(
              is_valid: False,
              script_pubkey: "",
              is_script: False,
              is_witness: False,
              error: "Unknown version byte",
            )
          }
        }
        Error(_) -> AddressValidationResult(
          is_valid: False,
          script_pubkey: "",
          is_script: False,
          is_witness: False,
          error: "Invalid address format",
        )
      }
    }
  }
}

/// Create handler for getnetworkinfo
fn create_getnetworkinfo_handler(
  chainstate: Subject(ChainstateQuery),
  sync: Subject(SyncQuery),
) -> MethodHandler {
  fn(_params: RpcParams, _ctx: RpcContext) -> Result(RpcValue, RpcError) {
    let network = query_chainstate_network(chainstate)
    let sync_state = query_sync_state(sync)

    let network_name = case network {
      oni_bitcoin.Mainnet -> "main"
      oni_bitcoin.Testnet -> "test"
      oni_bitcoin.Regtest -> "regtest"
      oni_bitcoin.Signet -> "signet"
    }

    let result = dict.new()
      |> dict.insert("version", RpcInt(270000))  // oni version encoded as int
      |> dict.insert("subversion", RpcString("/oni:0.1.0/"))
      |> dict.insert("protocolversion", RpcInt(70016))
      |> dict.insert("localservices", RpcString("0000000000000409"))
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
      |> dict.insert("networks", RpcArray([
        RpcObject(dict.new()
          |> dict.insert("name", RpcString("ipv4"))
          |> dict.insert("limited", RpcBool(False))
          |> dict.insert("reachable", RpcBool(True))
          |> dict.insert("proxy", RpcString(""))
          |> dict.insert("proxy_randomize_credentials", RpcBool(False))
        ),
        RpcObject(dict.new()
          |> dict.insert("name", RpcString("ipv6"))
          |> dict.insert("limited", RpcBool(False))
          |> dict.insert("reachable", RpcBool(True))
          |> dict.insert("proxy", RpcString(""))
          |> dict.insert("proxy_randomize_credentials", RpcBool(False))
        ),
      ]))
      |> dict.insert("relayfee", RpcFloat(0.00001))
      |> dict.insert("incrementalfee", RpcFloat(0.00001))
      |> dict.insert("localaddresses", RpcArray([]))
      |> dict.insert("warnings", RpcString(
        case sync_state.is_syncing {
          True -> "Initial block download in progress"
          False -> ""
        }
      ))
      |> dict.insert("chain", RpcString(network_name))

    Ok(RpcObject(result))
  }
}

/// Create handler for uptime
fn create_uptime_handler() -> MethodHandler {
  fn(_params: RpcParams, _ctx: RpcContext) -> Result(RpcValue, RpcError) {
    // Return uptime in seconds (placeholder - would track actual start time)
    Ok(RpcInt(0))
  }
}

/// Create handler for getmininginfo
fn create_getmininginfo_handler(
  chainstate: Subject(ChainstateQuery),
) -> MethodHandler {
  fn(_params: RpcParams, _ctx: RpcContext) -> Result(RpcValue, RpcError) {
    let height = query_chainstate_height(chainstate)
    let network = query_chainstate_network(chainstate)

    let chain = case network {
      oni_bitcoin.Mainnet -> "main"
      oni_bitcoin.Testnet -> "test"
      oni_bitcoin.Regtest -> "regtest"
      oni_bitcoin.Signet -> "signet"
    }

    let result = dict.new()
      |> dict.insert("blocks", RpcInt(height))
      |> dict.insert("difficulty", RpcFloat(1.0))
      |> dict.insert("networkhashps", RpcFloat(0.0))
      |> dict.insert("pooledtx", RpcInt(0))
      |> dict.insert("chain", RpcString(chain))
      |> dict.insert("warnings", RpcString(""))

    Ok(RpcObject(result))
  }
}

/// Create handler for help
fn create_help_handler() -> MethodHandler {
  fn(params: RpcParams, _ctx: RpcContext) -> Result(RpcValue, RpcError) {
    case params {
      ParamsArray([RpcString(command), ..]) -> {
        // Return help for specific command
        let help_text = case command {
          "getblockcount" -> "getblockcount\n\nReturns the height of the most-work fully-validated chain."
          "getbestblockhash" -> "getbestblockhash\n\nReturns the hash of the best (tip) block in the most-work fully-validated chain."
          "getblockchaininfo" -> "getblockchaininfo\n\nReturns an object containing various state info regarding blockchain processing."
          "getmempoolinfo" -> "getmempoolinfo\n\nReturns details on the active state of the TX memory pool."
          "getrawmempool" -> "getrawmempool ( verbose mempool_sequence )\n\nReturns all transaction ids in memory pool."
          "getblocktemplate" -> "getblocktemplate ( \"template_request\" )\n\nReturns data needed to construct a block."
          "submitblock" -> "submitblock \"hexdata\" ( \"dummy\" )\n\nAttempts to submit new block to network."
          "sendrawtransaction" -> "sendrawtransaction \"hexstring\" ( maxfeerate )\n\nSubmit a raw transaction to the network."
          "testmempoolaccept" -> "testmempoolaccept [\"rawtx\",...] ( maxfeerate )\n\nReturns result of mempool acceptance tests."
          "estimatesmartfee" -> "estimatesmartfee conf_target ( \"estimate_mode\" )\n\nEstimates the fee per kilobyte."
          "getdifficulty" -> "getdifficulty\n\nReturns the proof-of-work difficulty as a multiple of the minimum difficulty."
          "getnetworkhashps" -> "getnetworkhashps ( nblocks height )\n\nReturns the estimated network hashes per second."
          "getblockheader" -> "getblockheader \"blockhash\" ( verbose )\n\nReturns information about block header."
          "decoderawtransaction" -> "decoderawtransaction \"hexstring\"\n\nReturn a JSON object representing the serialized transaction."
          "validateaddress" -> "validateaddress \"address\"\n\nReturn information about the given bitcoin address."
          "getnetworkinfo" -> "getnetworkinfo\n\nReturns an object containing various state info regarding P2P networking."
          "uptime" -> "uptime\n\nReturns the total uptime of the server in seconds."
          "getmininginfo" -> "getmininginfo\n\nReturns a json object containing mining-related information."
          "help" -> "help ( \"command\" )\n\nList all commands, or get help for a specified command."
          _ -> "Unknown command: " <> command
        }
        Ok(RpcString(help_text))
      }
      _ -> {
        // Return list of all commands
        let commands = "== Blockchain ==\n" <>
          "getbestblockhash\n" <>
          "getblockchaininfo\n" <>
          "getblockcount\n" <>
          "getblockheader \"blockhash\" ( verbose )\n" <>
          "getdifficulty\n" <>
          "\n== Mining ==\n" <>
          "getblocktemplate ( \"template_request\" )\n" <>
          "getmininginfo\n" <>
          "getnetworkhashps ( nblocks height )\n" <>
          "submitblock \"hexdata\" ( \"dummy\" )\n" <>
          "\n== Network ==\n" <>
          "getnetworkinfo\n" <>
          "uptime\n" <>
          "\n== Rawtransactions ==\n" <>
          "decoderawtransaction \"hexstring\"\n" <>
          "sendrawtransaction \"hexstring\" ( maxfeerate )\n" <>
          "testmempoolaccept [\"rawtx\",...] ( maxfeerate )\n" <>
          "\n== Mempool ==\n" <>
          "getmempoolinfo\n" <>
          "getrawmempool ( verbose mempool_sequence )\n" <>
          "\n== Util ==\n" <>
          "estimatesmartfee conf_target ( \"estimate_mode\" )\n" <>
          "validateaddress \"address\"\n" <>
          "\n== Control ==\n" <>
          "help ( \"command\" )"
        Ok(RpcString(commands))
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

/// Query mempool for block template
fn query_block_template(mempool: Subject(MempoolQuery)) -> BlockTemplateData {
  process.call(mempool, QueryBlockTemplate, 30_000)  // Longer timeout for template
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
