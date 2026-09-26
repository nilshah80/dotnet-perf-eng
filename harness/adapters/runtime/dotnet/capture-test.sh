#!/usr/bin/env bash
set -euo pipefail
command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }

adapter_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The cancelled-capture cases need a SIGINT the capture can trap.
# shellcheck source=/dev/null
. "${adapter_dir}/../../../core/lib/sigint-reset.sh"
reset_inherited_sigint "$@"
test_root="$(mktemp -d)"
trap 'rm -rf "${test_root}"' EXIT
mkdir -p "${test_root}/harness/core/lib" "${test_root}/bin"

cat > "${test_root}/harness/core/lib/common.sh" <<'EOF'
# The on-CPU trace report needs a real Speedscope file; diff-speedscope-test.sh
# covers it, so the stubbed conversions here skip it.
perflab_python() { return 1; }
load_generator=k6
diagnostics_url=http://monitor
artifacts_root="${PERFLAB_TEST_ARTIFACTS_ROOT:-}"
diag_target() { printf 'Fixture.Api'; }
# Mirrors common.sh: a local role mapped in PERFLAB_DIAG_ENDPOINTS gets its own
# monitor; everything else uses the shared diagnostics URL.
diag_endpoint() {
  local svc="$1" pair
  for pair in ${PERFLAB_DIAG_ENDPOINTS:-}; do
    if [[ "${pair%%=*}" == "${svc}" ]]; then printf '%s' "${pair#*=}"; return 0; fi
  done
  printf '%s' "${diagnostics_url}"
}
# Delegates to the host jq so the selector under test is the real one, but it
# must keep BOTH guards common.sh's jqd applies. jq.exe writes CRLF on Windows,
# so a value read through a bare override carries a trailing CR that corrupts
# every later comparison and URL built from it; and MSYS rewrites any argument
# that looks like a POSIX path, so `--arg path /stacks` reaches jq.exe as
# C:/Program Files/Git/stacks and the lookup silently misses.
jqd() { MSYS_NO_PATHCONV=1 jq "$@" | tr -d '\r'; return "${PIPESTATUS[0]}"; }
json_escape() { local s="$1"; s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; printf '%s' "${s}"; }
# The real helper, verbatim: the counters state file is a TSV record read
# through it, and a fixture without it left every counters capture unread.
read_fields() {
  local expected="${1:?read_fields <expected-count>}" line
  TSV_FIELDS=()
  while IFS= read -r line; do
    TSV_FIELDS+=("${line}")
  done
  if [[ "${#TSV_FIELDS[@]}" -ne "${expected}" ]]; then
    echo "Expected ${expected} fields, received ${#TSV_FIELDS[@]}; refusing to continue with a misaligned record." >&2
    return 1
  fi
  return 0
}
loadgen_warmup() { mkdir -p "$1"; printf 'warmup\n' >> "${PERFLAB_TEST_CALLS}"; printf '{}' > "$1/warmup.json"; }
loadgen_measure() { mkdir -p "$1"; printf 'diagnostic\n' >> "${PERFLAB_TEST_CALLS}"; [[ -z "${PERFLAB_TEST_SLOW_LOAD:-}" ]] || sleep "${PERFLAB_TEST_SLOW_LOAD}"; printf '{}' > "$1/diagnostic.json"; }
# Record every request that reaches the authenticated wrapper. A monitor call
# that bypasses it (bare curl) would carry no Authorization, CA or client
# certificate on a protected monitor, and this log is how the test sees it.
monitor_curl() { printf 'monitor_curl:%s\n' "${*: -1}" >> "${PERFLAB_TEST_CALLS}"; curl "$@"; }
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
    if [[ "${PERFLAB_TEST_FAIL_EXTENDED_SOS:-0}" == '1' && " $* " == *' dumpasync '* ]]; then return 1; fi
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
  */stacks)
    if [[ -n "${PERFLAB_TEST_STACKS_FAIL_ONCE:-}" && ! -e "${PERFLAB_TEST_STACKS_FAIL_ONCE}" ]]; then
      # S03: an intermittent HTTP 500 with an empty body.
      : > "${PERFLAB_TEST_STACKS_FAIL_ONCE}"
      headers=''; previous=''
      for argument in "$@"; do [[ "${previous}" == '-D' ]] && headers="${argument}"; previous="${argument}"; done
      [[ -n "${headers}" ]] && printf 'HTTP/1.1 500 Internal Server Error\r\n\r\n' > "${headers}"
    elif [[ "${PERFLAB_TEST_STACKS_PROBLEM:-0}" == "1" ]]; then
      # dotnet-monitor answers a failed operation with HTTP 500 and ProblemDetails.
      headers=''; previous=''
      for argument in "$@"; do [[ "${previous}" == '-D' ]] && headers="${argument}"; previous="${argument}"; done
      [[ -n "${headers}" ]] && printf 'HTTP/1.1 500 Internal Server Error\r\n\r\n' > "${headers}"
      printf '{"title":"Unable to collect call stacks","detail":"profiler is not loaded"}'
    else
      printf 'Thread: (0x1)\n  Fixture.Api!Program.Main\n'
    fi ;;
  */dump) printf 'dump' ;;
  */livemetrics)
    # RFC 7464 json-seq: an ASCII RS before every record. Written to the -o
    # target like the real endpoint, because capture_counters parses the file.
    out=''; previous=''
    for argument in "$@"; do [[ "${previous}" == '-o' ]] && out="${argument}"; previous="${argument}"; done
    body=$'\x1e{"name":"cpu-usage","value":1.5}\n\x1e{"name":"working-set","value":42}\n'
    if [[ -n "${out}" ]]; then printf '%s' "${body}" > "${out}"; else printf '%s' "${body}"; fi
    for argument in "$@"; do [[ "${argument}" == '-w' ]] && { printf '200'; break; }; done ;;
  *) exit 22 ;;
esac
EOF
chmod +x "${test_root}/bin/curl"
# No real container is consulted: a failed fetch looks up the monitor's container
# for its log, and the fixture has none.
printf '#!/usr/bin/env bash\nexit 0\n' > "${test_root}/bin/docker"
chmod +x "${test_root}/bin/docker"

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
# Runtime counters must reach the monitor through monitor_curl, the only path
# that presents the Authorization header, CA and client certificate. The bare
# curl this replaced looked healthy on an unauthenticated lab and silently
# lost the signal on every protected monitor.
grep -q '^monitor_curl:.*/livemetrics' "${test_root}/captured-calls" \
  || { echo 'captured: /livemetrics was not requested through monitor_curl' >&2; exit 1; }
# A campaign trace stage records the counters it captured alongside its
# nettrace; presets used to skip counters entirely.
grep -q '"counters":{"captureState":"captured","reason":"","records":2,' \
  "${test_root}/captured/runtime/captures/trace/capture.json" \
  || { echo 'captured: campaign trace stage did not record parsed counters' >&2; exit 1; }

# Single-kind trace: the same counters path, the same wrapper, the same record.
trace_kind_output="${test_root}/trace-kind"
mkdir -p "${trace_kind_output}"; : > "${test_root}/trace-kind-calls"
PATH="${test_root}/bin:${PATH}" \
PERFLAB_HARNESS_ROOT="${test_root}/harness" \
PERFLAB_TEST_CALLS="${test_root}/trace-kind-calls" \
PERFLAB_TEST_GCDUMP_COUNT="${test_root}/trace-kind-gcdumps" \
PERFLAB_DIAGNOSTIC_RECOVERY_SECONDS=0 \
PERFLAB_DIAGNOSTIC_ARTIFACT_BUDGET_BYTES=67108864 \
PERF_SCENARIO=S07 PERF_RUN_ID=run-source \
  bash "${adapter_dir}/capture.sh" "${trace_kind_output}" trace 1 api >/dev/null 2>&1
[[ -s "${trace_kind_output}/runtime/api/cpu.nettrace" ]]
grep -q '^monitor_curl:.*/livemetrics' "${test_root}/trace-kind-calls" \
  || { echo 'trace-kind: /livemetrics was not requested through monitor_curl' >&2; exit 1; }
grep -q '"counters":{"captureState":"captured","reason":"","records":2,' \
  "${trace_kind_output}/runtime/capture.json" \
  || { echo 'trace-kind: json-seq counter records were not parsed as captured' >&2; exit 1; }
[[ -s "${trace_kind_output}/runtime/api/counters.json-seq" ]] \
  || { echo 'trace-kind: counters.json-seq was not retained' >&2; exit 1; }
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

# A local target is recreated in diagnose mode, so a dump must follow the
# scenario's load or it shows a fresh, idle process (S04's retained arrays were
# absent). Only a remote target, never recreated, is dumped without traffic. The
# acknowledgement belongs to the core command that invokes this adapter, so the
# adapter test verifies only its execution contract.
dump_output="${test_root}/dump-only"
mkdir -p "${dump_output}"; : > "${test_root}/dump-only-calls"
PATH="${test_root}/bin:${PATH}" \
PERFLAB_HARNESS_ROOT="${test_root}/harness" \
PERFLAB_TEST_CALLS="${test_root}/dump-only-calls" \
PERFLAB_TEST_GCDUMP_COUNT="${test_root}/dump-only-gcdumps" \
PERFLAB_DIAGNOSTIC_RECOVERY_SECONDS=0 \
PERFLAB_DIAGNOSTIC_ARTIFACT_BUDGET_BYTES=67108864 \
PERFLAB_DIAGNOSTIC_INCLUDE_DUMP=0 \
PERFLAB_TEST_ARTIFACTS_ROOT="${test_root}" \
PERF_SCENARIO=S07 PERF_RUN_ID=run-source \
  bash "${adapter_dir}/capture.sh" "${dump_output}" preset:dump 1 api >/dev/null 2>&1
# A process dump is process memory -- connection strings and tokens included --
# and a package is what gets shared (acceptance case 26). The dump leaves the
# package for the owner-only sensitive store; the package keeps a pointer with
# its hash, and the capture record names the pointer.
[[ ! -e "${dump_output}/runtime/captures/dump/process.dmp" ]] \
  || { echo 'dump-only: the process dump stayed in the evidence package' >&2; exit 1; }
dump_pointer="${dump_output}/runtime/captures/dump/process.dmp.retained.json"
retained_dump="${test_root}/sensitive/dump-only/runtime/captures/dump/process.dmp"
[[ -s "${retained_dump}" ]] || { echo 'dump-only: the dump was not retained in the sensitive store' >&2; exit 1; }
jq -e --arg sha "$(shasum -a 256 "${retained_dump}" | awk '{print $1}')" \
  '.exportable == false and .retainedPath == "sensitive/dump-only/runtime/captures/dump/process.dmp" and .sha256 == $sha and (.retainUntil | length > 0)' \
  "${dump_pointer}" >/dev/null || { echo 'dump-only: the retention pointer is wrong' >&2; cat "${dump_pointer}" >&2; exit 1; }
if [[ "$(uname -s)" != MINGW* && "$(uname -s)" != MSYS* ]]; then
  [[ "$(ls -l "${retained_dump}" | cut -c1-10)" == "-rw-------" ]] \
    || { echo 'dump-only: the retained dump is readable by others' >&2; exit 1; }
fi
grep -q '"artifactPaths":\["runtime/captures/dump/process.dmp.retained.json"\]' "${dump_output}/runtime/captures/dump/capture.json" \
  || { echo 'dump-only: the capture record does not name the retention pointer' >&2; exit 1; }
# Locally: warm-up, then the diagnostic load, then the dump.
grep -q '^warmup$' "${test_root}/dump-only-calls" || { echo 'dump-only: a local dump did not warm up' >&2; exit 1; }
load_line="$(grep -n '^diagnostic$' "${test_root}/dump-only-calls" | head -1 | cut -d: -f1)"
dump_line="$(grep -n '^monitor_curl:.*/dump' "${test_root}/dump-only-calls" | head -1 | cut -d: -f1)"
[[ -n "${load_line}" && -n "${dump_line}" && "${load_line}" -lt "${dump_line}" ]] \
  || { echo 'dump-only: a local dump was not taken after the diagnostic load' >&2; cat "${test_root}/dump-only-calls" >&2; exit 1; }
grep -q '"diagnosticLoadState":"captured"' "${dump_output}/runtime/campaign.json" \
  || { echo 'dump-only: the local dump did not record its diagnostic load' >&2; exit 1; }
# Remotely: the process already holds its state; no warm-up, no traffic.
remote_dump_output="${test_root}/dump-remote"
mkdir -p "${remote_dump_output}"; : > "${test_root}/dump-remote-calls"
PATH="${test_root}/bin:${PATH}" \
PERFLAB_HARNESS_ROOT="${test_root}/harness" \
PERFLAB_TEST_CALLS="${test_root}/dump-remote-calls" \
PERFLAB_TEST_GCDUMP_COUNT="${test_root}/dump-remote-gcdumps" \
PERFLAB_DIAGNOSTIC_RECOVERY_SECONDS=0 \
PERFLAB_DIAGNOSTIC_ARTIFACT_BUDGET_BYTES=67108864 \
PERFLAB_TEST_ARTIFACTS_ROOT="${test_root}" \
target_mode=remote PERFLAB_CAMPAIGN_DUMP_ONLY=1 \
PERF_SCENARIO=S07 PERF_RUN_ID=run-source \
  bash "${adapter_dir}/capture.sh" "${remote_dump_output}" preset:dump 1 api >/dev/null 2>&1
! grep -q '^warmup$\|^diagnostic$' "${test_root}/dump-remote-calls" \
  || { echo 'dump-remote: a remote dump drove traffic' >&2; exit 1; }
grep -q '"diagnosticLoadState":"not-applicable"' "${remote_dump_output}/runtime/campaign.json" \
  || { echo 'dump-remote: the remote dump recorded a diagnostic load' >&2; exit 1; }

# A single-kind dump has no per-stage normalization record. When the extended
# SOS commands fail, the thread and heap listing must survive, the retained
# report must say what failed, and the package metadata must carry it -- the
# reason used to be handed to a writer that returned without writing.
dump_kind_output="${test_root}/dump-kind"
mkdir -p "${dump_kind_output}"; : > "${test_root}/dump-kind-calls"
PATH="${test_root}/bin:${PATH}" \
PERFLAB_HARNESS_ROOT="${test_root}/harness" \
PERFLAB_TEST_CALLS="${test_root}/dump-kind-calls" \
PERFLAB_TEST_GCDUMP_COUNT="${test_root}/dump-kind-gcdumps" \
PERFLAB_DIAGNOSTIC_RECOVERY_SECONDS=0 \
PERFLAB_DIAGNOSTIC_ARTIFACT_BUDGET_BYTES=67108864 \
PERFLAB_TEST_ARTIFACTS_ROOT="${test_root}/dump-kind" \
PERF_SCENARIO=S07 PERF_RUN_ID=run-source \
  bash "${adapter_dir}/capture.sh" "${dump_kind_output}" dump 1 api >/dev/null 2>&1
[[ ! -e "${dump_kind_output}/runtime/api/process.dmp" && -s "${dump_kind_output}/runtime/api/process.dmp.retained.json" ]] \
  || { echo 'dump-kind: the process dump stayed in the evidence package' >&2; exit 1; }
[[ -s "${dump_kind_output}/sensitive/runtime/api/process.dmp" ]]
PERFLAB_HARNESS_ROOT="${test_root}/harness" \
PERFLAB_TEST_ARTIFACTS_ROOT="${test_root}/dump-kind" \
PERFLAB_TEST_FAIL_EXTENDED_SOS=1 \
  bash "${adapter_dir}/normalize.sh" "${test_root}/dump-kind" >/dev/null 2>&1 \
  || { echo 'dump-kind: an extended SOS failure must not fail normalization' >&2; exit 1; }
dump_report="$(find "${dump_kind_output}/analysis/runtime" -name '*-dump-report.txt' | head -1)"
[[ -n "${dump_report}" ]] && grep -q '^dump report' "${dump_report}" \
  || { echo 'dump-kind: the thread and heap listing was not retained' >&2; exit 1; }
grep -q 'FAILED: extended SOS commands' "${dump_report}" \
  || { echo 'dump-kind: the retained report does not say the extended commands failed' >&2; exit 1; }
grep -q 'extended SOS commands (dumpasync, syncblk, analyzeoom) failed' "${dump_kind_output}/runtime/normalization-limitations.json" \
  || { echo 'dump-kind: the package metadata does not carry the extended SOS failure' >&2; exit 1; }
# And the same normalization with the extended commands succeeding leaves no stale note.
PERFLAB_HARNESS_ROOT="${test_root}/harness" \
PERFLAB_TEST_ARTIFACTS_ROOT="${test_root}/dump-kind" \
  bash "${adapter_dir}/normalize.sh" "${test_root}/dump-kind" >/dev/null 2>&1
[[ ! -e "${dump_kind_output}/runtime/normalization-limitations.json" ]] \
  || { echo 'dump-kind: a stale limitations file survived a clean normalization' >&2; exit 1; }
grep -q '=== extended SOS: dumpasync, syncblk, analyzeoom ===' "${dump_report}" \
  || { echo 'dump-kind: the extended SOS output was not appended to the report' >&2; exit 1; }

# A package captured before dumps left packages still holds its dump. Normalize
# analyses it in place and then retains it, so the package stops carrying the
# credential the dump holds.
legacy_output="${test_root}/legacy-dump"
mkdir -p "${legacy_output}/runtime/api"
printf 'Host=db;Password=perflab;\n' > "${legacy_output}/runtime/api/process.dmp"
PERFLAB_HARNESS_ROOT="${test_root}/harness" \
PERFLAB_TEST_ARTIFACTS_ROOT="${legacy_output}" \
  bash "${adapter_dir}/normalize.sh" "${legacy_output}" >/dev/null 2>&1 \
  || { echo 'legacy-dump: normalization failed' >&2; exit 1; }
find "${legacy_output}/analysis/runtime" -name 'process-dump-report.txt' | grep -q . \
  || { echo 'legacy-dump: the in-package dump was not analysed' >&2; exit 1; }
[[ -s "${legacy_output}/runtime/api/process.dmp.retained.json" && -s "${legacy_output}/sensitive/runtime/api/process.dmp" ]] \
  || { echo 'legacy-dump: the analysed dump was not retained' >&2; exit 1; }
if grep -ral 'Password=perflab' "${legacy_output}/runtime" "${legacy_output}/analysis" >/dev/null 2>&1; then
  echo 'legacy-dump: the package still carries the credential' >&2; exit 1
fi

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

# A failed monitor request keeps its status and ProblemDetails (F13): curl -f used
# to discard the body, and a /stacks 500 was recorded only as "request failed".
problem_output="${test_root}/stacks-problem"
mkdir -p "${problem_output}"; : > "${test_root}/stacks-problem-calls"
if PATH="${test_root}/bin:${PATH}" \
  PERFLAB_HARNESS_ROOT="${test_root}/harness" \
  PERFLAB_TEST_CALLS="${test_root}/stacks-problem-calls" \
  PERFLAB_TEST_GCDUMP_COUNT="${test_root}/stacks-problem-gcdumps" \
  PERFLAB_ENABLE_DOTNET_MONITOR_STACKS=true PERFLAB_TEST_STACKS_PROBLEM=1 \
  PERF_SCENARIO=S07 PERF_RUN_ID=run-source \
  bash "${adapter_dir}/capture.sh" "${problem_output}" stacks 1 api >/dev/null 2> "${test_root}/stacks-problem.err"; then
  echo 'stacks-problem: a monitor HTTP 500 was accepted' >&2; exit 1
fi
grep -q 'HTTP 500: Unable to collect call stacks: profiler is not loaded' "${test_root}/stacks-problem.err" \
  || { echo "stacks-problem: the failure lost dotnet-monitor's ProblemDetails: $(cat "${test_root}/stacks-problem.err")" >&2; exit 1; }
[[ ! -e "${problem_output}/runtime/api/stacks.txt" ]] \
  || { echo 'stacks-problem: the error body was kept as stacks.txt' >&2; exit 1; }
# /stacks is read-only, so a server error is retried before the capture fails.
[[ "$(grep -c 'monitor_curl:.*/stacks' "${test_root}/stacks-problem-calls")" == 3 ]] \
  || { echo "stacks-problem: a persistent 500 was not retried three times: $(cat "${test_root}/stacks-problem-calls")" >&2; exit 1; }

# S03: one empty HTTP 500, then the stacks: the capture succeeds.
flaky_output="${test_root}/stacks-flaky"
mkdir -p "${flaky_output}"; : > "${test_root}/stacks-flaky-calls"
PATH="${test_root}/bin:${PATH}" \
  PERFLAB_HARNESS_ROOT="${test_root}/harness" \
  PERFLAB_TEST_CALLS="${test_root}/stacks-flaky-calls" \
  PERFLAB_TEST_GCDUMP_COUNT="${test_root}/stacks-flaky-gcdumps" \
  PERFLAB_ENABLE_DOTNET_MONITOR_STACKS=true PERFLAB_TEST_STACKS_FAIL_ONCE="${test_root}/stacks-flaky-failed" \
  PERF_SCENARIO=S03 PERF_RUN_ID=run-source \
  bash "${adapter_dir}/capture.sh" "${flaky_output}" stacks 1 api >/dev/null 2> "${test_root}/stacks-flaky.err" \
  || { echo "stacks-flaky: a transient 500 failed the capture: $(cat "${test_root}/stacks-flaky.err")" >&2; exit 1; }
grep -q 'Fixture.Api!Program.Main' "${flaky_output}/runtime/api/stacks.txt" \
  || { echo 'stacks-flaky: the retried stacks were not kept' >&2; exit 1; }
! grep -q 'No such file' "${test_root}/stacks-flaky.err" \
  || { echo "stacks-flaky: the empty error body was read as a file: $(cat "${test_root}/stacks-flaky.err")" >&2; exit 1; }

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

# A signal during the diagnostic load must end the capture. The old trap only
# stopped the load and carried on: it pulled the after-snapshot from a load it
# had just killed, recorded the campaign as captured and exited 0. The capture
# runs as a job with its own process group and is signalled like a terminal job.
for signal in INT TERM; do
  cancelled="${test_root}/cancelled-${signal}"
  mkdir -p "${cancelled}"; : > "${cancelled}-calls"
  set -m
  PATH="${test_root}/bin:${PATH}" \
  PERFLAB_HARNESS_ROOT="${test_root}/harness" \
  PERFLAB_TEST_CALLS="${cancelled}-calls" \
  PERFLAB_TEST_GCDUMP_COUNT="${cancelled}-gcdumps" \
  PERFLAB_TEST_SLOW_LOAD=30 \
  PERFLAB_DIAGNOSTIC_RECOVERY_SECONDS=0 \
  PERFLAB_DIAGNOSTIC_ARTIFACT_BUDGET_BYTES=67108864 \
  PERFLAB_DIAGNOSTIC_INCLUDE_DUMP=0 \
  PERF_SCENARIO=S07 PERF_RUN_ID=run-source \
    bash "${adapter_dir}/capture.sh" "${cancelled}" preset:memory 1 api </dev/null >/dev/null 2>&1 &
  capture_pid=$!
  set +m
  for _ in $(seq 1 100); do
    grep -q '^diagnostic$' "${cancelled}-calls" && break
    sleep 0.1
  done
  if ! grep -q '^diagnostic$' "${cancelled}-calls"; then
    kill -KILL -- "-${capture_pid}" 2>/dev/null || true
    echo "cancelled-${signal}: the diagnostic load never started" >&2; exit 1
  fi
  kill -"${signal}" -- "-${capture_pid}"
  capture_rc=0
  wait "${capture_pid}" || capture_rc=$?
  expected_rc=130
  [[ "${signal}" == INT ]] || expected_rc=143
  [[ "${capture_rc}" == "${expected_rc}" ]] \
    || { echo "cancelled-${signal}: exit ${capture_rc}, want ${expected_rc}" >&2; exit 1; }
  [[ "$(cat "${cancelled}-gcdumps")" == 1 ]] \
    || { echo "cancelled-${signal}: the capture pulled another snapshot after the signal" >&2; exit 1; }
done

echo "dotnet runtime campaign adapter tests passed"
