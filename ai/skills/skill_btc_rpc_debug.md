# Skill: Bitcoin RPC Debugging

## Purpose

Query public Bitcoin RPC endpoints to debug and validate our node implementation. Essential for:
- Verifying sync progress against real network state
- Validating chain parameters (genesis hash, difficulty)
- Detecting sync anomalies (runaway headers, wrong chain)
- Cross-checking block/transaction data

## Public RPC Endpoints

| Network | RPC URL | Local RPC Port |
|---------|---------|----------------|
| **Mainnet** | `https://bitcoin-mainnet-rpc.publicnode.com` | 8332 |
| **Testnet3** | `https://bitcoin-testnet-rpc.publicnode.com` | 18332 |
| **Testnet4** | `https://bitcoin-testnet4.gateway.tatum.io` | 48332 |
| **Signet** | Not available | 38332 |

## Genesis Hashes

```
mainnet:  000000000019d6689c085ae165831e934ff763ae46a2a6c172b3f1b60a8ce26f
testnet3: 000000000933ea01ad0ee984209779baaec3ced90fa3f408719526f8d77f4943
testnet4: 00000000da84f2bafbbc53dee25a72ae507ff4914b867c565be350b0da8bf043
signet:   00000008819873e925422c1ff0f99f7cc9bbb232af63a077a480a3633bee1ef6
```

## UV Script Commands

The `scripts/btc_rpc.py` script provides convenient commands:

```bash
# List all endpoints
uv run scripts/btc_rpc.py endpoints

# Get blockchain info
uv run scripts/btc_rpc.py info --network testnet3
uv run scripts/btc_rpc.py info --network testnet4

# Quick height check
uv run scripts/btc_rpc.py height --network testnet3

# Compare local node with public chain
uv run scripts/btc_rpc.py compare --network testnet3 --local http://127.0.0.1:18332
uv run scripts/btc_rpc.py compare --network testnet4 --local http://127.0.0.1:48332

# Verify genesis block
uv run scripts/btc_rpc.py genesis --network testnet3

# Get specific block
uv run scripts/btc_rpc.py block --network testnet3 --height 0
uv run scripts/btc_rpc.py block --network testnet4 --height 100
```

## Direct curl Commands

```bash
# Testnet3 blockchain info
curl -s -X POST -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":1,"method":"getblockchaininfo"}' \
    https://bitcoin-testnet-rpc.publicnode.com

# Testnet4 blockchain info
curl -s -X POST -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":1,"method":"getblockchaininfo"}' \
    https://bitcoin-testnet4.gateway.tatum.io

# Local node query
curl -s -X POST -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":1,"method":"getblockchaininfo"}' \
    http://127.0.0.1:18332
```

## Common Debugging Scenarios

### 1. Headers Exceeding Chain Tip

**Symptom**: Local headers count >> public chain height

```bash
uv run scripts/btc_rpc.py compare --network testnet3
# Local headers: 9,000,000+ vs Public: 4,800,000
```

**Diagnosis**: Missing chain continuity validation

**Fix**: IBD coordinator must verify `prev_block` matches hash of previous header

### 2. Stuck at Block 0

**Symptom**: Headers syncing but blocks stay at 0

**Diagnosis**: Block download not starting after headers complete

**Check**: IBD state transition from `IbdSyncingHeaders` to `IbdDownloadingBlocks`

### 3. Wrong Genesis Hash

**Symptom**: Connecting to wrong network

```bash
uv run scripts/btc_rpc.py genesis --network testnet3
# Compare with expected hash
```

**Fix**: Verify `oni_bitcoin.testnet_params()` returns correct genesis

### 4. Verify Sync Progress

```bash
# Monitor sync every few seconds
watch -n 5 'uv run scripts/btc_rpc.py compare --network testnet4'
```

## Expected Chain Heights (Jan 2025)

| Network | Height | Max Safety Limit |
|---------|--------|------------------|
| Mainnet | ~880,000 | 1,000,000 |
| Testnet3 | ~4,800,000 | 6,000,000 |
| Testnet4 | ~117,000 | 500,000 |
| Signet | ~200,000 | 500,000 |

## Related Files

- Script: `scripts/btc_rpc.py`
- Skill docs: `skills/bitcoin-rpc.md`
- Network params: `packages/oni_bitcoin/src/oni_bitcoin.gleam`
- IBD coordinator: `packages/oni_node/src/ibd_coordinator.gleam`
- Node config: `packages/oni_node/src/oni_node.gleam`
