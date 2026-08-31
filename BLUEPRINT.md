# Reusable performance-evidence harness — blueprint

A local, language-neutral performance lab built as a **thin ports-and-adapters
toolkit**. One stable core drives measurement, evidence capture, normalization,
and a read-only AI diagnosis; everything project- or language-specific plugs in
through a small bash descriptor and a handful of adapter scripts. The goal is to
onboard a new project or runtime by **adding files, not editing the core** — so
the ~70% that is reusable is genuinely reused instead of copy-pasted.

## Why this shape

The reference implementation is a .NET lab with deliberate performance defects.
Making it reusable naively (fork per language) forks that 70% and you maintain N
drifting copies. Instead:

- **Push variation up into OpenTelemetry + config, out of the scripts.** Every
  signal carries `service.name` + a run-id resource attribute, so capture scopes
  to one run by correlation key regardless of language. Dependency-client metrics
  use OTel semantic conventions (`db_client_*`, `http_client_*`), which are
  language-neutral. The only real language coupling left is *runtime metric
  names* and *runtime diagnostic tooling* — both isolated in a runtime adapter.
- **Keep the core dumb and declarative.** It reads a descriptor and calls
  adapters by convention. It hardcodes no service name, port, path, or metric.

## Architecture

```
repo root
├── harness/               # the reusable toolkit (never edited per project)
│   ├── core/              # orchestration -- never edited per project:
│   │   ├── run/               # run-single/multiple/all wrappers + run-scenario(s) orchestrators
│   │   ├── pe-tests/          # perf-engineering runners: sweep/repeat/mix/data-scale/fault
│   │   ├── capture/           # capture-evidence + capture/normalize-runtime
│   │   ├── analyze/           # analyze-trends (leak/trend) + compare-runs (A/B regression)
│   │   └── lib/               # common.sh (shared helpers) + lab-context.sh (lab-specific init)
│   ├── adapters/
│   │   ├── runtime/<rt>/     # metrics.sh, capture.sh, normalize.sh, versions.sh, evidence-extra.sh
│   │   ├── dependency/<dep>/ # reset/sample-midload/snapshot.sh (generic; connection config from the descriptor)
│   │   └── loadgen/<gen>/    # run.sh (shared measurement+evidence contract) + default.{lua,js} (fallback workload)
│   └── ai/                # diagnosis.schema.json, *-prompt.md, scripts/
├── labs/<project>/        # the experiment: lab.config.sh + scenarios.tsv + compose + infra
│                          #   + loadgen/<gen>.{js,lua} (own workload) + dependencies/<dep>/<phase>.sh (own probes)
└── source/<runtime>/<project>/   # the application under test (pristine)
```

Selecting `PERFLAB_RUNTIME=dotnet` loads `harness/adapters/runtime/dotnet/`.
Selecting `PERFLAB_DEPENDENCIES="postgres redis"` runs those dependency adapters.
Selecting `PERFLAB_LOAD_GENERATOR=k6` runs `harness/adapters/loadgen/k6/run.sh`,
which executes the lab's own `loadgen/k6.js` if present, else the shared
`default.js`.

## The descriptor (`labs/<project>/lab.config.sh`)

A sourced bash file — no jq needed to read it. Key fields:

| Field | Meaning |
|---|---|
| `PERFLAB_RUNTIME` | selects the runtime adapter |
| `PERFLAB_COMPOSE_FILE` / `PERFLAB_APP_SERVICES` | compose file + services to build/recreate |
| `PERFLAB_BASE_URL` / `PERFLAB_READY_URL` | host URL + readiness probe |
| `PERFLAB_PROM_JOB_REGEX` / `PERFLAB_SERVICE_NAME_REGEX` / `PERFLAB_RUN_ID_ATTR` | telemetry correlation |
| `PERFLAB_PROMETHEUS_URL` / `_TEMPO_URL` / `_LOKI_URL` / `_DIAGNOSTICS_URL` | endpoints |
| `PERFLAB_DEPENDENCIES` | dependency adapters to run |
| `PERFLAB_DIAG_TARGETS` | `service:process-identity` map for runtime diagnostics |
| `PERFLAB_LOAD_GENERATOR_DEFAULT` / `_INTERNAL_BASE_URL` / `_COMPOSE_NETWORK` / `_WRK_IMAGE` | load-gen selection & Docker-wrk wiring |
| `PERFLAB_SCENARIOS` / `PERFLAB_ARTIFACTS_ROOT` | catalog + evidence location |

## The contracts (the seams that make adapters swappable)

| Contract | Owner | Shape |
|---|---|---|
| **Correlation** | core + app | every signal carries `service.name` + run-id resource attr |
| **Workload** | core → loadgen | `PERF_METHOD/PATH/BODY/BASE_URL/RUN_ID` (+ optional `PERF_HEADERS`) env |
| **Per-lab workload** | lab → loadgen | `<lab>/loadgen/<gen>.{js,lua}` overrides the shared `default`; same counters + `observations.json` contract |
| **Dependency connection** | descriptor → dependency adapter | `PERFLAB_PG_*`, `PERFLAB_REDIS_*`, `PERFLAB_RABBIT_*` parameterize the generic captures |
| **Dependency probe (project)** | lab → dependency adapter | `<lab>/dependencies/<dep>/<phase>.sh`, discovered by convention, run after the generic capture |
| **Metric-role** | runtime adapter | `metrics.sh` exports `PERFLAB_METRIC_ROLES=("file|range\|instant|promql")` with `$JOB/$RUN_ID/$SERVICE_INSTANCE` placeholders |
| **Diagnostic-kind** | runtime adapter | `capture.sh <dir> <kind> <dur> <target>` produces raw; `normalize.sh <dir>` → Speedscope/text |
| **Dependency-lifecycle** | dependency adapter | `reset.sh` / `sample-midload.sh` / `snapshot.sh` (each takes `<dir>`) |
| **Load** | loadgen adapter | `run.sh <dir> <phase>` (`warmup\|measure\|diagnostic`); `measure` writes `benchmark/observations.json` |
| **Evidence package** | core | fixed directory layout + `manifest.json` / `facts.json` |

`facts.json` is an **index** (observations with units + raw source paths), never
conclusions. The load generator owns its observation units (wrk latency is a
`wrk-duration` string; k6 is numeric `ms`) — the two are recorded but never
cross-compared.

## Zero host jq (Docker-hosted jq)

The harness handles JSON without installing jq on the host:

- **Config** is bash (`lab.config.sh`); the **scenario catalog** is TSV parsed
  with `awk` (`scenarios.tsv`).
- **JSON the harness emits** (manifest, facts, suite manifest, observations) is
  built with `printf` + a `json_escape` helper.
- **JSON the harness must parse** (Prometheus/Tempo/Loki responses, Claude
  output, k6's nested summary) is parsed by **`jqd`** — `jq` run via
  `docker run --rm -i <jq-image>` (the lab already requires Docker). Simple
  presence checks use `grep`. This also removes the Windows jq CRLF/MSYS pain,
  since jq now runs on Linux.

## Evidence package layout

```
artifacts/runs/<run-id>/
├── manifest.json                # run identity, workload, git revision, status
├── facts.json                   # observations (units + raw-source paths)
├── benchmark/                   # native load output + observations.json
├── telemetry/{metrics,traces,logs}/    # Prometheus range/instant, Tempo, Loki
├── dependencies/                # per-dependency snapshots + app socket table
├── runtime/{capture.json,<target>/...} # raw diagnostics (with --with-runtime)
├── source/                      # tool versions, git status/diff
└── analysis/                    # diagnosis.json + normalized runtime reports
```

## Extending the harness

- **Another project, same runtime:** add `labs/<project>/` with its own
  `lab.config.sh` + `scenarios.tsv` (+ compose/infra), pointing at an app under
  `source/<rt>/<project>/`. No script edits, no harness change. (A different framework — Spring vs Quarkus, Express vs Fastify — is *not*
  a new adapter; OTel auto-instrumentation + the descriptor cover it.)
- **A new dependency (e.g. kafka, mongo):** add
  `harness/adapters/dependency/<dep>/{reset,sample-midload,snapshot}.sh` (generic;
  read connection config from the descriptor, never hardcode names/creds) and list
  it in `PERFLAB_DEPENDENCIES`. Project-specific probes (a named-query `EXPLAIN`, a
  named-table check) go in `labs/<project>/dependencies/<dep>/<phase>.sh`, run
  additively after the generic capture and discovered by convention.
- **A new load generator (e.g. gatling, vegeta):** add
  `harness/adapters/loadgen/<gen>/run.sh` (the shared measurement + observations
  contract) plus a shared `default.<ext>`. A project's own workload — auth,
  chaining, datasets — lives at `labs/<project>/loadgen/<gen>.<ext>`.
- **A new runtime:** add `harness/adapters/runtime/<rt>/` implementing the
  metric-role + diagnostic-kind contracts, and a thin instrumentation shim in the
  app that sets the standard resource attributes.

## Per-runtime adapter matrix

The core, `facts.json`, and the AI phase never see these names — only the runtime
adapter does. Exact Prometheus metric names shift by OTel version; confirm each
once by scraping `/metrics`.

| Runtime | Instrumentation | `runtime.saturation` signal | CPU profile → Speedscope | Heap → text | Stacks | Diagnostics transport |
|---|---|---|---|---|---|---|
| **.NET** *(reference)* | OTel .NET SDK | `dotnet_thread_pool_queue_length` | dotnet-trace → convert | gcdump report | dotnet-monitor `/stacks` | dotnet-monitor sidecar |
| **Node/TS** | OTel JS SDK | `nodejs_eventloop_lag/utilization` | `.cpuprofile` (native) | `.heapsnapshot` summarizer | Inspector / clinic | Inspector (CDP) |
| **JVM** | **OTel Java agent (zero code)** | `jvm_thread_count` / executor queue | async-profiler `-o speedscope` | `jmap` hprof → MAT | **`jstack`** | `jcmd`/`jstack` (needs PID ns) |
| **Java AOT** (native-image) | **compile-time** OTel (Quarkus/Micronaut/Spring-native) | leaner SDK metrics | **perf / eBPF** | jemalloc / heaptrack | perf sampled | external perf/eBPF |
| **Go** | OTel SDK + otelhttp/otelsql | `process_runtime_go_goroutines` | `/debug/pprof/profile` → convert | `/debug/pprof/heap` | `/debug/pprof/goroutine?debug=2` | **net/http/pprof (no caps)** |
| **Python** | `opentelemetry-instrument` | GIL% / asyncio lag (custom) | **py-spy `--format speedscope`** | `memray stats` | **`py-spy dump`** | py-spy attach (needs SYS_PTRACE) |

### The AOT / native principle

Managed runtimes (.NET, JVM, Node, CPython) get rich in-process diagnostics.
**AOT/native binaries (Java-AOT, Go, Rust, .NET NativeAOT) lose that** and lean
on OS-level perf/eBPF profilers. Model each AOT target as its own runtime adapter
— its diagnostics story diverges sharply from its managed sibling. Rust has no GC
at all, so the entire GC metric family has no analog (measure allocator + RSS
instead).

## What never changes (the invariant core)

Suite orchestration, the evidence-package format, `facts.json` as an index, the
Prometheus range-vs-instant discipline, mid-load sampling, fail-loud capture, the
measure/diagnose separation, and the entire read-only, schema-constrained AI
diagnosis (`harness/ai/`). That is the reused 70%.
