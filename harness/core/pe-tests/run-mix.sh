#!/usr/bin/env bash
# Run a weighted workload MIX -- realistic blended traffic (e.g. 70% list / 20%
# search / 10% checkout) that a single-endpoint scenario cannot express. A mix is
# a per-lab JSON file of {method,path,body,weight} at
# labs/<lab>/loadgen/mixes/<name>.json; the k6 workload reads it via PERF_MIX and
# picks a weighted-random request each iteration. Composes with any load profile.
#
#   run-mix.sh <mix-name> [duration-seconds] [--connections N] [--profile P]
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/common.sh"
require_loadgen
[[ "${load_generator}" == "k6" ]] || { echo "run-mix.sh needs PERFLAB_LOAD_GENERATOR=k6 (the mix workload is k6-only)." >&2; exit 1; }

mix_name="${1:?run-mix.sh <mix-name> [duration-seconds] [--connections N] [--profile P]}"; shift
duration="30"
if [[ $# -gt 0 && "${1}" != --* ]]; then duration="$1"; shift; fi
[[ "${duration}" =~ ^[1-9][0-9]*$ ]] || { echo "duration must be a positive integer." >&2; exit 1; }

connections="${PERFLAB_CONNECTIONS:-64}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --connections) connections="${2:?--connections needs a value}"; shift 2 ;;
    --profile)     export PERFLAB_PROFILE="${2:?--profile needs a value}"; shift 2 ;;
    *) echo "Unknown option '$1'." >&2; exit 1 ;;
  esac
done
[[ "${connections}" =~ ^[1-9][0-9]*$ ]] || { echo "--connections must be a positive integer." >&2; exit 1; }

mix_file="${lab_dir}/loadgen/mixes/${mix_name}.json"
[[ -f "${mix_file}" ]] || {
  echo "Mix '${mix_name}' not found: ${mix_file}" >&2
  echo "Available mixes for this lab:" >&2
  ls -1 "${lab_dir}/loadgen/mixes/" 2>/dev/null | sed 's/\.json$//; s/^/  /' >&2 || true
  exit 1
}
jqd -e 'type=="array" and length>0' < "${mix_file}" >/dev/null 2>&1 || {
  echo "Mix file must be a non-empty JSON array of {method,path,body,weight}: ${mix_file}" >&2; exit 1; }

export PERF_MIX="$(cat "${mix_file}")"
export PERFLAB_CONNECTIONS="${connections}"
echo "Workload mix '${mix_name}': ${connections} connections, ${duration}s, profile ${PERFLAB_PROFILE:-steady}"
exec "${harness_core_dir}/run/run-scenario.sh" "mix-${mix_name}" "${duration}"
