# Risk register

This document tracks major risks and mitigations.

## R1 — Consensus divergence from Bitcoin Core
- **Impact:** catastrophic (node forks or rejects valid chain)
- **Likelihood:** high without strict testing
- **Mitigations:**
  - differential tests vs Bitcoin Core
  - use upstream test vectors
  - strict separation of consensus and policy
  - code owner review for consensus-critical modules

## R2 — Cryptography performance and safety on BEAM
- **Impact:** high (IBD too slow, or runtime crashes via unsafe NIF)
- **Likelihood:** medium
- **Mitigations:**
  - clean crypto interface with reference + accelerated implementations
  - isolate NIF boundaries; fuzz them
  - avoid scheduler blocking; use dirty NIF or external processes if necessary
  - benchmark continuously

## R3 — Storage engine portability / build complexity
- **Impact:** high (hard to install, unstable, data loss)
- **Likelihood:** medium
- **Mitigations:**
  - evaluate DB engines early with realistic workloads
  - provide fallback engine for development (even if slower)
  - keep DB schema versioned and migration-safe

## R4 — DoS and resource exhaustion
- **Impact:** high (node unusable)
- **Likelihood:** high on public network
- **Mitigations:**
  - strict bounds everywhere (payload sizes, queue sizes)
  - rate limiting
  - peer scoring and bans
  - backpressure between subsystems

## R5 — Operational invisibility (hard to debug)
- **Impact:** medium-high
- **Likelihood:** medium
- **Mitigations:**
  - telemetry as first-class deliverable
  - structured logs and trace correlation IDs
  - standardized dashboards and alert rules

## R6 — Complexity of wallet scope
- **Impact:** medium (scope creep)
- **Likelihood:** high if attempted too early
- **Mitigations:**
  - keep wallet optional and isolated package
  - prioritize full node correctness first
  - implement PSBT-based signer separate from chainstate
