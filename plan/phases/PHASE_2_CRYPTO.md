# Phase 2: Cryptography

## Goal
Provide safe, testable cryptographic primitives and signature verification suitable for production performance.

## Deliverables
- `oni_bitcoin/crypto` stable interface
- Hashing primitives:
  - sha256, sha256d
  - tagged hash
  - ripemd160, hash160
- Signature primitives:
  - ECDSA verify
  - Schnorr verify
  - pubkey parsing

## Work packages

### 2.1 Interface definition
- Define types:
  - `PubKey`, `XOnlyPubKey`
  - `Signature` (ECDSA), `SchnorrSig`
- Define functions:
  - hash functions
  - verify functions
  - parse/serialize helpers

### 2.2 Reference backend
- Must be deterministic and portable.
- Used for differential tests and debugging.

### 2.3 Accelerated backend
- Use audited native code where feasible.
- Ensure BEAM scheduler safety.
- Provide clear build steps and CI integration.

### 2.4 Testing
- Hash vectors
- BIP340 vectors for schnorr
- ECDSA vectors used in Bitcoin Core

### 2.5 Benchmarks
- verify QPS
- sha256d throughput

## Acceptance criteria
- Reference and accelerated backends match on vectors and randomized tests.
- Crypto boundary has fuzz coverage for parsing inputs.
