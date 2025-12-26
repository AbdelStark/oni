# Phase 9: RPC and CLI

## Goal
Make the node operable and debuggable.

## Deliverables
- JSON-RPC server with auth, ACL, rate limits
- Minimum RPC methods
- CLI for start/status and raw decode tools
- Health and metrics endpoints integrated

## Work packages
- HTTP server selection and integration
- Auth modes (cookie + userpass)
- Method router and error codes
- Core methods for chain/peers/mempool/tx submit
- CLI with config handling

## Acceptance criteria
- Operators can run node and query status.
- Security defaults: bind localhost + auth required.
