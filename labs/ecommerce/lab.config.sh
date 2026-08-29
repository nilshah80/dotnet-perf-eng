#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Project descriptor for the eCommerce lab: a JWT-protected .NET Web API
# (products/orders/users CRUD + pagination) under source/dotnet/ecommerce.
#
# It demonstrates the reusable harness onboarding a SECOND project purely by
# adding files: a per-lab k6 workload that logs in via setup() (auth lives in
# the lab's script, not the shared adapter), postgres connection config that
# differs from the reference lab (db/user "ecommerce"), and an app-metric prefix
# of "ecommerce". No harness/ script is edited.
# ---------------------------------------------------------------------------

PERFLAB_PROJECT="ecommerce"
PERFLAB_RUNTIME="dotnet"

# --- Compose + application under test ---
PERFLAB_COMPOSE_FILE="labs/ecommerce/compose.yaml"
PERFLAB_APP_SERVICES="api"
PERFLAB_PRIMARY_APP_SERVICE="api"
PERFLAB_BASE_URL="http://127.0.0.1:8080"
PERFLAB_READY_URL="http://127.0.0.1:8080/health/ready"

# --- Telemetry correlation ---
PERFLAB_PROM_JOB_REGEX="ecommerce-.*"
PERFLAB_SERVICE_NAME_REGEX="ecommerce-api"
PERFLAB_RUN_ID_ATTR="perf.run.id"
# The app's OTel meter emits ecommerce_* metrics; capture-evidence scopes app
# metrics + the service-instance regex by this prefix.
PERFLAB_APP_METRIC_PREFIX="ecommerce"

# --- Observability + diagnostics endpoints (defaults; same host ports) ---
PERFLAB_PROMETHEUS_URL="http://127.0.0.1:9090"
PERFLAB_TEMPO_URL="http://127.0.0.1:3200"
PERFLAB_LOKI_URL="http://127.0.0.1:3100"
PERFLAB_DIAGNOSTICS_URL="http://127.0.0.1:18323"

# --- Load generators ---
PERFLAB_LOAD_GENERATOR_DEFAULT="k6"
PERFLAB_INTERNAL_BASE_URL="http://api:8080"
PERFLAB_COMPOSE_NETWORK="ecommerce_default"
PERFLAB_WRK_IMAGE=""
# The workload is this lab's own loadgen/k6.js: it authenticates once in setup()
# and sends the bearer token on every request, so protected scenarios need no
# harness change. (wrk would fall back to the shared unauthenticated default, so
# use k6 for protected endpoints, or pass a pre-minted token via PERF_HEADERS.)

# --- Dependencies (postgres only) ---
PERFLAB_DEPENDENCIES="postgres"
# Connection config differs from the reference lab -- proves the shared postgres
# adapter is parameterized, not hardcoded to perflab/perflab.
PERFLAB_PG_SERVICE="postgres"
PERFLAB_PG_USER="ecommerce"
PERFLAB_PG_DB="ecommerce"

# --- Runtime diagnostics: app service -> process identity ---
PERFLAB_DIAG_TARGETS="api:ECommerce.Api"

# --- Build (used by the AI fix phase) ---
PERFLAB_BUILD_DIR="source/dotnet/ecommerce"
PERFLAB_BUILD_COMMAND="dotnet build ECommerce.slnx -c Release"

# --- Paths ---
PERFLAB_ARTIFACTS_ROOT="artifacts"
PERFLAB_SCENARIOS="labs/ecommerce/scenarios.tsv"
