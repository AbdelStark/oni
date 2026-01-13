# .harness/ — Agent Persistent Memory

This directory is the agent's filesystem-based state tracking system.

**Principle**: Context is RAM (scarce), filesystem is state (persistent).

## Structure

```
.harness/
├── README.md        # This file
├── STATUS.md        # Implementation matrix
├── milestones.md    # Long-running task progress
├── backlog.yml      # Task queue with acceptance criteria
├── errors.md        # Known issues and solutions
└── knowledge/       # Domain-specific playbooks
    ├── serialization.md
    ├── crypto.md
    ├── script.md
    ├── p2p.md
    ├── storage.md
    └── fuzzing.md
```

## Usage

### Before Starting Work

1. **Read STATUS.md** — Understand current implementation state
2. **Check backlog.yml** — Find existing tasks or add new ones
3. **Review errors.md** — Avoid known pitfalls

### While Working

- Update task status in `backlog.yml` as you progress
- Log new errors and solutions to `errors.md`
- Reference `knowledge/` playbooks for domain patterns

### After Completing Work

- Mark tasks `done` in `backlog.yml`
- Update `STATUS.md` if implementation changed
- Add entries to `knowledge/` for patterns discovered
- Update `milestones.md` if milestone progress changed

## File Formats

### backlog.yml

```yaml
- id: X1
  title: "Short summary"
  subsystem: consensus|bitcoin|storage|p2p|rpc|node|ops|security
  status: pending|in_progress|done
  depends_on: [other_ids]
  description: >
    What to do
  acceptance:
    - "Criterion 1"
    - "Criterion 2"
```

### errors.md

```markdown
## [ERROR_CODE] Short description

**Symptoms**: What you observe
**Cause**: Root cause
**Solution**: How to fix
**Prevention**: How to avoid
```

### knowledge/*.md

```markdown
# Topic Name

## When to Use
...

## Patterns
...

## Pitfalls
...

## Examples
...
```

## Maintenance

- Keep entries concise — agents have limited context
- Remove obsolete entries — stale info is worse than no info
- Cross-reference with code — `file:line` format
- Update timestamps in STATUS.md when making changes
