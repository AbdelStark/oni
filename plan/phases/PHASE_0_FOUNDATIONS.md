# Phase 0: Foundations

## Goal
Create a disciplined engineering environment for a security-critical system.

## Deliverables
- Toolchain pinned and documented
- CI green on formatting, typecheck, unit tests
- AI-agent workflow and backlog system
- Supply chain controls (SBOM, dependency policy)
- Initial scaffolding packages exist

## Work packages

### 0.1 Toolchain
- Pin Erlang/OTP and Gleam versions (`.tool-versions`)
- Document supported platforms and how to install toolchain
- Decide on minimum OTP version (ADR)

### 0.2 Repo automation
- `Makefile`:
  - fmt, fmt-check
  - check (warnings-as-errors)
  - test
  - clean
- Optional:
  - `scripts/` for benches, fuzz, integration harness
  - pre-commit hooks

### 0.3 CI workflow
- GitHub Actions:
  - install toolchain
  - run `make ci`
  - cache dependencies/build outputs where safe

### 0.4 AI-agent readiness
- root-level `CLAUDE.md` and `AGENTS.md`
- `ai/skills/*`
- `ai/backlog/backlog.yml` + template
- `ai/STYLE_GUIDE.md` and repo map

### 0.5 Supply chain baseline
- SBOM workflow (CI)
- dependency review policy documented
- license compatibility tracking

## Acceptance criteria
- A clean checkout passes `make ci`.
- Contributors understand where to add tasks and how to run tests.
