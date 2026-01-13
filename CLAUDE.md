# CLAUDE.md

<prime_directive>
**Consensus correctness is sacred.**

Bitcoin Core is the reference implementation. Never guess consensus behavior.

If unsure:
1. Stop
2. Locate the upstream rule/test vector
3. Implement with tests and differential validation
</prime_directive>

<project>
**oni** — Production-grade Bitcoin full node in Gleam (Erlang/OTP).

Status: Milestones 0-5 complete. Milestone 6 near completion.
Tests: 915+ unit, 52 E2E regtest tests passing.
</project>

<commands>
```sh
make fmt        # Format all code
make check      # Type check all packages
make test       # Run all tests
make ci         # Full CI pipeline (fmt + check + test)

make run          # Run mainnet node
make run-testnet4 # Run testnet4 node
make run-regtest  # Run regtest node

make watch-ibd    # Monitor IBD progress
make node-status  # Check node via RPC
make node-logs    # View recent logs
```
</commands>

<packages>
```
packages/
├── oni_bitcoin    # Primitives + serialization
├── oni_consensus  # Script engine + validation
├── oni_storage    # UTXO set + chainstate
├── oni_p2p        # P2P networking
├── oni_rpc        # JSON-RPC server
└── oni_node       # OTP application
```
</packages>

<invariants>
1. **Parsing is total** — Never crash on malformed input
2. **Consensus is deterministic** — Same inputs = same outputs
3. **Resources are bounded** — No unbounded allocations
4. **Policy stays out of consensus** — Clean separation
5. **Tests prove correctness** — No consensus change without tests
</invariants>

<coding_rules>
- Use `Result` for fallible operations, never crash on expected failures
- Enforce size limits before allocation; cap all queues
- Consensus code must not import policy or P2P modules
- Avoid map iteration order for consensus-relevant logic
</coding_rules>

<definition_of_done>
- [ ] Unit tests exist and pass
- [ ] Docs updated (module purpose/invariants)
- [ ] Telemetry added where relevant
- [ ] Code formatted (`make fmt`)
- [ ] Type check passes (`make check`)
- [ ] Consensus changes include test vectors
</definition_of_done>

<pitfalls>
| Issue | Detail |
|-------|--------|
| Endianness | Bitcoin uses little-endian in many encodings |
| CompactSize | Edge cases at 0xFC/0xFD/0xFE/0xFF boundaries |
| Script numbers | Minimal encoding rules apply |
| Sighash | Preimage construction is subtle |
| Allocations | Always cap input sizes from network |
</pitfalls>

<resources>
| Resource | Location |
|----------|----------|
| Agent context | `AGENTS.md` |
| Harness (state tracking) | `.harness/` |
| Implementation status | `.harness/STATUS.md` |
| Milestones/roadmap | `.harness/milestones.md` |
| Task backlog | `.harness/backlog.yml` |
| Knowledge base | `.harness/knowledge/` |
| Architecture | `docs/ARCHITECTURE.md` |
| Consensus rules | `docs/CONSENSUS.md` |
| Test vectors | `test_vectors/` |
</resources>

<harness_usage>
The `.harness/` directory is the agent's persistent memory:

- **STATUS.md** — Implementation matrix (read before starting work)
- **milestones.md** — Progress tracking for long-running tasks
- **backlog.yml** — Task queue with acceptance criteria
- **errors.md** — Known issues and solutions
- **knowledge/** — Domain-specific playbooks

Update harness files as you work. Context is RAM, filesystem is state.
</harness_usage>

<workflow>
**Before starting:**
1. Read `.harness/STATUS.md` for current state
2. Check `.harness/backlog.yml` for existing tasks
3. Review `.harness/errors.md` for known issues

**While working:**
- Update backlog status as tasks progress
- Log errors and solutions to `errors.md`
- Reference knowledge base for domain patterns

**After completing:**
- Mark tasks done in backlog
- Update STATUS.md if implementation changed
- Add knowledge entries for new patterns discovered
</workflow>
