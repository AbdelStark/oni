# Storage and chainstate

This document describes the target storage architecture for oni.

## 1. Goals

- Crash-safe persistence for:
  - block headers and index
  - block data (blk files or DB)
  - UTXO set
  - peer address manager state
  - banlist
- Efficient reads during:
  - IBD (sequential block processing)
  - mempool validation (random UTXO access)
  - serving RPC queries (block/tx lookup)

## 2. Storage engines

oni must support at least one production-grade KV store for UTXO + indexes.

Candidate engines (evaluate with benchmarks + portability):
- LevelDB-compatible engine
- RocksDB (widely used; requires native library)
- LMDB (memory-mapped; excellent read performance)
- ETS + disk snapshots (not sufficient alone)

Selection criteria:
- high read QPS under random access
- write amplification and compaction behavior
- crash recovery guarantees
- ease of packaging on Linux/macOS/Windows
- BEAM interop stability

## 3. Data model

### 3.1 Block store
Two main patterns:
1. Bitcoin Core style `blkNNNNN.dat` append-only files + separate index DB.
2. Direct DB-backed storage of block bytes.

Preferred approach for simplicity + performance:
- Append-only block files (fast sequential I/O)
- Separate block index DB with:
  - file number
  - offset
  - length
  - header metadata (height, chainwork)

### 3.2 UTXO set
Key: outpoint `(txid, vout)`  
Value: coin record
- amount
- scriptPubKey
- height and coinbase flag

### 3.3 Undo data
To support reorg:
- per-block undo records containing spent outputs
- stored alongside block files or in DB

### 3.4 Headers / block index
- header chain in DB
- per-block metadata: height, status flags, chainwork
- indices:
  - hash → index entry
  - height → hash (active chain only)

## 4. Atomicity & recovery

- Block connect must be atomic:
  - UTXO updates
  - block index status update
  - undo write
- Use DB transactions where available.
- If the DB engine lacks transactions, implement a write-ahead log and recovery.

On startup:
- detect partial writes
- roll back to last consistent tip
- verify internal invariants (best chain, UTXO counts, etc.)

## 5. Caching

Performance requires caches:
- UTXO cache (LRU) with write-back batching
- Block index cache
- Script/sig caches (in memory, evictable)

Caches must:
- be bounded
- be observable (hit rate, size, evictions)
- be safely reset if corruption suspected

## 6. Migrations and versioning

- Every DB has a `schema_version`.
- Migrations are explicit and resumable.
- Backwards incompatible migrations must:
  - fail fast with clear operator instructions
  - support export/import or snapshot rebuild where possible

## 7. Pruning (optional mode)

- Keep only recent block files while maintaining full UTXO set.
- Must enforce that pruning never deletes blocks needed for:
  - reorg depth safety margin
  - serving configured RPC calls (document limitations)
