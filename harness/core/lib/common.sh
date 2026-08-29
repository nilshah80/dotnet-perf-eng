#!/usr/bin/env bash

set -euo pipefail

# ---------------------------------------------------------------------------
# Reusable performance harness -- shared library.
#
# Locations (this file is <harness_root>/core/lib/common.sh):
#   harness_core_dir = <harness_root>/core
#   harness_root     = <harness_root>            (the reusable toolkit)
#   repo_root        = holds harness/, the project tree, and lab.config.sh
#
# Design: zero host jq. The descriptor and scenario catalog are bash-native
# (lab.config.sh + scenarios.tsv), JSON the harness emits is built with printf
# helpers, and the few places that must parse foreign JSON (telemetry APIs,
# Claude output) call jq inside Docker via jqd(). Nothing here hardcodes a
# service name, port, metric, or source path; those come from the descriptor or
# an adapter under <harness_root>/adapters.
# ---------------------------------------------------------------------------
script_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
harness_core_dir="$(cd "${script_lib_dir}/.." && pwd)"
harness_root="$(cd "${harness_core_dir}/.." && pwd)"
repo_root="$(cd "${harness_root}/.." && pwd)"

# MSYS rewrites POSIX-looking environment variable values into Windows paths
# when spawning a native binary, so PERF_PATH=/api/... reached k6.exe/wrk as
# "C:/Program Files/Git/api/..." and the concatenated base URL became host
# "127.0.0.1:8080C", failing DNS on every request. These variables are URL
# parts and payloads consumed by the native load generators, not filesystem
# paths, so exclude them. (No jq CRLF shim is needed anymore: jq runs in Linux
# via jqd and the harness emits its own JSON with printf.)
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN*)
    export MSYS2_ENV_CONV_EXCL='PERF_BASE_URL;PERF_METHOD;PERF_PATH;PERF_BODY;PERF_RUN_ID;PERF_SCENARIO;PERF_RUN_MODE'
    ;;
esac

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Required command '$1' was not found." >&2
    exit 1
  fi
}

# Base dependencies. jq is deliberately NOT one of them -- it runs in Docker.
require_command docker
require_command curl
require_command awk

# ---------------------------------------------------------------------------
# Project descriptor (lab.config.sh) -- the single re-pointing seam.
# ---------------------------------------------------------------------------
# Lab selection: explicit PERFLAB_CONFIG path > PERFLAB_LAB (labs/<name>/) >
# auto-discover the single lab under labs/. Each lab is a labs/<project>/ folder
# holding lab.config.sh + scenarios.tsv (and its compose/infra); the app it tests
# lives separately under source/<runtime>/<project>/.
if [[ -n "${PERFLAB_CONFIG:-}" ]]; then
  lab_config="${PERFLAB_CONFIG}"
elif [[ -n "${PERFLAB_LAB:-}" ]]; then
  lab_config="${repo_root}/labs/${PERFLAB_LAB}/lab.config.sh"
else
  lab_config=""; _lab_count=0
  for _c in "${repo_root}"/labs/*/lab.config.sh; do
    [[ -f "${_c}" ]] || continue
    lab_config="${_c}"; _lab_count=$((_lab_count + 1))
  done
  if [[ "${_lab_count}" -ne 1 ]]; then
    echo "Select a lab: set PERFLAB_LAB=<name> or PERFLAB_CONFIG=<path> (found ${_lab_count} under ${repo_root}/labs)." >&2
    exit 1
  fi
fi
if [[ ! -f "${lab_config}" ]]; then
  echo "Lab descriptor not found: ${lab_config}" >&2
  exit 1
fi
# shellcheck disable=SC1090
source "${lab_config}"
export PERFLAB_CONFIG="${lab_config}"

resolve_repo_path() {
  local p="$1"
  case "$p" in
    /* | [A-Za-z]:[/\\]*) printf '%s' "$p" ;;
    *) printf '%s/%s' "${repo_root}" "$p" ;;
  esac
}

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

prometheus_url="${PERFLAB_PROMETHEUS_URL:-http://127.0.0.1:9090}"
tempo_url="${PERFLAB_TEMPO_URL:-http://127.0.0.1:3200}"
loki_url="${PERFLAB_LOKI_URL:-http://127.0.0.1:3100}"
diagnostics_url="${PERFLAB_DIAGNOSTICS_URL:-http://127.0.0.1:18323}"

dependencies="${PERFLAB_DEPENDENCIES:-}"
artifacts_root="$(resolve_repo_path "${PERFLAB_ARTIFACTS_ROOT:-artifacts}")"
scenario_catalog="$(resolve_repo_path "${PERFLAB_SCENARIOS:?PERFLAB_SCENARIOS not set}")"
runtime_adapter_dir="${harness_root}/adapters/runtime/${runtime}"

# wrk stays the default load generator. k6 is opt-in, and the two are not
# numerically comparable, so the generator is recorded in the manifest and must
# be held constant across a before/after comparison.
load_generator="${PERFLAB_LOAD_GENERATOR:-${PERFLAB_LOAD_GENERATOR_DEFAULT:-wrk}}"
if [[ "${load_generator}" != "wrk" && "${load_generator}" != "k6" ]]; then
  echo "PERFLAB_LOAD_GENERATOR must be 'wrk' or 'k6'; received '${load_generator}'." >&2
  exit 1
fi
# k6 runs on the host; wrk runs via Docker on the compose network (no host wrk).
internal_base_url="${PERFLAB_INTERNAL_BASE_URL:-http://api:8080}"
compose_network="${PERFLAB_COMPOSE_NETWORK:-perflab_default}"
wrk_image="${PERFLAB_WRK_IMAGE:-}"
require_loadgen() {
  case "${load_generator}" in
    k6) require_command k6 ;;
    wrk)
      require_command docker
      [[ -n "${wrk_image}" ]] || {
        echo "wrk runs via Docker; set PERFLAB_WRK_IMAGE in the descriptor to your wrk image." >&2
        exit 1
      }
      ;;
  esac
}

# ---------------------------------------------------------------------------
# jqd: jq inside Docker (no host jq). Reads stdin, writes stdout as LF. Callers
# MUST pipe file content in via stdin -- never pass a host file path as an
# argument, because it would not exist inside the container. MSYS_NO_PATHCONV
# stops Git Bash from rewriting jq filter arguments into Windows paths.
# ---------------------------------------------------------------------------
PERFLAB_JQ_IMAGE="${PERFLAB_JQ_IMAGE:-ghcr.io/jqlang/jq:1.7.1}"
jqd() {
  MSYS_NO_PATHCONV=1 docker run --rm -i "${PERFLAB_JQ_IMAGE}" "$@" | tr -d '\r'
  return "${PIPESTATUS[0]}"
}

# json_escape: escape a bash string for embedding inside a JSON string literal.
json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\t'/\\t}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\n'/\\n}"
  printf '%s' "$s"
}

# Convenience wrapper so no caller hardcodes the compose file path.
compose() { docker compose -f "${compose_file}" "$@"; }

# Adapter locators. Adapters re-source this file via PERFLAB_HARNESS_ROOT.
export PERFLAB_HARNESS_ROOT="${harness_root}"
dependency_dir() { printf '%s/adapters/dependency/%s' "${harness_root}" "$1"; }
loadgen_dir() { printf '%s/adapters/loadgen/%s' "${harness_root}" "${load_generator}"; }
# The load adapter has a single entry point run.sh <artifact-dir> <phase>,
# phase = warmup | measure | diagnostic.
loadgen_warmup() { "$(loadgen_dir)/run.sh" "$1" warmup; }
loadgen_measure() { "$(loadgen_dir)/run.sh" "$1" "$2"; }

# diag_target <app-service> -> process identity from PERFLAB_DIAG_TARGETS.
diag_target() {
  local svc="$1" pair
  for pair in ${PERFLAB_DIAG_TARGETS:-}; do
    if [[ "${pair%%:*}" == "${svc}" ]]; then
      printf '%s' "${pair#*:}"
      return 0
    fi
  done
  return 1
}

# ---------------------------------------------------------------------------
# Scenario catalog helpers (TAB-separated, awk-parsed).
# Columns: 1=id 2=name 3=method 4=path 5=body 6=target 7=diagnostic 8=connections
# ---------------------------------------------------------------------------
scenario_value() {
  local id="$1" field="$2" col
  case "$field" in
    id) col=1 ;; name) col=2 ;; method) col=3 ;; path) col=4 ;; body) col=5 ;;
    target) col=6 ;; diagnostic) col=7 ;; connections) col=8 ;;
    *) echo "Unknown scenario field '${field}'." >&2; return 1 ;;
  esac
  awk -F'\t' -v id="${id}" -v c="${col}" '
    $0 ~ /^[[:space:]]*#/ { next }
    $1 == id { print $c; exit }
  ' "${scenario_catalog}"
}

scenario_ids_all() {
  awk -F'\t' '
    $0 ~ /^[[:space:]]*#/ { next }
    NF >= 8 && $1 != "" { print $1 }
  ' "${scenario_catalog}"
}

require_scenario() {
  local id="$1"
  if ! awk -F'\t' -v id="${id}" '
        $0 ~ /^[[:space:]]*#/ { next }
        $1 == id { found = 1 }
        END { exit !found }
      ' "${scenario_catalog}"; then
    echo "Unknown scenario '${id}'. Available: $(scenario_ids_all | tr '\n' ' ')" >&2
    exit 1
  fi
}

wait_for_api() {
  local attempts=90
  local attempt
  for attempt in $(seq 1 "${attempts}"); do
    if curl -fsS "${ready_url}" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done

  echo "API did not become ready at ${ready_url}. Recent container logs:" >&2
  # shellcheck disable=SC2086
  compose logs --tail=100 ${app_services} >&2
  return 1
}

relative_to_repo() {
  local absolute_path="$1"
  printf '%s\n' "${absolute_path#"${repo_root}/"}"
}
