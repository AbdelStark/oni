# Task template

Copy this into `ai/backlog/backlog.yml` as a new entry.

```yaml
- id: X123
  title: ""
  subsystem: foundations|bitcoin|consensus|storage|p2p|rpc|node|ops|security
  depends_on: []
  description: >
    What is the work? Be specific and bounded.
  acceptance:
    - ""
  tests:
    - "unit"
    - "integration"
    - "fuzz"
    - "diff"
    - "bench"
```

Guidelines:
- keep tasks PR-sized
- specify acceptance criteria as verifiable statements
- specify test types explicitly
