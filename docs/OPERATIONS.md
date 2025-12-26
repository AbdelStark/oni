# Operations runbook (starter)

This is an initial runbook for operating oni.

## 1. Startup checklist

- Ensure data directory is writable.
- Ensure disk space is sufficient.
- Ensure RPC is bound to safe interface and auth is configured.
- Verify metrics endpoint is reachable (if enabled).

## 2. Health checks

- `/healthz` should return OK if process is alive.
- `/readyz` should return OK only when:
  - DB opened and consistent
  - chainstate loaded
  - node is not in recovery mode

## 3. Common alerts

- Node down
- No peers for extended duration
- IBD stalled (height not increasing)
- DB latency spike
- Disk nearly full
- Memory near cap

## 4. Incident response

### 4.1 Node crash loop
- Inspect logs for crash reason.
- If DB corruption suspected:
  - start in safe recovery mode (read-only)
  - export diagnostics
  - rebuild/reindex if necessary

### 4.2 Stuck IBD
- Check peer count and inbound/outbound connectivity.
- Check DB latency and disk usage.
- Check validation worker utilization.

### 4.3 High memory usage
- Check mempool size and eviction behavior.
- Check cache size settings.
- Look for p2p queue growth.

## 5. Backups

- Periodic backup of:
  - wallet data (if enabled)
  - banlist and addrman (optional)
- Full chainstate backup is large; prefer re-sync or snapshot strategy.
