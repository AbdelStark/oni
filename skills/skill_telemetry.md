# Skill: Telemetry integration

## Goal
Provide production-grade observability:
- structured logs
- metrics (Prometheus)
- traces (OpenTelemetry-style)

## Where
- Primarily `packages/oni_node` plus subsystem packages emitting events.

## Steps
1. Define telemetry conventions
   - metric names, labels, units
   - log fields and redaction rules
2. Instrument hot paths
   - IBD pipeline stages
   - script verification
   - DB reads/writes
   - P2P message counts
3. Implement endpoints
   - /metrics
   - /healthz
   - /readyz
4. Create dashboards and alert rules (starter set)

## Gotchas
- Cardinality explosions in labels.
- Logging raw tx data by default (avoid).
- Ensure telemetry doesn’t become the bottleneck.

## Acceptance checklist
- [ ] Metrics available in a running node
- [ ] Health checks reflect readiness correctly
- [ ] Log redaction rules documented and tested
- [ ] Trace spans correlate IBD stages
