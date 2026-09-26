#!/usr/bin/env bash
# Native JMeter adapter entrypoint. This script deliberately uses only the
# shell, jq, awk, and the JMeter runtime shipped in the adapter image.
set -euo pipefail

exit_usage=2
exit_exec=3
exit_publish=4
manifest="${ADAPTER_MANIFEST:-/opt/dotnet-perf-eng/adapter-manifest.json}"

fail() {
  printf '%s\n' "$1" >&2
  exit "${2:-${exit_usage}}"
}

require_manifest() {
  [[ -f "${manifest}" ]] || fail "adapter manifest is missing: ${manifest}" "${exit_publish}"
  jq -e '
    (.adapterId | type == "string" and length > 0) and
    (.adapterVersion | type == "string" and length > 0) and
    ((.generator // "jmeter") == "jmeter") and
    (.cpus | type == "number" and . > 0) and
    (.memoryBytes | type == "number" and . > 0) and
    (.maxThreads | type == "number" and . > 0)
  ' "${manifest}" >/dev/null || fail "adapter manifest is invalid" "${exit_publish}"
}

sha256_file() {
  sha256sum "$1" | awk '{print $1}'
}

confined_relative() {
  local value="$1"
  [[ -n "${value}" ]] || return 1
  [[ "${value}" != /* && "${value}" != *\\* ]] || return 1
  case "/${value}/" in
    */../*|*/./*) return 1 ;;
  esac
  [[ "${value}" != "." && "${value}" != ".." && "${value}" != */ ]] || return 1
  return 0
}

hash_inventory() {
  local root="$1"
  shift
  local rel
  local -a ordered=()
  while IFS= read -r rel; do
    [[ -n "${rel}" ]] && ordered+=("${rel}")
  done < <(printf '%s\n' "$@" | LC_ALL=C sort -u)
  ( for rel in "${ordered[@]}"; do
      confined_relative "${rel}" || fail "path '${rel}' escapes the workload root"
      [[ -f "${root}/${rel}" ]] || fail "workload file ${rel} is missing"
      printf '%s\n' "${rel}"
      cat "${root}/${rel}"
      printf '\0'
    done
  ) | sha256sum | awk '{print $1}'
}

format_epoch_ms() {
  local millis="$1" seconds remainder prefix
  seconds=$((millis / 1000))
  remainder=$((millis % 1000))
  prefix="$(date -u -d "@${seconds}" '+%Y-%m-%dT%H:%M:%S')"
  printf '%s.%03dZ' "${prefix}" "${remainder}"
}

percentile() {
  local sorted="$1" percentile_value="$2"
  awk -v p="${percentile_value}" '
    { values[++n] = $1 }
    END {
      if (n == 0) { print 0; exit }
      if (n == 1) { printf "%.6f", values[1]; exit }
      rank = (p / 100.0) * (n - 1)
      low = int(rank)
      high = (rank == low) ? low : low + 1
      weight = rank - low
      value = values[low + 1] * (1 - weight) + values[high + 1] * weight
      printf "%.6f", value
    }
  ' "${sorted}"
}

parse_jtl() {
  local jtl="$1" scratch="$2"
  local elapsed_file="${scratch}/request-elapsed.txt"
  local stats_file="${scratch}/jtl-stats.txt"
  : > "${elapsed_file}"
  awk -v elapsed_file="${elapsed_file}" '
    function csvsplit(text, values,    i, ch, next_ch, count, field, quoted) {
      delete values
      count = 1
      field = ""
      quoted = 0
      for (i = 1; i <= length(text); i++) {
        ch = substr(text, i, 1)
        if (quoted) {
          if (ch == "\"") {
            next_ch = substr(text, i + 1, 1)
            if (next_ch == "\"") {
              field = field "\""
              i++
            } else {
              quoted = 0
            }
          } else {
            field = field ch
          }
        } else if (ch == "\"") {
          quoted = 1
        } else if (ch == ",") {
          values[count++] = field
          field = ""
        } else {
          field = field ch
        }
      }
      if (quoted) return -1
      values[count] = field
      return count
    }
    function lower(value) {
      return tolower(value)
    }
    function classify(label) {
      if (index(label, "journey::") == 1) return "parent"
      if (index(label, "op::") == 1) return "child"
      if (index(label, "control::") == 1) return "control"
      return "request"
    }
    NR == 1 {
      count = csvsplit($0, row)
      if (count < 1) { print "invalid JTL header" > "/dev/stderr"; exit 2 }
      for (i = 1; i <= count; i++) index_by_name[lower(row[i])] = i
      required[1] = "timestamp"
      required[2] = "elapsed"
      required[3] = "label"
      required[4] = "responsecode"
      required[5] = "responsemessage"
      required[6] = "success"
      required[7] = "latency"
      for (i = 1; i <= 7; i++) {
        if (!(required[i] in index_by_name)) {
          print "invalid JTL header: missing " required[i] > "/dev/stderr"
          exit 2
        }
      }
      next
    }
    {
      count = csvsplit($0, row)
      if (count < 1) { print "invalid quoted JTL row " NR > "/dev/stderr"; exit 2 }
      timestamp = row[index_by_name["timestamp"]]
      elapsed = row[index_by_name["elapsed"]]
      label = row[index_by_name["label"]]
      response = row[index_by_name["responsecode"]]
      message = row[index_by_name["responsemessage"]]
      success = lower(row[index_by_name["success"]])
      latency = row[index_by_name["latency"]]
      if (timestamp !~ /^[0-9]+$/ || timestamp <= 0 || elapsed !~ /^[0-9]+$/ || latency !~ /^[0-9]+$/) {
        print "invalid numeric value in JTL row " NR > "/dev/stderr"
        exit 2
      }
      if (success != "true" && success != "false") {
        print "invalid success value in JTL row " NR > "/dev/stderr"
        exit 2
      }
      kind = classify(label)
      if (kind == "control") next
      samples++
      finished = (timestamp + 0) + (elapsed + 0)
      if (started == 0 || (timestamp + 0) < (started + 0)) started = timestamp + 0
      if (finished > (ended + 0)) ended = finished
      if (kind == "parent") {
        iterations++
        complete = index(message, "Number of samples in transaction : ") == 1 && index(message, "number of failing samples : ") > 0
        if (!complete) journey_aborted++
        else if (success == "true") journey_succeeded++
        else journey_failed++
        next
      }
      requests++
      elapsed_sum += elapsed
      print elapsed >> elapsed_file
      if (kind == "child") {
        if (label == "op::poll") polls++
        if (label == "op::pay") pays++
      }
      numeric = response ~ /^[0-9]+$/ && response >= 100 && response <= 599
      if (!numeric) transport_errors++
      else {
        if (response < 200 || response >= 300) non2xx++
        if (response < 200 || response >= 400) status_errors++
      }
      if (success == "true" && numeric && response >= 200 && response < 400) succeeded++
      else failed++
    }
    END {
      if (samples == 0) {
        print "JTL contained no samples" > "/dev/stderr"
        exit 2
      }
      if ((ended + 0) <= (started + 0)) {
        printf "JTL window has no duration (started=%.0f ended=%.0f samples=%d)\n", started, ended, samples > "/dev/stderr"
        exit 2
      }
      retries = polls > pays ? polls - pays : 0
      child_ops = requests >= retries ? requests - retries : 0
      print "samples=" samples
      print "requests=" requests
      print "iterations=" iterations
      print "journey_succeeded=" journey_succeeded
      print "journey_failed=" journey_failed
      print "journey_aborted=" journey_aborted
      print "succeeded=" succeeded
      print "failed=" failed
      print "status_errors=" status_errors
      print "non2xx=" non2xx
      print "transport_errors=" transport_errors
      printf "started=%.0f\n", started
      printf "ended=%.0f\n", ended
      print "elapsed_sum=" elapsed_sum
      print "journey_retries=" retries
      print "journey_child_ops=" child_ops
    }
  ' "${jtl}" > "${stats_file}" || return "${exit_exec}"
  LC_ALL=C sort -n "${elapsed_file}" -o "${elapsed_file}"
}

read_stat() {
  local stats="$1" name="$2"
  awk -F= -v name="${name}" '
    $1 == name { value=$2; found=1 }
    END { print (found && value != "" ? value : 0) }
  ' "${stats}"
}

publish_summary() {
  local jtl="$1" output_dir="$2" phase="$3" script_hash="$4"
  local scratch="${output_dir}/.scratch/${phase:-measure}"
  local stats="${scratch}/jtl-stats.txt" elapsed="${scratch}/request-elapsed.txt"
  mkdir -p "${scratch}" "${output_dir}/benchmark"
  parse_jtl "${jtl}" "${scratch}" || fail "unable to normalize JTL" "${exit_exec}"

  local requests iterations journey_succeeded journey_failed journey_aborted
  local succeeded failed status_errors non2xx transport_errors started ended elapsed_sum
  local retries child_ops window_ms rps error_rate mean p50 p90 p95 p99
  requests="$(read_stat "${stats}" requests)"
  iterations="$(read_stat "${stats}" iterations)"
  journey_succeeded="$(read_stat "${stats}" journey_succeeded)"
  journey_failed="$(read_stat "${stats}" journey_failed)"
  journey_aborted="$(read_stat "${stats}" journey_aborted)"
  succeeded="$(read_stat "${stats}" succeeded)"
  failed="$(read_stat "${stats}" failed)"
  status_errors="$(read_stat "${stats}" status_errors)"
  non2xx="$(read_stat "${stats}" non2xx)"
  transport_errors="$(read_stat "${stats}" transport_errors)"
  started="$(read_stat "${stats}" started)"
  ended="$(read_stat "${stats}" ended)"
  elapsed_sum="$(read_stat "${stats}" elapsed_sum)"
  retries="$(read_stat "${stats}" journey_retries)"
  child_ops="$(read_stat "${stats}" journey_child_ops)"

  if (( iterations == 0 )); then
    iterations="${requests}"
  elif (( journey_succeeded + journey_failed + journey_aborted != iterations )); then
    fail "journey outcomes do not reconcile" "${exit_exec}"
  fi
  window_ms=$((ended - started))
  rps="$(awk -v count="${requests}" -v window="${window_ms}" 'BEGIN { printf "%.9f", count * 1000.0 / window }')"
  error_rate="$(awk -v count="${requests}" -v failed="${failed}" 'BEGIN { printf "%.9f", count ? failed / count : 0 }')"
  mean="$(awk -v count="${requests}" -v sum="${elapsed_sum}" 'BEGIN { printf "%.6f", count ? sum / count : 0 }')"
  p50="$(percentile "${elapsed}" 50)"
  p90="$(percentile "${elapsed}" 90)"
  p95="$(percentile "${elapsed}" 95)"
  p99="$(percentile "${elapsed}" 99)"

  local summary_name="jmeter-summary-v1.json" jtl_name="results.jtl" write_observations=true
  case "${phase}" in
    warmup) summary_name="jmeter-warmup-summary-v1.json"; jtl_name="warmup-results.jtl"; write_observations=false ;;
    diagnostic) summary_name="jmeter-diagnostic-summary-v1.json"; jtl_name="diagnostic-results.jtl"; write_observations=false ;;
    ""|measure) ;;
    *) fail "--phase must be warmup, measure, or diagnostic" ;;
  esac

  require_manifest
  local adapter_id adapter_version summary_tmp summary_path
  adapter_id="$(jq -r '.adapterId' "${manifest}")"
  adapter_version="$(jq -r '.adapterVersion' "${manifest}")"
  summary_path="${output_dir}/benchmark/${summary_name}"
  summary_tmp="${summary_path}.tmp"
  jq -n \
    --arg script_hash "${script_hash}" \
    --arg jtl_hash "$(sha256_file "${jtl}")" \
    --argjson jtl_bytes "$(stat -c %s "${jtl}")" \
    --argjson requests "${requests}" \
    --argjson iterations "${iterations}" \
    --argjson journey_succeeded "${journey_succeeded}" \
    --argjson journey_failed "${journey_failed}" \
    --argjson journey_aborted "${journey_aborted}" \
    --argjson child_ops "${child_ops}" \
    --argjson retries "${retries}" \
    --argjson succeeded "${succeeded}" \
    --argjson failed "${failed}" \
    --argjson status_errors "${status_errors}" \
    --argjson non2xx "${non2xx}" \
    --argjson transport "${transport_errors}" \
    --argjson error_rate "${error_rate}" \
    --argjson rps "${rps}" \
    --argjson p50 "${p50}" --argjson p90 "${p90}" \
    --argjson p95 "${p95}" --argjson p99 "${p99}" \
    --argjson mean "${mean}" \
    --arg started "$(format_epoch_ms "${started}")" \
    --arg finished "$(format_epoch_ms "${ended}")" \
    --arg adapter_id "${adapter_id}" --arg adapter_version "${adapter_version}" '
      {
        scriptHash:$script_hash,jtlSha256:$jtl_hash,jtlBytes:$jtl_bytes,
        requests:$requests,iterations:$iterations,
        journeySucceeded:$journey_succeeded,journeyFailed:$journey_failed,
        journeyAborted:$journey_aborted,journeyChildOps:$child_ops,
        journeyWireRequests:$requests,journeyRetries:$retries,
        succeeded:$succeeded,failed:$failed,statusErrors:$status_errors,
        non2xx:$non2xx,transportErrors:$transport,droppedIterations:0,
        errorRate:$error_rate,requestsPerSecond:$rps,
        p50Ms:$p50,p90Ms:$p90,p95Ms:$p95,p99Ms:$p99,meanMs:$mean,
        startedAt:$started,finishedAt:$finished,
        adapterId:$adapter_id,adapterVersion:$adapter_version
      }
    ' > "${summary_tmp}"
  mv "${summary_tmp}" "${summary_path}"

  if [[ "${write_observations}" == true ]]; then
    local observations="${output_dir}/benchmark/observations.json"
    jq '[
      {name:"http.requests_per_second",value:.requestsPerSecond,unit:"request/s",source:"benchmark/jmeter-summary-v1.json"},
      {name:"http.latency.p50",value:.p50Ms,unit:"ms",source:"benchmark/jmeter-summary-v1.json"},
      {name:"http.latency.p90",value:.p90Ms,unit:"ms",source:"benchmark/jmeter-summary-v1.json"},
      {name:"http.latency.p95",value:.p95Ms,unit:"ms",source:"benchmark/jmeter-summary-v1.json"},
      {name:"http.latency.p99",value:.p99Ms,unit:"ms",source:"benchmark/jmeter-summary-v1.json"},
      {name:"http.requests.total",value:.requests,unit:"request",source:"benchmark/jmeter-summary-v1.json"},
      {name:"http.responses.non_2xx_3xx",value:.statusErrors,unit:"response",source:"benchmark/jmeter-summary-v1.json"},
      {name:"http.transport_errors",value:.transportErrors,unit:"error",source:"benchmark/jmeter-summary-v1.json"},
      {name:"http.error_rate",value:.errorRate,unit:"ratio",source:"benchmark/jmeter-summary-v1.json"},
      {name:"http.dropped_iterations",value:.droppedIterations,unit:"iteration",source:"benchmark/jmeter-summary-v1.json"}
    ] + (if .journeyWireRequests > 0 and .iterations != .requests then [
      # Same journey.* names and units as the k6 adapter, so gates, comparisons
      # and parity read one vocabulary; this adapter used to emit journeys.*.
      {name:"journey.starts",value:.iterations,unit:"iteration",source:"benchmark/jmeter-summary-v1.json"},
      {name:"journey.completed",value:.journeySucceeded,unit:"iteration",source:"benchmark/jmeter-summary-v1.json"},
      {name:"journey.failed",value:.journeyFailed,unit:"iteration",source:"benchmark/jmeter-summary-v1.json"},
      {name:"journey.aborted",value:.journeyAborted,unit:"iteration",source:"benchmark/jmeter-summary-v1.json"},
      {name:"journey.child_ops",value:.journeyChildOps,unit:"operation",source:"benchmark/jmeter-summary-v1.json"},
      {name:"journey.wire_requests",value:.journeyWireRequests,unit:"request",source:"benchmark/jmeter-summary-v1.json"},
      {name:"journey.retries",value:.journeyRetries,unit:"request",source:"benchmark/jmeter-summary-v1.json"},
      {name:"journey.request_amplification",value:(if .iterations > 0 then .journeyWireRequests / .iterations else 0 end),unit:"request/iteration",source:"benchmark/jmeter-summary-v1.json"}
    ] else [] end)' "${summary_path}" > "${observations}.tmp"
    mv "${observations}.tmp" "${observations}"
  fi

  cp "${jtl}" "${output_dir}/benchmark/${jtl_name}.tmp"
  mv "${output_dir}/benchmark/${jtl_name}.tmp" "${output_dir}/benchmark/${jtl_name}"
}

version_command() {
  local json_output=false
  [[ $# -le 1 ]] || fail "version accepts only --json"
  if [[ $# -eq 1 ]]; then
    [[ "$1" == "--json" ]] || fail "unknown version flag '$1'"
    json_output=true
  fi
  require_manifest
  local adapter_id adapter_version max_threads
  adapter_id="$(jq -r '.adapterId' "${manifest}")"
  adapter_version="$(jq -r '.adapterVersion' "${manifest}")"
  max_threads="$(jq -r '.maxThreads' "${manifest}")"
  if [[ "${json_output}" == false ]]; then
    printf '%s %s generator=jmeter maxThreads=%s\n' "${adapter_id}" "${adapter_version}" "${max_threads}"
    return
  fi
  jq -n \
    --arg generator jmeter \
    --arg adapter_id "${adapter_id}" \
    --arg adapter_version "${adapter_version}" \
    --arg image_digest "${PERFLAB_PLUGIN_IMAGE_DIGEST:-}" \
    --arg fingerprint "adapter=${adapter_version};maxThreads=${max_threads};id=${adapter_id}" \
    --arg revision "$(jq -r '.capabilityRevision // "v1"' "${manifest}")" \
    --arg contract "${PERFLAB_CONTRACT_DIGEST:-$(jq -r '.contractDigest // ""' "${manifest}")}" \
    --argjson cpus "$(jq '.cpus' "${manifest}")" \
    --argjson memory "$(jq '.memoryBytes' "${manifest}")" \
    --argjson max_threads "${max_threads}" '
      {
        generator:$generator,adapterId:$adapter_id,adapterVersion:$adapter_version,
        imageDigest:$image_digest,cpus:$cpus,memoryBytes:$memory,maxThreads:$max_threads,
        modes:["run-once","normalize","version"],fingerprint:$fingerprint,
        capabilityRevision:$revision,contractDigest:$contract
      }
    '
}

parse_invocation() {
  workload_root=""
  plan=""
  jtl=""
  output_dir=""
  phase=""
  timeout_value=""
  files=()
  while (($#)); do
    case "$1" in
      --workload-root|--plan|--file|--jtl|--output-dir|--phase|--timeout)
        local flag="$1"
        shift
        (($#)) || fail "flag ${flag} requires a value"
        case "${flag}" in
          --workload-root) workload_root="$1" ;;
          --plan) plan="$1" ;;
          --file) files+=("$1") ;;
          --jtl) jtl="$1" ;;
          --output-dir) output_dir="$1" ;;
          --phase) phase="$1" ;;
          --timeout) timeout_value="$1" ;;
        esac
        shift
        ;;
      *) fail "unknown flag '$1'" ;;
    esac
  done
  [[ -n "${output_dir}" ]] || fail "--output-dir is required"
}

normalize_command() {
  parse_invocation "$@"
  [[ -n "${jtl}" && -f "${jtl}" ]] || fail "--jtl is required"
  local content_hash
  if [[ -n "${workload_root}" || -n "${plan}" ]]; then
    [[ -n "${workload_root}" && -n "${plan}" ]] || fail "--workload-root and --plan must be supplied together"
    content_hash="$(hash_inventory "${workload_root}" "${plan}" "${files[@]}")"
  else
    content_hash="$(sha256_file "${jtl}")"
  fi
  publish_summary "${jtl}" "${output_dir}" "${phase:-measure}" "${content_hash}"
}

append_property() {
  local requested="$1" value="$2" canonical
  canonical="${requested}"
  case "${requested}" in
    perflab.base_url) canonical="perf.base_url" ;;
    perflab.threads) canonical="perf.threads" ;;
    perflab.duration_seconds) canonical="perf.duration_seconds" ;;
    perflab.run_id) canonical="perf.run_id" ;;
    perflab.scenario) canonical="perf.scenario" ;;
  esac
  jmeter_properties+=("-J${canonical}=${value}")
  if [[ "${canonical}" != "${requested}" ]]; then
    jmeter_properties+=("-J${requested}=${value}")
    legacy_properties+=("${requested}->${canonical}")
  fi
}

run_once_command() {
  parse_invocation "$@"
  case "${phase}" in warmup|measure|diagnostic) ;; *) fail "--phase must be warmup, measure, or diagnostic" ;; esac
  [[ "${timeout_value}" =~ ^[1-9][0-9]*(ms|s|m|h)$ ]] || fail "--timeout must be a positive duration"
  [[ -n "${workload_root}" && -d "${workload_root}" && -n "${plan}" ]] || fail "--workload-root and --plan are required"
  confined_relative "${plan}" || fail "path '${plan}' escapes the workload root"
  [[ -f "${workload_root}/${plan}" ]] || fail "workload plan ${plan} is missing"
  local rel
  for rel in "${files[@]}"; do
    confined_relative "${rel}" || fail "path '${rel}' escapes the workload root"
    [[ -f "${workload_root}/${rel}" ]] || fail "workload file ${rel} is missing"
  done
  require_manifest
  [[ "${PERFLAB_CONNECTIONS:-}" =~ ^[1-9][0-9]*$ ]] || fail "PERFLAB_CONNECTIONS must be a positive integer"
  local max_threads
  max_threads="$(jq -r '.maxThreads' "${manifest}")"
  (( PERFLAB_CONNECTIONS <= max_threads )) || fail "requested concurrency ${PERFLAB_CONNECTIONS} exceeds adapter maxThreads ${max_threads}"
  [[ -n "${JMETER_HOME:-}" && -f "${JMETER_HOME}/bin/ApacheJMeter.jar" ]] || fail "JMETER_HOME is not set to a valid JMeter runtime"

  local scratch="${output_dir}/.scratch/${phase}" raw_jtl="${output_dir}/.scratch/${phase}/results.jtl"
  mkdir -p "${scratch}/home" "${scratch}/tmp"
  jmeter_properties=()
  legacy_properties=()
  append_property "${PERFLAB_JMETER_PROP_BASE_URL:-perf.base_url}" "${PERF_BASE_URL:-}"
  append_property "${PERFLAB_JMETER_PROP_THREADS:-perf.threads}" "${PERFLAB_CONNECTIONS}"
  append_property "${PERFLAB_JMETER_PROP_DURATION_SECONDS:-perf.duration_seconds}" "${PERFLAB_DURATION_SECONDS:-}"
  append_property "${PERFLAB_JMETER_PROP_RUN_ID:-perf.run_id}" "${PERF_RUN_ID:-}"
  append_property "${PERFLAB_JMETER_PROP_SCENARIO:-perf.scenario}" "${PERF_SCENARIO:-}"
  local profile="${PERFLAB_PROFILE:-steady}" target_rps target_per_minute
  case "${profile}" in
    open|arrival|capacity|knee)
      target_rps="${PERFLAB_TARGET_RPS:-$((PERFLAB_CONNECTIONS * 10))}"
      [[ "${target_rps}" =~ ^[1-9][0-9]*$ ]] || fail "PERFLAB_TARGET_RPS must be a positive integer"
      target_per_minute=$((target_rps * 60))
      ;;
    *) target_rps=0; target_per_minute=600000000 ;;
  esac
  append_property "perf.profile" "${profile}"
  append_property "perf.target_rps" "${target_rps}"
  append_property "perf.target_per_minute" "${target_per_minute}"

  local -a command=(
    timeout --signal=TERM --kill-after=10s "${timeout_value}"
    java -Djava.awt.headless=true
    "-Duser.home=${scratch}/home" "-Djava.io.tmpdir=${scratch}/tmp"
    -jar "${JMETER_HOME}/bin/ApacheJMeter.jar" -n
    -t "${workload_root}/${plan}" -l "${raw_jtl}" -j "${scratch}/jmeter.log"
    -Jjmeter.save.saveservice.output_format=csv
    -Jjmeter.save.saveservice.print_field_names=true
    -Jjmeter.save.saveservice.timestamp_format=ms
    -Jjmeter.save.saveservice.time=true
    -Jjmeter.save.saveservice.label=true
    -Jjmeter.save.saveservice.response_code=true
    -Jjmeter.save.saveservice.response_message=true
    -Jjmeter.save.saveservice.successful=true
    -Jjmeter.save.saveservice.latency=true
    "${jmeter_properties[@]}"
  )
  if ! (cd "${workload_root}" && "${command[@]}"); then
    fail "JMeter execution failed or timed out" "${exit_exec}"
  fi
  local content_hash
  content_hash="$(hash_inventory "${workload_root}" "${plan}" "${files[@]}")"
  publish_summary "${raw_jtl}" "${output_dir}" "${phase}" "${content_hash}"
  if ((${#legacy_properties[@]})); then
    printf 'v1 property adapter applied: %s\n' "$(IFS=', '; printf '%s' "${legacy_properties[*]}")" >&2
  fi
}

usage() {
  printf '%s\n' 'usage: dotnet-perf-eng-load-jmeter run-once | normalize | version [--json]'
}

command_name="${1:-}"
[[ -n "${command_name}" ]] || { usage >&2; exit "${exit_usage}"; }
shift
case "${command_name}" in
  version) version_command "$@" ;;
  normalize) normalize_command "$@" ;;
  run-once) run_once_command "$@" ;;
  -h|--help|help) usage ;;
  *) fail "unknown mode '${command_name}' (want run-once, normalize, or version)" ;;
esac
