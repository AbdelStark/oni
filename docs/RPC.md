# RPC & operator interfaces

oni exposes operational functionality through:
- JSON-RPC over HTTP (primary)
- CLI tools (human-friendly)

## 1. Goals

- Familiar interface for Bitcoin operators and integrations.
- Secure-by-default (auth required, safe bind addresses, rate limits).
- High observability and debuggability.

## 2. RPC API surface

oni should aim for a Bitcoin Core-compatible subset first, then expand.

### 2.1 Minimum required RPC methods

Chain / node:
- `getblockchaininfo`
- `getnetworkinfo`
- `getpeerinfo`
- `getblockcount`
- `getbestblockhash`
- `getblockhash`
- `getblockheader`
- `getblock`
- `getchaintips`
- `stop`

Transactions:
- `sendrawtransaction`
- `getrawtransaction` (if txindex enabled; otherwise limited)
- `decoderawtransaction`

Mempool:
- `getmempoolinfo`
- `getrawmempool`

Diagnostics:
- `getrpcinfo`
- `uptime`

### 2.2 Optional / later
- `gettxoutsetinfo`
- `dumptxoutset`
- `verifychain`
- wallet RPCs (if wallet package enabled)

## 3. Auth and access control

- Default: bind to localhost only.
- Require authentication for all endpoints.
- Support:
  - cookie auth (local)
  - static username/password (operator-managed)
  - token auth (optional)
- Per-method ACL:
  - read-only vs admin
- Rate limiting by:
  - IP
  - auth identity
  - method

## 4. Metrics and health endpoints

Expose separately from JSON-RPC (to avoid auth coupling), but still secure:
- `/healthz` — liveness
- `/readyz` — readiness (DB ok, chainstate ok)
- `/metrics` — Prometheus scrape endpoint (optional)

## 5. Error model

- Stable error codes and messages.
- Never leak secrets in error messages.
- Provide request IDs for correlation with logs/traces.

## 6. CLI

Provide `oni` CLI:
- `oni node start`
- `oni node status`
- `oni rpc <method> [args]`
- `oni decode tx|block <hex>`
- `oni keys` (optional tooling)

CLI must:
- read config consistently
- support env overrides
- support JSON output for scripting
