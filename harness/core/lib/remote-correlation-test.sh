#!/usr/bin/env bash
# D-P1-7: remote correlation is an executable pre-traffic contract, not a
# metadata switch. This test exercises the exact-ID echo and rejects both an
# altered response and a user header that would replace the generated ID.
set -euo pipefail

root="$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)"
fail() { echo "remote-correlation-test: $*" >&2; exit 1; }
command -v jq >/dev/null || fail "jq is required"

# common.sh supplies validate_target_headers. Helpers-only avoids selecting a
# lab; replace dockerized jq with the host jq for this hermetic unit test.
export PERFLAB_LAB_OPTIONAL=1
# shellcheck disable=SC1091
source "${root}/harness/core/lib/common.sh"
# Delegates to the host jq so the selector under test is the real one, but it
# must keep BOTH guards common.sh's jqd applies. jq.exe writes CRLF on Windows,
# so a value read through a bare override carries a trailing CR that corrupts
# every later comparison and URL built from it; and MSYS rewrites any argument
# that looks like a POSIX path, so `--arg path /stacks` reaches jq.exe as
# C:/Program Files/Git/stacks and the lookup silently misses.
jqd() { MSYS_NO_PATHCONV=1 jq "$@" | tr -d '\r'; return "${PIPESTATUS[0]}"; }
# shellcheck disable=SC1091
source "${root}/harness/core/lib/performance.sh"

target_mode=remote
remote_telemetry=1
remote_correlation=1
remote_correlation_version=perflab-run-id-v1
remote_correlation_probe_path=/api/reliability/correlation
remote_correlation_header=X-Perf-Run-Id
remote_correlation_response_run_id_field=runId
remote_correlation_response_version_field=contractVersion
remote_correlation_prometheus_label=perf_run_id
remote_correlation_loki_label=perf_run_id
remote_correlation_tempo_attribute=span.perf.run.id

probe_mode=good
target_curl() {
  local saw_header=0 argument
  for argument in "$@"; do
    [[ "${argument}" == "X-Perf-Run-Id: run-proof" ]] && saw_header=1
  done
  [[ "${saw_header}" == "1" ]] || return 41
  case "${probe_mode}" in
    good) printf '{"runId":"run-proof","contractVersion":"perflab-run-id-v1"}\n' ;;
    wrong-run) printf '{"runId":"other-run","contractVersion":"perflab-run-id-v1"}\n' ;;
    *) return 42 ;;
  esac
}

work="$(mktemp -d "${TMPDIR:-/tmp}/remote-correlation.XXXXXX")"
trap 'rm -rf "${work}"' EXIT HUP INT TERM
proof="${work}/proof.json"
performance_remote_correlation_probe "https://target.example/base" run-proof "${proof}" \
  || fail "exact target proof was rejected"
jq -e '.verified == true and .runId == "run-proof" and .tempoAttribute == "span.perf.run.id"' \
  "${proof}" >/dev/null || fail "proof omitted the verified target contract"

probe_mode=wrong-run
if performance_remote_correlation_probe "https://target.example/base" run-proof "${work}/wrong.json" 2>/dev/null; then
  fail "a mismatched echoed run id was accepted"
fi

PERF_HEADERS='{"X-Perf-Run-Id":"caller-controlled"}'
if validate_target_headers 2>/dev/null; then
  fail "PERF_HEADERS was allowed to override the generated run id"
fi
PERF_HEADERS='{"Authorization":"Bearer test-only"}'
validate_target_headers || fail "ordinary target authorization header was rejected"

echo "remote correlation contract tests passed"
