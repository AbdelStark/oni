# Security Policy

## Reporting a Vulnerability

The oni team takes security seriously. We appreciate your efforts to responsibly disclose any security vulnerabilities you find.

### For Critical Vulnerabilities

**DO NOT** open a public GitHub issue for security vulnerabilities, especially:

- Consensus bugs that could cause chain splits
- Bugs that could lead to loss of funds
- Remote code execution vulnerabilities
- Denial of service vulnerabilities affecting node availability

Instead, please email the maintainers directly.

Include as much information as possible:
- A clear description of the vulnerability
- Steps to reproduce
- Potential impact assessment
- Any suggested fixes or mitigations

### Response Timeline

| Stage | Timeline |
|-------|----------|
| Initial Response | Within 48 hours |
| Status Update | Within 7 days |
| Fix Development | 30-90 days (severity dependent) |

### What to Expect

1. Acknowledgment of your report
2. Regular updates on our progress
3. Credit in the security advisory (if desired)
4. Notification when the fix is released

## Supported Versions

| Version | Supported |
|---------|-----------|
| main | :white_check_mark: |
| < 1.0 | :warning: Pre-release, best effort |

## Security Measures

### Consensus Code

- All consensus code is tested against Bitcoin Core test vectors
- Differential testing is performed for script execution
- Changes require review by consensus-aware maintainers

### Network Boundaries

- All P2P message parsing is fuzzed
- Strict bounds on all incoming data
- Rate limiting and DoS protection

### Dependencies

- External dependencies are vendored for reproducibility
- SBOM generated for each release
- Regular security audits of vendored packages

### Build Security

- Reproducible builds supported
- Release binaries include checksums
- CI runs security scanning on all PRs

## Coordinated Disclosure

We follow coordinated disclosure:
- Acknowledge receipt
- Reproduce and assess severity
- Develop a fix and release
- Publish an advisory (when appropriate)

For the technical threat model and security design, see `docs/SECURITY.md`.
