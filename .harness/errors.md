# Known Errors and Solutions

Document errors encountered during development and their solutions.

---

## [SECP256K1_NOT_FOUND] libsecp256k1 not installed

**Symptoms**: NIF compilation fails, signature verification unavailable

**Cause**: libsecp256k1 v0.5.0+ with schnorrsig module not installed

**Solution**:
```sh
# Ubuntu/Debian
git clone https://github.com/bitcoin-core/secp256k1
cd secp256k1
./autogen.sh
./configure --enable-module-schnorrsig
make && sudo make install
sudo ldconfig
```

**Prevention**: Use Docker image which includes pre-built libsecp256k1

---

## [IBD_STALL] Block download stalls during IBD

**Symptoms**: Sync progress stops, no new blocks arriving

**Cause**: Peer disconnected or slow peer blocking queue

**Solution**:
1. Check peer connections: `make node-status`
2. View logs for peer errors: `make node-logs`
3. If stuck, restart with fresh peers: `make fresh-testnet4`

**Prevention**: IBD coordinator has stall detection and peer reassignment

---

## [HEADER_VALIDATION] Header rejected during sync

**Symptoms**: `InvalidPrevBlock` or `InvalidPoW` errors in logs

**Cause**: Chain continuity broken or invalid proof of work

**Solution**:
1. Compare with public chain: `make compare-testnet4`
2. Check if on wrong fork
3. Clear data and resync if necessary

**Prevention**: Checkpoint validation ensures correct chain

---

## [BEAM_SCHEDULER_BLOCK] NIF blocking BEAM schedulers

**Symptoms**: Node becomes unresponsive, high latency

**Cause**: Long-running NIF operation without yielding

**Solution**: NIF operations should be dirty-scheduled or chunked

**Prevention**: All secp256k1 NIF calls use dirty schedulers

---

## [DETS_CORRUPTION] Persistent storage corruption

**Symptoms**: Node crashes on restart, data errors

**Cause**: Unclean shutdown or disk issues

**Solution**:
```sh
# Clear corrupted data
make clear-testnet4
# Resync
make run-testnet4
```

**Prevention**: Graceful shutdown with `make node-stop`

---

## Adding New Errors

Use this template:

```markdown
## [ERROR_CODE] Short description

**Symptoms**: What you observe
**Cause**: Root cause
**Solution**: How to fix
**Prevention**: How to avoid
```
