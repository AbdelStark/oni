# Skill: Bitcoin consensus serialization in Gleam

## Goal
Implement Bitcoin consensus serialization/deserialization that is:
- correct (matches Bitcoin Core),
- total (never crashes),
- allocation-bounded,
- exhaustively tested.

## Where
- Package: `packages/oni_bitcoin`
- Modules (planned):
  - `oni_bitcoin/codec/*`
  - `oni_bitcoin/types/*`

## Steps
1. Define canonical primitive codecs
   - little-endian u32/u64
   - CompactSize/varint
   - varstr (CompactSize length + bytes)
2. Build compound codecs
   - OutPoint, TxIn, TxOut
   - Transaction (legacy + witness)
   - BlockHeader, Block, merkle root
3. Enforce bounds
   - reject lengths above configured maximums
   - limit number of inputs/outputs/txs during parsing
4. Write roundtrip tests
   - decode(encode(x)) == x for generated values
5. Add known vectors
   - include raw hex samples from Bitcoin Core/BIPs with expected parsed fields

## Gotchas
- Endianness: many hashes are displayed big-endian but serialized little-endian.
- txid vs wtxid: txid excludes witness, wtxid includes witness.
- Varint boundaries: 0xFD/0xFE/0xFF encoding transitions.
- Avoid copying: prefer slicing binaries/BitArrays.

## Acceptance checklist
- [ ] Roundtrip tests for all structs
- [ ] At least one “real world” vector per struct (tx, block, header)
- [ ] Negative tests for truncated/oversized inputs
- [ ] No unbounded recursion or list growth on malformed input
