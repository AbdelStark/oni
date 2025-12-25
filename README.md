# oni

**oni** is a modern, production-grade implementation of the Bitcoin protocol written in **Gleam** (targeting Erlang/OTP).  
This repository is a **project blueprint**: it contains the PRD, architecture, an end‑to‑end implementation plan, and AI‑friendly agentic docs to support large-scale, high-assurance development.

## Goals

- Full Bitcoin protocol implementation compatible with **mainnet**
- Consensus correctness as the non-negotiable priority (Bitcoin Core is the reference)
- High performance and scalability (IBD, mempool, signature verification)
- Battle-tested robustness: fault tolerance via OTP supervision, strict resource controls, defensive networking
- First-class operations: structured logging, metrics, tracing, profiling, health checks
- Excellent developer experience: reproducible builds, deterministic test vectors, fuzzing, benchmarks, automation
- AI-assisted development friendliness: clear module boundaries, task decompositions, prompts, “skills” playbooks

## Non-goals (initially)

- Altcoin / non-Bitcoin consensus variants
- GUI wallet
- Lightning node (may be an integration target later)

## Repository layout

- `PRD.md` – product requirements
- `plan/` – implementation plan, milestones, quality gates, risks
- `docs/` – architecture, subsystem specs, security, telemetry, testing, performance
- `ai/` – agent instructions (CLAUDE.md, AGENTS.md) + skill playbooks + backlog
- `packages/` – monorepo packages (Gleam), with local path dependencies
- `scripts/` – automation scripts for CI, test vector syncing, benchmarking, releases
- `.github/` – CI workflows and templates

## Quick start (scaffolding only)

This repository ships with minimal Gleam package scaffolding so the structure is concrete.
You can run a placeholder entrypoint today:

```sh
cd packages/oni_node
gleam run
```

## Next step

Read these in order:

1. `PRD.md`
2. `docs/ARCHITECTURE.md`
3. `plan/IMPLEMENTATION_PLAN.md`
4. `ai/CLAUDE.md` + `ai/AGENTS.md`

---
**Status:** design + planning complete; implementation is expected to follow the plan.
