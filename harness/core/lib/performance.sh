#!/usr/bin/env bash
# Script-native validation helpers for the native performance harness.

performance_capability_preflight() {
  local generator="$1" workload="$2" protocol="${3:-}"
  case "${generator}" in k6|jmeter|wrk) ;; *) echo "unknown generator ${generator}" >&2; return 1 ;; esac
  case "${workload}" in request|journey|mix|protocol) ;; *) echo "unknown workload ${workload}" >&2; return 1 ;; esac
  if [[ "${generator}" == "wrk" && "${workload}" != "request" ]]; then
    echo "wrk supports request workloads only; rejected before traffic" >&2
    return 1
  fi
  if [[ "${workload}" == "protocol" ]]; then
    [[ "${generator}" == "k6" ]] || {
      echo "protocol workloads require k6; rejected before traffic" >&2
      return 1
    }
    case "${protocol}" in grpc|websocket|messaging|browser-synthetic) ;;
      *) echo "unknown protocol ${protocol}" >&2; return 1 ;;
    esac
  fi
}

# The generic generator capability is only a broad safety floor. A lab may
# intentionally implement a narrower subset (for example, k6-only protocol or
# security journeys). Its workload manifest is therefore authoritative for the
# selected scenario and must reject an undeclared generator before the target
# is leased or any traffic is sent.
performance_manifest_selector_preflight() {
  local file="$1" selector="$2" generator="$3" workload="$4"
  [[ -n "${file}" && -f "${file}" ]] || return 0
  jqd -e --arg selector "${selector}" --arg generator "${generator}" --arg workload "${workload}" '
    [.selectors[] | select(.id == $selector)] as $matches |
    ($matches | length == 1) and
    ($matches[0].type == $workload) and
    ($matches[0].generators | index($generator) != null)
  ' < "${file}" >/dev/null || {
    echo "workload selector '${selector}' does not declare generator '${generator}' for '${workload}'; refusing unsupported traffic before traffic" >&2
    return 1
  }
}

# Distributed execution is deliberately a selector-owned capability. A caller
# cannot turn an arbitrary k6 script or a JMeter plan into a remote workload by
# setting PERFLAB_SHARDS: the selected manifest entry must opt into the one
# closed v1 request protocol first.
performance_distributed_selector_preflight() {
  local file="$1" selector="$2" generator="$3" workload="$4"
  [[ -n "${file}" && -f "${file}" ]] || {
    echo "distributed execution requires a declared workload manifest" >&2
    return 1
  }
  jqd -e --arg selector "${selector}" --arg generator "${generator}" --arg workload "${workload}" '
    [.selectors[] | select(.id == $selector)] as $matches |
    ($matches | length == 1) and
    ($generator == "k6") and ($workload == "request") and
    ($matches[0].distributedMode == "k6-request-v1") and
    ($matches[0].entrypoints.k6 == "harness/core/distributed/k6-distributed.js") and
    ($matches[0].files == ["harness/core/distributed/k6-distributed.js"]) and
    ($matches[0].generators | index("k6") != null)
  ' < "${file}" >/dev/null || {
    echo "workload selector '${selector}' does not declare distributedMode k6-request-v1; refusing distributed traffic before a lease" >&2
    return 1
  }
}

# performance_origin_from_url returns the canonical origin of a full HTTP(S)
# URL. Unlike a manifest entry, a workload base URL may include a path; the
# caller is validating the network destination, not an individual route.
performance_origin_from_url() {
  local raw="$1" scheme remainder authority
  case "${raw}" in
    http://*|https://*) ;;
    *) echo "target URL must be absolute HTTP(S): ${raw}" >&2; return 1 ;;
  esac
  scheme="${raw%%://*}"
  remainder="${raw#*://}"
  authority="${remainder%%/*}"
  authority="${authority%%\?*}"
  authority="${authority%%\#*}"
  [[ -n "${authority}" && "${authority}" != *"@"* && "${authority}" != *[[:space:]]* ]] || {
    echo "target URL has no credential-free authority: ${raw}" >&2
    return 1
  }
  printf '%s://%s' "$(printf '%s' "${scheme}" | tr '[:upper:]' '[:lower:]')" "$(printf '%s' "${authority}" | tr '[:upper:]' '[:lower:]')"
}

# Manifest origin entries are intentionally stricter than workload URLs: only
# an origin (with an optional root slash) is meaningful in an egress allowlist.
performance_canonical_manifest_origin() {
  local raw="$1" remainder authority suffix origin
  origin="$(performance_origin_from_url "${raw}")" || return 1
  remainder="${raw#*://}"
  authority="${remainder%%/*}"
  authority="${authority%%\?*}"
  authority="${authority%%\#*}"
  suffix="${remainder#"${authority}"}"
  [[ "${suffix}" == "" || "${suffix}" == "/" ]] || {
    echo "allowed origin must not include a path, query, or fragment: ${raw}" >&2
    return 1
  }
  printf '%s' "${origin}"
}

# performance_manifest_allowed_origins_preflight <manifest> <selector> <base-url>
#
# The manifest controls the closed routing set, not a caller-provided
# environment value. The resolved base origin must be one member, and the
# compact JSON emitted here is what the project-owned journey consumes. This
# runs before readiness, leases, or generator traffic.
performance_manifest_allowed_origins_preflight() {
  local file="$1" selector="$2" base="$3" has raw candidate canonical base_origin
  local -a origins=()
  local found=0
  [[ -n "${file}" && -f "${file}" ]] || return 0
  has="$(jqd -r --arg selector "${selector}" '
    [.selectors[] | select(.id == $selector)] as $matches |
    if ($matches | length) != 1 then error("selector missing")
    else ($matches[0] | has("allowedOrigins")) end
  ' < "${file}")" || {
    echo "workload selector '${selector}' has no valid allowedOrigins declaration" >&2
    return 1
  }
  [[ "${has}" == "true" ]] || return 0
  base_origin="$(performance_origin_from_url "${base}")" || return 1
  raw="$(jqd -r --arg selector "${selector}" '
    [.selectors[] | select(.id == $selector)] as $matches |
    if ($matches | length) != 1 then error("selector missing")
    else $matches[0].allowedOrigins[] end
  ' < "${file}")" || {
    echo "workload selector '${selector}' has malformed allowedOrigins" >&2
    return 1
  }
  [[ -n "${raw}" ]] || {
    echo "workload selector '${selector}' must declare at least one allowed origin" >&2
    return 1
  }
  while IFS= read -r candidate; do
    canonical="$(performance_canonical_manifest_origin "${candidate}")" || return 1
    for existing in "${origins[@]}"; do
      [[ "${existing}" != "${canonical}" ]] || {
        echo "workload selector '${selector}' repeats allowed origin '${canonical}'" >&2
        return 1
      }
    done
    origins+=("${canonical}")
    [[ "${canonical}" == "${base_origin}" ]] && found=1
  done <<< "${raw}"
  (( ${#origins[@]} > 0 && found == 1 )) || {
    echo "base URL origin '${base_origin}' is not in workload selector '${selector}' allowedOrigins" >&2
    return 1
  }
  jqd -cn '$ARGS.positional' --args "${origins[@]}"
}

performance_profile_preflight() {
  local profile="$1" generator="$2"
  case "${profile}" in smoke|load|steady|ramp|stress|breakpoint|capacity|knee|spike|open|closed|soak|arrival) ;;
    *) echo "unknown profile ${profile}" >&2; return 1 ;;
  esac
  case "${generator}" in
    wrk) case "${profile}" in smoke|load|steady) ;; *) echo "${profile} requires k6" >&2; return 1 ;; esac ;;
    jmeter) case "${profile}" in smoke|load|steady|closed|open|arrival|capacity|knee) ;;
      *) echo "${profile} is not implemented by the JMeter adapter" >&2; return 1 ;; esac ;;
  esac
}

# D-P1-7. A remote target is window-scoped unless it implements this exact
# target-owned contract. The target must receive the generated run ID on every
# measured request, expose it as bounded Prometheus/Loki labels and as a span
# attribute, and echo it from a same-origin probe before traffic begins.
#
# Resource attributes describe a long-lived process and cannot carry an
# arbitrary remote run ID. The Tempo selector therefore deliberately uses the
# per-request span attribute `span.perf.run.id`.
performance_remote_correlation_validate() {
  local value name
  [[ "${target_mode:-}" == "remote" ]] || {
    echo "remote correlation requires PERFLAB_TARGET=remote" >&2
    return 1
  }
  [[ "${remote_telemetry:-0}" == "1" ]] || {
    echo "remote correlation requires PERFLAB_REMOTE_TELEMETRY=1" >&2
    return 1
  }
  [[ "${remote_correlation:-0}" == "1" ]] || return 0
  [[ "${remote_correlation_version:-}" == "perflab-run-id-v1" ]] || {
    echo "remote correlation requires version perflab-run-id-v1" >&2
    return 1
  }
  [[ "${remote_correlation_header:-}" == "X-Perf-Run-Id" ]] || {
    echo "remote correlation requires header X-Perf-Run-Id" >&2
    return 1
  }
  case "${remote_correlation_probe_path:-}" in
    /*)
      [[ "${remote_correlation_probe_path}" != //* && "${remote_correlation_probe_path}" != *'?'* &&
         "${remote_correlation_probe_path}" != *'#'* && "${remote_correlation_probe_path}" != *'..'* ]] || {
        echo "remote correlation probe path must be an absolute same-origin path" >&2
        return 1
      }
      ;;
    *) echo "remote correlation probe path must be an absolute same-origin path" >&2; return 1 ;;
  esac
  for name in remote_correlation_response_run_id_field remote_correlation_response_version_field \
              remote_correlation_prometheus_label remote_correlation_loki_label remote_correlation_tempo_attribute; do
    value="${!name:-}"
    [[ "${value}" =~ ^[A-Za-z0-9._-]{1,128}$ ]] || {
      echo "remote correlation ${name#remote_correlation_} must be a bounded identifier" >&2
      return 1
    }
  done
  [[ "${remote_correlation_prometheus_label}" == "perf_run_id" &&
     "${remote_correlation_loki_label}" == "perf_run_id" &&
     "${remote_correlation_tempo_attribute}" == "span.perf.run.id" ]] || {
    echo "remote correlation v1 requires perf_run_id labels and span.perf.run.id" >&2
    return 1
  }
}

performance_remote_correlation_probe_url() {
  local base="$1" scheme remainder authority
  case "${base}" in
    http://*|https://*) ;;
    *) echo "remote correlation requires an absolute HTTP(S) target URL" >&2; return 1 ;;
  esac
  scheme="${base%%://*}"
  remainder="${base#*://}"
  authority="${remainder%%/*}"
  [[ -n "${authority}" && "${authority}" != *'@'* && "${authority}" != *'?'* && "${authority}" != *'#'* ]] || {
    echo "remote correlation target URL has no valid origin" >&2
    return 1
  }
  printf '%s://%s%s' "${scheme}" "${authority}" "${remote_correlation_probe_path}"
}

# performance_remote_correlation_probe <base-url> <run-id> <proof-file>
# The response is bounded and discarded after validating the two fields. The
# evidence retains the proof contract and timestamp, never an arbitrary target
# response that could contain secrets or unrelated payload data.
performance_remote_correlation_probe() {
  local base="$1" run_id="$2" proof_file="$3" url response bytes
  [[ "${run_id}" =~ ^[A-Za-z0-9._-]{1,128}$ ]] || {
    echo "remote correlation run ID must be a bounded identifier" >&2
    return 1
  }
  performance_remote_correlation_validate || return 1
  url="$(performance_remote_correlation_probe_url "${base}")" || return 1
  response="$(mktemp "${TMPDIR:-/tmp}/perflab-remote-correlation.XXXXXX")" || return 1
  if ! target_curl -fsS --max-time 10 --max-filesize 65536 \
      -H "${remote_correlation_header}: ${run_id}" "${url}" | head -c 65537 > "${response}"; then
    bytes="$(wc -c < "${response}" | tr -d ' ')"
    rm -f "${response}"
    if [[ "${bytes}" =~ ^[0-9]+$ ]] && (( bytes > 65536 )); then
      echo "remote correlation probe response exceeded 65536 bytes" >&2
    else
      echo "remote correlation probe failed for ${url}" >&2
    fi
    return 1
  fi
  bytes="$(wc -c < "${response}" | tr -d ' ')"
  if [[ ! "${bytes}" =~ ^[0-9]+$ ]] || (( bytes > 65536 )); then
    rm -f "${response}"
    echo "remote correlation probe response exceeded 65536 bytes" >&2
    return 1
  fi
  if ! jqd -e --arg run "${run_id}" --arg version "${remote_correlation_version}" \
      --arg run_field "${remote_correlation_response_run_id_field}" \
      --arg version_field "${remote_correlation_response_version_field}" '
        type == "object" and .[$run_field] == $run and .[$version_field] == $version
      ' < "${response}" >/dev/null 2>&1; then
    rm -f "${response}"
    echo "remote correlation probe did not echo the exact run ID and contract version" >&2
    return 1
  fi
  rm -f "${response}"
  mkdir -p "$(dirname "${proof_file}")"
  printf '{"schemaVersion":"remote-correlation-v1","verified":true,"version":"%s","runId":"%s","header":"%s","probePath":"%s","prometheusLabel":"%s","lokiLabel":"%s","tempoAttribute":"%s","verifiedAt":"%s"}\n' \
    "${remote_correlation_version}" "${run_id}" "${remote_correlation_header}" \
    "${remote_correlation_probe_path}" "${remote_correlation_prometheus_label}" \
    "${remote_correlation_loki_label}" "${remote_correlation_tempo_attribute}" \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "${proof_file}"
}

# A measurement-window attestation is target-owned evidence for the concrete
# process generation that served a run at the load boundary. It is deliberately
# separate from remote-correlation: correlation proves the run tag; this probe
# proves the service instance and rejects a stale response before traffic.
performance_measurement_window_probe() {
  local base="$1" run_id="$2" window_id="$3" boundary="$4" output="$5"
  local probe_path="${PERFLAB_MEASUREMENT_WINDOW_PROBE_PATH:-}" origin url response bytes
  [[ -n "${probe_path}" ]] || return 0
  [[ "${run_id}" =~ ^[A-Za-z0-9._-]{1,128}$ && "${window_id}" =~ ^[A-Za-z0-9._-]{1,128}$ ]] || {
    echo "measurement-window run and window IDs must be bounded tokens" >&2
    return 1
  }
  case "${boundary}" in start|end) ;; *) echo "measurement-window boundary must be start or end" >&2; return 1 ;; esac
  case "${probe_path}" in
    /*)
      [[ "${probe_path}" != //* && "${probe_path}" != *'?'* && "${probe_path}" != *'#'* && "${probe_path}" != *'..'* ]] || {
        echo "measurement-window probe path must be an absolute same-origin path" >&2
        return 1
      }
      ;;
    *) echo "measurement-window probe path must be an absolute same-origin path" >&2; return 1 ;;
  esac
  origin="$(performance_origin_from_url "${base}")" || return 1
  url="${origin}${probe_path}"
  response="${output}.response"
  mkdir -p "$(dirname "${output}")"
  rm -f "${response}" "${response}.tmp"
  if ! target_curl -fsS --max-time 10 --max-filesize 65536 \
      -H "X-Perf-Run-Id: ${run_id}" -H "X-Perf-Measurement-Window: ${window_id}" "${url}" \
      | performance_stream_copy_limit "${response}" 65536; then
    rm -f "${response}" "${response}.tmp"
    echo "measurement-window ${boundary} probe failed for ${url}" >&2
    return 1
  fi
  bytes="$(wc -c < "${response}" | tr -d ' ')"
  if [[ ! "${bytes}" =~ ^[0-9]+$ ]] || (( bytes > 65536 )); then
    rm -f "${response}"
    echo "measurement-window probe response exceeded 65536 bytes" >&2
    return 1
  fi
  if ! jqd -e --arg run "${run_id}" --arg window "${window_id}" '
      type == "object" and .runId == $run and .measurementWindowId == $window and
      (.instanceId | type == "string" and test("^[A-Za-z0-9._-]{1,128}$")) and
      (.processStartedAtUnixMilliseconds | type == "number" and . > 0)
    ' < "${response}" >/dev/null 2>&1; then
    rm -f "${response}"
    echo "measurement-window ${boundary} probe did not echo the exact run/window identity and instance" >&2
    return 1
  fi
  local instance process_started
  instance="$(jqd -r '.instanceId' < "${response}")"
  process_started="$(jqd -r '.processStartedAtUnixMilliseconds' < "${response}")"
  if ! jqd -cn --arg run "${run_id}" --arg window "${window_id}" --arg boundary "${boundary}" \
      --arg url "${url}" --arg instance "${instance}" --arg observed "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --argjson processStarted "${process_started}" '
        {schemaVersion:"measurement-window-v1",runId:$run,measurementWindowId:$window,
        boundary:$boundary,probeUrl:$url,instanceId:$instance,
        processStartedAtUnixMilliseconds:$processStarted,observedAt:$observed}
      ' > "${output}.tmp"; then
    rm -f "${response}" "${output}.tmp"
    return 1
  fi
  mv "${output}.tmp" "${output}"
  rm -f "${response}"
}

performance_measurement_window_finalize() {
  local start="$1" end="$2" output="$3" run window start_instance end_instance start_observed end_observed start_process end_process
  [[ -s "${start}" && -s "${end}" ]] || {
    echo "measurement-window requires both start and end attestations" >&2
    return 1
  }
  run="$(jqd -r '.runId // empty' < "${start}")"
  window="$(jqd -r '.measurementWindowId // empty' < "${start}")"
  start_instance="$(jqd -r '.instanceId // empty' < "${start}")"
  end_instance="$(jqd -r '.instanceId // empty' < "${end}")"
  start_observed="$(jqd -r '.observedAt // empty' < "${start}")"
  end_observed="$(jqd -r '.observedAt // empty' < "${end}")"
  start_process="$(jqd -r '.processStartedAtUnixMilliseconds // empty' < "${start}")"
  end_process="$(jqd -r '.processStartedAtUnixMilliseconds // empty' < "${end}")"
  [[ -n "${run}" && -n "${window}" && -n "${start_instance}" && -n "${end_instance}" ]] || return 1
  if ! jqd -e --arg run "${run}" --arg window "${window}" '
      .runId == $run and .measurementWindowId == $window and .boundary == "end"
    ' < "${end}" >/dev/null; then
    echo "measurement-window end attestation does not match the start run/window" >&2
    return 1
  fi
  mkdir -p "$(dirname "${output}")"
  jqd -cn --arg run "${run}" --arg window "${window}" --arg start "${start_instance}" --arg end "${end_instance}" \
    --arg startObserved "${start_observed}" --arg endObserved "${end_observed}" \
    --argjson startProcess "${start_process}" --argjson endProcess "${end_process}" '
      {schemaVersion:"measurement-window-v1",runId:$run,measurementWindowId:$window,
       instanceIds:([$start,$end] | unique),restartDetected:($start != $end),
       scope:"exact-boundary-instance-set",
       start:{instanceId:$start,processStartedAtUnixMilliseconds:$startProcess,observedAt:$startObserved},
       end:{instanceId:$end,processStartedAtUnixMilliseconds:$endProcess,observedAt:$endObserved}}
    ' > "${output}.tmp" && mv "${output}.tmp" "${output}"
}

performance_session_preflight() {
  case "$1" in
    k6|jmeter) return 0 ;;
    *) echo "soak requires a continuous k6 or JMeter session" >&2; return 1 ;;
  esac
}

performance_soak_cert_preflight() {
  local duration="$1"
  [[ "${PERFLAB_SOAK_CERT:-0}" == "1" ]] || return 0
  case "${duration}" in ''|*[!0-9]*) echo "soak certification duration must be a positive integer" >&2; return 1 ;; esac
  (( duration >= 14400 )) || {
    echo "soak certification requires duration >= 14400s (four hours); got ${duration}s" >&2
    return 1
  }
}

performance_soak_bind_pid() {
  local start_file="$1" pid="$2" generator="${3:-unknown}" started_at="${4:-$(date -u +%s)}" identity
  [[ "${pid}" =~ ^[1-9][0-9]*$ ]] || { echo "soak generator pid is required" >&2; return 1; }
  [[ "${started_at}" =~ ^[1-9][0-9]*$ ]] || { echo "soak start epoch is required" >&2; return 1; }
  # A PID is a liveness handle, not a durable process identity: operating
  # systems can eventually reuse it. Bind an opaque session ID at launch and
  # carry it through every heartbeat/snapshot so a resumed process cannot be
  # represented as the original certified soak.
  identity="$(LC_ALL=C od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d '[:space:]')"
  [[ "${identity}" =~ ^[a-f0-9]{32}$ ]] || { echo "unable to create a soak generator identity" >&2; return 1; }
  printf '{"event":"start","generator":"%s","profile":"soak","generatorPid":%s,"generatorIdentity":"%s","startedAtEpoch":%s}\n' \
    "${generator}" "${pid}" "${identity}" "${started_at}" > "${start_file}"
  # Keep a small host-native binding sidecar. It lets the five-second
  # heartbeat path validate a session without starting a Dockerized jq process
  # on every interval, while start.json remains the portable evidence record.
  printf '%s\t%s\t%s\n' "${pid}" "${identity}" "${started_at}" > "${start_file}.identity"
}

performance_soak_assert_pid() {
  local start_file="$1" pid="$2" bound_pid identity started_at
  [[ -f "${start_file}" && -f "${start_file}.identity" ]] || { echo "soak generator identity was not bound" >&2; return 1; }
  read_fields 3 < <(tr '\t' '\n' < "${start_file}.identity") || {
    echo "soak generator identity record is malformed" >&2
    return 1
  }
  bound_pid="${TSV_FIELDS[0]}"
  identity="${TSV_FIELDS[1]}"
  started_at="${TSV_FIELDS[2]}"
  [[ "${bound_pid}" == "${pid}" && "${identity}" =~ ^[a-f0-9]{32}$ && "${started_at}" =~ ^[1-9][0-9]*$ ]] \
    || { echo "resume never presents a restarted generator as one soak (pid ${pid})" >&2; return 1; }
}

performance_soak_identity() {
  local start_file="$1"
  [[ -f "${start_file}.identity" ]] || return 1
  awk -F '\t' 'NF == 3 { print $2; exit }' "${start_file}.identity"
}

performance_target_preflight() {
  local kind="$1" ownership="$2" action="$3"
  case "${kind}" in
    managed-compose|local-container|agent)
      [[ "${ownership}" == "managed" || "${ownership}" == "delegated" ]] || {
        echo "${kind} refuses ${action} without lifecycle ownership" >&2
        return 1
      }
      ;;
    existing-process|existing-container)
      # C-5 attach-only. Measuring a target is not the same act as owning it:
      # observing a running process changes nothing, while deploying, resetting
      # or stopping one this run did not create destroys somebody else's state.
      # Collapsing the two made `existing-process` refuse everything, so the
      # kind could be declared and never used.
      case "${action}" in
        measure|attach|diagnose) return 0 ;;
        *)
          echo "attach-only target ${kind} refuses ${action}: this run did not create it" >&2
          return 1
          ;;
      esac
      ;;
    local-process|existing-environment|existing-kubernetes)
      echo "unmanaged target ${kind} refuses ${action}" >&2
      return 1
      ;;
    *) echo "unknown target kind ${kind}" >&2; return 1 ;;
  esac
}

# Per-request labels. A selector that groups by one of these creates a new
# series for every request, which degrades the backend for every OTHER query
# too -- the cost is not paid by the offending panel alone. The run id is
# deliberately NOT here: it is bounded at one value per run and is how evidence
# is scoped.
PERFLAB_UNBOUNDED_LABELS="${PERFLAB_UNBOUNDED_LABELS:-trace_id span_id request_id correlation_id session_id user_id order_id http_target http_url url_full client_address}"

# performance_reject_unbounded_labels <role> <selector>
# Refuses a metric or profile selector whose cardinality is unbounded. Called
# before the query is issued: a selector that would blow up the backend must be
# rejected rather than executed and then regretted.
performance_reject_unbounded_labels() {
  local role="$1" selector="$2" label
  for label in ${PERFLAB_UNBOUNDED_LABELS}; do
    # Matches `by (label)`, `by(label,...)`, `without (label)` and a selector
    # predicate `label=` / `label=~`. A label appearing only inside a metric
    # NAME is not a grouping and is left alone.
    if printf '%s' "${selector}" | grep -qE "(by|without)[[:space:]]*\\([^)]*\\b${label}\\b|\\b${label}[[:space:]]*(=~?|!=)"; then
      echo "Metric role '${role}' selects or groups by '${label}', which has one value per request." >&2
      echo "  Unbounded label cardinality degrades the backend for every query, not just this one." >&2
      echo "  Scope by run id (bounded at one value per run) instead." >&2
      return 1
    fi
  done
  return 0
}

performance_compare_preflight() {
  case "$1" in request|journey|mix|protocol) return 0 ;;
    *) echo "workload type '$1' is not comparable under stable v1" >&2; return 1 ;;
  esac
}

performance_validate_catalog() {
  local file="$1"
  jqd -e '
    .apiVersion == "perflab.io/v1" and .kind == "ScenarioCatalog" and
    .contractRevision == "v1" and (.scenarios | type == "array" and length > 0) and
    ([.scenarios[].id] | length == (unique | length)) and
    all(.scenarios[];
      (.id | type == "string" and length > 0) and
      (.workload.type == "request" or .workload.type == "journey" or
       .workload.type == "mix" or .workload.type == "protocol") and
      (.workload.selector | type == "string" and length > 0) and
      (.targets | type == "array" and length > 0) and
      (.defaults.rate | type == "number" and . > 0) and
      ((.diagnostics.profilingPolicy // "") == "" or
       (.diagnostics.profilingPolicy == "cpu" or
        .diagnostics.profilingPolicy == "cpu-wall" or
        .diagnostics.profilingPolicy == "memory" or
        .diagnostics.profilingPolicy == "contention" or
        .diagnostics.profilingPolicy == "exceptions" or
        .diagnostics.profilingPolicy == "soak-memory" or
        .diagnostics.profilingPolicy == "all-diagnostic")))
  ' < "${file}" >/dev/null
}

performance_validate_workload_manifest() {
  local file="$1"
  jqd -e '
    .apiVersion == "perflab.io/v1" and .kind == "WorkloadManifest" and
    .contractRevision == "v1" and (.selectors | type == "array" and length > 0) and
    ([.selectors[].id] | length == (unique | length)) and
    all(.selectors[];
      (.id | type == "string" and length > 0) and
      (.type == "request" or .type == "journey" or .type == "mix" or .type == "protocol") and
      (.generators | type == "array" and length > 0) and
      (
        (has("allowedOrigins") | not) or
        (
          .type == "journey" and
          (.allowedOrigins | type == "array" and length > 0) and
          all(.allowedOrigins[]; type == "string" and test("^https?://[^[:space:]/?#@]+/?$")) and
          ([.allowedOrigins[] | ascii_downcase | sub("/$"; "")] | length == (unique | length))
        )
      ) and
      (
        (has("distributedMode") | not) or
        (
          .distributedMode == "k6-request-v1" and .type == "request" and
          (.generators | index("k6") != null) and
          .entrypoints.k6 == "harness/core/distributed/k6-distributed.js" and
          .files == ["harness/core/distributed/k6-distributed.js"]
        )
      )
    )
  ' < "${file}" >/dev/null
}

performance_profiling_preflight() {
  local profile_type threshold quota item role value
  threshold="${PERFLAB_PROFILING_MIN_CORES_THRESHOLD:-}"
  [[ -n "${threshold}" ]] || { echo "profiling threshold is required" >&2; return 1; }
  if ! awk -v value="${threshold}" 'BEGIN { exit !(value >= 0.1 && value <= 1) }'; then
    echo "profiling threshold must be within 0.1 and 1 core" >&2
    return 1
  fi
  IFS=',' read -r -a profile_types <<< "${PERFLAB_PROFILING_TYPES:-cpu}"
  for profile_type in "${profile_types[@]}"; do
    case "${profile_type}" in cpu|wall|allocation|lock|exception|live-heap) ;;
      *) echo "unsupported profiling type ${profile_type}" >&2; return 1 ;;
    esac
  done
  for item in ${PERFLAB_PROFILING_SERVICE_QUOTAS:-}; do
    role="${item%%=*}"; value="${item#*=}"
    [[ -n "${role}" && "${value}" != "${item}" ]] || {
      echo "invalid profiling quota ${item}" >&2; return 1;
    }
    if ! awk -v threshold="${threshold}" -v value="${value}" 'BEGIN { exit !(value > 0 && threshold <= value) }'; then
      echo "profiling threshold ${threshold} exceeds ${role} quota ${value}" >&2
      return 1
    fi
  done
  jqd -cn \
    --arg state captured \
    --arg provider pyroscope-dotnet \
    --arg version 1.5.1 \
    --arg types "${PERFLAB_PROFILING_TYPES:-cpu}" \
    --arg threshold "${threshold}" \
    --arg source "${PERFLAB_PROFILING_QUOTA_SOURCE:-declared}" \
    '{captureState:$state,provider:$provider,providerVersion:$version,types:($types|split(",")),thresholdCores:($threshold|tonumber),quotaSource:$source}'
}

performance_compose_service_state() {
  local service="$1"
  compose ps --all --format '{{.State}}' "${service}" 2>/dev/null | head -n1 | tr -d '[:space:]'
}

performance_compose_service_id() {
  local service="$1"
  compose ps --all --format '{{.ID}}' "${service}" 2>/dev/null | head -n1 | tr -d '[:space:]'
}

performance_fault_state_applied() {
  local kind="$1" state="$2"
  case "${kind}" in
    pause)
      [[ "${state}" == "paused" ]] || { echo "fault apply was not observed: expected paused, got ${state:-empty}" >&2; return 1; }
      ;;
    stop|kill)
      [[ "${state}" == "exited" || "${state}" == "dead" ]] || { echo "fault apply was not observed: expected exited, got ${state:-empty}" >&2; return 1; }
      ;;
    *) echo "unknown fault kind ${kind}" >&2; return 1 ;;
  esac
}

performance_fault_state_restored() {
  local state="$1"
  [[ "${state}" == "running" ]] || { echo "fault restore was not observed: expected running, got ${state:-empty}" >&2; return 1; }
}

performance_crash_dump_enforce() {
  local dir="$1"
  local max="${PERFLAB_CRASH_DUMP_MAX_BYTES:-536870912}"
  local kept=0 size
  case "${max}" in ''|*[!0-9]*) echo "PERFLAB_CRASH_DUMP_MAX_BYTES must be an integer" >&2; return 1 ;; esac
  [[ -d "${dir}" ]] || return 0
  while IFS= read -r dump; do
    [[ -f "${dump}" ]] || continue
    size="$(wc -c < "${dump}" | tr -d ' ')"
    if (( size > max )); then
      echo "discarded oversize crash dump ${dump} (${size} bytes > ${max})" >&2
      rm -f "${dump}"
      continue
    fi
    kept=$((kept + 1))
    if (( kept > 1 )); then
      echo "discarded extra crash dump ${dump} (one dump per window)" >&2
      rm -f "${dump}"
    fi
  done < <(find "${dir}" -type f ! -name '.*' | LC_ALL=C sort)
}

# Bound a copy at budget+1 bytes so a chunked response cannot fill the disk
# before the size check. Return 2 when the overflow byte is seen.
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

# Run a shell snippet inside a Compose service. compose exec requires a running
# container; a stopped app (createdump after a crash) is reached with compose
# run against the same volume mounts.
performance_compose_sh() {
  local service="$1" script="$2"
  if compose exec -T "${service}" sh -c "${script}"; then
    return 0
  fi
  compose run --rm --no-deps -T --entrypoint sh "${service}" -c "${script}"
}

performance_crash_dump_source_directory() {
  # These are harness-owned mount points, not an operator-supplied shell path.
  # Keep the list closed so source-purge/copy callers cannot turn the helper
  # into an arbitrary `find`/`cat` primitive inside a Compose container.
  case "$1" in
    /diag/crash-dumps|/diag/collection-rule-dumps) printf '%s' "$1" ;;
    *) echo "unsupported crash-dump source directory '$1'" >&2; return 1 ;;
  esac
}

performance_crash_dump_enforce_source_at() {
  local service="$1" source_dir="$2"
  local max="${PERFLAB_CRASH_DUMP_MAX_BYTES:-536870912}"
  case "${max}" in ''|*[!0-9]*) echo "PERFLAB_CRASH_DUMP_MAX_BYTES must be an integer" >&2; return 1 ;; esac
  source_dir="$(performance_crash_dump_source_directory "${source_dir}")" || return 1
  performance_compose_sh "${service}" "
if [ ! -d ${source_dir} ]; then exit 0; fi
max=${max}
kept=0
for dump in \$(find ${source_dir} -type f ! -name '.*' | LC_ALL=C sort); do
  [ -f \"\$dump\" ] || continue
  size=\$(wc -c < \"\$dump\" | tr -d ' ')
  if [ \"\$size\" -gt \"\$max\" ]; then
    echo \"discarded oversize crash dump \$dump (\$size bytes > \$max)\" >&2
    rm -f \"\$dump\"
    continue
  fi
  kept=\$((kept + 1))
  if [ \"\$kept\" -gt 1 ]; then
    echo \"discarded extra crash dump \$dump (one dump per window)\" >&2
    rm -f \"\$dump\"
  fi
done
"
}

performance_crash_dump_enforce_source() {
  performance_crash_dump_enforce_source_at "$1" /diag/crash-dumps
}

performance_crash_dump_purge_source_at() {
  local service="$1" source_dir="$2"
  source_dir="$(performance_crash_dump_source_directory "${source_dir}")" || return 1
  performance_compose_sh "${service}" "if [ -d ${source_dir} ]; then find ${source_dir} -type f ! -name '.*' -exec rm -f {} +; fi"
}

performance_crash_dump_purge_source() {
  performance_crash_dump_purge_source_at "$1" /diag/crash-dumps
}

performance_crash_dump_collect_path_from() {
  local service="$1" source_dir="$2" dest="$3"
  local max="${PERFLAB_CRASH_DUMP_MAX_BYTES:-536870912}"
  local listing remote base
  case "${max}" in ''|*[!0-9]*) echo "PERFLAB_CRASH_DUMP_MAX_BYTES must be an integer" >&2; return 1 ;; esac
  source_dir="$(performance_crash_dump_source_directory "${source_dir}")" || return 1
  mkdir -p "${dest}"
  performance_crash_dump_enforce_source_at "${service}" "${source_dir}" || return 1
  listing="$(performance_compose_sh "${service}" "if [ ! -d ${source_dir} ]; then exit 0; fi; find ${source_dir} -type f ! -name '.*' | LC_ALL=C sort")" || return 1
  while IFS= read -r remote; do
    [[ -n "${remote}" ]] || continue
    base="${remote##*/}"
    if ! performance_compose_sh "${service}" "cat $(printf '%q' "${remote}")" | performance_stream_copy_limit "${dest}/${base}" "${max}"; then
      echo "Failed to copy createdump ${remote} from ${service} within the ${max}-byte budget." >&2
      return 1
    fi
  done <<< "${listing}"
  performance_crash_dump_purge_source_at "${service}" "${source_dir}" || {
    echo "Failed to delete crash-dump files from ${service}:${source_dir} after copy." >&2
    return 1
  }
}

performance_crash_dump_collect_from() {
  performance_crash_dump_collect_path_from "$1" /diag/crash-dumps "$2"
}
