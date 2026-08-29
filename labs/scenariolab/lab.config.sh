#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Project descriptor for the reusable performance harness.
# Sourced by harness/core/lib/common.sh. This bash file is the single seam that
# re-points the whole harness at a different project or runtime -- no script
# under harness/ hardcodes a service name, port, path, or metric name.
#
# Onboard another project by adding a sibling labs/<project>/ folder with its
# own lab.config.sh + scenarios.tsv (and its compose/infra), pointing at an app
# under source/<runtime>/<project>/. The harness auto-discovers the sole lab, or
# select one with PERFLAB_LAB=<name> or PERFLAB_CONFIG=<path>.
#
# Paths below are repo-root-relative unless absolute (compose's own paths are
# relative to the compose file).
# ---------------------------------------------------------------------------

PERFLAB_PROJECT="scenariolab"
PERFLAB_RUNTIME="dotnet"

# --- Compose + application under test ---
PERFLAB_COMPOSE_FILE="labs/scenariolab/compose.yaml"
PERFLAB_APP_SERVICES="api worker"        # rebuilt/recreated by the harness
PERFLAB_PRIMARY_APP_SERVICE="api"        # used for app-socket snapshots
PERFLAB_BASE_URL="http://127.0.0.1:8080"
PERFLAB_READY_URL="http://127.0.0.1:8080/health/ready"

# --- Telemetry correlation ---
PERFLAB_PROM_JOB_REGEX="perflab-.*"           # Prometheus job selector
PERFLAB_SERVICE_NAME_REGEX="perflab-(api|worker)"  # Tempo/Loki service.name selector
PERFLAB_RUN_ID_ATTR="perf.run.id"             # OTEL resource attr carrying the run id

# --- Observability + diagnostics endpoints ---
PERFLAB_PROMETHEUS_URL="http://127.0.0.1:9090"
PERFLAB_TEMPO_URL="http://127.0.0.1:3200"
PERFLAB_LOKI_URL="http://127.0.0.1:3100"
PERFLAB_DIAGNOSTICS_URL="http://127.0.0.1:18323"   # dotnet-monitor (runtime adapter)

# --- Load generators ---
# k6 runs on the host directly; wrk runs via Docker (no host install) on the
# compose network, targeting the app's internal URL.
PERFLAB_LOAD_GENERATOR_DEFAULT="k6"
PERFLAB_INTERNAL_BASE_URL="http://api:8080"   # app URL on the compose network (Docker load gens)
PERFLAB_COMPOSE_NETWORK="perflab_default"     # compose network a Docker load gen joins
PERFLAB_WRK_IMAGE=""                           # set to your wrk Docker image to enable wrk

# --- Dependencies (adapter names under harness/adapters/dependency/) ---
PERFLAB_DEPENDENCIES="postgres redis rabbitmq"

# --- Runtime diagnostics: app service -> process identity (space-separated svc:identity) ---
PERFLAB_DIAG_TARGETS="api:PerfLab.Api worker:PerfLab.Worker"

# --- Build (used by the AI fix phase) ---
PERFLAB_BUILD_DIR="source/dotnet/scenariolab"
PERFLAB_BUILD_COMMAND="dotnet build PerfLab.slnx -c Release"

# --- Paths ---
PERFLAB_ARTIFACTS_ROOT="artifacts"                         # evidence packages live here
PERFLAB_SCENARIOS="labs/scenariolab/scenarios.tsv"           # workload catalog
