---
name: node-manager
description: Manage and debug the oni Bitcoin node. Check sync progress, query RPC, view logs, and perform maintenance actions.
---

# Oni Node Manager Skill

Manage the oni Bitcoin node for debugging and monitoring sync progress.

## Quick Status Check

```bash
# Check local node status (Testnet4)
curl -s -X POST -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":1,"method":"getblockchaininfo"}' \
    http://127.0.0.1:48332 | jq

# Check local node status (Testnet3)
curl -s -X POST -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":1,"method":"getblockchaininfo"}' \
    http://127.0.0.1:18332 | jq

# Check local node status (Mainnet)
curl -s -X POST -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":1,"method":"getblockchaininfo"}' \
    http://127.0.0.1:8332 | jq
```

## Compare with Public Chain

```bash
# Compare Testnet4 sync progress
uv run scripts/btc_rpc.py compare --network testnet4

# Compare Testnet3 sync progress
uv run scripts/btc_rpc.py compare --network testnet3

# Watch sync progress (every 5 seconds)
watch -n 5 'uv run scripts/btc_rpc.py compare --network testnet4'
```

## RPC Port Reference

| Network | RPC Port | P2P Port |
|---------|----------|----------|
| Mainnet | 8332 | 8333 |
| Testnet3 | 18332 | 18333 |
| Testnet4 | 48332 | 48333 |
| Regtest | 18443 | 18444 |

## Node Management

### Start Node

```bash
# Testnet4
make run-testnet4

# Testnet3
make run-testnet

# Mainnet
make run

# Regtest (development)
make run-regtest
```

### Clear Data and Restart

```bash
# Testnet4 - full reset
rm -rf ~/.oni/testnet4 && make run-testnet4

# Testnet3 - full reset
rm -rf ~/.oni/testnet3 && make run-testnet

# Clear all networks
rm -rf ~/.oni
```

### View Running Processes

```bash
# Find oni node processes
ps aux | grep -E 'gleam|oni|beam' | grep -v grep

# Kill node (if needed)
pkill -f 'beam.*oni'
```

## Detailed RPC Commands

### Get Blockchain Info
```bash
curl -s -X POST -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":1,"method":"getblockchaininfo"}' \
    http://127.0.0.1:48332 | jq
```

Response fields:
- `headers`: Number of validated headers
- `blocks`: Number of validated blocks
- `bestblockhash`: Hash of best validated block
- `initialblockdownload`: True if still syncing

### Get Peer Info
```bash
curl -s -X POST -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":1,"method":"getpeerinfo"}' \
    http://127.0.0.1:48332 | jq
```

### Get Network Info
```bash
curl -s -X POST -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":1,"method":"getnetworkinfo"}' \
    http://127.0.0.1:48332 | jq
```

### Get Block by Height
```bash
# Get block hash at height
curl -s -X POST -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":1,"method":"getblockhash","params":[0]}' \
    http://127.0.0.1:48332 | jq

# Get block details
curl -s -X POST -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":1,"method":"getblock","params":["HASH_HERE"]}' \
    http://127.0.0.1:48332 | jq
```

## Debugging Sync Issues

### Issue: Headers synced but blocks at 0

**Symptom**: `headers` shows correct value but `blocks` stays at 0

**Check**: Look for block download messages in node output:
```
[IBD] Starting block download from height 0 to 117623
[IBD] Built download queue with X blocks to download
```

**Possible causes**:
1. Block download not starting after headers complete
2. `getdata` requests not being sent
3. Peers not responding to block requests

### Issue: Headers exceeding chain tip

**Symptom**: Local headers >> public chain height

**Check**:
```bash
uv run scripts/btc_rpc.py compare --network testnet4
```

**Fix**: Clear data and restart with latest code:
```bash
rm -rf ~/.oni/testnet4 && make run-testnet4
```

### Issue: No peers connecting

**Symptom**: Headers stay at 0, no sync progress

**Check**: DNS resolution and peer discovery:
```bash
# Test DNS seeds
dig seed.testnet4.bitcoin.sprovoost.nl
dig seed.testnet4.wiz.biz
```

## Log Analysis

Key log prefixes to watch:
- `[IBD]` - IBD coordinator messages
- `[Sync]` - Header/block sync events
- `[P2P]` - Peer connections
- `[Block]` - Block processing

### Expected Startup Sequence

```
Starting oni node v0.1.0...
  ✓ Chainstate initialized
  ✓ Mempool started
  ✓ Sync coordinator started
  ✓ Event router started
  ✓ P2P listener started on 0.0.0.0:48333
  ✓ IBD coordinator started
[IBD] ========================================
[IBD] Starting IBD coordinator
[IBD] Network: Testnet4
[IBD] Genesis hash: 00000000da84f2bafbbc53dee25a72ae507ff4914b867c565be350b0da8bf043
[IBD] Max expected height: 500000
[IBD] ========================================
  ✓ IBD coordinator connected to event router
  ✓ RPC server started on 127.0.0.1:48332
  Discovering peers via DNS...
  ✓ Found X peers from DNS seeds
  ✓ Initiated connection to X peers
Node started successfully!
```

### Expected Sync Sequence

```
[IBD] Peer connected: peer_id, height: XXXXX
[IBD] Starting headers sync...
[IBD] Sending getheaders with X locators
[Sync] Received 2000 headers from peer X
[IBD] Headers validated, new height: 2000
...
[IBD] Headers sync complete at height 117623
[IBD] Starting block download from height 0 to 117623
[IBD] Block 1 of 117623 (0%)
[IBD] Block 100 of 117623 (0%)
...
```

## Genesis Hashes (for verification)

```
Mainnet:  000000000019d6689c085ae165831e934ff763ae46a2a6c172b3f1b60a8ce26f
Testnet3: 000000000933ea01ad0ee984209779baaec3ced90fa3f408719526f8d77f4943
Testnet4: 00000000da84f2bafbbc53dee25a72ae507ff4914b867c565be350b0da8bf043
Signet:   00000008819873e925422c1ff0f99f7cc9bbb232af63a077a480a3633bee1ef6
```
