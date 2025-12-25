# Implementation plan

This plan is designed to guide a multi-contributor (and AI-assisted) effort toward a world-class Bitcoin implementation in Gleam.

> **Bitcoin Core is the reference** for consensus and network semantics.  
> Anything consensus-related must be validated using test vectors and differential testing against Bitcoin Core.

---

## 0. Guiding principles (non-negotiable)

1. **Correctness over cleverness**
   - No micro-optimizations before correctness is proven with tests and cross-checks.
2. **Determinism**
   - Consensus execution must be deterministic across runs and platforms.
3. **Bounded resources**
   - Every external input has strict bounds (sizes, counts, timeouts).
4. **Separation of concerns**
   - Consensus vs policy vs P2P must be split at module boundaries.
5. **Observability first**
   - Every major subsystem emits logs + metrics from day one.
6. **Reproducible builds**
   - Locked deps, documented toolchain, CI that matches releases.
7. **AI-friendly workflow**
   - Small, well-defined tasks with explicit acceptance criteria and tests.

---

## 1. Deliverables checklist

### Required (for mainnet-compatible full node)
- [ ] `oni_bitcoin`: canonical primitives + codecs + encodings + hash wrappers
- [ ] `oni_consensus`: script + sighash + block/tx validation + taproot/segwit
- [ ] `oni_storage`: block store + index + UTXO DB + undo + crash recovery
- [ ] `oni_p2p`: peer management + protocol + relay + IBD coordinator hooks
- [ ] `oni_rpc`: JSON-RPC server + auth + basic compatibility surface
- [ ] `oni_node`: OTP app + supervision tree + config + wiring
- [ ] End-to-end IBD to tip on mainnet in controlled environment
- [ ] Production telemetry: logs, metrics, tracing, health

### Optional (planned after baseline)
- [ ] Wallet and signer
- [ ] Indexers (txindex, addrindex)
- [ ] Compact blocks and advanced relay
- [ ] Snapshot/AssumeUTXO bootstrapping

---

## 2. Work organization and ownership

### Subsystem owners (conceptual)
- Consensus owner: script + sighash + validation
- P2P owner: message layer + peer lifecycle + DoS defense
- Storage owner: DB engine, crash recovery, migrations
- Ops owner: telemetry, deployment, CI, releases
- Security owner: threat model, fuzzing, dependency policy

See `ai/AGENTS.md` for agent roles and task routing.

---

## 3. Phases

Each phase is “done” only when:
- acceptance criteria pass,
- tests exist and run in CI,
- docs are updated,
- telemetry is in place for the new functionality.

### Phase 0 — Repository foundations

**Objective:** Set the project up for disciplined, scalable development.

Tasks:
1. Toolchain pinning
   - `.tool-versions` (Erlang/OTP + Gleam + optional Rust toolchain for NIFs)
   - Document supported OS targets and build prerequisites
2. Repo automation
   - `Makefile` (fmt, test, lint, ci, bench)
   - GitHub Actions CI workflow
3. AI agent system
   - `ai/CLAUDE.md`, `ai/AGENTS.md`
   - `ai/skills/*` playbooks
   - backlog/task templates
4. Security baseline
   - SBOM generation workflow
   - dependency review policy
   - vulnerability disclosure policy

Acceptance criteria:
- CI runs: format check + typecheck + unit tests (scaffolding).
- New contributor can run `make test` and get deterministic results.

---

### Phase 1 — Bitcoin primitives library (`oni_bitcoin`)

**Objective:** Provide a rock-solid, thoroughly tested base layer.

Scope:
- Core types:
  - hashes (Txid, BlockHash)
  - Script, Amount, OutPoint
  - network parameters (mainnet/testnet/regtest)
- Encoding/decoding:
  - consensus serialization for tx, block, header
  - CompactSize/varint, varstr
- Common encodings:
  - hex/base16
  - base58check
  - bech32 + bech32m

Key decisions:
- All parsing is **total**: returns `Result` and never crashes on malformed bytes.
- Prefer working with `BitArray`/binary slices to avoid copying.

Acceptance criteria:
- Roundtrip tests for all codecs.
- Known-good test vectors for:
  - varint edge cases
  - base58/bech32
  - tx and block serialization for curated corpus

---

### Phase 2 — Cryptography layer

**Objective:** Provide production-grade crypto primitives with a testable interface.

Scope:
- SHA256, sha256d, tagged hash
- RIPEMD160 (needed for HASH160)
- secp256k1:
  - ECDSA verify (legacy and segwit)
  - Schnorr verify (taproot)
  - pubkey parsing/validation

Architecture:
- Define `oni_bitcoin/crypto` with a stable interface.
- Provide at least two implementations:
  1. **Reference mode** (portable, simplest, used in tests/diff)
  2. **Accelerated mode** (native crypto for performance)

Implementation notes:
- If using native/NIF crypto:
  - treat as potentially unsafe; isolate; fuzz the boundary
  - ensure it does not block schedulers (dirty NIF or equivalent)
  - add crash-safety wrapper and fallbacks

Acceptance criteria:
- Crypto test vectors pass (BIP vectors where available).
- Differential tests between reference and accelerated mode.

---

### Phase 3 — Script engine (`oni_consensus`)

**Objective:** Implement Bitcoin script evaluation with exact semantics.

Scope:
- Script parsing/execution engine
- Script flags and activation-dependent behavior
- Signature checking integration (via crypto interface)
- SegWit v0 script evaluation and witness stack rules
- Taproot:
  - tapscript evaluation
  - schnorr checks
  - annex handling
  - control block and merkle path verification

Design:
- Pure functional core with explicit state:
  - stacks, altstack
  - opcode counter
  - script position
- Clear error taxonomy:
  - consensus failure reasons must be stable and testable
- Bound everything:
  - stack sizes, element sizes, op count, sigops count

Acceptance criteria:
- Script test vectors (valid/invalid) match Bitcoin Core behavior for covered cases.
- Fuzz target for script evaluation exists and runs in CI (smoke).

---

### Phase 4 — Block/transaction validation (stateless + contextual)

**Objective:** Implement consensus validation stages.

Scope:
- Tx validation:
  - stateless checks
  - contextual checks using UTXO view
  - sighash computation
- Block validation:
  - header PoW and difficulty checks
  - merkle root checks
  - witness commitment checks
  - weight limits
  - coinbase rules

Acceptance criteria:
- A curated corpus of blocks/txs validates identically to Bitcoin Core in differential harness.

---

### Phase 5 — Storage engine & chainstate (`oni_storage`)

**Objective:** Persistent, crash-safe chainstate and block store.

Scope:
- Choose DB engine (benchmark-driven).
- Implement:
  - block files or block DB
  - block index DB
  - UTXO DB with batching and caching
  - undo data and reorg support
  - migrations and schema versioning
- Provide `Chainstate` API:
  - `apply_block`
  - `disconnect_block`
  - `get_utxo(outpoint)`
  - `get_tip()`
  - snapshot/readonly views for mempool validation

Acceptance criteria:
- Crash recovery tests: power-loss simulation during connect.
- Reorg tests: disconnect/connect correctness.
- DB corruption detection with clear operator guidance.

---

### Phase 6 — P2P foundation (`oni_p2p`)

**Objective:** Interoperable networking with strong DoS defenses.

Scope:
- message framing and codec layer
- handshake (version/verack)
- peer lifecycle management (connect/disconnect, timeouts)
- basic inv/getdata for blocks and txs
- address manager persistence

Acceptance criteria:
- Can connect to peers on testnet/signet/regtest harness.
- Fuzz target for message decoding exists.
- Per-peer metrics and disconnect reasons implemented.

---

### Phase 7 — IBD coordinator and block relay

**Objective:** End-to-end sync to tip.

Scope:
- headers-first sync
- block download windows (bounded parallel)
- validation pipeline integration:
  - download → precheck → verify → connect
- handling forks and reorgs during sync

Acceptance criteria:
- Syncs a regtest chain quickly and deterministically.
- In a controlled environment, performs IBD to a known mainnet snapshot/tip.
- Emits detailed IBD telemetry (speed, ETA-free, progress by height).

---

### Phase 8 — Mempool + policy + tx relay

**Objective:** Functional transaction relay and policy.

Scope:
- mempool admission rules (policy)
- eviction and size limits
- orphan handling
- fee estimation baseline
- tx relay with inventory logic and filters

Acceptance criteria:
- Regtest scenarios:
  - accept valid txs, reject invalid/policy-failing txs
  - RBF basics
  - eviction under pressure
- Telemetry: mempool size, acceptance rates, rejection reasons.

---

### Phase 9 — RPC + CLI (`oni_rpc` + `oni_node`)

**Objective:** Operable node with standard controls.

Scope:
- JSON-RPC server:
  - auth
  - method routing
  - stable error codes
- CLI:
  - start/stop/status
  - raw decode tools
  - query helpers

Acceptance criteria:
- Operator can run node, query status, submit raw txs.
- Metrics and health endpoints integrated.

---

### Phase 10 — Hardening, performance, and production readiness

**Objective:** Make it truly production-grade.

Scope:
- Extensive fuzzing campaigns
- Long-run soak tests
- Network adversary simulation
- Performance tuning:
  - signature cache
  - DB batching
  - parallelism tuning
- Release engineering:
  - reproducible release pipeline
  - container images
  - upgrade process docs

Acceptance criteria:
- Soak test: multi-day run with stable memory and no crashes under load.
- Performance benchmarks tracked and gated.

---

## 4. Cross-cutting workstreams (always-on)

### 4.1 Telemetry
- Instrument every hot loop from the start.
- Maintain metric naming conventions and dashboards.

### 4.2 Security
- Every network boundary has fuzz coverage.
- Dependency review + SBOM in CI.
- Regular threat model updates.

### 4.3 Documentation
- Every module has a spec doc and invariants.
- ADRs (architecture decision records) for major decisions.

---

## 5. Definition of Done (DoD)

A task is “Done” only when:
- Tests added and passing.
- Benchmarks updated if performance-sensitive.
- Telemetry added (logs/metrics).
- Docs updated.
- Security review checklist completed (for network/consensus/storage changes).

See also `plan/QUALITY_GATES.md`.
