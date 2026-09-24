#!/usr/bin/env bash
# Capture telemetry + dependency evidence for a measured run and write facts.json.
# Runtime-neutral: runtime metric names come from the adapter's metrics.sh,
# dependency snapshots from dependency adapters, and the load generator's numbers
# from benchmark/observations.json. Foreign JSON (Prometheus/Tempo/Loki) is
# parsed with dockerized jq (jqd) or grep; facts.json is emitted with printf.
set -euo pipefail
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/common.sh"
# performance.sh carries the selector validators used below. It is sourced here
# rather than assumed present: the cardinality guard called a function this file
# never had in scope, so every run died at the first metric role.
# shellcheck disable=SC1091
source "${harness_core_dir}/lib/performance.sh"

artifact_dir="${1:?Usage: capture-evidence.sh <artifact-directory>}"
manifest="${artifact_dir}/manifest.json"
[[ -f "${manifest}" ]] || { echo "Manifest not found: ${manifest}" >&2; exit 1; }

# lab-context (from PERFLAB_TARGET + the remote-tier env) already resolved these;
# capture what the ACTIVE config is before the manifest read below overwrites them.
env_target_mode="${target_mode}"
env_remote_telemetry="${remote_telemetry}"
env_remote_correlation="${remote_correlation:-0}"
env_continuous_profiling="${continuous_profiling:-0}"

# Read the manifest fields we need in one jqd call (standalone-safe). The recorded
# target/remoteTelemetry say what the run actually WAS and gate the backend captures.
read_fields 23 < <(
  jqd -r '[.runId,(.telemetryRunId//.runId),.scenarioId,(.workload.loadGenerator//"wrk"),(.startedEpoch//0),(.target//"local"),(.remoteTelemetry // false),(.continuousProfiling // false),(.profilingKeepTiering // false),(.measurementStartedEpoch // 0),(.measurementEndedEpoch // 0),(.status // ""),
    # (.faultApplied // "") would map a persisted `false` to "" (jq // treats false
    # like null), defeating the explicit fault-outcome guard; has() distinguishes an
    # absent key ("") from a real false ("false").
    (if has("faultApplied") then (.faultApplied|tostring) else "" end),(if has("faultRestored") then (.faultRestored|tostring) else "" end),
    (.remoteCorrelation.enabled // false),(.remoteCorrelation.verified // false),(.remoteCorrelation.version // ""),(.remoteCorrelation.header // ""),
    (.remoteCorrelation.responseRunIdField // ""),(.remoteCorrelation.responseVersionField // ""),(.remoteCorrelation.prometheusLabel // ""),
    (.remoteCorrelation.lokiLabel // ""),(.remoteCorrelation.tempoAttribute // "")] | .[] | tostring' < "${manifest}") || exit 1
run_id="${TSV_FIELDS[0]}"; telemetry_run_id="${TSV_FIELDS[1]}"; scenario_id="${TSV_FIELDS[2]}"
load_gen="${TSV_FIELDS[3]}"; manifest_start_epoch="${TSV_FIELDS[4]}"; manifest_target="${TSV_FIELDS[5]}"
manifest_rt="${TSV_FIELDS[6]}"; manifest_cp="${TSV_FIELDS[7]}"; manifest_keep="${TSV_FIELDS[8]}"
manifest_meas_start="${TSV_FIELDS[9]}"; manifest_meas_end="${TSV_FIELDS[10]}"
manifest_prior_status="${TSV_FIELDS[11]}"; manifest_fault_applied="${TSV_FIELDS[12]}"
manifest_fault_restored="${TSV_FIELDS[13]}"
manifest_rc="${TSV_FIELDS[14]}"; manifest_rc_verified="${TSV_FIELDS[15]}"
manifest_rc_version="${TSV_FIELDS[16]}"; manifest_rc_header="${TSV_FIELDS[17]}"
manifest_rc_run_field="${TSV_FIELDS[18]}"; manifest_rc_version_field="${TSV_FIELDS[19]}"
manifest_rc_prom_label="${TSV_FIELDS[20]}"; manifest_rc_loki_label="${TSV_FIELDS[21]}"
manifest_rc_tempo_attr="${TSV_FIELDS[22]}"
manifest_target="${manifest_target:-local}"
[[ "${manifest_rt}" == "true" ]] && manifest_rt=1 || manifest_rt=0
[[ "${manifest_cp}" == "true" ]] && manifest_cp=1 || manifest_cp=0
[[ "${manifest_keep}" == "true" ]] && manifest_keep=1 || manifest_keep=0
[[ "${manifest_rc}" == "true" ]] && manifest_rc=1 || manifest_rc=0
[[ "${manifest_rc_verified}" == "true" ]] && manifest_rc_verified=1 || manifest_rc_verified=0

# Standalone-recapture guard: the package records what it WAS; the ACTIVE lab/env
# must match, because the backend URLs come from the env and default to localhost.
# run-scenario always calls us with a matching env; a manual re-run must re-supply it
# (matching lab/PERFLAB_TARGET, and for remote-observed the tier + its backend URLs),
# or we would silently query the wrong (e.g. localhost) environment.
if [[ "${manifest_target}" != "${env_target_mode}" ]]; then
  echo "Config/manifest mismatch: package target='${manifest_target}' but the active lab resolves target='${env_target_mode}'. Re-run with the matching lab/PERFLAB_TARGET (and, for remote, its backend URLs)." >&2
  exit 1
fi
if [[ "${manifest_rt}" == "1" && "${env_remote_telemetry}" != "1" ]]; then
  echo "Config/manifest mismatch: package is remote-observed, but PERFLAB_REMOTE_TELEMETRY is not enabled now -- the telemetry URLs were not required and would default to localhost. Re-run with PERFLAB_REMOTE_TELEMETRY=1 and the deployed backend URLs." >&2
  exit 1
fi
if [[ "${manifest_rc}" == "1" ]]; then
  if [[ "${manifest_target}" != "remote" || "${manifest_rt}" != "1" || "${manifest_rc_verified}" != "1" ]]; then
    echo "Manifest claims remote run-id correlation without a verified remote-observed run; refusing to recapture it as correlated evidence." >&2
    exit 1
  fi
  if [[ "${env_remote_correlation}" != "1" ]]; then
    echo "Config/manifest mismatch: package is remote run-id correlated, but PERFLAB_REMOTE_CORRELATION is not enabled now. Re-run with the declared target contract; otherwise this recapture would silently downgrade to a different selector." >&2
    exit 1
  fi
  performance_remote_correlation_validate || exit 1
  if [[ "${manifest_rc_version}" != "${remote_correlation_version}" || "${manifest_rc_header}" != "${remote_correlation_header}" ||
        "${manifest_rc_run_field}" != "${remote_correlation_response_run_id_field}" || "${manifest_rc_version_field}" != "${remote_correlation_response_version_field}" ||
        "${manifest_rc_prom_label}" != "${remote_correlation_prometheus_label}" || "${manifest_rc_loki_label}" != "${remote_correlation_loki_label}" ||
        "${manifest_rc_tempo_attr}" != "${remote_correlation_tempo_attribute}" ]]; then
    echo "Config/manifest mismatch: remote run-id correlation contract differs from the recorded package; refusing to query a different target signal contract." >&2
    exit 1
  fi
  if [[ "${run_id_label:-}" != "${remote_correlation_prometheus_label}" ]]; then
    echo "Config/manifest mismatch: PERFLAB_RUN_ID_ATTR maps to ${run_id_label:-empty}, but remote correlation requires ${remote_correlation_prometheus_label}." >&2
    exit 1
  fi
elif [[ "${env_remote_correlation}" == "1" ]]; then
  echo "Config/manifest mismatch: active remote correlation is enabled but this package was window-scoped; refusing to rewrite its evidence scope." >&2
  exit 1
fi
if [[ "${manifest_cp}" == "1" && "${env_continuous_profiling}" != "1" ]]; then
  echo "Config/manifest mismatch: package recorded continuousProfiling, but PERFLAB_CONTINUOUS_PROFILING is not enabled now. Re-run with PERFLAB_CONTINUOUS_PROFILING=1 (and, for remote, PERFLAB_PYROSCOPE_URL)." >&2
  exit 1
fi
if [[ "${manifest_cp}" == "0" && "${env_continuous_profiling}" == "1" ]]; then
  echo "Config/manifest mismatch: package recorded continuousProfiling=false, but PERFLAB_CONTINUOUS_PROFILING is enabled now. Recapture would query Pyroscope and rewrite compatibility as profiling-on. Unset PERFLAB_CONTINUOUS_PROFILING." >&2
  exit 1
fi
target_mode="${manifest_target}"
remote_telemetry="${manifest_rt}"
remote_correlation="${manifest_rc}"
continuous_profiling="${manifest_cp}"
export PERFLAB_CONTINUOUS_PROFILING="${continuous_profiling}"
profiling_keep_tiering="${manifest_keep}"
export PERFLAB_PROFILING_KEEP_TIERING="${profiling_keep_tiering}"

# Window selection, most-authoritative first: the env-exported measurement window
# (run-scenario, the normal path), then the manifest's FINALIZED measurement window
# (a standalone re-capture after the first run recorded it), then startedEpoch->now
# (a legacy/never-finalized package). Reusing the recorded window keeps a re-capture
# scoped to the measured load rather than "everything since start".
if [[ -n "${PERFLAB_MEASURE_START_EPOCH:-}" ]]; then
  start_epoch="${PERFLAB_MEASURE_START_EPOCH}"; end_epoch="${PERFLAB_MEASURE_END_EPOCH:-$(date -u +%s)}"
elif [[ "${manifest_meas_start}" != "0" && "${manifest_meas_end}" != "0" ]]; then
  start_epoch="${manifest_meas_start}"; end_epoch="${manifest_meas_end}"
else
  start_epoch="${manifest_start_epoch}"; end_epoch="$(date -u +%s)"
fi
# Track whether a required backend capture failed, so the manifest can finalize
# "partial" instead of "captured" and an incomplete package is not read as clean.
# run-scenario may pre-set it (a failed reset-stats or a fault that did not apply).
capture_incomplete="${PERFLAB_CAPTURE_INCOMPLETE:-0}"
metric_query_failures=0
telemetry_metrics_state="not-applicable"
telemetry_trace_state="not-applicable"
telemetry_log_state="not-applicable"
telemetry_profiles_state="not-applicable"
telemetry_metric_files=0
telemetry_trace_results=0
telemetry_trace_details=0
telemetry_log_records=0

mkdir -p "${artifact_dir}/source"

# ---------------------------------------------------------------------------
# Backend capture is two independent decisions:
#   capture_telemetry -- read Prometheus/Tempo/Loki/Pyroscope. TRUE for a local target
#     (owned, run-id scoped) OR a remote-observed one (PERFLAB_REMOTE_TELEMETRY=1,
#     the deployed env's backends, WINDOW scoped).
#   target_mode==local -- the compose-exec dependency snapshots + runtime extras.
#     These require OWNING the containers, so a remote target never runs them even
#     when observing telemetry.
# A plain black-box remote run does neither: facts.json (below) is its only evidence.
#
# Scoping differs by target. Local tags every signal with our perf.run.id, so it
# isolates by run id exactly. Remote-observed cannot (the deployed app was not
# started by us and carries no perf.run.id), so it scopes by the measurement TIME
# WINDOW only -- which also sweeps in any other traffic during that window.
# ---------------------------------------------------------------------------
capture_telemetry=0
if [[ "${target_mode}" == "local" || "${remote_telemetry}" == "1" ]]; then capture_telemetry=1; fi
correlated_run=0
if [[ "${target_mode}" == "local" ]]; then
  # Local owns the run: scope app metrics + traces by the exact perf.run.id.
  correlated_run=1
  prom_run_id_matcher="${run_id_label}=\"${telemetry_run_id}\""      # standalone inside {...}
  prom_run_id_selector=",${run_id_label}=\"${telemetry_run_id}\""    # appended after another selector
  trace_run_id_pred=" && resource.${run_id_attr} = \"${telemetry_run_id}\""
elif [[ "${remote_correlation}" == "1" ]]; then
  # This remote target proved its dynamic request contract before traffic. App
  # meters and structured logs use perf_run_id; traces use a span attribute
  # because resource attributes describe the already-running process.
  correlated_run=1
  prom_run_id_matcher="${remote_correlation_prometheus_label}=\"${telemetry_run_id}\""
  prom_run_id_selector=",${remote_correlation_prometheus_label}=\"${telemetry_run_id}\""
  trace_run_id_pred=" && ${remote_correlation_tempo_attribute} = \"${telemetry_run_id}\""
else
  # Remote-observed carries no perf.run.id, so it scopes app metrics by the deployed
  # env's JOB label + window (not an empty selector: job scoping keeps a shared
  # Prometheus from mixing in OTHER deployments that share the metric prefix), and
  # traces by the service.name regex already in trace_query + window.
  prom_run_id_matcher="job=~\"${prom_job_regex}\""
  prom_run_id_selector=",job=~\"${prom_job_regex}\""
  trace_run_id_pred=""
fi

if [[ "${capture_telemetry}" == "1" ]]; then
mkdir -p "${artifact_dir}/telemetry/metrics" "${artifact_dir}/telemetry/traces/details" \
         "${artifact_dir}/telemetry/logs"
if [[ "${target_mode}" == "remote" ]]; then
  if [[ "${remote_correlation}" == "1" ]]; then
    echo "Remote-observed: reading Prometheus/Tempo/Loki by verified run id ${telemetry_run_id}, bounded to the measurement window ${start_epoch}-${end_epoch}." >&2
  else
    echo "Remote-observed: reading Prometheus/Tempo/Loki scoped by the measurement window ${start_epoch}-${end_epoch} (NOT run-id isolated; other traffic in the window is included)." >&2
  fi
fi

# Instant vs range: gauges/rates must be read over the run window, because an
# instant query after load stops reports an idle process and hides the peak.
# Query provenance (D-P2-7). A backend response does not echo the query that
# produced it, so without this an evidence file cannot be re-run or audited:
# the reader cannot tell a genuinely empty series from a selector that never
# matched. Every rendered query is recorded with its endpoint, window and the
# artifact it produced. Appended as NDJSON so a failure mid-capture still
# leaves the queries issued so far.
# Whether an empty log window counts as a GAP depends on whether this run
# asked the application to log at all. Both the resolved setting and the
# decision are recorded so the reader never has to guess which case an
# empty window represents.
request_logging_level="${PERFLAB_REQUEST_LOGGING:-Warning}"
case "$(printf '%s' "${request_logging_level}" | tr '[:upper:]' '[:lower:]')" in
  trace|debug|information) logs_required_default=1 ;;
  *)                       logs_required_default=0 ;;
esac
logs_required="${PERFLAB_LOGS_REQUIRED:-${logs_required_default}}"
case "${logs_required}" in 0|1) ;; *) echo "PERFLAB_LOGS_REQUIRED must be 0 or 1; received '${logs_required}'." >&2; exit 1 ;; esac

queries_file="${artifact_dir}/telemetry/queries.ndjson"
window_start_utc="$(date -u -r "${start_epoch}" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@${start_epoch}" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")"
window_end_utc="$(date -u -r "${end_epoch}" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@${end_epoch}" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")"
record_trace_slice() { # record_trace_slice <start> <end> <limit> <artifact> <state>
  # Every parameter the request actually carried, so the record can be replayed
  # verbatim. Omitting one (most_recent changes WHICH traces come back, not just
  # how many) would make the provenance look exact while describing a different
  # query than the one that produced the artifact.
  mkdir -p "${artifact_dir}/telemetry"
  printf '{"signal":"traces","backend":"tempo","endpoint":"/api/search","query":"%s","artifact":"%s","captureState":"%s","startEpoch":%s,"endEpoch":%s,"limit":%s,"mostRecent":true}\n' \
    "$(json_escape "${trace_query}")" "$(json_escape "$4")" "$(json_escape "$5")" "$1" "$2" "$3" >> "${queries_file}"
}
record_query() { # record_query <signal> <backend> <endpoint> <query> <artifact> <state>
  mkdir -p "${artifact_dir}/telemetry"
  printf '{"signal":"%s","backend":"%s","endpoint":"%s","query":"%s","artifact":"%s","captureState":"%s","startEpoch":%s,"endEpoch":%s,"startUtc":"%s","endUtc":"%s"}\n' \
    "$(json_escape "$1")" "$(json_escape "$2")" "$(json_escape "$3")" "$(json_escape "$4")" \
    "$(json_escape "$5")" "$(json_escape "$6")" "${start_epoch}" "${end_epoch}" \
    "$(json_escape "${window_start_utc:-}")" "$(json_escape "${window_end_utc:-}")" >> "${queries_file}"
}
capture_prometheus_query() {
  local state=captured
  backend_curl -fsS --max-time 20 --get --data-urlencode "query=$2" \
    "${prometheus_url}/api/v1/query" > "${artifact_dir}/telemetry/metrics/$1.json" \
    || { echo "WARNING: Prometheus instant query '$1' failed; that metric is MISSING." >&2; capture_incomplete=1; metric_query_failures=$((metric_query_failures + 1)); state=failed; }
  record_query metrics prometheus "/api/v1/query" "$2" "telemetry/metrics/$1.json" "${state}"
}
capture_prometheus_range() {
  local state=captured
  backend_curl -fsS --max-time 30 --get --data-urlencode "query=$2" \
    --data-urlencode "start=${start_epoch}" --data-urlencode "end=${end_epoch}" --data-urlencode "step=5" \
    "${prometheus_url}/api/v1/query_range" > "${artifact_dir}/telemetry/metrics/$1.json" \
    || { echo "WARNING: Prometheus range query '$1' failed; that metric is MISSING." >&2; capture_incomplete=1; metric_query_failures=$((metric_query_failures + 1)); state=failed; }
  [[ "${state}" == "captured" ]] && state="$(grade_metric_role "$1")"
  record_query metrics prometheus "/api/v1/query_range" "$2" "telemetry/metrics/$1.json" "${state}"
}

# A backend answering 200 with an empty result set is NOT a captured metric: the
# file exists, so a reader sees an artifact, but there is nothing in it. For a
# role whose absence can only mean a broken scrape or selector, that must
# degrade the package -- otherwise a renamed metric silently produces a green
# run with no saturation evidence at all (D-P0-4). Conditional roles stay
# best-effort: empty there is a fact about the workload, not the capture.
grade_metric_role() { # grade_metric_role <role>
  local role="$1" file="${artifact_dir}/telemetry/metrics/$1.json" series
  series="$(jqd -r '(.data.result // []) | length' < "${file}" 2>/dev/null || echo 0)"
  [[ "${series}" =~ ^[0-9]+$ ]] || series=0
  if [[ "${series}" -gt 0 ]]; then printf 'captured'; return 0; fi
  case " ${PERFLAB_REQUIRED_METRIC_ROLES:-} " in
    *" ${role} "*)
      echo "WARNING: required metric role '${role}' returned no series; the scrape, selector or instrumentation is broken -- this is not an idle process." >&2
      capture_incomplete=1
      printf 'empty-required'
      ;;
    *) printf 'empty' ;;
  esac
}

# Application (<app_metric_prefix>_*) metrics: the app's own instrumentation,
# run-id scoped and runtime-neutral. Captured first because the client-metric
# scoping regex below is derived from them. The prefix is per-lab
# (PERFLAB_APP_METRIC_PREFIX, default "perflab").
if [[ "${target_mode}" == "remote" ]]; then
  # Remote-observed uses RANGE queries so instance discovery unions every
  # instance that served this run during the window. With a verified contract
  # the range is also filtered by its exact perf_run_id; without one it remains
  # the explicit job/window degraded mode.
  capture_prometheus_range scenario_executions "${app_metric_prefix}_scenario_executions_total{${prom_run_id_matcher}}"
  capture_prometheus_range application_metrics "{__name__=~\"${app_metric_prefix}_.*\"${prom_run_id_selector}}"
  capture_prometheus_range service_instances "target_info{${prom_run_id_matcher}}"

else
  # Local runs are also range-scoped. An instant query after a process restart
  # sees only the replacement generation (or a stale scrape), while the exact
  # measurement range retains every instance that actually served this run and
  # excludes generations outside the window.
  capture_prometheus_range scenario_executions "${app_metric_prefix}_scenario_executions_total{${prom_run_id_matcher}}"
  capture_prometheus_range application_metrics "{__name__=~\"${app_metric_prefix}_.*\"${prom_run_id_selector}}"
  capture_prometheus_range service_instances "target_info{${prom_run_id_matcher}}"
fi
# D-P0-9: telemetry-loss accounting, for BOTH the local and remote paths. Every
# other signal in this package is read THROUGH the collector, so a silent drop
# there makes an incomplete capture look complete -- the failure the capture
# states exist to prevent, one layer below where they can see it. The exporter
# queue is configured at 64, which is small for a 128-connection scenario, so
# drops are a live possibility rather than a theoretical one, and the local labs
# push the same volume through the same collector as a remote tier would.
# Window-scoped and best-effort: a collector that exposes no internal telemetry
# is a gap in observability of the pipeline, not a failed measurement.
capture_prometheus_range telemetry_export_failures \
  "sum by (exporter) (rate(otelcol_exporter_send_failed_spans_total[1m])) or sum by (exporter) (rate(otelcol_exporter_send_failed_metric_points_total[1m])) or sum by (exporter) (rate(otelcol_exporter_send_failed_log_records_total[1m]))"
capture_prometheus_range telemetry_queue_utilization \
  "otelcol_exporter_queue_size / clamp_min(otelcol_exporter_queue_capacity, 1)"
capture_prometheus_range telemetry_refused \
  "sum by (receiver) (rate(otelcol_receiver_refused_spans_total[1m])) or sum by (receiver) (rate(otelcol_receiver_refused_metric_points_total[1m]))"

# (No separate <prefix>_pool_* probe: neither lab exports app-level pool metrics,
# so it only ever produced an empty result[] file. The application_metrics query
# above already captures any <prefix>_pool_* series if a lab adds them, and the
# real connection-pool telemetry is database_pool_metrics.json from metrics.sh.)

# Resource identity also exists for routes that never emit an application counter
# (for example S27). Keep the exact local run ID, or the remote job/window scope.
# Parse each response independently: a missing or partial response must not
# discard valid identities from the other source. Query failures remain marked
# incomplete by the capture helpers above.
service_instance_regex="$(
  for identity_source in application_metrics service_instances; do
    identity_file="${artifact_dir}/telemetry/metrics/${identity_source}.json"
    if [[ -s "${identity_file}" ]]; then
      jqd -r '[.data.result[]? | (.metric.service_instance_id // .metric.instance // empty)] | unique | .[]' \
        < "${identity_file}" 2>/dev/null || true
    fi
  done | LC_ALL=C sort -u | paste -sd '|' -
)"
service_instance_regex="${service_instance_regex:-__no_correlated_service_instance__}"
# Remote-observed has no run-id fallback. If neither application metrics nor
# resource identity match its declared selector, runtime metrics cannot be
# correlated. Keep that incomplete state visible instead of claiming a
# diagnosable package.
if [[ "${target_mode}" == "remote" && "${service_instance_regex}" == "__no_correlated_service_instance__" ]]; then
  if [[ "${remote_correlation}" == "1" ]]; then
    echo "WARNING: no application or target_info series matched ${remote_correlation_prometheus_label}=\"${telemetry_run_id}\" in the window; runtime metric files will be EMPTY. Check the target writes the declared per-request metric label." >&2
  else
    echo "WARNING: no application or target_info series matched job=~\"${prom_job_regex}\" in the window; runtime metric files will be EMPTY. Check PERFLAB_APP_METRIC_PREFIX matches the deployed app and PERFLAB_PROM_JOB_REGEX its Prometheus job." >&2
  fi
  capture_incomplete=1
fi

# Runtime + dependency-client metrics from the runtime adapter map.
metrics_map="${runtime_adapter_dir}/metrics.sh"
if [[ -f "${metrics_map}" ]]; then
  # shellcheck disable=SC1090
  source "${metrics_map}"
  for entry in "${PERFLAB_METRIC_ROLES[@]}"; do
    IFS='|' read -r m_file m_type m_promql <<< "${entry}"
    # Reject before issuing: a selector with unbounded cardinality must not be
    # run and then regretted -- the series it creates outlive the run.
    performance_reject_unbounded_labels "${m_file}" "${m_promql}" || exit 1
    q="${m_promql//\$JOB/${prom_job_regex}}"
    q="${q//\$RUN_ID/${telemetry_run_id}}"
    q="${q//\$SERVICE_INSTANCE/${service_instance_regex}}"
    case "${m_type}" in
      range) capture_prometheus_range "${m_file}" "${q}" ;;
      instant) capture_prometheus_query "${m_file}" "${q}" ;;
      *) echo "Unknown metric type '${m_type}' for role '${m_file}'." >&2 ;;
    esac
  done
else
  echo "WARNING: runtime adapter '${runtime}' has no metrics.sh; runtime metrics not captured." >&2
fi

# Tempo traces, scoped by service.name + the run-id resource attribute. Tempo's
# search API has no portable cursor, so bounded time slices are recursively split
# when saturated. This expands the searchable population without one huge request.
trace_query="{ resource.service.name =~ \"${service_name_regex}\"${trace_run_id_pred} }"
trace_search_file="${artifact_dir}/telemetry/traces/search.json"
trace_pages_dir="${artifact_dir}/telemetry/traces/search-pages"
trace_population_file="${artifact_dir}/telemetry/traces/population.ndjson"
mkdir -p "${trace_pages_dir}"
: > "${trace_population_file}"
tempo_reachable=0
trace_page=0
trace_population_seen=0
trace_saturated=0
trace_next_cursor=""
capture_tempo_slice() { # <start-seconds> <end-seconds>
  local slice_start="$1" slice_end="$2" remaining page_limit page_file count middle attempt slice_ok=0
  (( trace_population_seen >= trace_limit )) && { trace_saturated=1; trace_next_cursor="${slice_start}000000000"; return 0; }
  remaining=$((trace_limit - trace_population_seen)); page_limit=1000
  (( remaining < page_limit )) && page_limit="${remaining}"
  trace_page=$((trace_page + 1))
  page_file="${trace_pages_dir}/search-$(printf '%05d' "${trace_page}").json"
  for attempt in $(seq 1 6); do
    if backend_curl -fsS --max-time 20 --get \
        --data-urlencode "q=${trace_query}" \
        --data-urlencode "start=${slice_start}" --data-urlencode "end=${slice_end}" --data-urlencode "limit=${page_limit}" \
        --data-urlencode "most_recent=true" \
        "${tempo_url}/api/search" > "${page_file}.tmp" 2>/dev/null; then
      tempo_reachable=1; mv "${page_file}.tmp" "${page_file}"; slice_ok=1; break
    fi
    rm -f "${page_file}.tmp"; (( attempt < 6 )) && sleep 5
  done
  # Record THIS request, not just the overall query. Trace search is issued as a
  # recursive series of time slices with their own start/end/limit, so a single
  # broad entry afterwards describes a request that was never made and cannot be
  # replayed. One record per slice keeps the provenance executable.
  record_trace_slice "${slice_start}" "${slice_end}" "${page_limit}" \
    "telemetry/traces/search-pages/$(basename "${page_file}")" \
    "$([[ "${slice_ok:-0}" == "1" ]] && echo captured || echo failed)"
  [[ -s "${page_file}" ]] || return 1
  count="$(jqd -r '(.traces // []) | length' < "${page_file}" 2>/dev/null || echo 0)"
  if (( count >= page_limit && slice_end - slice_start > 1 )); then
    middle=$((slice_start + (slice_end - slice_start) / 2))
    capture_tempo_slice "${slice_start}" "${middle}"
    capture_tempo_slice "${middle}" "${slice_end}"
    return 0
  fi
  jqd -c '.traces[]?' < "${page_file}" >> "${trace_population_file}" 2>/dev/null || true
  trace_population_seen=$((trace_population_seen + count))
  if (( count >= page_limit )); then
    trace_saturated=1; trace_next_cursor="${slice_end}000000000"
  fi
}
slice_start="${start_epoch}"
while (( slice_start < end_epoch && trace_population_seen < trace_limit )); do
  slice_end=$((slice_start + 60)); (( slice_end > end_epoch )) && slice_end="${end_epoch}"
  capture_tempo_slice "${slice_start}" "${slice_end}" || break
  slice_start="${slice_end}"
done
if [[ -s "${trace_population_file}" ]]; then
  jqd -s --argjson lim "${trace_limit}" '{traces:([.[]] | unique_by(.traceID) | .[:$lim])}' \
    < "${trace_population_file}" > "${trace_search_file}"
else
  printf '{"traces":[]}\n' > "${trace_search_file}"
fi
# An empty-but-reachable Tempo stays best-effort (ingest lag or sampling can leave a
# window with no traces). A TRANSPORT/HTTP failure on every retry is different: the
# backend was unreachable, so the traces are MISSING (not absent) -- mark partial.
if [[ "${tempo_reachable}" -eq 0 ]]; then
  echo "WARNING: Tempo unreachable at ${tempo_url} after retries; traces are MISSING." >&2
  capture_incomplete=1
fi
if [[ "${tempo_reachable}" -eq 1 ]]; then
  telemetry_trace_results="$(jqd -r '(.traces // []) | length' < "${trace_search_file}" 2>/dev/null || echo 0)"
  if [[ "${telemetry_trace_results}" -eq 0 ]]; then
    telemetry_trace_state="delayed"
  elif [[ "${trace_saturated}" -eq 1 || "${telemetry_trace_results}" -ge "${trace_limit}" ]]; then
    telemetry_trace_state="truncated"
  else
    telemetry_trace_state="captured"
  fi
else
  telemetry_trace_state="missing"
fi
# The per-slice records above are the replayable requests; this one is the
# merged RESULT, marked as such so it is not mistaken for a single query.
record_query traces tempo "(merged result of the /api/search slices above)" "${trace_query}" "telemetry/traces/search.json" "${telemetry_trace_state}"

if grep -q '"traceID"' "${trace_search_file}" 2>/dev/null; then
  trace_detail_failures=0
  while IFS= read -r trace_id; do
    [[ -z "${trace_id}" ]] && continue
    detail="${artifact_dir}/telemetry/traces/details/${trace_id}.json"
    # Stage then publish so a failed fetch cannot leave a zero-byte artifact
    # indistinguishable from a captured trace.
    if backend_curl -fsS --max-time 20 "${tempo_url}/api/traces/${trace_id}" > "${detail}.tmp" 2>/dev/null; then
      mv "${detail}.tmp" "${detail}"
    else
      rm -f "${detail}.tmp"; trace_detail_failures=$((trace_detail_failures + 1))
    fi
  done < <(jqd -r '
    .traces as $all | ($all | sort_by(.durationMs // 0)) as $sorted |
    ([
      $sorted[($sorted|length)/2|floor],
      $sorted[((($sorted|length)*95/100)|floor)],
      $sorted[((($sorted|length)*99/100)|floor)],
      $sorted[-1],
      ($sorted | max_by((.spanSet.matched // 0) + ([.spanSets[]?.matched // 0] | add // 0)))
    ] + [$all[] | select((.|tostring|test("error|status.*(error|true|2)";"i")))][:100])
    | map(select(. != null) | .traceID) | unique[]' < "${trace_search_file}" 2>/dev/null)
  if [[ "${trace_detail_failures}" -gt 0 ]]; then
    echo "WARNING: ${trace_detail_failures} trace detail fetch(es) failed; this evidence package is INCOMPLETE." >&2
    capture_incomplete=1
    telemetry_trace_state="partial"
  fi
fi
telemetry_trace_details="$(find "${artifact_dir}/telemetry/traces/details" -type f -name '*.json' 2>/dev/null | wc -l | tr -d ' ')"

# Loki logs use backward pagination with transport pages capped at 1,000 records.
# PERFLAB_LOG_LIMIT is the total phase budget, not a single-response size.
log_query="{service_name=~\"${service_name_regex}\"}"
if [[ "${correlated_run}" == "1" ]]; then
  # Match PerfLab's canonical Loki query: resource labels select the service and
  # the structured run attribute prevents concurrent traffic from leaking into
  # this evidence window. Remote targets use this only after the v1 probe has
  # proved their dynamic per-request contract.
  log_label="${run_id_label}"
  [[ "${target_mode}" == "remote" ]] && log_label="${remote_correlation_loki_label}"
  log_query+=" | ${log_label}=\"${telemetry_run_id}\""
fi
log_file="${artifact_dir}/telemetry/logs/query-range.json"
log_pages_dir="${artifact_dir}/telemetry/logs/pages"
mkdir -p "${log_pages_dir}"
log_reachable=0
log_end="${end_epoch}000000000"
log_start="${start_epoch}000000000"
log_page=0
log_total=0
log_more=0
while (( log_total < log_limit )); do
  log_page=$((log_page + 1)); log_page_limit=1000
  log_remaining=$((log_limit - log_total)); (( log_remaining < log_page_limit )) && log_page_limit="${log_remaining}"
  log_page_file="${log_pages_dir}/page-$(printf '%05d' "${log_page}").json"
  page_ok=0
  for attempt in $(seq 1 6); do
    if backend_curl -fsS --max-time 30 --get \
        --data-urlencode "query=${log_query}" \
        --data-urlencode "start=${log_start}" --data-urlencode "end=${log_end}" \
        --data-urlencode "direction=backward" --data-urlencode "limit=${log_page_limit}" \
        "${loki_url}/loki/api/v1/query_range" > "${log_page_file}.tmp" 2>/dev/null; then
      log_reachable=1; page_ok=1; mv "${log_page_file}.tmp" "${log_page_file}"; break
    fi
    rm -f "${log_page_file}.tmp"; (( attempt < 6 )) && sleep 5
  done
  (( page_ok == 1 )) || break
  page_count="$(jqd -r '[.data.result[]?.values[]?] | length' < "${log_page_file}" 2>/dev/null || echo 0)"
  log_total=$((log_total + page_count))
  if (( page_count < log_page_limit )); then log_more=0; break; fi
  oldest="$(jqd -r '[.data.result[]?.values[]?[0] | tonumber] | min // empty' < "${log_page_file}" 2>/dev/null || true)"
  if [[ -z "${oldest}" ]] || (( oldest <= log_start )); then log_more=0; break; fi
  log_end=$((oldest - 1)); log_more=1
done
log_cursor=""
[[ "${log_more}" -eq 1 ]] && log_cursor="${log_end}"
if compgen -G "${log_pages_dir}/page-*.json" >/dev/null; then
  for captured_log_page in "${log_pages_dir}"/page-*.json; do
    jqd -c . < "${captured_log_page}"
  done | jqd -s '{status:"success",data:{resultType:"streams",result:[.[]?.data.result[]?]}}' > "${log_file}"
else
  printf '{"status":"success","data":{"resultType":"streams","result":[]}}\n' > "${log_file}"
fi
# A silently empty capture is worse than a loud failure: it makes an incomplete
# package look diagnosable. Unreachable on every retry (transport/HTTP failure)
# makes the logs MISSING. A reachable-but-EMPTY window is also not evidence: a
# diagnosis cannot distinguish "the application said nothing" from "the log
# pipeline dropped everything", so it degrades the package to partial rather
# than passing as a complete capture (D-P0-4: absence must not read as health).
if [[ "${log_reachable}" -eq 0 ]]; then
  echo "WARNING: Loki unreachable at ${loki_url} after retries; logs are MISSING." >&2
  capture_incomplete=1
  telemetry_log_state="missing"
else
  telemetry_log_records="$(jqd -r '[.data.result[]?.values[]?] | length' < "${log_file}" 2>/dev/null || echo 0)"
  if [[ "${telemetry_log_records}" -eq 0 ]]; then
    # An empty window means different things depending on whether the run ASKED
    # the application to log. With request logging off (the default -- at this
    # lab's throughput it would emit ~1.2M lines per window) a healthy path emits
    # nothing, and calling every clean run "partial" would drain that state of
    # meaning. With logging on, empty IS a gap. So requiredness is explicit, and
    # the resolved setting travels with the evidence so a reader can tell which
    # case they are looking at instead of inferring it.
    if [[ "${logs_required}" == "1" ]]; then
      echo "WARNING: log capture produced no entries at ${log_file} although request logging is enabled (${request_logging_level}); the logs are MISSING." >&2
      capture_incomplete=1
      telemetry_log_state="missing"
    else
      echo "NOTE: no log entries in the window; request logging is '${request_logging_level}', so a healthy path emits none. Set PERFLAB_REQUEST_LOGGING=Information (and PERFLAB_LOGS_REQUIRED=1) to make this a gap." >&2
      telemetry_log_state="empty"
    fi
  elif [[ "${log_more}" -eq 1 || "${telemetry_log_records}" -ge "${log_limit}" ]]; then
    telemetry_log_state="truncated"
  else
    telemetry_log_state="captured"
  fi
fi
record_query logs loki "/loki/api/v1/query_range" "${log_query}" "telemetry/logs/query-range.json" "${telemetry_log_state}"
printf '{"requestLoggingLevel":"%s","logsRequired":%s,"records":%s,"captureState":"%s"}\n' \
  "$(json_escape "${request_logging_level}")" "$([[ "${logs_required}" == "1" ]] && echo true || echo false)" \
  "${telemetry_log_records:-0}" "$(json_escape "${telemetry_log_state}")" > "${artifact_dir}/telemetry/logs/policy.json"

telemetry_metric_files="$(find "${artifact_dir}/telemetry/metrics" -type f -name '*.json' 2>/dev/null | wc -l | tr -d ' ')"
telemetry_metrics_state="captured"
[[ "${metric_query_failures}" -gt 0 ]] && telemetry_metrics_state="partial"

fi   # end capture_telemetry

# Pyroscope CPU profiles stay in the Grafana observability adapter. Disabled
# runs record not-applicable and do not query the backend.
# shellcheck disable=SC1091
source "${harness_root}/adapters/observability/grafana/capture-profiles.sh"
if [[ "${continuous_profiling}" == "1" && "${target_mode}" == "local" ]]; then
  role="$(scenario_value "${scenario_id}" target || true)"
  mapped=""
  for pair in ${PERFLAB_PYROSCOPE_ROLE_SERVICES:-}; do
    case "${pair}" in
      "${role}:"*) mapped="${pair#*:}" ;;
    esac
  done
  if [[ -n "${mapped}" ]]; then
    pyroscope_required_services="${mapped}"
  fi
fi
pyroscope_capture_profiles
[[ "${profiles_incomplete:-0}" == "1" ]] && capture_incomplete=1

# Dependency snapshots + the app's own socket table + compose ps + runtime extras
# all shell into OWNED containers (compose exec / snapshot.sh / docker), so they
# are LOCAL-only -- a remote target (even remote-observed) never runs them.
if [[ "${target_mode}" == "local" ]]; then
  mkdir -p "${artifact_dir}/dependencies" "${artifact_dir}/runtime"
  # Dependency snapshots (per adapter) + the app's own socket table + compose ps.
  for dep in ${dependencies}; do
    "$(dependency_dir "${dep}")/snapshot.sh" "${artifact_dir}" \
      || { echo "WARNING: ${dep} snapshot failed; its evidence is MISSING." >&2; capture_incomplete=1; }
  done
  compose exec -T "${primary_app_service}" sh -c 'cat /proc/net/tcp /proc/net/tcp6' \
    > "${artifact_dir}/dependencies/${primary_app_service}-net-tcp.txt" 2>/dev/null || true
  compose ps --format json | jqd -s '.' > "${artifact_dir}/dependencies/docker-compose-ps.json" 2>/dev/null || true

  # Final boundary: what the run left behind (leaked containers, a restarted
  # dependency, residual host load).
  "${harness_core_dir}/capture/capture-environment.sh" "${artifact_dir}" post-run >/dev/null 2>&1 || true

  # Optional runtime-adapter evidence captured at measurement time.
  if [[ -f "${runtime_adapter_dir}/evidence-extra.sh" ]]; then
    bash "${runtime_adapter_dir}/evidence-extra.sh" "${artifact_dir}" || true
  fi
fi

# A plain black-box remote run (no telemetry read, no ownership) has only facts.json.
if [[ "${target_mode}" == "remote" && "${capture_telemetry}" != "1" ]]; then
  echo "Remote (black-box): skipping all backend capture (Prometheus/Tempo/Loki/Pyroscope/dependencies/runtime); facts.json from the load generator is the evidence." >&2
fi

# Tool versions (generic + runtime adapter probe). Runtime-neutral, both targets.
{
  docker version
  docker compose version
  wrk --version
  k6 version
  if [[ "${load_gen}" == "jmeter" && -n "${PERFLAB_JMETER_IMAGE:-}" ]]; then
    echo "--- jmeter ---"
    MSYS_NO_PATHCONV=1 docker run --rm --pull=never \
      --env PERFLAB_PLUGIN_IMAGE_DIGEST="${PERFLAB_PLUGIN_IMAGE_DIGEST:-}" \
      "${PERFLAB_JMETER_IMAGE}" version --json || true
  fi
  claude --version
  # The jq that parsed this package. The default is the pinned Docker image, but
  # PERFLAB_JQ=host substitutes whatever jq is installed, so without this line two
  # packages could differ in parsing with nothing in either one saying why. Only
  # host mode is probed: the pinned image reference already names the Docker jq,
  # and running it just to ask costs another container start per package.
  echo "--- jq: ${PERFLAB_JQ:-docker} ---"
  if [[ "${PERFLAB_JQ:-docker}" == "host" ]]; then command -v jq; jqd --version; else echo "${PERFLAB_JQ_IMAGE}"; fi
  echo "--- runtime adapter: ${runtime} ---"
  [[ -f "${runtime_adapter_dir}/versions.sh" ]] && bash "${runtime_adapter_dir}/versions.sh"
} > "${artifact_dir}/source/tool-versions.txt" 2>&1 || true

if git -C "${repo_root}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git -C "${repo_root}" status --short > "${artifact_dir}/source/git-status.txt"
  git -C "${repo_root}" diff --stat > "${artifact_dir}/source/git-diff-stat.txt"
fi

# facts.json: wrap the load generator's observations.json with run identity.
obs_file="${artifact_dir}/benchmark/observations.json"
[[ -s "${obs_file}" ]] || { echo "Missing ${obs_file}; the load generator did not emit observations." >&2; exit 1; }
write_safety_class="none"
lifecycle_ownership="none"
if [[ "${target_mode}" == "local" ]]; then
  lifecycle_ownership="managed"
fi
if [[ "${PERF_WORKLOAD_KIND:-}" == "journey" || "${PERF_WRITE_ACK:-}" == "managed-reference" ]]; then
  write_safety_class="managed-reference"
fi
remote_correlation_fact=false
[[ "${remote_correlation}" == "1" ]] && remote_correlation_fact=true
printf '{"runId":"%s","telemetryRunId":"%s","scenarioId":"%s","loadGenerator":"%s","remoteCorrelation":%s,"writeSafety":{"class":"%s"},"lifecycle":{"ownership":"%s"},"observations":%s}\n' \
  "$(json_escape "${run_id}")" "$(json_escape "${telemetry_run_id}")" "$(json_escape "${scenario_id}")" \
  "$(json_escape "${load_gen}")" "${remote_correlation_fact}" "$(json_escape "${write_safety_class}")" "$(json_escape "${lifecycle_ownership}")" "$(cat "${obs_file}")" \
  > "${artifact_dir}/facts.json"
if [[ -s "${artifact_dir}/benchmark/compatibility.json" ]]; then
  if cat "${artifact_dir}/facts.json" "${artifact_dir}/benchmark/compatibility.json" \
    | jqd -s '.[0] + {compatibility: .[1]}' > "${artifact_dir}/facts.json.tmp" 2>/dev/null; then
    mv "${artifact_dir}/facts.json.tmp" "${artifact_dir}/facts.json"
  else
    rm -f "${artifact_dir}/facts.json.tmp"
    if [[ "${load_gen}" == "jmeter" || "${load_gen}" == "k6" ]]; then
      echo "Failed to merge ${load_gen} compatibility.json into facts.json." >&2
      exit 1
    fi
  fi
elif [[ "${load_gen}" == "jmeter" || "${load_gen}" == "k6" ]]; then
  echo "${load_gen} measure phase did not publish compatibility.json." >&2
  exit 1
fi

# Per-request EFFICIENCY (derived facts): normalize resource use by throughput --
# CPU-ms, allocated bytes, GC-pause-ms and dependency-ms per request over the
# measure window. These catch the regression absolute latency hides ("same p99,
# 2x the CPU/allocations per request") and are gate-able / comparable / trendable
# like any other observation.
#
# Server metrics require telemetry capture. A black-box remote run must not read
# Prometheus just because the URL happens to be reachable (local-as-remote
# fixtures would otherwise silently convert load-only into observed-mode facts).
# Missing server costs stay absent -- never zero-filled.
if [[ "${capture_telemetry}" == "1" ]]; then
  eff_window=$(( end_epoch - start_epoch )); (( eff_window < 1 )) && eff_window=1
  eff_si="${service_instance_regex:-.+}"
  eff_reqrate="sum(rate(http_server_request_duration_seconds_count{service_instance_id=~\"${eff_si}\",http_route!~\"/health.*|\"}[${eff_window}s]))"
  prom_scalar() {
    backend_curl -fsS -G "${prometheus_url}/api/v1/query" \
      --data-urlencode "query=$1" --data-urlencode "time=${end_epoch}" 2>/dev/null \
      | jqd -r '.data.result[0].value[1] // empty' 2>/dev/null || true
  }
  eff_obs=()
  add_eff() { # <name> <unit> <numerator-promql>
    local v; v="$(prom_scalar "$3 / ${eff_reqrate}")"
    [[ -n "${v}" && "${v}" != "NaN" && "${v}" != "+Inf" && "${v}" != "-Inf" ]] || return 0
    eff_obs+=("{\"name\":\"$1\",\"value\":${v},\"unit\":\"$2\",\"source\":\"prometheus (derived)\"}")
  }
  add_eff "efficiency.cpu_ms_per_request"    "ms"   "1000 * sum(rate(dotnet_process_cpu_time_seconds_total{service_instance_id=~\"${eff_si}\"}[${eff_window}s]))"
  add_eff "efficiency.alloc_bytes_per_request" "byte" "sum(rate(dotnet_gc_heap_allocated_bytes_total{service_instance_id=~\"${eff_si}\"}[${eff_window}s]))"
  add_eff "efficiency.gc_pause_ms_per_request"  "ms"   "1000 * sum(rate(dotnet_gc_pause_time_seconds_total{service_instance_id=~\"${eff_si}\"}[${eff_window}s]))"
  add_eff "efficiency.db_ms_per_request"        "ms"   "1000 * sum(rate(db_client_operation_duration_seconds_sum{service_instance_id=~\"${eff_si}\"}[${eff_window}s]))"
  if (( ${#eff_obs[@]} > 0 )); then
    eff_json="[$(IFS=,; echo "${eff_obs[*]}")]"
    if jqd --argjson eff "${eff_json}" '.observations += $eff' < "${artifact_dir}/facts.json" > "${artifact_dir}/facts.json.tmp" 2>/dev/null; then
      mv "${artifact_dir}/facts.json.tmp" "${artifact_dir}/facts.json"
      echo "Added ${#eff_obs[@]} per-request efficiency observation(s) to facts.json." >&2
    else
      rm -f "${artifact_dir}/facts.json.tmp"
    fi
  fi
fi

# Finalize the manifest. Status is "partial" when a required backend capture failed,
# so an incomplete package is not mistaken for a clean one;
# measurementStartedEpoch/EndedEpoch record the exact window the telemetry above was
# queried over. The terminal fields are SET with jqd (not string-appended) so a
# standalone RECAPTURE replaces them idempotently -- never duplicating keys, whatever
# the manifest formatting -- which a duplicate-key append could otherwise use to hide
# the real status.
#
# Preserve the fault outcome across a recapture: it comes from the live run's env,
# else the prior manifest. A fault that did NOT apply or restore -- and any prior
# "partial" status -- is a permanent property of the run that a telemetry recapture
# cannot repair, so it is STICKY: recapture may add incompleteness, never clear it.
fault_applied="${PERFLAB_FAULT_APPLIED:-${manifest_fault_applied}}"
fault_restored="${PERFLAB_FAULT_RESTORED:-${manifest_fault_restored}}"
[[ "${manifest_prior_status}" == "partial" ]] && capture_incomplete=1
[[ "${fault_applied}" == "false" || "${fault_restored}" == "false" ]] && capture_incomplete=1
capture_status="captured"; [[ "${capture_incomplete}" -eq 1 ]] && capture_status="partial"
if jqd -c \
    --argjson ms "${start_epoch}" --argjson me "${end_epoch}" \
    --arg ca "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson ce "$(date -u +%s)" \
    --arg st "${capture_status}" --arg fa "${fault_applied}" --arg fr "${fault_restored}" \
    '.measurementStartedEpoch=$ms | .measurementEndedEpoch=$me | .completedAt=$ca
     | .completedEpoch=$ce | .status=$st
     | (if $fa=="" then . else .faultApplied=($fa=="true") end)
     | (if $fr=="" then . else .faultRestored=($fr=="true") end)' \
    < "${manifest}" > "${manifest}.tmp"; then
  mv "${manifest}.tmp" "${manifest}"
else
  rm -f "${manifest}.tmp"; echo "ERROR: failed to finalize ${manifest}." >&2; exit 1
fi

# A machine-readable capture inventory makes bounded/delayed evidence explicit.
# It is deliberately separate from facts.json: load observations remain generator
# facts, while this document describes the evidence collection surface shared by
# the native harness and PerfLab's normalized observability report.
mkdir -p "${artifact_dir}/telemetry"
jqd -n \
  --arg package_status "${capture_status}" \
  --arg metrics_state "${telemetry_metrics_state}" --argjson metric_files "${telemetry_metric_files}" --argjson metric_failures "${metric_query_failures}" \
  --arg traces_state "${telemetry_trace_state}" --argjson trace_results "${telemetry_trace_results}" --argjson trace_details "${telemetry_trace_details}" \
  --argjson trace_limit "${trace_limit}" --arg trace_cursor "${trace_next_cursor:-}" --argjson trace_pages "${trace_page:-0}" \
  --arg logs_state "${telemetry_log_state}" --argjson log_records "${telemetry_log_records}" --argjson log_limit "${log_limit}" --argjson log_pages "${log_page:-0}" --arg log_cursor "${log_cursor:-}" \
  --arg profiles_state "${telemetry_profiles_state}" \
  '{schemaVersion:"telemetry-capture-v1",packageStatus:$package_status,signals:{
    metrics:{captureState:$metrics_state,files:$metric_files,queryFailures:$metric_failures},
    traces:{captureState:$traces_state,returned:$trace_results,retainedDetails:$trace_details,limit:$trace_limit,pages:$trace_pages,nextCursor:(if $trace_cursor=="" then null else $trace_cursor end),truncated:($traces_state=="truncated")},
    logs:{captureState:$logs_state,returned:$log_records,limit:$log_limit,pages:$log_pages,nextCursor:(if $log_cursor=="" then null else $log_cursor end),truncated:($logs_state=="truncated")},
    profiles:{captureState:$profiles_state}
  }}' > "${artifact_dir}/telemetry/capture-status.json"
if [[ -s "${artifact_dir}/telemetry/profiles-signal.json" ]]; then
  if cat "${artifact_dir}/telemetry/capture-status.json" "${artifact_dir}/telemetry/profiles-signal.json" \
    | jqd -s '.[0] as $base | .[1] as $profiles | $base | .signals.profiles=($base.signals.profiles + $profiles)' \
    > "${artifact_dir}/telemetry/capture-status.json.tmp"; then
    mv "${artifact_dir}/telemetry/capture-status.json.tmp" "${artifact_dir}/telemetry/capture-status.json"
  else
    rm -f "${artifact_dir}/telemetry/capture-status.json.tmp"
    echo "WARNING: failed to merge Pyroscope capture status; profiles remain a captureState-only signal." >&2
  fi
fi
if [[ "${capture_incomplete}" -eq 1 ]]; then
  echo "NOTE: package finalized status:\"partial\" -- a required capture failed or a prior partial/fault outcome is sticky (see WARNINGs above)." >&2
fi

# Stamp the capture status onto facts.json too, so a single facts.json is
# self-describing and gate.sh can refuse a partial package (whose available
# metrics might meet SLOs only because a required capture failed) even when it is
# handed the facts file directly, without the sibling manifest.
if jqd --arg st "${capture_status}" --argjson cp "${continuous_profiling:-0}" --argjson keep "${profiling_keep_tiering:-0}" \
    '.status=$st | .continuousProfiling=($cp==1) | .profilingKeepTiering=($keep==1) | if has("compatibility") then .compatibility.continuousProfiling=($cp==1) | .compatibility.profilingKeepTiering=($keep==1) else . end' \
    < "${artifact_dir}/facts.json" > "${artifact_dir}/facts.json.tmp" 2>/dev/null; then
  mv "${artifact_dir}/facts.json.tmp" "${artifact_dir}/facts.json"
else
  rm -f "${artifact_dir}/facts.json.tmp"
fi
