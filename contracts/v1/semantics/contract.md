# Performance engineering contract semantics (`v1`)

This document contains the normative rules that cannot be expressed completely
by the JSON Schemas. Missing capability data means unsupported. Unknown
combinations fail closed before readiness, data mutation, or load.

## Workloads and journeys

A legacy TSV scenario compiles to one request workload. Its stable operation ID
is the scenario ID, and one measured iteration attempts exactly one primary
protocol request. Initialization, cancellation, redirects, retries, generator
failures, setup, teardown, and authentication bootstrap are not additional
measured iterations. Failed HTTP and transport attempts remain visible in
request-attempt totals. Open request execution uses `requests/s`.

A measured journey iteration is one complete parent labelled
`journey::<id>`. Protocol children use `op::<name>`. A failed middle operation
fails the journey without corrupting parent or child counts. Homogeneous mixes
contain only one `memberKind`. The managed reference checkout executes login,
browse, create, pay, poll, and verify; create and pay require acknowledged seed
and reset readiness.

k6 and JMeter support request and journey workloads. wrk is request-only and
rejects journeys before traffic. Browser synthetic workloads remain separate
from backend SLI load.

## Canonical profiles and sessions

Smoke, load/steady, ramp, stress, breakpoint/capacity/knee, spike, open, closed,
and soak compile to deterministic stages. A profile is supported only when both
k6 and JMeter capability paths implement it. wrk supports request-only smoke and
steady/load.

A continuous session advertises `Start`/`Snapshot`/`Stop` as one base
capability. `UpdateLoad` is a separate optional capability. Soak is rejected
before traffic when the base session capability is absent.

## Capability identifiers

| Identifier | Meaning |
| --- | --- |
| `workload.request` | One request per measured iteration |
| `workload.journey` | One complete journey per iteration |
| `workload.mix.homogeneous` | Mix members share one `memberKind` |
| `generator.k6.request` | k6 request workloads |
| `generator.jmeter.request` | JMeter HTTP request samples |
| `generator.wrk.request` | wrk request-only workloads |
| `generator.wrk.journey` | Always unsupported |
| `session.start-snapshot-stop` | Continuous session base capability |
| `session.update-load` | Optional in-session load update |
| `writeSafety.managed-reference` | Managed reference write authorization |

Non-session capabilities use `supported`, `experimental`, or `unsupported`.
JMeter open arrival remains experimental until its pinned strategy is fully
qualified.

## JMeter adapter wire

`version --json` conforms to `load/jmeter-adapter-wire.schema.json`.
`generator` is `jmeter`; `adapterId` is product-owned; and `maxThreads` comes
from the local adapter manifest. Concurrency above that ceiling is rejected
before traffic. Required modes are `run-once`, `normalize`, and `version`.

Canonical properties are `perf.base_url`, `perf.threads`,
`perf.duration_seconds`, `perf.run_id`, and `perf.scenario`. A recorded legacy
adapter may accept `perflab.*`; new defaults and shipped JMX files use only
`perf.*`. Journey parents retain `journey::<id>` and children retain
`op::<name>`.

## Lifecycle, writes, data, and recovery

`lifecycle.ownership` and `writeSafety.class` are independent fields with
separate value spaces. Ownership is `none`, `managed`, or `delegated`. Write
safety is `none` or `managed-reference`. Ownership `none` never grants writes.

Only `managed-reference` authorizes reference checkout writes, after a unique
run partition is seeded, reset, and acknowledged. Snapshot/restore is not a
substitute. Write budgets and ownership-aware cleanup apply throughout the run;
incomplete cleanup cannot produce a passing gate.

Unmanaged local-process, existing-environment, and existing-Kubernetes targets
refuse deploy, start, stop, and scale operations. The workload may still run
against an already-running target.

## Profiling, diagnostics, and observability

Measurement evidence and diagnostic campaigns are separate child runs.
Pyroscope queries are scoped by run, service, and time window and never use a
static `perf_phase` selector. CPU, wall, allocation, lock, exception, and
live-heap policies record the standard capture state. Unmanaged profiler
configuration is verified through a declared read-only endpoint.

## Distributed and release behavior

Shard plans do not multiply intended load. Aggregation preserves counts and
histograms and never averages percentiles. A release repeats coordinated parity
against independently produced attestations.

## Stable baseline compatibility

Request, journey, homogeneous mix, and protocol workloads use the complete
stable `v1` comparison model. A comparison proceeds only when every dimension
required by policy is present and compatible. Missing or different workload,
generator, load, dataset, environment, configuration, profiling, fault, or
evidence dimensions are inconclusive. Lossy projections are forbidden.
