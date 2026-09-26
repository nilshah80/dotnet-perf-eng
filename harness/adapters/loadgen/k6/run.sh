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

# k6 exports setup()'s return value as .setup_data. Ecommerce's setup() returns
# its login token, so every ecommerce package retained a live bearer JWT
# (acceptance case 26). Nothing reads it; a summary that cannot be rewritten
# fails the phase rather than keep the token.
strip_setup_data() {
  local file="$1"
  [[ -s "${file}" ]] || return 0
  if jqd 'del(.setup_data)' < "${file}" > "${file}.tmp" && [[ -s "${file}.tmp" ]]; then
    mv "${file}.tmp" "${file}"
  else
    rm -f "${file}.tmp" "${file}"
    echo "k6 summary ${file} could not be stripped of setup_data; removed it." >&2
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
# The entry script, then every local module it imports (transitively), sorted.
# Every lab script imports mix.js or journey.js, and hashing the entry alone
# kept one identity across a mix.js change that moved browse-and-buy's
# order-create share from 3.72% to 4.71%; compare-runs then called the heavier
# workload a 15% CPU regression. A script without local imports hashes as before.
workload_files() {
  local pending=("$1") seen=("$1") file dir spec target module_dir known entry
  while [[ ${#pending[@]} -gt 0 ]]; do
    file="${pending[0]}"; pending=("${pending[@]:1}")
    dir="$(dirname "${file}")"
    while IFS= read -r spec; do
      module_dir="$(cd "${dir}/$(dirname "${spec}")" 2>/dev/null && pwd)" || continue
      target="${module_dir}/$(basename "${spec}")"
      [[ -f "${target}" ]] || continue
      known=0
      for entry in "${seen[@]}"; do [[ "${entry}" == "${target}" ]] && known=1; done
      [[ "${known}" == 0 ]] || continue
      seen+=("${target}"); pending+=("${target}")
    done < <(grep -oE "(from|import)[[:space:]]*['\"]\.\.?/[^'\"]+['\"]" "${file}" | sed -E "s/^(from|import)[[:space:]]*['\"]//; s/['\"]$//")
  done
  printf '%s\n' "${seen[0]}"
  [[ ${#seen[@]} -gt 1 ]] && printf '%s\n' "${seen[@]:1}" | LC_ALL=C sort
  return 0
}
write_compatibility() {
  local script_rel workload_hash fingerprint base network timeout_seconds config_hash header_names
  script_rel="$(relative_to_repo "${js}")"
  workload_hash="$(while IFS= read -r file; do
      printf '%s\0' "$(relative_to_repo "${file}")"; cat "${file}"; printf '\0'
    done < <(workload_files "${js}") | sha256_stream)"
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
    if [[ "${PERF_PROTOCOL:-}" == "browser-synthetic" ]]; then
      source "${HARNESS_ROOT}/adapters/loadgen/k6/profiles.sh"
      cfg="${artifact_dir}/benchmark/k6-browser-warmup.json"
      k6_write_profile_config steady 1 "${warmup_seconds}" "${cfg}"
      k6 run --config "${cfg}" \
        --summary-export "${artifact_dir}/benchmark/k6-warmup.json" \
        --quiet --no-color "${js}" \
        > "${artifact_dir}/benchmark/k6-warmup.txt"
    else
      k6 run --vus 16 --duration "${warmup_seconds}s" \
        --summary-export "${artifact_dir}/benchmark/k6-warmup.json" \
        --quiet --no-color "${js}" \
        > "${artifact_dir}/benchmark/k6-warmup.txt"
    fi
    strip_setup_data "${artifact_dir}/benchmark/k6-warmup.json"
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

    generator_rc=0
    if [[ "${phase}" == "measure" && ( "${profile}" != "steady" || "${PERF_PROTOCOL:-}" == "browser-synthetic" ) ]]; then
      # shellcheck disable=SC1091
      source "${HARNESS_ROOT}/adapters/loadgen/k6/profiles.sh"
      cfg="${artifact_dir}/benchmark/k6-profile.json"
      k6_write_profile_config "${profile}" "${conns}" "${dur}" "${cfg}"
      echo "Load profile: ${profile} (executor recorded in benchmark/k6-profile.json)"
      k6 run --config "${cfg}" \
        --summary-trend-stats "avg,min,med,max,p(50),p(90),p(95),p(99)" \
        --summary-export "${artifact_dir}/benchmark/${summary}" \
        ${K6_RW_OUT[@]+"${K6_RW_OUT[@]}"} \
        --quiet --no-color "${js}" \
        > "${artifact_dir}/benchmark/${txt}" || generator_rc=$?
    else
      k6 run --vus "${conns}" --duration "${dur}s" \
        --summary-trend-stats "avg,min,med,max,p(50),p(90),p(95),p(99)" \
        --summary-export "${artifact_dir}/benchmark/${summary}" \
        ${K6_RW_OUT[@]+"${K6_RW_OUT[@]}"} \
        --quiet --no-color "${js}" \
        > "${artifact_dir}/benchmark/${txt}" || generator_rc=$?
    fi
    strip_setup_data "${artifact_dir}/benchmark/${summary}"

    write_compatibility
    [[ "${phase}" == "measure" ]] || exit "${generator_rc}"
    sfile="${artifact_dir}/benchmark/${summary}"
    if [[ ! -s "${sfile}" ]]; then
      echo "k6 summary export not found or empty: ${sfile}" >&2
      exit 1
    fi
    # Journey summaries use measured child requests. Protocol and browser
    # workloads use one completed k6 iteration as their operation unit and the
    # protocol-specific latency trend (falling back to iteration duration).
    # Single-request workloads prefer project-owned primary-request metrics so
    # setup/teardown traffic never contaminates measured counts or latency.
    jqd --arg workloadKind "${PERF_WORKLOAD_KIND:-request}" --arg protocol "${PERF_PROTOCOL:-}" '(.metrics // {}) as $m |
      ($m.journey_starts.count // 0) as $starts |
      ($workloadKind == "protocol") as $is_protocol |
      (if $starts > 0 then ($m.journey_wire_requests.count // 0)
       elif $is_protocol then ($m.iterations.count // 0)
       else ($m.perflab_primary_requests.count // $m.http_reqs.count // 0) end) as $requests |
      (if $starts > 0 then ($m.journey_wire_requests.rate // 0)
       elif $is_protocol then ($m.iterations.rate // 0)
       else ($m.perflab_primary_requests.rate // $m.http_reqs.rate // 0) end) as $rate |
      (if $starts > 0 then $m.journey_wire_latency
       elif $is_protocol then ($m.grpc_req_duration // $m.ws_session_duration // $m.browser_http_req_duration // $m.iteration_duration)
       else ($m.perflab_primary_request_latency // $m.http_req_duration) end) as $latency |
      (if $starts > 0 then ($m.journey_status_errors.count // 0)
       elif $is_protocol then ($m.perflab_http_non_2xx_3xx.count // $m.protocol_failures.count // $m.browser_http_req_failed.passes // 0)
       else ($m.perflab_http_non_2xx_3xx.count // 0) end) as $status_errors |
      (if $starts > 0 then ($m.journey_transport_errors.count // 0)
       elif $is_protocol then ($m.perflab_http_transport_errors.count // 0)
       else ($m.perflab_http_transport_errors.count // 0) end) as $transport_errors |
      [
        {name:"http.requests_per_second",value:$rate,unit:"request/s",source:"benchmark/k6-summary.json"},
        {name:"http.latency.p50",value:($latency["p(50)"]),unit:"ms",source:"benchmark/k6-summary.json"},
        {name:"http.latency.p90",value:($latency["p(90)"]),unit:"ms",source:"benchmark/k6-summary.json"},
        {name:"http.latency.p95",value:($latency["p(95)"]),unit:"ms",source:"benchmark/k6-summary.json"},
        {name:"http.latency.p99",value:($latency["p(99)"]),unit:"ms",source:"benchmark/k6-summary.json"},
        {name:"http.responses.non_2xx_3xx",value:$status_errors,unit:"response",source:"benchmark/k6-summary.json"},
        {name:"http.transport_errors",value:$transport_errors,unit:"error",source:"benchmark/k6-summary.json"},
        {name:"http.requests.total",value:$requests,unit:"request",source:"benchmark/k6-summary.json"},
        {name:"http.error_rate",value:(($status_errors + $transport_errors) / (if $requests > 0 then $requests else 1 end)),unit:"ratio",source:"benchmark/k6-summary.json"},
        {name:"http.dropped_iterations",value:($m.dropped_iterations.count // 0),unit:"iteration",source:"benchmark/k6-summary.json"},
        {name:"journey.starts",value:$starts,unit:"iteration",source:"benchmark/k6-summary.json"},
        {name:"journey.completed",value:($m.journey_completed.count // 0),unit:"iteration",source:"benchmark/k6-summary.json"},
        {name:"journey.failed",value:(($m.journey_failed.count // 0) + ($m.journey_failures.count // 0)),unit:"iteration",source:"benchmark/k6-summary.json"},
        {name:"journey.aborted",value:($m.journey_aborted.count // 0),unit:"iteration",source:"benchmark/k6-summary.json"},
        {name:"journey.child_ops",value:($m.journey_child_ops.count // 0),unit:"operation",source:"benchmark/k6-summary.json"},
        {name:"journey.wire_requests",value:($m.journey_wire_requests.count // 0),unit:"request",source:"benchmark/k6-summary.json"},
        {name:"journey.retries",value:($m.journey_retries.count // 0),unit:"request",source:"benchmark/k6-summary.json"},
        {name:"journey.request_amplification",value:(($m.journey_wire_requests.count // 0) / (if $starts > 0 then $starts else 1 end)),unit:"request/iteration",source:"benchmark/k6-summary.json"},
        {name:"journey.duration.p95",value:($m.journey_duration["p(95)"] // 0),unit:"ms",source:"benchmark/k6-summary.json"}
      ] | if $protocol == "browser-synthetic" then
        (($m.browser_http_req_failed.passes // 0) + ($m.browser_http_req_failed.fails // 0)) as $browser_requests |
        (($m.iterations.count // 0) / (if ($m.iterations.rate // 0) > 0 then $m.iterations.rate else 1 end)) as $elapsed |
        map(select((.name | startswith("http.")) and .name != "http.transport_errors") |
          .name = ("browser." + .name) |
          if .name == "browser.http.requests.total" then .value = $browser_requests
          elif .name == "browser.http.requests_per_second" then .value = (if $elapsed > 0 then $browser_requests / $elapsed else 0 end)
          elif .name == "browser.http.responses.non_2xx_3xx" then .name = "browser.http.requests.failed"
          elif .name == "browser.http.error_rate" then .value = (if $browser_requests > 0 then ($m.browser_http_req_failed.passes // 0) / $browser_requests else 0 end)
          else . end) + [
          {name:"browser.visits.total",value:($m.iterations.count // 0),unit:"visit",source:"benchmark/k6-summary.json"},
          {name:"browser.visits_per_second",value:($m.iterations.rate // 0),unit:"visit/s",source:"benchmark/k6-summary.json"},
          {name:"browser.visit.duration.p95",value:$m.iteration_duration["p(95)"],unit:"ms",source:"benchmark/k6-summary.json"},
          {name:"browser.checks.failed",value:($m.checks.fails // 0),unit:"check",source:"benchmark/k6-summary.json"},
          {name:"browser.web_vital.fcp.p95",value:$m.browser_web_vital_fcp["p(95)"],unit:"ms",source:"benchmark/k6-summary.json"},
          {name:"browser.web_vital.lcp.p95",value:$m.browser_web_vital_lcp["p(95)"],unit:"ms",source:"benchmark/k6-summary.json"}
        ] | map(select(.value != null))
      else . end' < "${sfile}" > "${artifact_dir}/benchmark/observations.json"
    if ! jqd -e 'any(.[]; (.name == "http.latency.p95" or .name == "browser.http.latency.p95") and (.value | type) == "number")' \
        < "${artifact_dir}/benchmark/observations.json" >/dev/null; then
      echo "k6 summary is missing the required numeric p95 latency" >&2
      exit 1
    fi
    if ! jqd -e '(.metrics // {}) as $m |
        ($m.journey_starts.count // 0) as $starts |
        ($m.journey_completed.count // 0) as $completed |
        (($m.journey_failed.count // 0) + ($m.journey_failures.count // 0)) as $failed |
        ($m.journey_aborted.count // 0) as $aborted |
        ($m.journey_child_ops.count // 0) as $children |
        ($m.journey_wire_requests.count // 0) as $wire |
        $starts == 0 or ($starts == ($completed + $failed + $aborted) and $wire >= $children)' \
        < "${sfile}" >/dev/null; then
      echo "k6 journey evidence is incomplete or cannot be reconciled" >&2
      exit 1
    fi
    exit "${generator_rc}"
    ;;
  *)
    echo "Unknown phase '${phase}' (use warmup|measure|diagnostic)." >&2
    exit 1
    ;;
esac
