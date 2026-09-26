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
  '  if [[ "${1:-}" == "del(.setup_data)" ]]; then jq "$@"; return; fi' \
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
  'printf "{\"metrics\":{},\"setup_data\":{\"token\":\"eyJfixture.bearer.token\"}}\n" > "${summary}"' \
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
# k6 exports setup()'s return value; ecommerce's setup() returns its login token,
# which must not survive into the package (acceptance case 26).
if grep -q 'eyJfixture' "${test_root}/measure/benchmark/k6-summary.json"; then
  echo "the measured k6 summary kept setup_data (a bearer token)" >&2
  exit 1
fi
jq -e 'has("metrics") and (has("setup_data") | not)' "${test_root}/measure/benchmark/k6-summary.json" >/dev/null \
  || { echo "stripping setup_data damaged the k6 summary" >&2; exit 1; }
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

# The workload identity covers the modules the script imports: a change to an
# imported mix.js changed what ran while the entry script's hash stayed put.
printf "import { pick } from './lib.js';\nexport default function () { pick(); }\n" > "${test_root}/workload/k6.js"
printf 'export function pick() { return 1; }\n' > "${test_root}/workload/lib.js"
run_phase import-a measure
printf 'export function pick() { return 2; }\n' > "${test_root}/workload/lib.js"
run_phase import-b measure
hash_a="$(sed -n 's/.*"workloadContentHash":"\([a-f0-9]*\)".*/\1/p' "${test_root}/import-a/benchmark/compatibility.json")"
hash_b="$(sed -n 's/.*"workloadContentHash":"\([a-f0-9]*\)".*/\1/p' "${test_root}/import-b/benchmark/compatibility.json")"
[[ -n "${hash_a}" && "${hash_a}" != "${hash_b}" ]] \
  || { echo "a change to an imported module kept the workload hash (${hash_a})" >&2; exit 1; }
printf 'export default function () {}\n' > "${test_root}/workload/k6.js"

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

# k6 Rate summaries count true values in `passes` and false values in `fails`.
# Browser request failure normalization must therefore count `passes`; using
# `fails` would invert a healthy browser run into an error rate above 100%.
# `fails` may only add to the browser request total (passes + fails).
grep -q 'browser_http_req_failed.passes' "${adapter_dir}/run.sh"
if grep 'browser_http_req_failed.fails' "${adapter_dir}/run.sh" | grep -vq 'as \$browser_requests'; then
  echo "browser failure normalization uses k6 false samples" >&2
  exit 1
fi

# Request workloads must exclude setup/teardown traffic when a project-owned
# primary-request counter and latency trend are available.
grep -q 'perflab_primary_requests.count' "${adapter_dir}/run.sh"
grep -q 'perflab_primary_request_latency' "${adapter_dir}/run.sh"

echo "k6 load adapter compatibility tests passed"
