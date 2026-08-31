# Reusable performance-engineering lab

A local, language-neutral performance-evidence harness built as a thin
ports-and-adapters toolkit. A stable core drives measurement, evidence capture,
normalization, and a read-only AI diagnosis; everything project- or
language-specific plugs in through a bash descriptor and small adapter scripts.

The reference project is a .NET service with deliberately planted performance
defects (scenarios `S00`–`S27`). Onboarding another project or runtime means
**adding files, not editing the core**.

> Architecture, contracts, and the per-runtime adapter matrix live in
> [`BLUEPRINT.md`](BLUEPRINT.md).

## Repository layout

```
harness/                          # reusable toolkit (never edited per project)
├── core/
│   ├── run/                     # run-single/multiple/all wrappers + run-scenario(s) orchestrators
│   ├── pe-tests/                # perf-engineering runners: run-sweep/mix/repeat/data-scale/fault
│   ├── capture/                 # capture-evidence + capture/normalize-runtime (the evidence pipeline)
│   ├── analyze/                 # analyze-trends (leak/trend), compare-runs (A/B regression)
│   └── lib/common.sh            # shared library (descriptor + adapters + JSON/loadgen helpers)
├── adapters/
│   ├── runtime/dotnet/           # metrics.sh, capture.sh, normalize.sh, versions.sh, evidence-extra.sh, diagnostics/Dockerfile
│   ├── dependency/{postgres,redis,rabbitmq}/  # reset/sample-midload/snapshot.sh (generic; config-parameterized)
│   └── loadgen/{wrk,k6}/         # run.sh (shared contract) + default.lua / default.js (fallback workload)
└── ai/                           # diagnosis.schema.json, *-prompt.md, scripts/
labs/scenariolab/                 # the EXPERIMENT (per project): what to test + how to run it
├── lab.config.sh                 # descriptor — the single re-pointing seam (bash)
├── scenarios.tsv                 # this project's API scenarios
├── loadgen/{k6.js,wrk.lua}       # this lab's workload (auth/data live here; else the shared default)
├── dependencies/<dep>/<phase>.sh # project-specific probes (e.g. postgres EXPLAIN), by convention
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

With more than one lab present, **every command needs a lab selected**, e.g.
`PERFLAB_LAB=ecommerce ./harness/core/run/run-multiple.sh E02,E03 20`.

## Prerequisites

- **Docker + Docker Compose** (runs the whole stack; also hosts `jq` — no host jq needed).
- **A load generator:** `k6` on the host (default), or a **wrk Docker image**
  (set `PERFLAB_WRK_IMAGE` in `lab.config.sh`). This machine uses k6.
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
./harness/core/run/run-single.sh S01 30
```

Brings up the stack, warms up, measures `S01` for 30s with k6, and writes an
evidence package under `artifacts/runs/<run-id>/`. Then, optionally:

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

The two are **not numerically comparable** (k6 reports latency as numeric ms;
wrk as unit-suffixed strings), so the generator is recorded in `manifest.json`
and must be held constant across a before/after comparison.

**Per-lab workloads.** `run.sh` (the measurement + `observations.json` contract)
is shared and identical across labs; the *workload script* is per-lab, resolved as
`PERFLAB_{K6,WRK}_SCRIPT` > `labs/<project>/loadgen/<gen>.{js,lua}` > the shared
`default.{js,lua}`. A project that needs a JWT `setup()` login, request chaining,
or per-request datasets ships its own `loadgen/<gen>.js` instead of editing the
shared default. The defaults also accept an optional `PERF_HEADERS` env var (a JSON
object of extra headers, e.g. a pre-minted bearer token).

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
| `capacity` | open | arrival rate ramps to `PERFLAB_TARGET_RPS` | the throughput knee (max sustainable RPS) |
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
`benchmark/k6-profile.json`. `--with-runtime` always captures under a **steady**
load regardless of profile, so a trace reflects a stable state rather than a ramp.

## Performance-engineering tests

Beyond a single load test, these runners answer the standard perf-engineering
questions. Each produces evidence packages under `artifacts/runs/`, and they
compose with the load profiles above (`--profile`). k6 only.

| Runner | Question it answers | Output |
|---|---|---|
| `run-sweep.sh <scen> [s/level] --rates R1,R2,…` | Capacity: the throughput↔latency knee / max sustainable RPS | per-level curve + `sweep.json` (`kneeRps`) |
| `run-repeat.sh <scen> [dur] --repeats N` | Trustworthy numbers: median / stddev / CV across N runs | `stats.json` |
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
PERFLAB_LAB=ecommerce  ./harness/core/run/run-single.sh E14 600 --no-runtime --  # soak: PERFLAB_PROFILE=soak
```

## Runtime diagnostics

Measurement and runtime capture are **separate runs** — diagnostic tools perturb
the process (`gcdump` forces a full collection). The orchestrator does this per
scenario **by default** (skip with `--no-runtime`); you can also run it by hand on
an existing package:

```bash
./harness/core/capture/capture-runtime.sh artifacts/runs/<run-id>            # scenario's recommended kind
./harness/core/capture/capture-runtime.sh artifacts/runs/<run-id> trace 30  # or choose: trace|gcdump|stacks|dump
./harness/core/capture/normalize-runtime.sh artifacts/runs/<run-id>         # binaries -> Speedscope JSON / text
```

`capture-runtime` recreates the app in `diagnose` mode before applying load
(clearing leaks/pools left by the measurement) and resolves the target by runtime
identity, not container PID. For .NET, a `stacks` request records a `trace`
fallback by default (the dotnet-monitor profiler channel is unreliable in this
sidecar topology) and documents it in `runtime/capture.json`.

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
| E02 | product-list-shallow | Product list, pg 1 (64) | Same as E00, captured with stacks | Stacks→trace |
| E03 | product-list-deep | Product list, pg 500 (64) | Deep `OFFSET` — rows scanned then discarded | Stacks→trace |
| E04 | product-list-large-page | Product list, 100/pg (48) | Large page — bigger result + serialization | CPU trace |
| E05 | product-search | Product search (64) | Non-sargable `name ILIKE '%…%'` seq scan, run twice (count+page) | CPU trace |
| E06 | product-get | Product by id (64) | Single product by PK — clean control | CPU trace |
| E07 | product-create | Product create (32) | Insert one product | Stacks→trace |
| E08 | product-update | Product update (32) | Patch one product; body varies per iteration → real `UPDATE` | Stacks→trace |
| E09 | orders-list-shallow | Orders list, pg 1 (64) | Order list sorted by unindexed `created_at` + per-request count | Stacks→trace |
| E10 | orders-list-deep | Orders list, pg 50 (48) | Deep `OFFSET` + unindexed `created_at` sort | Stacks→trace |
| E11 | order-get | Order by id (64) | One order + items (`Include`, PK + indexed join) | CPU trace |
| E12 | order-create | Order create (32) | Transactional write: lookup + order + item inserts | Stacks→trace |
| E13 | users-list | Users list, pg 1 (48) | Paged users (small table); count negligible | CPU trace |
| E14 | users-me | Current user (64) | Current user by PK — clean control | CPU trace |

## Evidence package

`facts.json` is an **index** — observations with units and raw-source paths, not
conclusions. The suite index carries, per scenario, both a pipeline `status`
(did the run complete) and a workload `health`/`errorRate` (`degraded` when the
HTTP error rate exceeds `PERFLAB_MAX_HTTP_ERROR_RATE`, default 5%), so a scenario
that ran green while most requests failed — a saturated pool, say — no longer
reads as clean. HTTP metrics still cannot see async loss: for broker-backed
scenarios cross-check `dependencies/rabbitmq-queues.json`. Binary runtime dumps
stay local; the AI normally reads normalized summaries. See
[`BLUEPRINT.md`](BLUEPRINT.md) for the full layout.

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

## Operational cautions

- Hold `PERFLAB_LOAD_GENERATOR` constant across any before/after comparison.
- Runtime diagnostics are **on by default** and ~double wall-clock per scenario;
  because profiling perturbs latency, use `--no-runtime` for the numbers in an A/B
  latency comparison and read the diagnostic run only for the mechanism.
- Write scenarios (e.g. product/order create) mutate the seeded dataset and it
  **persists in the DB volume across runs** — reset with `docker compose -f
  labs/<lab>/compose.yaml down -v` before a run whose read scenarios need the
  pristine seed, or their table sizes (and timings) will drift.
- `gcdump` forces a full collection; don't read it as steady-state heap.
- A `stacks` request usually yields a `trace` — confirm in `runtime/capture.json`.
- `capture-evidence` fails loud if telemetry or a dependency is unreachable, rather
  than emitting a silently empty package.

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
