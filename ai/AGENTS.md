# AGENTS.md — AI agent roles and workflow

oni is designed for multi-agent development. This file describes recommended agent roles and how they coordinate.

## 1. Agent roles

### 1.1 Consensus Agent
Scope:
- `packages/oni_consensus`
- `docs/CONSENSUS.md`

Responsibilities:
- script interpreter
- sighash
- validation rules
- consensus test vectors + differential harness

Never touches:
- mempool policy logic (except to define shared primitives)

### 1.2 Primitives Agent
Scope:
- `packages/oni_bitcoin`

Responsibilities:
- serialization, hashes, base58/bech32, core types
- strict parsing and encoding correctness
- cross-platform determinism

### 1.3 Storage Agent
Scope:
- `packages/oni_storage`
- `docs/STORAGE.md`

Responsibilities:
- DB abstraction
- UTXO set storage + caching
- crash recovery + migrations
- reorg correctness

### 1.4 P2P Agent
Scope:
- `packages/oni_p2p`
- `docs/P2P.md`

Responsibilities:
- message framing/codecs
- peer lifecycle + addrman
- relay scheduling + DoS defenses
- P2P fuzzing targets

### 1.5 RPC/CLI Agent
Scope:
- `packages/oni_rpc`, `packages/oni_node`

Responsibilities:
- JSON-RPC server
- auth, rate limiting
- CLI tooling
- operator UX

### 1.6 Ops/Telemetry Agent
Scope:
- `docs/TELEMETRY.md`, CI workflows, deployment scripts

Responsibilities:
- structured logging
- metrics and tracing
- dashboards and alerts
- release pipeline and SBOM

### 1.7 Security Agent
Scope:
- `docs/SECURITY.md`, fuzz harnesses, dependency policy

Responsibilities:
- threat model updates
- fuzzing strategy
- secure coding checklists
- supply chain controls

## 2. Coordination rules

- Each change must declare:
  - impacted subsystem(s)
  - consensus impact (yes/no)
  - test additions
- Cross-subsystem changes require a short ADR.

## 3. Task format

Add tasks to `ai/backlog/backlog.yml` using the template included there:
- id
- title
- subsystem
- description
- acceptance criteria
- tests required
- dependencies

## 4. Review strategy

- Consensus changes require explicit consensus-owner review.
- Storage changes require crash recovery tests.
- P2P changes require fuzz target updates or justification.
