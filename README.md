# Reusable performance-engineering lab

A local, language-neutral **performance-evidence harness** built as a thin
ports-and-adapters toolkit. A stable core drives measurement, evidence capture,
normalization, and a read-only AI diagnosis; everything project- or
language-specific plugs in through a bash descriptor and small adapter scripts.

The reference project is a .NET 10 service (plus an order worker) with
**deliberately planted performance defects** — a synthetic commerce API measured
against PostgreSQL, Redis, and RabbitMQ, exporting OpenTelemetry
logs/metrics/traces to Grafana OTEL-LGTM and runtime diagnostics through a
`dotnet-monitor` sidecar. Nothing runs in the cloud; every port is loopback-only.

This repository is the canonical owner of the actual .NET application source,
Compose definitions, catalogs, and generator workloads for ScenarioLab,
Ecommerce, and Protocol Reliability. Other orchestrators may reference these
assets, but must not carry independent copies of the lab applications.

Onboarding another project or runtime means **adding files, not editing the
core**.

> Architecture, contracts, and the per-runtime adapter matrix live in
> [`BLUEPRINT.md`](BLUEPRINT.md).

> Release readiness, the gate model, and the open work live in
> [`docs/REAL-WORLD-PERFORMANCE-ENGINEERING-IMPLEMENTATION-PLAN.md`](docs/REAL-WORLD-PERFORMANCE-ENGINEERING-IMPLEMENTATION-PLAN.md).

## Release readiness

Work is tracked against three gates: **A** is the first supported release, **B**
covers a capability only once it is advertised, **C** is platform expansion.

**Gate A is complete.** All 39 Gate A acceptance cases map to a command. The
final D-P0-7 proof captures a live .NET process and observes allocation events
through PerfLab's production EventPipe capture and analyzer path.

C-14 is closed as a non-blocking scope decision and must not be rerun to qualify
Gate A. Its former latency comparison used separate executions, so application,
runtime, host, deployment, and harness variance were inseparable from reporting
logic. The 10 completed trials established throughput parity (0.1% median
difference) but could not establish latency equivalence (18.5% difference with
roughly 47% within-side dispersion). If cross-product derivation parity is ever
needed, feed both implementations the same immutable k6 summary; independent
workload trials are intentionally excluded from the release gate.

The final structural parity check covers two scenarios from every supported
lab: ScenarioLab `S00`/`S01`, Ecommerce `E00`/`E06`, and Protocol Reliability
`P00`/`P04`. All six pass the 24-family evidence contract with no missing
normalized native facts and no unmapped native artifacts. The contract remains
`numericalPolicy: "report-only"`; this verifies evidence and normalization
coverage without reintroducing C-14's invalid independent-run numerical gate.

The rule that makes those numbers meaningful is that an item with **no** command
counts as not met, not as an omission: "we have not written the check yet" and
"the check passes" must never look alike from the outside. Section 23.2.1 of the
plan maps each defect to its command and 23.2.2 maps the acceptance cases. The
commands that do exist run in the contract check:

```bash
./scripts/contract/check.sh
```

Writing those proofs surfaced three defects that reading the code had not:
`bottleneck.sh` aborted the whole classifier when the DB-pool metric file was
absent; collector-health accounting only ran for remote targets, never for the
local path that every lab run uses; and the ported queue rule reported silence
for a deep queue on a server that had stopped serving.

## Architecture

The load generator drives the app; telemetry, dependency state, and runtime
diagnostics all fold into one immutable evidence package on the host, which is
the only thing the AI phase reads.

```mermaid
flowchart TD
    LG["Load generator<br/>k6 default, wrk, or<br/>container JMeter"] --> API["ASP.NET Core API<br/>.NET 10"]
    API --> PG[("PostgreSQL")]
    API -. scenariolab .-> REDIS[("Redis")]
    API -. scenariolab .-> RABBIT[("RabbitMQ")]
    RABBIT --> WORKER["Order worker<br/>.NET 10 / scenariolab"]

    API -- OTLP --> LGTM["Grafana OTEL-LGTM<br/>Prometheus / Loki / Tempo / Pyroscope"]
    WORKER -- OTLP --> LGTM
    API -- diagnostic socket --> MON["dotnet-monitor"]
    WORKER -- diagnostic socket --> MON
    MON --> RT["nettrace / gcdump / stacks / dump"]

    LG --> EV["Evidence package<br/>artifacts/runs/run-id"]
    LGTM --> EV
    PG --> EV
    REDIS --> EV
    RABBIT --> EV
    RT --> NORM["normalize<br/>Speedscope / text reports"]
    NORM --> EV

    EV --> CLAUDE["Claude Code<br/>read-only structured diagnosis"]
    CLAUDE --> GATE{{"Human review gate"}}
    GATE --> FIX["Interactive fix<br/>claude-fix.sh - the only editor"]
    FIX --> VAL["Re-measure:<br/>same workload + mechanism gate"]
```

`scenariolab` uses the full dependency set (postgres + redis + rabbitmq + worker);
`ecommerce` is a single API over postgres only. The two labs publish the **same**
loopback ports, so only one runs at a time — the harness stops the other lab's
stack automatically on bring-up.

**Single-operator by design:** because the labs share one set of host ports and a
single Compose project per lab, running **two harness invocations at once is
unsupported** — a second run recreates the app containers under a different
scenario mid-measurement and corrupts both. Run one scenario/suite/sweep at a
time (the pe-test runners already drive their scenarios sequentially).

## Repository layout

```
harness/                          # reusable toolkit (never edited per project)
├── core/
│   ├── run/                     # run-single/multiple/all wrappers + run-scenario(s) orchestrators
│   ├── pe-tests/                # perf-engineering runners: run-sweep/mix/repeat/data-scale/fault
│   ├── capture/                 # capture-evidence + capture/normalize-runtime (the evidence pipeline)
│   ├── analyze/                 # trends/leak, A/B regression, gate (+steady), capacity knee, steady-state, USE bottleneck, CPU + heap diff, cross-commit trend
│   └── lib/                     # common.sh (shared helpers) + lab-context.sh (lab-specific init)
├── adapters/
│   ├── runtime/dotnet/           # metrics.sh, capture.sh, normalize.sh, versions.sh, evidence-extra.sh, diagnostics/Dockerfile
│   ├── dependency/{postgres,redis,rabbitmq}/  # reset/sample-midload/snapshot.sh (generic; config-parameterized)
│   ├── loadgen/{wrk,k6,jmeter}/  # run.sh (shared contract) + default.lua / default.js / test-plan.jmx
│   └── observability/grafana/    # generate-dashboards.py — emits the per-lab Grafana dashboard suite
└── ai/                           # diagnosis.schema.json, *-prompt.md, scripts/
labs/scenariolab/                 # the EXPERIMENT (per project): what to test + how to run it
├── lab.config.sh                 # descriptor — the single re-pointing seam (bash)
├── scenarios.tsv                 # this project's API scenarios
├── loadgen/{k6.js,wrk.lua,test-plan.jmx}  # this lab's workload (auth/data live here; else the shared default)
├── dependencies/<dep>/<phase>.sh # project-specific probes (e.g. postgres EXPLAIN), by convention
├── infra/grafana/dashboards/     # provisioned dashboard suite (generated; one JSON per focused board)
├── infra/observability/          # otelcol-extra.yaml — additive collector overlay for dependency scrapes
└── compose.yaml  infra/          # lab wiring: app + deps + observability + diagnostics
source/dotnet/scenariolab/        # the APP under test ONLY (pristine — swappable for a real repo)
└── PerfLab.slnx  src/{Api,Worker,Shared}/
artifacts/runs/<run-id>/          # evidence packages
```

Three concerns, three homes: `harness/` (the reusable engine), `labs/<project>/`
(the experiment — descriptor, scenarios, lab compose/infra), and
`source/<runtime>/<project>/` (the application, kept clean). The harness
auto-discovers the sole lab; with several, select one via `PERFLAB_LAB=<name>`.

### Labs in this repo

| Lab | App | Dependencies | Demonstrates |
|---|---|---|---|
| `scenariolab` | `source/dotnet/scenariolab` (`PerfLab.Api` + worker) | postgres, redis, rabbitmq | the reference planted-defect catalog (`S00`–`S27`) |
| `ecommerce` | `source/dotnet/ecommerce` (`ECommerce.Api`) | postgres | a JWT-protected CRUD API (`E00`–`E14`); per-lab k6 workload that logs in via `setup()`, and postgres db/user `ecommerce` (parameterized dependency adapter) |
| `protocol-reliability` | `source/dotnet/protocol-reliability` (`ProtocolReliability.Api`) | none | HTTP control, gRPC, WebSocket, SignalR, messaging, browser synthetic, failover, backpressure, and recovery (`P00`–`P11`) |
| `remote-example` | *already-deployed endpoint* (not owned here) | none | the **remote target mode** (`PERFLAB_TARGET=remote`): a black-box load/capacity test against a URL, no Compose/telemetry ownership (`R00`–`R02`) |

With more than one lab present, **every command needs a lab selected**, e.g.
`PERFLAB_LAB=ecommerce ./harness/core/run/run-multiple.sh E02,E03 20`.

## Target modes — local vs remote

A lab declares `PERFLAB_TARGET` (default `local`). It decides whether the harness
**owns** the app under test.

| | `local` (default) | `remote` |
|---|---|---|
| App lifecycle | harness runs `compose up/down`, rebuilds, waits for ready | app is **already deployed**; harness never touches lifecycle |
| Dependencies | reset/reseed/fault the owned postgres/redis/rabbitmq | none owned — dependencies are off-limits |
| Warm-up + measure window | yes | yes |
| Load generator SLIs → `facts.json` | yes | yes — **the entire evidence** |
| Telemetry (Prometheus/Tempo/Loki/Pyroscope) | captured, **run-id-scoped** | off by default; opt-in `PERFLAB_REMOTE_TELEMETRY=1` reads it **window-scoped** |
| Runtime diagnostics (dotnet-monitor nettrace/gcdump/stacks) | available | off by default; opt-in `PERFLAB_REMOTE_DIAGNOSTICS=1` **+ ack** |
| `manifest.json` | `"target":"local"` | `"target":"remote"` (+ `"remoteTelemetry"`) |

### Target ownership — `PERFLAB_TARGET_KIND`

`local` vs `remote` answers *where* the app is. `PERFLAB_TARGET_KIND` answers a
different and more dangerous question: *did this run create it?* A diagnostic
recreates the app (`compose up -d --force-recreate`) so the process starts
clean. That is correct for a stack the harness brought up, and destructive for
anything else — pointed at a shared host it restarts an API somebody else is
using, and the first sign is their traffic failing.

Ownership is therefore explicit and conservative. "I am not sure" resolves to
"do not touch it".

| `PERFLAB_TARGET_KIND` | Meaning | Lifecycle operations |
|---|---|---|
| `managed-compose` (default) | this run owns the compose project | recreate, reset, clean up |
| `existing-process` | attach to a process this run did not start | **refused** |
| `existing-container` | attach to a container this run did not start | **refused** |
| `existing-environment` | a deployment this run does not own | **refused** |

A `remote` target is forced to `existing-environment` whatever the kind says, so
a stray environment variable cannot authorise recreating another environment.

A diagnostic also takes an **exclusive lease** on the target it is capturing,
keyed on the target rather than the run. Two concurrent captures would give one
process two EventPipe sessions, and each trace would then record the other's
overhead as application cost — so the second one is refused rather than
producing two quietly wrong measurements. A lease whose holder is gone is
reclaimed automatically, so a `kill -9` does not wedge the target.

**Remote** turns the harness into a black-box load/capacity tool against a URL:
it health-checks `PERFLAB_READY_URL`, warms up, measures against `PERFLAB_BASE_URL`,
and records the load generator's own throughput / latency-percentile / error-rate
SLIs. It is the mode for hitting a staging or production endpoint you do **not**
control.

```bash
# Point the example lab at your deployment (or edit labs/remote-example/lab.config.sh):
PERFLAB_LAB=remote-example \
PERFLAB_BASE_URL=https://staging.example.com \
PERFLAB_READY_URL=https://staging.example.com/health/ready \
  ./harness/core/run/run-scenario.sh R01 30
```

Works against a remote target: `run-scenario`, **`run-sweep`** (capacity knee),
`run-mix`, `run-repeat` (without `--reseed`), every load profile
(`steady`/`ramp`/`stress`/`spike`/`soak`/`capacity`/`arrival`), `compare-runs`,
`analyze-trends`. Refused (they mutate owned state, with a clear error):
`run-fault`, `run-data-scale`, `run-repeat --reseed`.

Caveats: k6 (a host process) is the recommended generator. **wrk runs in Docker**,
so a host-loopback `PERFLAB_BASE_URL` (`127.0.0.1`) is unreachable from inside the
container — use k6 for a host-local target; wrk is fine against a genuinely remote
host. For a protected endpoint, pass a pre-minted token per run via a **JSON**
`PERF_HEADERS='{"Authorization":"Bearer <token>"}'` (both workloads parse it as a
JSON object, not a raw header string; never commit tokens). Remote SLIs are measured
**from this machine**, so they include client-to-server network latency — keep the
generator close to the target and hold it constant across an A/B.

### Remote with more access: observed + diagnostics

`remote` is really a spectrum of how much of the deployed environment you can
reach. The plain mode assumes only a URL; two independent opt-ins add back
evidence when you have more:

**Remote-observed** (`PERFLAB_REMOTE_TELEMETRY=1`) — you have **read access** to
the deployed env's Prometheus/Tempo/Loki (and, when continuous profiling is on,
Pyroscope). The harness reads them too, but scoped by
the **measurement time window** instead of a run id (the deployed app was not
started by us, so it carries no `perf.run.id`). The catch: without run-id
isolation, everything else serving traffic in that window is swept in — trust it
only where your load dominates or the environment is isolated (a dedicated
staging). Requires the env's endpoint URLs and its own job/service label names:

```bash
PERFLAB_LAB=remote-example PERFLAB_REMOTE_TELEMETRY=1 \
PERFLAB_PROMETHEUS_URL=https://prom.staging PERFLAB_TEMPO_URL=https://tempo.staging \
PERFLAB_LOKI_URL=https://loki.staging \
PERFLAB_PROM_JOB_REGEX='staging-api-.*' PERFLAB_SERVICE_NAME_REGEX='checkout-api' \
  ./harness/core/run/run-scenario.sh R01 30
```

Collecting Pyroscope profiles from a remote target additionally requires
`PERFLAB_CONTINUOUS_PROFILING=1` and an explicit `PERFLAB_PYROSCOPE_URL`. The
harness never injects the native profiler into a remote process; the deployed
image must already contain it.

**Remote + diagnostics** (`PERFLAB_REMOTE_DIAGNOSTICS=1` **+ ack**) — the deployed
app exposes a reachable **dotnet-monitor** endpoint, so `capture-runtime` can pull
a nettrace/gcdump against it. Because attaching a profiler or pulling a gcdump/dump
**perturbs the live process** (a gcdump pauses the GC; a dump freezes it) and can
expose secrets/PII from process memory, it demands an explicit acknowledgement and
should be a **separate run from measurement**, on staging where possible:

```bash
PERFLAB_LAB=remote-example PERFLAB_REMOTE_DIAGNOSTICS=1 \
PERFLAB_REMOTE_DIAG_ACK=i-understand-perturbation \
PERFLAB_DIAGNOSTICS_URL=http://staging-host:18323 PERFLAB_DIAG_TARGETS='remote:MyApp.Api' \
  ./harness/core/capture/capture-runtime.sh artifacts/runs/<run-id> trace 20
```

Without the ack (or with `PERFLAB_REMOTE_DIAGNOSTICS` unset), `capture-runtime`
refuses on a remote target. Remote diagnostics are **standalone-only** — a suite
(`run-scenarios`) skips them (it should not auto-perturb a live target, and the raw
capture is normalized offline), so run `capture-runtime` directly for one scenario.
It reads the endpoint, readiness URL and workload from the **manifest** (not the
current catalog), so it can't profile the remote process while loading somewhere else.

Both tiers leave the app's **lifecycle and owned dependencies untouched** — but the
*load itself is real traffic*: a write scenario (POST/PUT/PATCH/DELETE) **mutates real
data** on the target. `run-scenario` warns on a non-GET method; a **diagnostic**
write is refused outright unless you also set `PERFLAB_REMOTE_WRITE_ACK=i-understand-data-mutation`.
Prefer read scenarios against production, or a disposable/staging dataset for writes.

More remote guardrails: a failed readiness check **fails closed** (refuses to load an
unhealthy target unless `PERFLAB_REMOTE_ALLOW_UNHEALTHY=1` — also the escape hatch when
the readiness URL itself requires auth this bare check can't supply, so point
`PERFLAB_READY_URL` at an **unauthenticated** health route where you can); a remote
tier will not inherit the localhost telemetry/diagnostics defaults (set the deployed
env's URLs explicitly); and re-capturing a package standalone must re-supply its
matching lab/env or `capture-evidence` hard-fails rather than query localhost. **Security:** dotnet-monitor is a powerful
endpoint (it can dump process memory); reach it over a **secured tunnel or
authenticating proxy** (e.g. `kubectl port-forward` to a local `PERFLAB_DIAGNOSTICS_URL`)
rather than exposing it, and never put credentials in a URL (they would be logged).

## Components and local ports

All ports bind to loopback (`127.0.0.1`) and all datasets are synthetic. Both
labs use the **same** host ports; `ecommerce` simply omits Redis and RabbitMQ.

| Component | Purpose | Host address | Lab |
|---|---|---|---|
| API | Workload endpoints | `http://127.0.0.1:8080` | both |
| Grafana | Dashboard suite, Explore, trace/log correlation | `http://127.0.0.1:3000` (`admin` / `admin`) | both |
| Prometheus | Metrics query API (OTLP + remote-write receivers on) | `http://127.0.0.1:9090` | both |
| Loki | Log query API | `http://127.0.0.1:3100` | both |
| Tempo | Trace query API | `http://127.0.0.1:3200` | both |

Evidence collection defaults to `PERFLAB_LOG_LIMIT=25000` and
`PERFLAB_TRACE_LIMIT=1000` per measured phase. Both accept values through
10,000,000. Loki is read backward in 1,000-record transport pages. Tempo is
searched in bounded time slices; saturated slices are recursively divided and
trace IDs are deduplicated before representative details are retained. The
limits are evidence budgets, not backend page sizes.
| Pyroscope | Continuous multi-type profiles (opt-in) | `http://127.0.0.1:4040` | both |
| OTLP ingest | Collector gRPC / HTTP | `127.0.0.1:4317` / `4318` | both |
| dotnet-monitor | Diagnostic API (trace/gcdump/stacks/dump) | `http://127.0.0.1:18323` | both |
| PostgreSQL | Lab database (`perflab` / `perflab`) | `127.0.0.1:5432` | both |
| postgres-exporter | Server-side PG metrics (`obs` profile — opt-in) | in-network only (scraped by the collector) | both |
| Redis | Lab cache (`allkeys-lru`) | `127.0.0.1:6379` | scenariolab |
| redis-exporter | Server-side Redis metrics (`obs` profile — opt-in) | in-network only (scraped by the collector) | scenariolab |
| RabbitMQ | Broker + management (`perflab` / `perflab`) | `127.0.0.1:5672`, mgmt `:15672`, metrics `:15692` | scenariolab |

Profiling and runtime diagnostics have two independent paths:

- **Continuous profiling** (opt-in): the Pyroscope .NET native profiler inside
  each app image, pushing directly to `http://lgtm:4040`. Enable it with
  `PERFLAB_CONTINUOUS_PROFILING=1` and select `PERFLAB_PROFILING_POLICY` as
  `cpu`, `cpu-wall`, `memory`, `contention`, `exceptions`, `soak-memory`, or
  `all-diagnostic`. The resolved `PERFLAB_PROFILING_TYPES` can contain CPU,
  wall, allocation, lock, exception, and live-heap streams. Default is off so
  benchmark runs stay unperturbed — the CLR profiler and `LD_PRELOAD` wrapper
  are not activated.
- **Invasive snapshots** from the `dotnet-monitor` sidecar (`.nettrace`, GC dump,
  stacks, process dump, Speedscope). These remain the default diagnose-mode
  workflow and still work when continuous profiling is enabled.

Hold `PERFLAB_CONTINUOUS_PROFILING`, `PERFLAB_PROFILING_POLICY`, the resolved
types, and `PERFLAB_PROFILING_KEEP_TIERING` constant between baseline and
candidate. On aarch64, the keep-tiering value changes
`DOTNET_TieredCompilation`.

Managed labs declare `PERFLAB_PROFILING_SERVICE_QUOTAS`,
`PERFLAB_PROFILING_QUOTA_SOURCE`, and the versioned
`PERFLAB_PROFILING_MIN_CORES_THRESHOLD`; preflight validates every service
before traffic and writes `analysis/profiling-preflight.json`. Remote profiling
also requires `PERFLAB_PROFILING_VERIFICATION_URL`, an HTTPS read-only endpoint
whose fresh response reports provider identity, effective quotas, active types,
and activation-probe results. Remote telemetry opt-in alone is not proof that a
profiler is active.

The supported observability stack for this release is Grafana LGTM plus
Pyroscope. No other APM backend is configured or queried. The managed image's
`DD_*` profiler settings configure the engine embedded in Grafana's Pyroscope
.NET agent; they do not enable a Datadog APM integration.

## Dashboards

Each lab provisions a **suite of focused Grafana dashboards** (folder-provisioned
from `labs/<lab>/infra/grafana/dashboards/`; the overview is the home dashboard).
Every board shares four template variables — `service`, `instance`, `scenario`,
`run` — so the same view narrows to one process or one measurement run, mirroring
how evidence capture scopes runtime metrics by `service_instance_id`.

| Board | For | What it answers |
|---|---|---|
| **Overview & SLOs** | stakeholders + PE landing | Golden signals (rate/errors/latency) server-side **and** client-side (k6), latency heatmap, correlated error logs |
| **.NET Runtime & GC** | performance engineer | Allocation rate, % time in GC, collections by generation, heap by gen, thread-pool queue/starvation, lock contention, exceptions |
| **HTTP & Endpoints** | PE + dev leads | Per-route RED (throughput/p99/errors), 5xx by exception type, Kestrel connections, sortable top-routes table |
| **Dependencies & Pools** | PE + SRE | Npgsql + HTTP-client pool saturation (pending requests, time-in-queue) and — with the `obs` profile — live Postgres/Redis/RabbitMQ server internals |
| **Messaging & Worker** *(scenariolab)* | PE | Order publish/process/retry, processing-duration p95, cache hit ratio, resource-pool lab (S21–S26), worker process health |
| **Profiling** | PE | Selected Pyroscope flame graphs by `$service` / `$run`, plus Profiles Drilldown. Empty unless `PERFLAB_CONTINUOUS_PROFILING=1`. |

**One-place correlation.** The lab overrides the image's Grafana datasource file
(`labs/<lab>/infra/grafana/datasources.yaml`, generated). One-click links that
work today: a Prometheus exemplar opens its trace in Tempo; a span's **Logs for
this span** opens the service's Loki lines for that `trace_id`; a span's
**Request rate** opens the service's Prometheus rate; a Loki line's `trace_id`
opens the trace. **Trace → profile is two clicks, not one:** Grafana only
renders a span-level profile link when the span carries a `pyroscope.profile.id`
tag, which requires the Pyroscope span-profiles SDK inside the app (deliberately
not adopted by the labs). Instead, from the trace use Explore **Split**, pick the
Pyroscope datasource and `{service_name="<service>"}`: the split pane keeps the
trace's time range, so the flame graph is the span's service over that window.
The overlay's `tracesToProfiles` block is pre-configured so the one-click button
appears automatically if a lab app ever adopts span profiles.

The boards are **generated** so both labs stay in lock-step — edit
`harness/adapters/observability/grafana/generate-dashboards.py` and re-run it;
never hand-edit the emitted JSON.

**Client-observed SLOs (k6 → Prometheus).** The measure phase streams the load
generator's own throughput/latency/error metrics into Prometheus via remote-write,
so the Overview board shows the **client view next to the server view** — the two
diverge exactly when the system saturates. It is guarded by a readiness probe
(never fails a run) and disabled with `PERFLAB_K6_PROM_RW=0`. k6 series carry
`run=$PERF_RUN_ID`, matching the app's `perf_run_id`, so `$run` filters both.

**Live dependency internals (opt-in).** Server-side Postgres/Redis metrics come
from exporters gated behind the `obs` compose profile, so default measurement
runs stay perturbation-free. RabbitMQ needs no exporter (its Prometheus plugin is
always scraped). Attach the exporters to a running stack with:

```bash
docker compose -f labs/scenariolab/compose.yaml --profile obs up -d postgres-exporter redis-exporter
```

**Exemplars.** Latency histograms carry trace exemplars (`OTEL_METRICS_EXEMPLAR_FILTER=trace_based`),
so a spike on a latency panel links straight to the Tempo trace that produced it.

## Prerequisites

- **Docker + Docker Compose** (runs the whole stack; also hosts `jq` — no host jq needed).
- **A load generator:** `k6` on the host (default), a **wrk Docker image**
  (`PERFLAB_WRK_IMAGE`), or the **native JMeter adapter image**
  (`PERFLAB_JMETER_IMAGE`, built with `harness/adapters/loadgen/jmeter/package.sh`).
  This machine uses k6 by default. JMeter is never installed on the host.
- **`claude` CLI** — only for the optional AI diagnosis phase.
- Bash (Git Bash on Windows), `curl`, `awk` — standard.

No host `jq` and no host `wrk` install are required.

Optional: copy `labs/scenariolab/.env.example` → `labs/scenariolab/.env` to
override compose defaults (dependency passwords, `SEED_SCALE`,
`PERFLAB_TRACE_SAMPLE_RATIO`). Harness config lives in
`labs/scenariolab/lab.config.sh`; per-run knobs like `PERFLAB_LOAD_GENERATOR`
are shell environment variables.

## Quick start

```bash
PERFLAB_LAB=scenariolab ./harness/core/run/run-single.sh S01 30
```

Brings up the stack, warms up for 10s, measures `S01` for 30s with k6, captures
runtime diagnostics, and writes an evidence package under
`artifacts/runs/<run-id>/`. Open Grafana at `http://127.0.0.1:3000` — it lands on
the **Overview & SLOs** board; the dashboard dropdown switches between the focused
boards (see **Dashboards** above), and Explore has Tempo traces and Loki logs.

Continuous profiling is off by default. To collect CPU and wall-time Pyroscope
profiles independently into `telemetry/profiles/` (or select allocation,
live-heap, lock, exception, or all diagnostic types with another policy):

```bash
PERFLAB_LAB=scenariolab PERFLAB_CONTINUOUS_PROFILING=1 \
  PERFLAB_PROFILING_POLICY=cpu-wall \
  ./harness/core/run/run-single.sh S01 30 --no-runtime
```
Then, optionally, hand a package to the AI phase:

```bash
./harness/ai/scripts/analyze-with-claude.sh artifacts/runs/<run-id>/scenarios/S01
```

(See **AI diagnosis** below for the interactive flow and how suites are handled.)

## Pipeline

```
run-single / run-multiple / run-all      wrappers you type
        └─ run-scenarios.sh              suite orchestrator (per-scenario, sequential)
              └─ run-scenario.sh         one measurement -> manifest.json
                    └─ capture-evidence.sh   telemetry + dependencies -> facts.json
        (default; skip with --no-runtime)
              └─ capture-runtime.sh          separate diagnose-mode load
                    └─ normalize-runtime.sh  binaries -> Speedscope / text

  human review gate
        └─ ai/scripts/analyze-with-claude.sh -> claude-fix.sh   (the only editor)
```

`run-scenarios` always produces an evidence package. Runtime diagnostics run **by
default** and are kept in a **separate** diagnose-mode run because profiling
perturbs the process; pass `--no-runtime` for a clean measurement-only baseline
(e.g. an A/B latency comparison). The AI phase sits outside the orchestrator,
behind a human gate.

## Commands

| Goal | Command |
|---|---|
| Measure one scenario | `./harness/core/run/run-single.sh S07 30` |
| Measure several under one run | `./harness/core/run/run-multiple.sh S07,S12,S17 30` |
| Full sweep of all scenarios | `./harness/core/run/run-all.sh 30 --continue-on-error` |
| Flat (non-suite) package | `./harness/core/run/run-scenario.sh S07 30` |
| Reshape the load (stress/spike/soak/…) | `PERFLAB_PROFILE=stress ./harness/core/run/run-single.sh E05 60` |
| Capacity / regression / mix / data-scale / fault | see **Load profiles** and **Performance-engineering tests** below |

`--no-runtime` and `--continue-on-error` work with **any** of `run-single`,
`run-multiple`, and `run-all` — they all forward to the suite orchestrator.
Runtime diagnostics are **on by default** (each scenario's recommended capture,
normalized to Speedscope/text; roughly doubles wall-clock per scenario). Use
`--no-runtime` (alias `--measure-only`) for a clean, un-perturbed baseline:

```bash
./harness/core/run/run-multiple.sh S02,S07,S12 30              # with runtime diagnostics (default)
./harness/core/run/run-multiple.sh S02,S07,S12 30 --no-runtime # clean measurement only
./harness/core/run/run-all.sh 30 --continue-on-error
```

The AI-diagnosis commands are covered under **AI diagnosis** below.

## Load generators

`k6` is the default (host binary; comparable to wrk's `-cN` via `--vus`). `wrk`
is opt-in and runs **via Docker** on the compose network — set
`PERFLAB_WRK_IMAGE` to a wrk image and select it per run:

```bash
PERFLAB_LOAD_GENERATOR=wrk ./harness/core/run/run-single.sh S01 30
```

**JMeter** is also opt-in and is **container-only**: the harness never installs
Java, Go, or Apache JMeter on the host. Build the native adapter image with
`harness/adapters/loadgen/jmeter/package.sh` (Docker-only) and pin
`PERFLAB_JMETER_IMAGE` to the printed digest (`name@sha256:…` or a local image
ID `sha256:` + 64 hex characters). The name is a compatibility environment
variable only. The adapter inspects that image, refuses a missing image
(`--pull=never`; it will not pull during a run), and executes `run-once`
inside the container. Point at a plan with `PERFLAB_JMETER_PLAN`
(defaults to `labs/<lab>/loadgen/test-plan.jmx`) and optional supporting files
via `PERFLAB_JMETER_FILES` (a JSON array of repository-relative paths).

```bash
./harness/adapters/loadgen/jmeter/package.sh
PERFLAB_LOAD_GENERATOR=jmeter \
PERFLAB_JMETER_IMAGE=sha256:<local-image-id> \
PERFLAB_JMETER_PLAN=labs/scenariolab/loadgen/test-plan.jmx \
  ./harness/core/run/run-single.sh S01 30
```

JMeter supports **steady** load only (`PERFLAB_PROFILE=steady`). Among the
performance-engineering runners it is enabled for **`run-repeat.sh` only**
(sweep / mix / data-scale / fault stay k6). Do not compare JMeter numbers to k6
or wrk: hold `PERFLAB_LOAD_GENERATOR` constant across a before/after pair.

Both k6 and JMeter measurements publish `observations.json` with p50, p90, p95,
and p99 plus `benchmark/compatibility.json` (`generatorFingerprint`,
`workloadContentHash`, `configurationHash`). Comparisons and repeat aggregation
fail closed when that envelope is absent or differs; the first new k6 baseline
may replace a legacy baseline that predates the envelope.

The JMX preprocessor joins `PERF_BASE_URL`'s URI path with `PERF_PATH` (so
`http://api:8080/v1` + `/orders` requests `/v1/orders`). Evidence includes
`benchmark/jmeter-summary-v1.json`, `observations.json`, and the compatibility
envelope. Scratch JTL/logs under `.scratch/<phase>` are removed
after each phase.

**ecommerce JWT.** k6 logs in once in `setup()` and reuses the bearer token.
JMeter does **not** run that `setup()`; protected scenarios need a pre-minted
token in `PERF_HEADERS='{"Authorization":"Bearer <token>"}'` (JSON object, never
commit tokens). E01 (login) needs no token. Login credentials are not forwarded
into the JMeter container.

The generators are **not numerically comparable** (k6 reports latency as numeric
ms; wrk as unit-suffixed strings; JMeter percentiles come from the native
adapter's JTL summary), so the generator is recorded in `manifest.json` and must
be held constant across a before/after comparison.

**Per-lab workloads.** `run.sh` (the measurement + `observations.json` contract)
is shared and identical across labs; the *workload script* is per-lab, resolved as
`PERFLAB_{K6,WRK}_SCRIPT` / `PERFLAB_JMETER_PLAN` > `labs/<project>/loadgen/<gen>.{js,lua,jmx}` > the shared
`default.{js,lua}`. A project that needs a JWT `setup()` login, request chaining,
or per-request datasets ships its own `loadgen/<gen>.js` instead of editing the
shared default. The defaults also accept an optional `PERF_HEADERS` env var (a JSON
object of extra headers, e.g. a pre-minted bearer token).

**The 10-second warm-up is a known bound.** `run-scenario.sh` warms up for 10s,
which is not enough for a light endpoint to reach steady state (tiered JIT
promotion, PostgreSQL plan caching, and pool fill are still in progress), so
absolute throughput for *fast* endpoints — the control above all — is understated
and an `S00`-vs-`Sxx` ratio understates the injected defect. It is
generator-independent, so it does not affect wrk↔k6 comparability, and it is
invisible on server-bound scenarios that never approach the warm-up ceiling.
Lengthening it would break comparability with all prior evidence, so it is left
alone; when an absolute ceiling is the question, use `run-repeat.sh` and read the
converged repetitions.

## Load profiles

By default a scenario runs a **steady** closed-loop load (constant VUs =
`connections` for the duration) — a single-point smoke/load test. Set
`PERFLAB_PROFILE` (k6 only) to reshape the measure phase into other
performance-engineering tests **without changing the scenario** — the profile is a
run-time choice layered on any scenario:

| Profile | Model | Shape | Answers |
|---|---|---|---|
| `steady` (default) | closed | constant VUs = `connections` | SLIs at the expected load |
| `ramp` | closed | VUs step `0 → connections` | where latency starts to degrade |
| `stress` | closed | VUs ramp past `connections` → `PERFLAB_MAX_VUS` (4×) | the breaking point / saturation |
| `spike` | closed | baseline → sudden `PERFLAB_SPIKE_VUS` (4×) → recover | surge tolerance and recovery |
| `soak` | closed | constant VUs for `PERFLAB_SOAK_DURATION_SECONDS` (≥10 min) | leaks, GC/socket drift over time |
| `capacity` | open | arrival rate ramps `PERFLAB_START_RPS` (1) → `PERFLAB_TARGET_RPS` | the throughput knee (max sustainable RPS) |
| `arrival` | open | constant `PERFLAB_TARGET_RPS` | latency at a fixed throughput (coordinated-omission-safe) |

```bash
PERFLAB_PROFILE=stress   ./harness/core/run/run-single.sh E05 60
PERFLAB_PROFILE=arrival  PERFLAB_TARGET_RPS=300  ./harness/core/run/run-single.sh E00 60
PERFLAB_PROFILE=capacity PERFLAB_TARGET_RPS=2000 ./harness/core/run/run-multiple.sh E00,E05 60
```

Closed-model profiles shape **VUs** (concurrency); open-model profiles (`capacity`,
`arrival`) drive a fixed **arrival rate** and surface `http.dropped_iterations`
(requests the system could not schedule at the target rate). `soak`'s payload is
the automatic leak-detection, and `run-sweep.sh` is the discrete, curve-producing
form of `capacity` — both under **Performance-engineering tests** below. All shapes
derive from the scenario's own `connections`/duration; the knobs above override
the defaults.
The profile is recorded in `manifest.json` and the exact k6 executor in
`benchmark/k6-profile.json`. Runtime capture always runs under a **steady**
load regardless of profile, so a trace reflects a stable state rather than a ramp.

## Performance-engineering tests

Beyond a single load test, these runners answer the standard perf-engineering
questions. Each produces evidence packages under `artifacts/runs/`, and they
compose with the load profiles above (`--profile`). Sweep / mix / data-scale /
fault are **k6 only**. `run-repeat.sh` also accepts `PERFLAB_LOAD_GENERATOR=jmeter`.

| Runner | Question it answers | Output |
|---|---|---|
| `run-sweep.sh <scen> [s/level] --rates R1,R2,…` | Capacity: the throughput↔latency knee / max sustainable RPS | per-level curve + `sweep.json` (`kneeRps` = first saturated, `maxSustainedRps` = highest sustained) |
| `run-repeat.sh <scen> [dur] --repeats N [--reseed]` | Run-to-run spread across N runs: median / stddev / CV (needs ≥2 reps; `stddev`/`cv` are `null` below that). Reps share the DB by default — pass `--reseed` for **write** scenarios so each rep starts from a fresh seed | `stats.json` |
| `compare-runs.sh <baseline> <candidate>` | Regression: is the candidate **significantly** worse than the baseline? | per-metric deltas, significance-aware flags (exit 1 on regression) |
| `run-mix.sh <mix-name> [dur]` | Realistic blended traffic (e.g. 70% list / 20% search / 10% checkout) | one package; mixes live in `labs/<lab>/loadgen/mixes/*.json` |
| `run-data-scale.sh <scen> --scales smoke,demo` | How perf degrades with data volume (reseeds the DB per scale) | `data-scale.json` |
| `run-fault.sh <scen> --dependency postgres --kind pause` | Resilience when a dependency stalls (`pause`) or fails (`stop`) mid-run, and whether it recovers | one package (error/latency spike, then recovery) |

**Soak leak-detection** runs automatically on every measure (`analyze-trends.sh`
→ `analysis/trend-report.json`): the least-squares slope and first→last growth of
the heap, working set, thread-pool queue, and DB connections, flagging a
`GROWING` series as a leak/drift candidate — the payload a `soak` run exists to
produce.

```bash
PERFLAB_LAB=ecommerce  ./harness/core/pe-tests/run-sweep.sh E05 30 --rates 100,250,500,1000,2000
PERFLAB_LAB=ecommerce  ./harness/core/pe-tests/run-repeat.sh E00 30 --repeats 7   # then compare two:
PERFLAB_LAB=ecommerce  ./harness/core/analyze/compare-runs.sh <baseline-dir> <candidate-dir>
PERFLAB_LAB=ecommerce  ./harness/core/pe-tests/run-mix.sh browse-and-buy 60 --connections 64 --profile stress
PERFLAB_LAB=ecommerce  ./harness/core/pe-tests/run-data-scale.sh E05 30 --scales smoke,demo
PERFLAB_LAB=scenariolab ./harness/core/pe-tests/run-fault.sh S00 30 --dependency postgres --kind pause --at 10 --for 10
PERFLAB_LAB=ecommerce  PERFLAB_PROFILE=soak ./harness/core/run/run-single.sh E14 600 --no-runtime  # soak (runs >=600s)
```

## Gating, capacity, efficiency & trend

These turn the lab from "run and inspect" into a guardrail that **decides**.

| Tool | What it does |
|---|---|
| `analyze/gate.sh <run> [--threshold R]` | **Performance gate.** Judges a run against absolute SLOs from `labs/<lab>/slos.tsv` **and** a stored baseline (regression, via `compare-runs.sh`). Prints a verdict table and **exits non-zero** on any SLO breach or regression — drops straight into CI. Refuses a `status:"partial"`/unknown package by default (`--allow-partial` to override); a missing required SLO metric fails (`--allow-missing` to skip). `--require-steady` additionally fails a run whose steady-state verdict is not `steady` (so a warm-up/drift-skewed number cannot pass) — this certifies **server-side** steady state, not client-p99 tail steadiness, and validates the stamp's embedded runId/scenario against the candidate and baseline. Accepts a `facts.json` **or** a `run-repeat` `stats.json` (SLOs are checked against the median). |
| `analyze/update-baseline.sh <run>` | Promote a run to `labs/<lab>/baselines/<scenario>.json`. Commit it so future gates compare against it. |
| `analyze/find-knee.sh <capacity-run>` | **Capacity knee from one continuous ramp.** Reads the k6 remote-write series of a `--profile capacity` (ramping-arrival-rate) run and reports the max sustained RPS before p99 breaches the SLO. Complements `run-sweep.sh` (discrete rate steps) with a single-run, client-observed knee → `analysis/capacity.json`. |
| `analyze/diff-profile.sh <baseline-run> <candidate-run>` | **Differential flame graph.** For each Speedscope profile (from `--with-runtime`), reports the methods whose share of CPU grew/shrank the most — the "which method got hotter" answer. Runs the differ in a `python:3-alpine` container (like `jqd`), so no host Python. |
| `analyze/trend-report.sh --scenario ID --metric M` | **Cross-commit trend.** Shows a metric per scenario across commits from `perf-history/<lab>.jsonl` (auto-appended after every measure by `record-trend.sh`; skip with `PERFLAB_RECORD_TREND=0`). |
| `analyze/steady-state.sh <run>` | **Steady-state validity.** Every reported number assumes the window was in steady state, but the harness only does a fixed warm-up. It buckets the window and, per bucket, reads genuinely window-local **server-side** metrics — `rate()` of the request count and `histogram_quantile` over the request-duration histogram (k6's remote-write percentiles are cumulative and can't be windowed). The verdict is **drift-based** (a systematic tail trend, not spread), reporting whether it settled (`steady` / `warming` / `unsteady`), the warm-up to trim, and the whole-vs-steady skew → `analysis/steady-state.json`. **Scope:** it certifies **server-side** steady state; client-side **p99 tail** steadiness is *not* independently verified (k6 client percentiles are cumulative/not windowable) — in a closed-loop run throughput tracks the client *mean*, not the tail (`clientLatencyCoupling`, `certifies`). Auto-run after every measure (skip `PERFLAB_STEADY_STATE=0`); enforce with `gate.sh --require-steady`. |
| `analyze/bottleneck.sh <run>` | **USE-method bottleneck classifier.** Decomposes a typical request into CPU / GC / DB / other time and combines it with per-resource saturation (thread-pool queue, DB-pool pending, GC-pause fraction, lock contention, CPU utilisation) to name the dominant bottleneck — `cpu-bound`, `threadpool-starved`, `gc-bound`, `lock-bound`, `db-pool-saturated`, `dependency-bound-db` — with a confidence and the evidence → `analysis/bottleneck.json`. A reproducible answer next to the AI phase's. Auto-run after every measure (skip `PERFLAB_BOTTLENECK=0`). |
| `analyze/diff-gcdump.sh <run>` or `<base> <cand>` | **Differential heap (leak attribution).** The memory counterpart of `diff-profile`: diffs two `dotnet-gcdump report`s and lists the types that grew / shrank / appeared — the "which type grew" answer that turns `analyze-trends`'s *"the heap is growing"* into a cause. Retained bytes are `Object Bytes × Count` per row (bucketed rows list per-object size). One run dir diffs its own `before`/`after` gcdump (same process, bracketing the load); two run dirs compare cross-commit. Pure awk — no container. **Auto-run** by `normalize-runtime` whenever a gcdump before/after pair is present (a plain measure has no gcdump, so — unlike steady-state/bottleneck — it runs on a diagnostic capture, not every measure). |

> **Significance-aware gating (repeat vs repeat).** `compare-runs.sh` only uses statistical significance when *both* sides carry per-metric spread (`n>1`), i.e. both are `run-repeat` `stats.json`. So for a significance-aware gate: baseline **and** candidate must be repeat runs — promote a `run-repeat` directory as the baseline, and gate a `run-repeat` candidate directory (`gate.sh` resolves `stats.json` and now covers `efficiency.*` too). A single `facts.json` candidate (`n=1`) against any baseline falls back to the relative `--threshold`.

**Per-request efficiency** is captured automatically into every `facts.json` as
`efficiency.cpu_ms_per_request`, `.alloc_bytes_per_request`, `.gc_pause_ms_per_request`
and `.db_ms_per_request` (and shown on the Runtime board). It catches the regression
absolute latency hides — *same p99, more CPU/allocations per request* — and is
gate-able / comparable / trendable like any other observation.

```bash
PERFLAB_LAB=scenariolab ./harness/core/run/run-single.sh S00 60 --no-runtime
PERFLAB_LAB=scenariolab ./harness/core/analyze/gate.sh artifacts/runs/<run>/scenarios/S00   # SLOs + regression, exit != 0 on fail
PERFLAB_LAB=scenariolab ./harness/core/analyze/update-baseline.sh artifacts/runs/<run>/scenarios/S00
PERFLAB_LAB=scenariolab PERFLAB_PROFILE=capacity PERFLAB_TARGET_RPS=800 ./harness/core/run/run-single.sh S00 40 --no-runtime
PERFLAB_LAB=scenariolab ./harness/core/analyze/find-knee.sh artifacts/runs/<run>/scenarios/S00
PERFLAB_LAB=scenariolab ./harness/core/analyze/trend-report.sh --scenario S00 --metric efficiency.cpu_ms_per_request
PERFLAB_LAB=scenariolab ./harness/core/analyze/gate.sh artifacts/runs/<run>/scenarios/S00 --require-steady   # SLOs + regression + steady-state
PERFLAB_LAB=scenariolab ./harness/core/analyze/bottleneck.sh artifacts/runs/<run>/scenarios/S00              # what IS the bottleneck?
# Leak attribution: capture a gcdump (brackets the load with before/after), then diff the two heaps.
PERFLAB_LAB=scenariolab ./harness/core/capture/capture-runtime.sh artifacts/runs/<run>/scenarios/S04 gcdump 30
PERFLAB_LAB=scenariolab ./harness/core/capture/normalize-runtime.sh artifacts/runs/<run>/scenarios/S04
PERFLAB_LAB=scenariolab ./harness/core/analyze/diff-gcdump.sh artifacts/runs/<run>/scenarios/S04             # which type grew
```

### How `bottleneck.sh` decides

The classifier reports the resource with the strongest evidence; two of its
rules exist because the obvious version of each was confidently wrong.

**Queue depth is not queue wait.** A thread-pool queue is only saturated when
the backlog represents real *waiting time* — `depth / throughput` seconds, gated
at 50 ms — not when the depth alone crosses a number. Twenty queued items at
2000 rps drains in 10 ms and is burst arrival; the same twenty at 50 rps is
400 ms of genuine starvation. Judging on depth alone diagnosed S04 (an
allocation problem) as `threadpool-starved [high]` from a ~0.5 ms backlog, which
would have sent an engineer looking for blocking calls that were not there. When
CPU is *also* saturated the queue is a symptom rather than the disease, so
`cpu-bound` wins and the report says why. A transient queue is called out
explicitly instead of being silently dropped, so an alarming depth is explained
rather than hidden.

**An unmodelled resource gets blamed on whatever is modelled.** The classifier
reads the upstream (`HttpClient`) connection pool as its own dimension, because
without it a scenario blocked on outbound connections was reported as thread-pool
starvation -- the queue being the only queue it knew about. `http_client_request_time_in_queue`
reports the wait for a connection *directly*, so unlike the thread-pool queue it
needs no depth/throughput inference; the gate is the wait itself (50 ms). It is
ranked per `server_address`, so the app's own OTLP exporter -- an `HttpClient`
too -- cannot stand in for the dependency the workload calls. When it saturates,
the thread-pool queue is reported as a *symptom* rather than offered as a rival
diagnosis, because telling a reader to hunt for blocking calls *and* to raise a
pool limit is two contradictory instructions from one report.

**Retention is reported but never wins.** Managed-heap growth comes from the
in-process before/after `gcdump` pair (`analysis/runtime/diff-gcdump-before-after.txt`,
the only honest source — a within-window metric slope cannot see a leak that
already saturated during warm-up). A leak is not a latency bottleneck, so it
never competes for the primary verdict; but a package whose heap grew by orders
of magnitude while nothing saturated would otherwise read as "no problem found",
so it is always surfaced as its own dimension with the artifact that produced
it. With no `gcdump` pair, retention reports `not-captured` — which must not be
read as "no growth".

Confidence is capped by evidence completeness: an uncaptured CPU series or
dropped generator iterations cap every verdict at `low`, because "not CPU-bound"
is part of every other conclusion and dropped iterations mean the generator, not
the server, set the pace.

## Runtime diagnostics

Measurement and runtime capture are **separate runs** — diagnostic tools perturb
the process (`gcdump` forces a full collection). The orchestrator does this per
scenario **by default** (skip with `--no-runtime`); you can also run it by hand on
an existing package:

```bash
./harness/core/capture/capture-runtime.sh artifacts/runs/<run-id>            # scenario's recommended kind
./harness/core/capture/capture-runtime.sh artifacts/runs/<run-id> trace 30  # or choose: trace|gcdump|stacks|dump
./harness/core/capture/capture-runtime.sh artifacts/runs/<run-id> --preset cpu-memory 30
./harness/core/capture/normalize-runtime.sh artifacts/runs/<run-id>         # binaries -> Speedscope JSON / text
```

The `diagnostic` TSV column is a **single recommended invasive runtime
diagnostic**, not an evidence allowlist. Load facts, metrics, logs, traces,
dependency snapshots, process discovery, and source/tool provenance are still
captured independently. The cell accepts one of `trace`, `gcdump`, `stacks`, or
`dump`; it does not accept `all` or a comma-separated list.

For a deep CPU-plus-memory investigation, `--preset cpu-memory` reuses one app
recreation and warm-up, then performs the ordered campaign: before GC dump,
short recovery, CPU trace concurrent with one diagnostic load, and after GC
dump. `cpu`, `memory`, `hang`, and `dump` are also accepted presets; there is
intentionally no `all`. `hang` is trace-only unless `--include-dump` is added.
Any process dump additionally requires
`PERFLAB_DUMP_ACK=i-understand-sensitive-dump`. The `dump` preset takes only the
process snapshot: it does not warm up, require a load-generator installation,
run diagnostic traffic, or require the remote data-mutation acknowledgement.

Campaign output is independent and self-describing:

```text
runtime/
├── campaign.json
├── normalization.json
├── campaign-load/                 # warm-up/diagnostic generator evidence; never benchmark input
└── captures/
    ├── gcdump-before/
    │   ├── capture.json
    │   ├── before.gcdump
    │   ├── normalization.json
    │   └── report.txt
    ├── trace/
    │   ├── capture.json
    │   ├── cpu.nettrace
    │   ├── normalization.json
    │   └── cpu.speedscope.json
    └── gcdump-after/
        ├── capture.json
        ├── after.gcdump
        ├── normalization.json
        └── report.txt
```

Each capture has requested/effective type, timestamps, artifact paths, and its
own state. One failed GC dump makes the campaign `partial`; it does not delete a
successful trace. Normalization also continues capture-by-capture and records a
separate state. The default 1 GiB campaign budget is preflighted against free
disk (`PERFLAB_DIAGNOSTIC_ARTIFACT_BUDGET_BYTES` changes it), and recovery
defaults to two seconds (`PERFLAB_DIAGNOSTIC_RECOVERY_SECONDS`). Diagnostic load
files live under `runtime/campaign-load`, so the package's measured
`facts.json`, observations, baselines, and gates remain unchanged. The campaign
records the source git revision, endpoint, connections, body, dataset identity,
generator fingerprint, and workload hash. It also verifies the diagnostic
k6/JMeter fingerprint and workload hash before claiming a complete replay.
Measurements created before these replay fields and compatibility envelopes
were added must be rerun before using a load-bearing preset.

For maximum attribution, or to capture several kinds that should not share a
process lifetime, keep the copy-per-kind workflow below. A directory can hold
one singular capture or one campaign; the command refuses to overwrite either.

```bash
./harness/core/run/run-single.sh S04 30 --no-runtime
base=artifacts/runs/<suite>/scenarios/S04
for kind in trace gcdump dump; do
  cp -R "${base}" "${base}-${kind}"
  [[ "${kind}" != dump ]] || export PERFLAB_DUMP_ACK=i-understand-sensitive-dump
  ./harness/core/capture/capture-runtime.sh "${base}-${kind}" "${kind}" 30
  ./harness/core/capture/normalize-runtime.sh "${base}-${kind}"
done
```

Start from a measurement created with `--no-runtime`, or copy a clean
measurement-only package before each command. `stacks` may be added to the
loop and is captured directly. Set
`PERFLAB_ENABLE_DOTNET_MONITOR_STACKS=false` only for an environment where that
endpoint is unavailable; the adapter then records its CPU-trace fallback.
Process dumps can contain secrets or personal data and should remain restricted.

Ordinary scenarios still collect all passive evidence together. Metrics,
logs, distributed traces, dependency snapshots, process/deployment inventory,
load evidence, and provenance are observed during the run where appropriate and
queried or published after load. Only these invasive runtime captures require a
kind or preset. Routine CI comparisons should use the clean measurement;
campaign throughput and latency are never baseline or gate inputs.

On a **local** target, `capture-runtime` recreates the app in `diagnose` mode
before any load-bearing diagnostic (clearing leaks/pools left by the measurement)
and resolves the target by runtime identity, not container PID. On a **remote**
target it does **not** recreate the app (it is not owned). Load-bearing diagnostics
drive the manifest-recorded workload; dump-only does not. The command leaves a
**raw** capture (normalize it offline; the in-place normalizer needs the local
tools container). For .NET, a `stacks` request captures dotnet-monitor's text
stack output directly and records any explicitly configured fallback in
`runtime/capture.json`.

## Scenario catalog

Each lab ships a `scenarios.tsv` — a TAB-separated file (id, name, method, path,
body, target, diagnostic, connections) parsed with `awk`. The tables below state
each lab's **intended** mechanism for maintainers and presenters; a scenario id is
only a **correlation key**, never proof of a defect — an AI diagnosis must still
prove it from the captured evidence and the source. The **Diagnostic** column is
the per-scenario runtime capture (on by default; opt out with `--no-runtime`).

### scenariolab — `labs/scenariolab/scenarios.tsv` (`S00`–`S27`)

One healthy control (`S00`) plus 27 deliberately planted behaviors.

| ID | Area | Workload (conns) | Injected mechanism | Expected symptom | Diagnostic |
|---|---|---|---|---|---|
| S00 | Control | Catalog rec. (64) | Bounded query + linear in-memory sort | Healthy baseline | CPU trace |
| S01 | CPU | Catalog rec. (64) | Ranks 2,500 candidates via nested comparisons | API CPU saturation, hot ranking loop | CPU trace |
| S02 | Threading | Threading (128) | Sync wait on `Task.Delay` in request path | Blocked threads, ThreadPool growth, tail latency | Stacks→trace |
| S03 | Synchronization | Threading (96) | Process-wide semaphore held across DB + delay | Serialized requests, p50≈p99 | Stacks→trace |
| S04 | Memory retention | Memory (32) | Static event subscribers retain 64 KiB arrays | Live heap grows to cap, survives GC | GC dump |
| S05 | Allocation/GC | Memory (32) | Repeated 128 KiB buffers, Base64, JSON copies | LOH churn, GC pressure | CPU trace |
| S06 | Scheduling | Threading (64) | 128 `Task.Run` + buffers per request | Excess work items, scheduling + alloc overhead | CPU trace |
| S07 | PG queries | Customer orders (48) | N+1: one item query per order (×50) | Amplified DB calls, pool-wait latency | Stacks→trace |
| S08 | PG pagination | Deep order page (48) | Large `OFFSET` (page 100) | Rows scanned then discarded; mild at smoke scale | Stacks→trace |
| S09 | PG lifecycle | Customer orders (64) | Npgsql connections retained in a static list | Pool drains, acquisition waits/timeouts | Stacks→trace |
| S10 | PG locking | Order create (64) | Hot-row txn open across Redis + delay + publish | Lock waits, serialized/slow POSTs | Stacks→trace |
| S11 | EF materialization | Customer orders (32) | Whole tracked graph loaded before in-memory paging | Excess rows/alloc, tracking overhead | GC dump |
| S12 | Cache coordination | Catalog cache (128) | Uncoalesced cache-miss refresh + delayed DB | Cache stampede, duplicated queries | Stacks→trace |
| S13 | Redis pattern | Catalog cache (64) | 100 fragments fetched sequentially | Many serialized Redis ops, high dep time | Stacks→trace |
| S14 | Redis sockets | Catalog cache (64) | `ConnectionMultiplexer` per request | Redis connection churn, TIME_WAIT | CPU trace |
| S15 | Redis keys | Catalog cache (64) | Unique GUID key per request, no expiry | Keyspace/memory growth, ~no hits | GC dump |
| S16 | RabbitMQ sockets | Order create (64) | Connection + channel per publish | Broker churn, TCP overhead, low throughput | CPU trace |
| S17 | Consumer backpressure | Order create → worker (48) | 1 dispatch slot, prefetch 500, 100 ms blocking | Queue hits cap → messages dead-lettered (loss) | Stacks→trace |
| S18 | Retry behavior | Poison order → worker (8) | Immediate requeue up to 50× | Retry storm, `orders.retried` count, dead-letters | Stacks→trace |
| S19 | Channel ownership | Order create (128) | One shared `IChannel` across publishers | Unsafe by contract; measures healthy (see note) | CPU trace |
| S20 | Message ownership | Order create → worker (48) | Broker-owned delivery memory retained uncopied | Retained payload, worker heap growth | GC dump |
| S21 | PG pool—low | Pool endpoint (48) | Npgsql pool capped at 2, lease held per request | Acquisition wait, pool timeouts (non-2xx) | trace + pool |
| S22 | PG pool—high | Pool endpoint (96) | Npgsql pool of 64 for the same work | Large PG backend/socket footprint | trace + pool |
| S23 | Redis pool—low | Pool endpoint (64) | One exclusively-leased multiplexer | Client lease queue, low throughput | trace + pool |
| S24 | Redis pool—high | Pool endpoint (128) | 32 multiplexers + exclusive slots | `connected_clients`/socket inflation | trace + pool |
| S25 | HTTP pool—low | Upstream call (64) | Handler limited to 2 conns vs 100 ms dep | `time_in_queue`, long tails | trace + HTTP |
| S26 | HTTP pool—high | Upstream call (128) | Handler with 128 pooled conns | High open/idle TCP count | trace + HTTP |
| S27 | DB deadlock | Deadlock endpoint (16) | Two txns lock rows 1 & 2 in opposite order (1→2 vs 2→1) | PG deadlock detector aborts one side (40P01) → ~half 409 | Stacks→trace |

**S17/S18 — async loss.** Both push work onto RabbitMQ and return 200, so HTTP
metrics look clean while the failure is on the broker: S17 fills the queue to its
`x-max-length` cap and dead-letters the overflow (message loss, not slow drain);
S18's poison messages requeue into a retry storm. Read `rabbitmq-queues.json` and
the `orders.retried` counter, not the HTTP summary.

**S19 — channel ownership.** Publishing from many requests through one shared
`IChannel` is unsafe by the .NET client's contract, but it did not reproduce here
(~106k publishes at 128 conns, zero failures, highest throughput in the lab).
Diagnose it from the source pattern, not an error count.

**S21–S26 — pools.** StackExchange.Redis has no fixed-size pool (share one
`ConnectionMultiplexer`); S23/S24 wrap it in a custom pool to show too-few-slots
vs too-many-multiplexers. Npgsql pools by default (S21/S22 cap/oversize it);
`HttpClient` pools live in `SocketsHttpHandler` (S25/S26 starve/oversize it). The
fix is one right-sized long-lived client, not a bigger custom pool.

**S27 — real deadlock (vs S10's convoy).** `GET /api/inventory/deadlock`
alternates the lock order per request, so concurrent transactions lock inventory
rows 1 and 2 as 1→2 and 2→1 and form a **circular wait**; PostgreSQL's detector
aborts one side with `SQLSTATE 40P01`, surfaced as a `409`. This is the case S10
cannot produce: S10's requests all lock a single row, which serializes into a
convoy but never cycles. Evidence: the `deadlocks` counter in
`dependencies/postgres-deadlocks.csv` (`pg_stat_database`) and a `degraded`
health/error rate from the 409s — not `pg_stat_statements`, which shows only the
`SELECT … FOR UPDATE` that ran.

### ecommerce — `labs/ecommerce/scenarios.tsv` (`E00`–`E14`)

A JWT-protected CRUD API: every request authenticates once in k6 `setup()`, then
the scenarios sweep product/order/user reads and writes. Some exercise common
real-world anti-patterns (offset pagination, non-sargable `ILIKE` search, a
`count(*)` per request, unindexed sorts); others are clean primary-key controls.
Seeded at `smoke` scale (20k products / 200 users / 20k orders).

| ID | Name | Workload (conns) | Exercises | Diagnostic |
|---|---|---|---|---|
| E00 | control-products | Product list, pg 1 (64) | Paged list baseline; `count(*)` + page query per request | CPU trace |
| E01 | login-throughput | Login (32) | PBKDF2 (100k) password hash — CPU-bound by design | CPU trace |
| E02 | product-list-shallow | Product list, pg 1 (64) | Same as E00, captured with stacks | Stacks |
| E03 | product-list-deep | Product list, pg 500 (64) | Deep `OFFSET` — rows scanned then discarded | Stacks |
| E04 | product-list-large-page | Product list, 100/pg (48) | Large page — bigger result + serialization | CPU trace |
| E05 | product-search | Product search (64) | Non-sargable `name ILIKE '%…%'` seq scan, run twice (count+page) | CPU trace |
| E06 | product-get | Product by id (64) | Single product by PK — clean control | CPU trace |
| E07 | product-create | Product create (32) | Insert one product | Stacks |
| E08 | product-update | Product update (32) | Patch one product; body varies per iteration → real `UPDATE` | Stacks |
| E09 | orders-list-shallow | Orders list, pg 1 (64) | Order list sorted by unindexed `created_at` + per-request count | Stacks |
| E10 | orders-list-deep | Orders list, pg 50 (48) | Deep `OFFSET` + unindexed `created_at` sort | Stacks |
| E11 | order-get | Order by id (64) | One order + items (`Include`, PK + indexed join) | CPU trace |
| E12 | order-create | Order create (32) | Transactional write: lookup + order + item inserts | Stacks→trace |
| E13 | users-list | Users list, pg 1 (48) | Paged users (small table); count negligible | CPU trace |
| E14 | users-me | Current user (64) | Current user by PK — clean control | CPU trace |

## Evidence package

Each run is a self-contained package — the single input to the AI phase. A suite
(`run-single/multiple/all`) nests one full package per scenario under
`scenarios/<ID>/`:

```
artifacts/runs/<run-id>/                 # a suite run
├── manifest.json                        # suite status + scenario index (profile, loadGenerator, git rev)
├── facts.json                           # aggregate index across scenarios
└── scenarios/<ID>/                       # one self-contained scenario package:
    ├── manifest.json                    # scenario, workload, loadGenerator, profile, telemetryRunId
    ├── facts.json                       # this scenario's observations (an index, not conclusions)
    ├── benchmark/
    │   ├── observations.json            # normalized SLIs: req/s, latency p50/p90/p95/p99, error/dropped
    │   ├── compatibility.json           # k6/JMeter generator, workload, configuration identity
    │   ├── k6-summary.json  k6.txt       # measure phase (or wrk.txt / jmeter-summary-v1.json)
    │   ├── k6-warmup.json  k6-warmup.txt
    │   ├── jmeter-summary-v1.json        # JMeter measure (plus jtl-metadata.json, observations.json)
    │   ├── diagnostic-k6-*.{json,txt}    # the separate diagnose-mode load
    │   └── diagnostic-compatibility.json # its envelope; the measured compatibility.json is never rewritten
    ├── telemetry/
    │   ├── capture-status.json           # metrics/traces/logs/profiles capture states
    │   ├── metrics/                      # Prometheus range (gauges) + instant (counters)
    │   ├── traces/                       # Tempo search + the slowest traces
    │   ├── logs/                         # Loki range query
    │   └── profiles/                     # Selected Pyroscope flame graphs (opt-in)
    ├── dependencies/                     # live snapshots (files present depend on the lab):
    │   ├── postgres-{statements,activity,connections,deadlocks,query-plan}.*   # + *-midload
    │   ├── redis-{info,latency,clients}.*                    # scenariolab only
    │   ├── rabbitmq-{queues,channels,connections,broker-metrics}.*   # scenariolab only
    │   └── container-stats-midload.ndjson  api-net-tcp*.txt  docker-compose-ps.json
    ├── runtime/                          # dotnet-monitor capture (on by default)
    │   ├── capture.json                  # requested vs effective diagnostic
    │   ├── processes.json  processes-diagnostic.json
    │   └── api/ | worker/                # cpu.nettrace, before/after.gcdump, stacks.txt, process.dmp
    ├── source/                           # tool-versions, git-status, git-diff-stat
    └── analysis/
        ├── trend-report.json            # leak/trend: least-squares slope + growth, GROWING flags
        └── runtime/                     # normalized: cpu.speedscope.json, *-gcdump/dump-report.txt
```

### Capture states — absence is not health

A backend that answers `200` with an empty result set still writes a file, so a
reader sees an artifact and assumes the signal was captured. For a signal whose
absence can only mean a broken scrape or a renamed selector, that is the worst
outcome available: a green run carrying no saturation evidence at all. Every
query in `telemetry/queries.ndjson` therefore carries one of:

| State | Means | What to repair |
|---|---|---|
| `captured` | the query returned data | — |
| `failed` | the query errored | the backend or the URL |
| `empty-required` | reachable, returned **nothing**, and the role is required | the scrape, the selector, or the instrumentation |
| `empty` | reachable, returned nothing, role is conditional | nothing — it is a fact about the workload |
| `truncated` | hit the result limit | raise `PERFLAB_LOG_LIMIT` / `PERFLAB_TRACE_LIMIT` |
| `missing` | the backend was unreachable | the backend |

Required roles belong to the **runtime adapter**, not to an operator setting:
under any load a .NET process has CPU, a working set, a GC heap, a thread pool,
and served requests, so an empty series for one of those is a broken capture.
Everything else is conditional — `database_pool_metrics` is legitimately empty
for a scenario that never opens a connection, and calling that "missing
evidence" would mark a correct package incomplete. An `empty-required` role
degrades the package to `partial`.

**Logs** are the case where the same emptiness means opposite things, so the
decision is explicit and recorded in `telemetry/logs/policy.json`:

- `Microsoft.AspNetCore: Warning` (the default) suppresses request logging, so a
  healthy path emits nothing and an empty window is **not** a gap.
- With `PERFLAB_REQUEST_LOGGING=Information`, an empty window **is** a gap and
  degrades the package. The knob registers ASP.NET Core's HTTP logging
  middleware (method, path, status, duration -- never bodies or headers) and is
  the only thing that turns it on: raising the `Microsoft.AspNetCore` category
  level does **not** produce per-request records on this framework version.
  With the knob off, the middleware is not registered at all, so a measurement
  run carries no request-logging overhead.
- `PERFLAB_LOGS_REQUIRED=0|1` overrides the level-derived default either way.

Per-request logging is not a blanket fix: S04 sustains ~19.6k rps, where it
emits roughly 1.2M lines per 30s window — enough to perturb the measurement and
instantly truncate the log budget. Turn it on for a low-rate investigation, not
for every run.

Collector health is captured on **both** the local and remote paths
(`telemetry_export_failures`, `telemetry_queue_utilization`,
`telemetry_refused`): every other signal in the package is read *through* the
collector, so a silent drop there makes an incomplete capture look complete one
layer below where the capture states can see it.

`facts.json` is an **index** — observations with units and raw-source paths, not
conclusions. The suite index carries, per scenario, both a pipeline `status`
(did the run complete) and a workload `health`/`errorRate` (`degraded` when the
HTTP error rate exceeds `PERFLAB_MAX_HTTP_ERROR_RATE`, default 5%), so a scenario
that ran green while most requests failed — a saturated pool, say — no longer
reads as clean. HTTP metrics still cannot see async loss: for broker-backed
scenarios cross-check `dependencies/rabbitmq-queues.json`. Binary runtime dumps
stay local; the AI normally reads normalized summaries. See
[`BLUEPRINT.md`](BLUEPRINT.md) for the full contract.

## AI diagnosis

The AI reads the immutable evidence package — no pasted screenshots or dumps. Two
entry points, both behind a human review gate.

**Manual (interactive, human-in-the-loop)** — print the evidence-first prompt and
open an authenticated interactive `claude` session:

```bash
DIR="$(ls -td artifacts/runs/suite-* | head -1)"   # newest suite (or a child, or a flat package)
./harness/ai/scripts/print-ai-prompt.sh "${DIR}"
claude
```

Paste the printed prompt. It works for a suite root (Claude analyzes each child
and compares them, using `S00` as a baseline), a single suite child
(`.../scenarios/S07`), or a flat package. Template:
`harness/ai/interactive-diagnosis-prompt.md`.

**Automated (structured, read-only)** — produce a schema-enforced
`analysis/diagnosis.json`. Target a **flat package or a suite child, never a suite
root**:

```bash
./harness/ai/scripts/analyze-with-claude.sh artifacts/runs/<run-id>/scenarios/S07
```

It runs `claude -p` with `--allowedTools "Read,Grep,Glob"` (it cannot edit files or
run commands) and `--json-schema`, writing `analysis/claude-raw.json` and the
normalized `analysis/diagnosis.json`. Optional knobs:

```bash
export CLAUDE_MODEL=sonnet
export CLAUDE_MAX_BUDGET_USD=5
```

**Apply a reviewed fix** — the only script that edits source, gated on a diagnosis
existing:

```bash
./harness/ai/scripts/claude-fix.sh artifacts/runs/<run-id>
```

It opens an interactive edit session, implements the minimal change from the
approved diagnosis, and builds via the descriptor's build command. Intentionally
not an unattended auto-fix.

## Validation protocol

For a defensible before/after comparison, hold everything constant except the
proposed fix:

1. Same source revision except the fix; same lab, scenario, endpoint, request
   body, connection count, duration, and Docker resources.
2. Same `SEED_SCALE` — and reseed (`down -v` + bring-up) when a write scenario or
   a data-scale test has mutated the dataset.
3. Same **load generator** — wrk, k6, and JMeter numbers are not comparable, so
   hold `PERFLAB_LOAD_GENERATOR` constant across the pair.
4. Reset Redis, RabbitMQ queues, and `pg_stat_statements` before each measurement
   (the harness does this at the start of every scenario).
5. Warm up, then take **repeated** measurements rather than one: `run-repeat.sh`
   reports median / stddev / CV, and `compare-runs.sh` flags a candidate only when
   the delta is significant.
6. Keep diagnostic captures **separate** from the reported numbers (`--no-runtime`
   for the measurement; read the diagnostic run only for the mechanism).
7. Check response correctness and error count **before** comparing speed.
8. Require a **mechanism-specific gate**: the hotspot disappears, the thread-pool
   queue stays bounded, live heap plateaus, DB spans collapse, the plan uses the
   intended access path, pool timeouts vanish, cache refreshes coalesce, the
   RabbitMQ backlog drains, or the deadlock/409s stop.

Docker Desktop measurements are comparative numbers for this machine, not
production capacity claims.

## Safety limits

- API: 1 CPU, 768 MiB. Worker: 0.75 CPU, 512 MiB.
- Normal PostgreSQL pool: 20 connections, 5-second connect/command timeout.
- Pool experiments (deliberately unsafe extremes, not a fixed pair): Npgsql 2
  (`S21`) vs 64 (`S22`); Redis pseudo-pool 1 (`S23`) vs 32 (`S24`); HTTP 2
  (`S25`) vs 128 (`S26`) — each below the local server/socket limits.
- Redis: `allkeys-lru` eviction. RabbitMQ work queue is length-capped
  (`x-max-length`), so `S17` overflow dead-letters rather than growing unbounded.
- Poison-message requeue: local cap of 50 before dead-lettering (`S18`).
- Only one injected behavior is active per process start; a suite runs scenarios
  sequentially in fresh containers, never several defects at once.
- All datasets are synthetic and every published port is loopback-only.

Stop a lab's stack while preserving volumes, or reset everything:

```bash
docker compose -f labs/scenariolab/compose.yaml down       # stop; keep data
docker compose -f labs/scenariolab/compose.yaml down -v    # full reset (deletes db/cache/broker/telemetry volumes)
```

## Operational cautions

- Hold `PERFLAB_LOAD_GENERATOR` constant across any before/after comparison.
  JMeter is container-only (`PERFLAB_JMETER_IMAGE`); do not install host Java.
- Hold `PERFLAB_CONTINUOUS_PROFILING` constant across an A/B pair. The CLR
  profiler perturbs latency (and on aarch64 hosts the wrapper also disables
  tiered compilation while profiling unless `PERFLAB_PROFILING_KEEP_TIERING=1`);
  default-off runs are the clean benchmark path. `compare-runs.sh` refuses to
  compare a profiling-on package against a profiling-off one, and refuses two
  profiling-on packages that disagree on keep-tiering.
- Runtime diagnostics are **on by default** and ~double wall-clock per scenario;
  because profiling perturbs latency, use `--no-runtime` for the numbers in an A/B
  latency comparison and read the diagnostic run only for the mechanism.
- Write scenarios (e.g. product/order create) mutate the seeded dataset and it
  **persists in the DB volume across runs** — reset with `docker compose -f
  labs/<lab>/compose.yaml down -v` before a run whose read scenarios need the
  pristine seed, or their table sizes (and timings) will drift.
- `gcdump` forces a full collection; don't read it as steady-state heap.
- A `stacks` request captures text stacks unless the endpoint was explicitly
  disabled; confirm the effective kind in `runtime/capture.json`.
- `capture-evidence` fails loud if telemetry or a dependency is unreachable, rather
  than emitting a silently empty package.

## Continuous profiling troubleshooting

- **Backend ready but empty.** `/ready` on port 4040 can succeed before the .NET
  profiler has uploaded a 10s window. Capture retries like Loki/Tempo. Check
  `telemetry/profiles/query.json` for the exact selector, window, and the
  recorded `ready` probe, and confirm `PERFLAB_CONTINUOUS_PROFILING=1` was set
  **before** `compose up` so the entrypoint exported `CORECLR_*` / `LD_PRELOAD`.
  Each service entry in `telemetry/profiles-signal.json` records the last
  `httpStatus`: an HTTP 4xx/5xx means Pyroscope was reachable but rejected the
  selector (`missing`, with the status in the reason), which is different from
  an unreachable backend (`ready=false`, "unreachable" in the reason).
- **Agent not loaded.** `CORECLR_*` and `LD_PRELOAD` are exported only into PID 1
  by the entrypoint, not into `docker exec` shells. Check
  `tr '\0' '\n' < /proc/1/environ` inside the app container, or look at
  `/opt/pyroscope/logs`. If profiler logs say the profiler is explicitly
  disabled, the wrapper took the disabled path — recreate the app containers
  after toggling `PERFLAB_CONTINUOUS_PROFILING`. On `aarch64`, pyroscope-dotnet
  1.5.1 still inherits Datadog's ARM64 gate: the wrapper sets
  `DD_INTERNAL_PROFILING_ENABLED_ARM64=1`. If logs say "Continuous Profiler is
  not enabled for ARM64 architecture", that flag did not reach the process.
  If logs say "The CPU limit is too low for the profiler to work properly",
  the container quota is below the profiler's default. The versioned provider
  descriptor permits a validated `0.1` threshold, so lab workers at
  `cpus: 0.75` still profile.
- **Only `Unknown-Type.Unknown-Method` frames (aarch64 hosts).** pyroscope-dotnet
  1.5.1 has no supported arm64 build; the gated aarch64 library resolves frames
  of first-JIT and ReadyToRun code but loses every frame of a method once tiered
  compilation re-jits it, so a flame graph collapses to one unknown frame
  ~20-30s after process start (live-verified: `DOTNET_TieredCompilation=0`
  keeps sampling rich and stable; `TieredPGO=0` does not help). On aarch64 the
  wrapper therefore disables tiered compilation while profiling is on and
  labels the profile `dotnet_tiered_compilation:0`; set
  `PERFLAB_PROFILING_KEEP_TIERING=1` to opt out. Compose interpolates that
  variable into the ScenarioLab API/worker and eCommerce API services (`0`
  when unset). Each service entry in
  `telemetry/profiles-signal.json` carries `symbolization`
  (`symbolized|partial|unknown`) and `symbolizedNodes`; an `unknown` profile is
  still `captured` content but is flagged as non-attributable. amd64 images
  (`TARGETARCH=amd64`) run the supported build with tiering untouched.
- **Wrong architecture.** Images download `glibc-x86_64` or `glibc-aarch64` from
  `TARGETARCH`, not the host. A `exec format error` or native-load failure in
  `/opt/pyroscope/logs` means the image was built for the other architecture.
- **Unwritable log directory.** The profiler logs to `/opt/pyroscope/logs` (mode
  0777). If that directory is missing or not writable by `$APP_UID`, native
  load fails. The images create it in the Dockerfile.
- **Invalid labels.** `PYROSCOPE_LABELS` values must be bounded tokens (no colon,
  comma, or space). The wrapper rejects `PERF_RUN_ID` / scenario values that
  cannot be labels. Secrets, URLs, and user IDs must never be labels. Do not
  add `service_name` to `PYROSCOPE_LABELS`: pyroscope-dotnet 1.5.1 already
  labels the Push series from `PYROSCOPE_APPLICATION_NAME`, and a duplicate
  `service_name` makes Grafana Pyroscope v2 return HTTP 400.
- **Ingestion delay / empty exact window.** Pyroscope stores each agent upload
  at a single timestamp. The wrapper sets `DD_PROFILING_UPLOAD_PERIOD=10` so a
  30s measurement window holds several points; with the inherited 60s period an
  active process can legitimately have **no** point inside the window and the
  required profile stays `delayed` (package `partial`). Capture polls like
  Loki/Tempo. Truncation at 16384 nodes is recorded as `truncated` and remains
  usable.

## No host jq

Config is bash, the scenario catalog is TSV (`awk`), JSON the harness emits is
built with `printf`, and the JSON it must parse (Prometheus/Tempo/Loki, Claude
output) is parsed by `jq` **inside Docker** (`jqd`). This removes the host jq
dependency and its Windows CRLF/MSYS pitfalls.

## Adding a project or runtime

See [`BLUEPRINT.md`](BLUEPRINT.md#extending-the-harness). In short: a new project
adds `labs/<project>/` (its own `lab.config.sh` + `scenarios.tsv` + compose/infra)
pointing at an app under `source/<rt>/<project>/`; a new runtime adds
`harness/adapters/runtime/<rt>/` plus a thin instrumentation shim. The harness
core and adapters never change.
