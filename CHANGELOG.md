# Changelog

All notable changes to this harness and its reference labs are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project intends to follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html)
once the first version is tagged.

## [Unreleased]

No version has been tagged yet. The entries below describe the state of `main`.

### Added

- Deploy-time telemetry injection for .NET targets, with no application
  change: a startup-hook assembly that the lab compose files stage through an
  init container. It carries the `perflab-baggage-v1` request contract
  (D-P1-8): every generator sends the run and phase as W3C baggage, the
  application's request span, log scope and request-duration metric carry
  them, and capture selects the measured phase only after a pre-traffic probe
  verifies the target echoes it. It also links spans to CPU profiles (D-P1-3):
  each local root span carries `pyroscope.profile.id`, and capture keeps the
  flame graph of exactly the captured slow traces' spans.
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
- `analyze/analyze-stages.sh` (auto-run after every measure) breaks a staged
  profile down by its executed k6 stages: server-side throughput, p99 and 5xx
  ratio per stage, the last healthy and first failing level and the level
  beyond which throughput stopped following the load (ramp, load, stress,
  breakpoint, capacity), and a spike's degradation and recovery time. Gate A
  cases 11 and 12 had only a compile-shape test.

### Fixed

- The live Gate B tests build the Protocol Reliability target with its
  Dockerfile's Release publish stage into their own temp directory. They ran
  `dotnet build --no-restore` in the source tree, so they depended on restore
  state a previous build had left there, wrote `bin/` and `obj/` into the
  application folder, ran Debug builds, and needed a host `protoc` that
  Grpc.Tools does not ship for Arm64 macOS.
- A process dump no longer stays in the evidence package. ScenarioLab's S03 and
  S04 dumps carried the lab's database connection string into
  `runtime/captures/dump/process.dmp`, which acceptance case 26's scan found.
  Dumps and CollectionRules Triage dumps now move to an owner-only
  `artifacts/sensitive/` store as soon as they are downloaded; the package
  keeps a pointer with the hash, size and retention deadline, as PerfLab keeps
  its dump as a retained, non-exportable artifact.
- Protocol summaries retain actual backpressure and transport outcomes even
  when k6 exits on a failed threshold. Browser visits, subrequests and Web Vitals
  stay separate from backend capacity, efficiency and SLO metrics.
- CPU saturation respects per-instance fractional quotas. Telemetry exporter
  connections are excluded from upstream pool attribution, and queue spikes
  need persistent backlog before establishing starvation.
- Same-name process restarts invalidate measurement identity. Protocol
  Reliability gives each replica its own monitor endpoint and IPC volume.
- Failed load and end-window probes preserve partial capture. Resource ticks
  follow the scheduled cadence and retain the cost of interrupted samples.
- Empty optional profiles no longer report a captured aggregate. Heap diffs
  no longer append an empty-list marker beneath populated results.
- Repeat, sweep and data-scale runners retain each child's output in `run.log`.
  Arrival/open effective duration matches the generated k6 executor, and lab
  descriptors honor an explicitly supplied wrk image.
- Runtime counters (`/livemetrics`) are requested through `monitor_curl`, so a
  protected monitor (authorization, custom CA, client certificate) no longer
  loses the counters while the trace still reads as captured. Campaign trace
  stages capture counters too; presets used to skip them.
- wrk no longer requires Docker. Without `PERFLAB_WRK_IMAGE` the host wrk runs
  against the published base URL. An image whose architecture differs from the
  Docker host is refused before traffic: the amd64 `williamyeh/wrk` image
  crashed with SIGSEGV (exit 139) under emulation on arm64.
  `source/tool-versions.txt` names the wrk that ran. The wrk warm-up lasts
  `PERFLAB_WARMUP_SECONDS`, as k6 and JMeter already did, instead of a fixed
  10 seconds under a "warming up for N seconds" announcement.
- A fault's `--at` offset counts from the recorded measurement start. The
  injector used to start before the measurement-start environment snapshot, so
  a `--at 20` Redis pause landed at +18 s of the measured window.
- Async reconciliation no longer balances counters across a broker restart. A
  RabbitMQ kill/stop (this run's fault, or a node uptime shorter than the time
  since the baseline, now recorded in `rabbitmq-nodes*.json`) resets
  `message_stats`; the report used to subtract a pre-restart baseline and claim
  46,584 accepted requests were never enqueued. It now reports the balance as
  not captured and keeps the end-of-run queue and dead-letter depths.
- The reconciliation balance subtracts the post-warm-up queue, in-flight and
  dead-letter depths as it already subtracted the counters. S17 begins its
  window with a full queue and 61,848 dead letters from warm-up, which were
  charged to the run. Differences within one 5 s management-statistics interval
  of the run's publish rate are reported as `statsLagTolerance`, not as loss.
- The upstream-pool verdict reports open connections as the largest active+idle
  total at one instant. It added each state's own peak, so S25's
  2-connection handler was reported as "4 open connection(s)".
- Loki log paging halves the page size when Loki answers with an HTTP error,
  and a reachable Loki that keeps erroring is recorded as `failed`, not
  `missing`. S27's 1000-entry pages of deadlock stack traces encoded to 5.8 MB,
  over Loki's 4 MiB gRPC limit; the package lost every log and reported
  "Loki unreachable".
- The postgres reset-stats adapter records `pg_stat_database` after warm-up
  (`postgres-deadlocks-preload.csv`), and ScenarioLab writes
  `postgres-deadlocks-delta.json` for the measured window. The deadlock counter
  was cumulative for the stack's lifetime, so S27's evidence carried every
  earlier run and later scenarios reported inherited deadlocks.
- A `dependency-bound-db` verdict whose mean DB time exceeds the median latency
  says so instead of reporting "~238% of a typical request is spent in the
  database". Both times carry one decimal: the checkout journey's 2.16 ms
  against 1.84 ms read as "2 ms exceeds 2 ms".
- A repeat's aggregate steady-state verdict names the worst thing its reps
  showed: `unsteady`, then `warming`, then a verdict that could not judge the
  window. Three 30-second reps, each `insufficient-data`, were aggregated as
  `unsteady`, and `gate.sh --require-steady` reported drift nobody measured.
- Steady-state certification runs for the `closed` and `open` profiles, the
  constant-VU and constant-arrival executors behind `steady` and `arrival`.
  They were reported as "intentionally non-steady (ramp/surge)".
- The Postgres dataset fingerprint counts rows exactly instead of reading the
  `n_live_tup` statistics estimate, which autovacuum revises: identical data
  fingerprinted differently (282,826 vs an exact 282,827 products).
- Protocol Reliability diagnose runs capture real `/stacks`. Its descriptor
  reset `PERFLAB_ENABLE_DOTNET_MONITOR_STACKS` to false when the runtime adapter
  re-read it, overriding the diagnose-mode enablement, so every P-series stacks
  diagnose fell back to a CPU trace even with continuous profiling off.
- The `hang` preset takes `/stacks` and the optional dump at the middle of the
  diagnostic load. Both ran after the load had finished, so S03's semaphore
  convoy (p99 5.4 s under load) had already drained and the snapshot showed an
  idle process. The runtime adapter test fixture now provides `diag_endpoint`,
  which the replica-specific monitor change made the adapter call; every
  adapter test case had been exiting 127.
- Weighted mix selection finishes its FNV-1a hash with the murmur3 avalanche.
  Keys that differ only in their trailing VU and iteration digits left the high
  bits correlated: browse-and-buy's 5% order-create member ran at 3.72% (chi²
  75.6 over five members) and now runs at 4.71% (chi² 8.3).
- A write-capable mix needs a managed-reference run partition only on a lab
  that provides one (`PERFLAB_WRITE_SAFETY_CLASS=managed-reference`, declared by
  ecommerce), as PerfLab already decides. Elsewhere it is an ordinary write
  workload under the lab's per-run reset, like S16. ScenarioLab's shipped
  `mixed-runtime` mix built the whole stack and then failed on a 404 from the
  missing seed endpoint. A journey mix on a lab without a partition is refused
  before anything starts. The README's browse-and-buy example now supplies the
  acknowledgement and budget it needs. As written it was refused.
- `writeSafety.class` in `facts.json` is `managed-reference` only when this run
  created a partition, not whenever `PERF_WRITE_ACK` is set. Otherwise the gate
  refused a partition-less run as "cleanup is incomplete".
- Async reconciliation compares HTTP successes with publishes only for a
  single-request workload, and records `httpComparison`. For a weighted mix the
  HTTP count includes members that never publish, so ScenarioLab's
  `mixed-runtime` reported 176,207 reads as "accepted and never enqueued".
- The gate's journey correctness check reads k6's `journey.failed` as well as
  the JMeter adapter's `journeys.failed`. It read only the JMeter name, so a k6
  checkout run with failed journeys passed the gate.
- The k6 `workloadContentHash` covers every local module the script imports
  (`mix.js`, the shared `journey.js`), not only the entry script. A `mix.js`
  change kept browse-and-buy's identity, and compare-runs reported the changed
  workload as a 15% CPU-per-request regression; it now refuses the pair. A
  script without local imports hashes as before. The k6 adapter test accepts
  `browser_http_req_failed.fails` in the browser request total, where the
  browser-scope fix legitimately uses it.
- k6 summaries no longer retain `setup_data`. The ecommerce `setup()` returns
  its login token, and k6 exported it into `k6-summary.json` and
  `k6-warmup.json`, so every ecommerce package carried a bearer JWT (acceptance
  case 26). A summary that cannot be rewritten is removed and fails the phase.
- The Postgres reset restores the seeded dataset before every run. The first
  reset on a fresh volume copies each table into a `perflab_seed` schema and
  later resets reload from it, undoing inserts and updates. After E07 the
  ecommerce catalogue held 282,827 products instead of 20,000, and
  browse-and-buy's search averaged 104 ms instead of ~5 ms. The dataset
  fingerprint ignores the snapshot schema.
- A scenario the catalog declares as open-model runs at its declared arrival
  rate when no `PERFLAB_PROFILE` is given. The checkout journey (open,
  5 journeys/s) ran as 5 closed users at ~20 journeys/s. The checkout JMX paces
  `op::login`, one sampler per journey, so its open-profile rate is journeys/s.
- The JMeter adapter reports journeys with the k6 adapter's `journey.*` names
  and units; it emitted `journeys.*`.
- Trend (leak) analysis marks a profile whose load changes inside the window
  (ramp, stress, spike, capacity, breakpoint, load) not applicable, as
  steady-state does. E06's surge was flagged as a thread-pool leak candidate.
- Runtime rate series (CPU, allocation, GC pause, lock contention) use a 20 s
  window evaluated from `start + window`, so no point averages time before the
  measurement (`PERFLAB_RATE_WINDOW_SECONDS` raises it for slow exporters). A
  one-minute rate carried R01's GC pauses into R02, labelled gc-bound.
- `trend-report.sh` shows each row's load generator, takes `--generator`, and
  warns when a series mixes scenarios, profiles or generators.
- The README describes S27 as observed: EF Core wraps 40P01, so aborted
  requests return HTTP 500, and about 95% fail at 16-way contention.
- Each lab has its own dataset-preparation marker. The shared marker left by an
  interrupted ScenarioLab run was reported as an interruption recovery by the
  next ecommerce run, and that run erased ScenarioLab's record of it.

### Changed

- Query provenance records carry the range step or the pinned evaluation time,
  page, attempt count and last transport exit; the derived efficiency scalars
  and every Loki page are recorded (D-P2-7).
- Dump normalization adds `dumpasync`, `syncblk` and `analyzeoom` as a second
  invocation, so the thread and heap listing survives an extended-command
  failure (D-P2-3).
- Sampler and cleanup traps are armed for every local run, every sampler tick
  is bounded, shutdown never waits on a stuck Docker call indefinitely, and a
  tick interrupted by the stop is finalized as a gap so the summary's counts
  always add up.
- A single-kind dump whose extended SOS commands fail keeps its thread and heap
  listing, says so in the retained report, and carries the failure into
  `runtime/normalization.json` as a limitation.
- Measured runs record a bounded in-window resource series
  (`dependencies/container-stats-series.ndjson`,
  `dependencies/<app>-sockets-series.ndjson`, `resource-series.json`) with
  gaps and sampler overhead; `PERFLAB_RESOURCE_SAMPLE_SECONDS` and
  `PERFLAB_RESOURCE_SAMPLE_MAX` bound it (D-P1-10).

### Notes

- Every port is loopback-only; nothing runs in the cloud.
- The labs share one set of host ports and a single Compose project each, so the
  harness is **single-operator by design** — concurrent invocations are
  unsupported and corrupt both runs.

[Unreleased]: https://github.com/nilshah80/dotnet-perf-eng/commits/main
