// node_rpc.gleam - Adapter connecting RPC service to node actors
//
// This module provides the glue between the RPC service types and
// the supervisor actor message types. It creates adapter actors
// that translate RPC queries into supervisor messages.
//
// The adapter actors receive RPC query messages and forward them
// to the underlying supervisor actors, translating between the
// RPC service types and supervisor message types.

import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import oni_bitcoin
import supervisor
import rpc_service.{
  type BlockTemplateData, type ChainstateQuery, type MempoolQuery,
  type SubmitBlockResult, type SubmitTxResult, type SyncQuery, type SyncState,
  type TemplateTxData, BlockTemplateData, QueryBlockTemplate, QueryHeight,
  QueryMempoolSize, QueryMempoolTxids, QueryNetwork, QuerySyncState, QueryTip,
  SubmitBlock, SubmitBlockAccepted, SubmitBlockDuplicate, SubmitBlockRejected,
  SubmitTx, SubmitTxAccepted, SubmitTxRejected, SyncState, TemplateTxData,
}
import oni_consensus/block_template
import oni_consensus/mempool

// ============================================================================
// Adapter Actor for Chainstate Queries
// ============================================================================

/// State for chainstate adapter
type ChainstateAdapterState {
  ChainstateAdapterState(target: Subject(supervisor.ChainstateMsg))
}

/// Start an adapter that translates RPC chainstate queries to supervisor messages
pub fn start_chainstate_adapter(
  chainstate: Subject(supervisor.ChainstateMsg),
) -> Result(Subject(ChainstateQuery), actor.StartError) {
  actor.start(
    ChainstateAdapterState(target: chainstate),
    handle_chainstate_query,
  )
}

fn handle_chainstate_query(
  msg: ChainstateQuery,
  state: ChainstateAdapterState,
) -> actor.Next(ChainstateQuery, ChainstateAdapterState) {
  case msg {
    QueryTip(reply) -> {
      // Forward to supervisor chainstate actor
      let result = process.call(state.target, supervisor.GetTip, 5000)
      process.send(reply, result)
      actor.continue(state)
    }

    QueryHeight(reply) -> {
      let result = process.call(state.target, supervisor.GetHeight, 5000)
      process.send(reply, result)
      actor.continue(state)
    }

    QueryNetwork(reply) -> {
      let result = process.call(state.target, supervisor.GetNetwork, 5000)
      process.send(reply, result)
      actor.continue(state)
    }

    SubmitBlock(block, reply) -> {
      // Submit block to chainstate for validation and connection
      // First check if block connects to our tip (basic validation)
      let tip_result = process.call(state.target, supervisor.GetTip, 5000)

      case tip_result {
        None -> {
          // No tip yet, only genesis allowed
          process.send(reply, SubmitBlockRejected("no chain tip"))
          actor.continue(state)
        }
        Some(current_tip) -> {
          // Check if this block's prev_hash matches our tip
          let block_prev = block.header.prev_block_hash
          case block_prev == current_tip {
            False -> {
              // Could be duplicate or orphan
              // For now, check if it's our current tip (duplicate)
              let block_hash = oni_bitcoin.block_hash_from_header(block.header)
              case block_hash == current_tip {
                True -> {
                  process.send(reply, SubmitBlockDuplicate)
                  actor.continue(state)
                }
                False -> {
                  process.send(reply, SubmitBlockRejected("prev-blk-not-found"))
                  actor.continue(state)
                }
              }
            }
            True -> {
              // Block connects to our tip, try to connect it
              let connect_result = process.call(
                state.target,
                supervisor.ConnectBlock(block, _),
                60_000,
              )
              case connect_result {
                Ok(_) -> {
                  process.send(reply, SubmitBlockAccepted)
                  actor.continue(state)
                }
                Error(reason) -> {
                  process.send(reply, SubmitBlockRejected(reason))
                  actor.continue(state)
                }
              }
            }
          }
        }
      }
    }
  }
}

// ============================================================================
// Adapter Actor for Mempool Queries
// ============================================================================

/// State for mempool adapter
type MempoolAdapterState {
  MempoolAdapterState(target: Subject(supervisor.MempoolMsg))
}

/// Start an adapter that translates RPC mempool queries to supervisor messages
pub fn start_mempool_adapter(
  mempool: Subject(supervisor.MempoolMsg),
) -> Result(Subject(MempoolQuery), actor.StartError) {
  actor.start(
    MempoolAdapterState(target: mempool),
    handle_mempool_query,
  )
}

fn handle_mempool_query(
  msg: MempoolQuery,
  state: MempoolAdapterState,
) -> actor.Next(MempoolQuery, MempoolAdapterState) {
  case msg {
    QueryMempoolSize(reply) -> {
      let result = process.call(state.target, supervisor.GetSize, 5000)
      process.send(reply, result)
      actor.continue(state)
    }

    QueryMempoolTxids(reply) -> {
      let result = process.call(state.target, supervisor.GetTxids, 5000)
      process.send(reply, result)
      actor.continue(state)
    }

    QueryBlockTemplate(reply) -> {
      // Get template data from supervisor mempool
      // Use default height=0 and bits (will be overridden by RPC handler)
      let template_data = process.call(
        state.target,
        supervisor.GetTemplateData(0, 0x1d00ffff, _),
        30_000,
      )

      // Convert to RPC template format
      let result = convert_template_data(template_data)
      process.send(reply, result)
      actor.continue(state)
    }

    SubmitTx(tx, reply) -> {
      // Forward to supervisor mempool's AddTx
      let add_result = process.call(
        state.target,
        supervisor.AddTx(tx, _),
        30_000,
      )

      // Convert result
      case add_result {
        Ok(_) -> {
          // Transaction accepted, compute txid
          let txid = oni_bitcoin.txid_from_tx(tx)
          process.send(reply, SubmitTxAccepted(txid))
        }
        Error(reason) -> {
          process.send(reply, SubmitTxRejected(reason))
        }
      }
      actor.continue(state)
    }
  }
}

/// Convert supervisor template data to RPC format
fn convert_template_data(data: supervisor.MempoolTemplateData) -> BlockTemplateData {
  let txs = list.map(data.transactions, fn(tx) {
    TemplateTxData(
      data: tx.data_hex,
      txid: tx.txid_hex,
      hash: tx.hash_hex,
      fee: tx.fee,
      sigops: tx.sigops,
      weight: tx.weight,
      depends: tx.depends,
    )
  })

  // Calculate subsidy for height 0 (will be adjusted in RPC)
  let subsidy = 5_000_000_000

  BlockTemplateData(
    transactions: txs,
    coinbase_value: subsidy + data.total_fees,
    total_fees: data.total_fees,
    weight_used: data.weight_used,
    sigops_used: data.sigops_used,
    height: 0,  // Will be set by RPC handler
    bits: 0x1d00ffff,
  )
}

// ============================================================================
// Adapter Actor for Sync Queries
// ============================================================================

/// State for sync adapter
type SyncAdapterState {
  SyncAdapterState(target: Subject(supervisor.SyncMsg))
}

/// Start an adapter that translates RPC sync queries to supervisor messages
pub fn start_sync_adapter(
  sync: Subject(supervisor.SyncMsg),
) -> Result(Subject(SyncQuery), actor.StartError) {
  actor.start(
    SyncAdapterState(target: sync),
    handle_sync_query,
  )
}

fn handle_sync_query(
  msg: SyncQuery,
  state: SyncAdapterState,
) -> actor.Next(SyncQuery, SyncAdapterState) {
  case msg {
    QuerySyncState(reply) -> {
      let status = process.call(state.target, supervisor.GetStatus, 5000)
      let is_syncing = status.state != "idle"
      let result = SyncState(
        state: status.state,
        headers_height: status.headers_height,
        blocks_height: status.blocks_height,
        is_syncing: is_syncing,
      )
      process.send(reply, result)
      actor.continue(state)
    }
  }
}

// ============================================================================
// Combined Node Handles for RPC
// ============================================================================

/// Combined handles for RPC service
pub type RpcNodeHandles {
  RpcNodeHandles(
    chainstate: Subject(ChainstateQuery),
    mempool: Subject(MempoolQuery),
    sync: Subject(SyncQuery),
  )
}

/// Create RPC-compatible handles from supervisor handles
pub fn create_rpc_handles(
  handles: supervisor.NodeHandles,
) -> Result(RpcNodeHandles, actor.StartError) {
  // Start adapter actors
  case start_chainstate_adapter(handles.chainstate) {
    Error(e) -> Error(e)
    Ok(chainstate_adapter) -> {
      case start_mempool_adapter(handles.mempool) {
        Error(e) -> Error(e)
        Ok(mempool_adapter) -> {
          case start_sync_adapter(handles.sync) {
            Error(e) -> Error(e)
            Ok(sync_adapter) -> {
              Ok(RpcNodeHandles(
                chainstate: chainstate_adapter,
                mempool: mempool_adapter,
                sync: sync_adapter,
              ))
            }
          }
        }
      }
    }
  }
}

// ============================================================================
// Convenience Functions
// ============================================================================

/// Start all node actors and create RPC handles
pub fn start_node_with_rpc(
  network: oni_bitcoin.Network,
  mempool_max_size: Int,
) -> Result(#(supervisor.NodeHandles, RpcNodeHandles), String) {
  // Start chainstate
  case supervisor.start_chainstate(network) {
    Error(_) -> Error("Failed to start chainstate")
    Ok(chainstate) -> {
      // Start mempool
      case supervisor.start_mempool(mempool_max_size) {
        Error(_) -> Error("Failed to start mempool")
        Ok(mempool) -> {
          // Start sync
          case supervisor.start_sync() {
            Error(_) -> Error("Failed to start sync")
            Ok(sync) -> {
              let node_handles = supervisor.NodeHandles(
                chainstate: chainstate,
                mempool: mempool,
                sync: sync,
              )

              // Create RPC handles
              case create_rpc_handles(node_handles) {
                Error(_) -> Error("Failed to create RPC handles")
                Ok(rpc_handles) -> Ok(#(node_handles, rpc_handles))
              }
            }
          }
        }
      }
    }
  }
}
