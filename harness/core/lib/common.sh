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
    export MSYS2_ENV_CONV_EXCL='PERF_BASE_URL;PERF_METHOD;PERF_PATH;PERF_BODY;PERF_RUN_ID;PERF_SCENARIO;PERF_RUN_MODE;PERF_HEADERS;PERF_MIX'
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
fi

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
    *)   echo "loadgen_script: unknown generator '${load_generator}'." >&2; return 1 ;;
  esac
  if [[ -n "${override}" ]]; then resolve_repo_path "${override}"; return 0; fi
  lab_script="${lab_dir}/loadgen/${load_generator}.${ext}"
  if [[ -f "${lab_script}" ]]; then printf '%s' "${lab_script}"; return 0; fi
  printf '%s/default.%s' "$(loadgen_dir)" "${ext}"
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
