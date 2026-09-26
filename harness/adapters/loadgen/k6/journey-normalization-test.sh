#!/usr/bin/env bash
# k6 journey and arrival-model normalization.
#
# Acceptance cases 5, 6, 8, 33 and 34. All four are about the SAME risk: a journey
# is a parent iteration made of several wire requests, and conflating the two
# makes throughput and error rate wrong in opposite directions.
#
#   6  parent and request counts must stay separate -- reporting wire requests
#      as journeys inflates throughput by the amplification factor
#   5  a failed middle operation fails the JOURNEY without corrupting the
#      request counts that were genuinely issued before it
#   8  open arrival must report journey starts/s and the derived amplification,
#      not just requests/s
#  34  arrival-rate runs must record dropped iterations and VU state, because a
#      generator that could not keep up did not deliver the offered load
#
# The k6 binary is stubbed and a crafted summary is fed to the REAL parser, so
# the arithmetic under test is the shipping normalization.
set -euo pipefail

adapter_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "${adapter_dir}/../../../.." && pwd)"
test_root="$(mktemp -d "${TMPDIR:-/tmp}/k6-journey-test.XXXXXX")"
trap '[[ "${PERFLAB_TEST_KEEP:-0}" == "1" ]] && echo "fixture kept at ${test_root}" >&2 || rm -rf "${test_root}"' EXIT HUP INT TERM
fail() { echo "k6-journey-normalization-test: $*" >&2; exit 1; }
command -v jq >/dev/null || fail "jq is required"

mkdir -p "${test_root}/bin"
# jqd() runs jq in a container; run the local binary instead.
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

# k6 writes the summary the harness then parses. The fixture IS the contract
# between k6 and the adapter.
cat > "${test_root}/bin/k6" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
# The adapter fingerprints the generator before it runs; a stub that cannot
# answer `version` fails the compatibility envelope, not the parser under test.
if [[ "${1:-}" == "version" ]]; then
  echo "k6 v0.0.0-fixture"
  exit 0
fi
export_path=""
previous=""
for arg in "$@"; do
  [[ "${previous}" == "--summary-export" ]] && export_path="${arg}"
  previous="${arg}"
done
[[ -n "${export_path}" ]] && cp "${PERFLAB_TEST_SUMMARY}" "${export_path}"
exit "${PERFLAB_TEST_K6_EXIT:-0}"
EOF
chmod +x "${test_root}/bin/k6"

# A journey run: 100 parents, each issuing 4 wire requests, of which 12 failed
# mid-journey. 9 journeys therefore failed while their earlier requests still
# count as issued.
cat > "${test_root}/journey-summary.json" <<'EOF'
{"metrics":{
  "journey_starts":{"count":100,"rate":10.0},
  "journey_completed":{"count":91},
  "journey_failed":{"count":9},
  "journey_aborted":{"count":0},
  "journey_child_ops":{"count":400},
  "journey_wire_requests":{"count":407,"rate":40.7},
  "journey_retries":{"count":7},
  "journey_status_errors":{"count":12},
  "journey_transport_errors":{"count":0},
  "journey_wire_latency":{"p(50)":11.0,"p(90)":30.0,"p(95)":41.0,"p(99)":77.0},
  "journey_duration":{"p(95)":410.0},
  "dropped_iterations":{"count":37},
  "vus":{"value":48,"max":64},
  "iteration_duration":{"p(95)":410.0},
  "http_reqs":{"count":407,"rate":40.7},
  "http_req_duration":{"p(50)":11.0,"p(90)":30.0,"p(95)":41.0,"p(99)":77.0}
}}
EOF

artifact="${test_root}/pkg"
mkdir -p "${artifact}/benchmark"
PATH="${test_root}/bin:${PATH}" \
PERFLAB_CONFIG="${repo}/labs/scenariolab/lab.config.sh" \
PERFLAB_TEST_SUMMARY="${test_root}/journey-summary.json" \
PERF_WORKLOAD_KIND=journey \
PERF_SCENARIO=S01 PERF_RUN_ID=run-journey \
PERFLAB_DURATION_SECONDS=10 \
PERFLAB_CONNECTIONS=64 \
PERF_METHOD=GET PERF_PATH=/api/journey PERF_BODY= \
PERF_BASE_URL=http://127.0.0.1:8080 \
PERFLAB_K6_PROM_RW=0 \
  bash "${adapter_dir}/run.sh" "${artifact}" measure > "${test_root}/run.out" 2>&1 \
  || fail "the k6 adapter failed on a journey summary: $(tail -5 "${test_root}/run.out")"

obs="${artifact}/benchmark/observations.json"
[[ -s "${obs}" ]] || fail "no observations were written"
value() { jq -r --arg n "$1" '(if type=="array" then . else .observations end)[] | select(.name==$n) | .value' < "${obs}"; }

# --- case 6: parent and request counts stay separate ------------------------
[[ "$(value journey.starts)" == "100" ]] \
  || fail "journey.starts=$(value journey.starts), want 100 parents"
[[ "$(value journey.wire_requests)" == "407" ]] \
  || fail "journey.wire_requests=$(value journey.wire_requests), want 407 (400 operations + 7 retries)"
[[ "$(value journey.starts)" != "$(value journey.wire_requests)" ]] \
  || fail "parent and wire-request counts are the same number; the two are conflated"

# --- case 8: amplification is derived, not assumed --------------------------
amplification="$(value journey.request_amplification)"
awk -v a="${amplification}" 'BEGIN { exit (a > 4.06 && a < 4.08) ? 0 : 1 }' \
  || fail "journey.request_amplification=${amplification}, want 4.07 (407 wire requests / 100 journeys)"
# Throughput must describe WIRE requests; reporting journeys here would
# understate load by the amplification factor, and vice versa.
[[ "$(value http.requests.total)" == "407" ]] \
  || fail "http.requests.total=$(value http.requests.total), want the 407 wire requests including retries"

# --- case 5: a failed middle operation fails the journey, not the counts -----
[[ "$(value journey.failed)" == "9" ]] \
  || fail "journey.failed=$(value journey.failed), want 9"
[[ "$(value journey.completed)" == "91" ]] \
  || fail "journey.completed=$(value journey.completed), want 91"
completed="$(value journey.completed)"; failed="$(value journey.failed)"
[[ "$((completed + failed))" == "100" ]] \
  || fail "completed + failed = $((completed + failed)), which does not reconcile with 100 starts"
# The requests issued before the failure are still real traffic and must not be
# discarded: erasing them would understate the load the system actually served.
[[ "$(value journey.wire_requests)" == "407" ]] \
  || fail "wire requests were altered by the journey failures"

# --- case 34: dropped iterations and VU state -------------------------------
[[ "$(value http.dropped_iterations)" == "37" ]] \
  || fail "http.dropped_iterations=$(value http.dropped_iterations), want 37; a generator that could not keep up did not deliver the offered load"

# A journey run must not silently report zero retries when the generator saw
# some: retries change the request count without changing the journey count.
[[ "$(value journey.retries)" == "7" ]] \
  || fail "journey.retries=$(value journey.retries), want 7"

# --- case 33: logical operations are not wire requests ----------------------
# A journey step is a LOGICAL operation; it may cost several wire requests once
# retries, redirects and embedded resources are counted. Reporting either number
# as the other makes throughput wrong in a direction nobody can see: per-request
# latency averaged over retries looks better than it is, and per-operation
# throughput counted in wire requests looks higher than it is.
[[ "$(value journey.child_ops)" == "400" ]] \
  || fail "journey.child_ops=$(value journey.child_ops), want 400 logical operations"
# The three counts are distinct measurements and must not be collapsed onto one
# another. Retries in particular inflate wire requests without adding operations.
retries="$(value journey.retries)"
[[ "${retries}" != "$(value journey.starts)" ]] \
  || fail "retries and journey starts report the same number; retries are not being counted separately"
# Wire requests must account for retries: 400 wire requests including 7 retries
# means the workload issued more calls than it has logical operations to show.
# EXACT accounting, not an inequality: wire requests must equal logical
# operations plus retries. `wire >= operations` passed while every retry was
# dropped from the wire count, which is the loss it was meant to catch.
awk -v w="$(value journey.wire_requests)" -v o="$(value journey.child_ops)" -v r="${retries}" \
  'BEGIN { exit (w == o + r) ? 0 : 1 }' \
  || fail "wire requests ($(value journey.wire_requests)) != operations ($(value journey.child_ops)) + retries (${retries}); retries are being lost from the wire count"
# Latency must be the WIRE latency, not the journey duration: a p99 taken over
# whole journeys describes a different population than one over requests.
awk -v v="$(value http.latency.p99)" 'BEGIN { exit (v == 77) ? 0 : 1 }' \
  || fail "http.latency.p99=$(value http.latency.p99), want the wire p99 of 77, not the journey duration"
awk -v v="$(value journey.duration.p95)" 'BEGIN { exit (v == 410) ? 0 : 1 }' \
  || fail "journey.duration.p95=$(value journey.duration.p95), want the journey p95 of 410 kept separate from wire latency"

# Expected protocol backpressure is still a non-success HTTP outcome. A k6
# threshold failure must preserve the same normalized evidence and its exit.
cat > "${test_root}/backpressure-summary.json" <<'EOF'
{"metrics":{"iterations":{"count":10,"rate":1},"http_reqs":{"count":10,"rate":1},"http_req_failed":{"value":0},"protocol_failures":{"count":0},"perflab_http_non_2xx_3xx":{"count":9},"perflab_http_transport_errors":{"count":1},"iteration_duration":{"p(50)":1,"p(90)":2,"p(95)":3,"p(99)":4}}}
EOF
failed_pkg="${test_root}/failed-threshold"
rc=0
PATH="${test_root}/bin:${PATH}" PERFLAB_CONFIG="${repo}/labs/scenariolab/lab.config.sh" PERFLAB_TEST_SUMMARY="${test_root}/backpressure-summary.json" PERFLAB_TEST_K6_EXIT=99 PERF_WORKLOAD_KIND=protocol PERF_SCENARIO=P04 PERF_RUN_ID=run-backpressure PERFLAB_DURATION_SECONDS=10 PERFLAB_CONNECTIONS=1 PERF_METHOD=POST PERF_PATH=/messages PERF_BASE_URL=http://127.0.0.1:8080 PERFLAB_K6_PROM_RW=0   bash "${adapter_dir}/run.sh" "${failed_pkg}" measure > "${test_root}/failed-threshold.out" 2>&1 || rc=$?
[[ "${rc}" == 99 ]] || fail "failed k6 threshold lost its exit status: ${rc}"
obs="${failed_pkg}/benchmark/observations.json"
[[ "$(value http.responses.non_2xx_3xx)" == 9 ]] || fail "expected backpressure disappeared from HTTP outcomes"
[[ "$(value http.transport_errors)" == 1 ]] || fail "transport failure disappeared from HTTP outcomes"
[[ "$(value http.error_rate)" == 1 ]] || fail "failed threshold did not preserve normalized error rate"
[[ -s "${failed_pkg}/benchmark/compatibility.json" ]] || fail "failed threshold lost its compatibility envelope"

cat > "${test_root}/browser-summary.json" <<'EOF'
{"metrics":{"iterations":{"count":10,"rate":1},"iteration_duration":{"p(95)":1200},"browser_http_req_duration":{"p(50)":2,"p(90)":3,"p(95)":4,"p(99)":5},"browser_http_req_failed":{"passes":3,"fails":27},"checks":{"fails":1}}}
EOF
browser_pkg="${test_root}/browser"
PATH="${test_root}/bin:${PATH}" PERFLAB_CONFIG="${repo}/labs/scenariolab/lab.config.sh" PERFLAB_TEST_SUMMARY="${test_root}/browser-summary.json" PERF_WORKLOAD_KIND=protocol PERF_PROTOCOL=browser-synthetic PERF_SCENARIO=P10 PERF_RUN_ID=run-browser PERFLAB_DURATION_SECONDS=10 PERFLAB_CONNECTIONS=1 PERF_METHOD=GET PERF_PATH=/ PERF_BASE_URL=http://127.0.0.1:8080 PERFLAB_K6_PROM_RW=0 bash "${adapter_dir}/run.sh" "${browser_pkg}" measure > "${test_root}/browser.out" 2>&1 || fail "browser parser failed"
obs="${browser_pkg}/benchmark/observations.json"
[[ -z "$(value http.requests.total)" ]] || fail "browser visits leaked into backend requests"
[[ "$(value browser.visits.total)" == 10 ]] || fail "browser visits lost"
[[ "$(value browser.http.requests.total)" == 30 ]] || fail "browser subrequests confused with visits"
[[ "$(value browser.http.requests_per_second)" == 3 ]] || fail "browser request rate denominator wrong"
[[ "$(value browser.http.error_rate)" == 0.1 ]] || fail "browser error ratio denominator wrong"
[[ "$(value browser.visit.duration.p95)" == 1200 ]] || fail "visit latency confused with subrequest latency"
[[ "$(value browser.http.latency.p95)" == 4 ]] || fail "browser subrequest latency lost"
[[ "$(value browser.checks.failed)" == 1 ]] || fail "browser correctness failure lost"
echo "k6 journey, protocol and browser normalization tests passed"
