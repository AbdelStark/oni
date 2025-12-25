# Phase 5: Storage and chainstate

## Goal
Persist chainstate and enable reorg-safe validation and sync.

## Deliverables
- DB backend selected and integrated
- Block store (files or DB)
- Block index and chainwork selection
- UTXO DB + caching
- Undo data + reorg correctness
- Crash recovery and migrations

## Work packages
- DB abstraction layer + one backend
- Schema versioning and migration hooks
- Blockstore implementation
- Block index metadata storage
- UTXO record encoding and read/write batching
- Undo record format
- Chainstate process API and invariants

## Acceptance criteria
- Connect/disconnect tests
- Crash recovery tests
- Pruning mode (optional) documented and safe
