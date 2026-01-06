// node_rpc.gleam - Adapter connecting RPC service to node actors
//
// This module provides the glue between the RPC service types and
// the supervisor actor message types. It creates adapter actors
// that translate RPC queries into supervisor messages.
//
// The adapter actors receive RPC query messages and forward them
// to the underlying supervisor actors, translating between the
// RPC service types and supervisor message types.

import gleam/bit_array
import gleam/erlang/process.{type Subject}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import oni_bitcoin
import oni_supervisor
import regtest_miner
import rpc_service.{
  type BlockTemplateData, type ChainstateQuery, type GenerateResult,
  type MempoolQuery, type SyncQuery, type TemplateTxData, BlockTemplateData,
  EstimateSmartFee, GenerateError, GenerateSuccess, MineBlocks, MineToAddress,
  QueryBlockTemplate, QueryHeight, QueryMempoolSize, QueryMempoolTxids,
  QueryNetwork, QuerySyncState, QueryTip, SubmitBlock, SubmitBlockAccepted,
  SubmitBlockDuplicate, SubmitBlockRejected, SubmitTx, SubmitTxAccepted,
  SubmitTxRejected, SyncState, TemplateTxData, TestMempoolAccept,
}

// ============================================================================
// Adapter Actor for Chainstate Queries
// ============================================================================

/// State for chainstate adapter
type ChainstateAdapterState {
  ChainstateAdapterState(target: Subject(oni_supervisor.ChainstateMsg))
}

/// Start an adapter that translates RPC chainstate queries to supervisor messages
pub fn start_chainstate_adapter(
  chainstate: Subject(oni_supervisor.ChainstateMsg),
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
      let result = process.call(state.target, oni_supervisor.GetTip, 5000)
      process.send(reply, result)
      actor.continue(state)
    }

    QueryHeight(reply) -> {
      let result = process.call(state.target, oni_supervisor.GetHeight, 5000)
      process.send(reply, result)
      actor.continue(state)
    }

    QueryNetwork(reply) -> {
      let result = process.call(state.target, oni_supervisor.GetNetwork, 5000)
      process.send(reply, result)
      actor.continue(state)
    }

    SubmitBlock(block, reply) -> {
      // Submit block to chainstate for validation and connection
      // First check if block connects to our tip (basic validation)
      let tip_result = process.call(state.target, oni_supervisor.GetTip, 5000)

      case tip_result {
        None -> {
          // No tip yet, only genesis allowed
          process.send(reply, SubmitBlockRejected("no chain tip"))
          actor.continue(state)
        }
        Some(current_tip) -> {
          // Check if this block's prev_hash matches our tip
          let block_prev = block.header.prev_block
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
              let connect_result =
                process.call(
                  state.target,
                  oni_supervisor.ConnectBlock(block, _),
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

    MineToAddress(nblocks, address, _maxtries, reply) -> {
      // Only allow in regtest
      let network = process.call(state.target, oni_supervisor.GetNetwork, 5000)
      case network {
        oni_bitcoin.Regtest -> {
          let result = perform_mining(state.target, nblocks, Some(address))
          process.send(reply, result)
          actor.continue(state)
        }
        _ -> {
          process.send(reply, GenerateError("Mining only available in regtest"))
          actor.continue(state)
        }
      }
    }

    MineBlocks(nblocks, _maxtries, reply) -> {
      let network = process.call(state.target, oni_supervisor.GetNetwork, 5000)
      case network {
        oni_bitcoin.Regtest -> {
          let result = perform_mining(state.target, nblocks, None)
          process.send(reply, result)
          actor.continue(state)
        }
        _ -> {
          process.send(reply, GenerateError("Mining only available in regtest"))
          actor.continue(state)
        }
      }
    }
  }
}

/// Perform mining and connect blocks to chainstate
fn perform_mining(
  chainstate: Subject(oni_supervisor.ChainstateMsg),
  nblocks: Int,
  address: Option(String),
) -> GenerateResult {
  // Get current tip and height
  let tip_opt = process.call(chainstate, oni_supervisor.GetTip, 5000)
  let height = process.call(chainstate, oni_supervisor.GetHeight, 5000)

  case tip_opt {
    None -> GenerateError("No chain tip available")
    Some(prev_block) -> {
      // Create mining config
      let config = case address {
        Some(addr) ->
          regtest_miner.MiningConfig(
            ..regtest_miner.default_config(),
            coinbase_address: Some(addr),
            coinbase_script: address_to_script(addr),
          )
        None -> regtest_miner.default_config()
      }

      // Get current timestamp
      let base_time = erlang_now_secs()

      // Mine blocks
      case
        regtest_miner.generate_blocks(
          config,
          prev_block,
          height + 1,
          nblocks,
          base_time,
        )
      {
        Error(err) -> GenerateError(err)
        Ok(blocks) -> {
          // Connect each mined block to chainstate
          case connect_mined_blocks(chainstate, blocks, []) {
            Error(err) -> GenerateError(err)
            Ok(hash_list) -> GenerateSuccess(hash_list)
          }
        }
      }
    }
  }
}

/// Connect mined blocks to chainstate and collect hashes
fn connect_mined_blocks(
  chainstate: Subject(oni_supervisor.ChainstateMsg),
  blocks: List(oni_bitcoin.Block),
  acc: List(String),
) -> Result(List(String), String) {
  case blocks {
    [] -> Ok(list.reverse(acc))
    [block, ..rest] -> {
      let hash = oni_bitcoin.block_hash_from_header(block.header)
      let hash_hex = oni_bitcoin.block_hash_to_hex(hash)

      case
        process.call(chainstate, oni_supervisor.ConnectBlock(block, _), 60_000)
      {
        Ok(_) -> connect_mined_blocks(chainstate, rest, [hash_hex, ..acc])
        Error(reason) -> Error("Failed to connect block: " <> reason)
      }
    }
  }
}

/// Convert address string to output script
fn address_to_script(address: String) -> BitArray {
  // Try bech32/bech32m first
  case oni_bitcoin.decode_bech32_address(address) {
    Ok(#(witness_version, program)) -> {
      case witness_version {
        0 -> {
          let prog_len = bit_array.byte_size(program)
          <<0, prog_len, program:bits>>
        }
        1 -> {
          let prog_len = bit_array.byte_size(program)
          <<0x51, prog_len, program:bits>>
        }
        _ -> regtest_miner.default_config().coinbase_script
      }
    }
    Error(_) -> {
      // Try base58check
      case oni_bitcoin.decode_base58check(address) {
        Ok(#(version, payload)) -> {
          case version {
            // P2PKH (mainnet=0, testnet/regtest=111)
            0 | 111 -> <<0x76, 0xa9, 0x14, payload:bits, 0x88, 0xac>>
            // P2SH (mainnet=5, testnet/regtest=196)
            5 | 196 -> <<0xa9, 0x14, payload:bits, 0x87>>
            _ -> regtest_miner.default_config().coinbase_script
          }
        }
        Error(_) -> regtest_miner.default_config().coinbase_script
      }
    }
  }
}

/// Get current Unix timestamp in seconds
@external(erlang, "erlang", "system_time")
fn erlang_system_time(unit: Atom) -> Int

fn erlang_now_secs() -> Int {
  erlang_system_time(second_atom())
}

@external(erlang, "erlang", "binary_to_atom")
fn binary_to_atom(bin: BitArray) -> Atom

type Atom

fn second_atom() -> Atom {
  binary_to_atom(<<"second":utf8>>)
}

// ============================================================================
// Adapter Actor for Mempool Queries
// ============================================================================

/// State for mempool adapter
type MempoolAdapterState {
  MempoolAdapterState(target: Subject(oni_supervisor.MempoolMsg))
}

/// Start an adapter that translates RPC mempool queries to supervisor messages
pub fn start_mempool_adapter(
  mempool: Subject(oni_supervisor.MempoolMsg),
) -> Result(Subject(MempoolQuery), actor.StartError) {
  actor.start(MempoolAdapterState(target: mempool), handle_mempool_query)
}

fn handle_mempool_query(
  msg: MempoolQuery,
  state: MempoolAdapterState,
) -> actor.Next(MempoolQuery, MempoolAdapterState) {
  case msg {
    QueryMempoolSize(reply) -> {
      let result = process.call(state.target, oni_supervisor.GetSize, 5000)
      process.send(reply, result)
      actor.continue(state)
    }

    QueryMempoolTxids(reply) -> {
      let result = process.call(state.target, oni_supervisor.GetTxids, 5000)
      process.send(reply, result)
      actor.continue(state)
    }

    QueryBlockTemplate(reply) -> {
      // Get template data from supervisor mempool
      // Use default height=0 and bits (will be overridden by RPC handler)
      let template_data =
        process.call(
          state.target,
          oni_supervisor.GetTemplateData(0, 0x1d00ffff, _),
          30_000,
        )

      // Convert to RPC template format
      let result = convert_template_data(template_data)
      process.send(reply, result)
      actor.continue(state)
    }

    SubmitTx(tx, reply) -> {
      // Forward to supervisor mempool's AddTx
      let add_result =
        process.call(state.target, oni_supervisor.AddTx(tx, _), 30_000)

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

    TestMempoolAccept(_tx, _max_fee_rate, reply) -> {
      // Placeholder - return a basic acceptance result
      let result =
        rpc_service.TestAcceptResult(
          txid: "",
          allowed: True,
          vsize: 0,
          fees: rpc_service.TestAcceptFees(
            base: 0,
            effective_feerate: 0.0,
            effective_includes: [],
          ),
          reject_reason: None,
        )
      process.send(reply, result)
      actor.continue(state)
    }

    EstimateSmartFee(_target_blocks, _mode, reply) -> {
      // Placeholder - return a basic fee estimate
      let result =
        rpc_service.FeeEstimateResult(feerate: 0.00001, errors: [], blocks: 1)
      process.send(reply, result)
      actor.continue(state)
    }
  }
}

/// Convert supervisor template data to RPC format
fn convert_template_data(
  data: oni_supervisor.MempoolTemplateData,
) -> BlockTemplateData {
  let txs =
    list.map(data.transactions, fn(tx) {
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
    height: 0,
    // Will be set by RPC handler
    bits: 0x1d00ffff,
  )
}

// ============================================================================
// Adapter Actor for Sync Queries
// ============================================================================

/// State for sync adapter
type SyncAdapterState {
  SyncAdapterState(target: Subject(oni_supervisor.SyncMsg))
}

/// Start an adapter that translates RPC sync queries to supervisor messages
pub fn start_sync_adapter(
  sync: Subject(oni_supervisor.SyncMsg),
) -> Result(Subject(SyncQuery), actor.StartError) {
  actor.start(SyncAdapterState(target: sync), handle_sync_query)
}

fn handle_sync_query(
  msg: SyncQuery,
  state: SyncAdapterState,
) -> actor.Next(SyncQuery, SyncAdapterState) {
  case msg {
    QuerySyncState(reply) -> {
      let status = process.call(state.target, oni_supervisor.GetStatus, 5000)
      let is_syncing = status.state != "idle"
      let result =
        SyncState(
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
  handles: oni_supervisor.NodeHandles,
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
) -> Result(#(oni_supervisor.NodeHandles, RpcNodeHandles), String) {
  // Start chainstate
  case oni_supervisor.start_chainstate(network) {
    Error(_) -> Error("Failed to start chainstate")
    Ok(chainstate) -> {
      // Start mempool
      case oni_supervisor.start_mempool(mempool_max_size) {
        Error(_) -> Error("Failed to start mempool")
        Ok(mempool) -> {
          // Start sync
          case oni_supervisor.start_sync() {
            Error(_) -> Error("Failed to start sync")
            Ok(sync) -> {
              let node_handles =
                oni_supervisor.NodeHandles(
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
