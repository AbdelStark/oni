# Differential testing vs Bitcoin Core

Differential testing compares oni’s behavior to Bitcoin Core for the same inputs.

## 1. Why it matters

Consensus divergence is the largest existential risk for this project.
Differential tests provide continuous evidence that oni matches Bitcoin Core for covered cases.

## 2. Modes

### 2.1 Offline vectors
- Use known vectors:
  - tx_valid / tx_invalid
  - script vectors
  - block vectors
- Run them in oni and compare expected outcomes.

### 2.2 Live oracle
- Run a local bitcoind (regtest or testnet) as an oracle:
  - submit txs/blocks
  - observe accept/reject
  - compare with oni validation results

## 3. Harness design

- Keep harness external to consensus code.
- Store corpus artifacts with provenance.
- Categorize differences:
  - consensus mismatch (bug)
  - policy mismatch (expected)
  - unknown (investigate)

## 4. CI strategy

- PR CI: small differential smoke suite.
- Nightly: larger differential suite + longer fuzz runs.

## 5. Reporting

- On failure, output:
  - artifact hash
  - minimal reproduction steps
  - oni error classification
  - bitcoind outcome and logs
