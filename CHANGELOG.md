# Changelog

All notable changes to this harness and its reference labs are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project intends to follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html)
once the first version is tagged.

## [Unreleased]

No version has been tagged yet. The entries below describe the state of `main`.

### Added

- A ports-and-adapters harness core driving measurement, evidence capture,
  normalization and a read-only AI diagnosis phase.
- A .NET 10 reference project — a synthetic commerce API plus an order worker —
  carrying deliberately planted performance defects.
- Labs: `scenariolab` (PostgreSQL + Redis + RabbitMQ + worker), `ecommerce`
  (API over PostgreSQL only), `protocol-reliability` and `remote-example`.
- OpenTelemetry logs, metrics and traces exported to the Grafana OTEL-LGTM
  stack (Prometheus, Loki, Tempo, Pyroscope).
- Runtime diagnostics through a `dotnet-monitor` sidecar, normalized to
  Speedscope and text reports.
- Load generation through k6 by default, with wrk and container-only JMeter.
- Immutable per-run evidence packages as the sole input to the AI phase.
- A human review gate, with `claude-fix.sh` as the only editor, and re-measurement
  under the same workload with a mechanism gate.
- Opt-in Pyroscope CPU profiling in the lab images and the harness.
- Contract, markdown, plan-consistency and independence checks under
  `scripts/contract/`.

### Notes

- Every port is loopback-only; nothing runs in the cloud.
- The labs share one set of host ports and a single Compose project each, so the
  harness is **single-operator by design** — concurrent invocations are
  unsupported and corrupt both runs.

[Unreleased]: https://github.com/nilshah80/dotnet-perf-eng/commits/main
