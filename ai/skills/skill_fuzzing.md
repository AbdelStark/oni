# Skill: Fuzzing harnesses for oni

## Goal
Ensure no untrusted input can crash the node or trigger unbounded resource use.

## Targets to fuzz
- P2P message envelope decode
- Per-message payload decode (version, inv, headers, tx, block)
- Transaction and block parsers
- Script interpreter (including witness stacks)

## Approach
1. Define pure decode functions:
   - `decode(bytes) -> Result(T, DecodeError)`
2. Create a fuzz runner that:
   - generates random bytes
   - calls decode
   - asserts:
     - no crash
     - bounded runtime
3. Add corpus seeding:
   - valid vectors
   - known edge cases
4. Integrate in CI:
   - short “smoke fuzz” run on PR
   - longer runs on scheduled jobs

## What to watch for
- unbounded list creation based on attacker-controlled length prefixes
- quadratic parsing behavior
- decoding that copies large binaries repeatedly
- integer overflows in length calculations

## Acceptance checklist
- [ ] Fuzz target exists for each network boundary
- [ ] CI smoke fuzz runs deterministically
- [ ] Crash found → minimized and added as regression test
