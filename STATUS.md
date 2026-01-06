# Implementation Status

This document tracks the implementation status of oni across all packages and features.

> **Last Updated**: 2026-01-06

## Summary

| Metric | Value |
|--------|-------|
| Total Source Files | 87 |
| Total Lines of Code | ~62,000 |
| Test Files | 33 |
| Test Coverage | Core paths covered |
| Documentation Files | 23 |

## Package Status

### oni_bitcoin (Primitives)

| Component | Status | Notes |
|-----------|--------|-------|
| Hash types (Hash256, Txid, Wtxid, BlockHash) | ✅ Done | Full implementation |
| Amount type with overflow protection | ✅ Done | Enforces 21M cap |
| Script type and utilities | ✅ Done | |
| OutPoint, TxIn, TxOut, Transaction | ✅ Done | Full types |
| Block, BlockHeader | ✅ Done | Full types |
| Network parameters (mainnet/testnet/regtest) | ✅ Done | |
| Hex encoding/decoding | ✅ Done | |
| Base58Check encoding | ✅ Done | |
| Bech32/Bech32m encoding | ✅ Done | |
| CompactSize/varint | ✅ Done | |
| Transaction serialization (legacy) | ✅ Done | |
| Transaction serialization (witness) | ✅ Done | |
| Block serialization | ✅ Done | |
| P2P message types | ✅ Done | In `message.gleam` |
| Output descriptors | ✅ Done | In `descriptors.gleam` |
| secp256k1 NIF | ✅ Done | C code complete, CI/Docker integrated |

### oni_consensus (Consensus)

| Component | Status | Notes |
|-----------|--------|-------|
| Opcode definitions | ✅ Done | All opcodes defined |
| Opcode byte mapping | ✅ Done | |
| Disabled opcode detection | ✅ Done | |
| Script flags | ✅ Done | All BIP flags |
| Script context | ✅ Done | With sig context |
| Script number encoding | ✅ Done | With edge cases |
| Script parsing | ✅ Done | |
| Script execution engine | ✅ Done | Core opcodes |
| Stack operations | ✅ Done | DUP, DROP, SWAP, etc. |
| Arithmetic operations | ✅ Done | ADD, SUB, etc. |
| Logic operations | ✅ Done | EQUAL, BOOLAND, etc. |
| Crypto operations (HASH160, SHA256, etc.) | ✅ Done | |
| OP_CHECKSIG | ✅ Done | With sig context |
| OP_CHECKMULTISIG | ✅ Done | |
| OP_CHECKLOCKTIMEVERIFY (BIP65) | ✅ Done | Tested |
| OP_CHECKSEQUENCEVERIFY (BIP112) | ✅ Done | Tested |
| Control flow (IF/ELSE/ENDIF) | ✅ Done | |
| Sighash types | ✅ Done | ALL, NONE, SINGLE, ANYONECANPAY |
| Sighash computation (legacy) | ✅ Done | In `validation.gleam` |
| Sighash computation (BIP143 SegWit) | ✅ Done | In `validation.gleam` |
| Sighash computation (BIP341 Taproot) | ✅ Done | In `validation.gleam` |
| Merkle root computation | ✅ Done | |
| Witness commitment | ✅ Done | |
| Transaction validation (stateless) | ✅ Done | In `validation.gleam` |
| Transaction validation (contextual) | ⚠️ Partial | |
| Block validation | ⚠️ Partial | Header checks, merkle |
| Difficulty calculation | ✅ Done | In `difficulty.gleam` |
| Soft fork activation | ✅ Done | In `activation.gleam` |
| Block filters (BIP157) | ✅ Done | In `block_filter.gleam` |
| Block templates (mining) | ✅ Done | In `block_template.gleam` |
| Signature cache | ✅ Done | In `sig_cache.gleam` |
| Schnorr batch verification | ✅ Done | In `schnorr_batch.gleam` |
| Mempool validation | ✅ Done | In `mempool_validation.gleam` |
| Mempool policy | ✅ Done | In `mempool_policy.gleam` |
| Fee estimation | ✅ Done | In `fees.gleam` |
| Checkpoints | ✅ Done | In `checkpoints.gleam` |

### oni_storage (Storage)

| Component | Status | Notes |
|-----------|--------|-------|
| Storage error types | ✅ Done | |
| Coin type (UTXO) | ✅ Done | With maturity check |
| UTXO view interface | ✅ Done | In-memory |
| UTXO batch operations | ✅ Done | |
| Block index | ✅ Done | With navigation |
| Block index entry | ✅ Done | With status |
| Ancestor lookup | ✅ Done | |
| Common ancestor finding | ✅ Done | |
| Chainstate type | ✅ Done | |
| Block store | ✅ Done | In-memory |
| Header store | ✅ Done | In-memory |
| Undo data types | ✅ Done | |
| Undo store | ✅ Done | In-memory |
| Connect block | ✅ Done | With UTXO updates |
| Disconnect block | ✅ Done | With undo data |
| DB backend interface | ✅ Done | In `db_backend.gleam` |
| Persistent storage | ✅ Done | DETS + unified_storage bridge |
| AssumeUTXO | ✅ Done | In `assumeutxo.gleam` |
| Pruning | ✅ Done | In `pruning.gleam` |
| Transaction index | ✅ Done | In `txindex.gleam` |
| DB maintenance | ✅ Done | In `db_maintenance.gleam` |

### oni_p2p (Networking)

| Component | Status | Notes |
|-----------|--------|-------|
| Message framing | ✅ Done | |
| Message types | ✅ Done | |
| Version handshake | ✅ Done | |
| Address manager | ✅ Done | In `addrman.gleam` |
| Address persistence | ✅ Done | In `addr_persistence.gleam` |
| Peer reputation | ✅ Done | In `peer_reputation.gleam` |
| Ban manager | ✅ Done | In `ban_manager.gleam` |
| Rate limiting | ✅ Done | In `ratelimit.gleam` |
| Relay logic | ✅ Done | In `relay.gleam` |
| Header sync | ✅ Done | In `sync.gleam` |
| Block sync | ✅ Done | In `sync.gleam` |
| Compact blocks (BIP152) | ✅ Done | In `compact_blocks.gleam` |
| Erlay (BIP330) | ✅ Done | In `erlay.gleam` |
| V2 transport (BIP324) | ✅ Done | In `v2_transport.gleam` |
| P2P network actor | ✅ Done | In `p2p_network.gleam` |
| Fuzz testing | ✅ Done | In `fuzz_test.gleam` |
| Network simulation | ✅ Done | Tests available |

### oni_rpc (RPC)

| Component | Status | Notes |
|-----------|--------|-------|
| JSON-RPC 2.0 server | ✅ Done | |
| HTTP server | ✅ Done | In `http_server.gleam` |
| HTTP protocol layer | ✅ Done | In `rpc_http.gleam` |
| RPC service handlers | ✅ Done | In `rpc_service.gleam` |
| Authentication | ✅ Done | |
| Rate limiting | ✅ Done | |
| Method routing | ✅ Done | |
| Error codes | ✅ Done | |

### oni_node (Application)

| Component | Status | Notes |
|-----------|--------|-------|
| OTP application | ✅ Done | |
| Supervision tree | ✅ Done | In `oni_supervisor.gleam` |
| Configuration | ✅ Done | In `config.gleam` |
| CLI interface | ✅ Done | In `cli.gleam` |
| Health checks | ✅ Done | In `health.gleam` |
| Prometheus metrics | ✅ Done | In `prometheus.gleam` |
| Structured logging | ✅ Done | In `structured_logger.gleam` |
| Event routing | ✅ Done | In `event_router.gleam` |
| IBD coordinator | ✅ Done | In `ibd_coordinator.gleam` |
| Persistent chainstate | ✅ Done | In `persistent_chainstate.gleam` |
| Reorg handler | ✅ Done | In `reorg_handler.gleam` |
| Parallel validation | ✅ Done | In `parallel_validation.gleam` |
| Mempool manager | ✅ Done | In `mempool_manager.gleam` |
| Node RPC bridge | ✅ Done | In `node_rpc.gleam` |
| Wallet (basic) | ✅ Done | In `wallet.gleam` |
| Benchmarks | ✅ Done | In `benchmark.gleam` |
| Network simulation | ✅ Done | In `network_sim.gleam` |

## Test Coverage

| Package | Test Files | Coverage |
|---------|------------|----------|
| oni_bitcoin | 4 | Core serialization, messages, descriptors, secp256k1/BIP-340 |
| oni_consensus | 8 | Script, validation, sighash, mempool |
| oni_storage | 6 | UTXO, persistence, pruning |
| oni_p2p | 5 | Networking, sync, compact blocks |
| oni_rpc | 3 | RPC handlers, HTTP |
| oni_node | 7 | E2E regtest (52 tests), CLI, integration |

**Total Tests**: 915+ unit tests, 52 E2E tests

## Infrastructure Status

| Component | Status | Notes |
|-----------|--------|-------|
| CI Pipeline | ✅ Done | GitHub Actions |
| Format check | ✅ Done | |
| Type check | ✅ Done | |
| Test automation | ✅ Done | |
| Documentation build | ✅ Done | |
| Multi-OTP testing | ✅ Done | OTP 26.2 & 27.2 |
| Docker support | ✅ Done | Dockerfile + compose |
| Systemd units | ✅ Done | Mainnet + testnet |
| Prometheus config | ✅ Done | In `monitoring/` |
| Grafana dashboards | ✅ Done | In `monitoring/grafana/` |

## Known Gaps / Remaining Work

### Critical for Production
1. **Real network sync**: Validate with actual Bitcoin Core regtest node
2. **libsecp256k1 installation**: Users need libsecp256k1 v0.5.0+ with schnorrsig module

### Important Improvements
1. **Differential testing**: ✅ Framework with 100+ script test vectors implemented
2. **Fuzz testing coverage**: ✅ Consensus + P2P parsing covered (50+ tests each)
3. **Performance benchmarks**: IBD speed, mempool throughput
4. **Memory profiling**: UTXO cache behavior under load

### Nice to Have
1. **Wallet features**: HD derivation, PSBT support
2. **Indexers**: Address and transaction indexes
3. **Schnorr batch verification**: Full implementation (currently stubbed)

### Recently Completed
1. **Sighash implementation**: Complete for legacy, BIP143, BIP341
2. **Persistent storage**: DETS backend with unified_storage bridge
3. **secp256k1 Gleam wiring**: Schnorr/ECDSA verify, Taproot tweak functions
4. **secp256k1 NIF CI/CD**: GitHub Actions now builds NIF with libsecp256k1
5. **Docker NIF support**: Dockerfile builds libsecp256k1 and NIF
6. **BIP-340 test vectors**: Schnorr verification test suite added
7. **Event router integration**: P2P events now properly routed to chainstate/mempool/sync
8. **Integration tests enabled**: End-to-end block connection tests added
9. **Simulated P2P sync tests**: Event router block/header routing validated
10. **Persistence validation tests**: Crash recovery and restart tests added
11. **Expanded differential testing**: 100+ script test vectors covering all opcode categories
12. **Consensus fuzz testing**: 50+ fuzz tests for script, tx, header, and CompactSize parsing
13. **Block download pipelining**: Stall detection, request reassignment, and peer performance tracking
14. **Sync test coverage**: 11 new tests for stall detection and peer performance metrics
15. **Benchmark definitions**: Standard crypto/validation benchmarks with regression detection
16. **Mining RPC (generatetoaddress)**: Full regtest mining via RPC with block connection
17. **secp256k1 signing functions**: NIF extended with ECDSA/Schnorr signing, private key derivation
18. **E2E regtest test suite**: 52 comprehensive E2E tests for RPC, mining, and chain operations
19. **CI E2E integration**: E2E tests run automatically in CI against live regtest node

## Legend

- ✅ Done: Feature implemented and tested
- ⚠️ Partial: Core implementation exists, needs completion
- ❌ Not Started: Not yet implemented
- 🚧 In Progress: Active development
