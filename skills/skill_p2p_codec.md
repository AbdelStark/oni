# Skill: P2P message codec & framing

## Goal
Implement P2P message encoding/decoding that is:
- interoperable,
- safe under hostile inputs,
- observable (metrics/logs).

## Where
- Package: `packages/oni_p2p`
- Modules (planned):
  - `oni_p2p/wire/*`
  - `oni_p2p/messages/*`

## Steps
1. Implement envelope parsing
   - magic, command, length, checksum, payload
2. Enforce bounds before allocation
   - per-command maximum payload size
3. Implement message codecs
   - version, verack
   - ping/pong
   - inv/getdata/notfound
   - headers/getheaders
   - block/tx
4. Integrate with per-peer process
   - bounded send queue
   - recv buffer management
5. Add fuzz target
   - feed random bytes into envelope parser and message dispatch

## Gotchas
- Checksum uses sha256d(payload), first 4 bytes.
- Command field padding and normalization.
- Large payloads (blocks) must stream or be bounded.

## Acceptance checklist
- [ ] Roundtrip tests per message
- [ ] Malformed input tests (short reads, wrong checksum, oversize)
- [ ] Fuzz target exists
- [ ] Metrics: per-command counts + bytes in/out
