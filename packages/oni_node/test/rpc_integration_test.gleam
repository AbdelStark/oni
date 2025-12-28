// rpc_integration_test.gleam - Integration tests for RPC service with node actors
//
// These tests verify that:
// 1. The RPC service properly integrates with supervisor actors
// 2. Real node state is returned through RPC calls
// 3. The adapter layer correctly translates between types

import gleeunit
import gleeunit/should
import gleam/erlang/process
import gleam/option.{None, Some}
import oni_bitcoin
import oni_supervisor
import node_rpc
import rpc_service.{QueryHeight, QueryMempoolSize, QueryMempoolTxids, QueryNetwork, QuerySyncState, QueryTip}

pub fn main() {
  gleeunit.main()
}

// ============================================================================
// Chainstate Adapter Tests
// ============================================================================

pub fn chainstate_adapter_query_height_test() {
  // Start a chainstate actor
  let assert Ok(chainstate) = oni_supervisor.start_chainstate(oni_bitcoin.Regtest)

  // Start the adapter
  let assert Ok(adapter) = node_rpc.start_chainstate_adapter(chainstate)

  // Query height through adapter
  let height = process.call(adapter, QueryHeight, 5000)

  // Should be 0 (genesis)
  should.equal(height, 0)
}

pub fn chainstate_adapter_query_tip_test() {
  // Start a chainstate actor
  let assert Ok(chainstate) = oni_supervisor.start_chainstate(oni_bitcoin.Regtest)

  // Start the adapter
  let assert Ok(adapter) = node_rpc.start_chainstate_adapter(chainstate)

  // Query tip through adapter
  let tip = process.call(adapter, QueryTip, 5000)

  // Should have a tip (genesis hash)
  should.be_true(option.is_some(tip))
}

pub fn chainstate_adapter_query_network_test() {
  // Start a chainstate actor for testnet
  let assert Ok(chainstate) = oni_supervisor.start_chainstate(oni_bitcoin.Testnet)

  // Start the adapter
  let assert Ok(adapter) = node_rpc.start_chainstate_adapter(chainstate)

  // Query network through adapter
  let network = process.call(adapter, QueryNetwork, 5000)

  // Should be testnet
  should.equal(network, oni_bitcoin.Testnet)
}

pub fn chainstate_adapter_regtest_network_test() {
  // Start a chainstate actor for regtest
  let assert Ok(chainstate) = oni_supervisor.start_chainstate(oni_bitcoin.Regtest)

  // Start the adapter
  let assert Ok(adapter) = node_rpc.start_chainstate_adapter(chainstate)

  // Query network through adapter
  let network = process.call(adapter, QueryNetwork, 5000)

  // Should be regtest
  should.equal(network, oni_bitcoin.Regtest)
}

// ============================================================================
// Mempool Adapter Tests
// ============================================================================

pub fn mempool_adapter_query_size_test() {
  // Start a mempool actor
  let assert Ok(mempool) = oni_supervisor.start_mempool(1000)

  // Start the adapter
  let assert Ok(adapter) = node_rpc.start_mempool_adapter(mempool)

  // Query size through adapter
  let size = process.call(adapter, QueryMempoolSize, 5000)

  // Should be 0 (empty)
  should.equal(size, 0)
}

pub fn mempool_adapter_query_txids_test() {
  // Start a mempool actor
  let assert Ok(mempool) = oni_supervisor.start_mempool(1000)

  // Start the adapter
  let assert Ok(adapter) = node_rpc.start_mempool_adapter(mempool)

  // Query txids through adapter
  let txids = process.call(adapter, QueryMempoolTxids, 5000)

  // Should be empty list
  should.equal(txids, [])
}

// ============================================================================
// Sync Adapter Tests
// ============================================================================

pub fn sync_adapter_query_state_test() {
  // Start a sync actor
  let assert Ok(sync) = oni_supervisor.start_sync()

  // Start the adapter
  let assert Ok(adapter) = node_rpc.start_sync_adapter(sync)

  // Query state through adapter
  let state = process.call(adapter, QuerySyncState, 5000)

  // Should be idle initially
  should.equal(state.state, "idle")
  should.equal(state.is_syncing, False)
}

pub fn sync_adapter_shows_syncing_test() {
  // Start a sync actor
  let assert Ok(sync) = oni_supervisor.start_sync()

  // Start syncing
  process.send(sync, oni_supervisor.StartSync("peer1"))

  // Start the adapter
  let assert Ok(adapter) = node_rpc.start_sync_adapter(sync)

  // Query state through adapter
  let state = process.call(adapter, QuerySyncState, 5000)

  // Should show syncing
  should.equal(state.state, "syncing_headers")
  should.equal(state.is_syncing, True)
}

// ============================================================================
// Combined Handles Tests
// ============================================================================

pub fn create_rpc_handles_test() {
  // Start all actors
  let assert Ok(chainstate) = oni_supervisor.start_chainstate(oni_bitcoin.Regtest)
  let assert Ok(mempool) = oni_supervisor.start_mempool(1000)
  let assert Ok(sync) = oni_supervisor.start_sync()

  let node_handles = oni_supervisor.NodeHandles(
    chainstate: chainstate,
    mempool: mempool,
    sync: sync,
  )

  // Create RPC handles
  let result = node_rpc.create_rpc_handles(node_handles)
  should.be_ok(result)
}

pub fn start_node_with_rpc_test() {
  // Start node with RPC handles
  let result = node_rpc.start_node_with_rpc(oni_bitcoin.Regtest, 10_000)

  case result {
    Ok(#(node_handles, rpc_handles)) -> {
      // Verify node handles work
      let height = process.call(node_handles.chainstate, oni_supervisor.GetHeight, 5000)
      should.equal(height, 0)

      // Verify RPC handles work
      let rpc_height = process.call(rpc_handles.chainstate, QueryHeight, 5000)
      should.equal(rpc_height, 0)
    }
    Error(_msg) -> {
      // Fail with message
      should.fail()
    }
  }
}

// ============================================================================
// Network-specific Tests
// ============================================================================

pub fn mainnet_genesis_tip_test() {
  let assert Ok(chainstate) = oni_supervisor.start_chainstate(oni_bitcoin.Mainnet)
  let assert Ok(adapter) = node_rpc.start_chainstate_adapter(chainstate)

  let tip = process.call(adapter, QueryTip, 5000)

  case tip {
    Some(hash) -> {
      let hex = oni_bitcoin.block_hash_to_hex(hash)
      // Mainnet genesis hash
      should.equal(hex, "000000000019d6689c085ae165831e934ff763ae46a2a6c172b3f1b60a8ce26f")
    }
    None -> should.fail()
  }
}

pub fn testnet_genesis_tip_test() {
  let assert Ok(chainstate) = oni_supervisor.start_chainstate(oni_bitcoin.Testnet)
  let assert Ok(adapter) = node_rpc.start_chainstate_adapter(chainstate)

  let tip = process.call(adapter, QueryTip, 5000)

  case tip {
    Some(hash) -> {
      let hex = oni_bitcoin.block_hash_to_hex(hash)
      // Testnet genesis hash
      should.equal(hex, "000000000933ea01ad0ee984209779baaec3ced90fa3f408719526f8d77f4943")
    }
    None -> should.fail()
  }
}

// ============================================================================
// Actor Lifecycle Tests
// ============================================================================

pub fn adapters_handle_multiple_queries_test() {
  let assert Ok(chainstate) = oni_supervisor.start_chainstate(oni_bitcoin.Regtest)
  let assert Ok(adapter) = node_rpc.start_chainstate_adapter(chainstate)

  // Multiple queries should all work
  let h1 = process.call(adapter, QueryHeight, 5000)
  let h2 = process.call(adapter, QueryHeight, 5000)
  let h3 = process.call(adapter, QueryHeight, 5000)

  should.equal(h1, h2)
  should.equal(h2, h3)
  should.equal(h1, 0)
}

pub fn multiple_adapters_same_actor_test() {
  let assert Ok(chainstate) = oni_supervisor.start_chainstate(oni_bitcoin.Regtest)

  // Create multiple adapters for the same chainstate
  let assert Ok(adapter1) = node_rpc.start_chainstate_adapter(chainstate)
  let assert Ok(adapter2) = node_rpc.start_chainstate_adapter(chainstate)

  // Both should return same data
  let h1 = process.call(adapter1, QueryHeight, 5000)
  let h2 = process.call(adapter2, QueryHeight, 5000)

  should.equal(h1, h2)
}
