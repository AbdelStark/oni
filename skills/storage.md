# Storage and Chainstate Patterns

UTXO set, block index, and persistence.

## Location

- Package: `packages/oni_storage`
- Key files: `utxo.gleam`, `chainstate.gleam`, `db_backend.gleam`

## Architecture

### UTXO Set
- Key: OutPoint (txid + vout index)
- Value: Coin (amount, script, height, coinbase flag)
- Operations: lookup, add, remove, batch

### Block Index
- Tracks all known block headers
- Chain navigation (tip, ancestor lookup)
- Fork tracking and common ancestor

### Chainstate
- Current tip
- UTXO view
- Connect/disconnect block operations

## Persistence

### DETS Backend
- Erlang built-in disk storage
- Tables: `utxo`, `block_index`, `chainstate`, `undo`
- Write-through caching via unified_storage

### Undo Data
- Stores spent coins for each block
- Required for block disconnection (reorg)
- Prunable after sufficient confirmations

## Operations

### Connect Block
1. Validate transactions against UTXO set
2. Mark spent outputs
3. Add new outputs
4. Store undo data
5. Update chain tip

### Disconnect Block
1. Load undo data
2. Remove created outputs
3. Restore spent outputs
4. Update chain tip

## Pitfalls

| Issue | Detail |
|-------|--------|
| Coinbase maturity | 100 blocks before spendable |
| Undo data | Must be created before connect |
| Reorg depth | Keep undo data for max reorg |
| DETS limits | Files can grow large |

## Code References

- UTXO: `packages/oni_storage/src/utxo.gleam`
- Chainstate: `packages/oni_storage/src/chainstate.gleam`
- Backend: `packages/oni_storage/src/db_backend.gleam`
