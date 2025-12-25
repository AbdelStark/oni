# P2P networking specification (target)

This document defines the target behavior for oni’s P2P subsystem.

## 1. Goals

- Interoperate with modern Bitcoin mainnet peers.
- Be robust under adversarial peers (DoS-resistance).
- Provide high-throughput relay and IBD without sacrificing correctness.
- Ensure clear observability: per-peer metrics, per-message counters, latency histograms.

## 2. P2P layers

### 2.1 Transport and framing
- TCP sockets with configurable timeouts and keepalive.
- Message envelope:
  - network magic
  - command string
  - payload length
  - checksum (first 4 bytes of sha256d(payload))
  - payload bytes

### 2.2 Handshake and feature negotiation
- version/verack exchange
- feature flags (services bits)
- user agent string, start height, relay flag
- protect against fingerprinting and unsafe defaults

### 2.3 Message codec layer
- Strict decoding with bounded allocations.
- Reject oversized payloads before allocation.
- Avoid incremental “string concat” during parsing; use binaries/BitArray.

### 2.4 Behavior layer
- Address manager and discovery
- Inventory relay and request scheduling
- Peer scoring + discouragement/banning
- Connection management (inbound/outbound quotas)

## 3. Peer lifecycle

### States
1. `Connecting` — TCP connect attempt, handshake not done.
2. `Handshaking` — version/verack in progress.
3. `Ready` — fully negotiated.
4. `Disconnecting` — shutdown initiated.

### Per-peer process model
- Each peer connection runs as its own actor/process.
- The peer process owns:
  - socket
  - send queue (bounded)
  - recv buffer
  - per-peer stats (bytes in/out, message counts)
- The Peer Manager owns global policy decisions (slots, bans).

## 4. Resource control and DoS defense

### Limits
- Max inbound peers
- Max outbound peers
- Max orphan transactions
- Max per-peer in-flight requests
- Max message payload sizes
- Per-message CPU budgets (soft), enforced by yielding and backpressure

### Misbehavior scoring
- Non-fatal protocol violations increment score.
- Score triggers “discourage” and then “ban” with duration.
- Banlist persisted on disk.

### Backpressure
- If validation is behind, P2P should:
  - stop requesting more blocks
  - lower tx relay throughput
  - disconnect abusive peers

## 5. Relay strategy

- Use inv/getdata and headers-first for IBD.
- Separate announcement processing from download scheduling.
- Protect against inv storms by:
  - inventory filters
  - per-peer rate limits
  - cache of recently seen items

## 6. IBD strategy

- Headers-first download:
  1. Sync headers to tip candidate chain.
  2. Download blocks in windows with bounded parallelism.
  3. Validate blocks and connect to chainstate.

- Compact blocks (future):
  - implement once baseline correctness is stable

## 7. Telemetry

P2P must emit:
- per-peer message counts by command
- bytes in/out
- handshake duration
- disconnect reasons
- block download latency
- tx relay latency
- global peer counts (inbound/outbound)

## 8. Operator controls

Expose via RPC:
- list peers
- disconnect peer
- addnode / connect
- ban / unban
- network totals
