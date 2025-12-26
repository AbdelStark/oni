# Protocol support matrix (planned)

This is a living checklist of what oni supports.

Legend:
- ✅ implemented
- 🟡 planned / in progress
- ⛔ not planned (yet)

## Networks
- 🟡 mainnet
- 🟡 testnet
- 🟡 regtest
- ⛔ signet (optional)

## Consensus features
- 🟡 Legacy script (P2PKH/P2SH)
- 🟡 SegWit v0 (BIP141 family)
- 🟡 Taproot v1 (BIP340/341/342)

## Encodings
- 🟡 Base58Check (legacy addresses, WIF)
- 🟡 Bech32 (SegWit v0)
- 🟡 Bech32m (Taproot)

## P2P messages (core)
- 🟡 version/verack
- 🟡 ping/pong
- 🟡 inv/getdata/notfound
- 🟡 headers/getheaders
- 🟡 block/tx
- 🟡 addr/getaddr

## Advanced P2P (later)
- ⛔ Compact blocks (BIP152) (planned later)
- ⛔ P2P transport encryption (future)

## RPC (minimum)
- 🟡 getblockchaininfo
- 🟡 getpeerinfo
- 🟡 getblock/getblockheader
- 🟡 sendrawtransaction

## Wallet
- ⛔ wallet disabled by default (planned as optional)
