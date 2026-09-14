# Real-world performance engineering implementation plan

Status: joint implementation plan and single source of truth  
Branch in both repositories: `feature/real-world-performance-engineering`  
Applies identically to: PerfLab and `dotnet-perf-eng`

## 1. Decision summary

Both repositories will support real project workloads ranging from a single API
request to stateful, multi-service user journeys. Each remains a complete
orchestrator. Neither repository may invoke, import, package, download, or
require the other repository's binary, container image, library, scripts, or
runtime artifacts.

Parity means identical semantics and compatible evidence, not shared runtime
implementation. Each repository owns its own:

- Scenario parser and validator.
- Profile compiler and execution state machine.
- k6, JMeter, and wrk adapters.
- Container images and helper executables.
- Target, telemetry, diagnostic, correctness, and data orchestration.
- Evidence normalization, comparison, gating, and reporting.
- Contract schemas and conformance fixtures.

Both implementations use a versioned contract revision and run the same
byte-identical conformance corpus. A repository must remain fully usable when
the other repository is absent.

The existing eight-column scenario format and single-request execution path
remain supported in both products. They are the preferred low-friction path for
endpoint-level load tests after development, smoke tests, isolated regression
checks, and targeted diagnostics.

This exact document must remain byte-identical in both repositories. A change to
the plan is incomplete until the same commit content exists in both branches.

## 2. Independence and parity contract

Both repositories must satisfy all of the following:

- A clean checkout can build, test, package, and execute without the other
  repository being present.
- No command executes the other product's CLI or helper binary.
- No adapter uses a container image built or released only by the other
  repository.
- No shell script sources files from the other repository.
- No build downloads the other repository's schemas, fixtures, generated code,
  packages, or release assets.
- Each repository checks in and validates its own copy of the agreed schemas and
  conformance fixtures.
- The normative contract bundle is byte-identical in both repositories and is
  locked by `contract-lock.json`, containing `contractRevision`, every schema
  and fixture digest, and the aggregate bundle digest.
- Each repository owns its generator adapters, images, orchestration engine,
  evidence normalization, diagnostics, reports, and release process.
- Parity is verified by matching contract behavior and normalized fixture
  results, never by calling one implementation from the other.
- The current `dotnet-perf-eng` JMeter dependency on the
  `perflab-load-jmeter` image must be removed. `dotnet-perf-eng` will own and pin
  its own JMeter runner image; PerfLab will continue to own and pin its own.
- Existing `PERFLAB_*` environment-variable names in `dotnet-perf-eng` are
  compatibility API names only and do not authorize a product dependency.

Product parity and generator capability are different rules:

- For a given generator, target kind, and contract revision, PerfLab and
  `dotnet-perf-eng` must advertise the same capability and produce the same
  semantic result.
- A generator can have an intrinsic limitation, such as wrk being request-only,
  but that limitation must be identical in both products.
- Neither product may claim a feature for a generator when the other product
  lacks it. Such work remains `experimental` until both independent paths pass.
- `supported`, `experimental`, and `unsupported` are versioned capability states;
  missing capability data means unsupported.

The initial joint contract revision is `rwpe-1`. Full-parity status requires
both implementations to carry the same contract-bundle digest and pass the
same byte-identical conformance corpus at that revision while installed and
executed independently. A separate parity workflow may compare exported
results from two isolated builds, but normal build, test, package, and execution
must never fetch or invoke the other repository.

## 3. Goals

1. Model request, journey, and mixed workloads without duplicating journey steps
   outside the project-owned k6 script or JMeter plan.
2. Give requests and journeys unambiguous scheduling and result semantics.
3. Support the complete performance-engineering portfolio through composable
   workload, load-model, profile, purpose, and evidence policies.
4. Run against an orchestrator-managed target or an already-running local or
   remote environment without requiring deployment.
5. Collect correlated load, application, infrastructure, dependency, APM,
   continuous-profile, and targeted .NET diagnostic evidence.
6. Preserve clean measurement cohorts and isolate invasive diagnostics.
7. Make long-running tests durable, bounded, observable, and safe to interrupt.
8. Preserve comparison integrity through complete workload, environment,
   dataset, generator, diagnostic, and overhead fingerprints.
9. Provide independently implemented, contract-compatible behavior in both
   repositories.

## 4. Non-goals and boundaries

- Neither orchestrator defines the ordered business steps of a journey.
- Neither orchestrator requires an application deployment step.
- Neither orchestrator infers that an arbitrary generator supports every profile.
- Neither orchestrator labels metrics with unbounded iteration, user, order, or trace
  identifiers.
- Neither orchestrator treats HTTP request count as journey count.
- Neither orchestrator merges profiling-on and profiling-off runs into one baseline
  cohort.
- Neither orchestrator silently approximates an unsupported workload or test type.
- Neither repository uses the other at runtime or build time.

## 5. Current state and material gaps

### 5.1 PerfLab gaps

| Area | Current state | Required state |
| --- | --- | --- |
| Lab scenario | `internal/lab/types.go` stores one method, path, and body | Versioned request, journey, and mix selector |
| Catalog | `internal/lab/discover.go` accepts an eight-column TSV | Keep TSV; add Scenario Catalog v1alpha2 JSON |
| Generic domain | `internal/core/model/domain.go` has journey types | Use them in lab execution instead of rejecting them |
| Compiler | `internal/orchestrator/experiment.go` rejects project journeys | Compile validated workload selectors and capabilities |
| k6 | One request or one weighted request per iteration | One request or one complete selected journey per iteration |
| JMeter | HTTP request sample semantics only | Separate journey parent and operation child semantics |
| wrk | Stateless request generator | Retain as request-only and reject journeys before traffic |
| Profile definitions | Lab profile binding and generic profile controller coexist | One canonical PerfLab profile compiler and controller |
| Arrival rate | k6 iteration rate is named RPS | Explicit request/s, journey/s, or iteration/s |
| Soak | Observation probes may create new load executions | One continuous load session with rolling observations |
| Diagnostics | One scenario diagnostic target | Ordered multi-target diagnostic campaign |
| Pyroscope | CPU query path only | Configurable CPU, wall, allocation, lock, exception, live heap |
| Target | Compose-owned local or remote URL | Explicit target kind and lifecycle ownership |
| Evidence | Global request and iteration totals | Journey, operation, request, correctness, and delivery evidence |
| Distributed load | No sharded execution protocol | Agent shards with deterministic aggregation |

### 5.2 `dotnet-perf-eng` gaps covered by the same plan

| Area | Current state | Required state |
| --- | --- | --- |
| Native scenario | `scenarios.tsv` describes one method/path/body | Same request/journey/mix contract and legacy adapter |
| Native execution | `run-scenario.sh` binds one request or weighted request mix | Compile and run the declared iteration contract |
| Native JMeter | Invokes the PerfLab-owned JMeter image; steady only | Repository-owned runner/image with request/journey semantics |
| Native profile logic | k6 shapes in `profiles.sh` plus individual PE runners | One native profile compiler matching the joint contract |
| Native target | `local` means managed Compose; `remote` means URL | Same target kind, lifecycle ownership, and capabilities |
| Native evidence | Request observations and package facts | Same v1alpha2 journey/operation/delivery/correctness semantics |
| Native durability | Per-run shell process and artifacts | Persisted stages, heartbeat, checkpoint, cancel, partial recovery |

The rest of this document defines one required behavior for both repositories.
Repository-specific file ownership appears only in the implementation map.

## 6. Canonical concepts

### 6.1 Orthogonal dimensions

Every execution is compiled from five independent dimensions:

| Dimension | Examples | Question answered |
| --- | --- | --- |
| Workload | request, journey, mix, protocol workload | What executes? |
| Load model | open arrival, closed concurrency | How is work scheduled? |
| Profile | smoke, steady, ramp, stress, spike, soak | How does load change over time? |
| Purpose | regression, capacity, resilience, scalability, leak | Why is it being run? |
| Evidence policy | clean, APM, continuous profile, diagnostic campaign | What is collected? |

The compiler validates the combination against generator, target, data, and
diagnostic capabilities before it creates a run or sends traffic.

### 6.2 Scenario

A scenario expresses performance intent and selects a project workload. It
contains:

- Stable ID and display name.
- Workload type and selector.
- Named execution targets.
- Read/write/destructive effect classification.
- Replay and reset policy.
- Required and participating services.
- Default load model and profile inputs.
- Correctness and SLO policy references.
- Continuous-profile policy.
- Runtime diagnostic targets and preset.

It does not duplicate journey steps, URLs embedded in generator assets,
response extraction, cookies, control flow, retries, or think time.

### 6.3 Workload

Supported workload kinds:

- `request`: one operation per iteration.
- `journey`: one complete business journey per iteration unless the workload
  manifest explicitly declares another iteration contract.
- `mix`: deterministic weighted selection of complete requests or complete
  journeys.
- `protocol`: an adapter-declared workload such as gRPC, WebSocket, or messaging.

The workload manifest declares selectors, stable operation IDs, required input
and secret names, supported generators, included assets, expected request
amplification, and result contract. The generator asset remains authoritative
for the actual ordered steps.

### 6.4 Operation, step, and iteration

- An operation is a stable, bounded logical action used in evidence, such as
  `catalog.search` or `checkout.submit`.
- A step is generator-owned code that may issue a request, perform checks,
  extract state, retry, wait, or invoke another protocol operation.
- An iteration is one request for a request workload and one complete journey
  for a journey workload.
- Setup, authentication bootstrap, teardown, and data provisioning are not
  measured iterations unless the scenario explicitly selects them as workload.

## 7. Scenario Catalog v1alpha2

Add the byte-identical `scenario-catalog.schema.json` to PerfLab under
`schemas/catalog/v1alpha2/` and to `dotnet-perf-eng` under
`contracts/v1alpha2/`. JSON is the first normative format so both independent
implementations can validate it without a new YAML runtime dependency. YAML can
be added later as a lossless frontend.

Representative structure:

```json
{
  "apiVersion": "perflab.io/v1alpha2",
  "kind": "ScenarioCatalog",
  "contractRevision": "rwpe-1",
  "scenarios": [
    {
      "id": "checkout",
      "name": "Browse and buy",
      "workload": {
        "type": "journey",
        "selector": "browse-and-buy"
      },
      "targets": ["storefront", "payments"],
      "effects": {
        "classification": "idempotent-write",
        "replayable": true,
        "resetPolicy": "restore-snapshot"
      },
      "services": {
        "required": ["api"],
        "participating": ["worker", "payments"]
      },
      "defaults": {
        "loadModel": "open",
        "rate": 20,
        "rateUnit": "journeys/s"
      },
      "diagnostics": {
        "targets": ["api", "worker"],
        "preset": "cpu-memory",
        "sourceLoadLevel": "first-failing"
      },
      "sloProfile": "checkout-default"
    }
  ]
}
```

Validation rules:

1. IDs are stable bounded tokens and unique case-sensitively.
2. Selectors exist in the workload manifest.
3. Declared workload type matches the selector's iteration contract.
4. Named targets and services resolve in the selected execution target.
5. Rate unit is compatible with workload and load model.
6. Effects are explicit; write safety is not inferred from one HTTP method.
7. Reset policy is available before a replayable write run is accepted.
8. Diagnostic targets expose the requested runtime capability.
9. Every referenced policy exists and is version compatible.
10. Unknown fields fail in strict mode and warn only in explicit compatibility
    mode.

### 7.1 Legacy single-request compatibility

The TSV parser remains intact as the v1 request adapter. Each entry is converted
internally into a v1alpha2 request workload with:

- One stable operation derived from the scenario ID.
- One measured iteration attempts exactly one primary protocol request. Counts
  differ only for explicitly recorded initialization, cancellation, redirect,
  or generator-failure cases; failed HTTP/transport attempts still count as
  request attempts.
- `rateUnit == requests/s` for open execution.
- Existing method/path/body/connections/diagnostic behavior.
- Existing remote-write acknowledgement behavior.

The migration command writes an equivalent JSON catalog without changing
runtime behavior:

```text
perflab lab migrate-catalog --lab <id> --output scenario-catalog.json
```

TSV deprecation cannot begin until two stable releases after v1alpha2 reaches
feature parity.

## 8. Workload Manifest v1alpha2

Add the byte-identical `workload-manifest.schema.json` under each repository's
contract path defined above. It records generator capabilities without
duplicating the generator's step implementation.

Required selector fields:

- ID, workload type, and iteration contract.
- Supported generators and entrypoints.
- Included project-relative files and data assets.
- Stable operation IDs and bounded display names.
- Required target names.
- Required plain input names and secret references.
- Authentication/bootstrap/refresh behavior.
- Per-VU/session state lifetime and reset boundary.
- Setup and teardown measurement exclusion.
- Logical-operation, protocol-attempt, redirect, retry, and embedded-resource
  accounting policy.
- Request amplification minimum and maximum.
- Replayability and required dataset behavior.
- Supported load models and profile constraints.
- Required custom metric/result contract version.

All included assets contribute exact bytes to `workloadContentHash`. Secret
names contribute to configuration identity; secret values never do.

## 9. Load and result semantics

### 9.1 Offered and delivered load

The execution manifest records both requested and delivered load:

- Requested rate/concurrency and unit.
- Scheduled iterations or journey starts.
- Started, completed, failed, and aborted work.
- Dropped starts and queueing delay.
- Achieved journey/request rate.
- Active and peak VUs/threads.
- Generator CPU, memory, network, and saturation state.
- Graceful-stop and forced-cancel counts.

Rate units:

| Workload | Valid open-model unit | Valid closed-model unit |
| --- | --- | --- |
| request | `requests/s`, `iterations/s` | `concurrent-iterations` |
| journey | `journeys/s`, `iterations/s` | `concurrent-users` |
| request mix | `selections/s`, `iterations/s` | `concurrent-iterations` |
| journey mix | `journeys/s`, `iterations/s` | `concurrent-users` |
| protocol | Adapter-declared | Adapter-declared |

HTTP RPS for a journey is a measured result, never the offered journey rate.

### 9.2 Evidence v1alpha2

Add a byte-identical new load-result schema to each contract bundle rather than
silently changing v1alpha1 field meaning. Preserve v1alpha1 projection for
existing consumers.

Required sections:

- `workload`: type, selector, hashes, generator, iteration contract.
- `delivery`: offered and achieved load, dropped work, generator saturation.
- `journeys`: started/completed/failed/aborted and duration distribution.
- `operations`: per-operation count, failure, retry, and latency distribution.
- `requests`: logical requests, protocol attempts, wire/subrequest counts,
  redirects, started/completed/failed, protocol classifications, and latency.
- `checks`: stable check ID, scope, passes, failures, and abort impact.
- `correctness`: expected/observed business outcomes and reconciliation.
- `amplification`: logical operations, protocol attempts, wire requests, and
  dependency calls per completed journey, with the numerator named explicitly.
- `phases`: exact warmup, stabilization, measurement, recovery, and drain windows.
- `target`: resolved endpoints, lifecycle ownership, capability snapshot.
- `profiling`: policy, types, services, configuration, and capture states.
- `diagnostics`: child campaigns, source load level, artifacts, and overhead.
- `faults`: requested/applied/restored timeline and recovery result.
- `compatibility`: complete comparison dimensions and hashes.

Percentiles are calculated from raw or mergeable histograms. Distributed or
windowed results must never average percentiles.

Journey wall time includes intentional think time and generator-side control
flow that a user experiences. Operation latency excludes think time and covers
the declared operation boundary. Generator overhead and scheduling delay are
reported separately. A scenario declares whether a failed operation aborts,
continues, compensates, or marks the journey failed after cleanup.

## 10. Generator contracts

### 10.1 k6

Add a project-importable helper and a v1alpha2 summary contract. The helper
publishes bounded metrics for journey started/completed/failed/aborted,
journey duration, operation duration/failure/retry, and classified aborts.

Rules:

- `default()` completes exactly one declared iteration contract.
- A journey dispatcher selects and completes one entire journey.
- Setup and teardown traffic is classified separately.
- `group` and request `name` tags use stable operation IDs.
- Per-user, order, trace, and iteration IDs are forbidden as metric tags.
- Open executors schedule the declared workload unit.
- Journey-internal think time is valid. Arrival-rate workloads must not add an
  extra terminal pacing sleep; the executor already controls iteration starts.
- Per-VU session state and per-iteration journey state follow the workload
  manifest and are reset deterministically.
- A journey scenario without journey contract metrics fails closed.
- Threshold failures and application correctness failures remain distinct.
- The adapter parses custom metrics and submetrics into Evidence v1alpha2.

### 10.2 JMeter

Introduce `sampleSemantics: journey-v2` alongside `http-request-v1`.

Journey convention:

- Parent Transaction Controller sample: `journey::<journey-id>`.
- Child protocol sample: `op::<operation-id>`.
- Parent generation must be enabled and child samples retained.
- `Include duration of timer and pre-post processors` must be enabled for a
  journey parent so end-to-end journey duration includes intentional think time
  and correlation work. Operation samples retain their own protocol latency.
- Parent duration and outcome populate journey results.
- Child protocol samples populate operation and request results.
- Parent samples never increment HTTP request totals.
- Assertions contribute checks and operation/journey failure classification.
- Cookie managers, extractors, CSV data sets, timers, and bounded preprocessors
  are recognized.

Retain the secure allowlist. Arbitrary script samplers remain disabled by
default and require an explicit policy plus recorded plugin inventory.

Each repository owns and releases its own JMeter runner/adapter image and must
not use the other repository's image. The independent adapters must
nevertheless pass the same byte-identical JTL fixtures and produce contract-equivalent
results. Removing the current native dependency on `perflab-load-jmeter` is a
Slice 0 prerequisite.

The required end state is JMeter support for the same common HTTP
request/journey portfolio as k6: smoke, steady/load, ramp, stress,
breakpoint/capacity, spike, soak,
open-arrival, closed-concurrency, volume/data-scale, mix, resilience, recovery,
repeatability, and regression. Its open-model implementation must pin and test a
specific strategy. If JMeter's built-in experimental Open Model Thread Group is
used, the exact JMeter version, schedule, random seed, interruption behavior,
and known limitations are part of the capability and compatibility envelope.
Until those acceptance tests pass in both products, that capability remains
experimental rather than being approximated with a closed Thread Group.

### 10.3 wrk

wrk remains a request-only generator. Preflight rejects journey selectors,
stateful response correlation, journey mixes, and unsupported profiles.

### 10.4 Capability negotiation

Each adapter reports:

- Workload and protocol kinds.
- Open and closed load models.
- Supported profile primitives.
- Runtime load-update support.
- Streaming snapshot and histogram support.
- Distributed/shard support.
- Cancellation and graceful-stop behavior.
- Supported checks and result contract versions.

The compiler validates capabilities before readiness, data mutation, or load.

Minimum parity target:

| Generator/adapter | Required common capability in both repositories |
| --- | --- |
| k6 | Request and journey workloads; all HTTP-applicable profiles and purposes; open/closed models; streaming snapshots; sharding |
| JMeter | Request and journey workloads; all HTTP-applicable profiles and purposes after staged validation; open/closed models; streaming JTL/histograms; sharding |
| wrk | Stateless HTTP request, smoke/steady/load/repetition only; no journey claim |
| Browser synthetic | Low-scale functional/user-experience journey under concurrent backend load; never the primary high-scale generator |
| Protocol adapters | Only explicitly implemented gRPC/WebSocket/messaging/database capabilities; identical support state in both products |

Distributed JMeter defaults to independently orchestrated shards with partitioned
load and data, not implicit RMI multiplication. If RMI mode is added, the
compiler divides the intended total load because JMeter runs the complete plan
on each server, records Java/JMeter/plugin parity across nodes, controls RMI
ports/TLS, and detects controller or result-channel saturation.

## 11. Performance-engineering portfolio

All items below are required in both orchestrators. A generator may support a
subset only because of an intrinsic generator/protocol limitation, and the same
subset must be reported by both products.

| Category | Profile or purpose | Required behavior and evidence |
| --- | --- | --- |
| Workload | Single request | One operation per iteration; endpoint latency, errors, checks |
| Workload | Journey | Stateful ordered user flow and end-to-end outcome |
| Workload | Mix | Deterministic weighted complete workloads and achieved distribution |
| Validation | Smoke | Minimal load; readiness, auth, contract, correctness |
| Schedule | Fixed iterations | Exact shared/per-user work count and completion deadline |
| Schedule | Baseline/steady | Adaptive warmup, stable hold, clean comparison window |
| Schedule | Load | Expected production-like load for a bounded duration |
| Schedule | Ramp | Ordered load stages with per-level evidence |
| Boundary | Stress | Stepwise load until stop condition; last healthy and first failing |
| Boundary | Breakpoint | Bracket and narrow the maximum safe load |
| Boundary | Capacity/knee | Throughput/latency/resource curve and saturation boundary |
| Transient | Spike/burst | Baseline, surge, hold, recovery, recovery-time SLO |
| Endurance | Soak/endurance | One uninterrupted generator session and rolling windows |
| Load model | Open arrival | Fixed request/journey arrival rate, scheduling delay, dropped starts |
| Load model | Closed concurrency | Fixed concurrent user/iteration population |
| Scale | Volume | Payload, response, batch, or item-count scale with exact fingerprint |
| Scale | Data scale | Reproducible dataset tiers, reset/restore, count verification |
| Scale | Scalability | Resource/replica configuration versus capacity and efficiency |
| Scale | Elasticity/autoscaling | Scale-out/in lag, overshoot, backlog, thrashing, and recovery |
| Reliability | Resilience | Performance during dependency/instance degradation |
| Reliability | Fault/chaos | Verified fault apply/restore timeline and blast-radius policy |
| Reliability | Failover | Primary loss, routing transition, correctness, and recovery objective |
| Reliability | Recovery | Time and correctness required to return to steady state |
| Overload | Backpressure/rate limiting | Admission, rejection taxonomy, queue bounds, fairness, recovery |
| Contention | Concurrency/contention | Shared-resource saturation, locking, pool, and queue behavior |
| Isolation | Multi-tenant/noisy neighbor | Per-tenant SLO, fairness, interference, and resource isolation |
| Lifecycle | Cold start | Process start-to-ready and first successful work |
| State | Cold/warm cache | Explicit cache-state cohorts and transition evidence |
| Connection | Connection/TLS churn | Keep-alive, pool reuse, handshake, DNS, and reconnect behavior |
| Async | Async/drain | Accepted work, backlog, terminal outcome, and drain SLO |
| Memory | Memory/leak | Allocation, live heap, GC, RSS, and retained-growth slopes |
| Statistics | Repeatability | Independent repetitions and variance summary |
| Statistics | Regression | Compatible candidate/baseline statistics and gate decision |
| Client | Browser synthetic | Navigation/Core Web Vitals under controlled backend load |
| Protocol | Protocol-specific | Adapter-declared gRPC/WebSocket/messaging/database semantics |

### 11.1 Declarative profile configuration

Add a byte-identical `profile.schema.json` to each contract bundle with:

- Load model and unit.
- Warmup, stabilization, measurement, cooldown, recovery, and drain.
- Fixed or generated stages.
- Step, bracket, and binary-search policy.
- Repetitions and independence/reset rules.
- Safety ceilings for rate, concurrency, duration, errors, resource use, writes,
  and artifact bytes.
- Stop conditions for SLO, correctness, target health, generator saturation,
  disk, and operator cancellation.
- Rolling observation and checkpoint cadence.
- Diagnostic trigger and source-level selection.
- Connection model, protocol timeouts, retry policy, client pacing, and
  coordinated-omission policy.
- Purpose-specific configuration for autoscaling, failover, overload,
  isolation, browser synthetic, and connection churn.

CLI flags override scalar fields, and every override is recorded. Complex
profiles should use a file rather than accumulating stage-specific flags.

Steady-state evaluation is based on rolling throughput, latency, errors,
correctness, and resource signals after warmup. It must not declare stability
from latency alone. Open-model evidence includes scheduled-versus-actual start
delay and dropped work; closed-model evidence explicitly acknowledges that
throughput falls as journey duration rises.

Mix selection uses a recorded seed, normalized weights, per-shard seed
derivation, and an achieved-distribution tolerance. Failure to achieve the
declared mix is generator-invalid evidence rather than an application result.

### 11.2 Real soak requirements

- Start the load generator once for the measured soak.
- Keep authentication/session/setup state alive.
- Read rolling counters and mergeable histograms without restarting load.
- Capture periodic target, dependency, runtime, and correctness observations.
- Calculate slopes for RSS, managed heap, live heap, allocation, handles,
  threads, sockets, GC pause, queue depth, and error rate.
- Enforce disk and artifact budgets with retention tiers.
- Write atomic checkpoints and a heartbeat.
- Mark an interrupted soak partial. A restarted generator creates a new segment
  and must not be represented as one uninterrupted run.
- Permit collector recovery against a still-running generator only when the
  adapter exposes a durable session identity and replay-safe cursor.

## 12. Execution targets and optional lifecycle

Replace the overloaded local/remote distinction with target kind, location,
and lifecycle ownership.

| Target kind | Lifecycle ownership | Behavior |
| --- | --- | --- |
| Compose | managed | Start, validate, measure, stop according to policy |
| Local process | none | Connect and observe; never terminate it |
| Local container | none or managed | Respect declared ownership |
| Existing environment | none | Use configured endpoints; no deployment |
| Existing Kubernetes namespace | none | Connect by declared URLs/agent; no apply/delete/scale and no mandatory `kubectl` |
| Managed Kubernetes | managed | Optional explicit install/update/cleanup |
| Remote agent target | none or delegated | Agent reports exact allowed actions |
| External/SaaS API | none | Load-generator evidence plus allowed telemetry |

`lifecycle.ownership: none` is the default for configured existing targets.
Neither orchestrator may deploy, scale, restart, stop, reset, fault, or delete
target resources without a declared capability and the required acknowledgement.

Preflight still validates:

- Target and readiness reachability.
- TLS and clock requirements.
- Authentication and secret references.
- Named base URLs and generator routing.
- Metrics, logs, traces, profiles, and diagnostic endpoints.
- Dataset, reset, fault, scaling, and runtime-diagnostic capabilities.
- Write/destructive policy and budget.
- Exclusive lease requirements.

Local-machine and generator-host fingerprints include CPU model/count, memory,
OS/kernel, architecture, power/battery state where available, thermal/throttling
signals, container/VM resource allocation, generator placement, network path,
and material background-load checks. Required fingerprint fields and acceptable
drift belong to the environment policy. Shared environments support leases or
explicit noisy-environment classification rather than pretending isolation.

## 13. Data, authentication, and correctness

### 13.1 Data lifecycle

Support:

- Existing immutable dataset.
- API-driven seed and cleanup.
- Snapshot/restore.
- Per-run schema/database/tenant.
- Per-agent and per-VU data partitions.
- Unique input leasing.
- Idempotency-key policy.
- Write and storage-growth budgets.
- Async terminal-state reconciliation.

Record dataset fingerprint, preparation code hash, seed, scale, partition map,
pre/post counts, reset result, and cleanup result.

### 13.2 Authentication

Generator-owned auth may include login journeys, OAuth/OIDC token acquisition
and refresh, cookies, CSRF, API keys, mTLS, proxies, and signed requests.
Each orchestrator supplies named secret handles and non-secret inputs. Secret
values are never written to manifests, command lines, logs, or artifact bundles.

Recorded/replayed production-derived inputs require an explicit sanitization
and provenance policy. PII, credentials, session material, payment data, and
customer payloads are denied by default. Retained JTL, traces, dumps, profiles,
logs, and request/response samples carry a sensitivity classification,
redaction status, retention deadline, access policy, and encryption state where
required. Process dumps always require the existing sensitive-dump
acknowledgement or its v1alpha2 equivalent.

### 13.3 Correctness

Correctness is a first-class gate, not an HTTP-status proxy. Capture:

- Journey completion and classified abort reason.
- Assertions and invariant checks.
- Expected, accepted, persisted, duplicated, corrupted, and terminal outcomes.
- Retry and idempotency behavior.
- Queue/backlog drain result.
- Cleanup/restoration result.

A faster run with failed correctness is ineligible for a passing regression
decision.

## 14. Observability, profiling, and diagnostics

### 14.1 Correlation

Use bounded resource/span dimensions:

- `perf.run.id`
- `perf.scenario.id`
- `perf.workload.id`
- `perf.journey.name`
- `perf.operation.name`
- `perf.phase`
- `service.name` and `service.instance.id`

Run IDs may scope traces/logs and exact run queries, but per-iteration IDs must
not become metric or profile labels. W3C trace context and baggage carry request
correlation where safe.

### 14.2 APM evidence

For each phase and service, capture:

- Request and dependency rate, errors, and latency.
- Database, cache, messaging, and external-service spans.
- Exemplars for slow and failed operations.
- Trace summaries and critical-path attribution.
- Bounded raw trace details under limits.
- Error logs and structured run/journey/operation correlation.
- Runtime, process, container, and dependency metrics.
- Sampling policy and evidence completeness.
- Required/optional/unavailable state for every configured source and signal.
- Query window, ingestion delay, clock skew, retry, truncation, and result limits.
- Service-instance churn so restarted processes, pods, and replicas remain
  attributable to the correct phase without folding stale series into results.

Journey evidence can span several server traces. Correlate them by run and
bounded journey name; do not create one unbounded span covering think time by
default.

### 14.3 Pyroscope

Extend continuous profiling from CPU-only to explicit profile policies:

| Type | Intended use |
| --- | --- |
| CPU | Default continuous profiling cohort |
| Wall time | Blocking, waits, and I/O investigations |
| Allocation | Allocation-heavy and memory campaigns |
| Lock contention | Contention and stress campaigns |
| Exceptions | Exception-heavy anomaly campaigns |
| Live heap | Periodic soak checkpoints and memory diagnostics |

Provide named policies such as `cpu`, `cpu-wall`, `memory`, `contention`,
`exceptions`, `soak-memory`, and `all-diagnostic`. Record exact enabled types,
sampling/upload configuration, profiler version, tiered-compilation behavior,
service set, and per-type capture state. Query and retain every requested type
independently.

Only supported trace/profile correlation is claimed. Other profile types remain
service/run/window correlated unless the profiler exposes a bounded supported
correlation mechanism.

Profiling policy contributes to the overhead compatibility hash. Provide
profiling-on/off calibration; never compare unlike policies as one cohort.

The .NET continuous profiler is normally selected when the target process
starts, not toggled casually during a measurement. Managed targets compile the
policy into a distinct profiling cohort before startup. For an unmanaged target,
the orchestrator validates and records the already-effective profiler types and
queries them; it does not restart or reconfigure the process without lifecycle
ownership. Unsupported runtime/OS/architecture/type combinations fail the
requested profiling capability or are explicitly optional according to policy.

### 14.4 `dotnet-monitor`

Keep invasive artifacts in diagnostic child runs by default. Support trace,
gcdump, stacks, dump, and ordered presets such as CPU, memory, CPU-memory, hang,
and dump.

For multiple services, execute separate target campaigns unless an explicit
concurrent-capture policy and overhead budget are present. Replay the exact
workload selector, assets, target map, data/auth policy, generator configuration,
and selected stress/capacity load level.

Non-replayable destructive journeys require a cloned dataset or an explicit
standalone diagnostic run; automatic replay is rejected.

Trace, dump, gcdump, and stack artifacts record target identity, capture window,
tool/runtime version, content hash, sensitivity, redaction limits, retention,
and access policy. Dumps are never collected by an aggregate `all` switch and
remain separately acknowledged because they can contain credentials and
personal data.

## 15. Orchestration state machine

The required state machine in each independent orchestrator is:

```text
resolve inputs
  -> validate contracts and capabilities
  -> acquire target/data lease
  -> preflight generator and evidence endpoints
  -> provision/start only when lifecycle is managed
  -> readiness
  -> prepare dataset and workload
  -> warmup
  -> stabilize
  -> measure/profile stages
  -> recover
  -> drain and reconcile correctness
  -> collect target/dependency/APM/profile evidence
  -> run diagnostic child campaigns
  -> normalize
  -> analyze, compare, and gate
  -> package evidence, write integrity manifest, and sign when policy requires
  -> restore faults/data and release lease
  -> stop only owned resources
```

Every transition is persisted atomically. Cleanup is ownership-aware and
idempotent. Cancellation stops load, restores faults, captures bounded partial
evidence, marks the run partial/interrupted, and never destroys unowned targets.

## 16. Comparison and gates

Compatibility must include:

- Contract and evidence versions.
- Scenario/workload selector and content hash.
- Operation map and iteration contract.
- Generator name, version, image/binary hash, and capabilities.
- Load model, rate unit, compiled stages, duration, and graceful-stop policy.
- Dataset and preparation fingerprint.
- Target endpoints and resource/environment envelope.
- Deployment/lifecycle mode without volatile run identity.
- Application/source/build identity.
- Telemetry and sampling policy.
- Continuous-profile policy and tiering/runtime settings.
- Diagnostic overhead policy.
- Fault and scaling policy.

Use independent repetitions, median/IQR, bootstrap confidence intervals, and
Mann-Whitney analysis where sample size permits. A gate is inconclusive rather
than passing when required evidence is missing, incompatible, partial, generator
saturated, or correctness-invalid.

The policy declares minimum completed repetitions, outlier handling, practical
effect-size thresholds, confidence level, and multiple-metric decision rules.
Warmup/stabilization observations never enter the measurement distribution.
Baseline approval records dirty-tree state, build identity, environment noise,
and operator justification. A baseline is immutable; replacement creates an
auditable new approval instead of rewriting history.

## 17. CLI and compatibility surface

Add common controls:

```text
--workload <selector>
--profile-config <path>
--rate <number>
--rate-unit <requests/s|journeys/s|iterations/s>
--warmup <duration>
--stabilization <duration>
--cooldown <duration>
--graceful-stop <duration>
--execution-target <id>
--lifecycle <none|managed>
--target-set <id>
--dataset <id>
--diagnostic-target <service>        # repeatable
--diagnostic-source-level <selector>
--profile-types <csv>
--profile-policy <id>
--max-duration <duration>
--max-rate <number>
--max-concurrency <number>
--max-artifact-bytes <bytes>
--write-budget <number>
--distributed
--shards <number>
--resume <run-id>
```

Compatibility mapping:

| Existing input | v1alpha2 mapping |
| --- | --- |
| `--connections` | Closed concurrency |
| `--start-rps`, `--target-rps` | Request rate only for request workloads; warn otherwise |
| `--max-vus`, `--spike-vus` | Profile limits/stages |
| `--soak-duration` | Soak measurement duration |
| `--rates` | Explicit staged rate list |
| `--mix` | Workload selector of type mix |
| `--seed-scale`, `--scale`, `--scales` | Dataset selection/scale |
| `--repeats`, `--reseed` | Repetition and reset policy |
| Fault flags | Fault policy overrides |
| `--target local|remote` | Compatibility target resolver |

All CLI overrides are normalized into the execution manifest. Environment
variables remain supported for automation, but secret values must use secret
providers/handles rather than plain manifest fields.

### 17.1 Existing PerfLab interface that must remain compatible

| Path | Existing controls to preserve |
| --- | --- |
| `version` | Version output and exit behavior |
| `init` | `--root` |
| `doctor` | `--root`, `--require-docker`, `--min-docker-cpus`, `--min-docker-memory`, `--min-free-disk`, `--target`, `--require-profiler-access`, `--require-clock-sync`, repeatable `--port`, repeatable `--plugin` |
| `systems` | `list`, `validate`, `inspect`; existing `--root` behavior |
| `plans` | `list`, `validate`, `render`; existing `--root` behavior |
| `plugins` | `list`, `install`, `remove`, `inspect`, `doctor`; existing `--root` behavior |
| `run` | Experiment path and `--root` |
| `suite run` | Suite path, `--root`, `--output`, `--continue-on-error` |
| `lab run`, `lab suite` | Scenario selectors and the common lab flags listed below |
| `pe` | `repeat`, `sweep`/`knee`, `mix`, `data-scale`, `fault`, `history`/`trend` and their flags below |
| `runtime capture` | Recorded-run target plus runtime campaign flags below |
| `gate` | Run path/ID, `--root`, `--require-steady`, `--allow-partial`, `--allow-missing`, `--slos`, `--baseline-json`, `--threshold`, `--baseline`, `--policy` |
| `analyze` | Run path/ID, `--root`, `--prompt`, `--scope`, `--lab`, `--scenario`, `--suite-baseline`, `--baseline`, `--response`, provider identity/version/model controls, `--source-root`, `--p99-ms` |
| `compare` | Baseline/candidate, `--root`, `--policy`, common/baseline/candidate workload, dataset, environment-envelope, overhead-policy, and phase-duration controls |
| `runs` | `list`, `show`, `cancel`, `resume`, `export`; `--root`, `--limit`, `--status`, `--output`, `--normalized-only` |
| `report` | Run/comparison ID and `--root` |
| `baseline` | `set`, `list`, `remove`; `--root`, `--project`, `--environment`, `--system`, `--plan`, `--approved` |
| `parity` | `--native-facts`, `--perflab-run`, `--perflab-diagnostic-run`, `--contract`; aggregate mode with `--contract` |
| `clean` | `--root`, `--retention` |
| `perflab-agent version`, `perflab-agent serve` | `--root`, loopback-only `--listen`; future remote-agent exposure requires a new authenticated transport rather than widening this listener |

Current common lab controls retained during migration:

```text
--root --output --lab --lab-config --duration --profile --generator
--base-url --ready-url --prometheus-url --tempo-url --loki-url
--grafana-url --pyroscope-url --diagnostics-url --prom-job-regex
--service-name-regex --log-limit --trace-limit --headers --seed-scale
--target --mix --ack --write-ack --connections --max-vus --spike-vus
--start-rps --target-rps --k6-prom-rw --no-runtime --measure-only
--retain-native-trace --no-retain-native-trace --remote-telemetry
--continuous-profiling --remote-diagnostics --allow-unhealthy
--print-experiment --skip-analyzers --continue-on-error --soak-duration
```

`PERFLAB_PROFILING_KEEP_TIERING` remains supported and is recorded even though
it currently has no public CLI flag.

Current PE-specific controls retained:

- `repeat`: `--repeats`, `--reseed`, plus common lab controls.
- `sweep`/`knee`: `--rates`, plus common lab controls.
- `mix`: `--mix`, plus common lab controls.
- `data-scale`: `--scale`/`--scales`, compatibility `--reseed`, plus common
  lab controls.
- `fault`: `pause|stop` or `--kind`, `--at`, `--for`, `--service`/`--dependency`,
  plus common lab controls.
- `history`/`trend`: `--root`, `--lab`, `--limit`, `--metric`.

Current runtime campaign controls retained:

```text
--root --kind trace|gcdump|stacks|dump
--preset cpu|memory|cpu-memory|hang|dump
--output --duration --warmup --recovery --artifact-budget-bytes
--include-dump --dump-ack --retain-native-trace
--no-retain-native-trace --remote-diagnostics --ack
--diagnostics-url --lab-config --write-ack
```

`--lab-config` remains rejected for recorded replay until the v1alpha2 replay
contract safely defines it. Compatibility flags retain their current meaning
for v1 request workloads and receive explicit migration errors rather than a
silent reinterpretation for journeys.

### 17.2 Existing `dotnet-perf-eng` interface that must remain compatible

| Path | Existing controls to preserve |
| --- | --- |
| `run-scenario.sh` | Scenario ID and duration; environment-selected generator/profile/target |
| `run-scenarios.sh` | Comma list or `all`, duration, `--with-runtime`, `--no-runtime`/`--measure-only`, `--continue-on-error` |
| `run-single.sh`, `run-multiple.sh`, `run-all.sh` | Existing positional selectors/duration and forwarding behavior |
| `run-repeat.sh` | `--repeats`, `--reseed`, `--profile` |
| `run-sweep.sh` | `--rates`; accepted measurement/runtime compatibility options |
| `run-mix.sh` | `--connections`, `--profile` |
| `run-data-scale.sh` | `--scales`, `--profile` |
| `run-fault.sh` | `--dependency`, `--kind`, `--at`, `--for`, `--profile` |
| `gate.sh` | `--baseline`, `--slos`, `--threshold`, `--no-baseline`, `--allow-missing`, `--allow-partial`, `--require-steady` |
| `compare-runs.sh` | `--threshold`, `--allow-generator-mismatch` |
| `find-knee.sh` | `--p99-ms`, `--slos`, `--step` |
| `steady-state.sh` | `--buckets`, `--tput-drift`, `--lat-drift`, `--warmup-frac`, `--warmup-tol`, `--lat-floor-ms` |
| `trend-report.sh` | `--lab`, `--scenario`, `--metric`, `--profile`, `--last`, `--include-partial` |
| `update-baseline.sh` | `--scenario`, `--allow-partial` |
| `diff-gcdump.sh`, `diff-profile.sh` | `--top` |
| `capture-runtime.sh` | Isolated `trace|gcdump|stacks|dump`, ordered `--preset`, duration, `--include-dump`, and existing safety environment |

Existing native environment groups remain accepted and become explicit manifest
inputs:

- Lab/target/lifecycle: `PERFLAB_LAB`, `PERFLAB_CONFIG`, `PERFLAB_PROJECT`,
  `PERFLAB_RUNTIME`, `PERFLAB_TARGET`, `PERFLAB_COMPOSE_FILE`,
  `PERFLAB_APP_SERVICES`, `PERFLAB_PRIMARY_APP_SERVICE`, `PERFLAB_BASE_URL`,
  `PERFLAB_READY_URL`, `PERFLAB_INTERNAL_BASE_URL`, `PERFLAB_COMPOSE_NETWORK`.
- Load: `PERFLAB_LOAD_GENERATOR`, `PERFLAB_PROFILE`,
  `PERFLAB_CONNECTIONS`, `PERFLAB_DURATION_SECONDS`, `PERFLAB_MAX_VUS`,
  `PERFLAB_SPIKE_VUS`, `PERFLAB_START_RPS`, `PERFLAB_TARGET_RPS`,
  `PERFLAB_SOAK_DURATION_SECONDS`, k6/wrk/JMeter entrypoint, image, file,
  warmup, timeout, and resource settings.
- Workload correlation: `PERF_SCENARIO`, `PERF_RUN_ID`, `PERF_RUN_MODE`,
  `PERF_METHOD`, `PERF_PATH`, `PERF_BODY`, `PERF_BASE_URL`, `PERF_HEADERS`,
  `PERF_MIX`.
- Telemetry: Prometheus, Tempo, Loki, Grafana, Pyroscope, diagnostics URLs;
  job/service filters, run attribute, metric roles/prefix, query limits, and k6
  remote-write settings.
- Profiling/diagnostics: continuous-profiling, keep-tiering, Pyroscope service
  mappings, diagnostic target mappings, preset, recovery, stacks enablement,
  artifact budget, include-dump, trace retention, and dump acknowledgement.
- Safety/remote: remote telemetry, diagnostics, unhealthy-target override,
  diagnostic/write acknowledgements, write budget, and capture-incomplete state.
- Data/dependencies/faults: seed scale, dataset identity, Postgres/Redis/RabbitMQ
  settings, dependency hooks, sweep/repeat/mix/data-scale settings, and fault
  target/kind/timing.
- Artifacts/suite/analysis: artifact roots/run IDs, suite identity/index/count,
  trend/bottleneck/steady-state controls, and leak threshold.

Exact current flag and environment behavior receives golden compatibility tests
before refactoring. Variables may later gain clearer aliases, but no existing
automation input is removed or repurposed during v1alpha2 delivery.

## 18. Repository implementation maps

### 18.1 PerfLab new packages and schemas

- `schemas/catalog/v1alpha2`: scenario catalog.
- `schemas/load/v1alpha2`: workload manifest and generator capability.
- `schemas/profile/v1alpha2`: composable profile definition.
- `schemas/evidence/v1alpha2`: execution manifest and load result.
- `internal/catalog`: load, migrate, validate, and hash catalogs.
- `internal/workload`: selector resolution and workload identity.
- `internal/capability`: compile-time capability negotiation.
- `internal/target`: endpoint, lifecycle, ownership, and lease resolution.
- `internal/session`: continuous load session and rolling snapshot abstraction.

### 18.2 PerfLab existing code to change

- `internal/lab/types.go`: replace endpoint-only scenario dependency with the
  versioned scenario/workload reference while preserving the legacy view.
- `internal/lab/discover.go`: load JSON catalog first and adapt TSV when used.
- `internal/lab/compile.go`: compile request/journey/mix, target ownership,
  capabilities, profiling policy, and v1alpha2 evidence expectations.
- `internal/lab/profiles.go`: become a compatibility frontend to the canonical
  profile compiler.
- `internal/core/model/domain.go`: finalize scenario, journey, operation, target,
  and workload invariants.
- `internal/core/model/load.go`: add delivery, journey, operation, histogram,
  saturation, and amplification fields.
- `internal/core/model/profile.go`: add composable purpose/profile fields.
- `internal/core/model/correctness.go`: add journey/business reconciliation.
- `internal/orchestrator/experiment.go`: accept validated journeys and workload
  selectors instead of rejecting them.
- `internal/orchestrator/run.go` and split runtime files: implement the persisted
  state machine, continuous sessions, target ownership, and child campaigns.
- `internal/profiles`: use continuous sessions and correct open/closed units.
- `plugins/load/k6`: parse v1alpha2 custom metrics and capabilities.
- `plugins/load/jmeter`: add journey-v2 parent/child parsing and additional
  profile capabilities.
- `plugins/load/wrk`: advertise and enforce request-only capability.
- `plugins/apm/grafana`: operation-aware queries and all requested Pyroscope
  profile types.
- `internal/comparison`, `internal/peanalyze`, `internal/reporting`: v1alpha2
  compatibility, statistics, and reports.
- `internal/cli`: catalog, profile, target, diagnostic, and migration commands.
- `api/control` and `sdk`: expose new models without breaking v1alpha1 clients.
- `internal/parity`, `test/conformance`, and `test/acceptance`: independent
  contract and end-to-end coverage.

### 18.3 `dotnet-perf-eng` new contracts and core modules

- `contracts/v1alpha2`: local schema copies and conformance fixtures.
- `harness/core/catalog`: validate, load, migrate, select, and hash catalogs.
- `harness/core/workload`: resolve selectors, assets, inputs, targets, secrets,
  and capability requirements.
- `harness/core/profile`: validate, compile, execute, observe, and checkpoint
  canonical native profiles.
- `harness/core/target`: target descriptors, readiness, lifecycle ownership,
  safety, and exclusive leases.
- `harness/core/orchestrate`: persisted state, stages, cancellation,
  ownership-aware cleanup, and partial recovery.
- `harness/core/session`: continuous generator session and rolling snapshot
  abstraction.

### 18.4 `dotnet-perf-eng` existing code to change

- `harness/core/lib/common.sh`: preserve portable v1 helpers while routing
  scenario/workload access through the versioned catalog.
- `harness/core/lib/lab-context.sh`: resolve target kind, lifecycle ownership,
  capabilities, target set, data policy, and evidence policy.
- `harness/core/run/run-scenario.sh`: become a stable frontend to the persisted
  native state machine.
- `harness/core/run/run-scenarios.sh`: retain suite behavior over normalized
  v1alpha2 child executions.
- `harness/core/pe-tests`: become purpose-specific frontends to the shared
  native workload/profile engine and add missing portfolio commands.
- `harness/adapters/loadgen/k6`: journey helper, selector contract, capability,
  continuous session, and v1alpha2 normalization.
- `harness/adapters/loadgen/jmeter`: replace the PerfLab-owned image with a
  repository-owned Dockerfile, runner, normalizer, package flow, fixtures,
  journey-v2 parsing, profile support, and capability output.
- `harness/adapters/loadgen/wrk`: advertise and enforce request-only support.
- `harness/adapters/observability/grafana`: operation-aware queries and every
  requested Pyroscope profile type.
- `harness/adapters/runtime/dotnet`: ordered multi-target campaigns, selected
  load-level replay, and complete compatibility evidence.
- `harness/adapters/dependency`: capability descriptors plus ownership-aware
  reset, snapshot, fault, and restoration.
- `harness/core/capture/capture-evidence.sh`: v1alpha2 result, APM correlation,
  multi-type profiles, and completeness states.
- `harness/core/analyze`: journey/operation comparison, robust statistics,
  compatibility, trend, gate, and report behavior.
- `labs/*`: add JSON catalogs, workload manifests, profile examples, real
  journeys, operation-aware dashboards, and retain `scenarios.tsv`.

The `dotnet-perf-eng` JMeter runner is an independently implemented static Go
helper built inside a repository-owned multi-stage Docker build. It launches
the pinned Java/JMeter runtime, streams and normalizes JTL, validates capability
and result contracts, and exposes `run-once`, `normalize`, and `version` modes.
Go and Java are not host prerequisites. The final image, source, package script,
digest pin, and release provenance live entirely in `dotnet-perf-eng`; no source
or binary is copied from PerfLab. Repository-owned contract validation tooling
uses the checked-in contract bundle and is packaged through the same independent
toolchain.

## 19. Delivery slices

Each slice must be releasable, tested, documented, backward compatible, and
implemented independently in both repositories before full-parity status is
claimed.

Slices are dependency ordered and land as coordinated repository changes. A
slice can merge independently behind `experimental`, but it cannot be marked
`supported` or used for a cross-product baseline until both repositories carry
the same contract-bundle digest and pass that slice's acceptance cases. Slice 0
through Slice 3 are prerequisites for journey measurements; Slice 4 is required
before non-steady journey profiles; Slice 5 is required before production soak.

### Slice 0: contract and fixture freeze

- Write ADRs for independence, ownership, rate units, journey semantics, and
  diagnostic isolation.
- Add v1alpha2 schemas and canonical positive/negative fixtures.
- Add `contractRevision` validation and conformance runner.
- Define capability identifiers and unsupported-combination errors.
- Prove each repository's conformance suite runs without the other checkout.
- Remove `dotnet-perf-eng`'s use of the PerfLab JMeter image and introduce its
  independently built and pinned runner image without regressing request-only
  JMeter behavior.

Exit: schemas, fixtures, and semantics are reviewed; the native JMeter runtime
is independent while request/JTL semantics remain unchanged.

### Slice 1: catalog and single-request compatibility

- Add JSON catalog/workload manifest parsing.
- Adapt TSV to request workloads.
- Add validate and migrate commands.
- Compile request scenarios through v1alpha2 without changing measured output.
- Add target/lifecycle ownership model in compatibility form.

Exit: every existing sample and v1 scenario passes unchanged; migrated output
is behaviorally equivalent.

### Slice 2: journey-aware evidence and k6

- Extend models/schemas/SDKs.
- Add k6 helper and selector binding.
- Parse journey, operation, request, check, amplification, and delivery metrics.
- Convert one reference lab to a stateful journey.
- Add cardinality and secret-leak tests.

Exit: a five-step journey with extraction, checks, think time, retries, and a
mid-step failure produces correct independent counts.

### Slice 3: JMeter journey and generator capabilities

- Add journey-v2 validation and parsing.
- Separate transaction parents from protocol children.
- Support selector properties and required plan components.
- Add capability negotiation to all generators.
- Add equivalent k6/JMeter conformance fixtures.
- Define the pinned JMeter closed/open scheduling strategies and their
  interruption, timer, random-seed, and result semantics.

Exit: k6 and JMeter produce semantically equivalent evidence for the same
journey; wrk rejects it before traffic.

### Slice 4: canonical profile engine

- Consolidate lab and generic profile compilation.
- Implement smoke, load, steady, ramp, stress, breakpoint, capacity/knee,
  spike, open, closed, and repetition behavior.
- Record last healthy/first failing levels and generator saturation.
- Add adaptive warmup/stabilization and safety stops.
- Implement each applicable profile through both the k6 and JMeter capability
  paths; do not mark the profile supported when only one repository has it.

Exit: every profile has deterministic compiled stages and golden execution
tests for request and journey units.

### Slice 5: continuous soak and long-run durability

- Add continuous load session APIs and streaming histograms.
- Stop restarting generator sessions for soak observations.
- Add checkpoints, heartbeats, rolling correctness, leak slopes, retention,
  artifact/disk limits, cancellation, and partial-run recovery.

Exit: accelerated soak proves one generator process/session; scheduled 8-hour
and 24-hour validation runs meet retention and stability requirements.

### Slice 6: unmanaged and managed targets

- Add local-process, local-container, existing-environment, existing-Kubernetes,
  managed-Compose, optional managed-Kubernetes, and agent target descriptors.
- Make lifecycle mutation conditional on ownership.
- Add named multi-origin routing, TLS/auth, clock, and exclusive leases.
- Add target capability snapshots and safety acknowledgements.

Exit: the same workload runs against an already-running local process and a
configured remote environment without deploy/start/stop calls.

### Slice 7: data, fault, scale, recovery, and drain

- Add data providers, partitions, reset/restore, write budgets, and cleanup.
- Expand fault providers to network delay/loss/reset/bandwidth, dependency
  pause/stop/restart, process/instance kill, CPU, memory, and disk pressure.
- Add scalability, cold/warm, async/backlog, recovery, and drain orchestration.
- Add failover, elasticity/autoscaling, overload/backpressure, contention,
  multi-tenant isolation, and connection/TLS churn policies.
- Require fault apply/restore proof and ownership-aware cleanup.

Exit: correctness, fault, and recovery evidence is complete and a failed cleanup
cannot produce a passing gate.

### Slice 8: profiling, diagnostics, and APM

- Add multi-type Pyroscope configuration, queries, capture states, and overhead
  compatibility.
- Add multi-target `dotnet-monitor` campaigns and load-level replay.
- Add operation-aware metrics/traces/logs and critical-path reporting.
- Add diagnostic artifact budgets and non-replayable workload rules.

Exit: CPU, wall, allocation, lock, exception, and heap policies are tested;
separate API/worker campaigns preserve clean measurement evidence.

### Slice 9: distributed load and protocols

- Add authenticated agent registration, clock checks, shard plans, unique data
  partitions, streaming mergeable histograms, and partial-agent policy.
- Add execution segments for k6 and an explicit JMeter distributed strategy.
- Add protocol adapter contracts for gRPC/WebSocket/messaging as implemented.
- Add a bounded browser-synthetic adapter that runs alongside, but does not
  replace, the backend load generator.

Exit: aggregate results preserve counts and histograms, identify generator
saturation per shard, and never average percentiles.

### Slice 10: reports, gates, migration, and release

- Update reports, trends, analysis, comparison, and gate messages.
- Add v1alpha1 projections and migration documentation.
- Add capability matrix command and support-level reporting.
- Complete security, performance-overhead, platform, and interruption tests.
- Publish upgrade and rollback procedures.
- Verify byte-identical plan, schema, fixture, and contract-lock digests in the
  coordinated parity workflow.

Exit: release checklist and full acceptance matrix pass in both independent
repositories.

## 20. Acceptance matrix

Required end-to-end cases:

1. Legacy TSV GET and write scenarios remain unchanged.
2. JSON request workload matches the equivalent TSV result.
3. Stateful checkout performs login, browse, create, pay, poll, and verify.
4. Dynamic values, cookies, token refresh, CSRF, retries, and think time work.
5. A failed middle operation fails the journey without corrupting request counts.
6. k6 and JMeter split journey parent and HTTP request counts correctly.
7. Weighted mixes select complete workloads and report achieved distribution.
8. Open arrival proves journey starts/s and derived request amplification.
9. Closed execution proves concurrent user/session semantics.
10. Stress distinguishes target saturation from generator starvation.
11. Breakpoint records last healthy and first failing levels.
12. Spike records failure and recovery time by phase.
13. Soak uses one uninterrupted generator session and emits rolling checkpoints.
14. Data-scale restores and verifies each dataset fingerprint.
15. Fault execution proves apply and restore, including interrupted cleanup.
16. Async execution reconciles accepted, completed, duplicate, corrupt, and
    outstanding work after drain.
17. Existing local process runs without deployment or termination.
18. Existing remote environment runs without lifecycle mutation.
19. Existing Kubernetes mode performs no apply/delete/scale action.
20. Multi-origin journey routes only to allowlisted targets.
21. CPU/wall/allocation/lock/exception/live-heap profile states are recorded.
22. API and worker runtime campaigns replay the selected load level separately.
23. Baseline compatibility rejects workload, operation, rate-unit, dataset,
    target, environment, generator, or profiling-policy mismatch.
24. Missing/partial/incompatible/correctness-invalid evidence cannot pass a gate.
25. Cancellation preserves partial evidence and restores owned mutations.
26. Secret scanning finds no credential values in arguments or artifacts.
27. Cardinality tests reject unbounded metric/profile labels.
28. Distributed aggregation matches a single-node fixture without percentile
    averaging.
29. Both repositories pass the same fixture corpus while installed alone.
30. No test shells out to, imports, downloads, or starts the other product.
31. Contract bundles and lock files have the same aggregate digest.
32. JMeter journey duration includes timers/pre/postprocessors while operation
    latency excludes think time.
33. Logical operations, retries, redirects, embedded resources, protocol
    attempts, and wire-request amplification are not conflated.
34. k6 arrival-rate tests record scheduling delay, dropped iterations, and VU
    exhaustion without calling the configured journey rate HTTP RPS.
35. JMeter open-model tests use the pinned validated strategy and never silently
    substitute a closed Thread Group.
36. JMeter sharding does not multiply intended total load and detects controller
    or result-channel saturation.
37. Autoscaling captures scale-out/in lag, thrashing, backlog, and efficiency.
38. Backpressure tests distinguish intentional rejection from transport or
    application failure and verify bounded recovery.
39. Noisy-neighbor tests report fairness and per-tenant SLOs without unbounded
    tenant labels.
40. Connection-churn tests distinguish DNS, TLS, connection, queue, and server
    latency.
41. Browser synthetic results remain separate from backend load-generator SLIs
    and are correlated by the bounded run/workload dimensions.
42. An unmanaged target's profiler configuration is observed, never changed by
    restarting or reconfiguring the process.
43. Required versus optional telemetry sources produce captured, partial,
    unavailable, or intentionally-disabled states without false completeness.
44. Restarted pods/processes are scoped to the correct measurement window and
    stale instances are excluded.
45. JTL, traces, profiles, dumps, logs, and samples satisfy sensitivity,
    redaction, retention, and access-policy checks.
46. Local-host fingerprints detect material power, thermal, resource-envelope,
    background-load, and generator-placement drift.
47. Resume never represents a restarted generator as one continuous soak.
48. Every current CLI flag and native environment input in the compatibility
    inventory has a golden parse/manifest test.

## 21. Release gates and definition of done

A capability is marked supported only when:

- Its schema, semantic rules, and failure modes are documented.
- PerfLab implements and tests it independently.
- `dotnet-perf-eng` implements and tests it independently.
- The byte-identical conformance corpus passes in both repositories.
- The contract bundle and `contract-lock.json` aggregate digest match exactly.
- Product capability matrices match for every generator/target/contract tuple.
- Unsupported generators/targets fail before traffic or mutation.
- Evidence is complete enough for an honest gate or explicitly inconclusive.
- Security, ownership, cleanup, and artifact-budget tests pass.
- User documentation includes a request example and, where applicable, a
  journey example.

The overall initiative is complete when every required portfolio item has an
implemented capability path, all acceptance cases pass, v1 request workflows
remain supported, and neither repository has any runtime or build dependency on
the other.

## 22. Normative external references

Implementation and acceptance tests must pin product versions and verify the
behavior used by the contract against the corresponding official documentation:

- [k6 scenario executors](https://grafana.com/docs/k6/latest/using-k6/scenarios/executors/)
- [k6 open and closed models](https://grafana.com/docs/k6/latest/using-k6/scenarios/concepts/open-vs-closed/)
- [k6 arrival-rate VU allocation and dropped iterations](https://grafana.com/docs/k6/latest/using-k6/scenarios/concepts/arrival-rate-vu-allocation/)
- [Pyroscope .NET supported profile types and configuration](https://grafana.com/docs/pyroscope/latest/configure-client/language-sdks/dotnet/)
- [Pyroscope .NET span-profile correlation](https://grafana.com/docs/pyroscope/latest/configure-client/trace-span-profiles/dotnet-span-profiles/)
- [JMeter Transaction Controller, Open Model Thread Group, timers, extractors, assertions, and samplers](https://jmeter.apache.org/usermanual/component_reference.html)
- [JMeter distributed testing](https://jmeter.apache.org/usermanual/remote-test.html)

Official behavior is an input to adapter implementation, not a substitute for
the repository-owned capability tests and evidence contract.
