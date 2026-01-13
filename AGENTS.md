# AGENTS.md

Agent roles and coordination for multi-agent development on oni.

## Agent Roles

<agents>
| Agent | Scope | Status |
|-------|-------|--------|
| **Consensus** | `oni_consensus`, script engine, sighash, validation | Complete |
| **Primitives** | `oni_bitcoin`, serialization, encoding, types | Complete |
| **Storage** | `oni_storage`, UTXO set, chainstate, persistence | Complete |
| **P2P** | `oni_p2p`, networking, sync, relay | Complete |
| **RPC/Node** | `oni_rpc`, `oni_node`, CLI, OTP app | Complete |
| **Ops** | Telemetry, CI/CD, deployment, monitoring | Complete |
| **Security** | Fuzzing, threat model, audits | Framework ready |
</agents>

## Boundaries

<boundaries>
**Consensus agent** owns:
- Script interpreter and opcodes
- Sighash computation (legacy, BIP143, BIP341)
- Block/transaction validation rules
- **Never touches**: mempool policy, P2P relay decisions

**Storage agent** owns:
- UTXO set operations
- Block index and chainstate
- Connect/disconnect block
- Crash recovery

**P2P agent** owns:
- Message framing and codecs
- Peer management and sync
- DoS defenses
- **Consensus rules flow through**: validation module only
</boundaries>

## Coordination

<coordination>
**Before work:**
1. Check `.harness/backlog.yml` for existing tasks
2. Read `.harness/STATUS.md` for current state
3. Verify dependencies are complete

**For each change, declare:**
- Impacted subsystem(s)
- Consensus impact (yes/no)
- Test additions
- Documentation updates

**Cross-subsystem changes:**
Require ADR in `docs/adr/`
</coordination>

## Review Requirements

<review>
| Change Type | Requirement |
|-------------|-------------|
| Consensus | Explicit review, test vectors |
| Storage | Crash recovery tests |
| P2P | Fuzz target update |
| Security-sensitive | Security review |
| Cross-subsystem | ADR required |
</review>

## Debugging Tools

<debugging>
```sh
# Bitcoin RPC queries (sync validation)
uv run scripts/btc_rpc.py height --network testnet4
uv run scripts/btc_rpc.py compare --network testnet4

# Node monitoring
make watch-ibd       # IBD progress
make node-status     # RPC health check
make node-logs       # Recent logs

# Node management
make node-stop       # Stop node
make clear-testnet4  # Clear data
make fresh-testnet4  # Clear + restart
```
</debugging>

## Knowledge Base

Domain playbooks in `.harness/knowledge/`:

| Playbook | Topic |
|----------|-------|
| `serialization.md` | Encoding/decoding patterns |
| `crypto.md` | Cryptographic operations |
| `script.md` | Script engine patterns |
| `p2p.md` | P2P message handling |
| `storage.md` | Storage and chainstate |
| `fuzzing.md` | Fuzz testing patterns |
