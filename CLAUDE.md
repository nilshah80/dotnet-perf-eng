# Performance-engineering lab instructions

This repository is a controlled local performance lab. Diagnose from the captured evidence and the actual implementation; a scenario identifier is only a correlation key and is never proof of a defect.

The harness is runtime-agnostic and lives under `harness/` (core scripts + adapters + the AI phase). Each experiment is a `labs/<project>/` folder (`lab.config.sh` + `scenarios.tsv` + compose/infra); the application it tests lives separately under `source/<runtime>/<project>/`. For this repository: lab `labs/scenariolab/`, app `source/dotnet/scenariolab/` (solution `PerfLab.slnx`).

For diagnosis work:

- Treat `artifacts/runs/<run-id>/facts.json` as an index, then verify claims against the referenced raw artifacts.
- Cite exact source paths and line numbers for every proposed root cause.
- Separate observations, inferences, and unverified hypotheses.
- Do not claim that a runtime artifact proves a source-level cause unless the causal link is visible in stacks, traces, allocations, dependency telemetry, or code.
- Prefer the smallest change that removes the mechanism while preserving API behavior and message semantics.
- Never disable telemetry, lower the workload, relax correctness, add arbitrary caching, or bypass a dependency to manufacture an apparent improvement.
- Keep measurement and diagnostic runs separate because traces, GC dumps, and process dumps perturb the process.

For code changes, first read the latest structured diagnosis under the selected evidence package. Build the full solution and state the exact validation workload and mechanism-specific success gate.

