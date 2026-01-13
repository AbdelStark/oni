# CLAUDE.md — oni AI development instructions

This file is intended for AI coding assistants (Claude, ChatGPT, etc.) contributing to **oni**.

## 0. Prime Directive

**Consensus correctness is sacred.**

Bitcoin Core is the reference implementation. Do not "guess" consensus behavior.

If you are unsure:
1. Stop
2. Locate the upstream rule/test vector
3. Implement with tests and differential validation

---

## 1. Project Overview

**oni** is a production-grade Bitcoin full node implementation written in **Gleam** (targeting Erlang/OTP).

### Current Status
- **Stage**: Milestones 0-5 complete. Milestone 6 near completion.
- **Tests**: 915+ unit tests, 52 E2E regtest tests passing
- **IBD**: Batch processing and parallel block downloads implemented
- **See**: [STATUS.md](/STATUS.md) for detailed implementation status

### Key Remaining Work
1. Live mainnet IBD testing
2. Memory-bounded operation validation
3. Production deployment testing

---

## 2. How to Work in This Repo

### 2.1 Read These First
1. `PRD.md` — Product requirements
2. `docs/ARCHITECTURE.md` — System design
3. `docs/CONSENSUS.md` — Consensus rules
4. `plan/ROADMAP.md` — Progress and milestones

### 2.2 Check Current State
1. `STATUS.md` — Implementation matrix
2. `ai/backlog/backlog.yml` — Task tracking
3. `CHANGELOG.md` — Recent changes

### 2.3 Local Commands

From repo root:

```sh
make fmt        # Format all code
make check      # Type check all packages
make test       # Run all tests
make ci         # Full CI pipeline
make build      # Build all packages
```

### 2.4 Node Operations

```sh
make run          # Run mainnet node
make run-testnet4 # Run testnet4 (BIP-94) node
make run-regtest  # Run regtest node

# Monitoring
make watch-ibd    # Watch IBD progress live
make node-status  # Check node status via RPC
make node-logs    # View recent logs
```

### 2.5 Package Layout

```
packages/
├── oni_bitcoin    # Primitives + serialization (COMPLETE)
├── oni_consensus  # Script + validation (COMPLETE)
├── oni_storage    # DB + chainstate (COMPLETE)
├── oni_p2p        # Networking (COMPLETE)
├── oni_rpc        # RPC server (COMPLETE)
└── oni_node       # OTP application (COMPLETE)
```

---

## 3. Coding Rules

### 3.1 Error Handling
- Parsing and network boundaries must never crash on malformed bytes
- Use `Result` for failure paths
- Do not throw exceptions for expected failures

```gleam
// Good: Return Result for fallible operations
pub fn parse_transaction(bytes: BitArray) -> Result(Transaction, ParseError)

// Bad: May crash on invalid input
pub fn parse_transaction(bytes: BitArray) -> Transaction
```

### 3.2 Bounded Resources
- All decoding must enforce size limits before allocation
- All queues must be bounded
- Never accept unbounded lists from the network without caps

### 3.3 Determinism
- Consensus code must be deterministic across runs
- Avoid relying on map/dict iteration order for consensus-relevant behavior

### 3.4 Consensus vs Policy Separation
- `oni_consensus` must not import policy or P2P modules
- Policy lives in mempool and relay code, not in block validation

---

## 4. Definition of Done

Your change is not done until:

- [ ] Unit tests exist and pass
- [ ] Docs updated (module purpose/invariants)
- [ ] Telemetry added where relevant
- [ ] No new dependencies without justification
- [ ] Consensus-critical changes include vectors or differential tests
- [ ] Code formatted (`make fmt`)
- [ ] Type check passes (`make check`)

---

## 5. How to Propose a Change

### Small Changes
1. Implement directly
2. Add tests
3. Update docs if needed

### Medium/Large Changes
1. Check if task exists in `ai/backlog/backlog.yml`
2. Write a short design note in `docs/adr/` if architectural
3. Add a task entry in `ai/backlog/backlog.yml`
4. Implement behind feature flags if risky
5. Add tests and benchmarks

---

## 6. Common Pitfalls

| Pitfall | Description |
|---------|-------------|
| Endianness | Bitcoin uses little-endian in many encodings |
| CompactSize boundaries | 0xFC/0xFD/0xFE/0xFF edge cases |
| Script numeric encoding | Minimal encoding rules |
| Sighash serialization | Preimage construction is tricky |
| Unbounded allocations | Always cap input sizes |

---

## 7. Testing Requirements

### Unit Tests
Required for all new functionality.

### Consensus Tests
Required for consensus-critical code:
- Test vectors (valid + invalid)
- Fuzz target update
- Differential tests vs Bitcoin Core where feasible

### Integration Tests
Required for cross-module changes.

---

## 8. If You Need Native Code (NIF)

- Prefer existing audited libraries where possible
- Keep NIF surface minimal and well-tested
- Add fuzzing to the boundary
- Document build steps under `docs/native/`
- Ensure NIF doesn't block BEAM schedulers

---

## 9. Quick Reference

| Resource | Location |
|----------|----------|
| Implementation status | `STATUS.md` |
| Task backlog | `ai/backlog/backlog.yml` |
| Roadmap | `plan/ROADMAP.md` |
| Architecture | `docs/ARCHITECTURE.md` |
| Consensus rules | `docs/CONSENSUS.md` |
| Agent roles | `ai/AGENTS.md` |
| Skills/playbooks | `ai/skills/` |
| Test vectors | `test_vectors/` |
| RPC debug script | `scripts/btc_rpc.py` |
| RPC skill docs | `skills/bitcoin-rpc.md` |

---

## 10. Key Invariants

1. **Parsing is total** — Never crash on malformed input
2. **Consensus is deterministic** — Same inputs = same outputs
3. **Resources are bounded** — No unbounded allocations
4. **Policy stays out of consensus** — Clean separation
5. **Tests prove correctness** — No consensus change without tests
