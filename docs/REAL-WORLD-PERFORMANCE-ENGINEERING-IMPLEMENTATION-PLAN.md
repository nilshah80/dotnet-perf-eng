# Real-world performance engineering implementation plan

- Status: joint implementation plan and single source of truth
- Branch in both repositories: `feature/real-world-performance-engineering`
- Applies identically to: PerfLab and `dotnet-perf-eng`

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
the plan is incomplete until the same file bytes exist in both branches and the
coordinated parity workflow accepts their exported attestations before merge.

## 2. Independence and parity contract

Both repositories must satisfy all of the following:

- A clean checkout can build, test, package, and execute without the other
  repository being present.
- No command executes the other product's CLI or helper binary.
- No adapter uses a container image built or released only by the other
  repository.
- No shell script sources files from the other repository.
- PerfLab's three shipped .NET lab descriptors resolve only the canonical lab
  assets in an explicitly configured or adjacent `dotnet-perf-eng` checkout.
  No other sample, discovery path, or generated configuration does so.
- No build downloads the other repository's schemas, fixtures, generated code,
  packages, or release assets.
- Each repository checks in and validates its own copy of the agreed schemas,
  normative semantic rules, and conformance fixtures.
- The normative contract bundle is byte-identical in both repositories and is
  locked by `contract-lock.json` as defined below.
- Each repository owns its generator adapters, images, orchestration engine,
  evidence normalization, diagnostics, reports, and release process.
- Parity is verified by matching contract behavior and normalized fixture
  results, never by calling one implementation from the other.
- `dotnet-perf-eng` exclusively owns the actual .NET source, Compose, catalog,
  mix, SLO, and generator assets for ScenarioLab, Ecommerce, and Protocol
  Reliability. PerfLab owns only thin descriptors for those labs and must not
  contain copied or independently implemented lab application source.
- The current `dotnet-perf-eng` dependency on the `perflab-load-jmeter` image
  must be removed. `dotnet-perf-eng` will own and pin its own JMeter runner
  image; PerfLab will continue to own and pin its own.
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

### 2.1 Normative contract bundle and digest

Logical names, rather than repository paths, identify bundle entries. For
example, `catalog/scenario-catalog.schema.json` maps to
`schemas/catalog/v1/scenario-catalog.schema.json` in PerfLab and
`contracts/v1/catalog/scenario-catalog.schema.json` in
`dotnet-perf-eng`.

For each revision, a byte-identical `contract-manifest.json` is the sole
authority for bundle membership. Its sorted `entries` array lists exactly one
object for every schema, normative semantics document, or conformance fixture
with `logicalName`, `kind: schema|semantics|fixture`, media type, and
`contentMode: text|binary`. The manifest does not list itself; it is included by
rule with the reserved logical name `meta/contract-manifest.json`. A file absent
from the manifest is not normative, even when stored under a contract directory.

Each repository also checks in a repository-local `contract-path-map.json` that
maps the manifest and every declared logical name to exactly one relative path.
Path maps may differ and are excluded from the normative bundle. They resolve
physical files but cannot add, remove, or rename bundle members.

The initial manifest fixes the locations of its non-schema rules. Logical entry
`semantics/contract.md` maps to `schemas/semantics/v1/contract.md` in PerfLab
and to `contracts/v1/semantics/contract.md` in `dotnet-perf-eng`. Its fixture
entry
`fixtures/request-iteration-accounting.json` maps to
`schemas/fixtures/v1/request-iteration-accounting.json` in PerfLab
and to
`contracts/v1/fixtures/request-iteration-accounting.json` in the
native repository. Every later semantic rule follows the same explicit
manifest, path-map, and conformance-fixture pattern; an unmaterialized plan
sentence cannot be treated as a released contract rule.

The bundle and lock use these rules:

1. Bundle entries are the manifest under its reserved logical name plus exactly
   the entries declared by that manifest. `contract-lock.json`,
   `contract-path-map.json`, contract history/index files, and parity metadata
   are excluded.
2. A logical name is a unique, forward-slash-separated ASCII token independent
   of checkout location. Logical names are sorted by unsigned UTF-8 byte order.
3. Each entry digest is lowercase hexadecimal SHA-256 over the exact checked-in
   file bytes. Text entries must be UTF-8 without BOM, use LF line endings, and
   end with exactly one LF. Binary fixture bytes are unchanged.
4. The aggregate preimage is the concatenation, in sorted order, of one record
   per entry: `<logicalName>`, one NUL byte, the 64-character entry digest, and
   one LF byte. The aggregate is lowercase hexadecimal SHA-256 of that byte
   sequence. Repository paths and JSON serialization never enter the preimage.
5. Generated `contract-lock.json` contains `contractRevision`, the manifest
   digest, `hashAlgorithm: "sha256"`, the sorted `logicalName` and `sha256`
   entries, and `aggregateSha256`. Its generator emits deterministic UTF-8 JSON
   without BOM, with two-space indentation, LF endings, stable field order, and
   one final LF.
6. Both repositories pin Markdown, JSON, JTL, JMX, and every other declared
   text-fixture extension to LF and declare diagnostic/archive fixtures binary
   in `.gitattributes`. CI rejects BOMs, CRLF, a text/binary attribute mismatch,
   an unclean regenerated lock, an unmapped, extra, or duplicate logical name,
   and a manifest/lock disagreement.

The lock generator must recompute bytes from the index or a clean checkout; it
must not normalize content while hashing. The same revision with a different
aggregate digest is a contract violation, not a compatible variant.

Each repository checks in the same generated `parity-lock.json`, containing the
expected plan SHA-256, active contract revision, manifest SHA-256, and aggregate
SHA-256 plus the contract-index SHA-256 and both product compatibility-inventory
SHA-256 values. Local CI validates its plan/contract bytes and its own inventory
field, then emits a signed or content-addressed
`parity-attestation.json`; it never fetches the peer checkout.
The coordinated parity workflow is the sole authority for cross-repository
equality. It compares the two exported attestations from independently built
checkouts. This workflow may obtain both repositories, but neither repository's
normal build, test, package, or execution path may do so.

### 2.2 Contract revision lifecycle

The stable joint contract identifier is `v1`, and versioned documents use
`perflab.io/v1`. There is no alpha alias and no feature-codename identifier in
the public contract, implementation package names, or repository paths.
Before the coordinated v1 release, the two repositories may refine normative
bytes only through byte-identical paired changes and regenerated locks. Once
v1 is released, its manifest, logical members, semantics, fixtures, and digest
are immutable. A later normative change requires a new stable revision such as
`v2`; a released revision is never reused, rewritten, or given another digest.
Editorial plan changes alone do not create a contract revision.

Behavior-changing prose in this plan is not a released runtime rule by itself.
Before that behavior can be marked supported, it must be encoded in a
manifest-listed schema or `semantics/*.md` entry with conformance fixtures.
Therefore a post-release semantic change always changes normative bytes and
creates the next stable revision. A change that touches no normative bytes
makes no contract-behavior change and retains the current revision.

Slices 0-10 together define the initial v1 release. The coordinated release
freezes every v1 normative byte in the manifest, including catalog, workload,
journey, profile, session, target, data/fault, diagnostics, distributed-load,
protocol, projection, capability, wire, semantic, and fixture entries. A slice
is not a separately released revision and cannot claim stable support until its
runtime behavior and shared conformance cases pass in both products.

A runner accepts
only revisions and exact digests listed in its generated `contract-index.json`.
A higher, lower-but-retired, malformed, or otherwise unknown revision fails
closed during contract resolution, before target lease, data or fault mutation,
deployment, or traffic. A newer runner may accept an older revision only
through a named, tested compatibility adapter; it records both the input and
effective revision and never silently upgrades persisted evidence.

At release, the manifest and lock are copied byte-for-byte into
`contract-history/<revision>/` and never changed. The byte-identical
`contract-index.json` records every still-supported revision, aggregate digest,
and adapter requirement. A runner cannot advertise an older revision unless it
retains that immutable snapshot or has an explicit adapter tested against its
original conformance corpus.

Full-parity status requires both implementations to carry the same bundle
digest and pass the same byte-identical conformance corpus for the claimed
revision while installed and executed independently. A parity workflow may
compare exported results from two isolated builds, but normal build, test,
package, and execution must never fetch or invoke the other repository.

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
- The orchestration products never execute or build each other. PerfLab may
  consume the canonical project-owned lab assets above when one of those labs
  is explicitly selected; this is target ownership, not an engine dependency.

## 5. Current state and material gaps

### 5.1 PerfLab gaps

| Area | Current state | Required state |
| --- | --- | --- |
| Shipped labs | Duplicate PerfLab targets can measure different operations | Thin descriptors resolve the three canonical `dotnet-perf-eng` labs |
| Discovery | Canonical lab root resolution is implicit and incomplete | Explicit `DOTNET_PERF_ENG_ROOT` with adjacent-checkout development fallback |
| Smoke/parity | Synthetic fixtures can hide target drift | Compile every descriptor against the canonical catalogs and workload assets |
| Lab scenario | `internal/lab/types.go` stores one method, path, and body | Versioned request, journey, and mix selector |
| Catalog | `internal/lab/discover.go` accepts an eight-column TSV | Keep TSV; add Scenario Catalog v1 JSON |
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
| Native evidence | Request observations and package facts | Same v1 journey/operation/delivery/correctness semantics |
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
  journeys. v1 mixes are homogeneous: every member is a request or every
  member is a journey; heterogeneous composition is unsupported.
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

## 7. Scenario Catalog v1

Add the byte-identical `scenario-catalog.schema.json` to PerfLab under
`schemas/catalog/v1/` and to `dotnet-perf-eng` under
`contracts/v1/catalog/`. JSON is the first normative format so both
independent implementations can validate it without a new YAML runtime
dependency. YAML can be added later as a lossless frontend.

Representative structure:

```json
{
  "apiVersion": "perflab.io/v1",
  "kind": "ScenarioCatalog",
  "contractRevision": "v1",
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

This `v1` example establishes catalog grammar. A runner may validate the
journey descriptor at that revision, but it cannot execute or advertise journey
support until it also implements the `v1` journey evidence contract.

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
internally into a v1 request workload with:

- One stable operation derived from the scenario ID.
- Exactly one primary protocol request attempted per measured iteration.
- Separate accounting for initialization, cancellation, redirects, retries,
  and generator failures.
- Failed HTTP and transport attempts included in request-attempt totals.
- `rateUnit == requests/s` for open execution.
- Existing method/path/body/connections/diagnostic behavior.
- Existing remote-write acknowledgement behavior.

The migration command writes an equivalent JSON catalog without changing
runtime behavior:

```text
perflab lab migrate-catalog --lab <id> --output scenario-catalog.json
```

TSV deprecation cannot begin until two stable releases after v1 reaches
feature parity.

## 8. Workload Manifest v1

Add the byte-identical `workload-manifest.schema.json` at
`schemas/load/v1/workload-manifest.schema.json` in PerfLab and
`contracts/v1/load/workload-manifest.schema.json` in
`dotnet-perf-eng`. It records generator capabilities without duplicating the
generator's step implementation.

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

A selector with `type: mix` additionally declares `memberKind` as exactly
`request` or `journey` and an ordered `members` array. Every member contains an
existing selector ID and a finite positive weight. All resolved member selectors
must match `memberKind`; nested mixes and mixed request/journey membership are
invalid in v1. Validation normalizes weights with a specified decimal
algorithm, rejects a zero or non-finite total, and includes the ordered member
IDs, source weights, normalized weights, and seed policy in the workload hash.

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
| journey mix | `selections/s`, `journeys/s`, `iterations/s` | `concurrent-users` |
| protocol | Adapter-declared | Adapter-declared |

HTTP RPS for a journey is a measured result, never the offered journey rate.

### 9.2 Evidence v1

Add a byte-identical load-result schema to each contract bundle. The complete
stable `v1` document is the comparison input for request, journey, mix, and
protocol workloads.

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

Evidence v1 retains the existing closed capture-state vocabulary:
`captured`, `missing`, `unsupported`, `failed`, `truncated`, `redacted`,
`delayed`, and `not-applicable`. It adds orthogonal query facts such as endpoint
reachability, query success, result count, ingestion wait, and whether an empty
result is policy-valid. New prose or adapters must not invent synonymous states.

## 10. Generator contracts

### 10.1 k6

Add a project-importable helper and a v1 summary contract. The helper
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
- The adapter parses custom metrics and submetrics into Evidence v1.

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
nevertheless pass the same byte-identical JTL fixtures and produce
contract-equivalent results. Slice 0 removes every native runtime, error,
comment, lab configuration, packaging, and documentation reference that tells
users to obtain a PerfLab-owned JMeter artifact. The compatibility environment
name `PERFLAB_JMETER_IMAGE` remains accepted in `dotnet-perf-eng`, but its value
selects only the native repository's independently built image.

The cross-product semantic identity is `generator: jmeter`; adapter identity is
product-owned. PerfLab retains `perflab.load.jmeter`, while
`dotnet-perf-eng` uses `dotnet-perf-eng.load.jmeter` and its independently
versioned manifest. Compatibility names such as `PERFLAB_PLUGIN_ID` and
`PERFLAB_PLUGIN_VERSION` may remain in the native environment surface, but
their values must describe the native adapter. The native evidence collector
reads identity/version from its repository-owned manifest or image `version`
output and never hard-codes PerfLab's ID or version. Normalized evidence records
both the common generator identity and product-specific adapter identity.

The canonical v1 JMeter property names are `perf.base_url`,
`perf.threads`, `perf.duration_seconds`, `perf.run_id`, and `perf.scenario`.
Both products emit that map in the compiled workload manifest and use it in new
JMX fixtures. New defaults, shipped JMX files, and generated configuration use
only `perf.*`.

A recorded v1 compatibility adapter accepts legacy `perflab.*` property keys on
existing native or PerfLab JMX files. It maps each legacy key to the canonical
`perf.*` name, records that a v1 key was used, and never presents `perflab.*` as
a product default. `dotnet-perf-eng` may retain the `PERFLAB_JMETER_PROP_*`
environment variable names for automation compatibility, but their default
values are the canonical `perf.*` keys. An explicit user override for an
external JMX file is recorded as user configuration, never as the native
default.

The common adapter wire contract is schema-backed. `version --json` returns the
common generator, product-owned adapter ID and version, image digest, CPU and
memory limits, positive `maxThreads`, supported modes, composite fingerprint,
capability revision, and contract digest. The host verifies those values against
its local manifest.
Requested concurrency must not exceed the advertised `maxThreads`; no shared
contract hard-codes the current value `256`. `run-once` validates a bounded
workload root, plan and support files, property map, phase, output directory, and
timeout, then emits schema-valid observations and a summary containing script
hash, delivery, result, and adapter provenance. `normalize` accepts only the
declared JTL/result inputs and produces the same normalized fixture result in
both products. Exit codes, required output files, cancellation, and malformed
version/run responses are covered by byte-identical conformance fixtures. Each
repository implements this CLI and image independently.
The `v1` manifest includes the request-only base wire entries
`load/jmeter-adapter-wire.schema.json`,
the JMeter section in `semantics/contract.md`, and one explicitly enumerated
logical entry
under `fixtures/jmeter-adapter-wire/` for every positive or negative case;
repository path maps resolve their exact physical files. `v1` adds the
journey parent/child, scheduling, and result cases without rewriting the base
contract.

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
- Streaming snapshot and histogram support.
- Distributed/shard support.
- Cancellation and graceful-stop behavior.
- Supported checks and result contract versions.
- Base continuous-session lifecycle support for `Start`, `Snapshot`, and `Stop`.
- Optional within-session `UpdateLoad` support as a separate capability.

The compiler validates capabilities before readiness, data mutation, or load.

The non-session capability fields are introduced by `v1`. The
`continuous-session` and `session-load-update` fields and their operation
semantics are introduced together by `v1`; they are not Slice 3 claims.
Before `v1`, an adapter advertises neither field. At `v1`, every adapter
reports an explicit support state for both. Claiming `continuous-session`
requires `Start`, `Snapshot`, and `Stop`; claiming `session-load-update`
additionally requires `UpdateLoad`. The latter is never implied by the former.
The earlier streaming-output capability describes incremental adapter results;
it is not the `LoadSession.Snapshot` operation.

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

Every adapter continues to implement the existing one-shot `Probe` contract.
An adapter that advertises `continuous-session` additionally implements:

- `Start` launches one compiled load execution and returns a durable session
  identity and initial snapshot cursor.
- `Snapshot` reads cumulative counters and mergeable histogram deltas for a
  bounded window without starting or stopping load.
- `UpdateLoad` is optional and is capability-negotiated before profiles that
  change load inside one session.
- `Stop` requests graceful termination, returns the final cursor, and records
  forced cancellation separately.

`Probe` remains an independent required path for smoke, steady, load, and other
one-shot profiles; it does not depend on session primitives. Soak never uses
repeated `Probe` calls and is rejected before traffic unless the selected
adapter implements the base `Start`/`Snapshot`/`Stop` session contract. Runtime
interfaces and orchestration bridges negotiate this optional capability
explicitly. Thus wrk can retain its supported one-shot request profiles while
rejecting soak and continuous-session profiles.

After that API contract is satisfied, a real soak must:

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

`lifecycle.ownership` and `writeSafety.class` are distinct fields. They must not
share an enum, flag, or serialized value space. `lifecycle.ownership` records
who may start, stop, scale, or delete the target (`none`, `managed`, or
`delegated` as defined by the target-kind table). `writeSafety.class` records
whether a mutating workload is allowed. The Slice 1 compatibility model uses
`writeSafety.class` values `none` and `managed-reference`.

`lifecycle.ownership: none` is the default for configured existing targets and
does not imply a write-safety class. Neither orchestrator may deploy, scale,
restart, stop, reset, fault, or delete target resources without a declared
capability and the required acknowledgement.

Slices 1 and 2 define one deliberately narrow bootstrap to that rule so the
reference write journey does not depend on Slices 6 or 7. Only
`writeSafety.class: managed-reference` can authorize the Slice 2 write journey.
The `v1`
reference-write contract then requires
`capabilities: [run-partition-seed, run-partition-reset]`, an explicit write
acknowledgement, a positive write budget, a cleanup deadline, and a unique run
partition. It applies only to the repository-owned Compose reference target.
The provider may create, seed, reconcile, and delete only that run partition;
it cannot mutate a shared or external target. Preflight verifies the target is
owned, the partition is new, the budget is bounded, and cleanup is idempotent.
Slices 6 and 7 generalize this bootstrap into target snapshots, leases,
providers, arbitrary datasets, and ownership-aware mutation. They do not supply
any prerequisite needed by the Slice 2 reference journey.

Preflight still validates:

- Target and readiness reachability.
- TLS and clock requirements.
- Authentication and secret references.
- Named base URLs and generator routing.
- Metrics, logs, traces, profiles, and diagnostic endpoints.
- Per-service effective CPU quota and continuous-profiler resource gates.
- Dataset, reset, fault, scaling, and runtime-diagnostic capabilities.
- Write/destructive policy and budget.
- Exclusive lease requirements.

Local-machine and generator-host fingerprints include CPU model/count, memory,
OS/kernel, architecture, power/battery state where available, thermal/throttling
signals, container/VM resource allocation, generator placement, network path,
and material background-load checks. Required fingerprint fields and acceptable
drift belong to the environment policy. Shared environments support leases or
explicit noisy-environment classification rather than pretending isolation.

### 12.1 Canonical project-owned .NET lab targets

`dotnet-perf-eng` is the sole source of truth for all actual .NET lab code:

- `source/dotnet/scenariolab` provides `PerfLab.Api` and `PerfLab.Worker`.
- `source/dotnet/ecommerce` provides `ECommerce.Api`.
- `source/dotnet/protocol-reliability` provides `ProtocolReliability.Api` for
  the two application instances used by that lab.

Their matching folders under `dotnet-perf-eng/labs` own Compose, catalogs,
workload manifests, generator scripts, mixes, SLOs, and deterministic data.
PerfLab contains no copy or independent implementation of these applications.
Its thin descriptors resolve the canonical checkout through
`DOTNET_PERF_ENG_ROOT`, with adjacent-checkout discovery only as a local
development convenience. The canonical source and catalogs define these route
groups:

- `GET /health/ready`.
- `POST /api/auth/login`; `GET|POST /api/products`;
  `GET|PATCH /api/products/{id}`.
- `GET|POST /api/orders`; `GET /api/orders/{id}`; `GET /api/users`;
  `GET /api/users/me`.
- `GET /api/catalog/recommendations`; `GET /api/runtime/threading`;
  `GET /api/runtime/memory`; `GET /api/customers/{id}/orders`.
- `GET /api/cache/catalog/{id}`; `GET /api/pools/{provider}`;
  `GET /api/inventory/deadlock`.
- `POST /api/orders/{id}/payment` plus the run-scoped seed, reset, and
  correctness routes described below.

The six-operation `checkout` journey is fixed and independently testable:

1. `login` posts fixed fixture credentials and extracts a bearer token.
2. `browse` lists products and extracts a product ID.
3. `create` posts an order with a unique run-scoped client order ID and extracts
   the order ID.
4. `pay` posts to `/api/orders/{id}/payment` with a run-scoped idempotency key.
5. `poll` reads `/api/orders/{id}` with bounded attempts until the worker records
   `completed` or a terminal failure.
6. `verify` reads `/api/perf/runs/{runId}/orders/{id}` and checks the persisted
   order, payment, item total, idempotency result, and exactly one worker outcome.

`POST /api/perf/runs/{runId}/seed` creates only the authenticated run partition.
`POST /api/perf/runs/{runId}/reset` reconciles and deletes only that partition;
both reject an absent or mismatched run ID. The worker consumes repository-owned
RabbitMQ order events and writes the terminal outcome. Dataset fixture IDs,
credentials, expected counts, state transitions, retry behavior, and cleanup
postconditions are exact golden integration-test inputs rather than references
to another repository.

The PerfLab descriptors use the canonical checkout as `workloadRoot` and bind
its exact scenario, mix, SLO, load, Compose, source, diagnostic-target, and
telemetry-service identities. Preflight resolves each requested role to one
live process and one telemetry service before traffic. Both products therefore
execute the same operation against the same build and differ only in their
orchestration and evidence implementations.

`samples/labs/remote-example/` owns only its generator assets, catalog, and SLO
policy. It has no implicit application or diagnostic process. The user supplies
target URLs and any exact remote service/process mappings; remote diagnostics
remain disabled when those capabilities are absent.

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

Slice 2 supplies a minimal deterministic provider for its reference checkout
journey using the `v1` managed-reference bootstrap in Section 12. The
provider uses a unique per-run database/schema partition with bounded seed,
reset, reconciliation, and cleanup. The journey may execute `create` and `pay`
only after ownership, acknowledgement, budget, and partition readiness pass.
Slice 7 expands that working provider into the general provider, partition,
fault, and scale framework; it does not deliver a Slice 2 prerequisite.

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
acknowledgement or its v1 equivalent.

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

Profiles do not have a static phase label. Profile queries isolate samples by
the exact `perf_run_id`, exact `service_name`, and exact capture window. Phase
attribution is derived from intersection with persisted phase windows; it is
never inferred from a profile label that the profiler does not emit.
The shipped `samples/observability/grafana-experiment.json` query must therefore
remove `perf_phase` and pass the persisted start/end window to Pyroscope.

### 14.2 LGTM telemetry evidence

The v1 implementation scope is Grafana, Prometheus, Loki, Tempo, and Pyroscope.
Other APM vendors are outside this release and must not add agents, exporters,
configuration, capture logic, or compatibility claims.

For each phase and service, capture:

- Request and dependency rate, errors, and latency.
- Database, cache, messaging, and external-service spans.
- Exemplars for slow and failed operations.
- Trace summaries and critical-path attribution.
- Bounded raw trace details under limits.
- Error logs and structured run/journey/operation correlation.
- Runtime, process, container, and dependency metrics.
- Sampling policy and evidence completeness.
- Required/optional policy, existing `CaptureState`, and query facts for every
  configured source and signal.
- Query window, ingestion delay, clock skew, retry, truncation, and result limits.
- Service-instance churn so restarted processes, pods, and replicas remain
  attributable to the correct phase without folding stale series into results.

Reachability and content are separate facts. Every query records endpoint
reachability, query success, result count, truncation, and the resulting state.
The following empty-result behavior is normative:

| Signal | Reachable, successful, but empty | Required-gate result |
| --- | --- | --- |
| Metrics | `missing` for an active measurement window | Inconclusive |
| Traces | `delayed` while awaiting ingestion, then `missing` | Inconclusive |
| Logs | `captured` with `resultCount: 0` and `emptyAllowed: true` | Complete unless a named log assertion was required |
| Continuous profiles | `delayed` while awaiting ingestion, then `missing` per requested type/service/window | Inconclusive |
| Diagnostic artifact | `missing` when a required child campaign produced no artifact | Inconclusive or failed campaign |

An endpoint or query error is `failed`; an unavailable capability is
`unsupported`; an expected but absent result is `missing`. A bounded result cut
short by a limit is `truncated`, policy transformation is `redacted`, ingestion
still inside its wait budget is `delayed`, and a source disabled by policy is
`not-applicable`. Optional non-captured evidence does not by itself fail the
overall gate, but it remains visible and cannot satisfy a rule that requires
that signal. Required evidence passes only in `captured`, or in `redacted` when
the evidence policy explicitly allows that representation. A named log-event
requirement overrides the default best-effort empty-log rule.

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

Profiling preflight evaluates each service's effective host, container, cgroup,
or job CPU quota, not only the host core count. Each versioned profiler
capability descriptor declares a positive `minimumEffectiveCpuCores`, its
authoritative source, supported override range, whether an override is allowed,
and a read-only activation probe. There is no universal hard-coded threshold.
The source is a pinned provider/image manifest or provider documentation captured
by that manifest; changing it changes the capability identity.

`effectiveCpuCores` is the minimum positive finite constraint reported by
process affinity, cpuset, cgroup quota divided by period, container CPU limit,
Kubernetes CPU limit, or operating-system job limit. Host-available logical CPUs
are used only when no narrower constraint exists. Fractional quotas are retained
without rounding, every candidate limit and its read error are recorded, and an
unknown required constraint makes preflight unverifiable rather than optimistic.

For a managed target, the orchestrator reads the effective quota from the
container/cgroup/job limit it created. It may set
`DD_PROFILING_MIN_CORES_THRESHOLD` before process start only when the selected
profiler descriptor allows it and the value is finite, positive, within the
declared provider range, and no greater than the effective CPU quota. Readiness
then proves the profiler is active for every requested type. A failed activation
probe makes the type `failed`, not captured.

For an unmanaged target, the target descriptor must name a read-only agent or
provider health/configuration endpoint that reports effective quota, active
profiler version, active types, and threshold. A signed operator-supplied
capability snapshot may replace that endpoint only when policy permits
attestation and its freshness window has not expired. The orchestrator never
infers process environment or rewrites it. If neither discovery path verifies
the effective configuration, the capability is `unsupported`; a required type
fails preflight and an optional type remains recorded as unsupported. The quota,
threshold, descriptor/attestation digest, source, freshness, probe result, and
decision are evidence.

The label validator reserves `service_name` for the profiler integration and
rejects a `PYROSCOPE_LABELS` entry that declares it again. It also rejects
duplicate or unbounded labels before traffic. Push/query health is checked
separately from sample count so an HTTP 400 or stub/empty flamebearer is a
`failed`, `delayed`, or `missing` capture according to the observed query facts,
never a successful empty profile.

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
than passing when required evidence is `missing`, `unsupported`, `failed`,
`truncated`, still `delayed` after its deadline, incompatible, or generator
saturated. Disallowed `redacted` evidence is also inconclusive.
Correctness-invalid evidence fails. These are capture states and completeness
facts;
`partial` is a run outcome, not a ninth `CaptureState` synonym.

The policy declares minimum completed repetitions, outlier handling, practical
effect-size thresholds, confidence level, and multiple-metric decision rules.
Warmup/stabilization observations never enter the measurement distribution.
Baseline approval records dirty-tree state, build identity, environment noise,
and operator justification. A baseline is immutable; replacement creates an
auditable new approval instead of rewriting history.

### 16.1 Stable baseline compatibility

Every baseline and candidate uses the complete stable `v1` evidence model.
Request, journey, homogeneous mix, and protocol workloads are comparable when
their workload identity, generator, load model, target, dataset, environment,
configuration, content, overhead policy, phase duration, and evidence
completeness satisfy the declared compatibility policy. Missing or different
required dimensions make the comparison inconclusive. No lossy projection,
implicit default, or operator assumption may manufacture comparability.

## 17. CLI and compatibility surface

Add common controls:

```text
--workload <selector>
--profile-config <path>
--rate <number>
--rate-unit <requests/s|journeys/s|selections/s|iterations/s>
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

| Existing input | v1 mapping |
| --- | --- |
| `--connections` | Closed concurrency |
| `--start-rps`, `--target-rps` | `requests/s` for requests; preserved as `selections/s` aliases for request mixes; rejected for journey-bearing workloads |
| `--max-vus`, `--spike-vus` | Profile limits/stages |
| `--soak-duration` | Soak measurement duration |
| `--rates` | Explicit staged rate list |
| `--mix` | Workload selector of type mix |
| `--seed-scale`, `--scale`, `--scales` | Dataset selection/scale |
| `--repeats`, `--reseed` | Repetition and reset policy |
| Fault flags | Fault policy overrides |
| `--target` with `local` or `remote` | Compatibility target resolver |

All CLI overrides are normalized into the execution manifest. Environment
variables remain supported for automation, but secret values must use secret
providers/handles rather than plain manifest fields.

The aliases `--start-rps` and `--target-rps` retain their current request-mix
automation behavior. For a legacy or v1 request mix, the compatibility
adapter accepts them and records the effective unit as `selections/s`, because
one selection currently executes one primary request. It also records that an
RPS-named compatibility alias was used. New automation should use `--rate` with
`--rate-unit selections/s`. A journey or journey mix rejects the aliases before
traffic. A journey points to `journeys/s`; a journey mix may use `selections/s`
or `journeys/s`. `iterations/s` remains the explicit contract-level alias. No
working request-mix input is removed or silently repurposed.

Slice 0 creates the machine-readable inventory source that does not exist
today. PerfLab replaces the hand-written top-level switch and ten ad hoc
`flag.FlagSet` construction sites with one declarative command-spec graph whose
parser factories, positional rules, flags, aliases, environment inputs, and
help/inventory output share the same descriptors. The native repository adds
the equivalent checked-in input descriptors and makes each shell parser's
conformance test prove that its accepted inputs match them.

Each product generates only its repository-local compatibility manifest from
those descriptors. Local CI validates runtime registration, its manifest, and
golden parse/manifest tests; it neither renders the other product's subsection
nor rewrites this joint document. The coordinated documentation job consumes
both exported inventories, renders the complete Section 17 once, and applies
the identical result to both repositories. `parity-lock.json` pins both
inventory digests and the resulting plan digest. Until that generator lands,
the tables remain a jointly reviewed snapshot and every literal control below
must be checked manually against source.

For v1, the release-only coordinator is owned by PerfLab at
`.github/workflows/coordinate-performance-contract.yml` with its implementation
under
`scripts/contract/coordinate-release/`. It consumes immutable inventory and
attestation artifacts exported by the two isolated repository jobs. It renders
Section 17 once, recalculates the plan digest, regenerates the complete
`parity-lock.json`, and emits one content-addressed patch applied to paired pull
requests. The contract release owner recorded in those pull requests verifies
that both patches are byte-identical before merge. This workflow may access both
artifacts and repositories; no normal build, test, package, or runtime path may
invoke it. Moving coordination ownership requires a normative
contract-governance change only when bundle bytes change; otherwise it requires
byte-identical plan and `parity-lock.json` updates in the paired pull requests.

### 17.1 Existing PerfLab interface that must remain compatible

| Path | Existing controls to preserve |
| --- | --- |
| `version` | Version output and exit behavior |
| `init` | `--root` |
| `doctor` | `--root`, `--require-docker`, `--min-docker-cpus`, `--min-docker-memory`, `--min-free-disk`, `--target`, `--require-profiler-access`, `--require-clock-sync`, repeatable `--port`, repeatable `--plugin` |
| `systems` | `list`, `validate`, `inspect`; existing `--root` behavior |
| `plans` | `list`, `validate`, `render`; existing `--root` behavior |
| `plugins` | `list`, `install`, `upgrade`, `remove`, `inspect`, `doctor`; existing `--root` behavior |
| `run` | Experiment path and `--root` |
| `suite run` | Suite path, `--root`, `--output`, `--continue-on-error` |
| `lab run`, `lab suite` | Scenario selectors and the common lab flags listed below |
| `pe` | `repeat`, `sweep`/`knee`, `mix`, `data-scale`, `fault`, `history`/`trend` and their flags below |
| `runtime capture` | Recorded-run target plus runtime campaign flags below |
| `gate` | Run path/ID, `--root`, `--require-steady`, `--allow-partial`, `--allow-missing`, `--slos`, `--baseline-json`, `--threshold`, `--baseline`, `--policy`, `--workload`, `--dataset`, `--environment-envelope`, `--overhead-policy`, `--phase-duration` |
| `analyze` | Optional `steady-state`, `bottleneck`, `efficiency`, `leak`, `capacity`, `diff-profile`, or `diff-gcdump`; run path/ID; `--root`, `--prompt`, `--scope`, `--lab`, `--scenario`, `--suite-baseline`, `--baseline`, `--response`, `--provider`, `--provider-name`, `--provider-version`, `--provider-model`, `--source-root`, `--p99-ms` |
| `compare` | Baseline/candidate positionals, `--root`, `--policy`, and every comparison-context flag listed below |
| `runs` | `list`, `show`, `cancel`, `resume`, `export`; `--root`, `--limit`, `--status`, `--output`, `--normalized-only` |
| `report` | Run/comparison ID and `--root` |
| `baseline` | `set`, `list`, `remove`; `--root`, `--project`, `--environment`, `--system`, `--plan`, `--approved` |
| `parity` | `--native-facts`, `--perflab-run`, `--perflab-diagnostic-run`, `--contract`; aggregate mode with `--contract` |
| `clean` | `--root`, `--retention` |
| `perflab-agent version`, `perflab-agent serve` | `--root`, loopback-only `--listen`; future remote-agent exposure requires a new authenticated transport rather than widening this listener |

Current comparison-context controls retained: `gate` accepts the five
unprefixed context flags; `compare` accepts those plus the baseline/candidate
overrides. `--root` and `--policy` remain on both commands.

```text
--root --policy
--workload --dataset --environment-envelope --overhead-policy --phase-duration
--baseline-workload --baseline-dataset --baseline-environment-envelope
--baseline-overhead-policy --baseline-phase-duration
--candidate-workload --candidate-dataset --candidate-environment-envelope
--candidate-overhead-policy --candidate-phase-duration
```

Current common lab controls retained during migration:

```text
--root --output --lab --lab-config --duration --profile --generator
--base-url --ready-url --prometheus-url --tempo-url --loki-url
--grafana-url --pyroscope-url --diagnostics-url --prom-job-regex
--service-name-regex --log-limit --trace-limit --headers --seed-scale
--target --mix --ack --write-ack --connections --max-vus --spike-vus
--start-rps --target-rps --k6-prom-rw --no-runtime --measure-only
--retain-native-trace --no-retain-native-trace --remote-telemetry
--continuous-profiling --profiling-policy --remote-diagnostics --allow-unhealthy
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

`--lab-config` remains rejected for recorded replay until the v1 replay
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
| `capture-runtime.sh` | Isolated `trace`, `gcdump`, `stacks`, or `dump`; ordered `--preset`, duration, `--include-dump`, and existing safety environment |

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
- Native adapter identity assertions: `PERFLAB_PLUGIN_ID`,
  `PERFLAB_PLUGIN_VERSION`, `PERFLAB_PLUGIN_IMAGE_DIGEST`,
  `PERFLAB_PLUGIN_CPUS`, and `PERFLAB_PLUGIN_MEMORY_BYTES`. The native manifest
  supplies and validates their values; callers cannot use them to impersonate a
  PerfLab adapter.
- JMeter compatibility: `PERFLAB_JMETER_IMAGE`, `PERFLAB_JMETER_PLAN`,
  `PERFLAB_JMETER_FILES`, `PERFLAB_JMETER_PROP_BASE_URL`,
  `PERFLAB_JMETER_PROP_THREADS`, `PERFLAB_JMETER_PROP_DURATION_SECONDS`,
  `PERFLAB_JMETER_PROP_RUN_ID`, and `PERFLAB_JMETER_PROP_SCENARIO`. Property
  variables default to the canonical `perf.*` names defined in Section 10.2;
  explicit overrides are recorded.
- Workload correlation: `PERF_SCENARIO`, `PERF_RUN_ID`, `PERF_RUN_MODE`,
  `PERF_METHOD`, `PERF_PATH`, `PERF_BODY`, `PERF_BASE_URL`, `PERF_HEADERS`,
  `PERF_MIX`.
- Telemetry: Prometheus, Tempo, Loki, Grafana, Pyroscope, diagnostics URLs;
  job/service filters, run attribute, metric roles/prefix, query limits, and k6
  remote-write settings.
- Profiling/diagnostics: continuous-profiling, profiling policy and resolved
  types, keep-tiering, Pyroscope service mappings, diagnostic target mappings,
  preset, recovery, stacks enablement, artifact budget, include-dump, trace
  retention, and dump acknowledgement.
- Safety/remote: remote telemetry, diagnostics, unhealthy-target override,
  diagnostic/write acknowledgements, write budget, and capture-incomplete state.
- Data/dependencies/faults: seed scale, dataset identity, Postgres/Redis/RabbitMQ
  settings, dependency hooks, sweep/repeat/mix/data-scale settings, and fault
  target/kind/timing.
- Artifacts/suite/analysis: artifact roots/run IDs, suite identity/index/count,
  trend/bottleneck/steady-state controls, and leak threshold.

Exact current flag and environment behavior receives golden compatibility tests
before refactoring. Variables may later gain clearer aliases, but no existing
automation input is removed or repurposed during v1 delivery.

## 18. Repository implementation maps

### 18.1 PerfLab new packages and schemas

- `parity-lock.json`: expected plan, active manifest, revision, and aggregate
  digests shared byte-for-byte with `dotnet-perf-eng`.
- `schemas/contract-manifest.json`: authoritative logical bundle membership.
- `schemas/contract-lock.json`: byte-identical logical-name lock and aggregate
  digest.
- `schemas/contract-path-map.json`: PerfLab logical-name-to-path resolution;
  excluded from the normative digest.
- `schemas/semantics/v1/contract.md` and `schemas/fixtures/v1`: physical homes
  for manifest-listed semantic rules and byte-identical fixtures.
- `.github/workflows/coordinate-performance-contract.yml` and
  `scripts/contract/coordinate-release`: release-only coordination described in
  Section 17; neither is part of normal product execution.
- `schemas/contract-index.json` and `schemas/contract-history`: supported
  revision registry and immutable released manifest/lock snapshots.
- `schemas/catalog/v1`: scenario catalog.
- `schemas/load/v1`: workload manifest and generator capability.
- `schemas/profile/v1`: composable profile definition.
- `schemas/evidence/v1`: execution manifest and load result.
- `internal/catalog`: load, migrate, validate, and hash catalogs.
- `internal/workload`: selector resolution and workload identity.
- `internal/capability`: compile-time capability negotiation.
- `internal/target`: endpoint, lifecycle, ownership, and lease resolution.
- `internal/session`: continuous load session and rolling snapshot abstraction.
- `samples/labs/{scenariolab,ecommerce,protocol-reliability}`: thin descriptors
  for the canonical project-owned labs defined in Section 12.1.

### 18.2 PerfLab existing code to change

- `internal/lab/types.go`: replace endpoint-only scenario dependency with the
  versioned scenario/workload reference while preserving the legacy view.
- `internal/lab/discover.go`: load JSON catalog first, adapt TSV when used, and
  resolve the canonical lab root explicitly and deterministically.
- `internal/lab/compile.go`: compile request/journey/mix, target ownership,
  capabilities, profiling policy, and v1 evidence expectations.
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
- `internal/orchestrator/run.go` and its runtime bridges: implement the persisted
  state machine, continuous-session lifecycle, target ownership, and child
  campaigns.
- `internal/profiles/controller.go`, `internal/profiles/soak.go`, and the
  profile runtime abstractions: retain required `Runtime.Probe`, add optional
  `SessionRuntime`/`LoadSession`, and use correct open/closed units.
- `plugins/load/k6`, `plugins/load/jmeter`, and `plugins/load/wrk`: retain the
  one-shot probe path; advertise the base start/snapshot/stop session capability
  and optional load-update capability separately; implement or reject each as
  advertised.
- `plugins/load/k6`: parse v1 custom metrics and capabilities.
- `plugins/load/jmeter`: add journey-v2 parent/child parsing and additional
  profile capabilities.
- `plugins/load/wrk`: advertise and enforce request-only capability.
- `plugins/apm/grafana`: operation-aware queries and all requested Pyroscope
  profile types.
- `internal/comparison`, `internal/peanalyze`, `internal/reporting`: v1
  compatibility, statistics, and reports.
- `internal/cli`: catalog, profile, target, diagnostic, and migration commands.
- `api/control` and `sdk`: expose new models without breaking v1 clients.
- `internal/parity`, `test/conformance`, and `test/acceptance`: independent
  contract and end-to-end coverage.
- `samples/labs/ecommerce`, `samples/labs/scenariolab`, and
  `samples/labs/protocol-reliability`: retain descriptor files only. Resolve
  every actual source, Compose, scenario, catalog, mix, SLO, and load asset from
  its canonical `dotnet-perf-eng` lab. The ecommerce lab includes the
  six-operation stateful journey and deterministic run-partition provider.
- `samples/labs/remote-example`: retain `deploymentMode: external` and add only
  repository-owned generator assets, catalog, and SLO policy. Do not add a
  Compose file, mixes file, application, or implicit diagnostic target; URLs and
  optional service/process mappings remain user inputs.
- `scripts/smoke-local.sh`, `scripts/smoke-local.ps1`, runnable samples under
  `samples/k6`, `samples/dependencies`, `samples/observability`, and
  `samples/runtime`, plus active README/docs guidance: use explicit external
  project paths. The three canonical .NET lab descriptors are the only allowed
  adjacent-checkout fallback.
- `samples/observability/grafana-experiment.json`: remove the static
  `perf_phase` Pyroscope selector and use the exact run, service, and persisted
  capture window.
- `scripts/verify-dotnet-perf-eng-parity.ps1` and sibling-skipping/cross-reading
  tests: replace direct peer execution with a local attestation exporter and
  checked-in normalized fixtures. The coordinated workflow runs each product in
  an isolated job and gives only exported attestations/results to its comparison
  job. Archived historical documents may retain clearly marked references but
  are excluded from runnable guidance and independence scanning.
- `samples/dotnet-perf-eng/*.json` and their `internal/parity` consumers: move
  reusable static policies into a product-neutral, manifest-listed conformance
  fixture path. Remove the product name and any sibling lookup; tests read only
  checked-in bytes and the coordinated workflow supplies live exported results.

### 18.3 `dotnet-perf-eng` new contracts and core modules

- `parity-lock.json`: expected plan, active manifest, revision, and aggregate
  digests shared byte-for-byte with PerfLab.
- `contracts/contract-manifest.json`: authoritative logical bundle membership.
- `contracts/contract-lock.json`: byte-identical logical-name lock and
  aggregate digest.
- `contracts/contract-path-map.json`: native logical-name-to-path resolution;
  excluded from the normative digest.
- `contracts/v1/semantics/contract.md` and `contracts/v1/fixtures`: physical
  homes for manifest-listed semantic rules and byte-identical fixtures.
- `contracts/contract-index.json` and `contracts/contract-history`: supported
  revision registry and immutable released manifest/lock snapshots.
- `contracts/v1`: local schema copies and conformance fixtures.
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
  v1 child executions.
- `harness/core/pe-tests`: become purpose-specific frontends to the shared
  native workload/profile engine and add missing portfolio commands.
- `harness/adapters/loadgen/k6`: journey helper, selector contract, capability,
  continuous session, and v1 normalization.
- `harness/adapters/loadgen/jmeter`: replace the PerfLab-owned image with a
  repository-owned Dockerfile, runner, normalizer, package flow, fixtures,
  journey-v2 parsing, profile support, schema-backed `version`/`run-once`/
  `normalize` modes, and capability output. Validate manifest-declared resource
  ceilings rather than hard-coding `256`.
- `harness/adapters/loadgen/*` and the native orchestration bridge: implement or
  explicitly reject the base start/snapshot/stop session lifecycle and separate
  optional load-update capability while retaining one-shot request compatibility.
- `harness/adapters/loadgen/wrk`: advertise and enforce request-only support.
- `harness/adapters/observability/grafana`: operation-aware queries and every
  requested Pyroscope profile type.
- `harness/adapters/runtime/dotnet`: ordered multi-target campaigns, selected
  load-level replay, and complete compatibility evidence.
- `harness/adapters/dependency`: capability descriptors plus ownership-aware
  reset, snapshot, fault, and restoration.
- `harness/core/capture/capture-evidence.sh`: v1 result, APM correlation,
  multi-type profiles, and completeness states.
- `harness/core/analyze`: journey/operation comparison, robust statistics,
  compatibility, trend, gate, and report behavior.
- `labs/*`: add JSON catalogs, workload manifests, profile examples, real
  journeys, operation-aware dashboards, and retain `scenarios.tsv`.
- `labs/ecommerce`: add the stateful reference journey and the same `v1`
  managed-reference run-partition seed/reset provider required of the PerfLab
  reference target. Snapshot/restore is not a native-only substitute.
- `harness/adapters/loadgen/jmeter/run.sh`, `harness/core/lib/common.sh`, lab
  configuration comments, error messages, packaging guidance, and README
  examples: remove PerfLab-owned JMeter artifact references while preserving
  `PERFLAB_JMETER_IMAGE` as a compatibility input for the native-owned image.
- `harness/adapters/loadgen/jmeter/run.sh` and
  `harness/core/capture/capture-evidence.sh`: replace hard-coded
  `perflab.load.jmeter`/`0.1.0` values with the native adapter ID and a version
  obtained from its repository-owned manifest/image. Preserve `PERFLAB_PLUGIN_*`
  only as compatibility variable names, not PerfLab-owned values.
- `harness/adapters/loadgen/jmeter/run.sh`,
  `labs/ecommerce/loadgen/test-plan.jmx`,
  `labs/scenariolab/loadgen/test-plan.jmx`, and native lab configuration:
  ship only the canonical `perf.*` map. Keep the recorded v1 compatibility
  adapter for existing `perflab.*` JMX keys. Retain
  `PERFLAB_JMETER_PROP_*` only as compatibility environment names.
- Native JMeter host/image conformance tests: cover malformed and mismatched
  `version --json`, manifest resource ceilings, `run-once` inputs and outputs,
  cancellation, `normalize`, JTL fixtures, and required artifact publication.

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

### 19.0 Slice 0: contract and fixture freeze

- Record independence, ownership, rate units, journey semantics, and diagnostic
  isolation once in the joint plan and normative contract semantics.
- Add every `v1` schema, the normative semantics document, and canonical
  positive/negative fixture listed by the initial manifest. The freeze includes
  catalog, workload, JMeter wire, iteration-accounting, capability identifiers,
  and their fixtures.
- Add the authoritative logical-name manifest, repository-local path maps,
  deterministic lock generator, history/index, parity lock, aggregate digest
  algorithm, `contractRevision` validation, and conformance runner. After this
  slice the `v1` aggregate digest is immutable.
- Pin Markdown and all declared text fixtures, including JTL/JMX, to UTF-8/LF;
  declare diagnostic/archive formats binary in both `.gitattributes` files.
- Add a repository-owned Markdown validator that rejects trailing whitespace,
  prose beyond 90 columns, and inconsistent table column counts. Tables,
  fenced code, and URL destinations are explicit length exceptions. For a
  Markdown link it counts the rendered label and surrounding prose, so a long
  label cannot hide behind a URL exception.
- Add local CI in each repository that validates only its own plan hash,
  manifest, paths, lock, attributes, fixtures, and conformance results against
  `parity-lock.json`, then exports a parity attestation. It must not fetch the
  other repository.
- Add the coordinated parity workflow that compares the two exported
  attestations. Add the release-only coordinator, ownership, generated patch,
  and paired-merge controls specified in Section 17. It alone decides
  cross-repository byte equality and repeats the check at release.
- Refactor PerfLab command/flag registration and declare native shell inputs as
  specified in Section 17. Generate compatibility inventories and fail CI for
  a runtime/inventory mismatch or undocumented input.
- Define capability identifiers and unsupported-combination errors.
- Remove every actual .NET lab source and duplicated canonical workload asset
  from PerfLab. Keep descriptor-only bindings for ScenarioLab, Ecommerce, and
  Protocol Reliability, and enforce the exact canonical source and identity
  mappings from Section 12.1.
- Move `samples/dotnet-perf-eng/*.json` to product-neutral conformance fixtures
  and replace sibling-reading/skipping parity tests with local fixture tests.
- Prove generic and remote samples validate in isolation. Prove each shipped
  .NET lab descriptor validates and compiles only against the configured
  canonical checkout and fails clearly when that checkout is unavailable.
- Add an allowlist-based independence scan in both repositories. It rejects
  copied .NET lab source in PerfLab and peer-owned engine/runtime/package
  dependencies while allowing only the three descriptor-to-target bindings.
- Remove `dotnet-perf-eng`'s use of the PerfLab JMeter image and all runtime,
  error, comment, lab-configuration, packaging, and documentation references
  to PerfLab-owned JMeter artifacts. Introduce its independently built and
  pinned runner without regressing request-only behavior; retain
  `PERFLAB_JMETER_IMAGE` only as the compatibility name for that native image.
- Replace native JMeter adapter/property identity defaults, implement the
  schema-backed CLI/wire contract, and verify manifest-declared resource limits.
  Keep the recorded v1 `perflab.*` property adapter; ship only `perf.*` defaults.

Exit: `v1` manifest membership, schemas, fixtures, lock regeneration,
revision rejection, local attestations, coordinated parity, generated-interface
inventory, formatting, and independence checks pass. PerfLab samples execute
without `dotnet-perf-eng`; the native JMeter runtime and guidance execute without
PerfLab; request/JTL sample semantics remain unchanged. Legacy `perflab.*` JMX
keys remain accepted only through the recorded v1 compatibility adapter.

### 19.1 Slice 1: catalog and single-request compatibility

- Add JSON catalog/workload manifest parsing against the frozen `v1` files.
- Adapt TSV to request workloads.
- Implement runtime validation of legacy request iteration accounting using the
  exact immutable semantics and fixture paths from Section 2.1. Do not edit
  those files.
- Add validate and migrate commands.
- Compile request scenarios through v1 without changing measured output.
- Add target compatibility fields `lifecycle.ownership` and `writeSafety.class`
  as separate values; do not share one enum.
- Implement and test the narrow, immutable v1-baseline comparison
  projection defined in Section 16.1 against its frozen `v1` schema.

Exit: every existing sample and v1 scenario passes unchanged; migrated output
is behaviorally equivalent, eligible legacy baselines still gate through a
recorded projection, and ineligible comparisons are inconclusive.

### 19.2 Slice 2: journey-aware evidence and k6

- Extend models/schemas/SDKs.
- Add k6 helper and selector binding.
- Parse journey, operation, request, check, amplification, and delivery metrics.
- Convert one reference lab to a stateful journey.
- Implement the `v1` managed-reference ownership, acknowledgement, write
  budget, unique partition, seed/reset, reconciliation, and cleanup contract
  before enabling its create/pay steps.
- Add cardinality and secret-leak tests.

Exit: the six-step journey defined in Section 12.1, with extraction, checks,
think time, retries, and a mid-step failure, produces correct independent
counts; repeated write runs prove reset, reconciliation, and cleanup.

### 19.3 Slice 3: JMeter journey and generator capabilities

- Add journey-v2 validation and parsing.
- Separate transaction parents from protocol children.
- Support selector properties and required plan components.
- Add `v1` non-session capability negotiation to all generators. Do not add
  or advertise the `v1` session capability fields in this slice.
- Add equivalent k6/JMeter conformance fixtures.
- Define the pinned JMeter closed/open scheduling strategies and their
  interruption, timer, random-seed, and result semantics.

Exit: k6 and JMeter produce semantically equivalent evidence for the same
journey; wrk rejects it before traffic.

### 19.4 Slice 4: canonical profile engine

- Consolidate lab and generic profile compilation.
- Implement smoke, load, steady, ramp, stress, breakpoint, capacity/knee,
  spike, open, closed, and repetition behavior.
- Record last healthy/first failing levels and generator saturation.
- Add adaptive warmup/stabilization and safety stops.
- Implement each applicable profile through both the k6 and JMeter capability
  paths; do not mark the profile supported when only one repository has it.

Exit: every profile has deterministic compiled stages and golden execution
tests for request and journey units.

### 19.5 Slice 5: continuous soak and long-run durability

- Retain required `Runtime.Probe` for every load adapter and current one-shot
  profile. Add `SessionRuntime`/`LoadSession` `Start`, `Snapshot`, and `Stop` to
  the profile runtime and orchestration bridges as the base optional session
  capability. Add `UpdateLoad` only as a second optional capability.
- Require every adapter to advertise both session support states. An adapter
  claiming the base capability must implement `Start`, `Snapshot`, and `Stop`.
  An adapter claiming load update must also implement `UpdateLoad`. Reject soak
  before traffic only when the base capability is absent; reject an in-session
  changing-load profile when load-update support is absent.
- Add streaming cumulative counters, cursors, and mergeable histograms.
- Stop restarting generator sessions for soak observations.
- Add checkpoints, heartbeats, rolling correctness, leak slopes, retention,
  artifact/disk limits, cancellation, and partial-run recovery.

Exit: accelerated soak proves one generator process/session; scheduled 8-hour
and 24-hour validation runs meet retention and stability requirements.

### 19.6 Slice 6: unmanaged and managed targets

- Add local-process, local-container, existing-environment, existing-Kubernetes,
  managed-Compose, optional managed-Kubernetes, and agent target descriptors.
- Make lifecycle mutation conditional on ownership.
- Add named multi-origin routing, TLS/auth, clock, and exclusive leases.
- Add target capability snapshots and safety acknowledgements.

Exit: the same workload runs against an already-running local process and a
configured remote environment without deploy/start/stop calls.

### 19.7 Slice 7: data, fault, scale, recovery, and drain

- Generalize the minimal Slice 2 reset provider into data providers,
  partitions, reset/restore, write budgets, and cleanup.
- Expand fault providers to network delay/loss/reset/bandwidth, dependency
  pause/stop/restart, process/instance kill, CPU, memory, and disk pressure.
- Add scalability, cold/warm, async/backlog, recovery, and drain orchestration.
- Add failover, elasticity/autoscaling, overload/backpressure, contention,
  multi-tenant isolation, and connection/TLS churn policies.
- Require fault apply/restore proof and ownership-aware cleanup.

Exit: correctness, fault, and recovery evidence is complete and a failed cleanup
cannot produce a passing gate.

### 19.8 Slice 8: profiling, diagnostics, and LGTM observability

- Add multi-type Pyroscope configuration, queries, capture states, and overhead
  compatibility.
- Add per-service effective CPU-quota/minimum-core validation, reserved-label
  descriptor/discovery validation, activation probes, reserved-label collision
  checks, and push/query/sample-state preflight.
- Add multi-target `dotnet-monitor` campaigns and load-level replay.
- Add operation-aware metrics/traces/logs and critical-path reporting.
- Add diagnostic artifact budgets and non-replayable workload rules.

Exit: CPU, wall, allocation, lock, exception, and heap policies are tested;
separate API/worker campaigns preserve clean measurement evidence.

### 19.9 Slice 9: distributed load and protocols

- Add authenticated agent registration, clock checks, shard plans, unique data
  partitions, streaming mergeable histograms, and partial-agent policy.
- Add execution segments for k6 and an explicit JMeter distributed strategy.
- Add protocol adapter contracts for gRPC/WebSocket/messaging as implemented.
- Add a bounded browser-synthetic adapter that runs alongside, but does not
  replace, the backend load generator.

Exit: aggregate results preserve counts and histograms, identify generator
saturation per shard, and never average percentiles.

### 19.10 Slice 10: reports, gates, and release

- Update reports, trends, analysis, comparison, and gate messages.
- Add capability matrix command and support-level reporting.
- Complete security, performance-overhead, platform, and interruption tests.
- Publish upgrade and rollback procedures.
- Repeat the authoritative cross-repository plan, manifest, schema, fixture,
  and contract-lock attestation comparison in the coordinated parity workflow;
  local CI continues to validate only its repository's parity lock.

Exit: release checklist and full acceptance matrix pass in both independent
repositories.

### 19.11 Sizing, ownership, dependencies, and parallel work

Ranges are rough engineering weeks per repository, including implementation,
tests, fixtures, documentation, and review but excluding scheduled wall-clock
soak time. Slice 0 was re-estimated after decomposing the expanded reference
target, release coordinator, complete `v1` freeze, CLI inventory refactor,
independence scan, and native JMeter implementation. The ranges total 56-87
engineer-weeks per repository and 112-174 across both independent
implementations. Later slices are recalibrated after Slice 0 exits.

| Slice | Size per repository | Accountable owner roles | Dependency/parallelism |
| --- | --- | --- | --- |
| 0 | 7-11 weeks, extra large | Contract lead, repository lead, build/release | Starts first; repository tracks run concurrently |
| 1 | 2-3 weeks, medium | Catalog/compatibility lead, comparison lead | After contract freeze; both repositories in parallel |
| 2 | 4-6 weeks, large | Workload/evidence lead, k6 lead, data owner | After Slice 1; paired implementation in parallel |
| 3 | 5-8 weeks, extra large | JMeter lead, capability lead, security reviewer | After Slice 2 semantics; adapters run in parallel |
| 4 | 6-9 weeks, extra large | Profile-engine lead, performance-methods reviewer | After Slices 2-3; per-product engines in parallel |
| 5 | 5-8 weeks, extra large | Runtime/session lead, reliability lead | After Slice 4; soak runs add 8/24 hours wall time |
| 6 | 4-6 weeks, large | Target/lifecycle lead, security reviewer | Design after Slice 1; can overlap Slices 3-5 |
| 7 | 6-10 weeks, extra large | Data/fault lead, service owners, safety reviewer | After Slices 2 and 6; provider work can split by capability |
| 8 | 6-9 weeks, extra large | Observability/profiling lead, .NET diagnostics lead | Design after Slice 2; integration after Slices 4 and 6 |
| 9 | 8-12 weeks, extra large | Distributed-systems lead, protocol owners, security | After Slices 3, 4, and 6; adapters can split by protocol |
| 10 | 3-5 weeks, large | Reporting/gate lead, release lead, documentation | Migration starts after Slice 1; final gate waits for all |

Development may overlap as listed, but supported releases remain revision- and
dependency-ordered. Every slice has one accountable PerfLab owner, one
accountable `dotnet-perf-eng` owner, and independent reviewers for contract
parity, security/safety, and performance-method validity. Cross-repository pull
requests link the same revision and acceptance cases without sharing runtime
artifacts.

The staffing assumption is two independent teams of four to six engineers,
with named repository leads, plus fractional contract, performance-method,
observability, security, service/data, QA, and release reviewers. A shared
contract steward coordinates semantics but never implements one repository on
behalf of the other. Before Slice 0 starts, each repository records a named DRI,
backup, reviewer, allocation, and escalation path for every owner role in a
repository-local ownership file. Slice 0 cannot exit with placeholder roles.

The planning critical path is Slice 0 -> 1 -> 2 -> 3 -> 4 -> 5, with Slice 6
starting after Slice 1, Slices 7 and 8 joining after their stated dependencies,
then Slice 9 -> 10. With the staffing assumption and 20-30 percent integration
contingency, the initial calendar envelope is 10-14 months. Eight-hour and
24-hour soak qualifications add elapsed validation time but not engineer-week
effort. Any staffing reduction, failed JMeter decision gate, or external target
access delay triggers re-estimation rather than compressing acceptance scope.

### 19.12 Top risks and mitigations

| Priority | Risk | Mitigation and decision gate |
| --- | --- | --- |
| 1 | JMeter Open Model Thread Group remains experimental or fails accuracy/stability qualification | Slice 3 pins and qualifies it against delivery fixtures. If it fails, implement an independently owned external-arrival scheduler with start-delay and dropped-work evidence in both products. Until that passes, JMeter open arrival remains experimental/unsupported; never substitute a closed model. k6 remains the supported open-arrival path in both products. |
| 2 | Contract or plan drift between independently implemented repositories | Manifest membership, immutable revision/digest pairing, local parity-lock validation, isolated conformance, and authoritative coordinated attestation comparison begin in Slice 0. |
| 3 | Generator semantics produce plausible but incomparable journey, request, retry, or histogram totals | Golden cross-generator fixtures, amplification bounds, raw/mergeable histograms, and no percentile averaging. |
| 4 | Profiling or diagnostics alter the cohort or silently collect nothing | CPU-quota and label preflight, per-type capture states, profiling-on/off calibration, isolated diagnostic child runs, and overhead compatibility hashes. |
| 5 | Long-running or mutating tests damage environments or yield misleading partial results | Ownership-aware leases, minimal early reset, budgets, heartbeats, atomic checkpoints, verified restore/cleanup, and gates that cannot pass incomplete evidence. |

## 20. Acceptance matrix

Required end-to-end cases:

1. Legacy TSV GET/write scenarios and request-mix RPS aliases retain their
   current behavior; the mix manifest records effective `selections/s`.
2. JSON request workload matches the equivalent TSV result.
3. Stateful checkout performs login, browse, create, pay, poll, and verify only
   after managed-reference ownership, acknowledgement, budget, unique-partition,
   and reset readiness pass, then proves bounded cleanup.
4. Dynamic values, cookies, token refresh, CSRF, retries, and think time work.
5. A failed middle operation fails the journey without corrupting request counts.
6. k6 and JMeter split journey parent and HTTP request counts correctly.
7. Weighted mixes declare one `memberKind`, reject nested or heterogeneous
   members, select complete workloads, and report achieved distribution.
8. Open arrival proves journey starts/s and derived request amplification.
9. Closed execution proves concurrent user/session semantics.
10. Stress distinguishes target saturation from generator starvation.
11. Breakpoint records last healthy and first failing levels.
12. Spike records failure and recovery time by phase.
13. Soak uses one uninterrupted generator session and emits rolling checkpoints;
    an adapter without base `Start`/`Snapshot`/`Stop` support retains `Probe`
    profiles but rejects soak. Missing `UpdateLoad` rejects only profiles that
    change load within that session.
14. Data-scale restores and verifies each dataset fingerprint.
15. Fault execution proves apply and restore, including interrupted cleanup.
16. Async execution reconciles accepted, completed, duplicate, corrupt, and
    outstanding work after drain.
17. Existing local process runs without deployment or termination.
18. Existing remote environment runs without lifecycle mutation.
19. Existing Kubernetes mode performs no apply/delete/scale action.
20. Multi-origin journey routes only to allowlisted targets.
21. CPU/wall/allocation/lock/exception/live-heap profile states are recorded;
    versioned threshold, effective-quota discovery, activation-probe, and
    duplicate-label failures are rejected before measurement.
22. API and worker runtime campaigns replay the selected load level separately.
23. Baseline compatibility rejects workload, operation, rate-unit, dataset,
    target, environment, generator, or profiling-policy mismatch.
24. Required `missing`, `unsupported`, `failed`, `truncated`, or expired
    `delayed` evidence cannot pass a gate; optional evidence follows its recorded
    policy, and correctness-invalid evidence always fails.
25. Cancellation preserves partial evidence and restores owned mutations.
26. Secret scanning finds no credential values in arguments or artifacts.
27. Cardinality tests reject unbounded metric/profile labels.
28. Distributed aggregation matches a single-node fixture without percentile
    averaging.
29. Both repositories pass the same fixture corpus while installed alone.
30. No runtime/build/package default, shipped sample, discovery path, recovery
    message, or test resolves, imports, downloads, or starts the other product.
31. The byte-identical manifest defines the same members across different
    physical paths; missing/extra members, byte/order/BOM/attribute/line-ending
    drift, or manifest/lock disagreement fails local CI.
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
42. An unmanaged target's profiler configuration is verified through its
    declared read-only endpoint or permitted fresh attestation, never by changing
    or inferring process environment; absent verification rejects required types.
43. Required versus optional telemetry uses only the existing eight
    `CaptureState` values plus query facts; empty logs are captured with zero
    results while empty required metrics/traces/profiles remain non-captured.
    The shipped Grafana experiment uses run/service/window profile selection and
    contains no static `perf_phase` profile selector.
44. Restarted pods/processes are scoped to the correct measurement window and
    stale instances are excluded.
45. JTL, traces, profiles, dumps, logs, and samples satisfy sensitivity,
    redaction, retention, and access-policy checks.
46. Local-host fingerprints detect material power, thermal, resource-envelope,
    background-load, and generator-placement drift.
47. Resume never represents a restarted generator as one continuous soak.
48. Every current CLI flag, subcommand, positional rule, and native environment
    input in the generated compatibility inventory has a golden parse/manifest
    test, including `gate` comparison-context flags, `plugins upgrade`, and every
    `analyze` mode/provider flag.
49. Adding a registered command, subcommand, flag, positional input, or native
    environment input without regenerating the inventory fails CI.
50. Compatible stable `v1` request, journey, mix, and protocol candidates are
    evaluated without lossy projection; missing or different required
    dimensions are inconclusive and require a new baseline.
51. A higher unknown contract revision and a reused revision with a different
    digest both fail before target lease, mutation, deployment, or traffic.
52. Native runtime, JMX, configuration, and documentation scans find no
    PerfLab-owned JMeter artifact guidance, adapter ID/version value, or
    `perflab.*` property default. `PERFLAB_JMETER_IMAGE`, `PERFLAB_PLUGIN_*`, and
    `PERFLAB_JMETER_PROP_*` remain compatibility names only. Native
    `version`/`run-once`/`normalize`, resource-ceiling, JTL, and artifact-contract
    fixtures pass without the PerfLab image or binary.
53. Local CI validates only local bytes against `parity-lock.json` and exports
    an attestation without fetching the peer. The release coordinator consumes
    both artifacts, renders Section 17, regenerates the plan digest and complete
    lock, emits paired patches, and rejects unequal plan, inventory, manifest,
    contract-index, revision, or aggregate fields.

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
- [JMeter components used by journey plans](https://jmeter.apache.org/usermanual/component_reference.html)
- [JMeter distributed testing](https://jmeter.apache.org/usermanual/remote-test.html)

Official behavior is an input to adapter implementation, not a substitute for
the repository-owned capability tests and evidence contract.
