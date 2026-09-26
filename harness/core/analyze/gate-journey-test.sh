#!/usr/bin/env bash
# A journey that failed is a correctness failure, whichever generator ran it.
#
# The gate read only journeys.failed, the JMeter adapter's former name, so a k6
# checkout run with failed journeys (journey.failed) passed. Packages recorded
# before the JMeter adapter moved to journey.* must still gate.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
fail() { echo "gate-journey-test: $*" >&2; exit 1; }
jq_bin="$(command -v jq || true)"; [[ -n "${jq_bin}" ]] || fail "jq is required"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/gate-journey-test.XXXXXX")"
trap 'rm -rf "${test_root}"' EXIT
mkdir -p "${test_root}/bin"
cat > "${test_root}/bin/docker" <<EOF
#!/usr/bin/env bash
set -euo pipefail
[[ "\${1:-}" == "run" ]] || exit 0
shift
while [[ \$# -gt 0 ]]; do
  case "\$1" in --rm|--interactive|-i|-t|--tty) shift ;; *) break ;; esac
done
shift
exec "${jq_bin}" "\$@"
EOF
chmod +x "${test_root}/bin/docker"

package() { # package <name> <failed-metric> <failed-count>
  local dir="${test_root}/$1"
  mkdir -p "${dir}"
  printf '{"runId":"%s","telemetryRunId":"%s","scenarioId":"checkout","status":"captured","observations":[{"name":"http.error_rate","value":0},{"name":"http.dropped_iterations","value":0},{"name":"efficiency.cpu_ms_per_request","value":3},{"name":"%s","value":%s}]}\n' \
    "$1" "$1" "$2" "$3" > "${dir}/facts.json"
  printf '%s' "${dir}"
}
gate() { # gate <dir> -> exit code; output in <dir>/gate.out
  local rc=0
  PATH="${test_root}/bin:${PATH}" PERFLAB_LAB=ecommerce \
    bash "${repo}/harness/core/analyze/gate.sh" "$1" --no-baseline --allow-missing > "$1/gate.out" 2>&1 || rc=$?
  return "${rc}"
}

k6_failed="$(package k6-failed journey.failed 3)"
if gate "${k6_failed}"; then fail "a k6 run with 3 failed journeys passed the gate: $(cat "${k6_failed}/gate.out")"; fi
grep -q 'journey.failed .*observed=3 FAIL (correctness)' "${k6_failed}/gate.out" \
  || fail "the gate did not name the failed journeys: $(cat "${k6_failed}/gate.out")"

legacy="$(package legacy-jmeter journeys.failed 2)"
if gate "${legacy}"; then fail "a package recorded with journeys.failed stopped gating"; fi

clean="$(package k6-clean journey.failed 0)"
gate "${clean}" || fail "a journey run with no failures did not pass: $(cat "${clean}/gate.out")"

echo "gate journey tests passed"
