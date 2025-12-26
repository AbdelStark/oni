# Policy and standardness

Policy defines what the node accepts into its mempool and relays, independent of consensus.

## 1. Principles

- Never reject a valid block due to policy.
- Policy is configurable and may differ across nodes.
- Policy must be explicit and observable (rejection reasons emitted).

## 2. Mempool admission

Planned policy checks include:
- minimal feerate (configurable)
- standard script forms (P2PKH, P2SH, SegWit v0, Taproot)
- standardness limits (sigops, script size, tx size)
- RBF rules
- ancestor/descendant limits (package policy)

## 3. Eviction

- Mempool is bounded by size.
- Eviction prefers lowest feerate packages while respecting dependencies.

## 4. Relay

- Respect peer feefilter and relay flags.
- Avoid re-announcing items too frequently.
- DoS protection: inv storms and tx floods.
