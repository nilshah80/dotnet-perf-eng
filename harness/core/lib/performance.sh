#!/usr/bin/env bash
# Script-native validation helpers for the native performance harness.

performance_capability_preflight() {
  local generator="$1" workload="$2" protocol="${3:-}"
  case "${generator}" in k6|jmeter|wrk) ;; *) echo "unknown generator ${generator}" >&2; return 1 ;; esac
  case "${workload}" in request|journey|mix|protocol) ;; *) echo "unknown workload ${workload}" >&2; return 1 ;; esac
  if [[ "${generator}" == "wrk" && "${workload}" != "request" ]]; then
    echo "wrk supports request workloads only; rejected before traffic" >&2
    return 1
  fi
  if [[ "${workload}" == "protocol" ]]; then
    [[ "${generator}" == "k6" ]] || {
      echo "protocol workloads require k6; rejected before traffic" >&2
      return 1
    }
    case "${protocol}" in grpc|websocket|messaging|browser-synthetic) ;;
      *) echo "unknown protocol ${protocol}" >&2; return 1 ;;
    esac
  fi
}

performance_profile_preflight() {
  local profile="$1" generator="$2"
  case "${profile}" in smoke|load|steady|ramp|stress|breakpoint|capacity|knee|spike|open|closed|soak|arrival) ;;
    *) echo "unknown profile ${profile}" >&2; return 1 ;;
  esac
  case "${generator}" in
    wrk) case "${profile}" in smoke|load|steady) ;; *) echo "${profile} requires k6" >&2; return 1 ;; esac ;;
    jmeter) case "${profile}" in smoke|load|steady|closed|open|arrival|capacity|knee) ;;
      *) echo "${profile} is not implemented by the JMeter adapter" >&2; return 1 ;; esac ;;
  esac
}

performance_session_preflight() {
  case "$1" in
    k6|jmeter) return 0 ;;
    *) echo "soak requires a continuous k6 or JMeter session" >&2; return 1 ;;
  esac
}

performance_target_preflight() {
  local kind="$1" ownership="$2" action="$3"
  case "${kind}" in
    managed-compose|local-container|agent)
      [[ "${ownership}" == "managed" || "${ownership}" == "delegated" ]] || {
        echo "${kind} refuses ${action} without lifecycle ownership" >&2
        return 1
      }
      ;;
    local-process|existing-environment|existing-kubernetes)
      echo "unmanaged target ${kind} refuses ${action}" >&2
      return 1
      ;;
    *) echo "unknown target kind ${kind}" >&2; return 1 ;;
  esac
}

performance_compare_preflight() {
  case "$1" in request|journey|mix|protocol) return 0 ;;
    *) echo "workload type '$1' is not comparable under stable v1" >&2; return 1 ;;
  esac
}

performance_validate_catalog() {
  local file="$1"
  jqd -e '
    .apiVersion == "perflab.io/v1" and .kind == "ScenarioCatalog" and
    .contractRevision == "v1" and (.scenarios | type == "array" and length > 0) and
    ([.scenarios[].id] | length == (unique | length)) and
    all(.scenarios[];
      (.id | type == "string" and length > 0) and
      (.workload.type == "request" or .workload.type == "journey" or
       .workload.type == "mix" or .workload.type == "protocol") and
      (.workload.selector | type == "string" and length > 0) and
      (.targets | type == "array" and length > 0) and
      (.defaults.rate | type == "number" and . > 0))
  ' < "${file}" >/dev/null
}

performance_validate_workload_manifest() {
  local file="$1"
  jqd -e '
    .apiVersion == "perflab.io/v1" and .kind == "WorkloadManifest" and
    .contractRevision == "v1" and (.selectors | type == "array" and length > 0) and
    ([.selectors[].id] | length == (unique | length)) and
    all(.selectors[];
      (.id | type == "string" and length > 0) and
      (.type == "request" or .type == "journey" or .type == "mix" or .type == "protocol") and
      (.generators | type == "array" and length > 0))
  ' < "${file}" >/dev/null
}

performance_profiling_preflight() {
  local profile_type threshold quota item role value
  threshold="${PERFLAB_PROFILING_MIN_CORES_THRESHOLD:-}"
  [[ -n "${threshold}" ]] || { echo "profiling threshold is required" >&2; return 1; }
  if ! awk -v value="${threshold}" 'BEGIN { exit !(value >= 0.1 && value <= 1) }'; then
    echo "profiling threshold must be within 0.1 and 1 core" >&2
    return 1
  fi
  IFS=',' read -r -a profile_types <<< "${PERFLAB_PROFILING_TYPES:-cpu}"
  for profile_type in "${profile_types[@]}"; do
    case "${profile_type}" in cpu|wall|allocation|lock|exception|live-heap) ;;
      *) echo "unsupported profiling type ${profile_type}" >&2; return 1 ;;
    esac
  done
  for item in ${PERFLAB_PROFILING_SERVICE_QUOTAS:-}; do
    role="${item%%=*}"; value="${item#*=}"
    [[ -n "${role}" && "${value}" != "${item}" ]] || {
      echo "invalid profiling quota ${item}" >&2; return 1;
    }
    if ! awk -v threshold="${threshold}" -v value="${value}" 'BEGIN { exit !(value > 0 && threshold <= value) }'; then
      echo "profiling threshold ${threshold} exceeds ${role} quota ${value}" >&2
      return 1
    fi
  done
  jqd -cn \
    --arg state captured \
    --arg provider pyroscope-dotnet \
    --arg version 1.5.1 \
    --arg types "${PERFLAB_PROFILING_TYPES:-cpu}" \
    --arg threshold "${threshold}" \
    --arg source "${PERFLAB_PROFILING_QUOTA_SOURCE:-declared}" \
    '{captureState:$state,provider:$provider,providerVersion:$version,types:($types|split(",")),thresholdCores:($threshold|tonumber),quotaSource:$source}'
}
