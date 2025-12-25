# Quality gates

oni’s quality gates are intentionally strict. This project is a Bitcoin implementation: correctness and security are mandatory.

## 1. Code quality gates

### 1.1 Formatting
- `gleam format --check` in CI for all packages.

### 1.2 Type checking
- `gleam check` in CI for all packages.
- Warnings are treated as errors in CI.

### 1.3 Testing
- Unit tests must be added for every new public function.
- Consensus-critical code must have:
  - test vectors
  - negative tests (invalid cases)
  - differential tests vs Bitcoin Core where possible

### 1.4 Documentation
- Every new module must document:
  - purpose
  - invariants
  - error conditions
- Public APIs must have doc comments.

## 2. Security gates

### 2.1 Dependency review
- New dependencies require:
  - justification
  - license compatibility check
  - maintenance/health check
  - security history check where possible

### 2.2 SBOM
- SBOM generated in CI and attached to releases.

### 2.3 Fuzzing
- P2P decoding fuzz targets.
- Script engine fuzz targets.
- Transaction/block parsing fuzz targets.

Short fuzz smoke in CI; long fuzz campaigns in nightly/cron.

## 3. Performance gates

- Hot-path changes require:
  - benchmark update
  - regression check against baseline
- No unbounded allocations introduced in parsing or relay paths.

## 4. Release gates

A release is allowed only if:
- all CI checks are green
- upgrade/release notes updated
- versioned artifacts reproducible from tagged commit
- SBOM published
