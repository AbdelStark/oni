// supervisor.gleam - OTP supervision tree for oni node
//
// This module implements the supervision tree that manages all node subsystems:
// - Chainstate: manages the UTXO set and block index
// - P2P Manager: handles peer connections and message routing
// - Mempool: holds pending transactions
// - Sync Coordinator: manages IBD and block sync
// - RPC Server: handles JSON-RPC requests
//
// The supervision strategy is rest-for-one: if a critical component fails,
// all components started after it are restarted.

import gleam/erlang/process.{type Subject}
import gleam/otp/actor
import gleam/otp/supervisor
import gleam/option.{type Option, None, Some}
import oni_bitcoin

// ============================================================================
// Node Handles
// ============================================================================

/// Handles to all node subsystems, returned after successful startup
pub type NodeHandles {
  NodeHandles(
    chainstate: Subject(ChainstateMsg),
    mempool: Subject(MempoolMsg),
    sync: Subject(SyncMsg),
  )
}

// ============================================================================
// Chainstate Actor
// ============================================================================

/// Messages for the chainstate actor
pub type ChainstateMsg {
  /// Get the current tip hash
  GetTip(reply: Subject(Option(oni_bitcoin.BlockHash)))
  /// Get the current tip height
  GetHeight(reply: Subject(Int))
  /// Connect a block to the chain
  ConnectBlock(block: oni_bitcoin.Block, reply: Subject(Result(Nil, String)))
  /// Disconnect the tip block
  DisconnectBlock(reply: Subject(Result(Nil, String)))
  /// Get a UTXO
  GetUtxo(outpoint: oni_bitcoin.OutPoint, reply: Subject(Option(CoinInfo)))
  /// Shutdown the chainstate
  ChainstateShutdown
}

/// UTXO information
pub type CoinInfo {
  CoinInfo(
    value: oni_bitcoin.Amount,
    script_pubkey: oni_bitcoin.Script,
    height: Int,
    is_coinbase: Bool,
  )
}

/// Chainstate actor state
pub type ChainstateState {
  ChainstateState(
    tip_hash: Option(oni_bitcoin.BlockHash),
    tip_height: Int,
    network: oni_bitcoin.Network,
  )
}

/// Start the chainstate actor
pub fn start_chainstate(
  network: oni_bitcoin.Network,
) -> Result(Subject(ChainstateMsg), actor.StartError) {
  let initial_state = ChainstateState(
    tip_hash: None,
    tip_height: 0,
    network: network,
  )

  actor.start(initial_state, handle_chainstate_msg)
}

fn handle_chainstate_msg(
  msg: ChainstateMsg,
  state: ChainstateState,
) -> actor.Next(ChainstateMsg, ChainstateState) {
  case msg {
    GetTip(reply) -> {
      process.send(reply, state.tip_hash)
      actor.continue(state)
    }

    GetHeight(reply) -> {
      process.send(reply, state.tip_height)
      actor.continue(state)
    }

    ConnectBlock(_block, reply) -> {
      // TODO: Implement actual block connection
      // For now, just increment height
      let new_state = ChainstateState(
        ..state,
        tip_height: state.tip_height + 1,
      )
      process.send(reply, Ok(Nil))
      actor.continue(new_state)
    }

    DisconnectBlock(reply) -> {
      // TODO: Implement actual block disconnection
      case state.tip_height > 0 {
        True -> {
          let new_state = ChainstateState(
            ..state,
            tip_height: state.tip_height - 1,
          )
          process.send(reply, Ok(Nil))
          actor.continue(new_state)
        }
        False -> {
          process.send(reply, Error("Cannot disconnect genesis"))
          actor.continue(state)
        }
      }
    }

    GetUtxo(_outpoint, reply) -> {
      // TODO: Implement actual UTXO lookup
      process.send(reply, None)
      actor.continue(state)
    }

    ChainstateShutdown -> {
      actor.Stop(process.Normal)
    }
  }
}

// ============================================================================
// Mempool Actor
// ============================================================================

/// Messages for the mempool actor
pub type MempoolMsg {
  /// Add a transaction to the mempool
  AddTx(tx: oni_bitcoin.Transaction, reply: Subject(Result(Nil, String)))
  /// Remove a transaction from the mempool
  RemoveTx(txid: oni_bitcoin.Txid)
  /// Get mempool size
  GetSize(reply: Subject(Int))
  /// Get all transaction IDs in mempool
  GetTxids(reply: Subject(List(oni_bitcoin.Txid)))
  /// Clear the mempool (e.g., after a block is connected)
  ClearConfirmed(txids: List(oni_bitcoin.Txid))
  /// Shutdown the mempool
  MempoolShutdown
}

/// Mempool actor state
pub type MempoolState {
  MempoolState(
    txs: List(oni_bitcoin.Transaction),
    size: Int,
    max_size: Int,
  )
}

/// Start the mempool actor
pub fn start_mempool(
  max_size: Int,
) -> Result(Subject(MempoolMsg), actor.StartError) {
  let initial_state = MempoolState(
    txs: [],
    size: 0,
    max_size: max_size,
  )

  actor.start(initial_state, handle_mempool_msg)
}

fn handle_mempool_msg(
  msg: MempoolMsg,
  state: MempoolState,
) -> actor.Next(MempoolMsg, MempoolState) {
  case msg {
    AddTx(tx, reply) -> {
      // TODO: Implement validation
      case state.size >= state.max_size {
        True -> {
          process.send(reply, Error("Mempool full"))
          actor.continue(state)
        }
        False -> {
          let new_state = MempoolState(
            ..state,
            txs: [tx, ..state.txs],
            size: state.size + 1,
          )
          process.send(reply, Ok(Nil))
          actor.continue(new_state)
        }
      }
    }

    RemoveTx(_txid) -> {
      // TODO: Implement removal by txid
      actor.continue(state)
    }

    GetSize(reply) -> {
      process.send(reply, state.size)
      actor.continue(state)
    }

    GetTxids(reply) -> {
      let txids = []  // TODO: Extract txids from transactions
      process.send(reply, txids)
      actor.continue(state)
    }

    ClearConfirmed(_txids) -> {
      // TODO: Remove confirmed transactions
      actor.continue(state)
    }

    MempoolShutdown -> {
      actor.Stop(process.Normal)
    }
  }
}

// ============================================================================
// Sync Coordinator Actor
// ============================================================================

/// Messages for the sync coordinator actor
pub type SyncMsg {
  /// Start syncing headers from a peer
  StartSync(peer_id: String)
  /// Header received from peer
  OnHeaders(peer_id: String, count: Int)
  /// Block received from peer
  OnBlock(hash: oni_bitcoin.BlockHash)
  /// Get sync status
  GetStatus(reply: Subject(SyncStatus))
  /// Shutdown sync coordinator
  SyncShutdown
}

/// Sync status
pub type SyncStatus {
  SyncStatus(
    state: String,
    headers_height: Int,
    blocks_height: Int,
    peers_syncing: Int,
  )
}

/// Sync coordinator state
pub type SyncState {
  SyncState(
    state: String,
    headers_height: Int,
    blocks_height: Int,
    syncing_from: Option(String),
  )
}

/// Start the sync coordinator actor
pub fn start_sync(
) -> Result(Subject(SyncMsg), actor.StartError) {
  let initial_state = SyncState(
    state: "idle",
    headers_height: 0,
    blocks_height: 0,
    syncing_from: None,
  )

  actor.start(initial_state, handle_sync_msg)
}

fn handle_sync_msg(
  msg: SyncMsg,
  state: SyncState,
) -> actor.Next(SyncMsg, SyncState) {
  case msg {
    StartSync(peer_id) -> {
      let new_state = SyncState(
        ..state,
        state: "syncing_headers",
        syncing_from: Some(peer_id),
      )
      actor.continue(new_state)
    }

    OnHeaders(_peer_id, count) -> {
      let new_state = SyncState(
        ..state,
        headers_height: state.headers_height + count,
      )
      actor.continue(new_state)
    }

    OnBlock(_hash) -> {
      let new_state = SyncState(
        ..state,
        blocks_height: state.blocks_height + 1,
      )
      actor.continue(new_state)
    }

    GetStatus(reply) -> {
      let peers = case state.syncing_from {
        Some(_) -> 1
        None -> 0
      }
      let status = SyncStatus(
        state: state.state,
        headers_height: state.headers_height,
        blocks_height: state.blocks_height,
        peers_syncing: peers,
      )
      process.send(reply, status)
      actor.continue(state)
    }

    SyncShutdown -> {
      actor.Stop(process.Normal)
    }
  }
}

// ============================================================================
// Node Supervisor
// ============================================================================

/// Start the node supervisor with all subsystems
pub fn start_node(
  network: oni_bitcoin.Network,
) -> Result(Subject(supervisor.Message), actor.StartError) {
  // Define the supervisor specification
  let spec = supervisor.Spec(
    argument: network,
    max_frequency: 5,
    frequency_period: 1,
    init: fn(children) {
      // Start chainstate
      children
      |> supervisor.add(supervisor.worker(fn(net) {
        start_chainstate(net)
      }))
      // Note: In a full implementation, we would add more children here:
      // - Mempool
      // - Sync coordinator
      // - P2P manager
      // - RPC server
    },
  )

  supervisor.start_spec(spec)
}

/// Configuration for starting the node
pub type NodeStartConfig {
  NodeStartConfig(
    network: oni_bitcoin.Network,
    data_dir: String,
    p2p_port: Int,
    rpc_port: Int,
    max_connections: Int,
    mempool_max_size: Int,
  )
}

/// Default node start configuration
pub fn default_start_config() -> NodeStartConfig {
  NodeStartConfig(
    network: oni_bitcoin.Mainnet,
    data_dir: "~/.oni",
    p2p_port: 8333,
    rpc_port: 8332,
    max_connections: 125,
    mempool_max_size: 300_000_000,  // 300 MB
  )
}
