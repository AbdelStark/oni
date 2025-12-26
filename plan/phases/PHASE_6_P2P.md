# Phase 6: P2P foundation

## Goal
Interoperate with Bitcoin peers with strong DoS defenses and good telemetry.

## Deliverables
- Envelope parser and per-command limits
- Message codecs for core commands
- Handshake state machine
- Peer lifecycle management
- Address manager persistence

## Work packages
- Implement envelope codec
- Implement version/verack
- Implement inv/getdata/headers/getheaders
- Implement block and tx messages
- Implement peer manager policies and quotas
- Add fuzz targets for wire decoding

## Acceptance criteria
- Connects to testnet peers in a controlled harness.
- Survives malformed message fuzzing without crashes.
