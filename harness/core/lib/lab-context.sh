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

# Target mode: "local" (default) = the harness OWNS the app under test (Compose
# lifecycle, dependency resets, dotnet-monitor, run-id-scoped telemetry).
# "remote" = the app is already deployed elsewhere and is NOT owned here; the
# harness only drives load against base_url and records the load generator's SLIs
# -- no lifecycle, no resets, no runtime diagnostics, no run-id-scoped telemetry.
target_mode="${PERFLAB_TARGET:-local}"
case "${target_mode}" in
  local|remote) : ;;
  *) echo "PERFLAB_TARGET must be 'local' or 'remote'; received '${target_mode}'." >&2; exit 1 ;;
esac

# Remote observability tiers -- opt-in, and only meaningful when target is remote
# (a local target already owns everything). Two independent axes on top of the
# black-box default:
#   PERFLAB_REMOTE_TELEMETRY=1  -> "remote-observed": ALSO read the deployed app's
#     Prometheus/Tempo/Loki, scoped by the measurement WINDOW (the deployed app
#     does not carry our perf.run.id, so exact run-id isolation is impossible and
#     other traffic in the window is swept in). Needs the endpoint URLs + the
#     deployed env's job/service label names.
#   PERFLAB_REMOTE_DIAGNOSTICS=1 -> allow capture-runtime.sh against a remote
#     dotnet-monitor endpoint. It PERTURBS the target and can expose PII from
#     process memory, so capture-runtime additionally requires an explicit ack
#     (PERFLAB_REMOTE_DIAG_ACK, see remote_diag_ack_phrase below).
remote_diag_ack_phrase="i-understand-perturbation"
# A remote DIAGNOSTIC replay of a write scenario (POST/PUT/PATCH/DELETE) mutates real
# data on the target, which the perturbation/PII ack above does not cover -- it needs
# this separate, explicit acknowledgement.
remote_write_ack_phrase="i-understand-data-mutation"
remote_telemetry=0
remote_diagnostics=0
continuous_profiling=0
case "${PERFLAB_CONTINUOUS_PROFILING:-0}" in
  1|true|yes|on) continuous_profiling=1 ;;
  0|false|no|off|"") continuous_profiling=0 ;;
  *) echo "PERFLAB_CONTINUOUS_PROFILING must be 1/true or 0/false; received '${PERFLAB_CONTINUOUS_PROFILING}'." >&2; exit 1 ;;
esac
# Compose interpolates this; normalize aliases so the container sees 0 or 1.
export PERFLAB_CONTINUOUS_PROFILING="${continuous_profiling}"
export PERFLAB_PROFILING_POLICY="${PERFLAB_PROFILING_POLICY:-cpu}"
if [[ -z "${PERFLAB_PROFILING_TYPES:-}" ]]; then
  case "${PERFLAB_PROFILING_POLICY}" in
    cpu) PERFLAB_PROFILING_TYPES="cpu" ;;
    cpu-wall) PERFLAB_PROFILING_TYPES="cpu,wall" ;;
    memory|soak-memory) PERFLAB_PROFILING_TYPES="allocation,live-heap" ;;
    contention) PERFLAB_PROFILING_TYPES="lock" ;;
    exceptions) PERFLAB_PROFILING_TYPES="exception" ;;
    all-diagnostic) PERFLAB_PROFILING_TYPES="cpu,wall,allocation,lock,exception,live-heap" ;;
    *) echo "unknown PERFLAB_PROFILING_POLICY '${PERFLAB_PROFILING_POLICY}'" >&2; exit 1 ;;
  esac
fi
export PERFLAB_PROFILING_TYPES
profiling_keep_tiering=0
case "${PERFLAB_PROFILING_KEEP_TIERING:-0}" in
  1|true|yes|on) profiling_keep_tiering=1 ;;
  0|false|no|off|"") profiling_keep_tiering=0 ;;
  *) echo "PERFLAB_PROFILING_KEEP_TIERING must be 1/true or 0/false; received '${PERFLAB_PROFILING_KEEP_TIERING}'." >&2; exit 1 ;;
esac
# Compose interpolates this into app services; normalize aliases so containers see 0 or 1.
export PERFLAB_PROFILING_KEEP_TIERING="${profiling_keep_tiering}"
if [[ "${target_mode}" == "remote" ]]; then
  case "${PERFLAB_REMOTE_TELEMETRY:-0}" in
    1|true|yes|on) remote_telemetry=1 ;;
    0|false|no|off|"") remote_telemetry=0 ;;
    *) echo "PERFLAB_REMOTE_TELEMETRY must be 1/true or 0/false; received '${PERFLAB_REMOTE_TELEMETRY}'." >&2; exit 1 ;;
  esac
  case "${PERFLAB_REMOTE_DIAGNOSTICS:-0}" in
    1|true|yes|on) remote_diagnostics=1 ;;
    0|false|no|off|"") remote_diagnostics=0 ;;
    *) echo "PERFLAB_REMOTE_DIAGNOSTICS must be 1/true or 0/false; received '${PERFLAB_REMOTE_DIAGNOSTICS}'." >&2; exit 1 ;;
  esac
  # A remote tier must point at the DEPLOYED environment's backends EXPLICITLY: the
  # observability/diagnostics URLs below otherwise default to localhost, which would
  # silently read a stale LOCAL stack as if it were the remote target. Require the
  # URLs for whichever tier is enabled (an explicit localhost is still allowed, for a
  # deliberately local-backed test -- what is forbidden is inheriting it by default).
  if [[ "${remote_telemetry}" == "1" && ( -z "${PERFLAB_PROMETHEUS_URL:-}" || -z "${PERFLAB_TEMPO_URL:-}" || -z "${PERFLAB_LOKI_URL:-}" ) ]]; then
    echo "PERFLAB_REMOTE_TELEMETRY=1 requires PERFLAB_PROMETHEUS_URL, PERFLAB_TEMPO_URL and PERFLAB_LOKI_URL set to the deployed environment backends; a remote target must not inherit the localhost defaults." >&2
    exit 1
  fi
  if [[ "${remote_diagnostics}" == "1" && -z "${PERFLAB_DIAGNOSTICS_URL:-}" ]]; then
    echo "PERFLAB_REMOTE_DIAGNOSTICS=1 requires PERFLAB_DIAGNOSTICS_URL set to the deployed dotnet-monitor endpoint; a remote target must not inherit the localhost default." >&2
    exit 1
  fi
  if [[ "${continuous_profiling}" == "1" ]]; then
    if [[ "${remote_telemetry}" != "1" ]]; then
      echo "PERFLAB_CONTINUOUS_PROFILING=1 on a remote target requires PERFLAB_REMOTE_TELEMETRY=1 and an explicit PERFLAB_PYROSCOPE_URL; the harness never injects a profiler into a remote deployment." >&2
      exit 1
    fi
    if [[ -z "${PERFLAB_PYROSCOPE_URL:-}" ]]; then
      echo "PERFLAB_CONTINUOUS_PROFILING=1 on a remote target requires PERFLAB_PYROSCOPE_URL set to the deployed Pyroscope endpoint; a remote target must not inherit the localhost default." >&2
      exit 1
    fi
    if [[ -z "${PERFLAB_PYROSCOPE_SERVICES:-}" ]]; then
      echo "PERFLAB_CONTINUOUS_PROFILING=1 on a remote target requires PERFLAB_PYROSCOPE_SERVICES (the deployed app's exact Pyroscope service_name labels); the harness cannot guess a remote identity." >&2
      exit 1
    fi
    if [[ -z "${PERFLAB_PROFILING_VERIFICATION_URL:-}" ]]; then
      echo "PERFLAB_CONTINUOUS_PROFILING=1 on a remote target requires PERFLAB_PROFILING_VERIFICATION_URL for a read-only profiler configuration endpoint." >&2
      exit 1
    fi
  fi
fi

base_url="${PERFLAB_BASE_URL:?PERFLAB_BASE_URL not set}"
ready_url="${PERFLAB_READY_URL:?PERFLAB_READY_URL not set}"

# The Compose file + app services are LOCAL-only (a remote target owns no
# lifecycle). The Prometheus/service scoping is required for a LOCAL target and
# for a REMOTE-OBSERVED one (PERFLAB_REMOTE_TELEMETRY=1, which reads the deployed
# env's backends), but omitted for a plain black-box remote target.
if [[ "${target_mode}" == "local" ]]; then
  compose_file="$(resolve_repo_path "${PERFLAB_COMPOSE_FILE:?PERFLAB_COMPOSE_FILE not set (required for a local target)}")"
  app_services="${PERFLAB_APP_SERVICES:?PERFLAB_APP_SERVICES not set (required for a local target)}"
  prom_job_regex="${PERFLAB_PROM_JOB_REGEX:?PERFLAB_PROM_JOB_REGEX not set (required for a local target)}"
  service_name_regex="${PERFLAB_SERVICE_NAME_REGEX:?PERFLAB_SERVICE_NAME_REGEX not set (required for a local target)}"
else
  compose_file="$(resolve_repo_path "${PERFLAB_COMPOSE_FILE:-/dev/null}")"
  app_services="${PERFLAB_APP_SERVICES:-}"
  prom_job_regex="${PERFLAB_PROM_JOB_REGEX:-}"
  service_name_regex="${PERFLAB_SERVICE_NAME_REGEX:-}"
  # Remote-observed reads the deployed environment's backends, so it needs that
  # environment's Prometheus job label and service.name. Validate explicitly (a
  # plain check, not ${VAR:?...}, whose message-parsing mishandles apostrophes).
  if [[ "${remote_telemetry}" == "1" && ( -z "${prom_job_regex}" || -z "${service_name_regex}" ) ]]; then
    echo "PERFLAB_REMOTE_TELEMETRY=1 needs PERFLAB_PROM_JOB_REGEX and PERFLAB_SERVICE_NAME_REGEX set to the deployed environment Prometheus job label and service.name." >&2
    exit 1
  fi
fi
primary_app_service="${PERFLAB_PRIMARY_APP_SERVICE:-${app_services%% *}}"
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
if [[ "${target_mode}" == "local" ]]; then
  pyroscope_url="${PERFLAB_PYROSCOPE_URL:-http://127.0.0.1:4040}"
else
  # Remote never inherits the loopback Pyroscope default; an explicit URL is
  # required above when continuous profiling is enabled.
  pyroscope_url="${PERFLAB_PYROSCOPE_URL:-}"
fi
pyroscope_services="${PERFLAB_PYROSCOPE_SERVICES:-}"
pyroscope_required_services="${PERFLAB_PYROSCOPE_REQUIRED_SERVICES:-}"
if [[ "${continuous_profiling}" == "1" && "${target_mode}" == "local" && -z "${pyroscope_services}" ]]; then
  echo "PERFLAB_CONTINUOUS_PROFILING=1 requires PERFLAB_PYROSCOPE_SERVICES (exact Pyroscope service_name labels) in the lab descriptor." >&2
  exit 1
fi
export PERFLAB_PYROSCOPE_SERVICES="${pyroscope_services}"
export PERFLAB_PYROSCOPE_ROLE_SERVICES="${PERFLAB_PYROSCOPE_ROLE_SERVICES:-}"
export PERFLAB_PROFILING_VERIFICATION_URL="${PERFLAB_PROFILING_VERIFICATION_URL:-}"
export PERFLAB_PROFILING_MIN_CORES_THRESHOLD="${PERFLAB_PROFILING_MIN_CORES_THRESHOLD:-}"
export PERFLAB_PROFILING_SERVICE_QUOTAS="${PERFLAB_PROFILING_SERVICE_QUOTAS:-}"
export PERFLAB_PROFILING_QUOTA_SOURCE="${PERFLAB_PROFILING_QUOTA_SOURCE:-}"

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
json_catalog=""
if [[ -n "${PERFLAB_CATALOG:-}" ]]; then
  json_catalog="$(resolve_repo_path "${PERFLAB_CATALOG}")"
elif [[ -f "${lab_dir}/catalog.json" ]]; then
  json_catalog="${lab_dir}/catalog.json"
fi
workload_manifest=""
if [[ -n "${PERFLAB_WORKLOAD_MANIFEST:-}" ]]; then
  workload_manifest="$(resolve_repo_path "${PERFLAB_WORKLOAD_MANIFEST}")"
elif [[ -f "${lab_dir}/workload-manifest.json" ]]; then
  workload_manifest="${lab_dir}/workload-manifest.json"
fi
if [[ -n "${workload_manifest}" && -f "${workload_manifest}" ]]; then
  go run "${harness_root}/core/performance/cmd" workload "${workload_manifest}" >/dev/null || {
    echo "workload manifest ${workload_manifest} rejected before target lease or traffic" >&2
    exit 1
  }
fi
# Project-specific dependency probes are discovered here by convention:
#   <lab>/dependencies/<dep>/<phase>.sh   (phase = reset|sample-midload|snapshot)
lab_dep_hooks_dir="${PERFLAB_DEP_HOOKS_DIR:-${lab_dir}/dependencies}"

# Load generator: PERFLAB_LOAD_GENERATOR (per-run) > the lab's
# PERFLAB_LOAD_GENERATOR_DEFAULT (both labs set k6) > the built-in wrk fallback.
# k6 and wrk are not numerically comparable, so the generator is recorded in the
# manifest and must be held constant across a before/after comparison.
load_generator="${PERFLAB_LOAD_GENERATOR:-${PERFLAB_LOAD_GENERATOR_DEFAULT:-wrk}}"
if [[ "${load_generator}" != "wrk" && "${load_generator}" != "k6" && "${load_generator}" != "jmeter" ]]; then
  echo "PERFLAB_LOAD_GENERATOR must be 'wrk', 'k6', or 'jmeter'; received '${load_generator}'." >&2
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
case " smoke load steady ramp stress breakpoint capacity knee spike open closed soak arrival " in
  *" ${load_profile} "*) : ;;
  *) echo "PERFLAB_PROFILE must be one of: steady ramp stress spike soak capacity arrival; received '${load_profile}'." >&2; exit 1 ;;
esac
case "${load_generator}" in
  wrk)
    case "${load_profile}" in steady|smoke|load) : ;; *) echo "PERFLAB_PROFILE='${load_profile}' requires k6; wrk supports steady, smoke, and load only." >&2; exit 1 ;; esac
    ;;
  jmeter)
    case "${load_profile}" in steady|smoke|load|closed) : ;; *) echo "PERFLAB_PROFILE='${load_profile}' requires k6; JMeter supports steady, smoke, load, and closed only." >&2; exit 1 ;; esac
    ;;
esac
