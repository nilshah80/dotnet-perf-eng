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
# The checkout journey's arrival timer paces op::login, one sampler per journey,
# so an open profile's rate is journeys/s rather than requests/s.
plan="${here}/../../../../labs/ecommerce/loadgen/checkout-journey.jmx"
login="$(grep -n 'testname="op::login"' "${plan}" | cut -d: -f1)"
timer="$(grep -n 'testclass="ConstantThroughputTimer"' "${plan}" | cut -d: -f1)"
browse="$(grep -n 'testname="op::browse"' "${plan}" | cut -d: -f1)"
if [[ -z "${timer}" || "${timer}" -lt "${login}" || "${timer}" -gt "${browse}" ]]; then
  echo "The checkout journey's arrival timer does not pace op::login." >&2
  exit 1
fi

echo "JMeter script runner checks passed."
