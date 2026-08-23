Hey Claude, I have completed a performance run in this local .NET performance
engineering lab. Please investigate it as a senior .NET performance engineer.
I do not want to tell you which defects were intentionally added.

First inspect the evidence directory printed at the end of this prompt. Start
with `manifest.json` and `facts.json`.

If `manifest.json` has `kind: "scenario-suite"`, inspect every child listed in
the suite manifest under `scenarios/<scenario-id>`. Analyze each scenario
independently before comparing them, use S00 as a general healthy-process
baseline when it is present, and report any failed or incomplete child as a
limitation. S00 is not an endpoint-matched baseline for every scenario. If this
is a single-scenario package, analyze only that package.

For each measured scenario, inspect:

- `benchmark/wrk.txt` and `benchmark/diagnostic-wrk.txt`;
- OpenTelemetry metrics, traces, and logs;
- PostgreSQL, Redis, RabbitMQ, HTTP/socket, and Docker snapshots;
- `runtime/capture.json` and the available normalized runtime evidence;
- the corresponding application source code.

Some catalog entries recommend managed stacks, but the local dotnet-monitor
sidecar can fail on `/stacks`. In that case `runtime/capture.json` records a CPU
trace fallback. Treat that as a diagnostic limitation, not as an application
failure. Empty or missing telemetry is also a limitation, not proof of health.

For each scenario, explain in plain English:

1. What symptoms were actually measured, with evidence paths and values.
2. The most likely root cause and its complete causal chain.
3. Competing explanations considered and the evidence against them.
4. Exact source files, line numbers, and symbols involved.
5. The smallest sensible code or configuration fix.
6. How to rerun the identical workload and prove the fix worked.
7. Confidence and missing evidence.

For a suite, finish with a comparison table, severity/production-impact
priority, shared mechanisms, and an executive PoC summary. Do not treat scenario
names or the README's expected-behavior table as proof; establish every finding
from measurements and source. Actually, do not refer any other files those are not related to scenarios artifacts.

Clearly distinguish measured facts, source observations, inferences, and
assumptions. Do not modify files, restart containers, or run another load test.
You may use read-only commands to inspect evidence and source. Ask me before
making any changes.
