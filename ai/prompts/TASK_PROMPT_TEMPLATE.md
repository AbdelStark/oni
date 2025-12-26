# Task prompt template (for AI assistants)

Use this template when asking an AI assistant to implement a backlog task.

## Context
- Repo: oni
- Subsystem: <bitcoin|consensus|storage|p2p|rpc|node|ops|security>
- Task ID: <ID from ai/backlog/backlog.yml>
- Relevant docs:
  - <list docs/ files>

## Requirements
- Do not change consensus semantics without vectors and/or differential tests.
- Parsing must be total and bounded.
- Add unit tests (and fuzz/diff tests if boundary code).
- Add telemetry if runtime-visible.

## Deliverables
- Code changes
- Tests
- Doc updates
- Notes on tradeoffs

## Commands to run
- make fmt
- make check
- make test
