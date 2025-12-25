# Roadmap (phase ordering)

This roadmap summarizes the order of major milestones.

> Note: This roadmap intentionally avoids time estimates. Progress is driven by correctness and quality gates.

## Milestone 0 — Project foundations
- CI, tooling, agent docs, security baseline.

## Milestone 1 — oni_bitcoin (primitives)
- canonical serialization, hashing interfaces, address encodings.

## Milestone 2 — oni_consensus (script + validation)
- script interpreter + sighash + segwit/taproot.

## Milestone 3 — oni_storage (chainstate)
- UTXO DB, block store, reorg, crash recovery.

## Milestone 4 — oni_p2p (networking)
- handshake, message framing, basic relay.

## Milestone 5 — End-to-end regtest node
- sync and reorg in regtest; functional RPC + CLI.

## Milestone 6 — End-to-end mainnet node
- IBD to tip in controlled environment; stable sync.

## Milestone 7 — Hardening and performance
- fuzz campaigns, soak tests, benchmark regression gates.

## Milestone 8 — Optional features
- wallet, indexers, compact blocks, snapshots.
