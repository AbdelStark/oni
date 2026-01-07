# AGENTS.md — AI agent roles and workflow

oni is designed for multi-agent development. This file describes recommended agent roles, their responsibilities, and how they coordinate.

## 1. Project Status

**Current Stage**: Milestones 0-5 complete. Node runs, responds to RPC, and passes 52 E2E regtest tests.

Key remaining work:
- Mainnet sync capability (Milestone 6)
- Persistent block storage backend
- Production hardening

See [STATUS.md](/STATUS.md) for detailed implementation status.

---

## 2. Agent Roles

### 2.1 Consensus Agent
**Scope:**
- `packages/oni_consensus`
- `docs/CONSENSUS.md`

**Responsibilities:**
- Script interpreter and opcode implementation
- Sighash computation (legacy, BIP143, BIP341)
- Validation rules (stateless and contextual)
- Consensus test vectors and differential harness
- Soft fork activation logic

**Never touches:**
- Mempool policy logic (except shared primitives)
- P2P relay decisions

**Current Status:** Complete. Script engine, sighash (all types), and secp256k1 NIF done.

### 2.2 Primitives Agent
**Scope:**
- `packages/oni_bitcoin`

**Responsibilities:**
- Serialization (transactions, blocks, messages)
- Hash functions (SHA256d, RIPEMD160, HASH160)
- Encoding (Base58Check, Bech32/Bech32m, hex)
- Core types (Hash256, Txid, Amount, Script)
- Network parameters

**Current Status:** Complete.

### 2.3 Storage Agent
**Scope:**
- `packages/oni_storage`
- `docs/STORAGE.md`

**Responsibilities:**
- DB abstraction layer
- UTXO set storage and caching
- Block index and chainstate
- Connect/disconnect block operations
- Crash recovery and migrations
- Reorg correctness

**Current Status:** Complete. In-memory and DETS persistent backends implemented.

### 2.4 P2P Agent
**Scope:**
- `packages/oni_p2p`
- `docs/P2P.md`

**Responsibilities:**
- Message framing and codecs
- Peer lifecycle and address management
- Relay scheduling and DoS defenses
- Header and block synchronization
- Compact blocks (BIP152)
- Erlay (BIP330)
- V2 transport (BIP324)
- P2P fuzzing targets

**Current Status:** Protocol layer complete.

### 2.5 RPC/CLI Agent
**Scope:**
- `packages/oni_rpc`
- `packages/oni_node`

**Responsibilities:**
- JSON-RPC 2.0 server
- Authentication and rate limiting
- CLI tooling
- Operator UX
- Health endpoints

**Current Status:** Complete.

### 2.6 Ops/Telemetry Agent
**Scope:**
- `docs/TELEMETRY.md`
- CI workflows
- Deployment scripts
- `monitoring/`

**Responsibilities:**
- Structured logging
- Prometheus metrics
- Grafana dashboards
- Alert definitions
- Release pipeline
- Docker and systemd configuration

**Current Status:** Complete.

### 2.7 Security Agent
**Scope:**
- `docs/SECURITY.md`
- Fuzz harnesses
- Dependency policy

**Responsibilities:**
- Threat model maintenance
- Fuzzing strategy and coverage
- Secure coding checklists
- Supply chain controls
- Security review coordination

**Current Status:** Framework in place, needs expansion.

---

## 3. Coordination Rules

### Before Starting Work
1. Check `ai/backlog/backlog.yml` for existing tasks
2. Review [STATUS.md](/STATUS.md) for current implementation state
3. Verify dependencies are complete

### For Each Change
Declare:
- Impacted subsystem(s)
- Consensus impact (yes/no)
- Test additions
- Documentation updates

### Cross-Subsystem Changes
Require a short ADR (Architecture Decision Record) in `docs/adr/`.

---

## 4. Task Format

Add tasks to `ai/backlog/backlog.yml`:

```yaml
- id: XN
  title: "Short summary"
  subsystem: consensus|bitcoin|storage|p2p|rpc|node|ops|security
  status: pending|in_progress|done
  depends_on: [other_ids]
  description: >
    What to do
  acceptance:
    - "Criteria 1"
    - "Criteria 2"
  tests:
    - "unit"
    - "integration"
    - "fuzz"
    - "diff"
    - "bench"
```

---

## 5. Review Strategy

| Change Type | Required Review |
|-------------|-----------------|
| Consensus changes | Explicit consensus-owner review |
| Storage changes | Crash recovery tests |
| P2P changes | Fuzz target update or justification |
| Security-sensitive | Security agent review |
| Cross-subsystem | ADR required |

---

## 6. Communication Guidelines

### Within Agents
- Document decisions in code comments
- Update relevant docs when behavior changes
- Add test cases for edge cases discovered

### Between Agents
- Use ADRs for architectural decisions
- Reference task IDs in commits
- Keep backlog.yml current

---

## 7. Skills Available

See `ai/skills/` for detailed playbooks:
- `skill_serialization.md` — Encoding/decoding patterns
- `skill_crypto.md` — Cryptographic operations
- `skill_script_interpreter.md` — Script engine work
- `skill_p2p_codec.md` — P2P message handling
- `skill_storage_chainstate.md` — Storage patterns
- `skill_telemetry.md` — Observability
- `skill_fuzzing.md` — Fuzz testing
- `skill_benchmarks.md` — Performance testing
- `skill_security_review.md` — Security audits
- `skill_btc_rpc_debug.md` — Bitcoin RPC debugging for sync validation

## 8. Debugging Tools

### Bitcoin RPC Queries

Use `scripts/btc_rpc.py` to query public Bitcoin RPC endpoints for debugging sync issues:

```bash
# Check current chain height
uv run scripts/btc_rpc.py height --network testnet4

# Compare local node with public chain
uv run scripts/btc_rpc.py compare --network testnet4

# Verify genesis block
uv run scripts/btc_rpc.py genesis --network testnet4
```

See `skills/bitcoin-rpc.md` for full documentation.
