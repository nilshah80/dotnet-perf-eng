#!/usr/bin/env bash
# Acceptance case 46: material host change is detected, not just recorded.
#
# A measurement is comparable to another only if the machine was the same
# machine. Recording the environment and never comparing it means the evidence
# exists and nobody reads it -- which is the same as not having it.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
fail() { echo "environment-drift-test: $*" >&2; exit 1; }
command -v jq >/dev/null || fail "jq is required"
command -v docker >/dev/null || fail "docker is required for the jq shim"

test_root="$(mktemp -d "${TMPDIR:-/tmp}/env-drift-test.XXXXXX")"
trap 'rm -rf "${test_root}"' EXIT HUP INT TERM
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
exec $(command -v jq) "\$@"
EOF
chmod +x "${test_root}/bin/docker"

# build_run <name> <first-json> <last-json>
build_run() {
  local dir="${test_root}/$1"
  mkdir -p "${dir}/environment/a-before" "${dir}/environment/z-after"
  printf '%s\n' "$2" > "${dir}/environment/a-before/host.json"
  printf '%s\n' "$3" > "${dir}/environment/z-after/host.json"
  printf '%s' "${dir}"
}

drift() {
  PATH="${test_root}/bin:${PATH}" PERFLAB_CONFIG="${repo}/labs/scenariolab/lab.config.sh" \
    bash "${repo}/harness/core/analyze/environment-drift.sh" "$1" > "$1/out.txt" 2>&1
  printf '%s' "$1/analysis/environment-drift.json"
}

stable_host='{"capturedAt":"t","phase":"before","loadAverage":{"1m":2.0,"5m":2.0,"15m":2.0},"dockerContainersRunning":7,"hostCpus":8,"hostMemoryBytes":8589934592}'

# --- an unchanged host is stable -------------------------------------------
report="$(drift "$(build_run stable "${stable_host}" "${stable_host}")")"
jq -e '.verdict == "stable" and .materialChange == false' "${report}" >/dev/null \
  || fail "an unchanged host was reported as drifted: $(jq -c '{verdict,findings}' "${report}")"

# --- a changed CPU allocation invalidates the comparison --------------------
changed_cpus='{"capturedAt":"t","phase":"after","loadAverage":{"1m":2.0},"dockerContainersRunning":7,"hostCpus":4,"hostMemoryBytes":8589934592}'
report="$(drift "$(build_run cpus "${stable_host}" "${changed_cpus}")")"
jq -e '.materialChange == true and (.findings | join(" ") | test("CPU allocation changed"))' "${report}" >/dev/null \
  || fail "the CPU allocation halved mid-run and was not reported: $(jq -c '{verdict,findings}' "${report}")"

# --- a changed memory envelope too ------------------------------------------
changed_mem='{"capturedAt":"t","phase":"after","loadAverage":{"1m":2.0},"dockerContainersRunning":7,"hostCpus":8,"hostMemoryBytes":4294967296}'
report="$(drift "$(build_run mem "${stable_host}" "${changed_mem}")")"
jq -e '.materialChange == true and (.findings | join(" ") | test("memory allocation changed"))' "${report}" >/dev/null \
  || fail "the memory envelope halved and was not reported"

# --- external load is the proxy this host offers for thermal/power state ----
loaded='{"capturedAt":"t","phase":"after","loadAverage":{"1m":10.0},"dockerContainersRunning":7,"hostCpus":8,"hostMemoryBytes":8589934592}'
report="$(drift "$(build_run load "${stable_host}" "${loaded}")")"
jq -e '.materialChange == true and (.findings | join(" ") | test("load changed"))' "${report}" >/dev/null \
  || fail "the host gained 8 units of load per 8 cores and it was not reported"

# Small load movement is normal and must NOT be flagged, or the signal becomes
# noise and gets ignored the first time it matters.
jittered='{"capturedAt":"t","phase":"after","loadAverage":{"1m":2.9},"dockerContainersRunning":7,"hostCpus":8,"hostMemoryBytes":8589934592}'
report="$(drift "$(build_run jitter "${stable_host}" "${jittered}")")"
jq -e '.verdict == "stable"' "${report}" >/dev/null \
  || fail "ordinary load jitter was reported as material change: $(jq -c .findings "${report}")"

# --- a restarted or extra container ----------------------------------------
extra='{"capturedAt":"t","phase":"after","loadAverage":{"1m":2.0},"dockerContainersRunning":12,"hostCpus":8,"hostMemoryBytes":8589934592}'
report="$(drift "$(build_run containers "${stable_host}" "${extra}")")"
jq -e '.materialChange == true and (.findings | join(" ") | test("container count changed"))' "${report}" >/dev/null \
  || fail "five extra containers appeared on the host and it was not reported"

# --- too few boundaries is "cannot judge", not "stable" ---------------------
single="${test_root}/single"
mkdir -p "${single}/environment/only"
printf '%s\n' "${stable_host}" > "${single}/environment/only/host.json"
report="$(drift "${single}")"
jq -e '.captureState == "missing" and .materialChange == null' "${report}" >/dev/null \
  || fail "one boundary was judged as stable; absence of evidence was read as evidence of stability"

echo "environment drift detection tests passed"
