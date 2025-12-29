# Contributing to oni

Thank you for your interest in contributing to oni! This project aims to build a production-grade Bitcoin full node in Gleam, and contributions of all kinds are welcome.

## Quick Start

```sh
# Clone the repository
git clone https://github.com/AbdelStark/oni.git
cd oni

# Install dependencies (via asdf or mise)
asdf install  # or: mise install

# Run the full CI check
make ci
```

## Ground Rules

### 1. Consensus Correctness is Sacred

Bitcoin Core is the reference implementation. If you're unsure about consensus behavior:
- Stop and investigate
- Locate the upstream rule or test vector
- Implement with tests and differential validation

**Never guess consensus behavior.**

### 2. Keep PRs Focused

- One logical change per PR
- Small, reviewable changes preferred
- Split large features into incremental PRs

### 3. Test Everything

- Unit tests for new functionality
- Integration tests for cross-module changes
- Consensus code requires test vectors

### 4. Separation of Concerns

Maintain strict boundaries between:
- **Consensus** (`oni_consensus`) — validation rules
- **Policy** — mempool and relay rules
- **P2P** (`oni_p2p`) — network protocol

Consensus code must not import policy or P2P modules.

---

## Development Setup

### Prerequisites

| Tool | Version | Installation |
|------|---------|--------------|
| Erlang/OTP | 27.2 | `asdf install erlang 27.2` |
| Gleam | 1.6.3 | `asdf install gleam 1.6.3` |

Versions are pinned in `.tool-versions` for reproducibility.

### Common Commands

```sh
# From repository root
make fmt        # Format all packages
make fmt-check  # Verify formatting
make check      # Type check all packages
make test       # Run all tests
make build      # Build all packages
make ci         # Full CI pipeline

# Per-package commands
cd packages/oni_node
gleam test      # Test single package
gleam run       # Run the node
gleam docs build # Generate docs
```

### Project Structure

```
packages/
├── oni_bitcoin/    # Primitives, serialization, encoding
├── oni_consensus/  # Script engine, validation rules
├── oni_storage/    # UTXO set, block storage
├── oni_p2p/        # P2P networking
├── oni_rpc/        # JSON-RPC server
└── oni_node/       # OTP application
```

---

## Code Style

### Formatting

- Use `gleam format` exclusively
- Do not hand-format code
- CI enforces formatting

### Type Annotations

- Explicit types at module boundaries (public functions)
- Type aliases for domain concepts
- Use custom types over primitives where meaningful

### Error Handling

```gleam
// Good: Return Result for fallible operations
pub fn parse_transaction(bytes: BitArray) -> Result(Transaction, ParseError)

// Bad: Panic on invalid input
pub fn parse_transaction(bytes: BitArray) -> Transaction  // may crash!
```

### Parsing Safety

- Parsing must be **total** — never crash on malformed input
- Enforce size limits before allocation
- Return descriptive errors

### Naming Conventions

- Functions: `snake_case`
- Types: `PascalCase`
- Modules: `snake_case`
- Constants: `snake_case` (Gleam convention)

---

## Testing Requirements

### All Code

- Unit tests for new functionality
- Tests must be deterministic
- Document test purpose in comments if non-obvious

### Consensus-Critical Code

1. **Test vectors** — valid and invalid cases
2. **Fuzz targets** — update or add new targets
3. **Differential tests** — compare against Bitcoin Core

### Test Organization

```
packages/oni_consensus/
├── src/
│   └── oni_consensus.gleam
└── test/
    ├── oni_consensus_test.gleam    # Unit tests
    ├── differential_test.gleam      # Differential tests
    └── fees_test.gleam              # Feature-specific tests
```

---

## Commit Messages

Follow conventional commits:

```
<type>(<scope>): <description>

[optional body]

[optional footer]
```

Types:
- `feat`: New feature
- `fix`: Bug fix
- `docs`: Documentation
- `refactor`: Code change that doesn't add feature or fix bug
- `test`: Adding tests
- `chore`: Maintenance tasks

Examples:
```
feat(consensus): implement OP_CHECKSEQUENCEVERIFY

Add BIP112 support with proper version and sequence handling.

Closes #42
```

```
fix(storage): prevent UTXO double-spend on reorg

The disconnect_block function wasn't properly restoring
spent outputs when handling deep reorgs.
```

---

## Pull Request Process

### Before Submitting

- [ ] Code compiles: `make check`
- [ ] Tests pass: `make test`
- [ ] Formatting correct: `make fmt-check`
- [ ] Documentation updated if needed
- [ ] Commit messages follow conventions

### PR Description

Include:
- What changed and why
- How to test
- Related issues
- Breaking changes (if any)

### Review Process

1. CI must pass
2. At least one maintainer approval
3. Consensus changes require explicit review
4. Address all review comments

---

## Adding Dependencies

New dependencies require:

1. **Justification** — Why is this needed?
2. **License check** — Must be MIT/Apache-2.0 compatible
3. **Maintenance health** — Active project, responsive maintainers
4. **Security review** — No known vulnerabilities
5. **Maintainer approval**

Document in PR why the dependency is necessary and alternatives considered.

---

## Documentation

### Code Documentation

- Document public functions with `///` comments
- Explain non-obvious behavior
- Link to relevant BIPs for consensus code

### Architecture Documentation

- Update `docs/` for architectural changes
- Add ADR (Architecture Decision Record) for significant decisions
- Keep README current

---

## Getting Help

- **Questions**: Open a GitHub Discussion
- **Bugs**: Open a GitHub Issue with reproduction steps
- **Security**: See [SECURITY.md](SECURITY.md) for private disclosure

---

## Recognition

Contributors are recognized in:
- Git commit history
- Release notes for significant contributions
- CONTRIBUTORS file for major contributions

Thank you for helping make oni a robust Bitcoin implementation!
