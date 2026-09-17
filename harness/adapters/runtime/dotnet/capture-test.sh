#!/usr/bin/env bash
set -euo pipefail

adapter_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf "${test_root}"' EXIT
mkdir -p "${test_root}/harness/core/lib" "${test_root}/bin"

cat > "${test_root}/harness/core/lib/common.sh" <<'EOF'
load_generator=k6
diagnostics_url=http://monitor
artifacts_root="${PERFLAB_TEST_ARTIFACTS_ROOT:-}"
diag_target() { printf 'Fixture.Api'; }
jqd() { cat >/dev/null; printf 'fixture-uid\n'; }
json_escape() { local s="$1"; s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; printf '%s' "${s}"; }
loadgen_warmup() { mkdir -p "$1"; printf 'warmup\n' >> "${PERFLAB_TEST_CALLS}"; printf '{}' > "$1/warmup.json"; }
loadgen_measure() { mkdir -p "$1"; printf 'diagnostic\n' >> "${PERFLAB_TEST_CALLS}"; printf '{}' > "$1/diagnostic.json"; }
compose() {
  local previous='' argument output=''
  for argument in "$@"; do [[ "${previous}" == '--output' ]] && output="${argument}"; previous="${argument}"; done
  if [[ " $* " == *' dotnet-trace convert '* ]]; then
    mkdir -p "$(dirname "${PERFLAB_TEST_ARTIFACTS_ROOT}${output#/artifacts}")"
    printf '{}' > "${PERFLAB_TEST_ARTIFACTS_ROOT}${output#/artifacts}.speedscope.json"
  elif [[ " $* " == *' dotnet-gcdump report '* ]]; then
    if [[ "${PERFLAB_TEST_FAIL_BEFORE_NORMALIZATION:-0}" == '1' && "$*" == *before.gcdump* ]]; then return 1; fi
    printf 'gcdump report\n'
  elif [[ " $* " == *' dotnet-dump analyze '* ]]; then
    printf 'dump report\n'
  fi
}
EOF

cat > "${test_root}/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
url="${*: -1}"
case "${url}" in
  */processes) printf '[{"uid":"fixture-uid","managedEntryPointAssemblyName":"Fixture.Api"}]' ;;
  */gcdump)
    count=0; [[ -f "${PERFLAB_TEST_GCDUMP_COUNT}" ]] && count="$(cat "${PERFLAB_TEST_GCDUMP_COUNT}")"
    count=$((count + 1)); printf '%s' "${count}" > "${PERFLAB_TEST_GCDUMP_COUNT}"
    if [[ "${PERFLAB_TEST_FAIL_FIRST_GCDUMP:-0}" == "1" && "${count}" == "1" ]]; then exit 22; fi
    printf 'gcdump-%s' "${count}" ;;
  */trace) printf 'nettrace' ;;
  */stacks) printf 'Thread: (0x1)\n  Fixture.Api!Program.Main\n' ;;
  */dump) printf 'dump' ;;
  *) exit 22 ;;
esac
EOF
chmod +x "${test_root}/bin/curl"

run_case() {
  local name="$1" fail_before="$2" expected_rc="$3" output
  output="${test_root}/${name}"
  mkdir -p "${output}"
  : > "${test_root}/${name}-calls"
  rm -f "${test_root}/${name}-gcdumps"
  set +e
  PATH="${test_root}/bin:${PATH}" \
  PERFLAB_HARNESS_ROOT="${test_root}/harness" \
  PERFLAB_TEST_CALLS="${test_root}/${name}-calls" \
  PERFLAB_TEST_GCDUMP_COUNT="${test_root}/${name}-gcdumps" \
  PERFLAB_TEST_FAIL_FIRST_GCDUMP="${fail_before}" \
  PERFLAB_DIAGNOSTIC_RECOVERY_SECONDS=0 \
  PERFLAB_DIAGNOSTIC_ARTIFACT_BUDGET_BYTES=67108864 \
  PERFLAB_DIAGNOSTIC_INCLUDE_DUMP=0 \
  PERF_SCENARIO=S07 PERF_RUN_ID=run-source \
    bash "${adapter_dir}/capture.sh" "${output}" preset:cpu-memory 1 api >/dev/null 2>&1
  rc=$?
  set -e
  [[ "${rc}" == "${expected_rc}" ]] || { echo "${name}: exit ${rc}, want ${expected_rc}" >&2; exit 1; }
  [[ -s "${output}/runtime/campaign.json" && -s "${output}/runtime/captures/trace/cpu.nettrace" && -s "${output}/runtime/captures/gcdump-after/after.gcdump" ]]
  [[ "$(grep -c '^warmup$' "${test_root}/${name}-calls")" == 1 ]]
  [[ "$(grep -c '^diagnostic$' "${test_root}/${name}-calls")" == 1 ]]
}

run_case captured 0 0
grep -q '"status":"captured"' "${test_root}/captured/runtime/campaign.json"
grep -q '"sequence":1' "${test_root}/captured/runtime/captures/gcdump-before/capture.json"
grep -q '"sequence":2' "${test_root}/captured/runtime/captures/trace/capture.json"
grep -q '"sequence":3' "${test_root}/captured/runtime/captures/gcdump-after/capture.json"
PERFLAB_HARNESS_ROOT="${test_root}/harness" \
PERFLAB_TEST_ARTIFACTS_ROOT="${test_root}/captured" \
  bash "${adapter_dir}/normalize.sh" "${test_root}/captured" >/dev/null
grep -q '"status":"captured"' "${test_root}/captured/runtime/captures/trace/normalization.json"
grep -q 'cpu.speedscope.json' "${test_root}/captured/runtime/captures/trace/normalization.json"
grep -q '"status":"captured"' "${test_root}/captured/runtime/captures/gcdump-after/normalization.json"

cp -R "${test_root}/captured" "${test_root}/normalization-partial"
find "${test_root}/normalization-partial" -name normalization.json -delete
set +e
PERFLAB_HARNESS_ROOT="${test_root}/harness" \
PERFLAB_TEST_ARTIFACTS_ROOT="${test_root}/normalization-partial" \
PERFLAB_TEST_FAIL_BEFORE_NORMALIZATION=1 \
  bash "${adapter_dir}/normalize.sh" "${test_root}/normalization-partial" >/dev/null 2>&1
normalization_rc=$?
set -e
[[ "${normalization_rc}" == 2 ]]
grep -q '"status":"partial"' "${test_root}/normalization-partial/runtime/captures/gcdump-before/normalization.json"
grep -q '"status":"captured"' "${test_root}/normalization-partial/runtime/captures/trace/normalization.json"
grep -q '"status":"captured"' "${test_root}/normalization-partial/runtime/captures/gcdump-after/normalization.json"

run_case partial 1 2
grep -q '"status":"partial"' "${test_root}/partial/runtime/campaign.json"
grep -q '"captureState":"failed"' "${test_root}/partial/runtime/captures/gcdump-before/capture.json"
grep -q '"captureState":"captured"' "${test_root}/partial/runtime/captures/trace/capture.json"

# dump is intentionally a process snapshot only: no warm-up and no diagnostic
# traffic. The acknowledgement belongs to the core command that invokes this
# adapter, so the adapter test verifies only its execution contract.
dump_output="${test_root}/dump-only"
mkdir -p "${dump_output}"; : > "${test_root}/dump-only-calls"
PATH="${test_root}/bin:${PATH}" \
PERFLAB_HARNESS_ROOT="${test_root}/harness" \
PERFLAB_TEST_CALLS="${test_root}/dump-only-calls" \
PERFLAB_TEST_GCDUMP_COUNT="${test_root}/dump-only-gcdumps" \
PERFLAB_DIAGNOSTIC_RECOVERY_SECONDS=0 \
PERFLAB_DIAGNOSTIC_ARTIFACT_BUDGET_BYTES=67108864 \
PERFLAB_DIAGNOSTIC_INCLUDE_DUMP=0 \
PERF_SCENARIO=S07 PERF_RUN_ID=run-source \
  bash "${adapter_dir}/capture.sh" "${dump_output}" preset:dump 1 api >/dev/null 2>&1
[[ -s "${dump_output}/runtime/captures/dump/process.dmp" ]]
[[ ! -s "${test_root}/dump-only-calls" ]]
grep -q '"diagnosticLoadState":"not-applicable"' "${dump_output}/runtime/campaign.json"

stacks_output="${test_root}/stacks-only"
mkdir -p "${stacks_output}"; : > "${test_root}/stacks-only-calls"
PATH="${test_root}/bin:${PATH}" \
PERFLAB_HARNESS_ROOT="${test_root}/harness" \
PERFLAB_TEST_CALLS="${test_root}/stacks-only-calls" \
PERFLAB_TEST_GCDUMP_COUNT="${test_root}/stacks-only-gcdumps" \
PERF_SCENARIO=S07 PERF_RUN_ID=run-source \
  bash "${adapter_dir}/capture.sh" "${stacks_output}" stacks 1 api >/dev/null 2>&1
[[ -s "${stacks_output}/runtime/api/cpu.nettrace" ]]
grep -q '"requestedDiagnostic":"stacks","effectiveDiagnostic":"trace"' \
  "${stacks_output}/runtime/capture.json"

direct_stacks_output="${test_root}/direct-stacks"
mkdir -p "${direct_stacks_output}"; : > "${test_root}/direct-stacks-calls"
PATH="${test_root}/bin:${PATH}" \
PERFLAB_HARNESS_ROOT="${test_root}/harness" \
PERFLAB_TEST_CALLS="${test_root}/direct-stacks-calls" \
PERFLAB_TEST_GCDUMP_COUNT="${test_root}/direct-stacks-gcdumps" \
PERFLAB_ENABLE_DOTNET_MONITOR_STACKS=true \
PERF_SCENARIO=S07 PERF_RUN_ID=run-source \
  bash "${adapter_dir}/capture.sh" "${direct_stacks_output}" stacks 1 api >/dev/null 2>&1
[[ -s "${direct_stacks_output}/runtime/api/stacks.txt" ]]
grep -q '"requestedDiagnostic":"stacks","effectiveDiagnostic":"stacks"' \
  "${direct_stacks_output}/runtime/capture.json"

echo "dotnet runtime campaign adapter tests passed"
