#!/usr/bin/env bash
# wrk load adapter -- wrk is NOT installed on the host; it runs via Docker,
# joined to the compose network, targeting the app's INTERNAL url (e.g.
# http://api:8080). k6, by contrast, runs on the host. Set PERFLAB_WRK_IMAGE in
# the descriptor to a wrk image whose entrypoint is wrk.
#   run.sh <artifact-dir> <phase>   phase = warmup | measure | diagnostic
set -euo pipefail
HARNESS_ROOT="${PERFLAB_HARNESS_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
# shellcheck disable=SC1091
source "${HARNESS_ROOT}/core/lib/common.sh"   # json_escape, compose_network, internal_base_url, wrk_image, loadgen_script

artifact_dir="${1:?run.sh <artifact-dir> <phase>}"
phase="${2:?phase required (warmup|measure|diagnostic)}"
mkdir -p "${artifact_dir}/benchmark"

[[ -n "${wrk_image}" ]] || { echo "PERFLAB_WRK_IMAGE is not set; wrk runs via Docker." >&2; exit 1; }

# The workload script is the lab's own wrk.lua if it ships one, else the shared
# default.lua. Its directory (not this adapter's) is mounted at /lab, and the
# workload values come from PERF_* passed by name so MSYS does not rewrite them.
# MSYS_NO_PATHCONV keeps the -v source (a Windows path) and /lab intact.
script="$(loadgen_script)"
script_dir="$(cd "$(dirname "${script}")" && pwd)"
script_base="$(basename "${script}")"
wrk_run() {
  MSYS_NO_PATHCONV=1 docker run --rm --network "${compose_network}" \
    -e PERF_METHOD -e PERF_PATH -e PERF_BODY -e PERF_RUN_ID -e PERF_HEADERS \
    -v "${script_dir}:/lab:ro" \
    "${wrk_image}" "$@"
}
lua="/lab/${script_base}"
url="${internal_base_url}"

case "${phase}" in
  warmup)
    wrk_run -t2 -c16 -d10s -s "${lua}" "${url}" > "${artifact_dir}/benchmark/warmup.txt"
    ;;
  measure | diagnostic)
    conns="${PERFLAB_CONNECTIONS:?PERFLAB_CONNECTIONS not set}"
    dur="${PERFLAB_DURATION_SECONDS:?PERFLAB_DURATION_SECONDS not set}"
    if [[ "${phase}" == "measure" ]]; then out="wrk.txt"; else out="diagnostic-wrk.txt"; fi
    wrk_run -t4 -c"${conns}" -d"${dur}s" --latency -s "${lua}" "${url}" \
      > "${artifact_dir}/benchmark/${out}"

    [[ "${phase}" == "measure" ]] || exit 0
    f="${artifact_dir}/benchmark/${out}"
    rps="$(awk '/Requests\/sec:/ {print $2}' "${f}" | tail -1)"; rps="${rps:-0}"
    p50="$(awk '$1 == "50%" {print $2}' "${f}" | tail -1)"
    p90="$(awk '$1 == "90%" {print $2}' "${f}" | tail -1)"
    p99="$(awk '$1 == "99%" {print $2}' "${f}" | tail -1)"
    non2xx="$(awk '/Non-2xx or 3xx responses:/ {print $5}' "${f}" | tail -1)"; non2xx="${non2xx:-0}"
    # "N requests in Ts, ..." is wrk's total line; the "Socket errors:" line
    # (connect/read/write/timeout) appears only when there ARE transport errors.
    # Emit requests.total + transport_errors + error_rate so the suite health
    # signal is load-generator-agnostic; without a total it could only guess.
    completed="$(awk '/requests in/ {print $1}' "${f}" | tail -1)"; completed="${completed:-0}"
    transport="$(awk '/Socket errors:/ {print $4 + $6 + $8 + $10}' "${f}" | tail -1)"; transport="${transport:-0}"
    # Total ATTEMPTS = completed responses + transport failures (connect/read/
    # write/timeout). Counting only completed responses made a run with zero
    # responses but many connection errors report requests.total=0 -> the suite
    # health read "unknown" instead of "degraded"; including transport makes a
    # total transport failure compute error_rate 1.0.
    total="$(awk -v c="${completed}" -v tr="${transport}" 'BEGIN { print c + tr }')"
    errrate="$(awk -v e="$((non2xx + transport))" -v t="${total}" 'BEGIN { if (t + 0 > 0) printf "%.6f", e / (t + 0); else print 0 }')"
    # wrk latency percentiles are unit-suffixed strings (e.g. "1.23ms") -> tagged
    # wrk-duration; the counts and rates are numeric.
    printf '[{"name":"http.requests_per_second","value":%s,"unit":"request/s","source":"benchmark/wrk.txt"},{"name":"http.latency.p50","value":"%s","unit":"wrk-duration","source":"benchmark/wrk.txt"},{"name":"http.latency.p90","value":"%s","unit":"wrk-duration","source":"benchmark/wrk.txt"},{"name":"http.latency.p99","value":"%s","unit":"wrk-duration","source":"benchmark/wrk.txt"},{"name":"http.responses.non_2xx_3xx","value":%s,"unit":"response","source":"benchmark/wrk.txt"},{"name":"http.transport_errors","value":%s,"unit":"error","source":"benchmark/wrk.txt"},{"name":"http.requests.total","value":%s,"unit":"request","source":"benchmark/wrk.txt"},{"name":"http.error_rate","value":%s,"unit":"ratio","source":"benchmark/wrk.txt"}]\n' \
      "${rps}" "$(json_escape "${p50:-unknown}")" "$(json_escape "${p90:-unknown}")" "$(json_escape "${p99:-unknown}")" "${non2xx}" "${transport}" "${total}" "${errrate}" \
      > "${artifact_dir}/benchmark/observations.json"
    ;;
  *)
    echo "Unknown phase '${phase}' (use warmup|measure|diagnostic)." >&2
    exit 1
    ;;
esac
