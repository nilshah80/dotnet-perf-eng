#!/usr/bin/env bash
# Evidence safety: secrets must not reach artifacts, and labels must stay bounded.
#
# Acceptance case 26 -- no credential values in arguments or artifacts. An
# evidence package is shared, attached to tickets and read by people who were
# not on the run; a password that reaches it is disclosed, and no later redaction
# un-discloses it.
#
# Acceptance case 27 -- unbounded metric and profile labels are rejected. A label
# whose value is per-request (a trace id, a URL with an id in it, a run id used
# as a metric label) multiplies series without limit, and the backend degrades
# for every other query, not just the offending one.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
fail() { echo "evidence-safety-test: $*" >&2; exit 1; }

# --- case 26: credential values in artifacts --------------------------------
# Values, not names: PERFLAB_..._PASSWORD appearing as a variable NAME in a
# descriptor is configuration, while the resolved value in a captured artifact
# is a disclosure.
secret_names='POSTGRES_PASSWORD RABBITMQ_PASSWORD PERFLAB_MONITOR_TOKEN PERFLAB_BACKEND_TOKEN'

# The lab descriptors must never hardcode a credential value: every one has to
# come from the environment with a documented default, so a real deployment can
# supply its own without editing a checked-in file.
for descriptor in "${repo}"/labs/*/lab.config.sh "${repo}"/labs/*/compose.yaml; do
  [[ -f "${descriptor}" ]] || continue
  for name in ${secret_names}; do
    # Accept ${NAME:-default} indirection; reject NAME=<literal>.
    if grep -E "^[[:space:]]*${name}[:=][[:space:]]*[\"']?[A-Za-z0-9]" "${descriptor}" 2>/dev/null \
       | grep -qv '\${'; then
      fail "${descriptor} hardcodes a value for ${name}; it must come from the environment"
    fi
  done
done

# A captured package must not contain a resolved credential. This scans EVERY
# retained run, not just the newest: a leak in an older package is still a leak,
# and scanning only the latest meant the check passed by forgetting.
#
# It also scans binary evidence. A process dump or nettrace is exactly where a
# connection string ends up, and excluding them scanned the places least likely
# to hold a secret while skipping the most likely.
credential_values='perflab'
runs_root="${repo}/artifacts/runs"
scanned=0
if [[ -d "${runs_root}" ]]; then
  while IFS= read -r run; do
    scanned=$((scanned + 1))
    for value in ${credential_values}; do
      # -a treats binaries as text so dumps and traces are searched too.
      if hits="$(grep -ral -e "Password=${value}" -e "password=${value}" -e "PASSWORD=${value}" \
                   -e ":${value}@" "${run}" 2>/dev/null | head -3)" && [[ -n "${hits}" ]]; then
        fail "a credential value reached evidence under ${run}:"$'\n'"${hits}"
      fi
    done
    # Command arguments are captured as provenance and are a classic leak path:
    # a token passed on a command line is visible in every process listing.
    for record in "${run}/source/tool-versions.txt" "${run}"/runtime/capture.json \
                  "${run}"/benchmark/*compatibility*.json; do
      [[ -f "${record}" ]] || continue
      if grep -qE -- '--(password|token|secret|api-key)[= ]' "${record}" 2>/dev/null; then
        fail "a credential-bearing argument was recorded in ${record}"
      fi
    done
  done < <(find "${runs_root}" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
fi

# A scan that silently finds nothing to scan proves nothing. Build a package
# that DOES contain a credential and confirm the scan would have caught it --
# otherwise this test passes on an empty machine for the wrong reason.
probe="$(mktemp -d "${TMPDIR:-/tmp}/evidence-safety-probe.XXXXXX")"
trap 'rm -rf "${probe}"' EXIT HUP INT TERM
mkdir -p "${probe}/telemetry"
printf 'Host=postgres;Password=perflab;Database=perflab\n' > "${probe}/telemetry/leak.json"
if ! grep -ral -e 'Password=perflab' "${probe}" >/dev/null 2>&1; then
  fail "the credential scan cannot detect a planted credential; it would pass on a leaking package"
fi
echo "  scanned ${scanned} retained run(s); scanner self-check passed"

# --- case 27: unbounded metric and profile labels ---------------------------
# A static grep over two files proves nothing about what the harness would DO
# with a bad selector. This exercises the rejection path itself, with fixtures
# on both sides: a selector that must be refused, and one that must not be.
# shellcheck disable=SC1091
source "${repo}/harness/core/lib/performance.sh"

reject_cases=(
  'sum by (trace_id) (http_server_request_duration_seconds_count)'
  'sum by(span_id, service) (rate(x[1m]))'
  'http_client_request_duration_seconds_count{http_url="https://example/api/42"}'
  'sum without (session_id) (x)'
  'count by (user_id) (orders_total)'
  'x{correlation_id=~".*"}'
)
for selector in "${reject_cases[@]}"; do
  if performance_reject_unbounded_labels fixture "${selector}" 2>/dev/null; then
    fail "an unbounded selector was accepted: ${selector}"
  fi
done

# The bounded cases matter as much: a validator that refuses everything would
# pass the tests above and make the harness unusable.
accept_cases=(
  'sum by (service_instance_id) (dotnet_process_cpu_time_seconds_total)'
  'sum by (exporter) (rate(otelcol_exporter_send_failed_spans_total[1m]))'
  'dotnet_thread_pool_queue_length_total{job=~"perflab-.*",perf_run_id="run-1"}'
  'sum by (db_client_connection_pool_name) (db_client_connection_count)'
  'sum by (server_address) (http_client_active_requests)'
)
for selector in "${accept_cases[@]}"; do
  performance_reject_unbounded_labels fixture "${selector}" 2>/dev/null \
    || fail "a bounded selector was refused: ${selector}"
done

# And every role the runtime adapter actually ships must pass its own rule --
# a validator nothing satisfies would be switched off the first time it fired.
# shellcheck disable=SC1090
source "${repo}/harness/adapters/runtime/dotnet/metrics.sh"
for entry in "${PERFLAB_METRIC_ROLES[@]}"; do
  IFS='|' read -r role _ selector <<< "${entry}"
  performance_reject_unbounded_labels "${role}" "${selector}" \
    || fail "the shipped metric role '${role}' violates the cardinality rule"
done

echo "evidence safety (secret scan, label cardinality) tests passed"
