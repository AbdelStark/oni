---
name: bitcoin-rpc
description: Query Bitcoin blockchain info from public RPC endpoints. Use for debugging sync issues, validating chain state, and comparing local node progress.
---

# Bitcoin RPC Query Skill

This skill provides tools to query public Bitcoin RPC endpoints for debugging and validating our node implementation.

## Public RPC Endpoints

| Network | RPC URL | Explorer | P2P Port | RPC Port |
|---------|---------|----------|----------|----------|
| **Mainnet** | `https://bitcoin-mainnet-rpc.publicnode.com` | [mempool.space](https://mempool.space) | 8333 | 8332 |
| **Testnet3** | `https://bitcoin-testnet-rpc.publicnode.com` | [mempool.space/testnet](https://mempool.space/testnet) | 18333 | 18332 |
| **Testnet4** | `https://bitcoin-testnet4.gateway.tatum.io` | [mempool.space/testnet4](https://mempool.space/testnet4) | 48333 | 48332 |
| **Signet** | Not available | [mempool.space/signet](https://mempool.space/signet) | 38333 | 38332 |

## Genesis Hashes

```
mainnet:  000000000019d6689c085ae165831e934ff763ae46a2a6c172b3f1b60a8ce26f
testnet3: 000000000933ea01ad0ee984209779baaec3ced90fa3f408719526f8d77f4943
testnet4: 00000000da84f2bafbbc53dee25a72ae507ff4914b867c565be350b0da8bf043
signet:   00000008819873e925422c1ff0f99f7cc9bbb232af63a077a480a3633bee1ef6
```

---

## Quick Commands

### Check Current Chain Height

```bash
# Testnet3
uv run scripts/btc_rpc.py height --network testnet3

# Testnet4
uv run scripts/btc_rpc.py height --network testnet4

# Mainnet
uv run scripts/btc_rpc.py height --network mainnet
```

### Get Full Blockchain Info

```bash
uv run scripts/btc_rpc.py info --network testnet3
uv run scripts/btc_rpc.py info --network testnet4
```

### Compare Local Node with Public Chain

```bash
# Compare testnet3 (default local port 18332)
uv run scripts/btc_rpc.py compare --network testnet3 --local http://127.0.0.1:18332

# Compare testnet4 (default local port 48332)
uv run scripts/btc_rpc.py compare --network testnet4 --local http://127.0.0.1:48332
```

### Verify Genesis Block

```bash
uv run scripts/btc_rpc.py genesis --network testnet3
uv run scripts/btc_rpc.py genesis --network testnet4
```

---

## Available Commands

| Command | Description |
|---------|-------------|
| `info` | Get blockchain info (height, best block, chainwork) |
| `block` | Get block by height or hash |
| `tx` | Get transaction by txid |
| `mempool` | Get mempool info |
| `compare` | Compare local node with public RPC |
| `endpoints` | List available RPC endpoints |
| `genesis` | Get genesis block info |
| `difficulty` | Get current difficulty |
| `height` | Quick height check |

---

## Usage Examples

### Check Blockchain Info

```bash
# Get testnet3 info
uv run scripts/btc_rpc.py info --network testnet3

# Output:
# ╭──────────────────── Bitcoin Testnet3 ────────────────────╮
# │ Chain: test                                               │
# │ Blocks: 4,811,779                                         │
# │ Headers: 4,811,779                                        │
# │ Best Block: 000000008c51...7c97dc4                        │
# │ Difficulty: 1.00                                          │
# │ Verification: 99.9998%                                    │
# │ IBD: False                                                │
# ╰───────────────────────────────────────────────────────────╯
```

### Compare Local Node Progress

```bash
# Debug sync issues by comparing with public chain
uv run scripts/btc_rpc.py compare --network testnet3

# Output shows sync progress and detects issues:
# ┌─────────────────────────────────────────────────────────┐
# │           Sync Comparison: Bitcoin Testnet3             │
# ├────────────┬─────────────┬─────────────┬────────┬───────┤
# │ Metric     │ Public      │ Local       │ Diff   │ Prog  │
# ├────────────┼─────────────┼─────────────┼────────┼───────┤
# │ Headers    │ 4,811,779   │ 9,208,000   │ +4.4M  │ RED!  │  <- PROBLEM!
# │ Blocks     │ 4,811,779   │ 0           │ -4.8M  │ 0%    │
# └────────────┴─────────────┴─────────────┴────────┴───────┘
# WARNING: Local headers significantly ahead of public chain!
```

### Get Block Details

```bash
# Get genesis block
uv run scripts/btc_rpc.py block --network testnet3 --height 0

# Get specific block by hash
uv run scripts/btc_rpc.py block --network testnet4 --hash 00000000da84f2...

# Raw JSON output for scripting
uv run scripts/btc_rpc.py block --network testnet3 --height 100 --raw
```

### Get Transaction

```bash
uv run scripts/btc_rpc.py tx <txid> --network testnet3
```

---

## Debugging Sync Issues

### Issue: Headers exceeding actual chain height

**Symptom**: Local headers count is much higher than public chain

```bash
uv run scripts/btc_rpc.py compare --network testnet3
# Shows: Local headers: 9,000,000+ vs Public: 4,800,000
```

**Cause**: Missing chain continuity validation - accepting headers that don't form a valid chain

**Solution**: The IBD coordinator must verify:
1. Each header's `prev_block` matches hash of previous header
2. First header in batch connects to last known header
3. Headers don't exceed maximum expected height

### Issue: Stuck at height 0

**Symptom**: Headers syncing but blocks stay at 0

```bash
uv run scripts/btc_rpc.py compare --network testnet3
# Shows: Headers: 4,800,000, Blocks: 0
```

**Cause**: Headers sync complete but block download not starting or blocks not being validated

**Solution**: Check IBD coordinator state transition from `IbdSyncingHeaders` to `IbdDownloadingBlocks`

### Issue: Wrong genesis hash

**Symptom**: Node starts syncing wrong chain

```bash
uv run scripts/btc_rpc.py genesis --network testnet3
# Verify genesis hash matches expected
```

**Solution**: Check network params in `oni_bitcoin.gleam` match expected genesis

---

## Direct curl Commands

For quick checks without the script:

```bash
# Testnet3 blockchain info
curl -s -X POST -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":1,"method":"getblockchaininfo"}' \
    https://bitcoin-testnet-rpc.publicnode.com | jq

# Testnet4 blockchain info
curl -s -X POST -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":1,"method":"getblockchaininfo"}' \
    https://bitcoin-testnet4.gateway.tatum.io | jq

# Local node (testnet3)
curl -s -X POST -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":1,"method":"getblockchaininfo"}' \
    http://127.0.0.1:18332 | jq

# Local node (testnet4)
curl -s -X POST -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":1,"method":"getblockchaininfo"}' \
    http://127.0.0.1:48332 | jq
```

---

## Network Configuration Reference

### Local RPC Ports (oni node defaults)

| Network | RPC Port | P2P Port | Data Dir |
|---------|----------|----------|----------|
| Mainnet | 8332 | 8333 | `~/.oni` |
| Testnet3 | 18332 | 18333 | `~/.oni/testnet3` |
| Testnet4 | 48332 | 48333 | `~/.oni/testnet4` |
| Regtest | 18443 | 18444 | `~/.oni/regtest` |

### Expected Chain Heights (as of Jan 2025)

| Network | Approx Height | Max Expected (safety) |
|---------|---------------|----------------------|
| Mainnet | ~880,000 | 1,000,000 |
| Testnet3 | ~4,800,000 | 6,000,000 |
| Testnet4 | ~117,000 | 500,000 |
| Signet | ~200,000 | 500,000 |
