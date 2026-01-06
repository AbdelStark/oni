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
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/supervisor
import oni_bitcoin
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

  let initial_state =
    ChainstateState(
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
      case
        oni_storage.storage_connect_block(
          state.storage,
          block,
          block_hash,
          new_height,
        )
      {
        Ok(#(new_storage, _undo)) -> {
          let new_state =
            ChainstateState(
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
              let new_state =
                ChainstateState(
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
          let coin_info =
            CoinInfo(
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
  /// Get template transactions for mining
  GetTemplateData(height: Int, bits: Int, reply: Subject(MempoolTemplateData))
  /// Clear the mempool (e.g., after a block is connected)
  ClearConfirmed(txids: List(oni_bitcoin.Txid))
  /// Revalidate and re-add transactions after a reorg
  RevalidateAndAdd(txs: List(oni_bitcoin.Transaction))
  /// Shutdown the mempool
  MempoolShutdown
}

/// Template data from mempool for block creation
pub type MempoolTemplateData {
  MempoolTemplateData(
    transactions: List(TemplateTxInfo),
    total_fees: Int,
    weight_used: Int,
    sigops_used: Int,
  )
}

/// Transaction info for template
pub type TemplateTxInfo {
  TemplateTxInfo(
    data_hex: String,
    txid_hex: String,
    hash_hex: String,
    fee: Int,
    sigops: Int,
    weight: Int,
    depends: List(Int),
  )
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
  let initial_state = MempoolState(txs: dict.new(), size: 0, max_size: max_size)

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
          // Perform basic stateless validation
          case validate_tx_basic(tx) {
            Error(error_msg) -> {
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
                  let new_state =
                    MempoolState(..state, txs: new_txs, size: state.size + 1)
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
          let new_state =
            MempoolState(..state, txs: new_txs, size: state.size - 1)
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
      let txids =
        dict.fold(state.txs, [], fn(acc, txid_hex, _tx) {
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
      let new_txs =
        list.fold(txids, state.txs, fn(txs, txid) {
          let txid_hex = oni_bitcoin.txid_to_hex(txid)
          dict.delete(txs, txid_hex)
        })
      let new_size = dict.size(new_txs)
      let new_state = MempoolState(..state, txs: new_txs, size: new_size)
      actor.continue(new_state)
    }

    GetTemplateData(height, bits, reply) -> {
      // Build template data from mempool transactions
      // For now, return empty template if mempool is empty or simplified
      let template_data = build_template_data(state, height, bits)
      process.send(reply, template_data)
      actor.continue(state)
    }

    RevalidateAndAdd(txs) -> {
      // Revalidate and re-add transactions after a reorg
      // This is called when blocks are disconnected and txs need to go back to mempool
      let new_state =
        list.fold(txs, state, fn(acc_state, tx) {
          // Basic validation - in production would do full contextual validation
          case validate_tx_basic(tx) {
            Ok(Nil) -> {
              let txid = oni_bitcoin.txid_from_tx(tx)
              let txid_hex = oni_bitcoin.txid_to_hex(txid)
              // Only add if not already in mempool
              case dict.has_key(acc_state.txs, txid_hex) {
                True -> acc_state
                False -> {
                  let new_txs = dict.insert(acc_state.txs, txid_hex, tx)
                  MempoolState(
                    ..acc_state,
                    txs: new_txs,
                    size: acc_state.size + 1,
                  )
                }
              }
            }
            Error(_) -> acc_state
          }
        })
      actor.continue(new_state)
    }

    MempoolShutdown -> {
      actor.Stop(process.Normal)
    }
  }
}

/// Basic stateless transaction validation
fn validate_tx_basic(tx: oni_bitcoin.Transaction) -> Result(Nil, String) {
  // Check non-empty inputs
  case list.is_empty(tx.inputs) {
    True -> Error("Transaction has no inputs")
    False -> {
      // Check non-empty outputs
      case list.is_empty(tx.outputs) {
        True -> Error("Transaction has no outputs")
        False -> Ok(Nil)
      }
    }
  }
}

/// Build template data from mempool state
fn build_template_data(
  state: MempoolState,
  height: Int,
  _bits: Int,
) -> MempoolTemplateData {
  // Get transactions sorted by some fee metric (simplified)
  let txs = dict.values(state.txs)

  // Calculate subsidy
  let halving_interval = 210_000
  let initial_subsidy = 5_000_000_000
  // 50 BTC
  let halvings = height / halving_interval
  let _subsidy = case halvings >= 64 {
    True -> 0
    False -> int.bitwise_shift_right(initial_subsidy, halvings)
  }

  // Build template transactions
  let #(template_txs, total_fees, total_weight, total_sigops) =
    build_template_txs(txs, [], 0, 0, 0, 0)

  MempoolTemplateData(
    transactions: template_txs,
    total_fees: total_fees,
    weight_used: total_weight,
    sigops_used: total_sigops,
  )
}

fn build_template_txs(
  remaining: List(oni_bitcoin.Transaction),
  acc: List(TemplateTxInfo),
  idx: Int,
  fees: Int,
  weight: Int,
  sigops: Int,
) -> #(List(TemplateTxInfo), Int, Int, Int) {
  // Max weight for block (minus coinbase overhead)
  let max_weight = 4_000_000 - 1000

  case remaining {
    [] -> #(list.reverse(acc), fees, weight, sigops)
    [tx, ..rest] -> {
      // Estimate tx weight and sigops
      let tx_weight = oni_bitcoin.tx_weight(tx)
      let tx_sigops = list.length(tx.inputs) + list.length(tx.outputs)
      let tx_fee = 1000
      // Placeholder fee (would come from mempool entry)

      // Check if fits
      case weight + tx_weight <= max_weight {
        False -> #(list.reverse(acc), fees, weight, sigops)
        True -> {
          // Encode transaction
          let txid = oni_bitcoin.txid_from_tx(tx)
          let wtxid = oni_bitcoin.wtxid_from_tx(tx)
          let tx_data = oni_bitcoin.encode_tx(tx)

          let info =
            TemplateTxInfo(
              data_hex: oni_bitcoin.hex_encode(tx_data),
              txid_hex: oni_bitcoin.txid_to_hex(txid),
              hash_hex: oni_bitcoin.hash256_to_hex(wtxid.hash),
              fee: tx_fee,
              sigops: tx_sigops,
              weight: tx_weight,
              depends: [],
              // Simplified - no dependency tracking
            )

          build_template_txs(
            rest,
            [info, ..acc],
            idx + 1,
            fees + tx_fee,
            weight + tx_weight,
            sigops + tx_sigops,
          )
        }
      }
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
pub fn start_sync() -> Result(Subject(SyncMsg), actor.StartError) {
  let initial_state =
    SyncState(
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
      let new_state =
        SyncState(
          ..state,
          state: "syncing_headers",
          syncing_from: Some(peer_id),
        )
      actor.continue(new_state)
    }

    OnHeaders(_peer_id, count) -> {
      let new_state =
        SyncState(..state, headers_height: state.headers_height + count)
      actor.continue(new_state)
    }

    OnBlock(_hash) -> {
      let new_state = SyncState(..state, blocks_height: state.blocks_height + 1)
      actor.continue(new_state)
    }

    GetStatus(reply) -> {
      let peers = case state.syncing_from {
        Some(_) -> 1
        None -> 0
      }
      let status =
        SyncStatus(
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
  let spec =
    supervisor.Spec(
      argument: network,
      max_frequency: 5,
      frequency_period: 1,
      init: fn(children) {
        // Start chainstate
        children
        |> supervisor.add(supervisor.worker(fn(net) { start_chainstate(net) }))
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
    mempool_max_size: 300_000_000,
    // 300 MB
  )
}
