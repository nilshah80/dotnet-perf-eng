# Reusable performance-engineering lab

A local, language-neutral performance-evidence harness built as a thin
ports-and-adapters toolkit. A stable core drives measurement, evidence capture,
normalization, and a read-only AI diagnosis; everything project- or
language-specific plugs in through a bash descriptor and small adapter scripts.

The reference project is a .NET service with deliberately planted performance
defects (scenarios `S00`–`S26`). Onboarding another project or runtime means
**adding files, not editing the core**.

> Architecture, contracts, and the per-runtime adapter matrix live in
> [`BLUEPRINT.md`](BLUEPRINT.md).

## Repository layout

```
harness/                          # reusable toolkit (never edited per project)
├── core/                         # run-scenario(s), capture-evidence, capture/normalize-runtime, lib/common.sh
├── adapters/
│   ├── runtime/dotnet/           # metrics.sh, capture.sh, normalize.sh, versions.sh, evidence-extra.sh, diagnostics/Dockerfile
│   ├── dependency/{postgres,redis,rabbitmq}/  # reset.sh, sample-midload.sh, snapshot.sh
│   └── loadgen/{wrk,k6}/         # run.sh + scenario.lua / scenario.js
└── ai/                           # diagnosis.schema.json, *-prompt.md, scripts/
labs/scenariolab/                 # the EXPERIMENT (per project): what to test + how to run it
├── lab.config.sh                 # descriptor — the single re-pointing seam (bash)
├── scenarios.tsv                 # this project's API scenarios
└── compose.yaml  infra/          # lab wiring: app + deps + observability + diagnostics
source/dotnet/scenariolab/        # the APP under test ONLY (pristine — swappable for a real repo)
└── PerfLab.slnx  src/{Api,Worker,Shared}/
artifacts/runs/<run-id>/          # evidence packages
```

Three concerns, three homes: `harness/` (the reusable engine), `labs/<project>/`
(the experiment — descriptor, scenarios, lab compose/infra), and
`source/<runtime>/<project>/` (the application, kept clean). The harness
auto-discovers the sole lab; with several, select one via `PERFLAB_LAB=<name>`.

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
./harness/core/run-single.sh S01 30
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
        (only with --with-runtime)
              └─ capture-runtime.sh          separate diagnose-mode load
                    └─ normalize-runtime.sh  binaries -> Speedscope / text

  human review gate
        └─ ai/scripts/analyze-with-claude.sh -> claude-fix.sh   (the only editor)
```

`run-scenarios` always produces an evidence package. Runtime diagnostics are
opt-in (`--with-runtime`) and kept in a **separate** diagnose-mode run because
profiling perturbs the process. The AI phase sits outside the orchestrator,
behind a human gate.

## Commands

| Goal | Command |
|---|---|
| Measure one scenario | `./harness/core/run-single.sh S07 30` |
| Measure several under one run | `./harness/core/run-multiple.sh S07,S12,S17 30` |
| Full sweep of all scenarios | `./harness/core/run-all.sh 30 --continue-on-error` |
| Flat (non-suite) package | `./harness/core/run-scenario.sh S07 30` |

`--with-runtime` and `--continue-on-error` work with **any** of `run-single`,
`run-multiple`, and `run-all` — they all forward to the suite orchestrator.
`--with-runtime` captures and normalizes each scenario's recommended runtime
diagnostic (and roughly doubles wall-clock per scenario):

```bash
./harness/core/run-multiple.sh S02,S07,S12 30 --with-runtime
./harness/core/run-all.sh 30 --with-runtime --continue-on-error
```

The AI-diagnosis commands are covered under **AI diagnosis** below.

## Load generators

`k6` is the default (host binary; comparable to wrk's `-cN` via `--vus`). `wrk`
is opt-in and runs **via Docker** on the compose network — set
`PERFLAB_WRK_IMAGE` to a wrk image and select it per run:

```bash
PERFLAB_LOAD_GENERATOR=wrk ./harness/core/run-single.sh S01 30
```

The two are **not numerically comparable** (k6 reports latency as numeric ms;
wrk as unit-suffixed strings), so the generator is recorded in `manifest.json`
and must be held constant across a before/after comparison.

## Runtime diagnostics

Measurement and runtime capture are **separate runs** — diagnostic tools perturb
the process (`gcdump` forces a full collection). `--with-runtime` does this per
scenario automatically; you can also run it by hand on an existing package:

```bash
./harness/core/capture-runtime.sh artifacts/runs/<run-id>            # scenario's recommended kind
./harness/core/capture-runtime.sh artifacts/runs/<run-id> trace 30  # or choose: trace|gcdump|stacks|dump
./harness/core/normalize-runtime.sh artifacts/runs/<run-id>         # binaries -> Speedscope JSON / text
```

`capture-runtime` recreates the app in `diagnose` mode before applying load
(clearing leaks/pools left by the measurement) and resolves the target by runtime
identity, not container PID. For .NET, a `stacks` request records a `trace`
fallback by default (the dotnet-monitor profiler channel is unreliable in this
sidecar topology) and documents it in `runtime/capture.json`.

## Scenario catalog

`labs/scenariolab/scenarios.tsv` — a TAB-separated file (id, name,
method, path, body, target, diagnostic, connections) parsed with `awk`. A
scenario id is only a **correlation key**, never proof of a defect; diagnose from
the evidence and the source.

## Evidence package

`facts.json` is an **index** — observations with units and raw-source paths, not
conclusions. Binary runtime dumps stay local; the AI normally reads normalized
summaries. See [`BLUEPRINT.md`](BLUEPRINT.md) for the full layout.

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
- `--with-runtime` ~doubles wall-clock per scenario, and `capture-runtime` destroys
  the measured process state — so measure first, diagnose second.
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
