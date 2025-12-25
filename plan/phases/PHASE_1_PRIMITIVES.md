# Phase 1: Bitcoin primitives (oni_bitcoin)

## Goal
Implement Bitcoin’s foundational types and codecs with exhaustive tests.

## Deliverables
- Core types: hashes, amounts, scripts, outpoints
- Consensus serialization: tx/block/header (encode + decode)
- Encodings: base16/base58check/bech32/bech32m
- Merkle utilities
- Test vectors + roundtrip properties

## Module plan (suggested)
See `docs/MODULE_PLAN.md`.

## Work packages

### 1.1 Primitive codecs
- Little-endian integer read/write
- CompactSize/varint
- varstr
- bounds and error types

### 1.2 Transactions
- Data structures: TxIn/TxOut/Transaction
- Legacy serialization
- Witness serialization
- txid/wtxid computation helpers (hash interface)

### 1.3 Blocks
- BlockHeader / Block data structures
- header serialization and hashing
- block serialization (tx list)
- merkle root computation utilities

### 1.4 Address encodings
- base58check
- bech32/bech32m
- scriptPubKey constructors for common address types

### 1.5 Tests
- Roundtrip encode/decode tests
- Edge case tests:
  - empty vectors
  - max length bounds
  - varint boundary transitions
- “Real world” vectors from upstream sources

## Acceptance criteria
- 100% of codecs have:
  - roundtrip tests
  - invalid input tests
- Address encoding vectors pass.
- No decoding path can crash on malformed bytes.
