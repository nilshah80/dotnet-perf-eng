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
# Design: no host jq by default. The descriptor and scenario catalog are
# bash-native (lab.config.sh + scenarios.tsv), JSON the harness emits is built
# with printf helpers, and the few places that must parse foreign JSON
# (telemetry APIs, Claude output) call jqd(), which runs jq inside Docker unless
# PERFLAB_JQ=host opts into the host jq. Nothing here hardcodes a
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
# paths, so exclude them. jqd separately normalizes jq output in both modes.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN*)
    export MSYS2_ENV_CONV_EXCL='PERF_BASE_URL;PERF_SECONDARY_BASE_URL;PERF_METHOD;PERF_PATH;PERF_BODY;PERF_RUN_ID;PERF_SCENARIO;PERF_RUN_MODE;PERF_HEADERS;PERF_MIX;PERF_ALLOWED_ORIGINS;PERFLAB_CONNECTIONS;PERFLAB_DURATION_SECONDS;PERFLAB_GENERATOR_NETWORK_PATH;PERFLAB_PLUGIN_IMAGE_DIGEST'
    ;;
esac

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Required command '$1' was not found." >&2
    exit 1
  fi
}

# Base dependencies. jq is deliberately NOT one of them -- it runs in Docker by
# default, and PERFLAB_JQ=host requires the host jq below.
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
    # Some consumers need the harness helpers (locations, relative_to_repo, jqd)
    # but no specific lab -- notably the AI phase, which only reads an existing
    # evidence package. They export PERFLAB_LAB_OPTIONAL=1 so an ambiguous (>1)
    # or absent (0) lab loads the library in "helpers-only" mode instead of
    # exiting. Orchestration scripts leave it unset and still fail loudly here.
    if [[ -n "${PERFLAB_LAB_OPTIONAL:-}" ]]; then
      lab_config=""
    else
      echo "Select a lab: set PERFLAB_LAB=<name> or PERFLAB_CONFIG=<path> (found ${_lab_count} under ${repo_root}/labs)." >&2
      exit 1
    fi
  fi
fi

resolve_repo_path() {
  local p="$1"
  # Absolute if POSIX (/...) or a forward-slash Windows drive path (C:/...), the
  # form Git Bash uses. A backslash drive path (C:\...) is not matched -- MSYS
  # glob backslash-escaping makes it unreliable -- so pass absolute overrides
  # (PERFLAB_ARTIFACTS_ROOT, compose, scenario, script paths) with forward slashes.
  case "$p" in
    /* | [A-Za-z]:/*) printf '%s' "$p" ;;
    *) printf '%s/%s' "${repo_root}" "$p" ;;
  esac
}

# jqd: the jq for everything the harness must parse. By default it runs inside
# Docker (no host jq) at the version PERFLAB_JQ_IMAGE names, so every platform
# parses evidence with the same jq. It must be available before the selected lab
# context validates its stable-v1 catalog and workload manifest.
#
# PERFLAB_JQ=host opts into the host jq instead. Starting a container per call
# costs seconds on Docker Desktop for Windows and the harness makes hundreds of
# calls, so the host binary is several times faster there. It is opt-in because a
# host jq is whatever version is installed rather than the image's; the jq
# that parsed a package is recorded in source/tool-versions.txt in either mode.
# Both modes strip CR from jq output, including native Windows CRLF, without
# requiring the -b flag added in jq 1.7. Under MSYS, MSYS_NO_PATHCONV stops
# rewriting POSIX-looking arguments such as `--arg path /stacks`. This is safe
# because jqd calls feed JSON through stdin rather than passing file paths.
PERFLAB_JQ_IMAGE="${PERFLAB_JQ_IMAGE:-ghcr.io/jqlang/jq:1.7.1}"
PERFLAB_JQ="${PERFLAB_JQ:-docker}"
case "${PERFLAB_JQ}" in
  docker) ;;
  host) require_command jq ;;
  *)
    echo "PERFLAB_JQ must be 'docker' or 'host' (got '${PERFLAB_JQ}')." >&2
    exit 1
    ;;
esac
jqd() {
  if [[ "${PERFLAB_JQ}" == "host" ]]; then
    MSYS_NO_PATHCONV=1 command jq "$@" | tr -d '\r'
    return "${PIPESTATUS[0]}"
  fi
  MSYS_NO_PATHCONV=1 docker run --rm -i "${PERFLAB_JQ_IMAGE}" "$@" | tr -d '\r'
  return "${PIPESTATUS[0]}"
}

# perflab_python (host Python 3 resolution) is shared with the standalone tests
# and the sh contract scripts, which cannot source this file.
# shellcheck source=python.sh
. "${script_lib_dir}/python.sh"

# D-P1-6. Values stay in the environment. Evidence records secret:// handles
# only. Isolated local Compose labs call these with empty auth and stay
# unauthenticated. Defined before lab-context so remote verification can use
# them at source time.
backend_curl() {
  local args=()
  if [[ -n "${PERFLAB_BACKEND_AUTHORIZATION:-}" ]]; then
    args+=(-H "Authorization: ${PERFLAB_BACKEND_AUTHORIZATION}")
  fi
  if [[ -n "${PERFLAB_BACKEND_CA_FILE:-}" ]]; then
    args+=(--cacert "${PERFLAB_BACKEND_CA_FILE}")
  fi
  if [[ -n "${PERFLAB_BACKEND_CLIENT_CERT:-}" && -n "${PERFLAB_BACKEND_CLIENT_KEY:-}" ]]; then
    args+=(--cert "${PERFLAB_BACKEND_CLIENT_CERT}" --key "${PERFLAB_BACKEND_CLIENT_KEY}")
  fi
  if (( ${#args[@]} > 0 )); then
    command curl "${args[@]}" "$@"
  else
    command curl "$@"
  fi
}

monitor_curl() {
  local args=()
  if [[ -n "${PERFLAB_MONITOR_AUTHORIZATION:-}" ]]; then
    args+=(-H "Authorization: ${PERFLAB_MONITOR_AUTHORIZATION}")
  fi
  if [[ -n "${PERFLAB_MONITOR_CA_FILE:-}" ]]; then
    args+=(--cacert "${PERFLAB_MONITOR_CA_FILE}")
  fi
  if [[ -n "${PERFLAB_MONITOR_CLIENT_CERT:-}" && -n "${PERFLAB_MONITOR_CLIENT_KEY:-}" ]]; then
    args+=(--cert "${PERFLAB_MONITOR_CLIENT_CERT}" --key "${PERFLAB_MONITOR_CLIENT_KEY}")
  fi
  if (( ${#args[@]} > 0 )); then
    command curl "${args[@]}" "$@"
  else
    command curl "$@"
  fi
}

# The load-generator header bag may carry a target Authorization value, but it
# must never replace the correlation identity that the harness generates for a
# run. A caller that could override X-Perf-Run-Id would make a successful probe
# meaningless: the probe could carry one ID while every measured request carries
# another. Validate the bag once before any target request (including readiness
# and the remote correlation probe), and pass it as independent curl arguments
# rather than evaluating user-controlled text.
validate_target_headers() {
  [[ -z "${PERF_HEADERS:-}" ]] && return 0
  if ! printf '%s' "${PERF_HEADERS}" | jqd -e '
    type == "object" and
    all(to_entries[];
      (.key | test("^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")) and
      (.value | type) == "string" and
      ((.value | length) <= 16384) and
      ((.value | test("[\\r\\n]") | not)) and
      ((.key | ascii_downcase) != "x-perf-run-id"))
  ' >/dev/null 2>&1; then
    echo "PERF_HEADERS must be a bounded JSON object of string HTTP headers and must not override X-Perf-Run-Id." >&2
    return 1
  fi
}

target_curl() {
  validate_target_headers || return 1
  if [[ -n "${PERF_HEADERS:-}" ]]; then
    # Headers reach curl through a file descriptor (-H @file), never argv: a
    # bearer token on the command line is visible to every local user in ps.
    command curl -H @<(printf '%s' "${PERF_HEADERS}" | jqd -r 'to_entries[] | "\(.key): \(.value)"') "$@"
  else
    command curl "$@"
  fi
}

# Lab-specific initialization (compose file, base/ready URLs, telemetry regexes,
# dependency wiring, load-generator/profile selection) lives in lab-context.sh
# and runs ONLY when a lab is selected. Helpers-only consumers skip it: they get
# the location vars and the functions in this file, which is all they need.
if [[ -n "${lab_config}" ]]; then
  if [[ ! -f "${lab_config}" ]]; then
    echo "Lab descriptor not found: ${lab_config}" >&2
    exit 1
  fi
  # shellcheck disable=SC1090
  source "${lab_config}"
  export PERFLAB_CONFIG="${lab_config}"
  # shellcheck disable=SC1091
  source "${script_lib_dir}/lab-context.sh"
  # Ownership and lease rules depend on the resolved target, so they load
  # after lab-context has decided local vs remote.
  # shellcheck disable=SC1091
  source "${script_lib_dir}/target-lifecycle.sh"
fi

# wrk_execution_mode: print "docker" when PERFLAB_WRK_IMAGE names an image, else
# "host" when a wrk binary is on PATH. A Docker image whose architecture differs
# from the Docker host is refused before traffic: an amd64 wrk emulated on an
# arm64 host dies with SIGSEGV (exit 139), even for a plain GET.
wrk_execution_mode() {
  if [[ -z "${wrk_image:-}" ]]; then
    command -v wrk >/dev/null 2>&1 || {
      echo "wrk not found: install wrk on the host, or set PERFLAB_WRK_IMAGE to a wrk image for the Docker path." >&2
      return 1
    }
    echo host
    return 0
  fi
  command -v docker >/dev/null 2>&1 || { echo "wrk image ${wrk_image} needs docker, which is not installed." >&2; return 1; }
  local image_arch host_arch
  image_arch="$(docker image inspect --format '{{.Architecture}}' "${wrk_image}" 2>/dev/null)" || {
    echo "wrk image ${wrk_image} is not present locally; the run never pulls it." >&2
    return 1
  }
  host_arch="$(docker info --format '{{.Architecture}}' 2>/dev/null)"
  case "${host_arch}" in aarch64) host_arch=arm64 ;; x86_64) host_arch=amd64 ;; esac
  if [[ -n "${host_arch}" && "${image_arch}" != "${host_arch}" ]]; then
    echo "wrk image ${wrk_image} is ${image_arch} but the Docker host is ${host_arch}; emulated wrk crashes. Unset PERFLAB_WRK_IMAGE to use the host wrk, or pin a ${host_arch} image." >&2
    return 1
  fi
  echo docker
}

require_loadgen() {
  case "${load_generator}" in
    k6) require_command k6 ;;
    wrk)
      wrk_execution_mode >/dev/null || exit 1
      ;;
    jmeter)
      require_command docker
      [[ -n "${PERFLAB_JMETER_IMAGE:-}" ]] || {
        echo "jmeter runs via Docker; set PERFLAB_JMETER_IMAGE to the native adapter image (build with harness/adapters/loadgen/jmeter/package.sh)." >&2
        exit 1
      }
      ;;
  esac
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

# Stop OTHER labs' compose stacks before bringing up the selected one. Every lab
# in this repo publishes the same fixed host ports (the app's 8080, postgres
# 5432, and the shared observability/diagnostics ports), so a lab left running
# from a previous selection would block `compose up` for the selected lab with a
# port-bind error -- following the documented PERFLAB_LAB workflow could not
# switch labs without a manual teardown. Bringing the others down (keeping their
# volumes) frees the ports; it is a fast no-op when they are already stopped.
stop_conflicting_lab_stacks() {
  local other
  for other in "${repo_root}"/labs/*/compose.yaml; do
    [[ -f "${other}" ]] || continue
    [[ "${other}" -ef "${compose_file}" ]] && continue   # never the selected lab
    docker compose -f "${other}" down --remove-orphans >/dev/null 2>&1 || true
  done
}

# Adapter locators. Adapters re-source this file via PERFLAB_HARNESS_ROOT.
export PERFLAB_HARNESS_ROOT="${harness_root}"
dependency_dir() { printf '%s/adapters/dependency/%s' "${harness_root}" "$1"; }
loadgen_dir() { printf '%s/adapters/loadgen/%s' "${harness_root}" "${load_generator}"; }

# Per-lab workload script for the active generator, falling back to the shared
# default. Resolution order: explicit PERFLAB_{K6,WRK}_SCRIPT from the descriptor
# > <lab>/loadgen/<gen>.<ext> > the shared default.<ext>. This is the seam that
# lets a project own its workload (auth in k6 setup(), datasets, chaining)
# WITHOUT forking the shared run.sh or the observations/evidence contract.
loadgen_script() {
  local ext override lab_script
  case "${load_generator}" in
    k6)  ext="js";  override="${PERFLAB_K6_SCRIPT:-}" ;;
    wrk) ext="lua"; override="${PERFLAB_WRK_SCRIPT:-}" ;;
    jmeter) ext="jmx"; override="${PERFLAB_JMETER_PLAN:-}" ;;
    *)   echo "loadgen_script: unknown generator '${load_generator}'." >&2; return 1 ;;
  esac
  if [[ "${PERF_WORKLOAD_KIND:-}" == "journey" || "${PERF_WORKLOAD_KIND:-}" == "mix" ]]; then
    if [[ "${load_generator}" == "wrk" ]]; then
      echo "capability generator.wrk.journey is unsupported; rejected before traffic" >&2
      return 1
    fi
  fi
  if [[ "${PERF_WORKLOAD_KIND:-}" == "journey" || "${PERF_MIX_KIND:-}" == "journey" ]]; then
    if [[ "${load_generator}" == "k6" && -f "${lab_dir}/loadgen/journey.js" ]]; then
      printf '%s' "${lab_dir}/loadgen/journey.js"; return 0
    fi
    if [[ "${load_generator}" == "k6" && -f "${harness_root}/adapters/loadgen/k6/journey.js" ]]; then
      printf '%s' "${harness_root}/adapters/loadgen/k6/journey.js"; return 0
    fi
    if [[ "${load_generator}" == "jmeter" && -f "${lab_dir}/loadgen/checkout-journey.jmx" ]]; then
      printf '%s' "${lab_dir}/loadgen/checkout-journey.jmx"; return 0
    fi
  fi
  if [[ "${PERF_WORKLOAD_KIND:-}" == "protocol" && "${load_generator}" == "k6" ]]; then
    if [[ "${PERF_PROTOCOL:-}" == "browser-synthetic" ]]; then
      printf '%s' "${lab_dir}/loadgen/browser.js"
    else
      printf '%s' "${lab_dir}/loadgen/protocol.js"
    fi
    return 0
  fi
  if [[ -n "${override}" ]]; then resolve_repo_path "${override}"; return 0; fi
  lab_script="${lab_dir}/loadgen/${load_generator}.${ext}"
  if [[ -f "${lab_script}" ]]; then printf '%s' "${lab_script}"; return 0; fi
  if [[ "${load_generator}" == "jmeter" && -f "${lab_dir}/loadgen/test-plan.jmx" ]]; then
    printf '%s' "${lab_dir}/loadgen/test-plan.jmx"; return 0
  fi
  if [[ "${load_generator}" == "jmeter" ]]; then
    echo "JMeter plan not found; set PERFLAB_JMETER_PLAN or add labs/<lab>/loadgen/test-plan.jmx" >&2
    return 1
  fi
  printf '%s/default.%s' "$(loadgen_dir)" "${ext}"
}

loadgen_supports() {
  local gen="${1:-${load_generator}}" op="${2:?loadgen_supports <generator> <operation>}"
  case "${gen}:${op}" in
    k6:*) return 0 ;;
    jmeter:session) return 0 ;;
    jmeter:repeat) return 0 ;;
    *) return 1 ;;
  esac
}

# The load adapter has a single entry point run.sh <artifact-dir> <phase>,
# phase = warmup | measure | diagnostic.
loadgen_warmup() { "$(loadgen_dir)/run.sh" "$1" warmup; }
loadgen_measure() { "$(loadgen_dir)/run.sh" "$1" "$2"; }

# loadgen_effective_duration <connections> <requested-duration> -> the seconds the
# measure phase will ACTUALLY run. Most profiles == the requested duration, but a
# k6 soak stretches to >=600s and a spike adds fixed surge/recover segments, so
# the manifest, the mid-load snapshot delay, and the fault window must use this,
# not the raw CLI value. The k6 adapter owns the stage math (profiles.sh).
loadgen_effective_duration() {
  if [[ "${load_generator}" == "k6" && "${load_profile}" != "steady" ]]; then
    # shellcheck disable=SC1090
    source "$(loadgen_dir)/profiles.sh"
    k6_profile_effective_duration "${load_profile}" "$1" "$2"
  else
    printf '%s' "$2"
  fi
}

# Run a lab's project-specific dependency probe for <dep> <phase>, if the lab
# provides one under <lab>/dependencies/<dep>/<phase>.sh. Additive: the shared
# adapter has ALREADY done the generic capture before calling this. Best-effort
# but LOUD on failure, so a broken probe is never mistaken for "nothing to
# capture" (cf. the log/trace warnings in capture-evidence.sh).
run_lab_dependency_hook() {
  local dep="$1" phase="$2" artifact_dir="$3"
  local hook="${lab_dep_hooks_dir}/${dep}/${phase}.sh"
  [[ -f "${hook}" ]] || return 0
  # Propagate the hook's failure (return non-zero) so the caller can mark the
  # package partial (snapshot) or abort (reset) -- a failed hook must not be
  # silently converted to success.
  bash "${hook}" "${artifact_dir}" && return 0
  echo "WARNING: lab dependency hook ${dep}/${phase} failed; its evidence is MISSING, not empty." >&2
  return 1
}

# read_fields <expected-count> -- fill TSV_FIELDS from one-field-per-line stdin.
#
# `IFS=$'\t' read -r a b c` is wrong for TSV whose fields may be empty: bash
# treats tab as IFS WHITESPACE, so consecutive tabs collapse into one delimiter
# and every field after an empty one shifts left. A GET workload has an empty
# body, so this silently rebuilt the replay envelope out of the wrong values --
# `body=true`, `dataset=64`, `conns=''` -- and the diagnostic replayed a
# workload that was never measured.
#
# Emit one field per line instead (jq: `.[] | tostring`) and read them
# positionally. An unexpected count is a refusal, not a best-effort parse,
# because a short read is exactly what the collapse used to produce.
TSV_FIELDS=()
read_fields() {
  local expected="${1:?read_fields <expected-count>}" line
  TSV_FIELDS=()
  while IFS= read -r line; do
    TSV_FIELDS+=("${line}")
  done
  if [[ "${#TSV_FIELDS[@]}" -ne "${expected}" ]]; then
    echo "Expected ${expected} fields, received ${#TSV_FIELDS[@]}; refusing to continue with a misaligned record." >&2
    return 1
  fi
  return 0
}

# Local replicas may have identical assembly names. Resolve their isolated
# monitor endpoint without weakening the adapter's single-match identity check.
# Remote targets continue to require the explicitly acknowledged endpoint.
diag_endpoint() {
  local svc="$1" pair
  if [[ "${target_mode:-local}" != remote ]]; then
    for pair in ${PERFLAB_DIAG_ENDPOINTS:-}; do
      if [[ "${pair%%=*}" == "${svc}" ]]; then printf '%s' "${pair#*=}"; return 0; fi
    done
  fi
  printf '%s' "${diagnostics_url}"
}

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
      type|selector) col=0 ;;
      profilingPolicy|loadModel) col=0 ;;
    *) echo "Unknown scenario field '${field}'." >&2; return 1 ;;
  esac
  if [[ -n "${scenario_catalog:-}" && -f "${scenario_catalog}" && "${col}" != 0 ]]; then
    local from_tsv
    from_tsv="$(awk -F'\t' -v id="${id}" -v c="${col}" '
      $0 ~ /^[[:space:]]*#/ { next }
      $1 == id { print $c; exit }
    ' "${scenario_catalog}")"
    if [[ -n "${from_tsv}" || "$field" == "body" ]]; then
      if awk -F'\t' -v id="${id}" '$0 !~ /^[[:space:]]*#/ && $1 == id { found=1 } END { exit !found }' "${scenario_catalog}"; then
        printf '%s' "${from_tsv}"
        return 0
      fi
    fi
  fi
  if [[ -n "${json_catalog:-}" && -f "${json_catalog}" ]]; then
    local filter
    case "${field}" in
      id|name) filter=".${field}" ;;
      type|selector) filter=".workload.${field}" ;;
      target) filter='.targets[0]' ;;
      diagnostic) filter='.diagnostics.preset' ;;
      profilingPolicy) filter='.diagnostics.profilingPolicy' ;;
      connections) filter='.defaults.rate' ;;
      loadModel) filter='.defaults.loadModel' ;;
      *) filter='' ;;
    esac
    if [[ -n "${filter}" ]]; then
      local value
      value="$(jqd -er --arg id "${id}" ".scenarios[] | select(.id == \$id) | ${filter}" < "${json_catalog}" 2>/dev/null || true)"
      if [[ -n "${value}" && "${value}" != "null" ]]; then
        printf '%s' "${value}"
        return 0
      fi
    fi
  fi
  if [[ "${field}" == "type" ]] && awk -F'\t' -v id="${id}" '$0 !~ /^[[:space:]]*#/ && $1 == id { found=1 } END { exit !found }' "${scenario_catalog}" 2>/dev/null; then
    printf 'request'
    return 0
  fi
  echo "Unknown scenario '${id}'." >&2
  return 1
}

scenario_ids_all() {
  if [[ -n "${json_catalog:-}" && -f "${json_catalog}" ]]; then
    jqd -er '.scenarios[].id' < "${json_catalog}"
    return
  fi
  awk -F'\t' '
    $0 ~ /^[[:space:]]*#/ { next }
    NF >= 8 && $1 != "" { print $1 }
  ' "${scenario_catalog}"
}

require_scenario() {
  local id="$1"
  if [[ -n "${scenario_catalog:-}" && -f "${scenario_catalog}" ]] && awk -F'\t' -v id="${id}" '
        $0 ~ /^[[:space:]]*#/ { next }
        $1 == id { found = 1 }
        END { exit !found }
      ' "${scenario_catalog}"; then
    return 0
  fi
  if [[ -n "${json_catalog:-}" && -f "${json_catalog}" ]]; then
    if jqd -e --arg id "${id}" 'any(.scenarios[]; .id == $id)' < "${json_catalog}" >/dev/null; then
      return 0
    fi
  fi
  echo "Unknown scenario '${id}'. Available: $(scenario_ids_all | tr '\n' ' ')" >&2
  exit 1
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
