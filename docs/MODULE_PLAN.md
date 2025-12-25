# Planned module map (detailed)

This document proposes a module layout for each package.
It is intended as a starting point; changes should be captured in ADRs.

> Naming convention: `oni_<pkg>/<area>/<module>`.

## 1. packages/oni_bitcoin

### types
- `oni_bitcoin/types/hash`
  - `Hash256`, `Txid`, `Wtxid`, `BlockHash`
  - endian helpers and display
- `oni_bitcoin/types/amount`
  - `Amount` (sats), safe arithmetic helpers
- `oni_bitcoin/types/script`
  - raw script bytes + helpers (no execution)
- `oni_bitcoin/types/transaction`
  - TxIn/TxOut/Transaction data structures
- `oni_bitcoin/types/block`
  - BlockHeader/Block

### codec
- `oni_bitcoin/codec/compact_size`
- `oni_bitcoin/codec/bytes` (LE ints, slices)
- `oni_bitcoin/codec/transaction`
- `oni_bitcoin/codec/block`
- `oni_bitcoin/codec/p2p` (shared structures)

### encoding
- `oni_bitcoin/encoding/base16`
- `oni_bitcoin/encoding/base58check`
- `oni_bitcoin/encoding/bech32`
- `oni_bitcoin/encoding/bech32m`

### crypto
- `oni_bitcoin/crypto/interface`
- `oni_bitcoin/crypto/reference/*`
- `oni_bitcoin/crypto/accelerated/*`

## 2. packages/oni_consensus

### script
- `oni_consensus/script/opcodes`
- `oni_consensus/script/parser`
- `oni_consensus/script/interpreter`
- `oni_consensus/script/flags`
- `oni_consensus/script/errors`

### sighash
- `oni_consensus/sighash/legacy`
- `oni_consensus/sighash/segwit_v0`
- `oni_consensus/sighash/taproot`

### validation
- `oni_consensus/validation/tx`
- `oni_consensus/validation/block_header`
- `oni_consensus/validation/block`
- `oni_consensus/validation/errors`

## 3. packages/oni_storage

- `oni_storage/db/interface`
- `oni_storage/db/rocksdb` (or chosen backend)
- `oni_storage/schema/version`
- `oni_storage/blockstore/files`
- `oni_storage/block_index`
- `oni_storage/utxo/codec`
- `oni_storage/utxo/cache`
- `oni_storage/undo/codec`
- `oni_storage/chainstate`

## 4. packages/oni_p2p

- `oni_p2p/wire/envelope`
- `oni_p2p/wire/limits`
- `oni_p2p/messages/*`
- `oni_p2p/peer/connection`
- `oni_p2p/peer/manager`
- `oni_p2p/addrman`
- `oni_p2p/relay/*`
- `oni_p2p/ibd/*`

## 5. packages/oni_rpc

- `oni_rpc/server`
- `oni_rpc/auth`
- `oni_rpc/methods/*`
- `oni_rpc/errors`

## 6. packages/oni_node

- `oni_node/config`
- `oni_node/app` (OTP start)
- `oni_node/supervisor`
- `oni_node/telemetry`
- `oni_node/main` (CLI entrypoint)
