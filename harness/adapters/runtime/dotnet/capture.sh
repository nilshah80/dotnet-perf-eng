#!/usr/bin/env bash
# dotnet runtime adapter -- capture in-process diagnostics via the dotnet-monitor
# sidecar. Invoked by harness/core/capture/capture-runtime.sh, which has already
# recreated the app in diagnose mode and exported the workload env
# (PERF_METHOD/PATH/BODY/BASE_URL, PERFLAB_CONNECTIONS, PERFLAB_DURATION_SECONDS,
# PERFLAB_LOAD_GENERATOR, PERF_SCENARIO).
#
# Contract:  capture.sh <artifact-dir> <requested-kind|preset:name> <duration-seconds> <target-service>
# Kinds:     trace | gcdump | stacks | dump
# Presets:   cpu | memory | cpu-memory | hang | dump
set -euo pipefail
HARNESS_ROOT="${PERFLAB_HARNESS_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
# shellcheck disable=SC1091
source "${HARNESS_ROOT}/core/lib/common.sh"

artifact_dir="${1:?capture.sh <artifact-dir> <kind> <duration> <target-service>}"
requested_kind="${2:?diagnostic kind required}"
duration_seconds="${3:-30}"
target="${4:?target service required}"
campaign_preset=""
if [[ "${requested_kind}" == preset:* ]]; then
  campaign_preset="${requested_kind#preset:}"
  requested_kind="${campaign_preset}"
fi

assembly_name="$(diag_target "${target}" || true)"
if [[ -z "${assembly_name}" ]]; then
  echo "No PERFLAB_DIAG_TARGETS mapping for app service '${target}'." >&2
  exit 1
fi

# Stacks are captured directly by default. An operator can explicitly disable
# that endpoint and retain the recorded CPU-trace fallback for an environment
# where dotnet-monitor's in-process stack channel is unavailable.
kind="${requested_kind}"
fallback_reason=""
if [[ -z "${campaign_preset}" && "${kind}" == "stacks" && "${PERFLAB_ENABLE_DOTNET_MONITOR_STACKS:-false}" != "true" ]]; then
  kind="trace"
  fallback_reason="dotnet-monitor /stacks is disabled by default because its in-process profiler channel is unreliable in this Docker Desktop sidecar topology"
  echo "Requested stacks for ${target}; capturing a CPU trace fallback instead."
  echo "Set PERFLAB_ENABLE_DOTNET_MONITOR_STACKS=true to explicitly retry /stacks."
fi

mkdir -p "${artifact_dir}/runtime"
capture_json="${artifact_dir}/runtime/capture.json"
if [[ -z "${campaign_preset}" ]]; then
  mkdir -p "${artifact_dir}/runtime/${target}"
  fb_field=""
  [[ -n "${fallback_reason}" ]] && fb_field=",\"fallbackReason\":\"$(json_escape "${fallback_reason}")\""
  printf '{"scenarioId":"%s","target":"%s","loadGenerator":"%s","requestedDiagnostic":"%s","effectiveDiagnostic":"%s","durationSeconds":%s,"startedAt":"%s","status":"running"%s}\n' \
    "$(json_escape "${PERF_SCENARIO:-}")" "$(json_escape "${target}")" "$(json_escape "${load_generator}")" \
    "$(json_escape "${requested_kind}")" "$(json_escape "${kind}")" "${duration_seconds}" \
    "$(json_escape "$(date -u +%Y-%m-%dT%H:%M:%SZ)")" "${fb_field}" > "${capture_json}"
fi

processes_file="${artifact_dir}/runtime/processes-diagnostic.json"
curl -fsS "${diagnostics_url}/processes" > "${processes_file}"
runtime_uid="$(jqd -r --arg a "${assembly_name}" \
  '.[] | select(((.managedEntryPointAssemblyName // "") | contains($a)) or ((.name // "") | contains($a))) | .uid' \
  < "${processes_file}" | head -1)"
if [[ -z "${runtime_uid}" || "${runtime_uid}" == "null" ]]; then
  echo "Could not find ${assembly_name} in dotnet-monitor /processes." >&2
  exit 1
fi

campaign_load_dir="${artifact_dir}/runtime/campaign-load"
run_load() {
  if [[ -n "${campaign_preset}" ]]; then
    mkdir -p "${campaign_load_dir}"
    loadgen_measure "${campaign_load_dir}" diagnostic
  else
    loadgen_measure "${artifact_dir}" diagnostic
  fi
}
out="${artifact_dir}/runtime/${target}"

# The capture runs a background load while curl pulls the artifact. If curl fails,
# `set -e` aborts before the `wait`, so a cleanup trap kills the background load on
# ANY exit (else it keeps hammering the app after the run). And every binary is
# staged through a .tmp so a failed fetch cannot leave a partial artifact that
# looks like a real capture.
load_pid=""
counters_pid=""
cleanup_load() {
  if [[ -n "${load_pid}" ]]; then
    kill "${load_pid}" 2>/dev/null || true
    wait "${load_pid}" 2>/dev/null || true
  fi
  # A counters stream outlives a failed trace pull otherwise, holding an
  # EventPipe session open against a process the run has already abandoned.
  if [[ -n "${counters_pid}" ]]; then
    kill "${counters_pid}" 2>/dev/null || true
    wait "${counters_pid}" 2>/dev/null || true
  fi
}
trap cleanup_load EXIT INT TERM

pull() {  # pull <dest-file> <curl-arg>...
  local dest="$1"; shift
  if curl -fsS "$@" > "${dest}.tmp"; then
    mv "${dest}.tmp" "${dest}"
  else
    rm -f "${dest}.tmp"
    echo "Diagnostic fetch failed for ${target} (${dest##*/}); the capture is incomplete." >&2
    exit 1   # the EXIT trap stops the background load; capture.json stays "running"
  fi
}

try_pull() { # try_pull <dest-file> <curl-arg>...
  local dest="$1"; shift
  if curl -fsS "$@" > "${dest}.tmp"; then
    mv "${dest}.tmp" "${dest}"
    return 0
  fi
  rm -f "${dest}.tmp"
  return 1
}

if [[ -n "${campaign_preset}" ]]; then
  campaign_json="${artifact_dir}/runtime/campaign.json"
  captures_root="${artifact_dir}/runtime/captures"
  mkdir -p "${captures_root}" "${campaign_load_dir}"
  campaign_started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  recovery_seconds="${PERFLAB_DIAGNOSTIC_RECOVERY_SECONDS:-2}"
  budget_bytes="${PERFLAB_DIAGNOSTIC_ARTIFACT_BUDGET_BYTES:-1073741824}"
  include_dump="${PERFLAB_DIAGNOSTIC_INCLUDE_DUMP:-0}"
  campaign_failures=0
  campaign_successes=0
  campaign_load_state="not-applicable"
  campaign_load_reason=""
  warmup_state="not-applicable"
  warmup_reason=""

  printf '{"scenarioId":"%s","sourceRunId":"%s","target":"%s","loadGenerator":"%s","requestedPreset":"%s","effectivePreset":"%s","durationSeconds":%s,"recoverySeconds":%s,"artifactBudgetBytes":%s,"gateEligible":false,"startedAt":"%s","status":"running","captures":[]}\n' \
    "$(json_escape "${PERF_SCENARIO:-}")" "$(json_escape "${PERF_RUN_ID:-}")" "$(json_escape "${target}")" \
    "$(json_escape "${load_generator}")" "$(json_escape "${campaign_preset}")" "$(json_escape "${campaign_preset}")" \
    "${duration_seconds}" "${recovery_seconds}" "${budget_bytes}" "$(json_escape "${campaign_started}")" > "${campaign_json}"

  write_campaign_capture() { # id sequence requested effective state start end reason artifact
    local stage_id="$1" sequence="$2" requested="$3" effective="$4" state="$5" started="$6" completed="$7" reason="$8" artifact="${9:-}"
    local stage_dir="${captures_root}/${stage_id}" artifacts='[]'
    mkdir -p "${stage_dir}"
    [[ -n "${artifact}" ]] && artifacts="[\"$(json_escape "${artifact}")\"]"
    printf '{"id":"%s","sequence":%s,"requestedDiagnostic":"%s","effectiveDiagnostic":"%s","captureState":"%s","startedAt":"%s","completedAt":"%s","reason":"%s","artifactPaths":%s,"gateEligible":false}\n' \
      "$(json_escape "${stage_id}")" "${sequence}" "$(json_escape "${requested}")" "$(json_escape "${effective}")" \
      "$(json_escape "${state}")" "$(json_escape "${started}")" "$(json_escape "${completed}")" "$(json_escape "${reason}")" "${artifacts}" \
      > "${stage_dir}/capture.json"
  }

  campaign_snapshot() { # id sequence requested filename endpoint [curl args...]
    local stage_id="$1" sequence="$2" requested="$3" filename="$4" endpoint="$5"; shift 5
    local stage_dir="${captures_root}/${stage_id}" started completed relative
    mkdir -p "${stage_dir}"
    started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    relative="runtime/captures/${stage_id}/${filename}"
    if try_pull "${stage_dir}/${filename}" --get --data-urlencode "uid=${runtime_uid}" "$@" "${diagnostics_url}/${endpoint}"; then
      completed="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      write_campaign_capture "${stage_id}" "${sequence}" "${requested}" "${requested}" captured "${started}" "${completed}" "" "${relative}"
      campaign_successes=$((campaign_successes + 1))
    else
      completed="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      write_campaign_capture "${stage_id}" "${sequence}" "${requested}" "${requested}" failed "${started}" "${completed}" "dotnet-monitor ${endpoint} request failed" ""
      campaign_failures=$((campaign_failures + 1))
      echo "Campaign stage ${stage_id} failed; continuing so independent evidence is retained." >&2
    fi
  }

  campaign_trace() { # sequence
    local sequence="$1" stage_dir="${captures_root}/trace" started completed trace_ok=0 load_ok=0 reason=""
    mkdir -p "${stage_dir}"
    started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    run_load & load_pid=$!
    if try_pull "${stage_dir}/cpu.nettrace" --get --data-urlencode "uid=${runtime_uid}" \
      --data-urlencode "durationSeconds=${duration_seconds}" --data-urlencode "profile=cpu" "${diagnostics_url}/trace"; then
      trace_ok=1
    else
      reason="dotnet-monitor trace request failed"
    fi
    if wait "${load_pid}"; then
      load_ok=1; campaign_load_state="captured"
    else
      campaign_load_state="failed"; campaign_load_reason="diagnostic load generator failed"
      reason="${reason:+${reason}; }${campaign_load_reason}"
    fi
    load_pid=""
    completed="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    if (( trace_ok == 1 )); then
      write_campaign_capture trace "${sequence}" trace trace captured "${started}" "${completed}" "${reason}" "runtime/captures/trace/cpu.nettrace"
      campaign_successes=$((campaign_successes + 1))
      if (( load_ok == 0 )); then
        campaign_failures=$((campaign_failures + 1))
      fi
    else
      write_campaign_capture trace "${sequence}" trace trace failed "${started}" "${completed}" "${reason}" "$([[ ${trace_ok} == 1 ]] && printf runtime/captures/trace/cpu.nettrace)"
      campaign_failures=$((campaign_failures + 1))
    fi
  }

  # The warm-up and diagnostic generator output live below runtime/campaign-load,
  # never in benchmark/, so measurement facts and observations remain immutable.
  if [[ "${campaign_preset}" != "dump" ]]; then
    export PERFLAB_WARMUP_SECONDS="${PERFLAB_WARMUP_SECONDS:-5}"
    if loadgen_warmup "${campaign_load_dir}"; then
      warmup_state="captured"
    else
      warmup_state="failed"; warmup_reason="diagnostic warm-up failed"
      campaign_failures=$((campaign_failures + 1))
    fi
  fi

  case "${campaign_preset}" in
    cpu)
      campaign_trace 1
      ;;
    memory)
      campaign_snapshot gcdump-before 1 gcdump before.gcdump gcdump
      sleep "${recovery_seconds}"
      if run_load; then campaign_load_state="captured"; else campaign_load_state="failed"; campaign_load_reason="diagnostic load generator failed"; campaign_failures=$((campaign_failures + 1)); fi
      campaign_snapshot gcdump-after 2 gcdump after.gcdump gcdump
      ;;
    cpu-memory)
      campaign_snapshot gcdump-before 1 gcdump before.gcdump gcdump
      sleep "${recovery_seconds}"
      campaign_trace 2
      campaign_snapshot gcdump-after 3 gcdump after.gcdump gcdump
      ;;
    hang)
      campaign_trace 1
      if [[ "${include_dump}" == "1" ]]; then
        campaign_snapshot dump 2 dump process.dmp dump --data-urlencode "type=WithHeap"
      fi
      ;;
    dump)
      campaign_snapshot dump 1 dump process.dmp dump --data-urlencode "type=WithHeap"
      ;;
  esac

  runtime_bytes=0
  while IFS= read -r runtime_file; do
    file_bytes="$(wc -c < "${runtime_file}" | tr -d ' ')"
    runtime_bytes=$((runtime_bytes + file_bytes))
  done < <(find "${artifact_dir}/runtime" -type f -print)
  if (( runtime_bytes > budget_bytes )); then
    campaign_failures=$((campaign_failures + 1))
    echo "Runtime campaign produced ${runtime_bytes} bytes, exceeding its ${budget_bytes}-byte budget." >&2
  fi

  captures_json="["; separator=""
  for sequence in 1 2 3; do
    for stage_file in "${captures_root}"/*/capture.json; do
      [[ -f "${stage_file}" ]] || continue
      stage_content="$(tr -d '\r\n' < "${stage_file}")"
      [[ "${stage_content}" == *"\"sequence\":${sequence},"* ]] || continue
      captures_json+="${separator}${stage_content}"
      separator=","
    done
  done
  captures_json+="]"
  campaign_state="captured"
  if (( campaign_failures > 0 )); then
    campaign_state="partial"
    (( campaign_successes == 0 )) && campaign_state="failed"
  fi
  campaign_completed="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '{"scenarioId":"%s","sourceRunId":"%s","target":"%s","loadGenerator":"%s","requestedPreset":"%s","effectivePreset":"%s","durationSeconds":%s,"recoverySeconds":%s,"artifactBudgetBytes":%s,"runtimeBytes":%s,"gateEligible":false,"warmupState":"%s","warmupReason":"%s","diagnosticLoadState":"%s","diagnosticLoadReason":"%s","startedAt":"%s","completedAt":"%s","status":"%s","captures":%s}\n' \
    "$(json_escape "${PERF_SCENARIO:-}")" "$(json_escape "${PERF_RUN_ID:-}")" "$(json_escape "${target}")" \
    "$(json_escape "${load_generator}")" "$(json_escape "${campaign_preset}")" "$(json_escape "${campaign_preset}")" \
    "${duration_seconds}" "${recovery_seconds}" "${budget_bytes}" "${runtime_bytes}" "${warmup_state}" "$(json_escape "${warmup_reason}")" \
    "${campaign_load_state}" "$(json_escape "${campaign_load_reason}")" "$(json_escape "${campaign_started}")" "$(json_escape "${campaign_completed}")" \
    "${campaign_state}" "${captures_json}" > "${campaign_json}"
  echo "Runtime diagnostic campaign ${campaign_preset} completed as ${campaign_state}."
  if [[ "${campaign_state}" == "captured" ]]; then exit 0; else exit 2; fi
fi

# Runtime counters. EventCounters come from the runtime's own System.Runtime
# source, so this needs NO application change -- only a subscriber. We use
# dotnet-monitor's /livemetrics rather than `dotnet-counters` on purpose: the
# tools container mounts neither /diag nor the app PID namespace, and the
# runtime connects to its diagnostic ports at STARTUP, so a counters listener
# started mid-run would never receive a connection. /livemetrics rides the
# sidecar's existing connection, needs no compose change, and cannot wedge the
# app's boot path. Best-effort: a failure is recorded, never fatal, because the
# trace/gcdump is the primary artifact of this phase.
# Runs in a BACKGROUND subshell, so it reports through a state file rather than
# a variable: a subshell's assignments never reach the parent.
counters_status_file="${artifact_dir}/runtime/.counters-state"
capture_counters() { # capture_counters <out-dir> <seconds>
  # /livemetrics returns RFC 7464 application/json-seq: each record is preceded
  # by an ASCII RS (0x1E), so this is neither a JSON document nor newline-
  # delimited JSON. The extension says so, and the parse below uses jq --seq --
  # without it even a well-formed capture fails to parse.
  local dest="$1/counters.json-seq" seconds="$2" http="" records=0
  http="$(curl -sS --max-time $((seconds + 30)) -o "${dest}.tmp" -w '%{http_code}' --get \
    --data-urlencode "uid=${runtime_uid}" --data-urlencode "durationSeconds=${seconds}" \
    "${diagnostics_url}/livemetrics" 2>/dev/null || true)"
  case "${http}" in
    2[0-9][0-9])
      # A 2xx with an empty or unparseable body is NOT a capture. Every record is
      # PARSED rather than pattern-matched: a substring test would accept
      # malformed JSON that merely contains the text "name", and would count
      # lines instead of records. jq slurps the newline-delimited sequence and
      # fails outright on malformed content, so records stays 0 and the capture
      # is marked missing -- the same absent-as-healthy trap the log and metric
      # states now close.
      # --seq is needed to PARSE the input, but jq also emits an RS (0x1E) before
      # its own output, so the result arrives as $'\x1e186'. Strip it before the
      # numeric guard: without this the guard rejects every valid capture and
      # marks it missing -- inverting the failure this validation exists to catch.
      #
      # jq is deliberately lenient here, and so are we: RFC 7464 defines a
      # truncated record as skippable, which is the point of the format for a
      # streamed response. A stream cut short still yields the records that did
      # arrive, so the count is "records that parsed", not "the stream was
      # pristine". Zero parsed records is the condition that means no evidence.
      records="$(jqd --seq -s '[.[] | select(type == "object" and has("name"))] | length' < "${dest}.tmp" 2>/dev/null | tr -d '\036' || echo 0)"
      [[ "${records}" =~ ^[0-9]+$ ]] || records=0
      if [[ "${records}" -gt 0 ]]; then
        mv "${dest}.tmp" "${dest}"
        printf 'captured\t%s\t\n' "${records}" > "${counters_status_file}"
      else
        rm -f "${dest}.tmp"
        printf 'missing\t0\tdotnet-monitor /livemetrics returned HTTP %s with no counter records\n' "${http}" > "${counters_status_file}"
      fi
      ;;
    ""|000)      rm -f "${dest}.tmp"; printf 'failed\t0\tdotnet-monitor /livemetrics unreachable\n' > "${counters_status_file}" ;;
    *)           rm -f "${dest}.tmp"; printf 'failed\t0\tdotnet-monitor /livemetrics returned HTTP %s\n' "${http}" > "${counters_status_file}" ;;
  esac
}
read_counters_state() {
  if [[ -s "${counters_status_file}" ]]; then
    IFS=$'\t' read -r counters_state counters_records counters_reason < "${counters_status_file}" || true
    rm -f "${counters_status_file}"
  fi
}
counters_state="not-applicable"; counters_reason="runtime counters were not requested for this capture kind"; counters_records=0

case "${kind}" in
  trace)
    run_load & load_pid=$!
    capture_counters "${out}" "${duration_seconds}" &
    counters_pid=$!
    pull "${out}/cpu.nettrace" --get --data-urlencode "uid=${runtime_uid}" \
      --data-urlencode "durationSeconds=${duration_seconds}" --data-urlencode "profile=cpu" \
      "${diagnostics_url}/trace"
    wait "${load_pid}"; load_pid=""
    wait "${counters_pid}" 2>/dev/null || true; counters_pid=""
    read_counters_state
    ;;
  gcdump)
    pull "${out}/before.gcdump" --get --data-urlencode "uid=${runtime_uid}" "${diagnostics_url}/gcdump"
    capture_counters "${out}" "${duration_seconds}" &
    counters_pid=$!
    run_load
    wait "${counters_pid}" 2>/dev/null || true; counters_pid=""
    read_counters_state
    pull "${out}/after.gcdump" --get --data-urlencode "uid=${runtime_uid}" "${diagnostics_url}/gcdump"
    ;;
  stacks)
    run_load & load_pid=$!
    sleep 5
    pull "${out}/stacks.txt" --get --data-urlencode "uid=${runtime_uid}" "${diagnostics_url}/stacks"
    wait "${load_pid}"; load_pid=""
    ;;
  dump)
    run_load & load_pid=$!
    sleep 5
    pull "${out}/process.dmp" --get --data-urlencode "uid=${runtime_uid}" --data-urlencode "type=WithHeap" "${diagnostics_url}/dump"
    wait "${load_pid}"; load_pid=""
    ;;
  *)
    echo "Unknown diagnostic '${kind}'. Use trace, gcdump, stacks, or dump." >&2
    exit 1
    ;;
esac

# Finalize capture.json: replace the transient "running" status with a terminal
# "captured" and append completedAt (append-only edit, no jq). The initial write
# emits ...,"status":"running"[,"fallbackReason":...]; strip that status token
# first so the finalized object carries exactly one status key (a duplicate key
# is ambiguous JSON -- last-wins parsers say captured, strict/first-wins say
# running, which would falsely read as "capture never completed").
content="$(cat "${capture_json}")"; content="${content%\}}"
running_status=',"status":"running"'; content="${content/${running_status}/}"
# Known limits of THIS capture, recorded as evidence rather than left for the
# reader to infer. Absence of a limitation must be a claim, not an oversight.
limitations='['
limitations+='"Speedscope retains CPU samples only; GC, contention and exception events present in the .nettrace are not normalized (read the raw trace for those)."'
limitations+=',"Only symbols embedded in the captured artifacts are resolved; no external symbol server is contacted."'
[[ "${kind}" == "trace" ]] && limitations+=',"profile=cpu enables Microsoft-Windows-DotNETRuntime 0x14C14FCCBD at Informational; GCAllocationTick is Verbose and AllocationSampling needs keyword 0x80000000000, so per-call-site allocation is NOT in this trace."'
[[ -n "${fallback_reason}" ]] && limitations+=",\"$(json_escape "${fallback_reason}")\""
[[ "${counters_state}" == "failed" || "${counters_state}" == "missing" ]] && limitations+=",\"$(json_escape "runtime counters unavailable: ${counters_reason}")\""
limitations+=']'
printf '%s,"counters":{"captureState":"%s","reason":"%s","records":%s,"source":"dotnet-monitor /livemetrics","format":"application/json-seq"},"limitations":%s,"completedAt":"%s","status":"captured"}\n' \
  "${content}" "$(json_escape "${counters_state}")" "$(json_escape "${counters_reason}")" "${counters_records:-0}" "${limitations}" \
  "$(json_escape "$(date -u +%Y-%m-%dT%H:%M:%SZ)")" > "${capture_json}"
echo "Captured ${kind} for ${target} (counters: ${counters_state})."
