#!/usr/bin/env bash
set -euo pipefail

root="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
export PERFLAB_LAB_OPTIONAL=1
# shellcheck disable=SC1091
source "${root}/harness/core/lib/common.sh"
# shellcheck disable=SC1091
source "${root}/harness/core/lib/performance.sh"
# shellcheck disable=SC1091
source "${root}/harness/adapters/loadgen/k6/profiles.sh"

for catalog in "${root}"/labs/*/catalog.json; do
  performance_validate_catalog "${catalog}"
done
for manifest in "${root}"/labs/*/workload-manifest.json; do
  performance_validate_workload_manifest "${manifest}"
done
for kind in request journey mix protocol; do
  performance_compare_preflight "${kind}"
done
if performance_capability_preflight wrk journey '' 2>/dev/null; then
  echo "wrk journey rejection failed" >&2
  exit 1
fi
if performance_target_preflight existing-environment none deploy 2>/dev/null; then
  echo "unmanaged deploy rejection failed" >&2
  exit 1
fi

work="$(mktemp -d "${TMPDIR:-/tmp}/native-profile.XXXXXX")"
trap 'rm -rf "${work}"' EXIT HUP INT TERM
for profile in smoke load steady ramp stress breakpoint capacity knee spike open closed soak arrival; do
  k6_write_profile_config "${profile}" 8 12 "${work}/${profile}.json"
  jqd -e '.scenarios.measure.executor | type == "string"' < "${work}/${profile}.json" >/dev/null
  duration="$(k6_profile_effective_duration "${profile}" 8 12)"
  [[ "${duration}" =~ ^[1-9][0-9]*$ ]]
done
PERF_PROTOCOL=browser-synthetic k6_write_profile_config steady 1 2 "${work}/browser.json"
jqd -e '.scenarios.measure.options.browser.type == "chromium"' < "${work}/browser.json" >/dev/null
printf '%s\n' 'native script foundation tests passed'
