# Performance & scalability

oni targets production-grade performance on the BEAM runtime.

## 1. Performance priorities

1. **Consensus correctness** (never sacrificed)
2. **IBD throughput**
3. **Mempool throughput**
4. **RPC query latency**
5. **Resource efficiency** (memory and disk)

## 2. Performance budgets (qualitative)

- No unbounded queues.
- No unbounded per-peer memory.
- No per-request allocations proportional to chain size.
- Avoid copying large binaries; use slicing and references.

## 3. Hot paths

- Script verification (ECDSA/Schnorr)
- UTXO lookups
- Block validation and connect
- Message parsing/encoding (P2P)

## 4. Concurrency model

- Validation is parallelized via a bounded worker pool.
- Chainstate connect/disconnect is serialized and authoritative.
- P2P IO is per-peer and concurrent, but backpressured by validation and mempool.

## 5. Crypto acceleration plan

- Use audited native implementations for secp256k1 operations.
- Avoid blocking schedulers:
  - treat crypto as “dirty” work (or run outside schedulers) where necessary.
- Maintain a reference implementation mode for debugging and differential testing.

## 6. Benchmarks

Maintain a benchmark suite:
- serialization throughput
- script interpreter microbenchmarks (opcode groups)
- signature verification QPS
- UTXO DB read/write latency
- end-to-end IBD throughput in regtest (synthetic) and mainnet (where feasible)

Benchmarks must:
- run locally and in CI (smoke version)
- report stable metrics (avoid noisy measurements)

## 7. Profiling workflow

- Profile IBD and mempool hotspots using:
  - BEAM scheduler stats
  - tracing spans (OpenTelemetry)
  - targeted microbenchmarks

Every performance regression requires:
- root cause analysis
- a benchmark reproduction
- an explicit tradeoff note if correctness requires the cost
