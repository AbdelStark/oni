# Telemetry, logging, and monitoring

oni’s operational maturity is a core feature. This document defines the target observability system.

## 1. Goals

- Operators can answer:
  - “Is the node healthy?”
  - “How far behind am I?”
  - “Where is the time spent (IBD, mempool, script checks)?”
  - “Which peers are abusive / slow?”
  - “Is disk/DB a bottleneck?”
- Developers can debug performance regressions using traces and profiles.
- Security posture: logs and telemetry do not leak secrets.

## 2. Logging

### 2.1 Requirements
- Structured logs (JSON by default).
- Correlation IDs:
  - request_id (RPC)
  - peer_id
  - block_hash / txid where appropriate
- Log levels:
  - ERROR, WARN, INFO, DEBUG
- Redaction rules:
  - never log private keys / seeds
  - avoid logging full raw tx unless explicitly enabled

### 2.2 Log events to cover
- node startup + config summary
- DB open/close, migrations
- peer connect/disconnect and reasons
- IBD progress checkpoints
- reorg events (depth, old/new tips)
- mempool acceptance/rejection summaries
- RPC requests (method, duration, status)

## 3. Metrics

### 3.1 Metric types
- Counters: total blocks processed, messages received, tx accepted
- Gauges: mempool size, peer count, UTXO cache size
- Histograms: validation time, DB read latency, network RTT

### 3.2 Required metric groups
- `node_*`
- `p2p_*`
- `ibd_*`
- `validation_*`
- `mempool_*`
- `storage_*`
- `rpc_*`

### 3.3 Cardinality rules
- Do not label metrics with:
  - full txid/blockhash (unbounded)
  - raw IP addresses unless explicitly configured
- Prefer peer IDs (bounded) or aggregated buckets.

## 4. Tracing

- Distributed traces using OpenTelemetry concepts:
  - spans for block download → verify → connect
  - spans for RPC calls
  - spans for DB operations
- Sampling:
  - always sample errors
  - sample IBD spans at configurable rate

## 5. Profiling

Production-friendly hooks:
- periodic BEAM scheduler utilization snapshot
- memory stats snapshots
- optional CPU profiling integration where available

## 6. Health checks

- Liveness: process running + supervision tree alive
- Readiness:
  - DB opened and consistent
  - chainstate loaded
  - initial peer connections established (optional)
  - not in “recovery mode”

## 7. Alerting recommendations

Provide a default Prometheus alert rules file (operators can modify):
- node down
- no peers for too long
- IBD stalled
- DB latency high
- memory usage near cap
- disk full / near full
