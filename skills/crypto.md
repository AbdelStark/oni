# Cryptographic Operations

secp256k1, hashing, and signature verification.

## Location

- Package: `packages/oni_bitcoin` (hashing), `packages/oni_consensus` (verification)
- NIF: `packages/oni_consensus/c_src/secp256k1_nif.c`

## Operations

### Hashing
- `sha256`, `sha256d` (double SHA256)
- `ripemd160`, `hash160` (SHA256 + RIPEMD160)
- `tagged_hash` (BIP340 tagged hashes)

### Signatures
- `ecdsa_verify` — Legacy and SegWit v0
- `schnorr_verify` — Taproot (BIP340)
- `ecdsa_sign`, `schnorr_sign` — For testing/wallet

## secp256k1 NIF

Requires libsecp256k1 v0.5.0+ with schnorrsig module.

```sh
# Build dependency
git clone https://github.com/bitcoin-core/secp256k1
./autogen.sh && ./configure --enable-module-schnorrsig
make && sudo make install
```

## Pitfalls

| Issue | Detail |
|-------|--------|
| Scheduler blocking | Use dirty schedulers for NIF calls |
| Public key format | Compressed vs uncompressed parsing |
| DER encoding | ECDSA signatures must be strict DER |
| Schnorr format | 64-byte fixed format, no DER |

## Code References

- NIF: `packages/oni_consensus/c_src/secp256k1_nif.c`
- Gleam wrapper: `packages/oni_consensus/src/secp256k1.gleam`
- Test vectors: `test_vectors/bip340_vectors.csv`
