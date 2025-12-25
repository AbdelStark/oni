# Skill: Chainstate storage and reorg correctness

## Goal
Implement chainstate persistence with crash safety and reorg support.

## Where
- Package: `packages/oni_storage`
- Modules (planned):
  - `oni_storage/utxo/*`
  - `oni_storage/blockstore/*`
  - `oni_storage/chainstate/*`

## Steps
1. Define DB schema with explicit version
2. Implement UTXO encoding and lookup
3. Implement ConnectBlock
   - read inputs
   - update UTXO set
   - write undo data
4. Implement DisconnectBlock using undo
5. Add crash recovery strategy
   - atomic commits or WAL
6. Add tests
   - connect/disconnect cycles
   - randomized reorg scenarios
   - simulated crash mid-commit

## Gotchas
- Reorg correctness requires deterministic undo data.
- DB compaction can cause latency spikes; telemetry required.
- Cache invalidation during reorg.

## Acceptance checklist
- [ ] Reorg tests pass
- [ ] Crash recovery test passes
- [ ] DB schema versioning and migration hooks exist
- [ ] Telemetry for DB latency and cache hit rate
