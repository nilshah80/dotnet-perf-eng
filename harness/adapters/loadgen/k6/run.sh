#!/usr/bin/env bash
# k6 load adapter -- single entry point for every phase.
#   run.sh <artifact-dir> <phase>   phase = warmup | measure | diagnostic
# For the "measure" phase it writes benchmark/observations.json from k6's nested
# summary JSON, parsed with dockerized jq (jqd).
set -euo pipefail
HARNESS_ROOT="${PERFLAB_HARNESS_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
# shellcheck disable=SC1091
source "${HARNESS_ROOT}/core/lib/common.sh"   # jqd
adapter_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

artifact_dir="${1:?run.sh <artifact-dir> <phase>}"
phase="${2:?phase required (warmup|measure|diagnostic)}"
mkdir -p "${artifact_dir}/benchmark"
js="${adapter_dir}/scenario.js"

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
    if [[ "${phase}" == "measure" ]]; then
      summary="k6-summary.json"; txt="k6.txt"
    else
      summary="diagnostic-k6-summary.json"; txt="diagnostic-k6.txt"
    fi
    k6 run --vus "${conns}" --duration "${dur}s" \
      --summary-export "${artifact_dir}/benchmark/${summary}" \
      --quiet --no-color "${js}" \
      > "${artifact_dir}/benchmark/${txt}"

    [[ "${phase}" == "measure" ]] || exit 0
    sfile="${artifact_dir}/benchmark/${summary}"
    if [[ ! -s "${sfile}" ]]; then
      echo "k6 summary export not found or empty: ${sfile}" >&2
      exit 1
    fi
    # k6 trend stats are floating-point ms (numeric, comparable between k6 runs,
    # NOT comparable to a wrk-duration string). Counters that never fire are
    # omitted, hence "// 0". non_2xx_3xx / transport_errors come from the lab's
    # own counters in scenario.js.
    jqd '(.metrics // {}) as $m | [
        {name:"http.requests_per_second",value:($m.http_reqs.rate // 0),unit:"request/s",source:"benchmark/k6-summary.json"},
        {name:"http.latency.p50",value:($m.http_req_duration["p(50)"]),unit:"ms",source:"benchmark/k6-summary.json"},
        {name:"http.latency.p90",value:($m.http_req_duration["p(90)"]),unit:"ms",source:"benchmark/k6-summary.json"},
        {name:"http.latency.p99",value:($m.http_req_duration["p(99)"]),unit:"ms",source:"benchmark/k6-summary.json"},
        {name:"http.responses.non_2xx_3xx",value:($m.perflab_http_non_2xx_3xx.count // 0),unit:"response",source:"benchmark/k6-summary.json"},
        {name:"http.transport_errors",value:($m.perflab_http_transport_errors.count // 0),unit:"error",source:"benchmark/k6-summary.json"},
        {name:"http.requests.total",value:($m.http_reqs.count // 0),unit:"request",source:"benchmark/k6-summary.json"}
      ]' < "${sfile}" > "${artifact_dir}/benchmark/observations.json"
    ;;
  *)
    echo "Unknown phase '${phase}' (use warmup|measure|diagnostic)." >&2
    exit 1
    ;;
esac
