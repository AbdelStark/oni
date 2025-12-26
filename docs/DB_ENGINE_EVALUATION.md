# DB engine evaluation plan

oni requires a persistent KV store for:
- UTXO set
- block index and metadata
- optional indexes (txindex, addrindex)

This document outlines how we will choose and validate a DB engine.

## 1. Candidate engines

Evaluate:
- RocksDB
- LevelDB-compatible engines
- LMDB

## 2. Evaluation criteria

### Correctness & safety
- crash consistency guarantees
- corruption detection and recovery story
- transactional semantics (or how to emulate)

### Performance
- random read latency (UTXO lookups)
- write throughput (connect block)
- compaction behavior under sustained writes

### Operational
- disk amplification
- compaction tuning knobs
- monitoring hooks (stats/telemetry)
- migration and upgrade behavior

### Portability
- Linux support (required)
- macOS/Windows (strongly desired)
- cross-compilation implications for releases

## 3. Benchmark plan

### 3.1 Workloads
- UTXO workload:
  - random reads with realistic key distribution
  - batched writes per block connect
- Block index workload:
  - write new headers
  - read tips and random historical lookups

### 3.2 Metrics to record
- p50/p95/p99 read latency
- write throughput
- compaction CPU time
- disk usage growth
- recovery time after unclean shutdown

## 4. Decision process

- Implement a DB abstraction interface first.
- Build benchmark harness and run on candidates.
- Record results in `benchmarks/db/`.
- Choose engine via an ADR.
