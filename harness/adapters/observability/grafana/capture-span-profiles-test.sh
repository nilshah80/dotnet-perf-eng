#!/usr/bin/env bash
# D-P1-3: span-to-profile evidence. The ids come from the captured traces'
# pyroscope.profile.id attributes, the query names exactly those spans for this
# run's service, and every outcome -- samples, none, unreachable, profiling off
# -- is recorded as its own state without failing the package.
set -euo pipefail

adapter_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
test_root="$(mktemp -d)"
trap 'rm -rf "${test_root}"' EXIT
fail() { echo "capture-span-profiles-test: $*" >&2; exit 1; }
command -v jq >/dev/null || fail "jq is required"

json_escape() { local s="$1"; s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; printf '%s' "${s}"; }
# The host jq, with the same CR and MSYS guards common.sh's jqd applies.
jqd() { MSYS_NO_PATHCONV=1 jq "$@" | tr -d '\r'; return "${PIPESTATUS[0]}"; }
# shellcheck disable=SC1091
source "${adapter_dir}/capture-profiles.sh"
# shellcheck disable=SC1091
source "${adapter_dir}/capture-span-profiles.sh"

# Fake curl: records the request body, answers like Pyroscope's Connect API.
mkdir -p "${test_root}/bin"
cat > "${test_root}/bin/curl" <<'CURL'
#!/usr/bin/env bash
out=""; data=""; url=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    --data) data="$2"; shift 2 ;;
    -w|-H|--max-time) shift 2 ;;
    http*) url="$1"; shift ;;
    *) shift ;;
  esac
done
printf '%s %s\n' "${url}" "${data}" >> "${SPAN_TEST_CALLS}"
case "${SPAN_TEST_MODE}" in
  samples) printf '{"flamegraph":{"names":["total","Checkout"],"levels":[{"values":["0","42","0","1"]}],"total":"42","maxSelf":"42"}}' > "${out}"; printf 200 ;;
  none) printf '{"flamegraph":{"names":["total"],"levels":[],"total":"0"}}' > "${out}"; printf 200 ;;
  down) exit 7 ;;
esac
CURL
chmod +x "${test_root}/bin/curl"
export PATH="${test_root}/bin:${PATH}" SPAN_TEST_CALLS="${test_root}/calls"

trace() { # <file> <service> <profile-id-or-empty>
  local attrs='[{"key":"http.route","value":{"stringValue":"/orders"}}]'
  [[ -n "$3" ]] && attrs="$(jq -cn --arg id "$3" '[{"key":"http.route","value":{"stringValue":"/orders"}},{"key":"pyroscope.profile.id","value":{"stringValue":$id}}]')"
  jq -cn --arg svc "$2" --argjson attrs "${attrs}" \
    '{batches:[{resource:{attributes:[{key:"service.name",value:{stringValue:$svc}}]},scopeSpans:[{spans:[{name:"GET /orders",attributes:$attrs},{name:"db",attributes:[]}]}]}]}' > "$1"
}

package() { # <name> -> artifact dir with two traces
  local dir="${test_root}/$1"
  mkdir -p "${dir}/telemetry/traces/details"
  trace "${dir}/telemetry/traces/details/a.json" perflab-api 00f067aa0ba902b7
  trace "${dir}/telemetry/traces/details/b.json" perflab-api 53995c3f42cd8ad8
  printf '%s' "${dir}"
}

continuous_profiling=1; capture_telemetry=1; target_mode=local
pyroscope_url=http://pyroscope:4040; telemetry_run_id=run-9; start_epoch=1800000000; end_epoch=1800000060

artifact_dir="$(package captured)"; SPAN_TEST_MODE=samples; export SPAN_TEST_MODE
pyroscope_capture_span_profiles
result="${artifact_dir}/telemetry/profiles/span-profiles.json"
jq -e '.captureState == "captured" and .tracesExamined == 2 and .spansWithProfileId == 2
       and .services[0].service == "perflab-api" and .services[0].spanIds == 2 and .services[0].totalSamples == 42' "${result}" >/dev/null \
  || fail "tagged spans with samples were not captured: $(cat "${result}")"
request="$(grep -o '{.*}' "${SPAN_TEST_CALLS}" | tail -1)"
grep -q 'querier.v1.QuerierService/SelectMergeSpanProfile' "${SPAN_TEST_CALLS}" || fail "the span-profile API was not queried"
jq -e '.spanSelector == ["00f067aa0ba902b7","53995c3f42cd8ad8"] and .labelSelector == "{service_name=\"perflab-api\",perf_run_id=\"run-9\"}"
       and .profileTypeID == "process_cpu:cpu:nanoseconds:cpu:nanoseconds"' <<< "${request}" >/dev/null \
  || fail "the query did not name exactly the tagged spans of this run's service: ${request}"
[[ -s "${artifact_dir}/telemetry/profiles/span-perflab-api-cpu.json" ]] || fail "the span flame graph was not kept"

artifact_dir="$(package empty)"; SPAN_TEST_MODE=none
pyroscope_capture_span_profiles
jq -e '.captureState == "missing" and .services[0].captureState == "empty"' "${artifact_dir}/telemetry/profiles/span-profiles.json" >/dev/null \
  || fail "a reachable Pyroscope with no samples was not reported as missing"

artifact_dir="$(package down)"; SPAN_TEST_MODE=down
pyroscope_capture_span_profiles
jq -e '.captureState == "failed" and (.reason | test("unreachable"))' "${artifact_dir}/telemetry/profiles/span-profiles.json" >/dev/null \
  || fail "an unreachable Pyroscope was not reported as failed"

# Traces without the attribute: the listener was not active. Nothing is queried.
artifact_dir="${test_root}/untagged"; mkdir -p "${artifact_dir}/telemetry/traces/details"
trace "${artifact_dir}/telemetry/traces/details/a.json" perflab-api ""
: > "${SPAN_TEST_CALLS}"
pyroscope_capture_span_profiles
jq -e '.captureState == "missing" and .spansWithProfileId == 0' "${artifact_dir}/telemetry/profiles/span-profiles.json" >/dev/null \
  || fail "untagged traces were not reported as missing"
[[ ! -s "${SPAN_TEST_CALLS}" ]] || fail "untagged traces still queried Pyroscope"

continuous_profiling=0; artifact_dir="$(package off)"
pyroscope_capture_span_profiles
jq -e '.captureState == "not-applicable"' "${artifact_dir}/telemetry/profiles/span-profiles.json" >/dev/null \
  || fail "a run without continuous profiling was not not-applicable"

echo "span profile capture tests passed"
