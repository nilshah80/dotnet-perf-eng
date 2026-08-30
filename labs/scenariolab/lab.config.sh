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
# Workload scripts are the shared run.sh (evidence contract) + a per-lab script.
# The active generator's script is resolved as: PERFLAB_{K6,WRK}_SCRIPT override >
# labs/scenariolab/loadgen/<gen>.{js,lua} (present) > the shared default. This lab
# ships its own copies under loadgen/; they equal the shared default because
# scenariolab endpoints are unauthenticated single-request scenarios.

# --- Dependencies (adapter names under harness/adapters/dependency/) ---
PERFLAB_DEPENDENCIES="postgres redis rabbitmq"

# --- Dependency connection config (consumed by the SHARED dependency adapters) ---
# These match compose.yaml and equal the harness defaults; they are stated here so
# the lab is self-describing and so onboarding a project with different service
# names/users/db is a config-only change (no adapter edits). Project-specific
# EVIDENCE (query plans, named-table probes) instead lives under
# labs/scenariolab/dependencies/<dep>/<phase>.sh and is discovered by convention.
PERFLAB_PG_SERVICE="postgres"
PERFLAB_PG_USER="perflab"
PERFLAB_PG_DB="perflab"
PERFLAB_REDIS_SERVICE="redis"
PERFLAB_RABBIT_SERVICE="rabbitmq"
PERFLAB_RABBIT_USER="perflab"
# Project-specific queues the rabbitmq reset purges before each scenario.
PERFLAB_RABBIT_QUEUES="perf.orders.created perf.orders.dead"

# --- Runtime diagnostics: app service -> process identity (space-separated svc:identity) ---
PERFLAB_DIAG_TARGETS="api:PerfLab.Api worker:PerfLab.Worker"

# --- Build (used by the AI fix phase) ---
PERFLAB_BUILD_DIR="source/dotnet/scenariolab"
PERFLAB_BUILD_COMMAND="dotnet build PerfLab.slnx -c Release"

# --- Paths ---
PERFLAB_ARTIFACTS_ROOT="artifacts"                         # evidence packages live here
PERFLAB_SCENARIOS="labs/scenariolab/scenarios.tsv"           # workload catalog
