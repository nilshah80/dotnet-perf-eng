#!/usr/bin/env bash
# wrk load adapter. With PERFLAB_WRK_IMAGE set, wrk runs via Docker, joined to
# the compose network, targeting the app's INTERNAL url (e.g. http://api:8080);
# the image's entrypoint must be wrk and its architecture must match the Docker
# host. Without an image, the host's wrk binary runs against the app's published
# base_url, the same path k6 uses.
#   run.sh <artifact-dir> <phase>   phase = warmup | measure | diagnostic
set -euo pipefail
HARNESS_ROOT="${PERFLAB_HARNESS_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
# shellcheck disable=SC1091
source "${HARNESS_ROOT}/core/lib/common.sh"   # json_escape, compose_network, internal_base_url, wrk_image, loadgen_script

artifact_dir="${1:?run.sh <artifact-dir> <phase>}"
phase="${2:?phase required (warmup|measure|diagnostic)}"
# wrk.lua sends this phase as request baggage (perflab-baggage-v1, D-P1-8).
export PERF_PHASE="${phase}"
mkdir -p "${artifact_dir}/benchmark"

if [[ "${PERF_WORKLOAD_KIND:-request}" == "journey" || "${PERF_WORKLOAD_KIND:-request}" == "mix" ]]; then
  echo "capability generator.wrk.journey is unsupported; rejected before traffic" >&2
  exit 1
fi

wrk_mode="$(wrk_execution_mode)" || exit 1

# The workload script is the lab's own wrk.lua if it ships one, else the shared
# default.lua. Its directory (not this adapter's) is mounted at /lab, and the
# workload values come from PERF_* passed by name so MSYS does not rewrite them.
# MSYS_NO_PATHCONV keeps the -v source (a Windows path) and /lab intact.
script="$(loadgen_script)"
script_dir="$(cd "$(dirname "${script}")" && pwd)"
script_base="$(basename "${script}")"
if [[ "${wrk_mode}" == "host" ]]; then
  # The host binary reaches the app where k6 does: the published base_url, for a
  # local or a remote target, including host loopback.
  url="${base_url}"
  lua="${script_dir}/${script_base}"
  wrk_run() { wrk "$@"; }
else
  # Local target: join the compose network and hit the app's INTERNAL url. Remote
  # target: no compose network -- run on Docker's default bridge and hit base_url
  # (the app's external url). A host-loopback base_url (127.0.0.1) is NOT reachable
  # from inside the container, so a host-local remote target must use the host wrk
  # or k6.
  if [[ "${target_mode:-local}" == "remote" ]]; then
    network_args=()
    url="${base_url}"
    # wrk runs in a container: its 127.0.0.1 is the container's own loopback, not the
    # host, so a host-loopback remote base_url yields an all-transport-errors run. Fail
    # fast with the fix rather than emitting a misleading 100%-error result.
    case "${url}" in
      *"://127.0.0.1"*|*"://localhost"*|*"://[::1]"*)
        echo "wrk cannot reach a host-loopback remote target (${url}) from inside its container. Unset PERFLAB_WRK_IMAGE to use the host wrk, use PERFLAB_LOAD_GENERATOR=k6, or point PERFLAB_BASE_URL at a routable host." >&2
        exit 1 ;;
    esac
  else
    network_args=(--network "${compose_network}")
    url="${internal_base_url}"
  fi
  wrk_run() {
    MSYS_NO_PATHCONV=1 docker run --rm "${network_args[@]}" \
      -e PERF_METHOD -e PERF_PATH -e PERF_BODY -e PERF_RUN_ID -e PERF_PHASE -e PERF_HEADERS \
      -v "${script_dir}:/lab:ro" \
      "${wrk_image}" "$@"
  }
  lua="/lab/${script_base}"
fi

case "${phase}" in
  warmup)
    # Same bounds k6 applies: the run announces PERFLAB_WARMUP_SECONDS, so the
    # warm-up must last that long rather than a fixed 10 seconds.
    warmup_seconds="${PERFLAB_WARMUP_SECONDS:-10}"
    case "${warmup_seconds}" in
      ''|*[!0-9]*) echo "PERFLAB_WARMUP_SECONDS must be an integer number of seconds; received '${warmup_seconds}'." >&2; exit 1 ;;
    esac
    if (( warmup_seconds < 1 || warmup_seconds > 600 )); then
      echo "PERFLAB_WARMUP_SECONDS must be between 1 and 600; received '${warmup_seconds}'." >&2
      exit 1
    fi
    # The measured connection count, not a fixed 16: a warm-up hotter than the
    # measurement changes the state the measurement starts from.
    conns="${PERFLAB_CONNECTIONS:?PERFLAB_CONNECTIONS not set}"
    threads=$(( conns < 2 ? conns : 2 ))
    wrk_run -t"${threads}" -c"${conns}" -d"${warmup_seconds}s" -s "${lua}" "${url}" > "${artifact_dir}/benchmark/warmup.txt"
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
    # wrk prints unit-suffixed percentiles ("612.00us", "1.23ms", "2.10s"); they
    # are recorded in ms like every other generator. A string read as a number
    # took 612 us for 612 ms.
    wrk_ms() {
      awk -v v="$1" 'BEGIN {
        if (v ~ /us$/) printf "%.4f", v / 1000; else if (v ~ /ms$/) printf "%.4f", v + 0
        else if (v ~ /[0-9]s$/) printf "%.4f", v * 1000; else if (v ~ /[0-9]m$/) printf "%.4f", v * 60000; else print "null" }'
    }
    printf '[{"name":"http.requests_per_second","value":%s,"unit":"request/s","source":"benchmark/wrk.txt"},{"name":"http.latency.p50","value":%s,"unit":"ms","source":"benchmark/wrk.txt"},{"name":"http.latency.p90","value":%s,"unit":"ms","source":"benchmark/wrk.txt"},{"name":"http.latency.p99","value":%s,"unit":"ms","source":"benchmark/wrk.txt"},{"name":"http.responses.non_2xx_3xx","value":%s,"unit":"response","source":"benchmark/wrk.txt"},{"name":"http.transport_errors","value":%s,"unit":"error","source":"benchmark/wrk.txt"},{"name":"http.requests.total","value":%s,"unit":"request","source":"benchmark/wrk.txt"},{"name":"http.error_rate","value":%s,"unit":"ratio","source":"benchmark/wrk.txt"}]\n' \
      "${rps}" "$(wrk_ms "${p50:-}")" "$(wrk_ms "${p90:-}")" "$(wrk_ms "${p99:-}")" "${non2xx}" "${transport}" "${total}" "${errrate}" \
      > "${artifact_dir}/benchmark/observations.json"
    ;;
  *)
    echo "Unknown phase '${phase}' (use warmup|measure|diagnostic)." >&2
    exit 1
    ;;
esac
