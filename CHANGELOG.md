# Changelog

All notable changes to oni are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

#### Core Infrastructure
- Complete 6-package monorepo structure (oni_bitcoin, oni_consensus, oni_storage, oni_p2p, oni_rpc, oni_node)
- CI/CD pipeline with GitHub Actions (format, typecheck, test, docs)
- Multi-OTP version testing (OTP 26.2 and 27.2)
- Makefile automation for common development tasks
- Docker support with multi-stage builds
- Systemd service units for mainnet and testnet

#### oni_bitcoin (Primitives)
- Core hash types: Hash256, Txid, Wtxid, BlockHash
- Amount type with 21M BTC cap enforcement
- Complete transaction and block type definitions
- Network parameters for mainnet, testnet, regtest, signet
- Encoding: hex, Base58Check, Bech32/Bech32m
- CompactSize/varint encoding
- Consensus serialization (legacy and witness transactions)
- P2P message type definitions
- Output descriptor parsing

#### oni_consensus (Consensus)
- Full Bitcoin opcode table and parser
- Script execution engine with stack operations
- Arithmetic, logic, and cryptographic operations
- OP_CHECKSIG and OP_CHECKMULTISIG support
- OP_CHECKLOCKTIMEVERIFY (BIP65) implementation
- OP_CHECKSEQUENCEVERIFY (BIP112) implementation
- Control flow operations (IF/ELSE/ENDIF/NOTIF)
- Sighash type definitions (ALL, NONE, SINGLE, ANYONECANPAY)
- Merkle root and witness commitment computation
- Transaction stateless validation
- Block filter support (BIP157)
- Mempool validation and policy separation
- Fee estimation framework
- Soft fork activation tracking
- Signature and script caching
- Schnorr batch verification structure

#### oni_storage (Storage)
- UTXO view interface with batch operations
- Coin type with coinbase maturity tracking
- Block index with chain navigation
- Ancestor and common ancestor lookup algorithms
- Chainstate manager
- Connect/disconnect block with UTXO updates
- Undo data generation and application
- Block and header stores (in-memory)
- DB backend interface abstraction
- AssumeUTXO snapshot support structure
- Pruning mode support
- Transaction index

#### oni_p2p (Networking)
- P2P message framing and serialization
- Version handshake protocol
- Address manager with persistence
- Peer reputation scoring system
- Ban manager with resource limits
- Rate limiting framework
- Relay scheduling
- Header and block sync state machines
- Compact blocks (BIP152)
- Erlay transaction relay (BIP330)
- V2 transport encryption (BIP324)
- Network simulation testing

#### oni_rpc (RPC)
- JSON-RPC 2.0 server implementation
- HTTP server with proper protocol handling
- Authentication and access control
- Rate limiting
- RPC service handlers

#### oni_node (Application)
- OTP application structure
- Supervision tree with fault tolerance
- Configuration management
- CLI interface
- Health check endpoints
- Prometheus metrics integration
- Structured logging with redaction
- Event routing system
- IBD coordinator
- Persistent chainstate management
- Reorg handler
- Parallel validation framework
- Mempool manager
- Basic wallet functionality
- Benchmarking utilities
- Network simulation for testing

#### Documentation
- Comprehensive PRD (Product Requirements Document)
- Architecture documentation
- Consensus specification
- P2P protocol documentation
- Storage design documentation
- RPC API specification
- Operations runbook
- Deployment guide
- Telemetry documentation
- Security hardening guide
- Performance optimization guide
- Testing strategy documentation
- AI development guides (CLAUDE.md, AGENTS.md)
- Skill playbooks for common development tasks

#### Testing
- 33 test files across all packages
- Script execution tests with BIP65/BIP112 coverage
- Validation tests for transactions and blocks
- Storage tests for UTXO operations
- P2P message parsing tests
- RPC handler tests
- E2E integration tests
- Network simulation tests
- Fuzz testing framework

### Changed
- N/A (initial release)

### Deprecated
- N/A (initial release)

### Removed
- N/A (initial release)

### Fixed
- N/A (initial release)

### Security
- Bounded resource allocation in all parsers
- Strict input validation at network boundaries
- Rate limiting on RPC and P2P interfaces
- Authentication required for RPC access

---

## Version History

No releases yet. Project is under active development toward v0.1.0.

### Planned: v0.1.0 (Alpha)
- Complete signature verification
- Headers-first sync with regtest
- Basic integration tests passing

### Planned: v0.2.0 (Beta)
- Persistent storage backend
- Mainnet sync capability
- Performance benchmarks

### Planned: v1.0.0 (Production)
- Full mainnet compatibility
- Comprehensive fuzzing
- Multi-day soak tests passing
- Production deployment documentation
