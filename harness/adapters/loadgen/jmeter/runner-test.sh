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

echo "JMeter script runner checks passed."
