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
    k6 run --vus 16 --duration 10s \
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
        "${K6_RW_OUT[@]}" \
        --quiet --no-color "${js}" \
        > "${artifact_dir}/benchmark/${txt}"
    else
      k6 run --vus "${conns}" --duration "${dur}s" \
        --summary-export "${artifact_dir}/benchmark/${summary}" \
        "${K6_RW_OUT[@]}" \
        --quiet --no-color "${js}" \
        > "${artifact_dir}/benchmark/${txt}"
    fi

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
        {name:"http.latency.p99",value:($m.http_req_duration["p(99)"]),unit:"ms",source:"benchmark/k6-summary.json"},
        {name:"http.responses.non_2xx_3xx",value:($m.perflab_http_non_2xx_3xx.count // 0),unit:"response",source:"benchmark/k6-summary.json"},
        {name:"http.transport_errors",value:($m.perflab_http_transport_errors.count // 0),unit:"error",source:"benchmark/k6-summary.json"},
        {name:"http.requests.total",value:($m.http_reqs.count // 0),unit:"request",source:"benchmark/k6-summary.json"},
        {name:"http.error_rate",value:((($m.perflab_http_non_2xx_3xx.count // 0) + ($m.perflab_http_transport_errors.count // 0)) / (if ($m.http_reqs.count // 0) > 0 then $m.http_reqs.count else 1 end)),unit:"ratio",source:"benchmark/k6-summary.json"},
        {name:"http.dropped_iterations",value:($m.dropped_iterations.count // 0),unit:"iteration",source:"benchmark/k6-summary.json"}
      ]' < "${sfile}" > "${artifact_dir}/benchmark/observations.json"
    ;;
  *)
    echo "Unknown phase '${phase}' (use warmup|measure|diagnostic)." >&2
    exit 1
    ;;
esac
