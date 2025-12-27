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
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import oni_bitcoin
import supervisor
import rpc_service.{
  type ChainstateQuery, type MempoolQuery, type SyncQuery, type SyncState,
  QueryHeight, QueryMempoolSize, QueryMempoolTxids, QueryNetwork,
  QuerySyncState, QueryTip, SyncState,
}

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
  }
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
