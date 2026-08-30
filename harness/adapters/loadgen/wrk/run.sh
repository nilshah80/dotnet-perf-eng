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
    # wrk latency percentiles are unit-suffixed strings (e.g. "1.23ms") -> tagged
    # wrk-duration; rps/non2xx are numeric.
    printf '[{"name":"http.requests_per_second","value":%s,"unit":"request/s","source":"benchmark/wrk.txt"},{"name":"http.latency.p50","value":"%s","unit":"wrk-duration","source":"benchmark/wrk.txt"},{"name":"http.latency.p90","value":"%s","unit":"wrk-duration","source":"benchmark/wrk.txt"},{"name":"http.latency.p99","value":"%s","unit":"wrk-duration","source":"benchmark/wrk.txt"},{"name":"http.responses.non_2xx_3xx","value":%s,"unit":"response","source":"benchmark/wrk.txt"}]\n' \
      "${rps}" "$(json_escape "${p50:-unknown}")" "$(json_escape "${p90:-unknown}")" "$(json_escape "${p99:-unknown}")" "${non2xx}" \
      > "${artifact_dir}/benchmark/observations.json"
    ;;
  *)
    echo "Unknown phase '${phase}' (use warmup|measure|diagnostic)." >&2
    exit 1
    ;;
esac
