# Crypto strategy

Bitcoin validation performance is dominated by cryptography:
- ECDSA signature verification (legacy + segwit)
- Schnorr signature verification (taproot)
- hashing (sha256d) for PoW and merkle computations

This document defines oni’s approach.

## 1. Requirements

- Correctness: match Bitcoin Core semantics and BIP test vectors.
- Safety: crypto failures must not crash the runtime.
- Performance: competitive signature verification throughput.
- Portability: must run on common Linux distributions; macOS/Windows support is a goal.

## 2. Layered design

### 2.1 Stable interface
`oni_bitcoin/crypto` defines:
- sha256, sha256d
- ripemd160, hash160
- tagged_hash
- ecdsa_verify, schnorr_verify
- pubkey parsing/validation

Consensus code only calls this interface.

### 2.2 Backends
1. **Reference backend**
   - used in tests, differential harness, and as a fallback
   - maximizes portability and debuggability

2. **Accelerated backend**
   - uses audited native libs where possible
   - may rely on BEAM native interfaces

## 3. Native code options

### Option A: Erlang crypto for hashes + libsecp256k1 for signatures
Pros:
- SHA256 often hardware-accelerated via OpenSSL
- reduces custom native code footprint

Cons:
- algorithm availability can vary in FIPS or restricted builds
- performance characteristics depend on OTP/OpenSSL build

### Option B: Rust NIF wrapping libsecp256k1 + hashing
Pros:
- control over implementation
- can provide consistent behavior across platforms

Cons:
- NIF stability and build pipeline complexity

### Option C: External port process (Rust daemon)
Pros:
- crash isolation from BEAM
- easier to update independently

Cons:
- IPC overhead

## 4. Recommended path

- Start with a reference implementation sufficient for correctness tests.
- Introduce accelerated signature verification early (IBD depends on it).
- Keep NIF surface minimal:
  - verify_schnorr
  - verify_ecdsa
  - parse_pubkey
- Hashing can initially use BEAM crypto primitives; optimize later if needed.

## 5. Testing and assurance

- Unit tests with BIP vectors.
- Differential tests:
  - reference backend vs accelerated backend
- Fuzzing:
  - pubkey parsing
  - signature parsing
  - boundary inputs to NIF functions

## 6. Operational considerations

- Log backend selection on startup.
- Provide metrics:
  - signature verification QPS
  - cache hit rates
  - time spent in crypto
