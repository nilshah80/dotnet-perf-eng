#!/usr/bin/env bash
set -euo pipefail
command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }

adapter_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf "${test_root}"' EXIT
mkdir -p "${test_root}/harness/core/lib" "${test_root}/bin"

cat > "${test_root}/harness/core/lib/common.sh" <<'EOF'
load_generator=k6
diagnostics_url=http://monitor
artifacts_root="${PERFLAB_TEST_ARTIFACTS_ROOT:-}"
diag_target() { printf 'Fixture.Api'; }
# Delegates to the host jq so the selector under test is the real one, but it
# must keep BOTH guards common.sh's jqd applies. jq.exe writes CRLF on Windows,
# so a value read through a bare override carries a trailing CR that corrupts
# every later comparison and URL built from it; and MSYS rewrites any argument
# that looks like a POSIX path, so `--arg path /stacks` reaches jq.exe as
# C:/Program Files/Git/stacks and the lookup silently misses.
jqd() { MSYS_NO_PATHCONV=1 jq "$@" | tr -d '\r'; return "${PIPESTATUS[0]}"; }
json_escape() { local s="$1"; s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; printf '%s' "${s}"; }
loadgen_warmup() { mkdir -p "$1"; printf 'warmup\n' >> "${PERFLAB_TEST_CALLS}"; printf '{}' > "$1/warmup.json"; }
loadgen_measure() { mkdir -p "$1"; printf 'diagnostic\n' >> "${PERFLAB_TEST_CALLS}"; printf '{}' > "$1/diagnostic.json"; }
monitor_curl() { curl "$@"; }
compose() {
  local previous='' argument output=''
  for argument in "$@"; do [[ "${previous}" == '--output' ]] && output="${argument}"; previous="${argument}"; done
  if [[ " $* " == *' dotnet-trace convert '* ]]; then
    mkdir -p "$(dirname "${PERFLAB_TEST_ARTIFACTS_ROOT}${output#/artifacts}")"
    printf '{}' > "${PERFLAB_TEST_ARTIFACTS_ROOT}${output#/artifacts}.speedscope.json"
  elif [[ " $* " == *' dotnet-gcdump report '* ]]; then
    if [[ "${PERFLAB_TEST_FAIL_BEFORE_NORMALIZATION:-0}" == '1' && "$*" == *before.gcdump* ]]; then return 1; fi
    if [[ "${PERFLAB_TEST_UNKNOWN_GCDUMP_TYPES:-0}" == '1' ]]; then
      printf '24 4 UNKNOWN 0x000000000001\n32 2 UNKNOWN 0x000000000002\n'
    elif [[ "${PERFLAB_TEST_PARTIAL_UNKNOWN_GCDUMP_TYPES:-0}" == '1' ]]; then
      for number in {1..19}; do printf '24 4 UNKNOWN 0x%012x\n' "${number}"; done
      printf '32 2 System.String\n'
    elif [[ "${PERFLAB_TEST_UNKNOWN_GCDUMP_BYTES:-0}" == '1' ]]; then
      for number in {1..19}; do printf '1 1 Example.Type%u\n' "${number}"; done
      printf '1000000 1 UNKNOWN 0x000000000001\n'
    else
      printf '24 4 System.String\n'
    fi
  elif [[ " $* " == *' dotnet-dump analyze '* ]]; then
    printf 'dump report\n'
  fi
}
EOF
mkdir -p "${test_root}/harness/adapters/runtime/dotnet"
cp "${adapter_dir}/capability.sh" "${test_root}/harness/adapters/runtime/dotnet/capability.sh"

cat > "${test_root}/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
url="${*: -1}"
case "${url}" in
  */info) printf '{"version":"10.0","runtimeVersion":"10.0","diagnosticPortMode":"Listen","diagnosticPortName":"/diag/monitor.sock","capabilities":[{"name":"call_stacks","enabled":true}]}' ;;
  */) printf '{"paths":{"/trace":{"get":{}},"/gcdump":{"get":{}},"/dump":{"get":{}},"/stacks":{"get":{}}}}' ;;
  */processes) printf '[{"uid":"fixture-uid","pid":4242,"name":"Fixture.Api","managedEntryPointAssemblyName":"Fixture.Api"}]' ;;
  */process) printf '{"uid":"fixture-uid","pid":4242,"name":"Fixture.Api","managedEntryPointAssemblyName":"Fixture.Api","commandLine":"dotnet Fixture.Api.dll","operatingSystem":"Linux","processArchitecture":"arm64"}' ;;
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

cp -R "${test_root}/captured" "${test_root}/normalization-unknown-types"
find "${test_root}/normalization-unknown-types" -name normalization.json -delete
set +e
PERFLAB_HARNESS_ROOT="${test_root}/harness" \
PERFLAB_TEST_ARTIFACTS_ROOT="${test_root}/normalization-unknown-types" \
PERFLAB_TEST_UNKNOWN_GCDUMP_TYPES=1 \
  bash "${adapter_dir}/normalize.sh" "${test_root}/normalization-unknown-types" >/dev/null 2>&1
unknown_types_rc=$?
set -e
[[ "${unknown_types_rc}" == 2 ]]
grep -q '"status":"failed"' "${test_root}/normalization-unknown-types/runtime/captures/gcdump-before/normalization.json"
grep -q 'type metadata is unavailable' "${test_root}/normalization-unknown-types/runtime/captures/gcdump-before/normalization.json"
[[ ! -e "${test_root}/normalization-unknown-types/runtime/captures/gcdump-before/report.txt" ]]

cp -R "${test_root}/captured" "${test_root}/normalization-partial-unknown-types"
find "${test_root}/normalization-partial-unknown-types" -name normalization.json -delete
set +e
PERFLAB_HARNESS_ROOT="${test_root}/harness" \
PERFLAB_TEST_ARTIFACTS_ROOT="${test_root}/normalization-partial-unknown-types" \
PERFLAB_TEST_PARTIAL_UNKNOWN_GCDUMP_TYPES=1 \
  bash "${adapter_dir}/normalize.sh" "${test_root}/normalization-partial-unknown-types" >/dev/null 2>&1
partial_unknown_types_rc=$?
set -e
[[ "${partial_unknown_types_rc}" == 2 ]]
grep -q '"status":"failed"' "${test_root}/normalization-partial-unknown-types/runtime/captures/gcdump-before/normalization.json"
grep -q 'type metadata is unavailable' "${test_root}/normalization-partial-unknown-types/runtime/captures/gcdump-before/normalization.json"
[[ ! -e "${test_root}/normalization-partial-unknown-types/runtime/captures/gcdump-before/report.txt" ]]

cp -R "${test_root}/captured" "${test_root}/normalization-unknown-type-bytes"
find "${test_root}/normalization-unknown-type-bytes" -name normalization.json -delete
set +e
PERFLAB_HARNESS_ROOT="${test_root}/harness" \
PERFLAB_TEST_ARTIFACTS_ROOT="${test_root}/normalization-unknown-type-bytes" \
PERFLAB_TEST_UNKNOWN_GCDUMP_BYTES=1 \
  bash "${adapter_dir}/normalize.sh" "${test_root}/normalization-unknown-type-bytes" >/dev/null 2>&1
unknown_type_bytes_rc=$?
set -e
[[ "${unknown_type_bytes_rc}" == 2 ]]
grep -q '"status":"failed"' "${test_root}/normalization-unknown-type-bytes/runtime/captures/gcdump-before/normalization.json"
grep -q 'type metadata is unavailable' "${test_root}/normalization-unknown-type-bytes/runtime/captures/gcdump-before/normalization.json"
[[ ! -e "${test_root}/normalization-unknown-type-bytes/runtime/captures/gcdump-before/report.txt" ]]

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
grep -q 'Call stacks contain type and method names' \
  "${direct_stacks_output}/runtime/capture.json"

conflict_stacks_output="${test_root}/conflict-stacks"
mkdir -p "${conflict_stacks_output}"; : > "${test_root}/conflict-stacks-calls"
PATH="${test_root}/bin:${PATH}" \
PERFLAB_HARNESS_ROOT="${test_root}/harness" \
PERFLAB_TEST_CALLS="${test_root}/conflict-stacks-calls" \
PERFLAB_TEST_GCDUMP_COUNT="${test_root}/conflict-stacks-gcdumps" \
PERFLAB_ENABLE_DOTNET_MONITOR_STACKS=true \
PERFLAB_CONTINUOUS_PROFILING=1 \
PERF_SCENARIO=S07 PERF_RUN_ID=run-source \
  bash "${adapter_dir}/capture.sh" "${conflict_stacks_output}" stacks 1 api >/dev/null 2>&1
[[ -s "${conflict_stacks_output}/runtime/api/cpu.nettrace" ]]
[[ ! -e "${conflict_stacks_output}/runtime/api/stacks.txt" ]]
grep -q '"requestedDiagnostic":"stacks","effectiveDiagnostic":"trace"' \
  "${conflict_stacks_output}/runtime/capture.json"
grep -q 'cannot share ICorProfiler with Pyroscope' \
  "${conflict_stacks_output}/runtime/capture.json"

forced_fallback_output="${test_root}/forced-stacks-fallback"
mkdir -p "${forced_fallback_output}"; : > "${test_root}/forced-stacks-fallback-calls"
PATH="${test_root}/bin:${PATH}" \
PERFLAB_HARNESS_ROOT="${test_root}/harness" \
PERFLAB_TEST_CALLS="${test_root}/forced-stacks-fallback-calls" \
PERFLAB_TEST_GCDUMP_COUNT="${test_root}/forced-stacks-fallback-gcdumps" \
PERFLAB_ENABLE_DOTNET_MONITOR_STACKS=true \
PERFLAB_CONTINUOUS_PROFILING=0 \
PERFLAB_STACKS_FORCE_TRACE=1 \
PERF_SCENARIO=S07 PERF_RUN_ID=run-source \
  bash "${adapter_dir}/capture.sh" "${forced_fallback_output}" stacks 1 api >/dev/null 2>&1
[[ -s "${forced_fallback_output}/runtime/api/cpu.nettrace" ]]
[[ ! -e "${forced_fallback_output}/runtime/api/stacks.txt" ]]
grep -q 'dotnet-monitor /stacks is not reliable after continuous profiling' \
  "${forced_fallback_output}/runtime/capture.json"

hang_stacks_output="${test_root}/hang-stacks"
mkdir -p "${hang_stacks_output}"; : > "${test_root}/hang-stacks-calls"
PATH="${test_root}/bin:${PATH}" \
PERFLAB_HARNESS_ROOT="${test_root}/harness" \
PERFLAB_TEST_CALLS="${test_root}/hang-stacks-calls" \
PERFLAB_TEST_GCDUMP_COUNT="${test_root}/hang-stacks-gcdumps" \
PERFLAB_ENABLE_DOTNET_MONITOR_STACKS=true \
PERFLAB_CONTINUOUS_PROFILING=0 \
PERFLAB_DIAGNOSTIC_RECOVERY_SECONDS=0 \
PERFLAB_DIAGNOSTIC_ARTIFACT_BUDGET_BYTES=67108864 \
PERFLAB_DIAGNOSTIC_INCLUDE_DUMP=0 \
PERF_SCENARIO=S07 PERF_RUN_ID=run-source \
  bash "${adapter_dir}/capture.sh" "${hang_stacks_output}" preset:hang 1 api >/dev/null 2>&1
[[ -s "${hang_stacks_output}/runtime/captures/trace/cpu.nettrace" ]]
[[ -s "${hang_stacks_output}/runtime/captures/stacks/stacks.txt" ]]

hostile_remote="${test_root}/hostile-remote"
mkdir -p "${hostile_remote}"; : > "${test_root}/hostile-remote-calls"
PATH="${test_root}/bin:${PATH}" \
PERFLAB_HARNESS_ROOT="${test_root}/harness" \
PERFLAB_TEST_CALLS="${test_root}/hostile-remote-calls" \
PERFLAB_TEST_GCDUMP_COUNT="${test_root}/hostile-remote-gcdumps" \
PERFLAB_ENABLE_DOTNET_MONITOR_STACKS=true \
target_mode=remote \
PERF_SCENARIO=S07 PERF_RUN_ID=run-source \
  bash "${adapter_dir}/capture.sh" "${hostile_remote}" stacks 1 api >/dev/null 2>&1
[[ -s "${hostile_remote}/runtime/api/cpu.nettrace" ]]
[[ ! -e "${hostile_remote}/runtime/api/stacks.txt" ]]
grep -q '"requestedDiagnostic":"stacks","effectiveDiagnostic":"trace"' \
  "${hostile_remote}/runtime/capture.json"
grep -q 'remote or attach-only' "${hostile_remote}/runtime/capture.json"

hostile_attach="${test_root}/hostile-attach"
mkdir -p "${hostile_attach}"; : > "${test_root}/hostile-attach-calls"
PATH="${test_root}/bin:${PATH}" \
PERFLAB_HARNESS_ROOT="${test_root}/harness" \
PERFLAB_TEST_CALLS="${test_root}/hostile-attach-calls" \
PERFLAB_TEST_GCDUMP_COUNT="${test_root}/hostile-attach-gcdumps" \
PERFLAB_ENABLE_DOTNET_MONITOR_STACKS=true \
PERFLAB_TARGET_KIND=existing-process \
PERF_SCENARIO=S07 PERF_RUN_ID=run-source \
  bash "${adapter_dir}/capture.sh" "${hostile_attach}" stacks 1 api >/dev/null 2>&1
[[ -s "${hostile_attach}/runtime/api/cpu.nettrace" ]]
[[ ! -e "${hostile_attach}/runtime/api/stacks.txt" ]]
grep -q 'remote or attach-only' "${hostile_attach}/runtime/capture.json"

hostile_hang="${test_root}/hostile-hang"
mkdir -p "${hostile_hang}"; : > "${test_root}/hostile-hang-calls"
PATH="${test_root}/bin:${PATH}" \
PERFLAB_HARNESS_ROOT="${test_root}/harness" \
PERFLAB_TEST_CALLS="${test_root}/hostile-hang-calls" \
PERFLAB_TEST_GCDUMP_COUNT="${test_root}/hostile-hang-gcdumps" \
PERFLAB_ENABLE_DOTNET_MONITOR_STACKS=true \
PERFLAB_CONTINUOUS_PROFILING=0 \
PERFLAB_DIAGNOSTIC_RECOVERY_SECONDS=0 \
PERFLAB_DIAGNOSTIC_ARTIFACT_BUDGET_BYTES=67108864 \
PERFLAB_DIAGNOSTIC_INCLUDE_DUMP=0 \
target_mode=remote \
PERF_SCENARIO=S07 PERF_RUN_ID=run-source \
  bash "${adapter_dir}/capture.sh" "${hostile_hang}" preset:hang 1 api >/dev/null 2>&1
[[ -s "${hostile_hang}/runtime/captures/trace/cpu.nettrace" ]]
[[ ! -e "${hostile_hang}/runtime/captures/stacks/stacks.txt" ]]

echo "dotnet runtime campaign adapter tests passed"
