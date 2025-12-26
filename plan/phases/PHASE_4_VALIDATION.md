# Phase 4: Consensus validation

## Goal
Implement block and transaction validation rules and expose stable validation entrypoints.

## Deliverables
- Tx stateless validation
- Tx contextual validation (UTXO + script checks)
- Block header validation (PoW/difficulty/time/versionbits)
- Block body validation (merkle, witness commitment, weight)
- Stable error taxonomy

## Work packages
- Validate tx structure and amounts
- Validate locktime/sequence rules
- Implement merkle root check
- Implement witness commitment check
- Difficulty adjustment and PoW verification
- ConnectBlock semantics integration points (with storage)

## Acceptance criteria
- Differential tests vs Bitcoin Core for a curated corpus.
- Stable error classifications used by higher layers (mempool, p2p).
