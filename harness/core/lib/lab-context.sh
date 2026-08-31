#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Lab-specific initialization -- sourced by lib/common.sh ONLY when a lab is
# selected (see the PERFLAB_LAB_OPTIONAL "helpers-only" path there). Everything
# here needs a resolved lab descriptor: the compose file, base/ready URLs,
# telemetry job/service regexes and metric prefix, dependency connection config,
# the lab directory + dependency-hook location, and the load-generator/profile
# selection. It runs in common.sh's shell (its variables become globals) and
# relies on repo_root, harness_root, lab_config and resolve_repo_path already
# existing.
# ---------------------------------------------------------------------------
project="${PERFLAB_PROJECT:?PERFLAB_PROJECT not set in ${lab_config}}"
runtime="${PERFLAB_RUNTIME:?PERFLAB_RUNTIME not set in ${lab_config}}"

compose_file="$(resolve_repo_path "${PERFLAB_COMPOSE_FILE:?PERFLAB_COMPOSE_FILE not set}")"
app_services="${PERFLAB_APP_SERVICES:?PERFLAB_APP_SERVICES not set}"
primary_app_service="${PERFLAB_PRIMARY_APP_SERVICE:-${app_services%% *}}"
base_url="${PERFLAB_BASE_URL:?PERFLAB_BASE_URL not set}"
ready_url="${PERFLAB_READY_URL:?PERFLAB_READY_URL not set}"

prom_job_regex="${PERFLAB_PROM_JOB_REGEX:?PERFLAB_PROM_JOB_REGEX not set}"
service_name_regex="${PERFLAB_SERVICE_NAME_REGEX:?PERFLAB_SERVICE_NAME_REGEX not set}"
run_id_attr="${PERFLAB_RUN_ID_ATTR:-perf.run.id}"
# OTEL resource attribute perf.run.id becomes Prometheus label perf_run_id
# (dots to underscores). Loki/Tempo keep the dotted attribute.
run_id_label="${run_id_attr//./_}"
# Application (business) metric prefix in Prometheus: the app's own OTel meter
# emits metrics named "<prefix>_*", and capture-evidence scopes its app-metric,
# scenario-executions, and pool-metric queries by it (and derives the
# service-instance regex from the result). Default matches the reference lab.
app_metric_prefix="${PERFLAB_APP_METRIC_PREFIX:-perflab}"

prometheus_url="${PERFLAB_PROMETHEUS_URL:-http://127.0.0.1:9090}"
tempo_url="${PERFLAB_TEMPO_URL:-http://127.0.0.1:3200}"
loki_url="${PERFLAB_LOKI_URL:-http://127.0.0.1:3100}"
diagnostics_url="${PERFLAB_DIAGNOSTICS_URL:-http://127.0.0.1:18323}"

dependencies="${PERFLAB_DEPENDENCIES:-}"
artifacts_root="$(resolve_repo_path "${PERFLAB_ARTIFACTS_ROOT:-artifacts}")"
scenario_catalog="$(resolve_repo_path "${PERFLAB_SCENARIOS:?PERFLAB_SCENARIOS not set}")"
runtime_adapter_dir="${harness_root}/adapters/runtime/${runtime}"

# ---------------------------------------------------------------------------
# Dependency connection config -- the "parameterize" seam. Defaults match this
# lab's compose services; a lab overrides any of these in lab.config.sh so the
# SHARED dependency adapters run their GENERIC captures against a different
# db/user/service/port without being edited. Project-specific EVIDENCE (an
# EXPLAIN of a named query, a probe of a named table) goes through the per-lab
# dependency hook mechanism below instead, never through these variables.
# ---------------------------------------------------------------------------
pg_service="${PERFLAB_PG_SERVICE:-postgres}"
pg_user="${PERFLAB_PG_USER:-perflab}"
pg_db="${PERFLAB_PG_DB:-perflab}"
redis_service="${PERFLAB_REDIS_SERVICE:-redis}"
rabbit_service="${PERFLAB_RABBIT_SERVICE:-rabbitmq}"
rabbit_user="${PERFLAB_RABBIT_USER:-perflab}"
rabbit_mgmt_url="${PERFLAB_RABBIT_MGMT_URL:-http://127.0.0.1:15672}"
rabbit_metrics_url="${PERFLAB_RABBIT_METRICS_URL:-http://127.0.0.1:15692/metrics}"
# Space-separated queue names the rabbitmq reset should purge (project-specific).
rabbit_queues="${PERFLAB_RABBIT_QUEUES:-}"

# The current lab's own directory (holds lab.config.sh, compose, infra, and the
# per-lab loadgen/ and dependencies/ override folders).
lab_dir="$(cd "$(dirname "${lab_config}")" && pwd)"
# Project-specific dependency probes are discovered here by convention:
#   <lab>/dependencies/<dep>/<phase>.sh   (phase = reset|sample-midload|snapshot)
lab_dep_hooks_dir="${PERFLAB_DEP_HOOKS_DIR:-${lab_dir}/dependencies}"

# Load generator: PERFLAB_LOAD_GENERATOR (per-run) > the lab's
# PERFLAB_LOAD_GENERATOR_DEFAULT (both labs set k6) > the built-in wrk fallback.
# k6 and wrk are not numerically comparable, so the generator is recorded in the
# manifest and must be held constant across a before/after comparison.
load_generator="${PERFLAB_LOAD_GENERATOR:-${PERFLAB_LOAD_GENERATOR_DEFAULT:-wrk}}"
if [[ "${load_generator}" != "wrk" && "${load_generator}" != "k6" ]]; then
  echo "PERFLAB_LOAD_GENERATOR must be 'wrk' or 'k6'; received '${load_generator}'." >&2
  exit 1
fi
# k6 runs on the host; wrk runs via Docker on the compose network (no host wrk).
internal_base_url="${PERFLAB_INTERNAL_BASE_URL:-http://api:8080}"
compose_network="${PERFLAB_COMPOSE_NETWORK:-perflab_default}"
wrk_image="${PERFLAB_WRK_IMAGE:-}"

# Load profile: the SHAPE of the measure-phase load. "steady" (default) is the
# constant-VU test the harness has always run; the others drive k6 executors so
# the harness answers capacity/limits/endurance questions instead of a single
# point -- ramp/stress/spike/soak are closed-model VU shapes, capacity/arrival
# are open-model arrival-rate. Executors are k6-only (wrk does "steady" only).
# Tuning knobs (all optional, k6 adapter reads them): PERFLAB_MAX_VUS,
# PERFLAB_SPIKE_VUS, PERFLAB_TARGET_RPS, PERFLAB_START_RPS,
# PERFLAB_SOAK_DURATION_SECONDS.
load_profile="${PERFLAB_PROFILE:-steady}"
case " steady ramp stress spike soak capacity arrival " in
  *" ${load_profile} "*) : ;;
  *) echo "PERFLAB_PROFILE must be one of: steady ramp stress spike soak capacity arrival; received '${load_profile}'." >&2; exit 1 ;;
esac
if [[ "${load_profile}" != "steady" && "${load_generator}" != "k6" ]]; then
  echo "PERFLAB_PROFILE='${load_profile}' needs PERFLAB_LOAD_GENERATOR=k6 (load-shape executors are k6-only; wrk supports 'steady')." >&2
  exit 1
fi
