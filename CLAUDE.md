# CLAUDE.md

This project uses AI-assisted development guidelines.

## Quick Reference

| Resource | Location |
|----------|----------|
| Primary AI instructions | `ai/CLAUDE.md` |
| Agent roles | `ai/AGENTS.md` |
| Skill playbooks | `ai/skills/` |
| Implementation status | `STATUS.md` |
| Task backlog | `ai/backlog/backlog.yml` |
| RPC debug script | `scripts/btc_rpc.py` |

## Current Status

**Stage**: Milestones 0-5 complete. Node runs, responds to RPC, mines regtest blocks, and passes 52 E2E tests.

See `STATUS.md` for detailed implementation matrix.

---

For the full AI development instructions, see `ai/CLAUDE.md`.

The key instructions from that file are included below for convenience.

---

## Prime Directive

**Consensus correctness is sacred.**

Bitcoin Core is the reference implementation. Do not "guess" consensus behavior.

If you are unsure:
1. Stop
2. Locate the upstream rule/test vector
3. Implement with tests and differential validation

## Local Commands

```sh
make fmt        # Format all code
make check      # Type check all packages
make test       # Run all tests
make ci         # Full CI pipeline
```

## Package Layout

```
packages/
├── oni_bitcoin    # Primitives + serialization (COMPLETE)
├── oni_consensus  # Script + validation (COMPLETE)
├── oni_storage    # DB + chainstate (COMPLETE)
├── oni_p2p        # Networking (COMPLETE)
├── oni_rpc        # RPC server (COMPLETE)
└── oni_node       # OTP application (COMPLETE)
```

## Coding Rules

1. **Error Handling**: Use `Result` for failure paths. Never crash on malformed input.
2. **Bounded Resources**: Enforce size limits before allocation. Cap all queues.
3. **Determinism**: Consensus code must be deterministic across runs.
4. **Separation**: `oni_consensus` must not import policy or P2P modules.

## Definition of Done

- [ ] Unit tests exist and pass
- [ ] Docs updated
- [ ] Telemetry added where relevant
- [ ] Code formatted (`make fmt`)
- [ ] Type check passes (`make check`)
- [ ] Consensus changes include test vectors

## Key Invariants

1. **Parsing is total** — Never crash on malformed input
2. **Consensus is deterministic** — Same inputs = same outputs
3. **Resources are bounded** — No unbounded allocations
4. **Policy stays out of consensus** — Clean separation
5. **Tests prove correctness** — No consensus change without tests
