# .NET Performance Engineering + AI PoC

This repository is a local-only performance-engineering lab for .NET 10. It runs a synthetic commerce API and order worker against PostgreSQL, Redis, and RabbitMQ, exports OpenTelemetry logs/metrics/traces to Grafana OTEL-LGTM, exposes runtime diagnostics through a `dotnet-monitor` sidecar, packages evidence on the host filesystem, and gives Claude Code a controlled evidence-first diagnosis/fix workflow.

No Azure, S3, Blob Storage, or other cloud service is used.

## Architecture

```mermaid
flowchart TD
    WRK[wrk or k6 + scenario runner on macOS] --> API[ASP.NET Core API<br/>.NET 10]
    API --> PG[(PostgreSQL)]
    API --> REDIS[(Redis)]
    API --> RABBIT[(RabbitMQ)]
    RABBIT --> WORKER[Order worker<br/>.NET 10]

    API -- OTLP --> LGTM[Grafana OTEL-LGTM<br/>Collector + Prometheus + Loki + Tempo + Pyroscope]
    WORKER -- OTLP --> LGTM

    API -- diagnostic socket --> MONITOR[dotnet-monitor]
    WORKER -- diagnostic socket --> MONITOR
    MONITOR --> RUNTIME[nettrace / gcdump / stacks / dump]

    WRK --> EVIDENCE[Local evidence package]
    LGTM --> EVIDENCE
    PG --> EVIDENCE
    REDIS --> EVIDENCE
    RABBIT --> EVIDENCE
    RUNTIME --> NORMALIZER[One-shot diagnostics tools container]
    NORMALIZER --> EVIDENCE

    EVIDENCE --> CLAUDE[Claude Code CLI<br/>read-only structured diagnosis]
    CLAUDE --> REVIEW[Human review gate]
    REVIEW --> FIX[Interactive Claude Code fix]
    FIX --> VALIDATE[Same benchmark + correctness gates]
```

## Components and local ports

| Component | Purpose | Host address |
|---|---|---|
| API | Workload endpoints | `http://127.0.0.1:8080` |
| Grafana | Dashboard, Explore, trace/log correlation | `http://127.0.0.1:3000` (`admin` / `admin`) |
| Prometheus | Metrics query API | `http://127.0.0.1:9090` |
| Loki | Log query API | `http://127.0.0.1:3100` |
| Tempo | Trace query API and optional MCP | `http://127.0.0.1:3200` |
| Pyroscope | Profiles backend, reachable but unused (see note below) | `http://127.0.0.1:4040` |
| dotnet-monitor | Diagnostic API | `http://127.0.0.1:52323` |
| PostgreSQL | Lab database | `127.0.0.1:5432` |
| Redis | Lab cache | `127.0.0.1:6379` |
| RabbitMQ management | Queue inspection | `http://127.0.0.1:15672` (`perflab` / `perflab`) |
| RabbitMQ Prometheus | Broker metrics | `http://127.0.0.1:15692/metrics` |

All published ports are bound to loopback. OTEL-LGTM persists its data in the `lgtm-data` Docker volume; evidence intended for AI is copied to `artifacts/runs`.

Pyroscope ships inside the OTEL-LGTM image and its port is published, but no
application sends it profiles: there is no Pyroscope SDK reference in the
solution, and `/api/apps` reports no registered application. CPU profiling in
this lab comes from the `dotnet-monitor` sidecar instead, captured by
`scripts/capture-runtime.sh` and converted to Speedscope by
`scripts/normalize-runtime.sh`. Treat Pyroscope as available-but-empty.

## Prerequisites

- Docker Desktop with Compose
- .NET SDK 10.0.101 or a later 10.0 patch
- `wrk`, `jq`, `curl`, and Git
- `k6` only if you opt in to the k6 load generator with `PERFLAB_LOAD_GENERATOR=k6`
- Claude Code CLI authenticated with your Anthropic account or configured provider
- `uvx` only if the generated Grafana MCP configuration uses the client-side `mcp-grafana` server

## Build without containers

```bash
dotnet restore PerfLab.slnx
dotnet build PerfLab.slnx --configuration Release --no-restore
```

## Quick start

Start a healthy control stack:

```bash
cp .env.example .env
docker compose up -d --build
curl http://127.0.0.1:8080/health/ready
```

Open Grafana and choose the provisioned **.NET Performance Engineering Lab** dashboard. Use Explore for detailed Tempo traces and Loki logs.

Run one controlled scenario under a suite run ID:

```bash
./scripts/run-single.sh S01 30
```

The command performs a deterministic dependency reset, recreates API/worker containers with the selected `PERF_SCENARIO` and unique telemetry correlation key, warms up for 10 seconds, runs the selected load generator (`wrk` by default), and captures telemetry/dependency snapshots. It prints the suite evidence directory, for example:

```text
artifacts/runs/suite-20260822T120000Z/scenarios/S01
```

Use the lower-level `./scripts/run-scenario.sh S01 30` only when a flat, non-suite evidence package is specifically required. The control is `S00`. Scenario workload definitions are in `scenarios/scenarios.json`; they deliberately use neutral names so the identifier itself is not a diagnosis.

## Single, multiple, and all-scenario scripts

The convenience scripts all use the same suite format and accept an optional duration. Runtime capture remains a separate workload so its overhead never contaminates the reported measurement:

| Scope | Measurement only | Measurement plus runtime evidence |
|---|---|---|
| Single | `./scripts/run-single.sh S07 30` | `./scripts/run-single.sh S07 30 --with-runtime` |
| Multiple | `./scripts/run-multiple.sh S07,S12,S17 30` | `./scripts/run-multiple.sh S07,S12,S17 30 --with-runtime` |
| All | `./scripts/run-all.sh 30` | `./scripts/run-all.sh 30 --with-runtime --continue-on-error` |

`run-scenarios.sh` remains the underlying general-purpose runner, so these are equivalent:

```bash
./scripts/run-single.sh S21 30
./scripts/run-scenarios.sh S21 30

./scripts/run-multiple.sh S21,S22,S23,S24 30
./scripts/run-scenarios.sh S21,S22,S23,S24 30

./scripts/run-all.sh 30
./scripts/run-scenarios.sh all 30
```

An all-scenario run currently executes 27 measurements (`S00` through `S26`). With 30-second measurement and diagnostic phases it includes at least 27 minutes of workload time, plus warm-ups, dependency resets, container recreation, OTLP flushes, and artifact normalization.

## Multi-scenario suite runs

Use the suite runner directly when several scenarios must belong to one top-level run ID. Pass a comma-separated list, or `all` for the complete catalog:

```bash
./scripts/run-scenarios.sh S01,S07,S12 30
./scripts/run-scenarios.sh all 30
```

The scenarios execute sequentially so dependency resets, Docker resource contention, and process-local state cannot contaminate one another. The suite has one user-facing run ID, while each scenario receives a unique `telemetryRunId` for unambiguous trace and log correlation.

Add each scenario's recommended runtime capture and normalization with `--with-runtime`:

```bash
./scripts/run-scenarios.sh S01,S07,S12 30 --with-runtime
```

Catalog entries that request managed stacks automatically use a CPU-trace fallback in this Docker Desktop topology. The requested and effective diagnostics are recorded in each child's `runtime/capture.json`. Set `PERFLAB_ENABLE_DOTNET_MONITOR_STACKS=true` only when intentionally retesting dotnet-monitor's in-process `/stacks` endpoint.

By default the suite stops on the first failure and preserves all partial evidence. Use `--continue-on-error` when a full sweep should attempt every selected scenario; the final suite status is `completed-with-errors` and the command still exits nonzero if any scenario failed:

```bash
./scripts/run-scenarios.sh all 30 --with-runtime --continue-on-error
```

The resulting package is grouped under one run directory:

```text
artifacts/runs/suite-20260822T120000Z/
├── manifest.json                 # suite status and scenario index
├── facts.json                    # aggregate benchmark facts
└── scenarios/
    ├── S01/                      # complete single-scenario evidence package
    │   ├── manifest.json
    │   ├── facts.json
    │   ├── benchmark/
    │   ├── telemetry/
    │   ├── dependencies/
    │   ├── runtime/
    │   └── analysis/
    ├── S07/
    └── S12/
```

Run Claude against an individual child directory when diagnosing an isolated fault, for example `artifacts/runs/<suite-run-id>/scenarios/S07`. This preserves the one-fault-at-a-time reasoning model while keeping the complete experiment under one suite ID.

## Load generator selection

wrk is the default and remains fully supported. k6 is opt-in through a single
environment variable, honoured by `run-scenario.sh`, every `run-*` wrapper, and
`capture-runtime.sh`:

```bash
./scripts/run-single.sh S01 30                             # wrk (default)
PERFLAB_LOAD_GENERATOR=k6 ./scripts/run-single.sh S01 30   # k6
PERFLAB_LOAD_GENERATOR=k6 ./scripts/run-all.sh 30 --with-runtime
```

The choice is recorded in `manifest.json` at `workload.loadGenerator` and in
`facts.json` at `loadGenerator`, so every evidence package states which tool
produced its numbers. `capture-evidence.sh` reads that field rather than a flag,
so it selects the right benchmark parser without being told which generator ran.
It runs automatically at the end of each scenario and is not meant to be re-run
later; see [Evidence](#evidence). A diagnostic capture defaults to the generator
that produced the measurement.

Workload definitions live side by side and neither is generated from the other:
`scripts/wrk/scenario.lua` and `scripts/k6/scenario.js` read the same
`PERF_METHOD`, `PERF_PATH`, `PERF_BODY`, and `PERF_RUN_ID` contract. k6 also
honours `PERF_BASE_URL`. wrk's `-c<connections>` maps to k6's `--vus`, with
connection reuse pinned on so one VU holds one connection.

What differs, and why it matters:

| Aspect | wrk | k6 |
|---|---|---|
| Latency percentiles in `facts.json` | strings such as `43.21ms`, `unit: "wrk-duration"` | numbers in `unit: "ms"` |
| Throughput | parsed from `Requests/sec:` text | `.metrics.http_reqs.rate` |
| Non-2xx/3xx vs transport failures | reported separately by wrk itself | separated by the lab's own counters in `scripts/k6/scenario.js`, because the built-in `http_req_failed` merges them |
| Client-side cost per request | C, negligible | Go runtime plus a JS VM per VU |

The load generator is **part of the held-constant configuration**: compare wrk
with wrk and k6 with k6.

At steady state the two agree closely. Measured against one fully warmed `S00`
process on a 16-core host, 64 connections, 20 seconds each, run in a controlled
order:

| Client | Throughput |
|---|---|
| `wrk -t4 -c64` | 5,149 req/s |
| `wrk -t12 -c64` | 5,360 req/s |
| `k6 --vus 64` | 5,088 req/s |

Within about 5%, so the generator choice is not what moves these numbers, and
wrk's hardcoded four threads are not a client-side ceiling at this connection
count.

### The 10-second warm-up is the dominant measurement artifact

The first measurement taken against a freshly recreated container reports roughly
2,000 req/s whichever client runs it — 2,015 req/s for a first `wrk -t4` run and
2,033 req/s for a first `k6` run — and every later run against the same warm
process converges near 5,000 req/s. The reported figure is therefore about 2.5x
low on a light endpoint, because `run-scenario.sh` warms up for 10 seconds and
the process has not reached steady state: tiered JIT promotion, PostgreSQL plan
caching, and pool fill are all still in progress.

This is generator-independent and pre-existing, so it does not affect wrk-to-k6
comparability, and it is invisible on server-bound scenarios: `S01` measures
176 req/s under wrk and 183 req/s under k6, far below any warm-up ceiling.

It does mean that absolute throughput for fast endpoints — `S00` above all — is
understated, so a `S00`-versus-`Sxx` ratio understates the injected defect.
Lengthening the warm-up would change every existing number and break
comparability with all prior evidence, so it is deliberately left alone here.
Treat it as a known bound, and follow the validation protocol's repetition rule
when an absolute ceiling is the question.

k6's advantage for this lab is that `facts.json` no longer depends on parsing
human-readable text, and that non-2xx responses are distinguishable from
connection failures — which matters for the pool-capacity scenarios, where a
pool timeout and a refused connection are different findings.

## Runtime diagnostics

Performance measurement and runtime capture are separate runs. Diagnostic tools perturb the target process, and `gcdump` triggers a full collection.

Use the capture recommended by the scenario catalog:

```bash
./scripts/capture-runtime.sh artifacts/runs/<run-id>
```

If the recommendation is `stacks`, the default local behavior records `trace` instead and documents the fallback in `runtime/capture.json`. This avoids treating the known dotnet-monitor sidecar profiler-channel HTTP 500 as a failed application scenario.

Or choose one explicitly:

```bash
./scripts/capture-runtime.sh artifacts/runs/<run-id> trace 30
./scripts/capture-runtime.sh artifacts/runs/<run-id> gcdump 30
./scripts/capture-runtime.sh artifacts/runs/<run-id> stacks 30
./scripts/capture-runtime.sh artifacts/runs/<run-id> dump 30
```

The script recreates API and worker containers in `diagnose` mode before applying load, which clears process-local leaks and exhausted pools left by the measurement run. It resolves the correct process by runtime UID rather than assuming a container PID.

Normalize binary artifacts before AI analysis:

```bash
./scripts/normalize-runtime.sh artifacts/runs/<run-id>
```

The one-shot diagnostics image contains `dotnet-trace`, `dotnet-gcdump`, `dotnet-dump`, and `dotnet-counters`. It converts `.nettrace` to Speedscope JSON and emits text reports for GC/process dumps. Dump analysis stays in a Linux ARM64 container matching the application architecture when Docker Desktop runs on Apple Silicon.

## Evidence package

Each run is self-contained:

```text
artifacts/runs/<run-id>/
├── manifest.json                     # scenario, workload, loadGenerator, git revision
├── facts.json                        # observations with units and raw-source paths
├── benchmark/
│   ├── warmup.txt                    # wrk runs
│   ├── wrk.txt
│   ├── diagnostic-wrk.txt
│   ├── k6-warmup.txt                 # k6 runs
│   ├── k6-warmup.json
│   ├── k6.txt
│   ├── k6-summary.json
│   ├── diagnostic-k6.txt
│   └── diagnostic-k6-summary.json
├── telemetry/
│   ├── metrics/
│   │   ├── application_metrics.json
│   │   ├── database_pool_metrics.json
│   │   ├── http_client_metrics.json
│   │   ├── pool_metrics.json
│   │   ├── process_cpu.json
│   │   ├── working_set.json
│   │   ├── gc_heap.json
│   │   ├── thread_pool_queue.json
│   │   ├── request_duration.json
│   │   └── scenario_executions.json
│   ├── traces/
│   │   ├── search.json
│   │   └── details/<trace-id>.json   # 10 slowest traces
│   └── logs/
│       └── query-range.json
├── dependencies/
│   ├── postgres-statements.csv       # includes normalised query text
│   ├── postgres-activity.csv
│   ├── postgres-connections.csv
│   ├── postgres-order-plan.json
│   ├── redis-info.txt
│   ├── redis-slowlog.txt
│   ├── redis-latency.txt
│   ├── rabbitmq-queues.json
│   ├── rabbitmq-connections.json
│   ├── rabbitmq-channels.json
│   ├── api-net-tcp.txt
│   └── docker-compose-ps.json
├── runtime/
│   ├── capture.json                  # requested vs effective diagnostic, loadGenerator
│   ├── processes.json
│   ├── processes-diagnostic.json
│   └── api|worker/
│       ├── cpu.nettrace              # trace captures
│       ├── cpu.speedscope.json       # after normalize-runtime.sh
│       ├── before.gcdump             # gcdump captures
│       ├── after.gcdump
│       ├── stacks.json               # stacks captures
│       └── process.dmp               # dump captures
├── source/
│   ├── tool-versions.txt
│   ├── git-status.txt
│   └── git-diff-stat.txt
└── analysis/
    ├── claude-raw.json               # after analyze-with-claude.sh
    ├── diagnosis.json
    └── runtime/                      # after normalize-runtime.sh
        └── *-gcdump-report.txt, *-dump-report.txt
```

`facts.json` contains observations, units, timestamps, and raw-source paths—not conclusions. Binary dumps remain local; Claude normally sees normalized summaries instead of consuming a huge opaque dump.

## Script reference

### What the orchestrator does and does not do

`run-scenarios.sh` runs the measurement and always produces an evidence package.
Runtime capture and normalization are opt-in, and each stage is gated on the
previous one succeeding:

```text
run-scenario.sh                always      measure, then capture-evidence.sh
  └─ succeeded AND --with-runtime?
       capture-runtime.sh                  separate diagnose-mode load
         └─ succeeded?
              normalize-runtime.sh         binaries to readable text
```

Without `--with-runtime` there is no runtime capture and no normalization at all.
Any failing stage short-circuits the rest and marks that scenario `failed`. The
orchestrator never runs the AI phase: `analyze-with-claude.sh` and
`claude-fix.sh` sit outside it, behind the human review gate.

### Pipeline

```text
run-single / run-multiple / run-all      wrappers you type
             |  exec
      run-scenarios.sh                   suite orchestrator
             |  per scenario, sequentially
      run-scenario.sh                    one measurement
             |  automatically
      capture-evidence.sh                telemetry and dependencies, facts.json
             |  only with --with-runtime
      capture-runtime.sh                 dotnet-monitor capture
             |
      normalize-runtime.sh               Speedscope and text reports
             |  choose one
   print-ai-prompt.sh   OR   analyze-with-claude.sh
             |                          |
                   human review gate
                           |
                    claude-fix.sh       the only script that edits source
```

### Choosing a script

| Goal | Command |
|---|---|
| Measure one scenario | `./scripts/run-single.sh S07 30` |
| Measure several under one run ID | `./scripts/run-multiple.sh S07,S12,S17 30` |
| Full sweep of all 27 | `./scripts/run-all.sh 30 --with-runtime --continue-on-error` |
| Add CPU trace or GC dump evidence | append `--with-runtime` |
| Produce a flat, non-suite package | `./scripts/run-scenario.sh S07 30` |
| Capture runtime evidence after the fact | `./scripts/capture-runtime.sh <dir>` then `./scripts/normalize-runtime.sh <dir>` |
| Diagnose interactively | `./scripts/print-ai-prompt.sh <dir>` then `claude` |
| Produce a machine-readable diagnosis | `./scripts/analyze-with-claude.sh <dir>` |
| Apply a reviewed fix | `./scripts/claude-fix.sh <dir>` |
| Let Claude query live Grafana and Tempo | `./scripts/configure-claude-mcp.sh` once, first |

### Measurement

`run-single.sh`, `run-multiple.sh`, and `run-all.sh` are thin wrappers that
`exec` into `run-scenarios.sh`. The only logic they add is input guarding:
`run-multiple.sh` requires at least two comma-separated IDs and rejects `all`.
Prefer these.

`run-scenarios.sh <list|all> [duration] [--with-runtime] [--continue-on-error]`
is the orchestrator. It validates the load generator, duration, unknown IDs,
duplicates, and empty list entries before starting, so a full sweep cannot fail
on a typo at scenario 14. It creates `artifacts/runs/suite-<UTC>` with collision
suffixing, runs scenarios strictly sequentially so dependency resets and
process-local state cannot cross-contaminate, gives each child a unique
`telemetryRunId` for unambiguous correlation, tracks per-scenario status, and
aggregates child facts into a suite `facts.json`. It stops on the first failure
by default while preserving partial evidence; `--continue-on-error` attempts
every scenario, finishes `completed-with-errors`, and still exits nonzero. On
`SIGINT` or `SIGTERM` it marks the active scenario `interrupted` and finalizes
the suite rather than leaving a half-written manifest.

`run-scenario.sh <scenario> [duration]` performs one measurement and is normally
invoked by the orchestrator through `PERFLAB_ARTIFACT_DIR` and related
variables. Run it directly only when a flat, non-suite package is required. Its
order is: write `manifest.json`, recreate `api` and `worker` with the scenario
environment, wait for `/health/ready`, reset dependencies deterministically
(Redis `FLUSHALL`, `pg_stat_statements_reset()`, purge both queues), warm up for
10 seconds, measure at the catalog's connection count, wait 6 seconds for the
final OTLP batch, then call `capture-evidence.sh`.

The names differ by one letter: the plural script is the suite orchestrator, the
singular one produces a single flat package.

### Evidence

`capture-evidence.sh <artifact-directory>` collects the telemetry, dependency,
and tool-version snapshots and writes `facts.json`. It runs automatically at the
end of every scenario.

**Do not re-run it against an older package.** Only its choice of which
benchmark file to parse comes from `manifest.json`; everything else is captured
live. It queries Prometheus, Tempo, and Loki from the package's `startedEpoch`
to *now*, snapshots whichever dependencies are currently running, records the
current git checkout, overwrites the existing telemetry/dependency/source files
in place, and rewrites `completedAt`. Re-running it hours later silently pairs an
old benchmark with unrelated live evidence. Re-measure instead.

Metrics are captured two different ways, and the JSON shape differs. Gauges and
rates — `process_cpu`, `working_set`, `gc_heap`, `thread_pool_queue`, and
`request_duration` — use `query_range` across the run window at a 5-second step,
so each series carries a `values` array. Sampling those once after the load
stopped would report an idle process and hide the peak the metric exists to
show. The cumulative `perflab_*` counters use an instant query, where a single
read at the end is already the run total, and carry a single `value`.

It gathers Prometheus queries
(deriving a `service_instance_id` filter from the application metrics so database
and HTTP pool metrics are correlated rather than global), a Tempo search with
retries followed by the ten slowest traces, a Loki range query, PostgreSQL
statement/activity/connection snapshots and a query plan, Redis `INFO`,
`SLOWLOG`, and `LATENCY`, RabbitMQ queues, connections, and channels, the API
container's `/proc/net/tcp`, `docker compose ps`, tool versions, and git state.

`facts.json` records observations with units and source paths, never conclusions.
Most HTTP captures tolerate failure, but the PostgreSQL and Redis captures do
not, so the script fails loudly when a dependency is unreachable.

### Runtime capture and normalization

`capture-runtime.sh <dir> [trace|gcdump|stacks|dump] [duration]` is a separate
load run, because tracing perturbs the process. It defaults to the diagnostic
recommended by the scenario catalog, recreates `api` and `worker` with
`--force-recreate` in `diagnose` mode — which deliberately clears the leaks and
exhausted pools the measurement produced — and resolves the target process by
dotnet-monitor runtime UID rather than container PID.

| Kind | Behavior |
|---|---|
| `trace` | background load plus `/trace?profile=cpu` for the duration |
| `gcdump` | gcdump before, then load, then gcdump after; each forces a full collection |
| `stacks` | load, wait 5 seconds, `/stacks` |
| `dump` | load, wait 5 seconds, `/dump?type=Heap` |

A `stacks` request falls back to `trace` unless
`PERFLAB_ENABLE_DOTNET_MONITOR_STACKS=true`, and the reason is recorded in
`runtime/capture.json`. Check `effectiveDiagnostic` before reasoning about stack
evidence.

`normalize-runtime.sh <dir>` must run before AI analysis. In the `tools`-profile
container it converts every `.nettrace` to Speedscope JSON, every `.gcdump` to a
text report, and every `.dmp` to `clrthreads`, `clrstack -all`, and
`dumpheap -stat` output. Without it, Claude is handed opaque binaries.

### AI phase

`print-ai-prompt.sh <dir>` is read-only and prints the interactive prompt plus
the evidence path. It accepts a suite root, a suite child, or a flat package.

`analyze-with-claude.sh <dir>` produces the schema-enforced diagnosis. It runs
`claude -p` with `--allowedTools "Read,Grep,Glob"`, so it can neither edit files
nor run commands, and writes `analysis/claude-raw.json` plus the normalized
`analysis/diagnosis.json`. Target a flat package or a suite child, never a suite
root. It is slow because it is a nested agent session rather than a script.

`claude-fix.sh <dir>` is the only script that changes source. It refuses to start
unless `analysis/diagnosis.json` exists, which is the human review gate.

`configure-claude-mcp.sh` is a one-off that exports the LGTM container's
generated MCP configuration to the ignored file `ai/generated-mcp.json`, which
`analyze-with-claude.sh` then passes through `--mcp-config`.

### Not invoked directly

`scripts/lib/common.sh` is sourced for `require_command`, `require_scenario`,
`scenario_value`, and `wait_for_api`. `scripts/wrk/scenario.lua` and
`scripts/k6/scenario.js` are workload definitions; both read `PERF_METHOD`,
`PERF_PATH`, `PERF_BODY`, and `PERF_RUN_ID`, and the k6 script additionally
honours `PERF_BASE_URL`.

### Operational cautions

1. Hold `PERFLAB_LOAD_GENERATOR` constant across any before/after pair.
2. k6's `--vus`/`--duration` form allows in-flight iterations to drain past the
   declared duration, bounded by the slowest iteration rather than by k6's
   30-second `gracefulStop` ceiling. Measured overshoot on a 30-second run is 8 ms
   for `S00`, 45 ms for `S12`, and 124 ms for `S07` — under half a percent. It is
   deliberately not set to `0s`: that force-interrupts in-flight iterations and
   can bias request and error accounting.
3. The managed runners pin `PERF_BASE_URL` to `http://127.0.0.1:8080` and record
   it as `workload.baseUrl`. Only a standalone `k6 run` honours an ambient value.
4. The 10-second warm-up understates fast endpoints by roughly 2.5x.
5. `--with-runtime` approximately doubles wall-clock time per scenario.
6. `capture-runtime.sh` destroys the measured process state by design, so capture measurements first.
7. `gcdump` forces a full collection and must not be read as steady-state heap.
8. A `stacks` request usually yields a trace; confirm in `runtime/capture.json`.
9. `capture-evidence.sh` fails hard when PostgreSQL or Redis is unreachable.

## How Claude Code is used

Yes, the PoC prompts Claude Code directly through its CLI, but it does not rely on a person pasting dashboard screenshots or raw dumps into a chat.

For the normal interactive, human-in-the-loop workflow, print the reusable prompt and then start the already authenticated Claude CLI without `-p`:

```bash
PERF_LAB_EVIDENCE_DIR="$(ls -td artifacts/runs/suite-* | head -1)"

./scripts/print-ai-prompt.sh "${PERF_LAB_EVIDENCE_DIR}"
claude
```

### Manual check

The same thing as one copy-pasteable block, starting from a fresh shell. It
selects the most recent suite run, prints the prompt, and opens an interactive
Claude session. Change the `cd` target to wherever this repository is cloned:

```bash
cd /<path to dir>/dotnet-perf-eng

PERF_LAB_EVIDENCE_DIR="$(ls -td artifacts/runs/suite-* | head -1)"

./scripts/print-ai-prompt.sh "${PERF_LAB_EVIDENCE_DIR}"

claude
```

`ls -td artifacts/runs/suite-*` orders by modification time, so
`PERF_LAB_EVIDENCE_DIR` resolves to the newest suite. To diagnose one scenario
in isolation rather than the whole suite, point it at a child instead:

```bash
PERF_LAB_EVIDENCE_DIR="artifacts/runs/<suite-run-id>/scenarios/S07"
```

`print-ai-prompt.sh` requires `manifest.json` and `facts.json` in the target
directory and exits nonzero otherwise, so a failed or partial run is reported
rather than silently analyzed.

Copy the printed prompt into Claude. It works for a single package, a suite root, or one suite child. The source template is `ai/interactive-diagnosis-prompt.md`; it requires evidence-first reasoning, exact source locations, competing hypotheses, a minimal fix, and an unchanged-workload validation plan. For suite runs it also asks Claude to use `S00` as a general process baseline and produce a cross-scenario comparison.

The optional structured diagnosis phase is non-interactive and read-only. Run it against a flat single-scenario package or a suite child, not a suite root:

```bash
./scripts/analyze-with-claude.sh artifacts/runs/<run-id>
```

The script effectively runs:

```bash
claude -p \
  --permission-mode dontAsk \
  --allowedTools "Read,Grep,Glob" \
  --no-session-persistence \
  --output-format json \
  --json-schema '<diagnosis schema>' \
  '<evidence-first prompt and evidence path>'
```

Claude can read the evidence package and relevant source, but it cannot edit or invoke shell commands in this phase. The schema requires measured symptoms, ranked hypotheses, causal chain, exact source lines, a minimal fix, risks, validation gates, and limitations. The raw CLI envelope is retained as `analysis/claude-raw.json`; the normalized report is `analysis/diagnosis.json`.

Set an optional model or spend ceiling before running:

```bash
export CLAUDE_MODEL=sonnet
export CLAUDE_MAX_BUDGET_USD=5
```

After a human reviews the diagnosis, start the separate edit phase:

```bash
./scripts/claude-fix.sh artifacts/runs/<run-id>
```

This opens an interactive Claude Code session with edit acceptance enabled. Claude reads the approved diagnosis, changes the smallest relevant source surface, builds the solution, and explains risks. It is intentionally not a fully unattended auto-fix pipeline.

### Optional live Grafana MCP access

The primary AI input is the immutable evidence package. MCP is optional for follow-up questions and live telemetry exploration.

OTEL-LGTM generates an MCP configuration for Grafana/Tempo. Export it after the stack is running:

```bash
./scripts/configure-claude-mcp.sh
```

This saves the container-generated configuration as the ignored local file `ai/generated-mcp.json`. The diagnosis script detects it and passes `--mcp-config` to Claude. Tempo MCP is enabled in `compose.yaml`; Grafana MCP can query metrics, logs, dashboards, and data sources. Do not replace the captured evidence with unconstrained live queries—live state can change during analysis and is harder to audit.

## Controlled scenario coverage

The implementation includes one healthy control and 26 deliberately problematic behaviors. The table states the lab's expected mechanism for maintainers and presenters; an AI diagnosis must still prove it from captured measurements and source rather than treating this table as evidence.

| ID | Area | Workload | Deliberately injected mechanism | Expected evidence | Runtime capture |
|---|---|---|---|---|---|
| S00 | Control | Catalog recommendations, 64 connections | Bounded query and linear in-memory ordering | Healthy latency/throughput baseline; bounded DB spans and allocations | CPU trace |
| S01 | CPU | Catalog recommendations, 64 | Candidate limit of 2,500 ranked with nested comparisons and repeated span equality; the limit binds only at `demo` scale, and `smoke` caps the set at the category's ~1,000 active products | API CPU saturation, hot ranking loop, higher latency, lower throughput | CPU trace |
| S02 | Threading | Runtime threading, 128 | Synchronous wait on `Task.Delay` inside request processing | Blocked worker threads, ThreadPool growth/queueing, long tail latency | Managed stacks → trace fallback |
| S03 | Synchronization | Runtime threading, 96 | Process-wide semaphore held across a DB call and delay | Serialized requests and low CPU, with uniformly high latency rather than a long tail: strict serialization makes p99 and p50 nearly equal | Managed stacks → trace fallback |
| S04 | Memory retention | Runtime memory, 32 | Static event subscribers retain capped 64 KiB arrays | Live heap grows toward the safety cap and survives collections | GC dump before/after |
| S05 | Allocation/GC | Runtime memory, 32 | Repeated 128 KiB buffers, Base64 strings, JSON copies, and deserialization | LOH allocation churn, GC pressure, CPU in encoding/serialization | CPU trace |
| S06 | Scheduling | Runtime threading, 64 | 128 `Task.Run` operations and buffers per request | Excess work items, scheduling overhead, allocation and CPU pressure | CPU trace |
| S07 | PostgreSQL queries | Customer orders, 48 | One order query followed by one item query per order | N+1 spans/statements, amplified DB calls and request latency | Managed stacks → trace fallback |
| S08 | PostgreSQL pagination | Deep order-history page, 48 | Large `OFFSET` pagination at page 100 | Rows scanned then discarded to return one page, and a higher mean DB time; the access path itself stays reasonable, so at `smoke` scale this is the mildest defect in the catalog and grows with table size | Managed stacks → trace fallback |
| S09 | PostgreSQL lifecycle | Customer orders, 64 | Open Npgsql connections retained in a static collection | Default pool drains, acquisition waits/timeouts, retained DB sockets | Managed stacks → trace fallback |
| S10 | PostgreSQL locking | Order creation, 64 | Hot row transaction remains open across Redis work, delay, and publication | Lock waits, serialized updates, slow/erroring POST requests | Managed stacks → trace fallback |
| S11 | EF Core materialization | Customer orders, 32 | Entire tracked order/item graph loaded before in-memory paging | Excess rows, allocations, tracking overhead, larger GC dump | GC dump |
| S12 | Cache coordination | Catalog cache, 128 | Cache miss refreshes are not coalesced and include delayed DB work | Cache stampede, duplicated DB queries, latency spike after reset/expiry | Managed stacks → trace fallback |
| S13 | Redis command pattern | Catalog cache, 64 | 100 cache fragments fetched sequentially | Many serialized Redis operations per request and high dependency time | Managed stacks → trace fallback |
| S14 | Redis sockets | Catalog cache, 64 | `ConnectionMultiplexer` created and disposed per request | Redis connection churn, socket growth/TIME_WAIT, connect overhead | CPU trace |
| S15 | Redis key lifecycle | Catalog cache, 64 | Unique GUID key per request with no expiry | Keyspace and Redis memory growth with almost no hits | GC dump |
| S16 | RabbitMQ sockets | Order creation, 64 | RabbitMQ connection and channel created for every publish | Broker connection/channel churn, TCP overhead, lower throughput | CPU trace |
| S17 | Consumer backpressure | Order creation, worker target, 48 | One consumer dispatch slot, prefetch 500, and blocking 100 ms processing | Queue backlog to the length cap, unacked messages equal to the prefetch, and a publish-to-process ratio in the hundreds; once the cap is reached the overflow policy dead-letters messages, so the headline symptom is message loss rather than slow drain | Managed stacks → trace fallback |
| S18 | Retry behavior | Poison order creation, worker target, 8 | Immediate requeue up to a capped 50 attempts | Repeated deliveries visible as many process spans per trace, a large `perflab.orders.retried` count, and dead-letter activity. The retry storm also emits log records faster than the OTLP batch processor can export them, so individual lines are dropped and the counter is the reliable evidence rather than Loki | Managed stacks → trace fallback |
| S19 | RabbitMQ channel ownership | Order creation, 128 | Concurrent publishers use one shared channel without serialization | Unsafe by the client's documented contract, but measured as high throughput with no publish failures on RabbitMQ.Client 7.2.2; see the note below | CPU trace |
| S20 | Message memory ownership | Order creation, worker target, 48 | Broker-owned delivery memory retained without copying | Retained/invalid payload ownership and worker heap growth | GC dump |
| S21 | PostgreSQL pool—low | Pool endpoint, 48 | Npgsql pool capped at 2 while each request holds its lease for deterministic work | High acquisition wait, pool timeouts/non-2xx responses, only two active pool connections | CPU trace + pool metrics |
| S22 | PostgreSQL pool—high | Pool endpoint, 96 | Npgsql pool permits 64 concurrent leases for the same workload | Large PostgreSQL backend/socket footprint; oversizing masks long lease duration and shifts pressure downstream | CPU trace + pool metrics |
| S23 | Redis pseudo-pool—low | Pool endpoint, 64 | One exclusively leased `ConnectionMultiplexer` despite its thread-safe multiplexed design | Client-side lease queue, low throughput, high custom pool-wait metric | CPU trace + pool metrics |
| S24 | Redis pseudo-pool—high | Pool endpoint, 128 | 32 application-managed multiplexers and exclusive slots | Redis `connected_clients`/socket inflation and unnecessary client memory/threads | CPU trace + pool metrics |
| S25 | HTTP pool—low | Internal upstream call, 64 | Singleton handler limited to two connections against a 100 ms dependency | `http.client.request.time_in_queue`, long tails, about two active upstream connections | CPU trace + HTTP metrics |
| S26 | HTTP pool—high | Internal upstream call, 128 | Singleton handler permits 128 pooled connections to the same dependency | High open/idle TCP connection count and resource footprint | CPU trace + HTTP metrics |

### What “channel ownership” means for S19

S19 publishes from many concurrent requests through one shared `IChannel`,
skipping the serialization the default path applies. That is contrary to the
.NET client's guidance, which handles concurrency through channel multiplexing —
a channel per concurrent publisher over one connection — rather than by sharing
a channel.

The hazard is real by contract, but it did not reproduce here. A 12-second run at
128 connections issued 106,788 publishes with zero non-2xx responses, zero
transport errors, and the highest throughput of any scenario measured in this
lab. Do not expect protocol errors from this scenario on RabbitMQ.Client 7.2.2;
treat it as a demonstration that an unsafe ownership pattern can look healthy
under measurement, which is why the contract matters more than the observation.
Diagnose it from the source ownership pattern, not from an error count.

### What “Redis pool” means here

StackExchange.Redis does not expose a conventional fixed-size connection pool: `ConnectionMultiplexer` is thread-safe, multiplexes concurrent commands, and is designed to be shared and reused. S23/S24 deliberately wrap multiplexers in an application-owned exclusive pool to demonstrate the two common mistakes—serializing work through too few slots and creating many multiplexers to compensate. The production correction is normally one appropriately configured, long-lived multiplexer, not a larger custom pool. See the [StackExchange.Redis basic usage guidance](https://stackexchange.github.io/StackExchange.Redis/Basics.html).

Npgsql connections are pooled by default; its minimum/maximum settings define retention and capacity, and closing a logical connection returns the physical connection to the pool. See the [Npgsql connection-string parameters](https://www.npgsql.org/doc/connection-string-parameters) and [basic usage guidance](https://www.npgsql.org/doc/basic-usage.html). `HttpClient` pools belong to `SocketsHttpHandler`; connection limits that are too low queue callers, while unbounded/high fan-out or poor handler lifetime can create excessive sockets. See the [.NET HttpClient guidelines](https://learn.microsoft.com/dotnet/fundamentals/networking/http/httpclient-guidelines).

### Existing socket and pool-adjacent scenarios

Yes, socket issues were already represented before S21–S26:

- S09 retains Npgsql connections, which consumes both pool leases and PostgreSQL TCP sockets until the pool exhausts.
- S14 creates a Redis multiplexer per request, producing Redis client/socket churn.
- S16 creates a RabbitMQ connection per publish, producing broker connection/channel and TCP churn.
- S19 is primarily unsafe shared-channel concurrency rather than socket exhaustion.
- S02/S06 cover ThreadPool starvation/fan-out; the .NET ThreadPool is not a network connection pool.

S21–S26 add explicit low/high capacity experiments for Npgsql, an intentionally application-managed Redis pseudo-pool, and `SocketsHttpHandler`. Other useful future extensions would be RabbitMQ channel-pool sizing, outbound gRPC HTTP/2 stream limits, and multi-tenant per-destination pool fragmentation.

The low/high pairs are deliberately two unsafe extremes, not a before/after fix pair. Compare S21 with S22, S23 with S24, and S25 with S26 to expose the queueing-versus-resource trade-off; use the validation plan to test a separately chosen right-sized configuration. S00 remains useful for process-level health but is not an endpoint-matched baseline for the pool workloads.

Only one scenario is selected per process startup. A comma-separated or `all` suite still runs scenarios sequentially in fresh API/worker containers; it does not activate several injected behaviors simultaneously.

## Validation protocol

For a defensible before/after comparison:

1. Keep the same source revision except for the proposed fix.
2. Use the same seed scale, scenario, endpoint, request body, thread count, connection count, duration, and Docker Desktop resources.
3. Use the same load generator. wrk and k6 numbers are not comparable to each other, so a before/after pair must hold `PERFLAB_LOAD_GENERATOR` constant.
4. Reset Redis, RabbitMQ queues, and `pg_stat_statements` before each measurement.
5. Warm up, then run at least five 60-second measurement repetitions for a presentation-quality result.
6. Keep diagnostic captures separate from reported throughput/latency.
7. Check response correctness and error count before comparing speed.
8. Require a mechanism-specific gate: hotspot disappears, thread-pool queue remains bounded, live heap plateaus, DB spans collapse, plan uses the intended access path, pool timeouts disappear, cache refreshes coalesce, or RabbitMQ backlog drains.

Docker Desktop measurements are comparative numbers for this machine, not production capacity claims.

## Safety limits

- API: 1 CPU, 768 MiB
- Worker: 0.75 CPU, 512 MiB
- Normal PostgreSQL pool: 20 connections, 5-second connect/command timeout
- Pool experiments: 2 connections for S21 and 64 for S22, below PostgreSQL's local server limit
- Redis pseudo-pool experiments: 1 multiplexer for S23 and a capped 32 for S24
- HTTP pool experiments: 2 connections for S25 and a capped 128 loopback connections for S26
- Redis: 256 MiB with `allkeys-lru`
- RabbitMQ work queue: maximum 10,000 messages
- Poison-message requeue: local cap of 50 before dead-lettering
- Retained-memory scenario: approximately 125 MiB cap
- All datasets are synthetic and all service ports are loopback-only

Stop the stack while preserving volumes:

```bash
docker compose down
```

`docker compose down -v` also deletes all PoC database/cache/broker/telemetry volumes; use it only when you intentionally want a full data reset.
