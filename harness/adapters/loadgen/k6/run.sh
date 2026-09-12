#!/usr/bin/env bash
# k6 load adapter -- single entry point for every phase.
#   run.sh <artifact-dir> <phase>   phase = warmup | measure | diagnostic
# For the "measure" phase it writes benchmark/observations.json from k6's nested
# summary JSON, parsed with dockerized jq (jqd).
set -euo pipefail
HARNESS_ROOT="${PERFLAB_HARNESS_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
# shellcheck disable=SC1091
source "${HARNESS_ROOT}/core/lib/common.sh"   # jqd, loadgen_script

artifact_dir="${1:?run.sh <artifact-dir> <phase>}"
phase="${2:?phase required (warmup|measure|diagnostic)}"
mkdir -p "${artifact_dir}/benchmark"
# The workload script is the lab's own k6.js if it ships one, else the shared
# default.js. run.sh (this file, the measurement + evidence contract) is always
# shared and identical across labs.
js="$(loadgen_script)"

sha256_stream() {
  if command -v openssl >/dev/null 2>&1; then
    openssl dgst -sha256 2>/dev/null | awk '{print $NF}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  else
    echo "k6 compatibility capture needs openssl or shasum for SHA-256." >&2
    return 1
  fi
}

# The compatibility envelope of a MEASURED package is immutable evidence. A
# diagnostic replay that runs inside a measured package (isolated non-campaign
# diagnostics) publishes its own envelope beside it instead of overwriting it;
# a fresh campaign-load directory still receives compatibility.json.
compatibility_target() {
  local target="${artifact_dir}/benchmark/compatibility.json"
  if [[ "${phase}" == "diagnostic" && -s "${target}" ]]; then
    target="${artifact_dir}/benchmark/diagnostic-compatibility.json"
  fi
  printf '%s' "${target}"
}
write_compatibility() {
  local script_rel workload_hash fingerprint base network timeout_seconds config_hash header_names
  script_rel="$(relative_to_repo "${js}")"
  workload_hash="$({ printf '%s\0' "${script_rel}"; cat "${js}"; printf '\0'; } | sha256_stream)"
  fingerprint="$(k6 version 2>&1 | tr -d '\r' | awk 'NF { if (seen++) printf " | "; printf "%s", $0 }')"
  base="${PERF_BASE_URL%/}"
  network="${PERFLAB_GENERATOR_NETWORK_PATH:-host}"
  header_names='[]'
  if [[ -n "${PERF_HEADERS:-}" ]]; then
    header_names="$(printf '%s' "${PERF_HEADERS}" | jqd -c 'if type=="object" then keys|sort else error("PERF_HEADERS must be an object") end')"
  fi
  if [[ "${phase}" == "measure" ]]; then timeout_seconds=$((dur + 90)); else timeout_seconds=$((dur + 60)); fi
  # Include request bodies, headers, and mix definitions in the digest without
  # publishing them or placing them in an external command's argument list.
  config_hash="$({
    printf 'connections\0%s\0duration\0%s\0timeout\0%s\0profile\0%s\0scenario\0%s\0' \
      "${conns}" "${dur}" "${timeout_seconds}s" "${profile}" "${PERF_SCENARIO:-}"
    printf 'baseUrl\0%s\0method\0%s\0path\0%s\0body\0%s\0headerNames\0%s\0mix\0%s\0network\0%s\0script\0%s\0' \
      "${base}" "${PERF_METHOD:-}" "${PERF_PATH:-}" "${PERF_BODY:-}" "${header_names}" "${PERF_MIX:-}" "${network}" "${script_rel}"
  } | sha256_stream)"
  [[ "${workload_hash}" =~ ^[a-f0-9]{64}$ && "${config_hash}" =~ ^[a-f0-9]{64}$ && -n "${fingerprint}" ]] || {
    echo "k6 compatibility fingerprint/hash capture failed." >&2; exit 1;
  }
  printf '{"generator":"k6","generatorFingerprint":"%s","workloadContentHash":"%s","configurationHash":"%s","networkPath":"%s","timeout":"%ss","durationSeconds":%s,"connections":%s,"scenario":"%s","profile":"%s","baseUrl":"%s","method":"%s","path":"%s","script":"%s"}\n' \
    "$(json_escape "${fingerprint}")" "${workload_hash}" "${config_hash}" "$(json_escape "${network}")" \
    "${timeout_seconds}" "${dur}" "${conns}" "$(json_escape "${PERF_SCENARIO:-}")" "$(json_escape "${profile}")" \
    "$(json_escape "${base}")" "$(json_escape "${PERF_METHOD:-}")" "$(json_escape "${PERF_PATH:-}")" "$(json_escape "${script_rel}")" \
    > "$(compatibility_target)"
}

# --- Optional k6 -> Prometheus remote-write (MEASURE phase only) --------------
# Streams the load generator's own throughput/latency/error metrics into the
# lab's Prometheus so the Grafana SLO panels show the CLIENT-observed view next
# to server-side signals -- the two diverge exactly when the system is saturating
# (client sees queueing the server never records). Series carry run=$PERF_RUN_ID
# (== the app's perf_run_id) so a dashboard filters both sources by one variable.
#
# Guarded by a Prometheus readiness probe: when the endpoint is unreachable -- a
# remote black-box target with no local stack, or the stack still starting -- it
# is skipped with a warning and NEVER fails the run. Disable with PERFLAB_K6_PROM_RW=0.
# NB: k6 reserves the `scenario` tag (its executor name), so the perf scenario is
# carried as perf_scenario.
K6_RW_OUT=()
k6_enable_prom_rw() {
  [[ "${PERFLAB_K6_PROM_RW:-1}" == "0" ]] && return 0
  local base="${PERFLAB_PROMETHEUS_URL:-}"
  [[ -z "${base}" ]] && return 0
  base="${base%/}"
  if ! curl -fsS --max-time 2 "${base}/-/ready" >/dev/null 2>&1; then
    echo "k6->Prometheus remote-write skipped: ${base}/-/ready not reachable." >&2
    return 0
  fi
  export K6_PROMETHEUS_RW_SERVER_URL="${base}/api/v1/write"
  export K6_PROMETHEUS_RW_TREND_STATS="${K6_PROMETHEUS_RW_TREND_STATS:-p(50),p(90),p(95),p(99),avg,max}"
  K6_RW_OUT=(--out experimental-prometheus-rw
    --tag "perf_scenario=${PERF_SCENARIO:-unknown}"
    --tag "run=${PERF_RUN_ID:-unknown}"
    --tag "testid=${PERF_RUN_ID:-unknown}")
  echo "k6->Prometheus remote-write -> ${K6_PROMETHEUS_RW_SERVER_URL} (run=${PERF_RUN_ID:-unknown})"
}

case "${phase}" in
  warmup)
    warmup_seconds="${PERFLAB_WARMUP_SECONDS:-10}"
    case "${warmup_seconds}" in
      ''|*[!0-9]*) echo "PERFLAB_WARMUP_SECONDS must be an integer number of seconds; received '${warmup_seconds}'." >&2; exit 1 ;;
    esac
    if (( warmup_seconds < 1 || warmup_seconds > 600 )); then
      echo "PERFLAB_WARMUP_SECONDS must be between 1 and 600; received '${warmup_seconds}'." >&2
      exit 1
    fi
    k6 run --vus 16 --duration "${warmup_seconds}s" \
      --summary-export "${artifact_dir}/benchmark/k6-warmup.json" \
      --quiet --no-color "${js}" \
      > "${artifact_dir}/benchmark/k6-warmup.txt"
    ;;
  measure | diagnostic)
    conns="${PERFLAB_CONNECTIONS:?PERFLAB_CONNECTIONS not set}"
    dur="${PERFLAB_DURATION_SECONDS:?PERFLAB_DURATION_SECONDS not set}"
    profile="${PERFLAB_PROFILE:-steady}"
    if [[ "${phase}" == "measure" ]]; then
      summary="k6-summary.json"; txt="k6.txt"
    else
      summary="diagnostic-k6-summary.json"; txt="diagnostic-k6.txt"
    fi
    # The MEASURE phase honors the load profile via a generated k6 config
    # (--config carries the executor; the workload script stays untouched). The
    # DIAGNOSTIC phase always uses a steady load so a captured trace reflects a
    # stable state rather than a ramp.
    # Client metrics stream to Prometheus for the measure phase only (the diagnostic
    # phase is a separate perturbing load and must not pollute the SLO panels).
    K6_RW_OUT=()
    [[ "${phase}" == "measure" ]] && k6_enable_prom_rw

    if [[ "${phase}" == "measure" && "${profile}" != "steady" ]]; then
      # shellcheck disable=SC1091
      source "${HARNESS_ROOT}/adapters/loadgen/k6/profiles.sh"
      cfg="${artifact_dir}/benchmark/k6-profile.json"
      k6_write_profile_config "${profile}" "${conns}" "${dur}" "${cfg}"
      echo "Load profile: ${profile} (executor recorded in benchmark/k6-profile.json)"
      k6 run --config "${cfg}" \
        --summary-export "${artifact_dir}/benchmark/${summary}" \
        ${K6_RW_OUT[@]+"${K6_RW_OUT[@]}"} \
        --quiet --no-color "${js}" \
        > "${artifact_dir}/benchmark/${txt}"
    else
      k6 run --vus "${conns}" --duration "${dur}s" \
        --summary-trend-stats "avg,min,med,max,p(50),p(90),p(95),p(99)" \
        --summary-export "${artifact_dir}/benchmark/${summary}" \
        ${K6_RW_OUT[@]+"${K6_RW_OUT[@]}"} \
        --quiet --no-color "${js}" \
        > "${artifact_dir}/benchmark/${txt}"
    fi

    write_compatibility
    [[ "${phase}" == "measure" ]] || exit 0
    sfile="${artifact_dir}/benchmark/${summary}"
    if [[ ! -s "${sfile}" ]]; then
      echo "k6 summary export not found or empty: ${sfile}" >&2
      exit 1
    fi
    # k6 trend stats are floating-point ms (numeric, comparable between k6 runs,
    # NOT comparable to a wrk-duration string). Counters that never fire are
    # omitted, hence "// 0". non_2xx_3xx / transport_errors come from the
    # workload script's own counters (default.js or the lab's k6.js).
    jqd '(.metrics // {}) as $m | [
        {name:"http.requests_per_second",value:($m.http_reqs.rate // 0),unit:"request/s",source:"benchmark/k6-summary.json"},
        {name:"http.latency.p50",value:($m.http_req_duration["p(50)"]),unit:"ms",source:"benchmark/k6-summary.json"},
        {name:"http.latency.p90",value:($m.http_req_duration["p(90)"]),unit:"ms",source:"benchmark/k6-summary.json"},
        {name:"http.latency.p95",value:($m.http_req_duration["p(95)"]),unit:"ms",source:"benchmark/k6-summary.json"},
        {name:"http.latency.p99",value:($m.http_req_duration["p(99)"]),unit:"ms",source:"benchmark/k6-summary.json"},
        {name:"http.responses.non_2xx_3xx",value:($m.perflab_http_non_2xx_3xx.count // 0),unit:"response",source:"benchmark/k6-summary.json"},
        {name:"http.transport_errors",value:($m.perflab_http_transport_errors.count // 0),unit:"error",source:"benchmark/k6-summary.json"},
        {name:"http.requests.total",value:($m.http_reqs.count // 0),unit:"request",source:"benchmark/k6-summary.json"},
        {name:"http.error_rate",value:((($m.perflab_http_non_2xx_3xx.count // 0) + ($m.perflab_http_transport_errors.count // 0)) / (if ($m.http_reqs.count // 0) > 0 then $m.http_reqs.count else 1 end)),unit:"ratio",source:"benchmark/k6-summary.json"},
        {name:"http.dropped_iterations",value:($m.dropped_iterations.count // 0),unit:"iteration",source:"benchmark/k6-summary.json"}
      ]' < "${sfile}" > "${artifact_dir}/benchmark/observations.json"
    if ! jqd -e 'any(.[]; .name == "http.latency.p95" and (.value | type) == "number")' \
        < "${artifact_dir}/benchmark/observations.json" >/dev/null; then
      echo "k6 summary is missing the required numeric p95 latency" >&2
      exit 1
    fi
    ;;
  *)
    echo "Unknown phase '${phase}' (use warmup|measure|diagnostic)." >&2
    exit 1
    ;;
esac
