# Configuration

oni configuration must be:
- explicit
- validated at startup
- safe by default

## 1. Configuration sources (priority order)

1. CLI flags
2. Environment variables
3. Config file
4. Built-in defaults

## 2. Core config keys (planned)

### Network
- `network`: mainnet|testnet|regtest|signet
- `listen`: [ip:port]
- `connect`: [ip:port] (optional fixed peers)
- `proxy`: socks5 proxy (optional)
- `max_inbound`: int
- `max_outbound`: int

### Storage
- `data_dir`: path
- `db_engine`: rocksdb|leveldb|lmdb
- `prune`: true|false
- `cache_mb`: int

### Mempool
- `mempool_max_mb`: int
- `min_relay_fee`: sats/vbyte
- `relay`: true|false

### RPC
- `rpc_bind`: ip:port
- `rpc_auth`: cookie|userpass|token
- `rpc_allowip`: CIDR list
- `rpc_rate_limit`: config

### Telemetry
- `log_level`
- `metrics_bind`
- `trace_exporter`: none|otlp
- `trace_sample_rate`

## 3. Validation

On startup:
- reject unknown keys (or warn; decide in ADR)
- validate types and ranges
- emit effective config snapshot to logs and metrics
