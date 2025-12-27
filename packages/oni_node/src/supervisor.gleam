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

import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/otp/actor
import gleam/otp/supervisor
import gleam/option.{type Option, None, Some}
import oni_bitcoin
import oni_consensus
import oni_consensus/validation
import oni_storage.{type Storage}

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
  /// Get the network type
  GetNetwork(reply: Subject(oni_bitcoin.Network))
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
    storage: Storage,
  )
}

/// Start the chainstate actor
pub fn start_chainstate(
  network: oni_bitcoin.Network,
) -> Result(Subject(ChainstateMsg), actor.StartError) {
  // Get genesis hash for the network
  let params = case network {
    oni_bitcoin.Mainnet -> oni_bitcoin.mainnet_params()
    oni_bitcoin.Testnet -> oni_bitcoin.testnet_params()
    oni_bitcoin.Regtest -> oni_bitcoin.regtest_params()
    oni_bitcoin.Signet -> oni_bitcoin.testnet_params()
  }

  // Initialize storage with genesis
  let storage = oni_storage.storage_new(params.genesis_hash)

  let initial_state = ChainstateState(
    tip_hash: Some(params.genesis_hash),
    tip_height: 0,
    network: network,
    storage: storage,
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

    GetNetwork(reply) -> {
      process.send(reply, state.network)
      actor.continue(state)
    }

    ConnectBlock(block, reply) -> {
      // Compute block hash from header
      let block_hash = oni_bitcoin.block_hash_from_header(block.header)
      let new_height = state.tip_height + 1

      // Connect block using storage layer
      case oni_storage.storage_connect_block(state.storage, block, block_hash, new_height) {
        Ok(#(new_storage, _undo)) -> {
          let new_state = ChainstateState(
            ..state,
            tip_hash: Some(block_hash),
            tip_height: new_height,
            storage: new_storage,
          )
          process.send(reply, Ok(Nil))
          actor.continue(new_state)
        }
        Error(storage_error) -> {
          let error_msg = storage_error_to_string(storage_error)
          process.send(reply, Error(error_msg))
          actor.continue(state)
        }
      }
    }

    DisconnectBlock(reply) -> {
      case state.tip_height > 0, state.tip_hash {
        True, Some(tip_hash) -> {
          // Disconnect block using storage layer
          case oni_storage.storage_disconnect_block(state.storage, tip_hash) {
            Ok(new_storage) -> {
              let new_tip = oni_storage.storage_get_tip(new_storage)
              let new_height = oni_storage.storage_get_height(new_storage)
              let new_state = ChainstateState(
                ..state,
                tip_hash: Some(new_tip),
                tip_height: new_height,
                storage: new_storage,
              )
              process.send(reply, Ok(Nil))
              actor.continue(new_state)
            }
            Error(storage_error) -> {
              let error_msg = storage_error_to_string(storage_error)
              process.send(reply, Error(error_msg))
              actor.continue(state)
            }
          }
        }
        _, _ -> {
          process.send(reply, Error("Cannot disconnect genesis"))
          actor.continue(state)
        }
      }
    }

    GetUtxo(outpoint, reply) -> {
      // Lookup UTXO in the storage layer
      case oni_storage.storage_get_utxo(state.storage, outpoint) {
        Some(coin) -> {
          // Convert storage Coin to CoinInfo
          let coin_info = CoinInfo(
            value: coin.output.value,
            script_pubkey: coin.output.script_pubkey,
            height: coin.height,
            is_coinbase: coin.is_coinbase,
          )
          process.send(reply, Some(coin_info))
        }
        None -> {
          process.send(reply, None)
        }
      }
      actor.continue(state)
    }

    ChainstateShutdown -> {
      actor.Stop(process.Normal)
    }
  }
}

/// Convert storage error to string for error messages
fn storage_error_to_string(error: oni_storage.StorageError) -> String {
  case error {
    oni_storage.NotFound -> "Block or UTXO not found"
    oni_storage.CorruptData -> "Corrupt data in storage"
    oni_storage.DatabaseError(msg) -> "Database error: " <> msg
    oni_storage.IoError(msg) -> "IO error: " <> msg
    oni_storage.MigrationRequired -> "Database migration required"
    oni_storage.ChecksumMismatch -> "Checksum mismatch"
    oni_storage.OutOfSpace -> "Out of disk space"
    oni_storage.BlockNotInMainChain -> "Block not in main chain"
    oni_storage.InvalidBlockHeight -> "Invalid block height"
    oni_storage.UndoDataMissing -> "Undo data missing"
    oni_storage.InvalidUndoData -> "Invalid undo data"
    oni_storage.Other(msg) -> msg
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
    /// Transactions indexed by txid hex
    txs: Dict(String, oni_bitcoin.Transaction),
    /// Number of transactions
    size: Int,
    /// Maximum number of transactions
    max_size: Int,
  )
}

/// Start the mempool actor
pub fn start_mempool(
  max_size: Int,
) -> Result(Subject(MempoolMsg), actor.StartError) {
  let initial_state = MempoolState(
    txs: dict.new(),
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
      // Check mempool size limit
      case state.size >= state.max_size {
        True -> {
          process.send(reply, Error("Mempool full"))
          actor.continue(state)
        }
        False -> {
          // Perform stateless validation
          case validation.validate_tx_stateless(tx) {
            Error(consensus_error) -> {
              let error_msg = consensus_error_to_string(consensus_error)
              process.send(reply, Error(error_msg))
              actor.continue(state)
            }
            Ok(_) -> {
              // Compute txid and add to mempool
              let txid = oni_bitcoin.txid_from_tx(tx)
              let txid_hex = oni_bitcoin.txid_to_hex(txid)

              // Check if already in mempool
              case dict.has_key(state.txs, txid_hex) {
                True -> {
                  process.send(reply, Error("Transaction already in mempool"))
                  actor.continue(state)
                }
                False -> {
                  let new_txs = dict.insert(state.txs, txid_hex, tx)
                  let new_state = MempoolState(
                    ..state,
                    txs: new_txs,
                    size: state.size + 1,
                  )
                  process.send(reply, Ok(Nil))
                  actor.continue(new_state)
                }
              }
            }
          }
        }
      }
    }

    RemoveTx(txid) -> {
      let txid_hex = oni_bitcoin.txid_to_hex(txid)
      case dict.has_key(state.txs, txid_hex) {
        False -> actor.continue(state)
        True -> {
          let new_txs = dict.delete(state.txs, txid_hex)
          let new_state = MempoolState(
            ..state,
            txs: new_txs,
            size: state.size - 1,
          )
          actor.continue(new_state)
        }
      }
    }

    GetSize(reply) -> {
      process.send(reply, state.size)
      actor.continue(state)
    }

    GetTxids(reply) -> {
      // Extract txids from the dict keys
      let txids = dict.fold(state.txs, [], fn(acc, txid_hex, _tx) {
        case oni_bitcoin.txid_from_hex(txid_hex) {
          Ok(txid) -> [txid, ..acc]
          Error(_) -> acc
        }
      })
      process.send(reply, txids)
      actor.continue(state)
    }

    ClearConfirmed(txids) -> {
      // Remove all confirmed transactions from mempool
      let new_txs = list.fold(txids, state.txs, fn(txs, txid) {
        let txid_hex = oni_bitcoin.txid_to_hex(txid)
        dict.delete(txs, txid_hex)
      })
      let new_size = dict.size(new_txs)
      let new_state = MempoolState(
        ..state,
        txs: new_txs,
        size: new_size,
      )
      actor.continue(new_state)
    }

    MempoolShutdown -> {
      actor.Stop(process.Normal)
    }
  }
}

/// Convert consensus error to string for error messages
fn consensus_error_to_string(error: oni_consensus.ConsensusError) -> String {
  case error {
    // Script errors
    oni_consensus.ScriptInvalid -> "Invalid script"
    oni_consensus.ScriptDisabledOpcode -> "Disabled opcode"
    oni_consensus.ScriptStackUnderflow -> "Stack underflow"
    oni_consensus.ScriptStackOverflow -> "Stack overflow"
    oni_consensus.ScriptVerifyFailed -> "Verify failed"
    oni_consensus.ScriptEqualVerifyFailed -> "Equal verify failed"
    oni_consensus.ScriptCheckSigFailed -> "Signature verification failed"
    oni_consensus.ScriptCheckMultisigFailed -> "Multisig verification failed"
    oni_consensus.ScriptCheckLockTimeVerifyFailed -> "CLTV verification failed"
    oni_consensus.ScriptCheckSequenceVerifyFailed -> "CSV verification failed"
    oni_consensus.ScriptPushSizeExceeded -> "Push size exceeded"
    oni_consensus.ScriptOpCountExceeded -> "Op count exceeded"
    oni_consensus.ScriptBadOpcode -> "Bad opcode"
    oni_consensus.ScriptMinimalData -> "Non-minimal data encoding"
    oni_consensus.ScriptWitnessMalleated -> "Witness malleated"
    oni_consensus.ScriptWitnessUnexpected -> "Unexpected witness"
    oni_consensus.ScriptCleanStack -> "Clean stack requirement not met"
    oni_consensus.ScriptSizeTooLarge -> "Script too large"

    // Transaction errors
    oni_consensus.TxMissingInputs -> "Missing inputs"
    oni_consensus.TxDuplicateInputs -> "Duplicate inputs"
    oni_consensus.TxEmptyInputs -> "Transaction has no inputs"
    oni_consensus.TxEmptyOutputs -> "Transaction has no outputs"
    oni_consensus.TxOversized -> "Transaction too large"
    oni_consensus.TxBadVersion -> "Bad transaction version"
    oni_consensus.TxInvalidAmount -> "Invalid transaction amount"
    oni_consensus.TxOutputValueOverflow -> "Output value overflow"
    oni_consensus.TxInputNotFound -> "Input not found"
    oni_consensus.TxInputSpent -> "Input already spent"
    oni_consensus.TxInputsNotAvailable -> "Inputs not available"
    oni_consensus.TxPrematureCoinbaseSpend -> "Premature coinbase spend"
    oni_consensus.TxSequenceLockNotMet -> "Sequence lock not met"
    oni_consensus.TxLockTimeNotMet -> "Locktime not met"
    oni_consensus.TxSigOpCountExceeded -> "Sigop count exceeded"

    // Block errors
    oni_consensus.BlockInvalidHeader -> "Invalid block header"
    oni_consensus.BlockInvalidPoW -> "Invalid proof of work"
    oni_consensus.BlockInvalidMerkleRoot -> "Invalid merkle root"
    oni_consensus.BlockInvalidWitnessCommitment -> "Invalid witness commitment"
    oni_consensus.BlockTimestampTooOld -> "Block timestamp too old"
    oni_consensus.BlockTimestampTooFar -> "Block timestamp too far in future"
    oni_consensus.BlockBadVersion -> "Bad block version"
    oni_consensus.BlockTooLarge -> "Block too large"
    oni_consensus.BlockWeightExceeded -> "Block weight exceeded"
    oni_consensus.BlockBadCoinbase -> "Bad coinbase"
    oni_consensus.BlockDuplicateTx -> "Duplicate transaction in block"
    oni_consensus.BlockBadPrevBlock -> "Bad previous block"

    // Other
    oni_consensus.Other(msg) -> msg
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
  /// Get sync status (full status object)
  GetStatus(reply: Subject(SyncStatus))
  /// Get sync state string (simple state query)
  GetSyncState(reply: Subject(String))
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

    GetSyncState(reply) -> {
      process.send(reply, state.state)
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
