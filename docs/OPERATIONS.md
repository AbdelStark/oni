# Operations runbook

This runbook focuses on safe operation of an oni node in production environments.
It complements the deployment guide with day-2 operational practices.

## 1. Production readiness checklist

Before serving real traffic:
- ✅ All CI checks green (`make ci`)
- ✅ Mainnet IBD completed in a controlled environment
- ✅ Metrics and logs visible in dashboards
- ✅ Backup/restore procedure tested
- ✅ Alerting in place for core health signals

## 2. Startup checklist

- Review configuration expectations in `docs/CONFIGURATION.md`.
- Validate configuration file and environment overrides.
- Confirm data directory ownership/permissions.
- Ensure disk space headroom (minimum 20% free).
- Verify RPC is bound to a safe interface and auth is configured.
- Confirm metrics endpoint is reachable (if enabled).
- Verify system clock is synchronized (NTP/chrony).

## 3. Health checks

Endpoints:
- `/healthz` should return OK if the process is alive.
- `/readyz` should return OK only when:
  - DB opened and consistent
  - chainstate loaded
  - node is not in recovery mode

Operational expectations:
- Ready state flips to “not ready” during reindex/recovery.
- Health checks should remain “OK” unless the process is unhealthy.

## 4. Core telemetry signals

Recommended dashboards/alerts:
- Peer count (inbound/outbound)
- Tip height and headers height
- IBD progress rate (blocks/hour)
- DB read/write latency
- Validation error rate
- Mempool size and eviction rate
- Disk usage and free space
- Memory usage vs. configured cache limits

## 5. Backups and recovery

Backup strategy:
- Backup chainstate only if you have a consistent snapshot mechanism.
- Backup addrman and banlist periodically (small and cheap).
- Prefer snapshots over live DB file copies.

Restore expectations:
- If chainstate is corrupted, prefer re-sync unless snapshot restore is proven.
- Document restore time objectives (RTO) and data loss limits (RPO).

## 6. Upgrades and rollbacks

Upgrade workflow:
1. Announce planned maintenance window.
2. Stop the node cleanly.
3. Upgrade binary/container.
4. Start node and monitor readiness.
5. Validate headers/chainstate continuity.

Rollback checklist:
- Keep prior binary/container tagged.
- Preserve data directory.
- Record the software version and schema compatibility.

## 7. Incident response

### 7.1 Crash loop
- Inspect logs and crash dumps.
- Start in safe recovery mode if DB corruption suspected.
- Capture diagnostics before reindexing.

### 7.2 Stuck IBD
- Check peer count and inbound/outbound connectivity.
- Check disk latency and free space.
- Check validation worker utilization.

### 7.3 High memory usage
- Review mempool size and eviction behavior.
- Verify cache limits vs. available memory.
- Inspect P2P queue lengths for backpressure issues.

### 7.4 RPC overload
- Check RPC request rate and latency.
- Increase rate limits only with caution.
- Consider isolating RPC to a separate interface or network segment.

## 8. Security hardening

- Bind RPC to localhost or a private network interface.
- Use strong RPC authentication and rotate secrets periodically.
- Run the node under a dedicated system user.
- Enforce filesystem and process limits (see systemd unit examples).
- Restrict outbound firewall rules to required ports.

## 9. Capacity planning

- Disk growth tracks chain size and index settings.
- Cache sizing should leave headroom for OS and BEAM overhead.
- Plan for mainnet IBD to be CPU- and IO-intensive.

## 10. Routine maintenance

- Periodically verify backups and restore procedures.
- Rotate logs and archive metrics for long-term analysis.
- Review configuration drift after upgrades.
