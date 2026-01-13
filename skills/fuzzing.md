# Fuzz Testing Patterns

Fuzzing strategy for consensus and P2P code.

## Location

- Package: `packages/oni_consensus` (consensus fuzz)
- Package: `packages/oni_p2p` (P2P fuzz)
- Test files: `*_fuzz_test.gleam`

## Coverage Areas

### Consensus Fuzzing
- Script parsing boundaries
- Script execution edge cases
- Script number encoding
- Transaction parsing
- Block header parsing
- CompactSize boundaries
- Sighash computation
- Merkle root calculation

### P2P Fuzzing
- Message framing
- All message types
- Payload boundaries
- Checksum validation

## Approach

### Property-Based
```gleam
// Generate random valid-ish input
// Feed to parser
// Assert: never crashes, returns Result
```

### Boundary Testing
- Min/max values for all fields
- Off-by-one at size limits
- Truncated inputs
- Oversized inputs

### Mutation
- Bit flips in valid inputs
- Field swaps
- Length manipulation

## Pitfalls

| Issue | Detail |
|-------|--------|
| Determinism | Use seeded random for reproducibility |
| Coverage | Track which code paths are hit |
| Timeouts | Cap execution time per case |
| Memory | Bound allocation in fuzz targets |

## Code References

- Consensus fuzz: `packages/oni_consensus/test/consensus_fuzz_test.gleam`
- P2P fuzz: `packages/oni_p2p/test/fuzz_test.gleam`
- Test vectors: `test_vectors/`

## Running Fuzz Tests

```sh
# Run all tests including fuzz
make test

# Run specific package tests
cd packages/oni_consensus && gleam test
```
