# Testing strategy

oni’s correctness is primarily validated by **tests**. The testing strategy is multi-layered and explicitly designed for consensus-critical code.

## 1. Testing layers

### 1.1 Unit tests
- Pure functions: serialization, hashing, bech32/base58, varints
- Script opcode semantics
- Sighash algorithms
- DB encoding/decoding

### 1.2 Property considerers
- Roundtrip encode/decode (block/tx/message)
- Varint boundaries, endian correctness
- Script stack invariants (bounded stack size, deterministic outcomes)

### 1.3 Fuzzing
- P2P message framing and decoding
- Script programs and signatures
- Transaction and block parsing
- Consensus validation entrypoints

Fuzzing targets must:
- never crash the runtime (panic is a bug)
- enforce bounds on allocations

### 1.4 Differential tests (vs Bitcoin Core)
- For a curated corpus:
  - run validation in oni
  - run validation in Bitcoin Core
  - compare accept/reject + error class

### 1.5 Integration tests
- Start a node in regtest mode.
- Generate blocks, submit transactions, reorg.
- Connect multiple oni nodes together and verify relay.

### 1.6 System tests
- Simulate adversarial peers and network partitions.
- Disk full, DB corruption injection, crash recovery tests.

## 2. Test vectors

Use canonical vectors from:
- Bitcoin Core test data (where possible and license-compatible)
- BIP reference vectors
- Hand-maintained edge case corpus

Track provenance:
- source
- commit hash (if taken from upstream)
- any modifications

## 3. CI gates

Minimum CI:
- format check
- type check
- unit tests
- integration smoke (regtest fast)
- fuzz smoke (short time budget)
- SBOM and dependency audit

## 4. Release qualification

Before a release:
- full regression test suite
- longer fuzz campaign
- sync-to-tip in a controlled environment
- performance benchmarks vs prior release
