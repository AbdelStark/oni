# Skill: Cryptography integration (secp256k1, hashing)

## Goal
Provide secure and fast cryptographic operations with a testable interface.

## Requirements
- Correctness: match BIP vectors and Bitcoin Core behavior.
- Safety: no runtime crashes; avoid scheduler blocking.
- Auditability: minimal native code surface; clear documentation.

## Steps
1. Define a `Crypto` interface in `oni_bitcoin/crypto`:
   - sha256, sha256d, ripemd160, hash160, tagged_hash
   - ecdsa_verify, schnorr_verify
   - pubkey parsing and validation
2. Implement reference backend:
   - portable and used for differential tests
3. Implement accelerated backend:
   - use audited native libraries
   - fuzz boundary
4. Add test vectors:
   - hashing vectors
   - ECDSA and Schnorr vectors (BIP340)
5. Add benchmarks for verify throughput

## Gotchas
- Constant-time behavior for secret-dependent operations (wallet).
- FIPS/OpenSSL mode limitations for some hash algorithms.
- Ensure public key parsing rules match Bitcoin Core.

## Acceptance checklist
- [ ] Reference and accelerated backends produce identical results
- [ ] Vectors pass
- [ ] Benchmarks included
- [ ] Failure modes documented and tested
