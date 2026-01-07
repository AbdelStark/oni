# Skill: Node Manager

## Purpose

Manage and debug the oni Bitcoin node. Use this skill to check sync progress, diagnose issues, and perform maintenance.

## Quick Commands

### Check Node Status (Testnet4)

```bash
curl -s -X POST -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":1,"method":"getblockchaininfo"}' \
    http://127.0.0.1:48332 | jq
```

### Compare with Public Chain

```bash
uv run scripts/btc_rpc.py compare --network testnet4
```

### Watch Sync Progress

```bash
watch -n 5 'uv run scripts/btc_rpc.py compare --network testnet4'
```

## RPC Ports

| Network | RPC Port |
|---------|----------|
| Mainnet | 8332 |
| Testnet3 | 18332 |
| Testnet4 | 48332 |
| Regtest | 18443 |

## Common Debugging Tasks

### 1. Check Current Sync Status

```bash
# One-liner status check
curl -s -X POST -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":1,"method":"getblockchaininfo"}' \
    http://127.0.0.1:48332 | jq '{headers, blocks, bestblockhash, initialblockdownload}'
```

### 2. Clear Data and Restart

```bash
rm -rf ~/.oni/testnet4 && make run-testnet4
```

### 3. Check if Node is Running

```bash
ps aux | grep -E 'beam.*oni' | grep -v grep
```

### 4. Kill Node Process

```bash
pkill -f 'beam.*oni'
```

## Key Files

| File | Purpose |
|------|---------|
| `packages/oni_node/src/ibd_coordinator.gleam` | IBD state machine |
| `packages/oni_node/src/event_router.gleam` | P2P message routing |
| `packages/oni_node/src/oni_node.gleam` | Node startup |
| `scripts/btc_rpc.py` | RPC debugging script |

## Expected Response Fields

```json
{
  "headers": 117623,      // Validated headers count
  "blocks": 0,            // Validated blocks count
  "bestblockhash": "...", // Tip of validated block chain
  "initialblockdownload": true  // Still syncing
}
```

## IBD Phases

1. **Waiting for peers** - Discovering and connecting
2. **Syncing headers** - Downloading header chain
3. **Downloading blocks** - Fetching full blocks
4. **Synced** - Caught up with network

## Troubleshooting

### Headers OK but blocks=0

Block download phase not progressing. Check:
1. IBD state transition to `IbdDownloadingBlocks`
2. `getdata` messages being sent
3. Block responses being received

### Headers exceeding chain

Invalid headers being accepted. Check:
1. Chain continuity validation
2. Genesis hash matches network
3. max_expected_height limit

### No sync progress

Peer connectivity issue. Check:
1. DNS seed resolution
2. P2P port open
3. Network magic bytes correct
