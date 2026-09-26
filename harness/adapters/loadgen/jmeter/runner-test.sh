#!/usr/bin/env bash
set -euo pipefail
here="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
runner="${here}/runner.sh"

bash -n "${runner}"
grep -q 'dotnet-perf-eng.load.jmeter' "${here}/adapter-manifest.json"
grep -q 'ENTRYPOINT \["/usr/local/bin/dotnet-perf-eng-load-jmeter"\]' "${here}/Dockerfile"
if grep -Eq 'golang:|go build|runner/.*\.go' "${here}/Dockerfile"; then
  echo "JMeter adapter image still contains a Go build dependency." >&2
  exit 1
fi
if grep -R -n -E 'perflab\.(base_url|threads|duration_seconds|run_id|scenario)' \
  "${here}/../.." --include='*.jmx'; then
  echo "Native JMX files must use canonical perf.* property names." >&2
  exit 1
fi

# Journey observations use the k6 adapter's names, so gates and comparisons read
# one vocabulary (the gate checked only journeys.failed and missed k6 failures).
grep -q '{name:"journey.starts"' "${runner}"
if grep -q 'name:"journeys\.' "${runner}"; then
  echo "JMeter journey observations still use journeys.* names." >&2
  exit 1
fi
# Journey duration uses k6's observation name, so the k6/JMeter comparison reads
# the same metric.
grep -q '{name:"journey.duration.p95"' "${runner}" \
  || { echo "The JMeter summary does not report journey.duration.p95." >&2; exit 1; }
# The checkout journey's arrival timer paces one Flow Control Action per journey,
# so an open profile's rate is journeys/s -- and it sits BEFORE the journey
# transaction, whose includeTimers would otherwise count the pacing wait as
# journey time (~1 s per journey against k6's 283 ms).
plan="${here}/../../../../labs/ecommerce/loadgen/checkout-journey.jmx"
pacing="$(grep -n 'testname="journey-arrival-pacing"' "${plan}" | cut -d: -f1)"
timer="$(grep -n 'testclass="ConstantThroughputTimer"' "${plan}" | cut -d: -f1)"
journey="$(grep -n 'testname="journey::checkout"' "${plan}" | cut -d: -f1)"
if [[ -z "${pacing}" || -z "${timer}" || "${timer}" -lt "${pacing}" || "${timer}" -gt "${journey}" ]]; then
  echo "The checkout journey's arrival timer is not on the pacing action before the journey transaction." >&2
  exit 1
fi

# The summary's journey duration is the p95 of the journey transaction samples
# (280 and 300 ms here), not of the child requests, on the real parser.
work="$(mktemp -d "${TMPDIR:-/tmp}/jmeter-runner-test.XXXXXX")"
trap 'rm -rf "${work}"' EXIT HUP INT TERM
printf '%s\n' 'timeStamp,elapsed,label,responseCode,responseMessage,threadName,success,allThreads,Latency' \
  '1700000000000,300,journey::checkout,200,"Number of samples in transaction : 2, number of failing samples : 0",t1,true,1,0' \
  '1700000000000,100,op::login,200,OK,t1,true,1,90' '1700000000100,150,op::browse,200,OK,t1,true,1,140' \
  '1700000001000,280,journey::checkout,200,"Number of samples in transaction : 2, number of failing samples : 0",t1,true,1,0' \
  '1700000001000,90,op::login,200,OK,t1,true,1,80' '1700000001100,140,op::browse,200,OK,t1,true,1,130' > "${work}/results.jtl"
ADAPTER_MANIFEST="${here}/adapter-manifest.json" bash "${runner}" normalize --jtl "${work}/results.jtl" --output-dir "${work}/out" >/dev/null
jq -e '.journeyDurationP95Ms == 299 and .iterations == 2 and .startedAt == "2023-11-14T22:13:20.000Z"' "${work}/out/benchmark/jmeter-summary-v1.json" >/dev/null \
  || { echo "The JMeter summary journey duration is wrong: $(cat "${work}/out/benchmark/jmeter-summary-v1.json")" >&2; exit 1; }
jq -e 'any(.[]; .name == "journey.duration.p95" and .value == 299)' "${work}/out/benchmark/observations.json" >/dev/null \
  || { echo "The journey.duration.p95 observation is missing." >&2; exit 1; }

echo "JMeter script runner checks passed."
