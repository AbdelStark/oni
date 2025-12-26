# Security

oni is a network-exposed, adversarially operated system. Security is a first-class requirement.

## 1. Threat model

### 1.1 Adversaries
- Internet peers attempting to:
  - crash the node
  - exhaust memory/CPU/disk
  - corrupt chainstate
  - cause incorrect validation (consensus failure)
  - deanonymize or fingerprint the operator
- Local attackers with limited access attempting to:
  - read secrets (RPC creds, wallet seeds)
  - tamper with data directory
- Supply-chain attackers attempting to:
  - introduce malicious dependencies
  - compromise build/release pipeline

### 1.2 Assets
- Correct chainstate (UTXO set, best chain)
- Node availability (uptime)
- Operator secrets (RPC creds, wallet keys)
- Operator privacy (network identity)
- Integrity of releases (artifact trust)

## 2. Security principles

- **Fail closed** on protocol decoding: reject malformed inputs early.
- **Bound everything**: memory, CPU, disk, queues, timeouts.
- **Crash isolation**: use OTP supervision; keep consensus state in an authoritative process.
- **Minimal privilege**: run as non-root; least privileges for data dir.
- **Defense in depth**: multiple validation layers, independent checks.

## 3. Network hardening

- Strict message size limits per command.
- Per-peer rate limits and inbound bandwidth caps.
- Handshake timeout and progressive backoff on reconnect.
- Ban/discourage policy for repeated misbehavior.
- Address manager poisoning defense:
  - limit new addr acceptance
  - prefer diverse buckets
  - persist to disk with sanity checks

## 4. Storage safety

- Checksums and versioning for DB entries where feasible.
- Crash-safe atomic connect/disconnect semantics.
- Detect and refuse to run on corrupted DB unless operator opts in to repair/reindex.

## 5. Cryptography

- Use well-audited crypto primitives:
  - secp256k1 for ECDSA/Schnorr
  - SHA256, tagged hashes
  - constant-time comparisons for secret material where applicable
- Avoid custom crypto unless unavoidable (e.g., RIPEMD160 implementation may be required for portability).

## 6. Wallet / secrets (if wallet enabled)

- Encrypt wallet at rest.
- In-memory secrets should be minimized and overwritten where possible.
- Never log secrets. Never send secrets over telemetry.

## 7. Supply chain

- Pin dependencies via lockfiles and CI enforcement.
- Maintain SBOM generation in CI.
- Dependency updates require review and test runs.
- Prefer vendoring small test vectors instead of runtime fetching.

## 8. Vulnerability disclosure

Create a `SECURITY.md` at repo root describing:
- how to report vulnerabilities
- supported versions
- response expectations

(See root `SECURITY.md` in this repo.)

## 9. Security testing

- Fuzz:
  - P2P message decoding
  - script interpreter and sighash
  - transaction and block parsing
- Differential tests vs Bitcoin Core.
- Static analysis and dependency scanning (CI).
