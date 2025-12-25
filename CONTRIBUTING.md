# Contributing to oni

Thanks for contributing! oni is a Bitcoin implementation; correctness and security are the bar.

## 1. Ground rules

- Consensus changes require test vectors and differential validation.
- Keep PRs small and focused.
- Add tests for every new behavior.
- Keep modules cohesive and avoid cross-layer coupling (consensus vs policy vs p2p).

## 2. Development setup

### Prerequisites
- Erlang/OTP (pinned in `.tool-versions`)
- Gleam (pinned in `.tool-versions`)

### Common commands

From repo root:

```sh
make fmt
make test
make check
```

You can also run per package:

```sh
cd packages/oni_node
gleam test
gleam run
```

## 3. Code style

- Use `gleam format` and do not hand-format.
- Prefer explicit types at module boundaries.
- Avoid raising exceptions; return `Result` for fallible operations.
- Parsing must be total (never crash on malformed bytes).

## 4. Testing requirements

- Unit tests required for new functionality.
- Consensus-critical code requires:
  - vectors (valid + invalid)
  - fuzz target update or new target
  - differential tests vs Bitcoin Core where feasible

## 5. Adding dependencies

New dependencies require:
- justification
- license compatibility check
- maintenance health check
- approval by maintainers

## 6. Security issues

Please report security vulnerabilities privately. See `SECURITY.md`.
