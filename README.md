# oni

**oni** is a modern, production-grade implementation of the Bitcoin protocol written in **Gleam** (targeting Erlang/OTP).

[![CI](https://github.com/AbdelStark/oni/actions/workflows/ci.yml/badge.svg)](https://github.com/AbdelStark/oni/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

## Overview

oni aims to be a **fully validating, mainnet-compatible Bitcoin full node** with:
- **Consensus correctness** as the non-negotiable priority (Bitcoin Core is the reference)
- **Fault tolerance** via Erlang/OTP supervision trees
- **Production-grade observability**: structured logging, Prometheus metrics, health checks
- **AI-assisted development**: clear module boundaries and comprehensive documentation

## Project Status

> **Status: Active Development** — Milestones 0-5 complete. Node runs, responds to RPC, mines regtest blocks, and passes 52 E2E tests.

### Implementation Progress

| Package | Description | Status |
|---------|-------------|--------|
| `oni_bitcoin` | Primitives, serialization, encoding | ✅ Implemented |
| `oni_consensus` | Script engine, validation, sighash | ✅ Implemented |
| `oni_storage` | UTXO set, block index, chainstate | ✅ Implemented |
| `oni_p2p` | P2P networking, peer management | ✅ Implemented |
| `oni_rpc` | JSON-RPC server, HTTP interface | ✅ Implemented |
| `oni_node` | OTP application, orchestration | ✅ Implemented |

See [STATUS.md](STATUS.md) for detailed implementation status.

## Features

### Implemented
- **Bitcoin primitives**: Transactions, blocks, scripts, addresses (P2PKH, P2SH, Bech32/Bech32m)
- **Script interpreter**: Full opcode support including OP_CHECKLOCKTIMEVERIFY (BIP65), OP_CHECKSEQUENCEVERIFY (BIP112)
- **Signature verification**: secp256k1 NIF with ECDSA and Schnorr signing/verification
- **Sighash computation**: Legacy, BIP143 (SegWit), and BIP341 (Taproot)
- **Validation**: Stateless and contextual transaction/block validation
- **Storage**: In-memory and DETS persistent backends, UTXO set with connect/disconnect block
- **P2P foundation**: Message framing, compact blocks (BIP152), Erlay (BIP330), v2 transport (BIP324)
- **RPC server**: JSON-RPC 2.0 HTTP server with authentication and rate limiting
- **Mining RPC**: `generatetoaddress` and `generate` for regtest block production
- **Node**: OTP application that runs and responds to RPC calls
- **Operations**: Prometheus metrics, structured logging, health endpoints
- **E2E Testing**: 52 comprehensive regtest tests running in CI

### Next Steps
- Persistent block storage backend
- Headers-first IBD synchronization
- Full mainnet sync capability (Milestone 6)

## Quick Start

### Prerequisites
- Erlang/OTP 26+ (27.2 recommended)
- Gleam 1.6.2+

### Build and Test
```sh
# Format, typecheck, and test all packages
make ci

# Run individual commands
make fmt       # Format code
make check     # Type check
make test      # Run tests
make build     # Build all packages
```

### Run Node
```sh
# Mainnet (default)
make run

# Testnet
make run-testnet

# Regtest (for development)
make run-regtest
```

## Repository Structure

```
oni/
├── packages/           # Gleam packages (monorepo)
│   ├── oni_bitcoin/    # Primitives + serialization
│   ├── oni_consensus/  # Script engine + validation
│   ├── oni_storage/    # Block store + UTXO DB
│   ├── oni_p2p/        # P2P networking
│   ├── oni_rpc/        # JSON-RPC server
│   └── oni_node/       # OTP application
├── docs/               # Architecture and specifications
├── plan/               # Implementation roadmap
├── ai/                 # AI development guidance
├── test_vectors/       # Bitcoin Core test vectors
├── scripts/            # Automation scripts
├── monitoring/         # Prometheus + Grafana configs
└── deploy/             # Deployment configurations
```

## Documentation

### Getting Started
- [PRD.md](PRD.md) — Product requirements
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — System design
- [docs/CONSENSUS.md](docs/CONSENSUS.md) — Consensus rules

### Development
- [ai/CLAUDE.md](ai/CLAUDE.md) — AI development instructions
- [CONTRIBUTING.md](CONTRIBUTING.md) — Contribution guidelines
- [plan/IMPLEMENTATION_PLAN.md](plan/IMPLEMENTATION_PLAN.md) — Development phases

### Operations
- [docs/OPERATIONS.md](docs/OPERATIONS.md) — Operational runbook
- [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md) — Deployment guide
- [docs/TELEMETRY.md](docs/TELEMETRY.md) — Observability setup

## Design Principles

1. **Correctness over cleverness** — No micro-optimizations before correctness is proven
2. **Determinism** — Consensus execution must be deterministic across runs
3. **Bounded resources** — Every external input has strict bounds
4. **Separation of concerns** — Consensus, policy, and P2P are cleanly separated
5. **Observability first** — Telemetry is a first-class deliverable

## Non-Goals (initially)

- Altcoin / non-Bitcoin consensus variants
- GUI wallet
- Lightning node (may be an integration target later)
- Mining pool / stratum server

## Testing

```sh
# Run all tests
make test

# Run with test vectors
make test-vectors

# Run differential tests against Bitcoin Core
make test-differential
```

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for development setup and contribution guidelines.

## License

MIT License — see [LICENSE](LICENSE) for details.

## Acknowledgments

- **Bitcoin Core** — The reference implementation
- **rust-bitcoin** — Design inspiration for modularity
- **Gleam** — The language enabling this implementation
