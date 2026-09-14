#!/usr/bin/env bash
set -euo pipefail

adapter_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf "${test_root}"' EXIT
mkdir -p "${test_root}/harness/core/lib" "${test_root}/bin" "${test_root}/workload"
printf 'export default function () {}\n' > "${test_root}/workload/k6.js"

printf '%s\n' \
  'load_generator=k6' \
  'loadgen_script() { printf "%s" "${PERFLAB_TEST_SCRIPT}"; }' \
  'relative_to_repo() { printf "labs/fixture/loadgen/k6.js"; }' \
  'json_escape() { local s="$1"; s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; printf "%s" "${s}"; }' \
  'jqd() {' \
  '  if [[ "${1:-}" == "-e" ]]; then local data; data="$(cat)"; [[ "${data}" == *\"metrics\"* ]] && return 0; [[ "${data}" =~ \"http.latency.p95\",\"value\":-?[0-9] ]]; return; fi' \
  '  local value=12.5; [[ "${PERFLAB_TEST_NULL_P95:-0}" == "1" ]] && value=null' \
  '  cat >/dev/null; printf "[{\"name\":\"http.latency.p95\",\"value\":%s,\"unit\":\"ms\",\"source\":\"benchmark/k6-summary.json\"}]\n" "${value}"' \
  '}' \
  > "${test_root}/harness/core/lib/common.sh"

printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'if [[ "${1:-}" == "version" ]]; then printf "k6 v1.2.3 fixture\n"; exit 0; fi' \
  'summary=""; while [[ $# -gt 0 ]]; do if [[ "$1" == "--summary-export" ]]; then summary="$2"; shift 2; else shift; fi; done' \
  '[[ -n "${summary}" ]] || exit 2' \
  'printf "{\"metrics\":{}}\n" > "${summary}"' \
  'printf "fixture run\n"' \
  > "${test_root}/bin/k6"
chmod +x "${test_root}/bin/k6"

run_phase() {
  local output_name="$1" phase="${2:-$1}" output rc=0
  output="${test_root}/${output_name}"
  mkdir -p "${output}"
  PATH="${test_root}/bin:${PATH}" \
  PERFLAB_HARNESS_ROOT="${test_root}/harness" \
  PERFLAB_TEST_SCRIPT="${test_root}/workload/k6.js" \
  PERFLAB_TEST_NULL_P95="${PERFLAB_TEST_NULL_P95:-0}" \
  PERFLAB_K6_PROM_RW=0 PERFLAB_CONNECTIONS=4 PERFLAB_DURATION_SECONDS=1 \
  PERFLAB_PROFILE=steady PERF_SCENARIO=S07 PERF_BASE_URL=http://127.0.0.1:8080/v1/ \
  PERF_METHOD=GET PERF_PATH=/orders PERF_BODY='' \
    bash "${adapter_dir}/run.sh" "${output}" "${phase}" || rc=$?
  (( rc == 0 )) || return "${rc}"
  [[ -s "${output}/benchmark/compatibility.json" ]]
  grep -q '"generatorFingerprint":"k6 v1.2.3 fixture"' "${output}/benchmark/compatibility.json"
  grep -Eq '"workloadContentHash":"[a-f0-9]{64}"' "${output}/benchmark/compatibility.json"
}

run_phase measure
grep -q '"http.latency.p95"' "${test_root}/measure/benchmark/observations.json"
run_phase diagnostic
[[ ! -e "${test_root}/diagnostic/benchmark/observations.json" ]]

# A real measure must fail closed if normalization cannot produce numeric p95.
if PERFLAB_TEST_NULL_P95=1 run_phase missing-p95 measure 2>/dev/null; then
  echo "measure unexpectedly accepted a missing p95" >&2
  exit 1
fi

measure_hash="$(sed -n 's/.*"workloadContentHash":"\([a-f0-9]*\)".*/\1/p' "${test_root}/measure/benchmark/compatibility.json")"
diagnostic_hash="$(sed -n 's/.*"workloadContentHash":"\([a-f0-9]*\)".*/\1/p' "${test_root}/diagnostic/benchmark/compatibility.json")"
[[ -n "${measure_hash}" && "${measure_hash}" == "${diagnostic_hash}" ]]

# A diagnostic replay inside a MEASURED package must leave the measured envelope
# byte-identical (capture-runtime's mutation guard hashes it) and publish its
# own beside it.
cp -R "${test_root}/measure" "${test_root}/measured-package"
before="$(shasum -a 256 "${test_root}/measured-package/benchmark/compatibility.json" | awk '{print $1}')"
PATH="${test_root}/bin:${PATH}" PERFLAB_HARNESS_ROOT="${test_root}/harness" PERFLAB_TEST_SCRIPT="${test_root}/workload/k6.js" \
  PERFLAB_K6_PROM_RW=0 PERFLAB_CONNECTIONS=4 PERFLAB_DURATION_SECONDS=1 PERFLAB_PROFILE=steady \
  PERF_SCENARIO=S07 PERF_BASE_URL=http://127.0.0.1:8080/v1/ PERF_METHOD=GET PERF_PATH=/orders PERF_BODY='' \
  bash "${adapter_dir}/run.sh" "${test_root}/measured-package" diagnostic
after="$(shasum -a 256 "${test_root}/measured-package/benchmark/compatibility.json" | awk '{print $1}')"
[[ "${before}" == "${after}" ]] || { echo "diagnostic replay mutated the measured compatibility envelope" >&2; exit 1; }
[[ -s "${test_root}/measured-package/benchmark/diagnostic-compatibility.json" ]] || { echo "diagnostic replay did not publish its own envelope" >&2; exit 1; }

echo "k6 load adapter compatibility tests passed"
