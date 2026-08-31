#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# REMOTE-TARGET example descriptor.
#
# PERFLAB_TARGET="remote" means the harness does NOT own the app under test:
# no Compose lifecycle, no dependency resets, no dotnet-monitor, and no
# run-id-scoped Prometheus/Tempo/Loki capture. The harness only drives load
# against PERFLAB_BASE_URL and records the load generator's OWN SLIs (throughput,
# latency percentiles, error rate) into facts.json -- a black-box capacity /
# latency test against an already-deployed endpoint.
#
# Select it with:   PERFLAB_LAB=remote-example
# Point it at YOUR endpoint by editing PERFLAB_BASE_URL / PERFLAB_READY_URL below,
# or override per-run:  PERFLAB_BASE_URL=... PERFLAB_READY_URL=... PERFLAB_LAB=remote-example ...
#
# What still works against a remote target:
#   run-scenario (single point), run-sweep (capacity knee), run-mix (blend),
#   run-repeat (WITHOUT --reseed), every load profile
#   (steady/ramp/stress/spike/soak/capacity/arrival), compare-runs, analyze-trends.
# Off by default, opt-in when you have more access (see the tiers below):
#   owned-telemetry capture (PERFLAB_REMOTE_TELEMETRY=1, window-scoped) and
#   capture-runtime diagnostics (PERFLAB_REMOTE_DIAGNOSTICS=1 + ack, STANDALONE only
#   -- suites skip it, and the raw capture is normalized offline).
# What is refused (they mutate owned state; clear "needs a local target" error):
#   run-fault, run-data-scale, run-repeat --reseed.
# ---------------------------------------------------------------------------

PERFLAB_PROJECT="remote-example"
# Runtime only labels the local tool-versions probe here; no app is built or owned
# for a remote target, so its actual runtime is unknown and irrelevant to the test.
PERFLAB_RUNTIME="dotnet"
PERFLAB_TARGET="remote"           # <-- the switch: black-box load against base_url

# --- Target endpoint (EDIT THESE for your deployment) ---
# A genuinely remote host works with both k6 and wrk. A host-loopback URL
# (127.0.0.1) works with k6 (a host process) but NOT wrk (a Docker container's
# 127.0.0.1 is its own loopback, not the host) -- use k6 for a host-local target.
# Both honor a per-run override, so these are only defaults.
PERFLAB_BASE_URL="${PERFLAB_BASE_URL:-http://127.0.0.1:8080}"
PERFLAB_READY_URL="${PERFLAB_READY_URL:-http://127.0.0.1:8080/health/ready}"

# --- Load generator ---
# k6 (host) is the default and the recommended generator for a remote target.
# wrk (Docker) also works against a genuinely remote URL; set PERFLAB_WRK_IMAGE to
# a wrk image whose entrypoint is wrk. Leave empty to use k6 only.
PERFLAB_LOAD_GENERATOR_DEFAULT="k6"
PERFLAB_WRK_IMAGE=""

# --- Optional richer tiers (only if you have MORE than URL access) ------------
# The default above is a pure black-box test. If you have READ access to the
# deployed environment's observability / diagnostics, opt into one or both tiers.
# Both are per-run env toggles (shown here as documentation, left unset by default
# so the example stays black-box); set them in your own lab.config or on the run.
#
# (A) remote-observed -- ALSO read the deployed env's Prometheus/Tempo/Loki,
#     scoped by the measurement WINDOW (the deployed app carries no perf.run.id, so
#     other traffic in the window is included; trust it only on an isolated env).
#     Requires that env's endpoint URLs + its job/service label names:
#   PERFLAB_REMOTE_TELEMETRY=1 \
#   PERFLAB_PROMETHEUS_URL="https://prom.staging.example.com" \
#   PERFLAB_TEMPO_URL="https://tempo.staging.example.com" \
#   PERFLAB_LOKI_URL="https://loki.staging.example.com" \
#   PERFLAB_PROM_JOB_REGEX="staging-api-.*" \
#   PERFLAB_SERVICE_NAME_REGEX="checkout-api" \
#   PERFLAB_APP_METRIC_PREFIX="myapp"   # if the deployed app's meter prefix differs
#
# (B) remote + diagnostics -- capture nettrace/gcdump against a remote
#     dotnet-monitor. It PERTURBS the live target and can expose PII, so it needs
#     an explicit ack and must be a SEPARATE run from measurement (prefer staging):
#   PERFLAB_REMOTE_DIAGNOSTICS=1 \
#   PERFLAB_REMOTE_DIAG_ACK=i-understand-perturbation \
#   PERFLAB_DIAGNOSTICS_URL="http://staging-host:18323" \
#   PERFLAB_DIAG_TARGETS="remote:MyApp.Api"    # scenario target service -> assembly name

# --- Auth (optional) ---
# For a protected endpoint, pass a PRE-MINTED token per-run via PERF_HEADERS -- do
# NOT commit real tokens. PERF_HEADERS is a flat JSON object of header name/value
# pairs (both the k6 and wrk workloads parse it as JSON, NOT a raw header string):
#   PERF_HEADERS='{"Authorization":"Bearer <token>"}' PERFLAB_LAB=remote-example \
#     harness/core/run/run-scenario.sh R02 30

# --- Paths ---
PERFLAB_ARTIFACTS_ROOT="artifacts"
PERFLAB_SCENARIOS="labs/remote-example/scenarios.tsv"

# NOTE: a remote target intentionally sets NONE of PERFLAB_COMPOSE_FILE /
# PERFLAB_APP_SERVICES / PERFLAB_DEPENDENCIES / PERFLAB_PROM_JOB_REGEX /
# PERFLAB_SERVICE_NAME_REGEX / the observability *_URL endpoints -- it owns none of
# them, and harness/core/lib/lab-context.sh does not require them when
# PERFLAB_TARGET=remote.
