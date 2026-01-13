# Serialization Patterns

Bitcoin consensus serialization in Gleam.

## Location

- Package: `packages/oni_bitcoin`
- Key files: `transaction.gleam`, `block.gleam`, `compact_size.gleam`

## Core Patterns

### Primitive Codecs
- Little-endian u32/u64
- CompactSize/varint for lengths
- varstr (CompactSize + bytes)

### Compound Types
- OutPoint, TxIn, TxOut
- Transaction (legacy + witness)
- BlockHeader, Block

## Pitfalls

| Issue | Detail |
|-------|--------|
| Endianness | Hashes displayed big-endian, serialized little-endian |
| txid vs wtxid | txid excludes witness, wtxid includes witness |
| Varint boundaries | 0xFC/0xFD/0xFE/0xFF encoding transitions |
| CompactSize | Must reject non-canonical encodings |

## Code References

- CompactSize: `packages/oni_bitcoin/src/compact_size.gleam`
- Transaction: `packages/oni_bitcoin/src/transaction.gleam`
- Block: `packages/oni_bitcoin/src/block.gleam`

## Testing Requirements

- Roundtrip tests for all structs
- Real-world vectors from Bitcoin Core
- Negative tests for truncated/oversized inputs
- No unbounded allocations on malformed input
