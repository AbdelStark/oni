# Phase 8: Mempool and policy

## Goal
Implement mempool admission, eviction, and tx relay.

## Deliverables
- Policy checks distinct from consensus
- Bounded mempool with eviction rules
- Orphan handling
- Relay integration with peer filters

## Work packages
- Policy validation pipeline using chainstate snapshots
- Indexes by fee rate and dependencies
- Eviction algorithm
- RBF handling baseline
- Tx relay and re-announcement rules

## Acceptance criteria
- Regtest policy scenarios pass.
- Telemetry includes acceptance/rejection breakdown.
