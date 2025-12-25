# Repository structure

This repo is intentionally structured to support:
- modular development (like rust-bitcoin crates),
- strict separation of consensus vs policy vs networking,
- AI-assisted development (small, well-scoped tasks).

## Top level

- `README.md` — overview
- `PRD.md` — product requirements
- `plan/` — implementation plan, milestones, risks, quality gates
- `docs/` — system architecture and subsystem specs
- `ai/` — agent instructions and skill playbooks
- `packages/` — Gleam packages (local path deps)
- `scripts/` — automation for tests, benchmarks, and ops
- `.github/` — CI workflows and templates

## Packages

### `packages/oni_bitcoin`
Foundational primitives and codecs:
- consensus serialization/deserialization
- hashes, encodings (base58, bech32/bech32m)
- script AST + opcode tables (not the interpreter)
- compact size / varint
- network magic constants and message envelopes

**Must be usable as a standalone library**.

### `packages/oni_consensus`
Consensus engine:
- script interpreter
- sighash algorithms
- block/tx validation logic (consensus rules)
- witness + taproot validation
- merkle checks, coinbase rules, etc.

No P2P code. No policy code.

### `packages/oni_storage`
Persistence:
- block store
- header/chain index
- UTXO DB + caching layer
- DB migrations, versioning, snapshots (optional)

### `packages/oni_p2p`
Networking:
- transport framing
- message parsing/encoding
- peer lifecycle + address manager
- inv/getdata/headers/block/tx handling
- relay policies and throttling hooks

### `packages/oni_rpc`
Operator interfaces:
- JSON-RPC server
- authentication + ACL
- rate limiting
- metrics endpoints (optional)

### `packages/oni_node`
OTP application:
- supervision tree
- config load
- wiring of subsystems
- lifecycle management
- build/release/deploy entrypoints

## Internal module organization pattern

Inside a package we use:

- `src/<pkg_name>.gleam` — public entrypoints and re-exports
- `src/<pkg_name>/internal/*` — internal modules (not part of stable API)
- `test/` — tests

This matches Gleam’s `internal_modules` guidance and keeps APIs stable.
