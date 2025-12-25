# PRD: oni — Production-grade Bitcoin implementation in Gleam

## 1. Summary

**oni** is a world-class, production-grade implementation of the Bitcoin protocol written in **Gleam**, targeting the **Erlang/OTP** runtime for fault tolerance, concurrency, and operational reliability.

The primary deliverable is a **fully validating, mainnet-compatible full node**:
- Maintains consensus-correct chainstate (headers, blocks, UTXO set)
- Participates in the Bitcoin P2P network for block/transaction relay
- Provides operator interfaces (CLI + JSON-RPC) comparable to Bitcoin Core
- Provides production-grade observability: metrics, tracing, structured logs, profiling hooks
- Prioritizes security, correctness, and robustness without compromise

Bitcoin Core is the reference for consensus semantics and network behavior. Rust-bitcoin is a design inspiration for modularity and ergonomics, but consensus correctness is anchored to Bitcoin Core and BIPs.

## 2. Vision

Build a Bitcoin implementation that is:
- **Correct**: consensus rules identical to Bitcoin Core for the same network parameters.
- **Reliable**: self-healing and resilient under adverse network and disk conditions.
- **Fast**: competitive IBD time and mempool throughput through parallelism and careful optimization.
- **Operable**: easy to deploy, monitor, debug, and upgrade.
- **Maintainable**: clean modular architecture, testability, and a strict quality bar.
- **AI-friendly**: designed to be efficiently built and reviewed with AI assistance.

## 3. Target users & personas

### Node operators
- Want a stable full node with low operational overhead.
- Need metrics/logs, health checks, and safe configuration.

### Developers / integrators
- Need a clean library surface for parsing, serialization, script/consensus logic.
- Want reliable test harnesses and clear module boundaries.

### Researchers / security auditors
- Need clear threat model, reproducible builds, and test vector provenance.

## 4. Scope

### In-scope: required for “full Bitcoin node”
1. **Consensus correctness**
   - Full validation: block headers, difficulty, PoW, script validation, UTXO updates, reorgs.
   - Support the modern mainnet ruleset (SegWit, Taproot).
   - Strict adherence to consensus serialization and script rules.

2. **P2P networking**
   - Standard network handshake and message set.
   - Inventory relay: tx and block announcements, request/response.
   - Peer management: outbound/inbound, bans, discouragement scoring, timeouts, resource limits.

3. **Chainstate & storage**
   - Persistent block storage and block index.
   - Persistent UTXO set (key-value store).
   - Reorg handling and crash-safe recovery.
   - Optional pruning mode (policy-driven).

4. **Mempool**
   - Policy validation (distinct from consensus).
   - Fee and eviction policy.
   - Relay logic integrated with P2P.

5. **RPC + CLI**
   - JSON-RPC server with a compatible subset of Bitcoin Core RPC.
   - CLI tooling for node operation and debugging.
   - Auth, access control, safe defaults.

6. **Observability and operations**
   - Structured logs with redaction.
   - Prometheus metrics and OpenTelemetry traces (or equivalent).
   - Health endpoints and readiness checks.
   - Profiling hooks, GC and scheduler visibility.

7. **Security hardening**
   - Threat model and mitigations.
   - Dependency and supply-chain controls.
   - Fuzzing + property tests for consensus-critical code.

### Optional (post-MVP, but planned)
- Wallet (HD keys, PSBT, signing, coin selection)
- Indexers (addrindex, txindex equivalents)
- Compact block relay optimizations
- P2P transport upgrades (as they become relevant)
- AssumeUTXO/snapshot bootstrapping

## 5. Out of scope (explicitly)
- Lightning node implementation.
- Mining pool / stratum server.
- Exchange-grade custody features (HSM orchestration, multi-party signing) as part of the core node.

## 6. Functional requirements

### 6.1 Chain validation
- Must validate from genesis to tip (IBD).
- Must accept/reject blocks exactly as Bitcoin Core would (same chain params).
- Must support reorgs safely and deterministically.
- Must maintain a canonical “active chain” view.

### 6.2 Transaction validation
- Must validate scripts for legacy, SegWit v0, and Taproot (v1) spends.
- Must implement all required sighash algorithms.
- Must enforce BIP68/112/113 rules.
- Must enforce consensus rules for coinbase, witness commitment, etc.

### 6.3 P2P behavior
- Must implement version handshake and required message framing.
- Must relay blocks and transactions according to policy.
- Must handle adversarial peers without crashing or exhausting resources.
- Must persist peer addresses and reconnect strategy.

### 6.4 Storage
- Must persist block data and indexes.
- Must persist UTXO set with crash safety.
- Must support database migrations and versioning.
- Must support pruning (optional mode) without breaking validation.

### 6.5 RPC/CLI
- Must expose safe operational endpoints (status, peers, chain tip, mempool stats).
- Must expose transaction submission and raw access APIs.
- Must provide authentication, per-method access control, and rate limiting.

## 7. Non-functional requirements

### 7.1 Performance
- IBD throughput competitive for the BEAM environment.
- Parallel signature verification and script checks where safe.
- Efficient storage reads/writes with caching.
- Avoid BEAM scheduler blocking with heavy cryptographic operations.

### 7.2 Reliability
- OTP supervision tree ensures crash isolation and recovery.
- Backpressure across subsystems (P2P → validation → storage) to avoid overload.
- Configurable resource caps: memory, disk, file descriptors, network bandwidth.

### 7.3 Security
- Harden against network-level DoS and state explosion.
- Strict input validation for all external bytes.
- Safe defaults: bind addresses, auth, minimum logging redaction rules.
- Clear vulnerability disclosure process.

### 7.4 Observability
- Metrics, logs, and traces are first-class deliverables, not afterthoughts.
- Every critical loop emits telemetry: P2P, IBD, validation, DB, mempool.

### 7.5 Developer experience
- Deterministic tests and cross-implementation test vectors.
- Clear module ownership and “AI agent” guidance.
- CI gates for formatting, type checking, tests, fuzzing smoke, and security scans.

## 8. Compatibility requirements

- **Mainnet compatibility** with Bitcoin Core semantics.
- Network parameters: mainnet + testnet + regtest (at minimum), signet optional.
- Peer protocol compatibility with modern nodes (version negotiation and feature flags).

## 9. Compliance & licensing

- Prefer permissive licensing compatible with Bitcoin ecosystem (MIT / Apache-2.0).
- Maintain an SBOM and dependency license inventory.
- Document crypto dependency provenance and build steps.

## 10. Success criteria

- Node performs IBD to current mainnet tip and stays synced.
- Successfully connects to and relays with diverse peer set.
- Validates blocks and transactions identically to Bitcoin Core (for covered cases).
- Operates stably under adversarial network simulation with bounded resources.
- Provides production-grade telemetry suitable for paging and capacity planning.

## 11. Open questions (tracked in plan)
- Which exact DB backend (LevelDB vs RocksDB vs LMDB) is the best fit for BEAM + portability?
- How to package cryptographic primitives for speed while preserving easy builds?
- Scope of RPC compatibility: “subset” vs full Bitcoin Core parity.
