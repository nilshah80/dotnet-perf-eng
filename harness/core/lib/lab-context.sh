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
# shellcheck disable=SC1091
source "${harness_root}/core/lib/performance.sh"

# D-P1-1. Named Pyroscope policies are process-lifetime. The catalog may select
# one per scenario; CLI/env still wins. These helpers are defined before first
# use because this file is sourced top to bottom.
profiling_types_for_policy() {
  case "$1" in
    cpu) printf 'cpu' ;;
    cpu-wall) printf 'cpu,wall' ;;
    memory|soak-memory) printf 'allocation,live-heap' ;;
    contention) printf 'lock' ;;
    exceptions) printf 'exception' ;;
    all-diagnostic) printf 'cpu,wall,allocation,lock,exception,live-heap' ;;
    *) return 1 ;;
  esac
}

profiling_startup_key() {
  printf '%s|%s|%s|%s' \
    "${PERFLAB_CONTINUOUS_PROFILING:-0}" \
    "${PERFLAB_PROFILING_POLICY:-}" \
    "${PERFLAB_PROFILING_TYPES:-}" \
    "${PERFLAB_PROFILING_KEEP_TIERING:-0}"
}

profiling_needs_recreate() {
  local previous="${1:-}" next="${2:-}"
  [[ -n "${previous}" && "${previous}" != "${next}" ]]
}

verify_requested_profiling_types() {
  local requested_type
  [[ "${target_mode}" == "remote" && "${continuous_profiling}" == "1" ]] || return 0
  [[ -n "${profiling_verification_body:-}" ]] || return 0
  for requested_type in ${PERFLAB_PROFILING_TYPES//,/ }; do
    if ! printf '%s' "${profiling_verification_body}" | jqd -e --arg t "${requested_type}" '(.activeTypes // []) | index($t) != null' >/dev/null 2>&1; then
      echo "Remote profiler verification does not list profile type '${requested_type}' as active; it cannot supply that evidence." >&2
      return 1
    fi
  done
  return 0
}

resolve_profiling_policy() {
  local scenario_id="${1:-}" catalog_policy=""
  if [[ -n "${PERFLAB_OPERATOR_PROFILING_POLICY}" || -n "${PERFLAB_OPERATOR_PROFILING_TYPES}" ]]; then
    export PERFLAB_PROFILING_POLICY="${PERFLAB_OPERATOR_PROFILING_POLICY:-cpu}"
    if [[ -n "${PERFLAB_OPERATOR_PROFILING_TYPES}" ]]; then
      export PERFLAB_PROFILING_TYPES="${PERFLAB_OPERATOR_PROFILING_TYPES}"
    else
      PERFLAB_PROFILING_TYPES="$(profiling_types_for_policy "${PERFLAB_PROFILING_POLICY}")" \
        || { echo "unknown PERFLAB_PROFILING_POLICY '${PERFLAB_PROFILING_POLICY}'" >&2; return 1; }
      export PERFLAB_PROFILING_TYPES
    fi
    export PERFLAB_PROFILING_POLICY_SOURCE="operator"
    verify_requested_profiling_types || return 1
    return 0
  fi
  if [[ -n "${json_catalog:-}" && -f "${json_catalog}" && -n "${scenario_id}" ]]; then
    catalog_policy="$(jqd -r --arg id "${scenario_id}" \
      '.scenarios[] | select(.id == $id) | .diagnostics.profilingPolicy // empty' \
      < "${json_catalog}" 2>/dev/null || true)"
  fi
  if [[ -n "${catalog_policy}" ]]; then
    PERFLAB_PROFILING_TYPES="$(profiling_types_for_policy "${catalog_policy}")" \
      || { echo "unknown catalog diagnostics.profilingPolicy '${catalog_policy}' for ${scenario_id}" >&2; return 1; }
    export PERFLAB_PROFILING_POLICY="${catalog_policy}"
    export PERFLAB_PROFILING_TYPES
    export PERFLAB_PROFILING_POLICY_SOURCE="catalog"
    verify_requested_profiling_types || return 1
    return 0
  fi
  export PERFLAB_PROFILING_POLICY="cpu"
  export PERFLAB_PROFILING_TYPES="cpu"
  export PERFLAB_PROFILING_POLICY_SOURCE="default"
  verify_requested_profiling_types || return 1
}

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
remote_correlation=0
continuous_profiling=0
case "${PERFLAB_CONTINUOUS_PROFILING:-0}" in
  1|true|yes|on) continuous_profiling=1 ;;
  0|false|no|off|"") continuous_profiling=0 ;;
  *) echo "PERFLAB_CONTINUOUS_PROFILING must be 1/true or 0/false; received '${PERFLAB_CONTINUOUS_PROFILING}'." >&2; exit 1 ;;
esac
# Compose interpolates this; normalize aliases so the container sees 0 or 1.
export PERFLAB_CONTINUOUS_PROFILING="${continuous_profiling}"
# Capture operator intent BEFORE defaulting. A missing env is how a per-scenario
# catalog policy can still be selected; defaulting first made every run look like
# the operator asked for cpu and the catalog field was dead.
PERFLAB_OPERATOR_PROFILING_POLICY="${PERFLAB_PROFILING_POLICY-}"
PERFLAB_OPERATOR_PROFILING_TYPES="${PERFLAB_PROFILING_TYPES-}"
export PERFLAB_PROFILING_POLICY="${PERFLAB_PROFILING_POLICY:-cpu}"
if [[ -z "${PERFLAB_PROFILING_TYPES:-}" ]]; then
  PERFLAB_PROFILING_TYPES="$(profiling_types_for_policy "${PERFLAB_PROFILING_POLICY}")" \
    || { echo "unknown PERFLAB_PROFILING_POLICY '${PERFLAB_PROFILING_POLICY}'" >&2; exit 1; }
fi
export PERFLAB_PROFILING_TYPES
export PERFLAB_PROFILING_POLICY_SOURCE="${PERFLAB_PROFILING_POLICY_SOURCE:-default}"
if [[ -n "${PERFLAB_OPERATOR_PROFILING_POLICY}" || -n "${PERFLAB_OPERATOR_PROFILING_TYPES}" ]]; then
  PERFLAB_PROFILING_POLICY_SOURCE="operator"
  export PERFLAB_PROFILING_POLICY_SOURCE
fi
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
  case "${PERFLAB_REMOTE_CORRELATION:-0}" in
    1|true|yes|on) remote_correlation=1 ;;
    0|false|no|off|"") remote_correlation=0 ;;
    *) echo "PERFLAB_REMOTE_CORRELATION must be 1/true or 0/false; received '${PERFLAB_REMOTE_CORRELATION}'" >&2; exit 1 ;;
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
  if [[ "${remote_correlation}" == "1" ]]; then
    remote_correlation_version="${PERFLAB_REMOTE_CORRELATION_VERSION:-}"
    remote_correlation_probe_path="${PERFLAB_REMOTE_CORRELATION_PROBE_PATH:-}"
    remote_correlation_header="${PERFLAB_REMOTE_CORRELATION_HEADER:-}"
    remote_correlation_response_run_id_field="${PERFLAB_REMOTE_CORRELATION_RESPONSE_RUN_ID_FIELD:-}"
    remote_correlation_response_version_field="${PERFLAB_REMOTE_CORRELATION_RESPONSE_VERSION_FIELD:-}"
    remote_correlation_prometheus_label="${PERFLAB_REMOTE_CORRELATION_PROMETHEUS_LABEL:-}"
    remote_correlation_loki_label="${PERFLAB_REMOTE_CORRELATION_LOKI_LABEL:-}"
    remote_correlation_tempo_attribute="${PERFLAB_REMOTE_CORRELATION_TEMPO_ATTRIBUTE:-}"
    performance_remote_correlation_validate || exit 1
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
    # D-P0-2. Requiring the URL and never reading it meant any syntactically
    # valid string satisfied the check: the run then claimed the remote profiler
    # was active without ever asking it. The harness does not own the remote
    # process, so this endpoint is the ONLY evidence that profiling was on --
    # it has to be fetched and its answer validated, not assumed.
    case "${PERFLAB_PROFILING_VERIFICATION_URL}" in
      https://*) ;;
      http://127.0.0.1*|http://localhost*) ;;   # loopback only, for testing the contract
      *) echo "PERFLAB_PROFILING_VERIFICATION_URL must use HTTPS (HTTP is allowed only for loopback testing); refusing to read a profiler attestation over plaintext." >&2; exit 1 ;;
    esac
    profiling_verification_file="${PERFLAB_PROFILING_VERIFICATION_OUT:-}"
    profiling_verification_body="$(backend_curl -fsS --max-time 10 --max-filesize 1048576 "${PERFLAB_PROFILING_VERIFICATION_URL}" 2>/dev/null || true)"
    if [[ -z "${profiling_verification_body}" ]]; then
      echo "Remote profiler verification endpoint ${PERFLAB_PROFILING_VERIFICATION_URL} returned nothing; cannot confirm the remote profiler is active." >&2
      exit 1
    fi
    # The document must state that profiling is active AND cover every type this
    # run asks for. A remote agent running cpu-only cannot substantiate an
    # allocation finding, so a partial match is a refusal, not a warning.
    if ! printf '%s' "${profiling_verification_body}" | jqd -e '.activationProbe == "active"' >/dev/null 2>&1; then
      echo "Remote profiler verification did not report activationProbe=\"active\"; refusing to record profiles as evidence from an unverified agent." >&2
      exit 1
    fi
    verify_requested_profiling_types || exit 1
    if [[ -n "${profiling_verification_file}" ]]; then
      mkdir -p "$(dirname "${profiling_verification_file}")"
      printf '%s\n' "${profiling_verification_body}" > "${profiling_verification_file}"
    fi
    echo "Remote profiler verification accepted for types: ${PERFLAB_PROFILING_TYPES}" >&2
  fi
fi

if [[ "${target_mode}" != "remote" ]]; then
  case "${PERFLAB_REMOTE_CORRELATION:-0}" in
    0|false|no|off|"") : ;;
    *) echo "PERFLAB_REMOTE_CORRELATION requires PERFLAB_TARGET=remote" >&2; exit 1 ;;
  esac
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
observability_result_max=10000000
log_limit="${PERFLAB_LOG_LIMIT:-25000}"
trace_limit="${PERFLAB_TRACE_LIMIT:-1000}"
for limit_entry in "PERFLAB_LOG_LIMIT:${log_limit}" "PERFLAB_TRACE_LIMIT:${trace_limit}"; do
  limit_name="${limit_entry%%:*}"; limit_value="${limit_entry#*:}"
  if [[ ! "${limit_value}" =~ ^[1-9][0-9]*$ ]] || (( limit_value > observability_result_max )); then
    echo "${limit_name} must be an integer between 1 and ${observability_result_max}; received '${limit_value}'." >&2
    exit 1
  fi
done
export PERFLAB_LOG_LIMIT="${log_limit}" PERFLAB_TRACE_LIMIT="${trace_limit}"
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

# D-P1-6. Isolated local Compose stays unauthenticated. Telemetry backends and
# remote monitors are admitted independently: a backend token must not satisfy
# a monitor request, and vice versa.
if [[ "${target_mode}" == "remote" ]]; then
  require_remote_endpoint_auth() {
    local name="$1" authorization="$2" ca="$3" cert="$4" key="$5"
    if [[ -n "${cert}" || -n "${key}" ]]; then
      if [[ -z "${cert}" || -z "${key}" ]]; then
        echo "${name} client certificate and key must be set together." >&2
        exit 1
      fi
    fi
    if [[ -z "${authorization}${ca}${cert}" ]]; then
      echo "${name} requires a secret-backed Authorization header or declared CA/mTLS configuration (values are never written to artifacts)." >&2
      exit 1
    fi
  }
  if [[ "${remote_telemetry}" == "1" ]]; then
    require_remote_endpoint_auth "external telemetry backends" \
      "${PERFLAB_BACKEND_AUTHORIZATION:-}" "${PERFLAB_BACKEND_CA_FILE:-}" \
      "${PERFLAB_BACKEND_CLIENT_CERT:-}" "${PERFLAB_BACKEND_CLIENT_KEY:-}"
  fi
  if [[ "${remote_diagnostics}" == "1" ]]; then
    require_remote_endpoint_auth "remote diagnostics" \
      "${PERFLAB_MONITOR_AUTHORIZATION:-}" "${PERFLAB_MONITOR_CA_FILE:-}" \
      "${PERFLAB_MONITOR_CLIENT_CERT:-}" "${PERFLAB_MONITOR_CLIENT_KEY:-}"
  fi
fi

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
  # shellcheck disable=SC1091
  source "${harness_root}/core/lib/performance.sh"
  performance_validate_workload_manifest "${workload_manifest}" || {
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
# are open-model arrival-rate. k6 implements every profile, JMeter implements
# its declared subset, and wrk is intentionally limited to simple closed load.
# Tuning knobs (all optional, k6 adapter reads them): PERFLAB_MAX_VUS,
# PERFLAB_SPIKE_VUS, PERFLAB_TARGET_RPS, PERFLAB_START_RPS,
# PERFLAB_SOAK_DURATION_SECONDS.
load_profile="${PERFLAB_PROFILE:-steady}"
case " smoke load steady ramp stress breakpoint capacity knee spike open closed soak arrival " in
  *" ${load_profile} "*) : ;;
  *) echo "PERFLAB_PROFILE must be one of: smoke load steady ramp stress breakpoint capacity knee spike open closed soak arrival; received '${load_profile}'." >&2; exit 1 ;;
esac
case "${load_generator}" in
  wrk)
    case "${load_profile}" in steady|smoke|load) : ;; *) echo "PERFLAB_PROFILE='${load_profile}' requires k6; wrk supports steady, smoke, and load only." >&2; exit 1 ;; esac
    ;;
  jmeter)
    case "${load_profile}" in
      steady|smoke|load|closed|open|arrival|capacity|knee) : ;;
      *) echo "PERFLAB_PROFILE='${load_profile}' is not implemented by JMeter." >&2; exit 1 ;;
    esac
    ;;
esac
