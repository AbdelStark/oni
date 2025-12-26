# Skill: Security review checklist for changes

## When to use
Any change that touches:
- consensus validation
- P2P parsing/handling
- storage formats and migrations
- RPC auth and access control
- cryptographic interfaces

## Checklist
- [ ] Inputs are bounded (size limits, counts, timeouts).
- [ ] Parsing is total (Result; no crash on malformed bytes).
- [ ] No new unbounded queues or per-peer memory growth.
- [ ] No secrets logged; redaction verified.
- [ ] Dependencies reviewed (license + maintenance + CVE exposure).
- [ ] Fuzz targets updated or added (if on a boundary).
- [ ] Differential tests updated (consensus changes).
- [ ] Threat model note updated if risk changes.

## Output
- Add a short “security notes” section to the PR description or ADR.
