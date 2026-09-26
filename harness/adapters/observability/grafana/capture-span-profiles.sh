#!/usr/bin/env bash
# Span-to-profile correlation evidence (D-P1-3) for the native package.
# Sourced by capture-evidence.sh after the traces and the Pyroscope profiles.
#
# With continuous CPU profiling on an x64 process, the deploy-time injection
# (harness/adapters/runtime/dotnet/injection) tags each local root span with
# pyroscope.profile.id and labels the CPU samples taken while it ran with the
# same id. This reads the ids from the detail traces already captured -- the
# median, p95, p99 and slowest -- and asks Pyroscope for the CPU profile of
# exactly those spans, so a slow trace opens onto its own flame graph.
#
# Best-effort, like every Gate C signal: the result records its own capture
# state and never marks the package incomplete. CPU profiles only.
#
# Required globals: artifact_dir, continuous_profiling, capture_telemetry,
# pyroscope_url, start_epoch, end_epoch, telemetry_run_id, target_mode,
# PYROSCOPE_PROFILE_TYPE (from capture-profiles.sh), json_escape, jqd.
SPAN_PROFILE_MAX_NODES="${SPAN_PROFILE_MAX_NODES:-4096}"

span_profiles_write() { # <state> <reason> <traces> <spans> <services-json>
  printf '{"schemaVersion":"span-profiles-v1","captureState":"%s","reason":"%s","endpoint":"%s","profileType":"%s","startEpoch":%s,"endEpoch":%s,"tracesExamined":%s,"spansWithProfileId":%s,"services":[%s]}\n' \
    "$1" "$(json_escape "$2")" "$(json_escape "$(pyroscope_record_endpoint "${pyroscope_url:-}")")" \
    "$(json_escape "${PYROSCOPE_PROFILE_TYPE}")" "${start_epoch}" "${end_epoch}" "$3" "$4" "$5" \
    > "${artifact_dir}/telemetry/profiles/span-profiles.json"
}

# span_profile_ids <trace-detail-file>... -> TSV: service, profile id
span_profile_ids() {
  cat "$@" 2>/dev/null | jqd -r '
    (.batches // .resourceSpans // .trace.resourceSpans // [])[] as $rs
    | (($rs.resource.attributes // []) | map(select(.key == "service.name"))[0].value.stringValue // "") as $service
    | ($rs.scopeSpans // $rs.instrumentationLibrarySpans // [])[] | (.spans // [])[]
    | ((.attributes // []) | map(select(.key == "pyroscope.profile.id"))[0].value.stringValue // empty) as $id
    | select($service != "" and ($id | test("^[0-9a-f]{16}$")))
    | [$service, $id] | @tsv' 2>/dev/null | LC_ALL=C sort -u
}

# span_profile_query <service> <ids> <artifact> -> sets span_total, span_state, span_code
span_profile_query() {
  local service="$1" ids="$2" file="$3" selector body
  span_total=0; span_state="failed"; span_code=""
  selector="{service_name=\"${service}\"}"
  [[ "${target_mode}" == "local" ]] && selector="{service_name=\"${service}\",perf_run_id=\"${telemetry_run_id}\"}"
  # Pyroscope stamps each profile upload at the start of its period, so the
  # upload holding the first measured requests carries a timestamp from before
  # the window: a query starting at the window missed every sample in S00. The
  # span ids belong to this run alone, so a minute either side cannot admit
  # another run's samples.
  # shellcheck disable=SC2086 # one span id per word
  body="$(jqd -cn --arg type "${PYROSCOPE_PROFILE_TYPE}" --arg selector "${selector}" \
    --arg start "$(((start_epoch - 60) * 1000))" --arg end "$(((end_epoch + 60) * 1000))" \
    --argjson maxNodes "${SPAN_PROFILE_MAX_NODES}" \
    '{profileTypeID: $type, labelSelector: $selector, spanSelector: $ARGS.positional, start: $start, end: $end, maxNodes: $maxNodes}' \
    --args ${ids})"
  span_code="$(curl -sS --max-time 30 -o "${file}.tmp" -w '%{http_code}' -H 'Content-Type: application/json' \
    --data "${body}" "${pyroscope_url%/}/querier.v1.QuerierService/SelectMergeSpanProfile" 2>/dev/null || true)"
  case "${span_code}" in
    2[0-9][0-9])
      mv "${file}.tmp" "${file}"
      span_total="$(jqd -r '(.flamegraph.total // "0") | tostring' < "${file}" 2>/dev/null || echo 0)"
      [[ "${span_total}" =~ ^[0-9]+$ ]] || span_total=0
      if (( span_total > 0 )); then span_state="captured"; else span_state="empty"; fi
      ;;
    *) rm -f "${file}.tmp" ;;
  esac
}

pyroscope_capture_span_profiles() {
  mkdir -p "${artifact_dir}/telemetry/profiles"
  if [[ "${continuous_profiling:-0}" != "1" || "${capture_telemetry:-0}" != "1" ]]; then
    span_profiles_write not-applicable "continuous CPU profiling was not enabled for this run" 0 0 ""
    return 0
  fi
  local details=() traces spans pairs service ids file services_json="" captured=0 reached=0
  while IFS= read -r file; do details+=("${file}"); done < <(find "${artifact_dir}/telemetry/traces/details" -type f -name '*.json' 2>/dev/null | LC_ALL=C sort)
  traces="${#details[@]}"
  if (( traces == 0 )); then
    span_profiles_write missing "no trace details were captured to correlate" 0 0 ""
    return 0
  fi
  pairs="$(span_profile_ids "${details[@]}")"
  spans="$(printf '%s' "${pairs}" | grep -c . || true)"
  if (( spans == 0 )); then
    span_profiles_write missing "no captured span carries pyroscope.profile.id: the injection links spans only in an x64 process with continuous CPU profiling on (pyroscope-dotnet's span API is x64-only)" "${traces}" 0 ""
    return 0
  fi
  for service in $(printf '%s\n' "${pairs}" | cut -f1 | LC_ALL=C sort -u); do
    ids="$(printf '%s\n' "${pairs}" | awk -F'\t' -v s="${service}" '$1 == s { print $2 }')"
    span_profile_query "${service}" "${ids}" "${artifact_dir}/telemetry/profiles/span-${service}-cpu.json"
    [[ "${span_state}" == captured ]] && captured=$((captured + 1))
    [[ "${span_state}" == captured || "${span_state}" == empty ]] && reached=1
    services_json="${services_json}${services_json:+,}$(printf '{"service":"%s","spanIds":%s,"totalSamples":%s,"httpStatus":"%s","captureState":"%s","artifact":"%s"}' \
      "$(json_escape "${service}")" "$(printf '%s\n' "${ids}" | grep -c .)" "${span_total}" "$(json_escape "${span_code}")" "${span_state}" \
      "$([[ "${span_state}" == failed ]] || echo "telemetry/profiles/span-${service}-cpu.json")")"
  done
  if (( captured > 0 )); then
    span_profiles_write captured "" "${traces}" "${spans}" "${services_json}"
  elif (( reached == 1 )); then
    span_profiles_write missing "Pyroscope answered but held no CPU samples for the tagged spans" "${traces}" "${spans}" "${services_json}"
  else
    span_profiles_write failed "Pyroscope was unreachable" "${traces}" "${spans}" "${services_json}"
  fi
}
