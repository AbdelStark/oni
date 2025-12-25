# Phase 7: IBD and sync

## Goal
Sync headers and blocks end-to-end and stay in sync.

## Deliverables
- Headers-first sync
- Block download scheduling with bounded parallelism
- Validation pipeline integration and backpressure
- Reorg handling during sync

## Work packages
- Header sync and chain selection
- Download window logic
- Request tracking and timeout/retry
- Integrate block validation and connect
- Telemetry: block/s, validation latency, DB latency

## Acceptance criteria
- Regtest sync and fork scenarios pass.
- Controlled environment mainnet sync succeeds.
