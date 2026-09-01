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

# lab-context (from PERFLAB_TARGET + the remote-tier env) already resolved these;
# capture what the ACTIVE config is before the manifest read below overwrites them.
env_target_mode="${target_mode}"
env_remote_telemetry="${remote_telemetry}"

# Read the manifest fields we need in one jqd call (standalone-safe). The recorded
# target/remoteTelemetry say what the run actually WAS and gate the backend captures.
IFS=$'\t' read -r run_id telemetry_run_id scenario_id load_gen manifest_start_epoch manifest_target manifest_rt manifest_meas_start manifest_meas_end manifest_prior_status manifest_fault_applied manifest_fault_restored < <(
  jqd -r '[.runId,(.telemetryRunId//.runId),.scenarioId,(.workload.loadGenerator//"wrk"),(.startedEpoch//0),(.target//"local"),(.remoteTelemetry // false),(.measurementStartedEpoch // 0),(.measurementEndedEpoch // 0),(.status // ""),
    # (.faultApplied // "") would map a persisted `false` to "" (jq // treats false
    # like null), defeating the explicit fault-outcome guard; has() distinguishes an
    # absent key ("") from a real false ("false").
    (if has("faultApplied") then (.faultApplied|tostring) else "" end),(if has("faultRestored") then (.faultRestored|tostring) else "" end)] | @tsv' < "${manifest}")
manifest_target="${manifest_target:-local}"
[[ "${manifest_rt}" == "true" ]] && manifest_rt=1 || manifest_rt=0

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
target_mode="${manifest_target}"
remote_telemetry="${manifest_rt}"

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

mkdir -p "${artifact_dir}/source"

# ---------------------------------------------------------------------------
# Backend capture is two independent decisions:
#   capture_telemetry -- read Prometheus/Tempo/Loki. TRUE for a local target
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
if [[ "${target_mode}" == "local" ]]; then
  # Local owns the run: scope app metrics + traces by the exact perf.run.id.
  prom_run_id_matcher="${run_id_label}=\"${telemetry_run_id}\""      # standalone inside {...}
  prom_run_id_selector=",${run_id_label}=\"${telemetry_run_id}\""    # appended after another selector
  trace_run_id_pred=" && resource.${run_id_attr} = \"${telemetry_run_id}\""
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
[[ "${target_mode}" == "remote" ]] && \
  echo "Remote-observed: reading Prometheus/Tempo/Loki scoped by the measurement window ${start_epoch}-${end_epoch} (NOT run-id isolated; other traffic in the window is included)." >&2

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
if [[ "${target_mode}" == "remote" ]]; then
  # Remote-observed uses RANGE (window) queries so instance discovery below unions
  # every instance seen DURING the window -- an instance that restarted or scaled in
  # mid-window would be missed by an instant query taken only at capture time.
  capture_prometheus_range scenario_executions "${app_metric_prefix}_scenario_executions_total{${prom_run_id_matcher}}"
  capture_prometheus_range application_metrics "{__name__=~\"${app_metric_prefix}_.*\"${prom_run_id_selector}}"
else
  capture_prometheus_query scenario_executions "${app_metric_prefix}_scenario_executions_total{${prom_run_id_matcher}}"
  capture_prometheus_query application_metrics "{__name__=~\"${app_metric_prefix}_.*\"${prom_run_id_selector}}"
fi
# (No separate <prefix>_pool_* probe: neither lab exports app-level pool metrics,
# so it only ever produced an empty result[] file. The application_metrics query
# above already captures any <prefix>_pool_* series if a lab adds them, and the
# real connection-pool telemetry is database_pool_metrics.json from metrics.sh.)

service_instance_regex="$(jqd -r '[.data.result[]? | (.metric.service_instance_id // .metric.instance // empty)] | unique | join("|")' \
  < "${artifact_dir}/telemetry/metrics/application_metrics.json" 2>/dev/null || true)"
service_instance_regex="${service_instance_regex:-__no_correlated_service_instance__}"
# Remote-observed has no run-id fallback, so if the deployed app's meter prefix (or
# its Prometheus job) does not match, application_metrics is empty -> no correlated
# instance -> every runtime metric file comes back present-but-empty and the package
# would otherwise finalize "captured" and look diagnosable. Make that visible.
if [[ "${target_mode}" == "remote" && "${service_instance_regex}" == "__no_correlated_service_instance__" ]]; then
  echo "WARNING: no series matched \"${app_metric_prefix}_*\" with job=~\"${prom_job_regex}\" in the window; runtime metric files will be EMPTY. Check PERFLAB_APP_METRIC_PREFIX matches the deployed app and PERFLAB_PROM_JOB_REGEX its Prometheus job." >&2
  capture_incomplete=1
fi

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
trace_query="{ resource.service.name =~ \"${service_name_regex}\"${trace_run_id_pred} }"
trace_search_file="${artifact_dir}/telemetry/traces/search.json"
: > "${trace_search_file}"
tempo_reachable=0
for _ in $(seq 1 6); do
  # Stage through .tmp and promote only on success, so a later FAILED retry cannot
  # truncate a valid response an earlier retry already returned (empty or not).
  if curl -fsS --max-time 20 --get \
      --data-urlencode "q=${trace_query}" \
      --data-urlencode "start=${start_epoch}" --data-urlencode "end=${end_epoch}" --data-urlencode "limit=200" \
      "${tempo_url}/api/search" > "${trace_search_file}.tmp" 2>/dev/null; then
    tempo_reachable=1
    mv "${trace_search_file}.tmp" "${trace_search_file}"
    grep -q '"traceID"' "${trace_search_file}" 2>/dev/null && break
  fi
  rm -f "${trace_search_file}.tmp"; sleep 5
done
# An empty-but-reachable Tempo stays best-effort (ingest lag or sampling can leave a
# window with no traces). A TRANSPORT/HTTP failure on every retry is different: the
# backend was unreachable, so the traces are MISSING (not absent) -- mark partial.
if [[ "${tempo_reachable}" -eq 0 ]]; then
  echo "WARNING: Tempo unreachable at ${tempo_url} after retries; traces are MISSING." >&2
  capture_incomplete=1
fi

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
  if [[ "${trace_detail_failures}" -gt 0 ]]; then
    echo "WARNING: ${trace_detail_failures} trace detail fetch(es) failed; this evidence package is INCOMPLETE." >&2
    capture_incomplete=1
  fi
fi

# Loki logs. Retry with a temp file so a timeout cannot truncate the artifact.
# limit=2000 stays under Loki's 4 MiB gRPC message cap on verbose scenarios.
log_query="{service_name=~\"${service_name_regex}\"}"
log_file="${artifact_dir}/telemetry/logs/query-range.json"
: > "${log_file}"
log_reachable=0
for _ in $(seq 1 6); do
  if curl -fsS --max-time 30 --get \
      --data-urlencode "query=${log_query}" \
      --data-urlencode "start=${start_epoch}000000000" --data-urlencode "end=${end_epoch}000000000" \
      --data-urlencode "limit=2000" \
      "${loki_url}/loki/api/v1/query_range" > "${log_file}.tmp" 2>/dev/null; then
    log_reachable=1
    mv "${log_file}.tmp" "${log_file}"
    grep -q '"values":\[\[' "${log_file}" 2>/dev/null && break
  fi
  rm -f "${log_file}.tmp"; sleep 5
done
# A silently empty capture is worse than a loud failure: it makes an incomplete
# package look diagnosable. Empty-but-reachable stays best-effort; unreachable on
# every retry (transport/HTTP failure) makes the logs MISSING -> mark partial.
grep -q '"values":\[\[' "${log_file}" 2>/dev/null || \
  echo "WARNING: log capture produced no entries at ${log_file}; treat these logs as MISSING, not as evidence of a quiet run." >&2
if [[ "${log_reachable}" -eq 0 ]]; then
  echo "WARNING: Loki unreachable at ${loki_url} after retries; logs are MISSING." >&2
  capture_incomplete=1
fi

fi   # end capture_telemetry

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

  # Optional runtime-adapter evidence captured at measurement time.
  if [[ -f "${runtime_adapter_dir}/evidence-extra.sh" ]]; then
    bash "${runtime_adapter_dir}/evidence-extra.sh" "${artifact_dir}" || true
  fi
fi

# A plain black-box remote run (no telemetry read, no ownership) has only facts.json.
if [[ "${target_mode}" == "remote" && "${capture_telemetry}" != "1" ]]; then
  echo "Remote (black-box): skipping all backend capture (Prometheus/Tempo/Loki/dependencies/runtime); facts.json from the load generator is the evidence." >&2
fi

# Tool versions (generic + runtime adapter probe). Runtime-neutral, both targets.
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

# Per-request EFFICIENCY (derived facts): normalize resource use by throughput --
# CPU-ms, allocated bytes, GC-pause-ms and dependency-ms per request over the
# measure window. These catch the regression absolute latency hides ("same p99,
# 2x the CPU/allocations per request") and are gate-able / comparable / trendable
# like any other observation. Best-effort: if Prometheus is unreachable (a
# black-box remote run) or the app emitted no requests, the queries no-op and
# facts.json is left unchanged. Rates cancel the window, so cpu-seconds/request *
# 1000 = cpu-ms/request, independent of run length.
eff_window=$(( end_epoch - start_epoch )); (( eff_window < 1 )) && eff_window=1
eff_si="${service_instance_regex:-.+}"
eff_reqrate="sum(rate(http_server_request_duration_seconds_count{service_instance_id=~\"${eff_si}\",http_route!~\"/health.*|\"}[${eff_window}s]))"
prom_scalar() {
  curl -fsS -G "${prometheus_url}/api/v1/query" \
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
if [[ "${capture_incomplete}" -eq 1 ]]; then
  echo "NOTE: package finalized status:\"partial\" -- a required capture failed or a prior partial/fault outcome is sticky (see WARNINGs above)." >&2
fi

# Stamp the capture status onto facts.json too, so a single facts.json is
# self-describing and gate.sh can refuse a partial package (whose available
# metrics might meet SLOs only because a required capture failed) even when it is
# handed the facts file directly, without the sibling manifest.
if jqd --arg st "${capture_status}" '.status=$st' < "${artifact_dir}/facts.json" > "${artifact_dir}/facts.json.tmp" 2>/dev/null; then
  mv "${artifact_dir}/facts.json.tmp" "${artifact_dir}/facts.json"
else
  rm -f "${artifact_dir}/facts.json.tmp"
fi
