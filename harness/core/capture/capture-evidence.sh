#!/usr/bin/env bash
# Capture telemetry + dependency evidence for a measured run and write facts.json.
# Runtime-neutral: runtime metric names come from the adapter's metrics.sh,
# dependency snapshots from dependency adapters, and the load generator's numbers
# from benchmark/observations.json. Foreign JSON (Prometheus/Tempo/Loki) is
# parsed with dockerized jq (jqd) or grep; facts.json is emitted with printf.
set -euo pipefail
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/common.sh"

artifact_dir="${1:?Usage: capture-evidence.sh <artifact-directory>}"
manifest="${artifact_dir}/manifest.json"
[[ -f "${manifest}" ]] || { echo "Manifest not found: ${manifest}" >&2; exit 1; }

# Read the manifest fields we need in one jqd call (standalone-safe).
IFS=$'\t' read -r run_id telemetry_run_id scenario_id load_gen start_epoch < <(
  jqd -r '[.runId,(.telemetryRunId//.runId),.scenarioId,(.workload.loadGenerator//"wrk"),(.startedEpoch//0)] | @tsv' < "${manifest}")
# Prefer the measurement window (exported by run-scenario) so telemetry, traces,
# logs, and the trend analysis cover the measured load only -- not Compose
# startup, the warm-up, or the post-load cooldown. Fall back to the manifest
# start and "now" for a standalone/legacy invocation.
start_epoch="${PERFLAB_MEASURE_START_EPOCH:-${start_epoch}}"
end_epoch="${PERFLAB_MEASURE_END_EPOCH:-$(date -u +%s)}"
# Track whether a required backend capture failed, so the manifest can finalize
# "partial" instead of "captured" and an incomplete package is not read as clean.
# run-scenario may pre-set it (a failed reset-stats or a fault that did not apply).
capture_incomplete="${PERFLAB_CAPTURE_INCOMPLETE:-0}"

mkdir -p "${artifact_dir}/telemetry/metrics" "${artifact_dir}/telemetry/traces/details" \
         "${artifact_dir}/telemetry/logs" "${artifact_dir}/dependencies" \
         "${artifact_dir}/source" "${artifact_dir}/runtime"

# Instant vs range: gauges/rates must be read over the run window, because an
# instant query after load stops reports an idle process and hides the peak.
capture_prometheus_query() {
  curl -fsS --max-time 20 --get --data-urlencode "query=$2" \
    "${prometheus_url}/api/v1/query" > "${artifact_dir}/telemetry/metrics/$1.json" \
    || { echo "WARNING: Prometheus instant query '$1' failed; that metric is MISSING." >&2; capture_incomplete=1; }
}
capture_prometheus_range() {
  curl -fsS --max-time 30 --get --data-urlencode "query=$2" \
    --data-urlencode "start=${start_epoch}" --data-urlencode "end=${end_epoch}" --data-urlencode "step=5" \
    "${prometheus_url}/api/v1/query_range" > "${artifact_dir}/telemetry/metrics/$1.json" \
    || { echo "WARNING: Prometheus range query '$1' failed; that metric is MISSING." >&2; capture_incomplete=1; }
}

# Application (<app_metric_prefix>_*) metrics: the app's own instrumentation,
# run-id scoped and runtime-neutral. Captured first because the client-metric
# scoping regex below is derived from them. The prefix is per-lab
# (PERFLAB_APP_METRIC_PREFIX, default "perflab").
capture_prometheus_query scenario_executions "${app_metric_prefix}_scenario_executions_total{${run_id_label}=\"${telemetry_run_id}\"}"
capture_prometheus_query application_metrics "{__name__=~\"${app_metric_prefix}_.*\",${run_id_label}=\"${telemetry_run_id}\"}"
# (No separate <prefix>_pool_* probe: neither lab exports app-level pool metrics,
# so it only ever produced an empty result[] file. The application_metrics query
# above already captures any <prefix>_pool_* series if a lab adds them, and the
# real connection-pool telemetry is database_pool_metrics.json from metrics.sh.)

service_instance_regex="$(jqd -r '[.data.result[]? | (.metric.service_instance_id // .metric.instance // empty)] | unique | join("|")' \
  < "${artifact_dir}/telemetry/metrics/application_metrics.json" 2>/dev/null || true)"
service_instance_regex="${service_instance_regex:-__no_correlated_service_instance__}"

# Runtime + dependency-client metrics from the runtime adapter map.
metrics_map="${runtime_adapter_dir}/metrics.sh"
if [[ -f "${metrics_map}" ]]; then
  # shellcheck disable=SC1090
  source "${metrics_map}"
  for entry in "${PERFLAB_METRIC_ROLES[@]}"; do
    IFS='|' read -r m_file m_type m_promql <<< "${entry}"
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

# Tempo traces, scoped by service.name + the run-id resource attribute. Retry
# (Tempo needs time to ingest a burst); presence check uses grep (no jq in the
# loop); the top-10-by-duration selection uses jqd once.
trace_query="{ resource.service.name =~ \"${service_name_regex}\" && resource.${run_id_attr} = \"${telemetry_run_id}\" }"
trace_search_file="${artifact_dir}/telemetry/traces/search.json"
for _ in $(seq 1 6); do
  curl -fsS --max-time 20 --get \
    --data-urlencode "q=${trace_query}" \
    --data-urlencode "start=${start_epoch}" --data-urlencode "end=${end_epoch}" --data-urlencode "limit=200" \
    "${tempo_url}/api/search" > "${trace_search_file}" 2>/dev/null || true
  grep -q '"traceID"' "${trace_search_file}" 2>/dev/null && break
  sleep 5
done

if grep -q '"traceID"' "${trace_search_file}" 2>/dev/null; then
  trace_detail_failures=0
  while IFS= read -r trace_id; do
    [[ -z "${trace_id}" ]] && continue
    detail="${artifact_dir}/telemetry/traces/details/${trace_id}.json"
    # Stage then publish so a failed fetch cannot leave a zero-byte artifact
    # indistinguishable from a captured trace.
    if curl -fsS --max-time 20 "${tempo_url}/api/traces/${trace_id}" > "${detail}.tmp" 2>/dev/null; then
      mv "${detail}.tmp" "${detail}"
    else
      rm -f "${detail}.tmp"; trace_detail_failures=$((trace_detail_failures + 1))
    fi
  done < <(jqd -r '.traces | sort_by(.durationMs // 0) | reverse | .[:10][] | .traceID' < "${trace_search_file}" 2>/dev/null)
  [[ "${trace_detail_failures}" -gt 0 ]] && \
    echo "WARNING: ${trace_detail_failures} trace detail fetch(es) failed; this evidence package is INCOMPLETE." >&2
fi

# Loki logs. Retry with a temp file so a timeout cannot truncate the artifact.
# limit=2000 stays under Loki's 4 MiB gRPC message cap on verbose scenarios.
log_query="{service_name=~\"${service_name_regex}\"}"
log_file="${artifact_dir}/telemetry/logs/query-range.json"
: > "${log_file}"
for _ in $(seq 1 6); do
  if curl -fsS --max-time 30 --get \
      --data-urlencode "query=${log_query}" \
      --data-urlencode "start=${start_epoch}000000000" --data-urlencode "end=${end_epoch}000000000" \
      --data-urlencode "limit=2000" \
      "${loki_url}/loki/api/v1/query_range" > "${log_file}.tmp" 2>/dev/null; then
    mv "${log_file}.tmp" "${log_file}"
    grep -q '"values":\[\[' "${log_file}" 2>/dev/null && break
  fi
  rm -f "${log_file}.tmp"; sleep 5
done
# A silently empty capture is worse than a loud failure: it makes an incomplete
# package look diagnosable.
grep -q '"values":\[\[' "${log_file}" 2>/dev/null || \
  echo "WARNING: log capture produced no entries at ${log_file}; treat these logs as MISSING, not as evidence of a quiet run." >&2

# Dependency snapshots (per adapter) + the app's own socket table + compose ps.
for dep in ${dependencies}; do
  "$(dependency_dir "${dep}")/snapshot.sh" "${artifact_dir}" \
    || { echo "WARNING: ${dep} snapshot failed; its evidence is MISSING." >&2; capture_incomplete=1; }
done
compose exec -T "${primary_app_service}" sh -c 'cat /proc/net/tcp /proc/net/tcp6' \
  > "${artifact_dir}/dependencies/${primary_app_service}-net-tcp.txt" 2>/dev/null || true
compose ps --format json | jqd -s '.' > "${artifact_dir}/dependencies/docker-compose-ps.json" 2>/dev/null || true

# Optional runtime-adapter evidence captured at measurement time.
if [[ -f "${runtime_adapter_dir}/evidence-extra.sh" ]]; then
  bash "${runtime_adapter_dir}/evidence-extra.sh" "${artifact_dir}" || true
fi

# Tool versions (generic + runtime adapter probe).
{
  docker version
  docker compose version
  wrk --version
  k6 version
  claude --version
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
printf '{"runId":"%s","telemetryRunId":"%s","scenarioId":"%s","loadGenerator":"%s","observations":%s}\n' \
  "$(json_escape "${run_id}")" "$(json_escape "${telemetry_run_id}")" "$(json_escape "${scenario_id}")" \
  "$(json_escape "${load_gen}")" "$(cat "${obs_file}")" \
  > "${artifact_dir}/facts.json"

# Finalize the manifest (append top-level fields to our own JSON, no jq). Status
# is "partial" when a required backend capture failed, so an incomplete package
# is not mistaken for a clean one. measurementStartedEpoch/EndedEpoch record the
# exact window the telemetry above was queried over.
content="$(cat "${manifest}")"; content="${content%\}}"
capture_status="captured"; [[ "${capture_incomplete}" -eq 1 ]] && capture_status="partial"
# Record whether the fault took effect AND whether the dependency recovered in the
# window (run-scenario sets these for a fault run), so a resilience package whose
# injection or recovery failed is self-describing.
fault_applied_field=""
[[ -n "${PERFLAB_FAULT_APPLIED:-}" ]]  && fault_applied_field="${fault_applied_field},\"faultApplied\":${PERFLAB_FAULT_APPLIED}"
[[ -n "${PERFLAB_FAULT_RESTORED:-}" ]] && fault_applied_field="${fault_applied_field},\"faultRestored\":${PERFLAB_FAULT_RESTORED}"
printf '%s,"measurementStartedEpoch":%s,"measurementEndedEpoch":%s,"completedAt":"%s","completedEpoch":%s,"status":"%s"%s}\n' \
  "${content}" "${start_epoch}" "${end_epoch}" "$(json_escape "$(date -u +%Y-%m-%dT%H:%M:%SZ)")" "$(date -u +%s)" "${capture_status}" "${fault_applied_field}" \
  > "${manifest}"
if [[ "${capture_incomplete}" -eq 1 ]]; then
  echo "NOTE: package finalized status:\"partial\" -- a required capture failed (see WARNINGs above)." >&2
fi
