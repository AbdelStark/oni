# CLAUDE.md

This project uses AI-assisted development guidelines located at:

- `ai/CLAUDE.md` (primary)
- `ai/AGENTS.md`
- `ai/skills/`

For convenience, `ai/CLAUDE.md` is duplicated below.

---

# CLAUDE.md — oni AI development instructions

This file is intended for AI coding assistants (Claude, ChatGPT, etc.) contributing to **oni**.

## 0. Prime directive

**Consensus correctness is sacred.**  
Bitcoin Core is the reference implementation. Do not “guess” consensus behavior.

If you are unsure:
- stop,
- locate the upstream rule/test vector,
- implement with tests and differential validation.

## 1. How to work in this repo

### 1.1 Read these first
- `PRD.md`
- `docs/ARCHITECTURE.md`
- `docs/CONSENSUS.md`
- `plan/IMPLEMENTATION_PLAN.md`

### 1.2 Local commands
From repo root:

```sh
make fmt
make check
make test
```

### 1.3 Where code lives
- `packages/oni_bitcoin` — primitives + codecs
- `packages/oni_consensus` — script + validation
- `packages/oni_storage` — DB and chainstate
- `packages/oni_p2p` — networking
- `packages/oni_rpc` — RPC server
- `packages/oni_node` — OTP application

## 2. Coding rules

### 2.1 Error handling
- Parsing and network boundaries must never crash on malformed bytes.
- Use `Result` for failure paths.
- Do not throw exceptions for expected failures.

### 2.2 Bounded resources
- All decoding must enforce size limits before allocation.
- All queues must be bounded.
- Never accept unbounded lists from the network without caps.

### 2.3 Determinism
- Consensus code must be deterministic across runs.
- Avoid relying on map/dict iteration order for consensus-relevant behavior.

### 2.4 Consensus vs policy separation
- `oni_consensus` must not import policy or P2P modules.
- Policy lives in mempool and relay code, not in block validation.

## 3. Definition of Done (for AI contributions)

Your change is not done until:
- unit tests exist and pass
- docs updated (module purpose/invariants)
- telemetry added where relevant
- no new dependencies without justification
- consensus-critical changes include vectors or differential tests

## 4. How to propose a change

For medium/large changes:
1. Write a short design note in `docs/adr/` (Architecture Decision Record).
2. Add a task entry in `ai/backlog/backlog.yml`.
3. Implement behind feature flags if risky.
4. Add tests and benchmarks.

## 5. Common pitfalls

- Endianness errors (Bitcoin uses little-endian in many encodings).
- CompactSize/varint boundary handling.
- Script numeric encoding rules and minimal encoding flags.
- Incorrect sighash serialization preimages.
- Unbounded allocations when parsing P2P messages.

## 6. If you need native code (NIF)

- Prefer existing audited libraries where possible.
- Keep NIF surface minimal and well-tested.
- Add fuzzing to the boundary.
- Document build steps under `docs/native/`.
