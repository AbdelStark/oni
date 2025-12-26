# AI-assisted development guide

This guide is for using AI tools effectively on oni.

## 1. Principles

- Prefer small, composable pull requests.
- Never mix refactors with behavioral changes.
- Consensus code changes must be backed by tests and/or differential verification.
- When uncertain, add an explicit TODO and a failing test (if appropriate).

## 2. Workflow template (recommended)

1. Identify the subsystem and read its docs:
   - `oni_bitcoin`: codecs and primitives
   - `oni_consensus`: script/validation
   - `oni_storage`: DB + chainstate
   - `oni_p2p`: networking
2. Create/choose a backlog task (`ai/backlog/backlog.yml`).
3. Write or update a mini-spec in the relevant `docs/` file.
4. Implement with tests.
5. Add telemetry if runtime-visible.
6. Run `make ci`.

## 3. Task sizing rules

Good AI tasks:
- implement a single message codec + tests
- implement a single encoding (bech32m) + vectors
- implement one script opcode group + tests
- implement a DB record encoding + roundtrip tests

Bad AI tasks (too large):
- “implement full script interpreter”
- “implement mainnet IBD”
- “implement wallet”

Break large tasks into 1–3 day equivalent chunks (no time estimates in tickets; just scope).

## 4. Documentation standards

Every module should answer:
- What does it do?
- What invariants must hold?
- What errors can it return and why?
- What is the test coverage strategy?

## 5. Debuggability requirements

Any new subsystem must:
- emit structured logs for lifecycle events
- emit metrics for throughput and error counts
- have a deterministic reproduction path for failures
