#!/usr/bin/env bash
# D-P0-6 live qualification. It starts a separate Compose project so an
# operator's normal lab is never restarted or reused. The only app request is
# made after the rule is confirmed Running; it must create exactly one Triage
# dump in the monitor's 512 MiB tmpfs, then the production bounded-copy helper
# must remove the source file after its temporary local copy is verified.
set -euo pipefail

root="$(CDPATH= cd -- "$(dirname "$0")/../../../.." && pwd)"
base_compose="${root}/labs/protocol-reliability/compose.yaml"
override_compose="${root}/labs/protocol-reliability/compose.collection-rules-live.yaml"
fail() { echo "collection-rules-live-test: $*" >&2; exit 1; }
for tool in docker curl jq lsof; do
  command -v "${tool}" >/dev/null 2>&1 || fail "${tool} is required"
done
[[ -f "${base_compose}" && -f "${override_compose}" ]] || fail "missing Protocol Reliability Compose fixture"

monitor_port=""
for candidate in $(seq 29423 29459); do
  api_candidate=$((candidate - 1000))
  metrics_candidate=$((candidate + 2))
  if ! lsof -n -iTCP:"${candidate}" -sTCP:LISTEN >/dev/null 2>&1 &&
     ! lsof -n -iTCP:"${metrics_candidate}" -sTCP:LISTEN >/dev/null 2>&1 &&
     ! lsof -n -iTCP:"${api_candidate}" -sTCP:LISTEN >/dev/null 2>&1; then
    monitor_port="${candidate}"
    break
  fi
done
[[ -n "${monitor_port}" ]] || fail "no isolated local port set is available"
metrics_port=$((monitor_port + 2))
api_port=$((monitor_port - 1000))
project="perflab-collection-rules-${monitor_port}"
work="$(mktemp -d "${TMPDIR:-/tmp}/collection-rules-live.XXXXXX")"

compose() {
  PERFLAB_COLLECTION_RULES_MONITOR_PORT="${monitor_port}" \
  PERFLAB_COLLECTION_RULES_METRICS_PORT="${metrics_port}" \
  PERFLAB_COLLECTION_RULES_API_PORT="${api_port}" \
  PERFLAB_COLLECTION_RULES=1 \
  PERFLAB_DUMP_ACK=i-understand-sensitive-dump \
  PERF_RUN_MODE=diagnose \
  PERFLAB_TARGET_KIND=managed-compose \
    docker compose -p "${project}" -f "${base_compose}" -f "${override_compose}" "$@"
}
cleanup() {
  compose down --volumes --remove-orphans >/dev/null 2>&1 || true
  if [[ "${PERFLAB_TEST_KEEP:-0}" == "1" ]]; then
    echo "retained live evidence at ${work}" >&2
  else
  rm -rf -- "${work}"
  fi
}
trap cleanup EXIT HUP INT TERM

compose up -d --build diagnostic-permissions dotnet-monitor api-a >/dev/null
monitor="http://127.0.0.1:${monitor_port}"
api="http://127.0.0.1:${api_port}"
uid=""
for _ in $(seq 1 60); do
  processes="$(curl -fsS --max-time 2 "${monitor}/processes" 2>/dev/null || true)"
  uid="$(printf '%s' "${processes}" | jq -r '.[0].uid // empty' 2>/dev/null || true)"
  [[ -n "${uid}" ]] && break
  sleep 1
done
[[ -n "${uid}" ]] || { compose logs dotnet-monitor api-a >&2; fail "monitor never attached to api-a"; }

command_line="$(compose exec -T dotnet-monitor sh -c "tr '\\000' ' ' </proc/1/cmdline")"
[[ "${command_line}" == *"--configuration-file-path /opt/perflab/collection-rules.json"* ]] \
  || fail "armed monitor was not launched with the real CollectionRules configuration"
tmpfs="$(docker inspect "$(compose ps -q dotnet-monitor)" --format '{{json .HostConfig.Tmpfs}}')"
printf '%s' "${tmpfs}" | jq -e '."/diag/collection-rule-dumps" | contains("size=536870912")' >/dev/null \
  || fail "monitor CollectionRules egress is not mounted as a 512 MiB tmpfs"

rule_state() {
  curl -fsS --max-time 5 --get --data-urlencode "uid=${uid}" "${monitor}/collectionrules" |
    jq -r '.PerflabCrashDump.state // empty'
}
[[ "$(rule_state)" == "Running" ]] || fail "rule was not Running before the first application request"
source_count() {
  compose exec -T dotnet-monitor sh -c '
count=0
for dump in /diag/collection-rule-dumps/*; do
  [ -f "$dump" ] || continue
  count=$((count + 1))
done
printf "%s" "$count"
'
}
[[ "$(source_count)" == "0" ]] || fail "rule egress was not empty before its trigger"

# The monitor attaches when the runtime starts, before Kestrel listens. The
# deploy-time telemetry injection widened that gap enough that the one
# permitted request reached Docker's port proxy first and came back empty.
# Wait for the listening socket inside the container instead: that is not an
# ASP.NET request, so the rule's single trigger is still the request below.
listening=0
for _ in $(seq 1 60); do
  if compose exec -T api-a sh -c 'cat /proc/net/tcp /proc/net/tcp6 2>/dev/null' |
      awk '$2 ~ /:1F90$/ && $4 == "0A" { found = 1 } END { exit !found }'; then
    listening=1
    break
  fi
  sleep 1
done
[[ "${listening}" == "1" ]] || { compose logs api-a >&2; fail "api-a never listened on 8080"; }

# This is the one application request permitted by the configured
# AspNetRequestCount trigger. Polling afterward talks only to monitor.
curl -fsS --max-time 10 "${api}/api/reliability/status" >/dev/null
for _ in $(seq 1 90); do
  [[ "$(source_count)" == "1" ]] && break
  sleep 1
done
[[ "$(source_count)" == "1" ]] || { compose logs dotnet-monitor api-a >&2; fail "first request did not create exactly one dump"; }
state="$(rule_state)"
[[ "${state}" == "Throttled" || "${state}" == "Completed" ]] \
  || fail "rule did not report its one-action terminal state (got ${state:-empty})"

# Reuse the actual harness path instead of an unbounded docker/compose copy.
# It reads only the closed diagnostic directory, copies with limit+1, and
# purges the source only after the bounded copy succeeds.
# shellcheck disable=SC1091
source "${root}/harness/core/lib/performance.sh"
copy_dir="${work}/bounded-copy"
PERFLAB_CRASH_DUMP_MAX_BYTES=536870912 \
  performance_crash_dump_collect_path_from dotnet-monitor /diag/collection-rule-dumps "${copy_dir}" \
  || fail "bounded CollectionRules dump copy/purge failed"
copy_count="$(find "${copy_dir}" -type f | wc -l | tr -d '[:space:]')"
[[ "${copy_count}" == "1" ]] || fail "bounded copy retained ${copy_count} dumps, want one"
copy_bytes="$(find "${copy_dir}" -type f -exec wc -c {} \; | awk '{print $1}')"
[[ "${copy_bytes}" -gt 0 && "${copy_bytes}" -le 536870912 ]] \
  || fail "copied dump has invalid size ${copy_bytes:-empty}"
[[ "$(source_count)" == "0" ]] || fail "CollectionRules source dump survived bounded copy/purge"

echo "live CollectionRules passed: armed monitor loaded the real config, one ${copy_bytes}-byte Triage dump stayed within its tmpfs budget, and the source was purged"
