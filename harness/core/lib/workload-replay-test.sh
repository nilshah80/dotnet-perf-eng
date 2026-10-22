#!/usr/bin/env bash
# Exercise the shipping resolver and replay restoration, with host jq and no
# target lifecycle. Compatible with macOS Bash 3.2 and Git Bash on Windows.
set -euo pipefail
root="$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)"
fail() { echo "workload-replay-test: $*" >&2; exit 1; }
export PERFLAB_CONFIG="${root}/labs/protocol-reliability/lab.config.sh"
export PERFLAB_JQ=host PERFLAB_TARGET=local PERFLAB_CONTINUOUS_PROFILING=0
# shellcheck disable=SC1091
source "${root}/harness/core/lib/common.sh"
work="$(mktemp -d "${TMPDIR:-/tmp}/workload-replay.XXXXXX")"
trap 'rm -rf "${work}"' EXIT HUP INT TERM
manifest="${workload_manifest}"
load_generator=k6

for id in P01 P02 P03 P04 P10 P12 P13; do
  export PERF_SCENARIO="${id}"
  export PERF_WORKLOAD_KIND="$(scenario_value "${id}" type)"
  export PERF_PROTOCOL="$(scenario_value "${id}" selector)"
  unset PERF_WORKLOAD_ENTRYPOINT
  expected="$(jqd -r --arg id "${id}" '.selectors[] | select(.id == $id) | .entrypoints.k6' < "${manifest}")"
  actual="$(relative_to_repo "$(loadgen_script)")"
  [[ "${actual}" == "${expected}" ]] || fail "${id} measured ${actual}, expected ${expected}"
  origins='[]'; secondary=''
  if [[ "${id}" == P13 ]]; then
    origins='["http://127.0.0.1:18080","http://127.0.0.1:18084"]'
    secondary='http://127.0.0.1:18084'
  fi
  jqd -n --arg type "${PERF_WORKLOAD_KIND}" --arg selector "${PERF_PROTOCOL}" \
    --arg entrypoint "${expected}" --argjson origins "${origins}" --arg secondary "${secondary}" \
    '{workload:{loadGenerator:"k6",type:$type,selector:$selector,entrypoint:$entrypoint,allowedOrigins:$origins,secondaryBaseUrl:$secondary}}' \
    > "${work}/${id}.json"
  # A later standalone invocation inherits none of measurement's exports.
  unset PERF_WORKLOAD_KIND PERF_PROTOCOL PERF_WORKLOAD_ENTRYPOINT PERF_SECONDARY_BASE_URL
  PERF_ALLOWED_ORIGINS='["https://stale.example"]'
  performance_restore_workload_selector "${work}/${id}.json" "${id}" || fail "${id} replay was refused"
  [[ "${PERF_WORKLOAD_KIND}" == "$(scenario_value "${id}" type)" ]] || fail "${id} lost its type"
  [[ "${PERF_PROTOCOL}" == "$(scenario_value "${id}" selector)" ]] || fail "${id} lost its selector"
  actual="$(relative_to_repo "$(loadgen_script)")"
  [[ "${actual}" == "${expected}" ]] || fail "${id} replayed ${actual}, expected ${expected}"
  [[ "${PERF_SECONDARY_BASE_URL}" == "${secondary}" ]] || fail "${id} lost its secondary origin"
  if [[ "${id}" == P13 ]]; then
    [[ "${PERF_ALLOWED_ORIGINS}" == "${origins}" ]] || fail 'P13 lost its closed origin set'
  else
    [[ -z "${PERF_ALLOWED_ORIGINS:-}" ]] || fail "${id} borrowed an inherited allowlist"
  fi
  echo "${id}: measured and replayed ${actual}"
done

# Replay uses the recorded entrypoint, even after a manifest or descriptor edit.
jqd '.selectors |= map(if .id == "P13" then .entrypoints.k6="labs/protocol-reliability/loadgen/journey.js" else . end)' \
  < "${manifest}" > "${work}/changed-manifest.json"
workload_manifest="${work}/changed-manifest.json"
performance_restore_workload_selector "${work}/P13.json" P13
[[ "$(relative_to_repo "$(loadgen_script)")" == 'labs/protocol-reliability/loadgen/multi-origin.js' ]] \
  || fail 'replay followed a changed manifest'
PERF_WORKLOAD_ENTRYPOINT='labs/protocol-reliability/loadgen/missing.js'
if loadgen_script 2>/dev/null; then fail 'a missing recorded entrypoint silently fell back'; fi

# Legacy protocols/journeys cannot be reconstructed authoritatively. Requests
# retain their supported legacy path, and an inherited selector cannot leak in.
printf '{"workload":{}}\n' > "${work}/legacy.json"
PERF_METHOD=JOURNEY
if performance_restore_workload_selector "${work}/legacy.json" P12 2>/dev/null; then
  fail 'a legacy journey replayed without its measured workload identity'
fi
PERF_METHOD=POST
if performance_restore_workload_selector "${work}/legacy.json" P01 2>/dev/null; then
  fail 'a legacy protocol replayed without its measured workload identity'
fi
PERF_METHOD=GET
performance_restore_workload_selector "${work}/legacy.json" P00
[[ "${PERF_WORKLOAD_KIND}" == request && -z "${PERF_PROTOCOL}" && -z "${PERF_WORKLOAD_ENTRYPOINT}" ]] \
  || fail 'legacy request fallback inherited another workload'
[[ "$(relative_to_repo "$(loadgen_script)")" == 'labs/protocol-reliability/loadgen/k6.js' ]] \
  || fail 'legacy request lost its descriptor fallback'

# Resolving a manifest or replay path must never bypass the wrk journey gate.
load_generator=wrk
if performance_restore_workload_selector "${work}/P13.json" P13 2>/dev/null; then
  fail 'a recorded k6 journey accepted a different generator'
fi
PERF_WORKLOAD_KIND=journey
if loadgen_script 2>/dev/null; then fail 'wrk accepted a recorded journey'; fi
load_generator=jmeter
PERF_WORKLOAD_KIND=request; unset PERF_WORKLOAD_ENTRYPOINT
[[ "$(relative_to_repo "$(loadgen_script)")" == 'labs/protocol-reliability/loadgen/test-plan.jmx' ]] \
  || fail 'JMeter request fallback changed'
# Keep the documented isolated-capture generator override for requests while
# refusing to hand a generator-specific journey file to another generator.
printf '{"workload":{"loadGenerator":"k6","type":"request","selector":"P00","entrypoint":"labs/protocol-reliability/loadgen/k6.js"}}\n' > "${work}/request.json"
performance_restore_workload_selector "${work}/request.json" P00
[[ -z "${PERF_WORKLOAD_ENTRYPOINT}" && "$(relative_to_repo "$(loadgen_script)")" == 'labs/protocol-reliability/loadgen/test-plan.jmx' ]] \
  || fail 'an isolated request generator override used the recorded k6 script as a JMeter plan'
if performance_restore_workload_selector "${work}/P12.json" P12 2>/dev/null; then
  fail 'JMeter accepted a recorded k6 security journey'
fi
echo 'workload selector and diagnostic replay regression tests passed'
