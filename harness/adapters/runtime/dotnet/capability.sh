#!/usr/bin/env bash
# Runtime capability preflight for dotnet-monitor. This is deliberately a live
# report, not a static image/version claim: the monitor tells us its diagnostic
# port mode and enabled in-process capability, and its OpenAPI document tells
# us whether the exact capture endpoint exists before we start any EventPipe
# session or dump collection.

dotnet_monitor_capability_fetch() { # <destination> <url>
  local dest="$1" url="$2" limit=1048576 rc bytes
  set +e
  monitor_curl -fsS --max-time 10 "${url}" | head -c $((limit + 1)) > "${dest}.tmp"
  rc=$?
  set -e
  bytes="$(wc -c < "${dest}.tmp" | tr -d ' ')"
  if (( bytes == 0 || bytes > limit || rc != 0 )); then
    rm -f "${dest}.tmp"
    if (( bytes > limit )); then
      echo "dotnet-monitor capability response exceeded the ${limit}-byte safety limit." >&2
    else
      echo "Could not read the dotnet-monitor capability response from ${url}." >&2
    fi
    return 1
  fi
  mv "${dest}.tmp" "${dest}"
}

dotnet_monitor_capability_require() { # <artifact-dir> <uid> <kind>...
  local artifact_dir="$1" runtime_uid="$2"; shift 2
  local report_dir="${artifact_dir}/runtime" info_file openapi_file report_file
  local kind path enabled
  [[ -n "${runtime_uid}" ]] || { echo "Cannot preflight dotnet-monitor capabilities without a selected runtime uid." >&2; return 1; }
  (( $# > 0 )) || { echo "Cannot preflight dotnet-monitor capabilities without a requested diagnostic kind." >&2; return 1; }
  mkdir -p "${report_dir}"
  info_file="${report_dir}/.monitor-info.json"
  openapi_file="${report_dir}/.monitor-openapi.json"
  report_file="${report_dir}/capabilities.json"
  trap 'rm -f "${info_file}" "${openapi_file}" "${info_file}.tmp" "${openapi_file}.tmp"' RETURN
  dotnet_monitor_capability_fetch "${info_file}" "${diagnostics_url}/info" || return 1
  dotnet_monitor_capability_fetch "${openapi_file}" "${diagnostics_url}/" || return 1
  if ! jqd -e '
    type == "object" and
    (.diagnosticPortMode == "Listen") and
    ((.diagnosticPortName // "") | type == "string" and length > 0) and
    ((.version // "") | type == "string" and length > 0)
  ' < "${info_file}" >/dev/null 2>&1; then
    echo "dotnet-monitor does not report a live Listen-mode diagnostic port; refusing diagnostic capture." >&2
    return 1
  fi

  for kind in "$@"; do
    case "${kind}" in
      trace) path="/trace" ;;
      gcdump) path="/gcdump" ;;
      dump) path="/dump" ;;
      stacks)
        path="/stacks"
        enabled="$(jqd -r '[.capabilities[]? | select(.name == "call_stacks") | .enabled][0] // false' < "${info_file}")"
        [[ "${enabled}" == "true" ]] || { echo "dotnet-monitor does not advertise enabled call_stacks; refusing /stacks before profiler injection." >&2; return 1; }
        ;;
      *) echo "Unknown dotnet-monitor capability kind '${kind}'." >&2; return 1 ;;
    esac
    if ! jqd -e --arg path "${path}" '
      (.paths[$path] // {}) | type == "object" and
      (has("get") or has("post"))
    ' < "${openapi_file}" >/dev/null 2>&1; then
      echo "dotnet-monitor does not advertise ${path}; refusing ${kind} capture before perturbing the target." >&2
      return 1
    fi
  done

  # Keep only verified, bounded provenance rather than preserving the full
  # remote OpenAPI response in an artifact. The report is enough to reproduce
  # the preflight decision without exposing arbitrary monitor configuration.
  jqd -nc --argjson info "$(cat "${info_file}")" --arg uid "${runtime_uid}" '
    $info as $i |
    {
      version: "perflab-dotnet-monitor-capability-v1",
      targetUid: $uid,
      monitor: {
        version: $i.version,
        runtimeVersion: ($i.runtimeVersion // ""),
        diagnosticPortMode: $i.diagnosticPortMode,
        diagnosticPortName: $i.diagnosticPortName,
        callStacks: ([ $i.capabilities[]? | select(.name == "call_stacks") | .enabled ][0] // false)
      },
      requestedCaptures: $ARGS.positional,
      state: "supported"
    }
  ' --args "$@" > "${report_file}" || {
    rm -f "${report_file}"
    echo "Could not record the verified dotnet-monitor capability report." >&2
    return 1
  }
}
