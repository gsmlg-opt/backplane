# BackplaneTelemetry

Shared Observability v2 infrastructure for the Backplane umbrella: event
envelopes, correlation context, redaction, bounded buffers, runtime diagnostic
sinks, and health snapshots through `Backplane.Observability.health/0`.

`BackplaneTelemetry.Supervisor` owns observability settings and the runtime sink
when enabled. Operational policy is stored under `observability.*` in the shared
Settings store. LLM, MCP, and audit persistence writers remain in their owning
domain apps.

The legacy `BackplaneTelemetry.TelemetryLogger` remains available for rollback.
See the repository's [observability guidance](../../AGENTS.md#observability-v2)
for configuration and ownership boundaries.

