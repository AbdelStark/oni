# Deployment

oni targets production deployment on Linux via Erlang/OTP releases.

## 1. Build artifacts

Short term:
- Use `gleam export erlang-shipment` to produce a self-contained “shipment” directory.
- Wrap with systemd, Docker, or Kubernetes.

Long term:
- Adopt OTP release tooling once it is officially supported/standard in the Gleam ecosystem.

## 2. Docker

Recommended pattern:
- multi-stage build
- build in a Gleam container or image that has Erlang + Gleam installed
- copy the shipment output to a minimal runtime image

See Gleam deployment docs:
- https://gleam.run/deployment/linux-server/

## 3. Configuration

- Config file in data directory (TOML/JSON)
- Environment variable overrides
- Secrets (RPC auth) via:
  - local cookie file
  - injected secret store (K8s secret, vault, etc)

## 4. Observability in production

- /metrics scraped by Prometheus
- logs shipped to centralized logging
- traces exported to OTLP collector (optional)

## 5. Upgrades

- Document DB schema versions and migrations.
- Provide a safe upgrade procedure:
  - stop node
  - backup data directory
  - run migration tool (if needed)
  - start node and verify readiness
