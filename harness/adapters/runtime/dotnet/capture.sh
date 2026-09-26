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
# shellcheck disable=SC1091
source "${HARNESS_ROOT}/adapters/runtime/dotnet/capability.sh"
# The real retention helper, never a fixture: a dump must leave the package.
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../core/lib" && pwd)/sensitive-evidence.sh"

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

diagnostics_url="$(diag_endpoint "${target}")"

# D-P0-3. /stacks injects ICorProfiler. Pyroscope already occupies that slot
# on a measured process, so the measurement default is the recorded CPU-trace
# fallback. Diagnose-mode recreates an owned app with Pyroscope off and sets
# PERFLAB_ENABLE_DOTNET_MONITOR_STACKS=true so the call-stack channel can load.
# Do not use dotnet-stack (dotnet/diagnostics#5444 is open; no diagnostic port).
kind="${requested_kind}"
fallback_reason=""
dotnet_monitor_stacks_capture_allowed() {
  [[ "${PERFLAB_ENABLE_DOTNET_MONITOR_STACKS:-false}" == "true" ]] || return 1
  [[ "${PERFLAB_CONTINUOUS_PROFILING:-0}" != "1" ]] || return 1
  [[ "${target_mode:-local}" != "remote" ]] || return 1
  [[ "${PERFLAB_TARGET_KIND:-managed-compose}" == "managed-compose" ]] || return 1
  return 0
}
if [[ -z "${campaign_preset}" && "${kind}" == "stacks" ]]; then
  if [[ "${PERFLAB_STACKS_FORCE_TRACE:-0}" == "1" ]]; then
    kind="trace"
    fallback_reason="dotnet-monitor /stacks is not reliable after continuous profiling; this diagnose capture retains the CPU-trace fallback"
    echo "Requested stacks for ${target} after continuous profiling; capturing a CPU trace fallback instead."
  elif [[ "${PERFLAB_ENABLE_DOTNET_MONITOR_STACKS:-false}" != "true" ]]; then
    kind="trace"
    fallback_reason="dotnet-monitor /stacks is disabled during measurement because it injects ICorProfiler, which conflicts with Pyroscope; diagnose-mode recreates an owned app with profiling off"
    echo "Requested stacks for ${target}; capturing a CPU trace fallback instead."
    echo "Diagnose-mode capture-runtime.sh enables /stacks after recreating with PERFLAB_CONTINUOUS_PROFILING=0."
  elif [[ "${PERFLAB_CONTINUOUS_PROFILING:-0}" == "1" ]]; then
    kind="trace"
    fallback_reason="dotnet-monitor /stacks cannot share ICorProfiler with Pyroscope; the process still has continuous profiling loaded"
    echo "Requested stacks for ${target} while Pyroscope is loaded; capturing a CPU trace fallback instead."
  elif [[ "${target_mode:-local}" == "remote" || "${PERFLAB_TARGET_KIND:-managed-compose}" != "managed-compose" ]]; then
    kind="trace"
    fallback_reason="dotnet-monitor /stacks is refused on a remote or attach-only target because it injects ICorProfiler into a process this run does not own"
    echo "Requested stacks for ${target} on a remote or attach-only target; capturing a CPU trace fallback instead."
  fi
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

# Even a capability or identity refusal must leave a terminal capture state.
finalize_failed_capture() {
  local rc="$1"
  [[ -s "${capture_json}" ]] || return 0
  if jqd -e '.status == "running"' < "${capture_json}" >/dev/null 2>&1; then
    jqd --argjson code "${rc}" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)"       '.status="failed" | .exitCode=$code | .finishedAt=$at' < "${capture_json}" > "${capture_json}.tmp"       && mv "${capture_json}.tmp" "${capture_json}"
  fi
}
trap 'rc=$?; finalize_failed_capture "${rc}"' EXIT

processes_file="${artifact_dir}/runtime/processes-diagnostic.json"
monitor_curl -fsS "${diagnostics_url}/processes" > "${processes_file}"
# D-P0-1. Selecting with `head -1` silently attached to the FIRST process whose
# assembly matched, which is wrong the moment two replicas share an assembly:
# protocol-reliability maps api-a and api-b to ProtocolReliability.Api, so a
# capture requested for api-b produced api-a's trace under api-b's name. No
# error, no warning, and every number downstream attributed to the wrong
# process. Ambiguity must fail closed, and the identity that was actually
# attached must be recorded so a reader can check it rather than trust it.
runtime_uids=()
while IFS= read -r matched_uid; do
  [[ -n "${matched_uid}" ]] && runtime_uids+=("${matched_uid}")
done < <(jqd -r --arg a "${assembly_name}" \
  '.[] | select(((.managedEntryPointAssemblyName // "") | contains($a)) or ((.name // "") | contains($a))) | .uid' \
  < "${processes_file}")
if [[ "${#runtime_uids[@]}" -eq 0 ]]; then
  echo "Could not find ${assembly_name} in dotnet-monitor /processes." >&2
  exit 1
fi
if [[ "${#runtime_uids[@]}" -gt 1 ]]; then
  echo "Ambiguous diagnostic target: ${#runtime_uids[@]} processes match assembly '${assembly_name}' for service '${target}'." >&2
  echo "  Matching uids: ${runtime_uids[*]}" >&2
  echo "  Attaching to any of them would attribute this capture to a process that may not be '${target}'." >&2
  echo "  Give each replica a distinct assembly name or its own dotnet-monitor endpoint (PERFLAB_DIAGNOSTICS_URL per service)." >&2
  exit 1
fi
runtime_uid="${runtime_uids[0]}"
# The pid from the LIST, kept so the detail response can be checked against the
# entry that was actually selected.
list_pid="$(jqd -r --arg uid "${runtime_uid}" '[.[] | select(.uid == $uid)][0].pid // ""' < "${processes_file}" 2>/dev/null || echo "")"
if [[ -z "${runtime_uid}" || "${runtime_uid}" == "null" ]]; then
  echo "Could not find ${assembly_name} in dotnet-monitor /processes." >&2
  exit 1
fi

# Independent identity proof. The uid alone says which process dotnet-monitor
# picked; these say WHICH process that actually is, so a wrong attach is
# visible in the evidence instead of inferred from a service label.
# Independent identity proof. The uid alone says which process dotnet-monitor
# picked; these say WHICH process that actually is, so a wrong attach is visible
# in the evidence instead of inferred from a service label.
#
# This reads /process?uid=, not the /processes list. The list carries only
# pid/uid/name -- it has no command line, architecture or assembly name -- so an
# identity built from it recorded nulls for every field that could actually
# identify anything, while looking like a complete record. The endpoint itself is
# part of the identity too: "the only process matching this assembly" is a claim
# about one monitor, and two labs pointed at two sidecars both answer it.
target_identity_file="${artifact_dir}/runtime/target-identity.json"
target_detail_file="${artifact_dir}/runtime/process-detail.json"
if ! monitor_curl -fsS --get --data-urlencode "uid=${runtime_uid}" "${diagnostics_url}/process" > "${target_detail_file}"; then
  echo "Could not read process detail for uid ${runtime_uid} from ${diagnostics_url}." >&2
  echo "  Without it the capture would be attributed to a process nothing in the evidence identifies." >&2
  exit 1
fi
if ! jqd -c --arg svc "${target}" --arg asm "${assembly_name}" \
  --arg endpoint "${diagnostics_url}" --arg run "${PERF_RUN_ID:-}" \
  '{requestedService: $svc, expectedAssembly: $asm, uid: .uid,
    diagnosticsEndpoint: $endpoint, runId: $run,
    processId: .pid, name: .name,
    managedEntryPointAssemblyName: .managedEntryPointAssemblyName,
    commandLine: .commandLine, operatingSystem: .operatingSystem,
    processArchitecture: .processArchitecture,
    selection: "single-match", matchedProcesses: 1}' \
  < "${target_detail_file}" > "${target_identity_file}"; then
  echo "Could not record the diagnostic target identity for '${target}'." >&2
  exit 1
fi
# An identity that does not name the process proves nothing. This used to be
# written with `|| true` from the list endpoint, so a package looked complete
# while the one artifact saying WHICH process was attached held nulls -- the same
# absent-as-healthy failure the capture states exist to stop.
if ! jqd -e '(.uid // "") != "" and (.processId != null) and ((.commandLine // "") != "")' \
     < "${target_identity_file}" >/dev/null 2>&1; then
  echo "Recorded target identity is incomplete: $(cat "${target_identity_file}" 2>/dev/null || echo '<empty>')" >&2
  echo "  dotnet-monitor returned no pid or command line for uid ${runtime_uid}, so the attach cannot be verified." >&2
  exit 1
fi
# Confirm the detail describes the SAME process the selection picked. Two calls
# to a live monitor are two moments: a restart between them can reuse a uid or
# renumber a pid, and checking only that the detail is populated would accept a
# different process silently. Three things must agree -- the uid asked for, the
# pid from the list entry, and the assembly the service maps to.
detail_uid="$(jqd -r '.uid // ""' < "${target_identity_file}")"
if [[ "${detail_uid}" != "${runtime_uid}" ]]; then
  echo "Target identity mismatch: asked ${diagnostics_url}/process for uid '${runtime_uid}', got '${detail_uid}'." >&2
  echo "  The monitor answered about a different process than the one selected." >&2
  exit 1
fi
detail_pid="$(jqd -r '.processId // ""' < "${target_identity_file}")"
if [[ -n "${list_pid}" && "${list_pid}" != "null" && "${detail_pid}" != "${list_pid}" ]]; then
  echo "Target identity mismatch: uid ${runtime_uid} was pid ${list_pid} in /processes and pid ${detail_pid} in /process." >&2
  echo "  The process was replaced between the two calls; attributing this capture to '${target}' would be a guess." >&2
  exit 1
fi
detail_assembly="$(jqd -r '.managedEntryPointAssemblyName // ""' < "${target_identity_file}")"
if [[ "${detail_assembly}" != *"${assembly_name}"* ]]; then
  echo "Target identity mismatch: uid ${runtime_uid} reports assembly '${detail_assembly}', expected '${assembly_name}' for service '${target}'." >&2
  echo "  Refusing to attribute this capture to '${target}'." >&2
  exit 1
fi

# Container and image identity, plus a command hash. The assembly name is shared
# by every replica of a service, so it cannot tell two of them apart; the image
# digest and container ID can, and the command hash makes an argument change
# visible between two runs that otherwise look identical. Best-effort: an
# attach-only or non-container target has no compose entry, and that is recorded
# as not-applicable rather than failing a capture that is otherwise sound.
container_identity="{}"
if container_row="$(compose ps --format json "${target}" 2>/dev/null | jqd -sc '(.[0] // .) | select(type == "object")' 2>/dev/null)" \
   && [[ -n "${container_row}" && "${container_row}" != "null" ]]; then
  container_id="$(printf '%s' "${container_row}" | jqd -r '.ID // ""' 2>/dev/null || echo "")"
  image_ref="$(printf '%s' "${container_row}" | jqd -r '.Image // ""' 2>/dev/null || echo "")"
  image_digest=""
  if [[ -n "${container_id}" ]]; then
    image_digest="$(docker inspect --format '{{.Image}}' "${container_id}" 2>/dev/null || echo "")"
  fi
  # A container we FOUND but cannot digest is a failure, not a partial success.
  # The image digest is the only field that distinguishes two replicas running
  # different builds of the same service; letting an inspect failure degrade to
  # an empty string produced an identity that looked recorded and identified
  # nothing -- precisely the absent-as-healthy shape these states exist to stop.
  if [[ -z "${container_id}" || -z "${image_digest}" ]]; then
    echo "Container identity for '${target}' is incomplete (container='${container_id:-}' digest='${image_digest:-}')." >&2
    echo "  The target runs in a container this run can see, so its image digest is required: without it two replicas on different builds are indistinguishable in the evidence." >&2
    exit 1
  fi
  container_identity="$(jqd -nc --arg cid "${container_id}" --arg image "${image_ref}" --arg digest "${image_digest}" \
    '{containerId: $cid, image: $image, imageDigest: $digest, source: "compose-ps"}')" || {
    echo "Could not record container identity for '${target}'." >&2
    exit 1
  }
else
  container_identity='{"source":"not-applicable","reason":"target is not a compose-managed container in this run"}'
fi
command_line_sha=""
detail_command="$(jqd -r '.commandLine // ""' < "${target_identity_file}")"
if [[ -n "${detail_command}" ]]; then
  command_line_sha="$(printf '%s' "${detail_command}" | { command -v sha256sum >/dev/null 2>&1 && sha256sum || shasum -a 256; } | awk '{print $1}')"
fi
# Merging the enrichment used to be best-effort: a failure here left the base
# identity in place and the run continued, so the container and command hash
# could be absent from a package that reported no problem.
identity_tmp="${target_identity_file}.tmp"
if ! jqd -c --argjson container "${container_identity}" --arg cmdsha "${command_line_sha}" \
   '. + {container: $container, commandLineSha256: $cmdsha}' \
   < "${target_identity_file}" > "${identity_tmp}"; then
  rm -f "${identity_tmp}"
  echo "Could not attach container identity and command hash to the target identity for '${target}'." >&2
  exit 1
fi
mv "${identity_tmp}" "${target_identity_file}"

# D-P2-4. The selected process exists, but that alone does not prove this
# monitor can execute the requested diagnostic operation. Ask its live info
# and OpenAPI reports before opening an EventPipe session, loading the stacks
# profiler, or requesting a dump. A missing endpoint/capability is a refusal,
# never a late capture error after the target was perturbed.
capability_kinds=()
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
  #
  # monitor_curl, not curl: it carries the Authorization header, the CA and the
  # client certificate that every other monitor call already presents. A bare
  # curl here answered 401 (or failed the TLS handshake) on every protected
  # monitor while the primary trace still completed as captured, so the missing
  # counters were only a limitation line nobody read.
  local dest="$1/counters.json-seq" seconds="$2" http="" records=0
  http="$(monitor_curl -sS --max-time $((seconds + 30)) -o "${dest}.tmp" -w '%{http_code}' --get \
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
    if read_fields 3 < <(tr '\t' '\n' < "${counters_status_file}"); then
      counters_state="${TSV_FIELDS[0]}"; counters_records="${TSV_FIELDS[1]}"; counters_reason="${TSV_FIELDS[2]}"
    fi
    rm -f "${counters_status_file}"
  fi
}

if [[ -n "${campaign_preset}" ]]; then
  case "${campaign_preset}" in
    cpu) capability_kinds=(trace) ;;
    memory) capability_kinds=(gcdump) ;;
    cpu-memory) capability_kinds=(gcdump trace) ;;
    hang)
      capability_kinds=(trace)
      dotnet_monitor_stacks_capture_allowed && capability_kinds+=(stacks)
      [[ "${PERFLAB_DIAGNOSTIC_INCLUDE_DUMP:-0}" == "1" ]] && capability_kinds+=(dump)
      ;;
    dump) capability_kinds=(dump) ;;
    *) echo "Unknown runtime campaign preset '${campaign_preset}' for capability preflight." >&2; exit 1 ;;
  esac
else
  capability_kinds=("${kind}")
fi
dotnet_monitor_capability_require "${artifact_dir}" "${runtime_uid}" "${capability_kinds[@]}" || exit 1

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
# INT/TERM end the capture. Cleaning up and carrying on pulled the next snapshot
# from a load that had just been killed and recorded the capture as captured.
# The signal is re-raised so capture-runtime.sh sees a real interruption.
capture_on_signal() {
  trap '' INT TERM
  cleanup_load
  trap - EXIT INT TERM
  kill -s "$1" "$$"
}
trap 'rc=$?; cleanup_load; finalize_failed_capture "${rc}"' EXIT
trap 'capture_on_signal INT' INT
trap 'capture_on_signal TERM' TERM

performance_stream_copy_limit() {
  local dest="$1" budget="$2" limit actual
  case "${budget}" in ''|*[!0-9]*) echo "download budget must be an integer" >&2; return 1 ;; esac
  limit=$((budget + 1))
  head -c "${limit}" > "${dest}.tmp" || true
  actual="$(wc -c < "${dest}.tmp" | tr -d ' ')"
  if (( actual == 0 )); then
    rm -f "${dest}.tmp"
    return 1
  fi
  if (( actual > budget )); then
    rm -f "${dest}.tmp"
    echo "Diagnostic artifact ${dest##*/} exceeded the ${budget}-byte budget during the bounded copy; it was discarded rather than left on disk." >&2
    return 2
  fi
  mv "${dest}.tmp" "${dest}"
}

pull() {  # pull <dest-file> <curl-arg>...
  try_pull "$@" || {
    echo "Diagnostic fetch failed for ${target} (${1##*/})$(monitor_failure "$1" | sed 's/^/: /'); the capture is incomplete." >&2
    exit 1
  }
}

monitor_failure() { # monitor_failure <dest-file> -> the recorded failure, consumed
  [[ -s "$1.failure" ]] || return 0
  cat "$1.failure"; rm -f "$1.failure"
}

diagnostic_download_budget() { # dest-file
  local dest="$1"
  local budget="${PERFLAB_DIAGNOSTIC_ARTIFACT_BUDGET_BYTES:-1073741824}"
  case "${budget}" in ''|*[!0-9]*) echo "PERFLAB_DIAGNOSTIC_ARTIFACT_BUDGET_BYTES must be an integer." >&2; exit 1 ;; esac
  if [[ "${dest##*/}" == "stacks.txt" ]]; then
    local stacks_budget="${PERFLAB_STACKS_MAX_BYTES:-16777216}"
    case "${stacks_budget}" in ''|*[!0-9]*) echo "PERFLAB_STACKS_MAX_BYTES must be an integer." >&2; exit 1 ;; esac
    (( stacks_budget < budget )) && budget="${stacks_budget}"
  elif [[ "${dest##*/}" == *.dmp || "${dest##*/}" == coredump.* ]]; then
    local dump_budget="${PERFLAB_CRASH_DUMP_MAX_BYTES:-536870912}"
    case "${dump_budget}" in ''|*[!0-9]*) echo "PERFLAB_CRASH_DUMP_MAX_BYTES must be an integer." >&2; exit 1 ;; esac
    (( dump_budget < budget )) && budget="${dump_budget}"
  fi
  printf '%s' "${budget}"
}

# try_pull <dest-file> <curl-arg>... -- fetches into dest within its budget. A
# failed request leaves <dest>.failure naming the HTTP status and dotnet-monitor's
# ProblemDetails title/detail: `curl -f` used to discard that body, so a /stacks
# 500 was recorded only as "request failed" and its cause was unrecoverable.
# /stacks is a read-only request that dotnet-monitor intermittently answers with
# an empty HTTP 500 (S03: its profiler channel to the app refused, errno 99,
# seconds after the diagnose-mode recreate), so a server error there is retried
# for up to 25 s; the other kinds start sessions or freeze the process and are
# never repeated. A final server error on a local target keeps the monitor's
# log lines beside the failure.
try_pull() {
  local dest="$1" attempt attempts=1 rc
  [[ "${dest##*/}" == "stacks.txt" ]] && attempts=6
  for (( attempt = 1; attempt <= attempts; attempt++ )); do
    rc=0; try_pull_once "$@" || rc=$?
    (( rc == 0 )) && { (( attempt > 1 )) && echo "dotnet-monitor ${dest##*/}: captured on attempt ${attempt} of ${attempts}." >&2; return 0; }
    grep -q '^HTTP 5' "${dest}.failure" 2>/dev/null || return "${rc}"
    (( attempt < attempts )) && { echo "dotnet-monitor ${dest##*/}: $(cat "${dest}.failure"); retrying (${attempt}/${attempts})." >&2; sleep 5; }
  done
  keep_monitor_log "${dest}"
  return "${rc}"
}

keep_monitor_log() { # dest-file -- the recent log of the local container publishing the monitor port
  local port container
  [[ "${target_mode:-local}" == "local" && "${PERFLAB_TARGET_KIND:-managed-compose}" == "managed-compose" ]] || return 0
  port="$(printf '%s' "${diagnostics_url}" | sed -E 's#^[a-z]+://[^:/]+:?([0-9]*).*#\1#')"
  [[ -n "${port}" ]] || return 0
  container="$(docker ps --filter "publish=${port}" --format '{{.Names}}' 2>/dev/null | head -1)"
  [[ -n "${container}" ]] || return 0
  docker logs --since 2m "${container}" 2>&1 | tail -n 200 > "${dest}.monitor.log" || true
  [[ -s "${dest}.monitor.log" ]] || return 0
  printf '%s (monitor log: %s)\n' "$(tr -d '\n' < "${dest}.failure")" "${dest##*/}.monitor.log" > "${dest}.failure.tmp" && mv "${dest}.failure.tmp" "${dest}.failure"
}

try_pull_once() {
  local dest="$1"; shift
  local budget limit copy_rc curl_rc statuses status detail
  budget="$(diagnostic_download_budget "${dest}")"
  limit=$((budget + 1))
  rm -f "${dest}.tmp" "${dest}.headers" "${dest}.failure"
  set +o pipefail
  monitor_curl -sS -D "${dest}.headers" --max-filesize "${limit}" "$@" | performance_stream_copy_limit "${dest}" "${budget}"
  statuses=("${PIPESTATUS[@]}")
  curl_rc="${statuses[0]:-1}"
  copy_rc="${statuses[1]:-1}"
  set -o pipefail
  status="$(awk 'toupper($1) ~ /^HTTP\// { code = $2 } END { print code }' "${dest}.headers" 2>/dev/null || true)"
  rm -f "${dest}.headers"
  if [[ "${status}" =~ ^[0-9]+$ ]] && (( status >= 400 )); then
    detail=""
    [[ -s "${dest}" ]] && detail="$(jqd -r '[.title, .detail] | map(select(. != null and . != "")) | join(": ")' < "${dest}" 2>/dev/null | tr '\r\n' '  ' | head -c 300 || true)"
    printf 'HTTP %s%s\n' "${status}" "${detail:+: ${detail}}" > "${dest}.failure"
    rm -f "${dest}" "${dest}.tmp"
    return 1
  fi
  if (( copy_rc == 2 )); then
    echo "Diagnostic artifact ${dest##*/} reached more than ${budget} bytes, exceeding the ${budget}-byte budget; it was discarded rather than left in the package." >&2
    return 1
  fi
  if (( copy_rc != 0 )); then
    rm -f "${dest}.tmp" "${dest}"
    return 1
  fi
  if (( curl_rc != 0 && curl_rc != 18 && curl_rc != 23 && curl_rc != 63 )); then
    rm -f "${dest}"
    return 1
  fi
  return 0
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

  write_campaign_capture() { # id sequence requested effective state start end reason artifact [extra-json-fields]
    local stage_id="$1" sequence="$2" requested="$3" effective="$4" state="$5" started="$6" completed="$7" reason="$8" artifact="${9:-}" extra="${10:-}"
    local stage_dir="${captures_root}/${stage_id}" artifacts='[]'
    mkdir -p "${stage_dir}"
    [[ -n "${artifact}" ]] && artifacts="[\"$(json_escape "${artifact}")\"]"
    printf '{"id":"%s","sequence":%s,"requestedDiagnostic":"%s","effectiveDiagnostic":"%s","captureState":"%s","startedAt":"%s","completedAt":"%s","reason":"%s","artifactPaths":%s,"gateEligible":false%s}\n' \
      "$(json_escape "${stage_id}")" "${sequence}" "$(json_escape "${requested}")" "$(json_escape "${effective}")" \
      "$(json_escape "${state}")" "$(json_escape "${started}")" "$(json_escape "${completed}")" "$(json_escape "${reason}")" "${artifacts}" "${extra}" \
      > "${stage_dir}/capture.json"
  }

  # The counters object a trace stage records next to its nettrace. Same shape
  # as the single-kind capture, so a reader parses one format for both paths.
  counters_json_field() {
    printf ',"counters":{"captureState":"%s","reason":"%s","records":%s,"source":"dotnet-monitor /livemetrics","format":"application/json-seq"}' \
      "$(json_escape "${counters_state}")" "$(json_escape "${counters_reason}")" "${counters_records:-0}"
  }

  campaign_snapshot() { # id sequence requested filename endpoint [curl args...]
    local stage_id="$1" sequence="$2" requested="$3" filename="$4" endpoint="$5"; shift 5
    local stage_dir="${captures_root}/${stage_id}" started completed relative
    mkdir -p "${stage_dir}"
    started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    relative="runtime/captures/${stage_id}/${filename}"
    if try_pull "${stage_dir}/${filename}" --get --data-urlencode "uid=${runtime_uid}" "$@" "${diagnostics_url}/${endpoint}"; then
      if [[ "${filename}" == *.dmp ]]; then
        retain_sensitive_file "${stage_dir}/${filename}" process-memory || exit 1
        relative="${relative}.retained.json"
      fi
      completed="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      write_campaign_capture "${stage_id}" "${sequence}" "${requested}" "${requested}" captured "${started}" "${completed}" "" "${relative}"
      campaign_successes=$((campaign_successes + 1))
    else
      completed="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      write_campaign_capture "${stage_id}" "${sequence}" "${requested}" "${requested}" failed "${started}" "${completed}" "dotnet-monitor ${endpoint} request failed$(monitor_failure "${stage_dir}/${filename}" | sed 's/^/ (/; s/$/)/')" ""
      campaign_failures=$((campaign_failures + 1))
      echo "Campaign stage ${stage_id} failed; continuing so independent evidence is retained." >&2
    fi
  }

  campaign_trace() { # sequence [mid-load-hook]
    local sequence="$1" mid_load_hook="${2:-}" stage_dir="${captures_root}/trace" started completed trace_ok=0 load_ok=0 reason="" counters_pid="" trace_pid=""
    mkdir -p "${stage_dir}"
    started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    run_load & load_pid=$!
    # Live runtime counters ride the same window as the trace, exactly as the
    # single-kind path does. A campaign used to skip them entirely, so a preset
    # run had no CPU/GC/thread-pool series unless someone read the raw nettrace.
    counters_state="not-applicable"; counters_reason=""; counters_records=0
    capture_counters "${stage_dir}" "${duration_seconds}" & counters_pid=$!
    if [[ -n "${mid_load_hook}" ]]; then
      # A load-induced hang (a convoy, a starved pool) exists only while the load
      # runs; a snapshot after the load finishes shows a recovered process. Take
      # the hook's snapshots at the middle of the load, inside the trace window.
      try_pull "${stage_dir}/cpu.nettrace" --get --data-urlencode "uid=${runtime_uid}" \
        --data-urlencode "durationSeconds=${duration_seconds}" --data-urlencode "profile=cpu" "${diagnostics_url}/trace" & trace_pid=$!
      sleep "$(( duration_seconds / 2 > 0 ? duration_seconds / 2 : 1 ))"
      "${mid_load_hook}"
      if wait "${trace_pid}"; then trace_ok=1; else reason="dotnet-monitor trace request failed$(monitor_failure "${stage_dir}/cpu.nettrace" | sed 's/^/ (/; s/$/)/')"; fi
    elif try_pull "${stage_dir}/cpu.nettrace" --get --data-urlencode "uid=${runtime_uid}" \
      --data-urlencode "durationSeconds=${duration_seconds}" --data-urlencode "profile=cpu" "${diagnostics_url}/trace"; then
      trace_ok=1
    else
      reason="dotnet-monitor trace request failed$(monitor_failure "${stage_dir}/cpu.nettrace" | sed 's/^/ (/; s/$/)/')"
    fi
    if wait "${load_pid}"; then
      load_ok=1; campaign_load_state="captured"
    else
      campaign_load_state="failed"; campaign_load_reason="diagnostic load generator failed"
      reason="${reason:+${reason}; }${campaign_load_reason}"
    fi
    load_pid=""
    wait "${counters_pid}" 2>/dev/null || true; counters_pid=""
    read_counters_state
    if [[ "${counters_state}" == "failed" || "${counters_state}" == "missing" ]]; then
      reason="${reason:+${reason}; }runtime counters unavailable: ${counters_reason}"
    fi
    completed="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    if (( trace_ok == 1 )); then
      write_campaign_capture trace "${sequence}" trace trace captured "${started}" "${completed}" "${reason}" "runtime/captures/trace/cpu.nettrace" "$(counters_json_field)"
      campaign_successes=$((campaign_successes + 1))
      if (( load_ok == 0 )); then
        campaign_failures=$((campaign_failures + 1))
      fi
    else
      write_campaign_capture trace "${sequence}" trace trace failed "${started}" "${completed}" "${reason}" "$([[ ${trace_ok} == 1 ]] && printf runtime/captures/trace/cpu.nettrace)" "$(counters_json_field)"
      campaign_failures=$((campaign_failures + 1))
    fi
  }

  # The warm-up and diagnostic generator output live below runtime/campaign-load,
  # never in benchmark/, so measurement facts and observations remain immutable.
  # Only a remote dump (a process never recreated) skips the load; the core
  # capture-runtime.sh decides and exports it.
  dump_only="${PERFLAB_CAMPAIGN_DUMP_ONLY:-0}"
  if [[ "${dump_only}" == "0" ]]; then
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
      hang_snapshots() {
        local next_seq=2
        if dotnet_monitor_stacks_capture_allowed; then
          campaign_snapshot stacks "${next_seq}" stacks stacks.txt stacks
          next_seq=$((next_seq + 1))
        fi
        if [[ "${include_dump}" == "1" ]]; then
          campaign_snapshot dump "${next_seq}" dump process.dmp dump --data-urlencode "type=WithHeap"
        fi
      }
      campaign_trace 1 hang_snapshots
      ;;
    dump)
      # The dump follows the load, so it holds what the scenario built up.
      if [[ "${dump_only}" == "0" ]]; then
        if run_load; then campaign_load_state="captured"; else campaign_load_state="failed"; campaign_load_reason="diagnostic load generator failed"; campaign_failures=$((campaign_failures + 1)); fi
      fi
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
    # Counting the overage and keeping the files is not a budget: the disk is
    # already full and the oversized artifacts are already in the package that
    # somebody will attach to a ticket. Remove the largest binary captures until
    # the package is within budget, and record exactly what was dropped so the
    # evidence says what is missing rather than quietly lacking it.
    dropped_json=""; dropped_count=0
    while IFS= read -r oversized_file; do
      (( runtime_bytes > budget_bytes )) || break
      oversized_bytes="$(wc -c < "${oversized_file}" | tr -d ' ')"
      rm -f "${oversized_file}"
      runtime_bytes=$((runtime_bytes - oversized_bytes))
      dropped_count=$((dropped_count + 1))
      dropped_json="${dropped_json}${dropped_json:+,}$(printf '{"artifact":"%s","bytes":%s}' \
        "$(json_escape "${oversized_file#"${artifact_dir}/"}")" "${oversized_bytes}")"
      echo "  removed ${oversized_file#"${artifact_dir}/"} (${oversized_bytes} bytes) to stay within the budget" >&2
    done < <(find "${artifact_dir}/runtime" -type f \( -name '*.nettrace' -o -name '*.gcdump' -o -name '*.dmp' -o -name 'stacks.txt' \) -print0 \
             | xargs -0 ls -S 2>/dev/null)
    printf '{"budgetBytes":%s,"bytesAfterEnforcement":%s,"removed":%s,"artifacts":[%s]}\n' \
      "${budget_bytes}" "${runtime_bytes}" "${dropped_count}" "${dropped_json}" \
      > "${artifact_dir}/runtime/artifact-budget.json"
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
    retain_sensitive_file "${out}/process.dmp" process-memory || exit 1
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
[[ "${kind}" == "stacks" ]] && limitations+=',"Call stacks contain type and method names from the process; they are retained locally, bounded by PERFLAB_STACKS_MAX_BYTES, and are not an exportable artifact."'
[[ -n "${fallback_reason}" ]] && limitations+=",\"$(json_escape "${fallback_reason}")\""
[[ "${counters_state}" == "failed" || "${counters_state}" == "missing" ]] && limitations+=",\"$(json_escape "runtime counters unavailable: ${counters_reason}")\""
limitations+=']'
printf '%s,"counters":{"captureState":"%s","reason":"%s","records":%s,"source":"dotnet-monitor /livemetrics","format":"application/json-seq"},"limitations":%s,"completedAt":"%s","status":"captured"}\n' \
  "${content}" "$(json_escape "${counters_state}")" "$(json_escape "${counters_reason}")" "${counters_records:-0}" "${limitations}" \
  "$(json_escape "$(date -u +%Y-%m-%dT%H:%M:%SZ)")" > "${capture_json}"
echo "Captured ${kind} for ${target} (counters: ${counters_state})."
