# Roadmap

This roadmap tracks oni's progress toward becoming a production-grade Bitcoin full node.

> **Note**: This roadmap intentionally avoids time estimates. Progress is driven by correctness and quality gates.

---

## Current Focus

**Goal**: Achieve mainnet Initial Block Download (IBD) capability.

**Recent Milestone**: Milestone 5 (End-to-End Regtest Node) is now complete with full E2E test coverage.

---

## Milestone 0 — Project Foundations ✅

**Status: Complete**

- [x] Repository structure and monorepo layout
- [x] CI/CD pipeline (format, typecheck, test)
- [x] AI development documentation (CLAUDE.md, AGENTS.md)
- [x] Skills playbooks for common tasks
- [x] Security baseline documentation
- [x] Makefile automation

---

## Milestone 1 — oni_bitcoin (Primitives) ✅

**Status: Complete**

- [x] Hash types (Hash256, Txid, Wtxid, BlockHash)
- [x] Amount type with 21M cap enforcement
- [x] Transaction and block types
- [x] Network parameters (mainnet/testnet/regtest/signet)
- [x] Hex, Base58Check, Bech32/Bech32m encoding
- [x] CompactSize/varint codec
- [x] Consensus serialization (legacy and witness)
- [x] P2P message type definitions
- [x] Output descriptor parsing

---

## Milestone 2 — oni_consensus (Script + Validation) ✅

**Status: Complete**

- [x] Full opcode table and parser
- [x] Script execution engine
- [x] Stack, arithmetic, logic, and crypto operations
- [x] OP_CHECKSIG and OP_CHECKMULTISIG
- [x] OP_CHECKLOCKTIMEVERIFY (BIP65)
- [x] OP_CHECKSEQUENCEVERIFY (BIP112)
- [x] Control flow (IF/ELSE/ENDIF/NOTIF)
- [x] Sighash type definitions
- [x] Sighash computation (legacy, BIP143 SegWit, BIP341 Taproot)
- [x] Merkle root and witness commitment
- [x] Transaction stateless validation
- [x] Block filter support (BIP157)
- [x] Mempool validation and policy
- [x] secp256k1 NIF with ECDSA/Schnorr verification
- [x] Differential testing (100+ Bitcoin Core script vectors)
- [x] Consensus fuzz testing

---

## Milestone 3 — oni_storage (Chainstate) ✅

**Status: Complete**

- [x] UTXO view interface with batch operations
- [x] Coin type with maturity tracking
- [x] Block index with chain navigation
- [x] Ancestor and common ancestor lookup
- [x] Chainstate manager
- [x] Connect block with UTXO updates
- [x] Disconnect block with undo data
- [x] Block and header stores
- [x] DB backend interface abstraction
- [x] Persistent storage (DETS backend + unified_storage)
- [x] AssumeUTXO support structure
- [x] Pruning mode support
- [x] Transaction index
- [x] DB maintenance utilities

---

## Milestone 4 — oni_p2p (Networking) ✅

**Status: Complete (protocol layer)**

- [x] Message framing and serialization
- [x] Version handshake protocol
- [x] Address manager with persistence
- [x] Peer reputation scoring
- [x] Ban manager and resource limits
- [x] Rate limiting
- [x] Relay scheduling
- [x] Header sync state machine
- [x] Block download coordination
- [x] Compact blocks (BIP152)
- [x] Erlay (BIP330) transaction relay
- [x] V2 transport (BIP324)
- [x] Network simulation testing

---

## Milestone 5 — End-to-End Regtest Node ✅

**Status: Complete**

- [x] OTP application structure
- [x] Supervision tree
- [x] Configuration management
- [x] CLI interface
- [x] RPC server (JSON-RPC 2.0 with working HTTP)
- [x] Authentication and rate limiting
- [x] Prometheus metrics
- [x] Structured logging
- [x] Health endpoints
- [x] IBD coordinator structure
- [x] Parallel validation framework
- [x] Reorg handler
- [x] Event router integration
- [x] Block download pipelining with stall detection
- [x] Signature verification (secp256k1 NIF with ECDSA and Schnorr signing)
- [x] Node runs and responds to RPC calls
- [x] Mining RPC (generatetoaddress, generate)
- [x] Regtest block mining and validation
- [x] Full integration test suite (915+ unit tests)
- [x] E2E regtest test suite (52 tests)
- [x] CI E2E integration with live node testing

---

## Milestone 6 — End-to-End Mainnet Node

**Status: Not Started**

- [ ] Persistent storage backend
- [ ] IBD to mainnet tip
- [ ] Stable sync under load
- [ ] Reorg handling under adversarial conditions
- [ ] Memory-bounded operation
- [ ] Production deployment testing

---

## Milestone 7 — Hardening and Performance

**Status: Not Started**

- [ ] Comprehensive fuzzing campaigns
- [ ] Multi-day soak tests
- [ ] Network adversary simulation
- [ ] Signature cache optimization
- [ ] DB batching tuning
- [ ] Parallelism optimization
- [ ] Benchmark regression gates
- [ ] Reproducible release pipeline
- [ ] Container images
- [ ] Upgrade process documentation

---

## Milestone 8 — Optional Features

**Status: Planned**

- [ ] HD wallet support
- [ ] PSBT signing
- [ ] Transaction index API
- [ ] Address index API
- [ ] Compact block relay optimization
- [ ] AssumeUTXO snapshot bootstrapping

---

## Quality Gates

Every milestone completion requires:
1. All tests passing in CI
2. Documentation updated
3. Telemetry in place
4. Security review for sensitive code
5. No regressions in existing functionality

See [QUALITY_GATES.md](QUALITY_GATES.md) for detailed criteria.

---

## Legend

- ✅ Complete
- 🚧 In Progress
- Unmarked — Not Started
