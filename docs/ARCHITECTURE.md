# Architecture

This document describes the target architecture for **oni** as a production-grade Bitcoin node implemented in **Gleam** on **Erlang/OTP**.

> Design principle: **consensus correctness first**. Performance, UX, and feature breadth come second.  
> The architecture is optimized for *auditability*, *fault tolerance*, and *operational visibility*.

## 1. High-level component map

### 1.1 Packages (monorepo)

- `oni_bitcoin` — primitives + serialization + encoding + crypto façades
- `oni_consensus` — consensus rules, script engine, sighash, validation
- `oni_storage` — block store, chainstate DB, indexes, migrations
- `oni_p2p` — P2P protocol, peer lifecycle, relay, address manager
- `oni_rpc` — JSON-RPC server, auth, rate limiting, admin endpoints
- `oni_node` — the OTP application wiring everything into a running node

> The packages are designed so:
> - `oni_consensus` depends on `oni_bitcoin`
> - `oni_storage` depends on `oni_bitcoin` and **never** on `oni_p2p`
> - `oni_p2p` depends on `oni_bitcoin` for message types, but not on `oni_storage` directly
> - `oni_node` composes them

### 1.2 Runtime processes (OTP actors)

Core runtime actors (supervised):

- **Config**: loads validated config; makes it immutable (or read-only)
- **Telemetry**: central metrics & tracing integration
- **DNS Seeder / AddrMan**: address discovery + persistence
- **Peer Supervisor**: dynamic supervisor for per-peer connection processes
- **Peer Manager**: policies for inbound/outbound peers, bans, discouragement
- **Net Processor**: parses/encodes P2P frames; routes to handlers
- **Header Sync**: maintains header chain, triggers IBD
- **Block Download / IBD Coordinator**: fetches blocks, schedules validation
- **Validation Worker Pool**: parallel script/sig checks with bounded concurrency
- **Chainstate**: authoritative state machine for active chain + UTXO transitions
- **Mempool**: policy-validation and tx admission/eviction/relay
- **RPC Server**: authenticated JSON-RPC endpoints

Optional actors:
- **Indexer** (txindex/addrindex)
- **Wallet** (key store, signer, coin selector)

## 2. Supervision tree

A production node should be an OTP application with a clear supervision tree.

Example (conceptual):

```text
oni_app
└─ oni_root_sup (one_for_one)
   ├─ oni_config_srv
   ├─ oni_telemetry_srv
   ├─ oni_storage_sup
   │  ├─ oni_db_mgr
   │  ├─ oni_blockstore_srv
   │  └─ oni_chainstate_srv
   ├─ oni_validation_sup
   │  ├─ oni_script_cache
   │  └─ oni_validation_pool (N workers)
   ├─ oni_mempool_srv
   ├─ oni_p2p_sup
   │  ├─ oni_addrman_srv
   │  ├─ oni_peer_mgr_srv
   │  └─ oni_peer_conn_sup (dynamic)
   │     └─ peer_X_conn (per peer)
   └─ oni_rpc_sup
      └─ oni_rpc_srv
```

### Restart strategies

- `oni_chainstate_srv`: restart *carefully*; on crash, run DB recovery and reindex checks.
- P2P peer connection processes: restart or replace freely; state is non-authoritative.
- Validation pool workers: can crash/restart; correctness is ensured by Chainstate as the authority.

## 3. Data ownership & invariants

### 3.1 Authoritative state
- **Chainstate** owns:
  - Active chain tip
  - UTXO set view
  - Block index (or a handle to it)
  - Reorg execution
- Only Chainstate mutates consensus-critical state.

### 3.2 Derived state
- Mempool is **policy** state. It can be rebuilt from peers if needed.
- Peer manager state is derived; safe to reset.

### 3.3 Immutability boundaries
- Raw bytes are immutable after parsing.
- All consensus hashes are derived from exact canonical serialization.

## 4. Critical flows

### 4.1 Inbound block flow
1. P2P receives `block` message bytes.
2. Decode to `Block` (strict bounds).
3. `Header Sync` ensures header chain is known.
4. `IBD Coordinator` schedules block to validation pool.
5. Validation pool runs:
   - Structural checks (sizes, merkle root)
   - Context-free tx checks
   - Script verification (parallel)
6. Chainstate applies block:
   - Connect block to UTXO set
   - Update indexes
   - Commit DB transaction
7. Telemetry emits timings, sizes, cache hit rates.

### 4.2 Transaction admission flow
1. P2P receives `tx` bytes.
2. Decode to `Transaction`.
3. Mempool policy validation:
   - Standardness checks
   - Fee/rate checks
   - RBF rules
   - UTXO availability via Chainstate snapshot API
4. If accepted:
   - Insert into mempool indexes
   - Relay to peers (with inventory and fee filter)

### 4.3 Reorg flow
1. Chainstate learns of a better chain.
2. Disconnect blocks (reverse apply) to common ancestor.
3. Connect new blocks in order.
4. Update mempool: revalidate conflicted txs; resurrect where policy allows.

## 5. Performance strategy

- Parallelism:
  - Script verification is parallelizable per input with bounded worker pool.
  - Block download is pipelined: download → precheck → verify → connect.
- Caching:
  - Signature cache (keyed by (txid/wtxid, input index, sighash)).
  - Script execution cache (where safe).
  - UTXO cache and DB read batching.
- Avoid BEAM scheduler blocking:
  - Heavy crypto (secp256k1, SHA256, etc.) should run in native code or via built-in crypto primitives that are safe and do not block schedulers.
- Backpressure:
  - Bounded queues between P2P, validation, and chainstate.
  - Drop/ban peers exceeding resource budgets.

## 6. Determinism and correctness guardrails

- Separate **consensus** from **policy**.
- Do not “optimize” consensus checks without:
  - Test vectors
  - Cross-check runs against Bitcoin Core
  - Fuzzing and differential tests

## 7. Configuration principles

- Every config parameter:
  - Has a safe default
  - Is validated at startup
  - Is documented
- Config changes are reflected in telemetry (effective config snapshot).

## 8. Extensibility

Planned extension points:
- Indexers and query engines
- Wallet and signing backends
- Alternative storage engines via a stable storage trait/module boundary
- Network transport upgrades
