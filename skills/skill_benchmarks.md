# Skill: Benchmarking and performance regression control

## Goal
Maintain performance while preserving correctness.

## Bench types
- Microbench (pure functions)
  - hashing, encoding, varint
  - signature verify
  - script opcode groups
- Component bench
  - UTXO DB lookups
  - block connect/disconnect
- End-to-end
  - regtest sync pipeline throughput

## Steps
1. Add a benchmark harness under `scripts/bench.sh` or `packages/*/bench/`.
2. Keep inputs deterministic:
   - fixed corpus of txs/blocks
   - fixed random seeds
3. Record results:
   - store baseline summaries in `benchmarks/` as JSON
4. Add CI gating:
   - smoke benchmark on PR (fast)
   - full benchmark on nightly

## Gotchas
- Avoid noisy metrics (run multiple iterations, report median).
- Ensure benchmarks don’t accidentally include logging overhead.
- Separate consensus correctness tests from performance tests.

## Acceptance checklist
- [ ] Benchmarks reproducible across runs on same machine
- [ ] Baseline stored and easy to compare
- [ ] Perf regressions caught before release
