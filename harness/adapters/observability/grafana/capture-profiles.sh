#!/usr/bin/env bash
# Grafana/Pyroscope profile capture for the native evidence package.
# Sourced by capture-evidence.sh so provider-specific /pyroscope/render logic
# stays in the observability adapter rather than the core capture script.
#
# Required globals (from lab-context + capture-evidence): artifact_dir,
# continuous_profiling, capture_telemetry, pyroscope_url, pyroscope_services,
# pyroscope_required_services, start_epoch, end_epoch, telemetry_run_id,
# target_mode, json_escape, jqd.

PYROSCOPE_PROFILE_TYPE="${PYROSCOPE_PROFILE_TYPE:-process_cpu:cpu:nanoseconds:cpu:nanoseconds}"
PYROSCOPE_MAX_NODES="${PYROSCOPE_MAX_NODES:-16384}"
PYROSCOPE_CAPTURE_ATTEMPTS="${PYROSCOPE_CAPTURE_ATTEMPTS:-6}"
PYROSCOPE_CAPTURE_SLEEP="${PYROSCOPE_CAPTURE_SLEEP:-5}"

pyroscope_record_endpoint() {
  printf '%s' "${1:-}" | sed -E 's#(https?://)[^/@]+@#\1#'
}

pyroscope_service_required() {
  local service="$1" required
  for required in ${pyroscope_required_services}; do
    [[ "${required}" == "${service}" ]] && return 0
  done
  return 1
}

pyroscope_query_selector() {
  local service="$1"
  if [[ "${target_mode}" == "local" ]]; then
    printf '%s{service_name="%s",perf_run_id="%s"}' "${PYROSCOPE_PROFILE_TYPE}" "${service}" "${telemetry_run_id}"
  else
    printf '%s{service_name="%s"}' "${PYROSCOPE_PROFILE_TYPE}" "${service}"
  fi
}

pyroscope_profile_stats() {
  local file="$1" stats
  stats="$(jqd -r '[((.flamebearer.names // []) | length), ((.flamebearer.levels // []) | length)] | @tsv' < "${file}" 2>/dev/null || true)"
  if [[ "${stats}" =~ ^[0-9]+[$'\t'][0-9]+$ ]]; then
    printf '%s\n' "${stats}"
  else
    printf '0\t0\n'
  fi
}

# Frames the profiler could not resolve are emitted as Unknown-Type.Unknown-Method
# (or empty / raw addresses). Ignoring the synthetic "total" root, report how
# many frame names are real symbols so an all-unknown flame graph is never
# advertised as symbolized evidence.
pyroscope_symbolized_names() {
  jqd -r '[(.flamebearer.names // [])[] | ascii_downcase | ltrimstr(" ") | select(. != "total" and . != "" and (startswith("unknown") | not) and (startswith("0x") | not))] | length' \
    < "$1" 2>/dev/null || printf '0\n'
}

# One readiness probe per capture; recorded in query.json so an "unreachable"
# result distinguishes a down backend from a rejected query.
pyroscope_probe_ready() {
  if curl -fsS --max-time 10 "${pyroscope_url%/}/ready" >/dev/null 2>&1; then
    pyroscope_ready=true
  else
    pyroscope_ready=false
  fi
}

# Query one service. Sets: pyroscope_last_state, pyroscope_last_reason,
# pyroscope_last_nodes, pyroscope_last_attempts, pyroscope_last_reachable,
# pyroscope_last_http.
pyroscope_query_service() {
  local service="$1"
  local selector file attempt reachable=0 names=0 levels=0 http_code=""
  selector="$(pyroscope_query_selector "${service}")"
  file="${artifact_dir}/telemetry/profiles/${service}-cpu.json"
  : > "${file}"
  pyroscope_last_state="missing"
  pyroscope_last_reason="Pyroscope was unreachable"
  pyroscope_last_nodes=0
  pyroscope_last_attempts=0
  pyroscope_last_reachable=0
  pyroscope_last_http=""
  pyroscope_last_symbolized=0
  pyroscope_last_symbolization="unknown"
  for attempt in $(seq 1 "${PYROSCOPE_CAPTURE_ATTEMPTS}"); do
    pyroscope_last_attempts="${attempt}"
    # No -f: a 4xx/5xx is a REACHABLE backend rejecting the query, which must be
    # reported as such (with the status) rather than as "unreachable".
    http_code="$(curl -sS --max-time 20 --get -o "${file}.tmp" -w '%{http_code}'         --data-urlencode "query=${selector}"         --data-urlencode "from=${start_epoch}"         --data-urlencode "until=${end_epoch}"         --data-urlencode "format=json"         --data-urlencode "maxNodes=${PYROSCOPE_MAX_NODES}"         "${pyroscope_url%/}/pyroscope/render" 2>/dev/null || true)"
    case "${http_code}" in
      2[0-9][0-9])
        reachable=1
        pyroscope_last_http="${http_code}"
        mv "${file}.tmp" "${file}"
        names=0; levels=0
        IFS=$'\t' read -r names levels < <(pyroscope_profile_stats "${file}") || true
        [[ "${names}" =~ ^[0-9]+$ ]] || names=0
        [[ "${levels}" =~ ^[0-9]+$ ]] || levels=0
        # A reachable empty window is a flamebearer with only the synthetic
        # "total" node. That is not captured content.
        if [[ "${names}" -gt 1 && "${levels}" -gt 0 ]]; then
          break
        fi
        ;;
      ""|000)
        rm -f "${file}.tmp"
        ;;
      *)
        reachable=1
        pyroscope_last_http="${http_code}"
        # Keep the error body for provenance; it is not a flamebearer.
        mv "${file}.tmp" "${file}"
        ;;
    esac
    if [[ "${attempt}" -lt "${PYROSCOPE_CAPTURE_ATTEMPTS}" && "${PYROSCOPE_CAPTURE_SLEEP}" != "0" ]]; then
      sleep "${PYROSCOPE_CAPTURE_SLEEP}"
    fi
  done
  pyroscope_last_reachable="${reachable}"
  pyroscope_last_nodes="${names:-0}"
  if [[ "${reachable}" -eq 0 ]]; then
    pyroscope_last_state="missing"
    pyroscope_last_reason="Pyroscope unreachable at ${pyroscope_url} after ${pyroscope_last_attempts} attempt(s) (ready=${pyroscope_ready:-unknown})"
    return 0
  fi
  case "${pyroscope_last_http}" in
    2[0-9][0-9]) : ;;
    *)
      pyroscope_last_state="missing"
      pyroscope_last_reason="Pyroscope returned HTTP ${pyroscope_last_http} for ${service} (selector rejected or backend error)"
      return 0
      ;;
  esac
  if ! jqd -e '.flamebearer and (.flamebearer.names | type=="array") and (.flamebearer.levels | type=="array")' \
      < "${file}" >/dev/null 2>&1; then
    pyroscope_last_state="missing"
    pyroscope_last_reason="Pyroscope returned an invalid flamebearer response for ${service}"
    return 0
  fi
  if [[ "${pyroscope_last_nodes}" -le 1 || "${levels:-0}" -le 0 ]]; then
    pyroscope_last_state="delayed"
    pyroscope_last_reason="Pyroscope returned no CPU samples for ${service} in the measurement window"
    return 0
  fi
  pyroscope_last_symbolized="$(pyroscope_symbolized_names "${file}")"
  [[ "${pyroscope_last_symbolized}" =~ ^[0-9]+$ ]] || pyroscope_last_symbolized=0
  # Every .NET profile carries a small residue of native runtime frames the
  # profiler cannot name; only a material (>5%) unknown share is "partial".
  local frames unknown_frames
  frames=$((pyroscope_last_nodes - 1))
  unknown_frames=$((frames - pyroscope_last_symbolized))
  if [[ "${pyroscope_last_symbolized}" -eq 0 ]]; then
    pyroscope_last_symbolization="unknown"
  elif [[ $((unknown_frames * 20)) -gt "${frames}" ]]; then
    pyroscope_last_symbolization="partial"
  else
    pyroscope_last_symbolization="symbolized"
  fi
  if [[ "${pyroscope_last_nodes}" -ge "${PYROSCOPE_MAX_NODES}" ]]; then
    pyroscope_last_state="truncated"
    pyroscope_last_reason="Pyroscope flame graph reached the ${PYROSCOPE_MAX_NODES}-node limit"
    return 0
  fi
  pyroscope_last_state="captured"
  pyroscope_last_reason=""
  if [[ "${pyroscope_last_symbolization}" == "unknown" ]]; then
    pyroscope_last_reason="profile contains no symbolized frames (only Unknown-Type.Unknown-Method); samples exist but cannot be attributed to code"
  fi
}

pyroscope_write_not_applicable() {
  printf '%s\n' '{"captureState":"not-applicable","enabled":false,"reason":"continuous CPU profiling is disabled","files":0,"services":[]}' \
    > "${artifact_dir}/telemetry/profiles-signal.json"
}

# Writes telemetry/profiles/* and telemetry/profiles-signal.json. Sets
# profiles_incomplete=1 when a required service is missing or delayed.
pyroscope_capture_profiles() {
  profiles_incomplete=0
  telemetry_profiles_state="not-applicable"
  if [[ "${capture_telemetry}" != "1" || "${continuous_profiling}" != "1" ]]; then
    mkdir -p "${artifact_dir}/telemetry"
    pyroscope_write_not_applicable
    return 0
  fi
  mkdir -p "${artifact_dir}/telemetry/profiles"
  local service selector start_utc end_utc endpoint overall="captured" required_failed=0 files=0
  local services_json="" service_json
  start_utc="$(date -u -r "${start_epoch}" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@${start_epoch}" +%Y-%m-%dT%H:%M:%SZ)"
  end_utc="$(date -u -r "${end_epoch}" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@${end_epoch}" +%Y-%m-%dT%H:%M:%SZ)"
  endpoint="$(pyroscope_record_endpoint "${pyroscope_url}")"
  if [[ "${target_mode}" == "remote" ]]; then
    echo "Remote-observed: reading Pyroscope scoped by the measurement window ${start_epoch}-${end_epoch} (NOT run-id isolated; other traffic in the window is included)." >&2
  fi
  if [[ -z "${pyroscope_url}" ]]; then
    echo "WARNING: continuous profiling is enabled but PERFLAB_PYROSCOPE_URL is empty; profiles are MISSING." >&2
    printf '%s\n' '{"captureState":"missing","enabled":true,"reason":"Pyroscope endpoint is empty","files":0,"services":[]}' \
      > "${artifact_dir}/telemetry/profiles-signal.json"
    profiles_incomplete=1
    telemetry_profiles_state="missing"
    return 0
  fi
  if [[ -z "${pyroscope_services}" ]]; then
    echo "WARNING: continuous profiling is enabled but PERFLAB_PYROSCOPE_SERVICES is empty; profiles are MISSING." >&2
    printf '%s\n' '{"captureState":"missing","enabled":true,"reason":"no Pyroscope services configured","files":0,"services":[]}' \
      > "${artifact_dir}/telemetry/profiles-signal.json"
    profiles_incomplete=1
    telemetry_profiles_state="missing"
    return 0
  fi
  pyroscope_ready=false
  pyroscope_probe_ready
  for service in ${pyroscope_services}; do
    pyroscope_query_service "${service}"
    files=$((files + 1))
    selector="$(pyroscope_query_selector "${service}")"
    if [[ "${pyroscope_last_state}" == "captured" || "${pyroscope_last_state}" == "truncated" ]] && [[ "${pyroscope_last_symbolization}" != "symbolized" ]]; then
      echo "WARNING: Pyroscope profile for ${service} is ${pyroscope_last_symbolization} (${pyroscope_last_symbolized} symbolized of ${pyroscope_last_nodes} frames). On aarch64 hosts pyroscope-dotnet 1.5.1 is an unsupported build that loses every frame of tiered-up (re-jitted) methods; the lab entrypoint disables tiered compilation there unless PERFLAB_PROFILING_KEEP_TIERING=1 was set. Check the profile's dotnet_tiered_compilation label." >&2
    fi
    service_json="$(printf '{"service":"%s","captureState":"%s","reason":"%s","nodes":%s,"symbolizedNodes":%s,"symbolization":"%s","truncated":%s,"required":%s,"attempts":%s,"httpStatus":"%s","selector":"%s"}' \
      "$(json_escape "${service}")" "$(json_escape "${pyroscope_last_state}")" "$(json_escape "${pyroscope_last_reason}")" \
      "${pyroscope_last_nodes}" "${pyroscope_last_symbolized}" "$(json_escape "${pyroscope_last_symbolization}")" \
      "$([[ "${pyroscope_last_state}" == "truncated" ]] && echo true || echo false)" \
      "$(pyroscope_service_required "${service}" && echo true || echo false)" \
      "${pyroscope_last_attempts}" "$(json_escape "${pyroscope_last_http}")" "$(json_escape "${selector}")")"
    if [[ -n "${services_json}" ]]; then
      services_json="${services_json},"
    fi
    services_json="${services_json}${service_json}"
    # The signal state follows the REQUIRED services. An optional service that
    # was legitimately idle (delayed/missing) is recorded per service and must
    # not degrade an otherwise captured profile signal; truncation is content
    # and is surfaced regardless of requirement.
    if [[ "${pyroscope_last_state}" == "truncated" && "${overall}" == "captured" ]]; then
      overall="truncated"
    fi
    if pyroscope_service_required "${service}"; then
      case "${pyroscope_last_state}" in
        delayed)
          [[ "${overall}" == "captured" || "${overall}" == "truncated" ]] && overall="delayed"
          ;;
        missing)
          overall="missing"
          ;;
      esac
    fi
    if pyroscope_service_required "${service}"; then
      case "${pyroscope_last_state}" in
        captured|truncated) : ;;
        *)
          echo "WARNING: required Pyroscope profile for ${service} is ${pyroscope_last_state}; this evidence package is INCOMPLETE." >&2
          required_failed=1
          ;;
      esac
    else
      echo "NOTE: optional Pyroscope profile for ${service} is ${pyroscope_last_state}." >&2
    fi
  done
  if [[ "${required_failed}" -eq 1 ]]; then
    profiles_incomplete=1
    if [[ "${overall}" == "captured" || "${overall}" == "truncated" ]]; then
      overall="partial"
    fi
  fi
  if [[ -z "${pyroscope_required_services}" ]]; then
    # With no required service the signal is best-effort: report the weakest
    # observed state so an all-idle window is not advertised as captured.
    local weakest="captured" st
    for st in $(printf '%s\n' "${services_json}" | tr ',' '\n' | sed -n 's/.*"captureState":"\([a-z-]*\)".*/\1/p'); do
      case "${st}" in
        missing) weakest="missing" ;;
        delayed) [[ "${weakest}" != "missing" ]] && weakest="delayed" ;;
      esac
    done
    [[ "${weakest}" != "captured" ]] && overall="${weakest}"
  fi
  telemetry_profiles_state="${overall}"
  printf '{"schemaVersion":"pyroscope-query-v1","endpoint":"%s","ready":%s,"profileType":"%s","maxNodes":%s,"startEpoch":%s,"endEpoch":%s,"startUtc":"%s","endUtc":"%s","windowScoped":%s,"attemptsPerService":%s,"services":[%s]}\n' \
    "$(json_escape "${endpoint}")" "${pyroscope_ready}" "$(json_escape "${PYROSCOPE_PROFILE_TYPE}")" "${PYROSCOPE_MAX_NODES}" \
    "${start_epoch}" "${end_epoch}" "$(json_escape "${start_utc}")" "$(json_escape "${end_utc}")" \
    "$([[ "${target_mode}" == "remote" ]] && echo true || echo false)" \
    "${PYROSCOPE_CAPTURE_ATTEMPTS}" "${services_json}" \
    > "${artifact_dir}/telemetry/profiles/query.json"
  printf '{"captureState":"%s","enabled":true,"files":%s,"profileType":"%s","maxNodes":%s,"windowScoped":%s,"truncated":%s,"services":[%s]}\n' \
    "$(json_escape "${overall}")" "${files}" "$(json_escape "${PYROSCOPE_PROFILE_TYPE}")" "${PYROSCOPE_MAX_NODES}" \
    "$([[ "${target_mode}" == "remote" ]] && echo true || echo false)" \
    "$([[ "${overall}" == "truncated" ]] && echo true || echo false)" \
    "${services_json}" \
    > "${artifact_dir}/telemetry/profiles-signal.json"
}
