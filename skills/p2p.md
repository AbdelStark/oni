# P2P Networking Patterns

Bitcoin P2P protocol and sync.

## Location

- Package: `packages/oni_p2p`
- Key files: `message.gleam`, `sync.gleam`, `peer.gleam`

## Message Flow

### Handshake
1. Connect to peer
2. Send `version` message
3. Receive `version` response
4. Exchange `verack`
5. Connection established

### Header Sync (IBD)
1. Send `getheaders` with locator
2. Receive `headers` (up to 2000)
3. Validate headers (PoW, timestamps, chain continuity)
4. Repeat until tip

### Block Download
1. Request blocks with `getdata`
2. Distribute requests across peers
3. Track in-flight requests
4. Detect stalls, reassign to other peers
5. Connect blocks in order

## Message Types

| Message | Purpose |
|---------|---------|
| `version` | Protocol negotiation |
| `verack` | Handshake acknowledgment |
| `inv` | Inventory announcement |
| `getdata` | Request specific items |
| `headers` | Block headers |
| `block` | Full block data |
| `tx` | Transaction |

## Pitfalls

| Issue | Detail |
|-------|--------|
| Message size | Max 4MB (32MB for block) |
| Checksum | SHA256d of payload, first 4 bytes |
| Services | Check peer services before requesting |
| Ban score | Track misbehavior, disconnect bad peers |

## Code References

- Message framing: `packages/oni_p2p/src/message.gleam`
- Sync coordinator: `packages/oni_p2p/src/sync.gleam`
- Address manager: `packages/oni_p2p/src/addrman.gleam`
