#!/usr/bin/env bash
# Detect material host change across a run's environment boundaries.
#
# Acceptance case 46. A measurement is only comparable to another if the machine
# was the same machine. On a laptop it often is not: Docker Desktop's CPU or
# memory allocation can be changed from a settings pane between runs, another
# lab or a build can load the host mid-window, and a container can restart
# without the app metrics showing any of it.
#
# The snapshots to answer that are already captured at each boundary. What was
# missing is the comparison: recording the environment and never checking it
# means the evidence exists and nobody reads it, which is the same as not having
# it. This reports; it never edits the measurement.
#
#   environment-drift.sh <run-dir>
# Writes analysis/environment-drift.json.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${here}/../lib/common.sh"

run_arg="${1:?environment-drift.sh <run-dir>}"
[[ -d "${run_arg}" ]] || { echo "environment-drift: '${run_arg}' is not a run directory." >&2; exit 2; }
env_root="${run_arg}/environment"
mkdir -p "${run_arg}/analysis"
out="${run_arg}/analysis/environment-drift.json"

# Tunables. The load threshold is a RATIO because absolute load is meaningless
# without knowing the core count; the envelope thresholds are exact because a
# changed CPU or memory allocation is never noise.
load_ratio_threshold="${PERFLAB_ENV_LOAD_DRIFT:-0.50}"

boundaries=()
while IFS= read -r dir; do
  [[ -s "${dir}/host.json" ]] && boundaries+=("${dir}")
done < <(find "${env_root}" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | LC_ALL=C sort)

if [[ "${#boundaries[@]}" -lt 2 ]]; then
  # Fewer than two boundaries is NOT "no drift": it is no basis to judge. Saying
  # "stable" here would be the absent-as-healthy failure in a new place.
  printf '{"kind":"environment-drift","captureState":"missing","reason":"fewer than two environment boundaries were captured, so drift cannot be judged","boundaries":%s,"materialChange":null}\n' \
    "${#boundaries[@]}" > "${out}"
  echo "environment-drift: only ${#boundaries[@]} boundary snapshot(s); cannot judge drift." >&2
  exit 0
fi

first="${boundaries[0]}/host.json"
last="${boundaries[${#boundaries[@]} - 1]}/host.json"
read_num() { jqd -r --arg k "$2" '(.[$k] // .loadAverage[$k] // empty) | tostring' < "$1" 2>/dev/null | head -1; }

cpus_a="$(read_num "${first}" hostCpus)"; cpus_b="$(read_num "${last}" hostCpus)"
mem_a="$(read_num "${first}" hostMemoryBytes)"; mem_b="$(read_num "${last}" hostMemoryBytes)"
load_a="$(read_num "${first}" 1m)"; load_b="$(read_num "${last}" 1m)"
containers_a="$(read_num "${first}" dockerContainersRunning)"; containers_b="$(read_num "${last}" dockerContainersRunning)"

findings=""
material=0
add() { findings="${findings}${findings:+,}$(printf '"%s"' "$(json_escape "$1")")"; material=1; }

# A changed CPU or memory allocation invalidates the comparison outright: the
# machine that produced the second half is not the machine that produced the
# first.
if [[ -n "${cpus_a}" && -n "${cpus_b}" && "${cpus_a}" != "${cpus_b}" ]]; then
  add "host CPU allocation changed mid-run: ${cpus_a} -> ${cpus_b} cores; the two halves of this run were measured on different machines"
fi
if [[ -n "${mem_a}" && -n "${mem_b}" && "${mem_a}" != "${mem_b}" ]]; then
  add "host memory allocation changed mid-run: ${mem_a} -> ${mem_b} bytes"
fi
# Load is the proxy this host can actually offer for thermal and power state:
# sustained external load is what throttling and competing work look like from
# inside a container.
if [[ -n "${load_a}" && -n "${load_b}" && -n "${cpus_a}" && "${cpus_a}" != "0" ]]; then
  drift="$(awk -v a="${load_a}" -v b="${load_b}" -v c="${cpus_a}" -v t="${load_ratio_threshold}" \
    'BEGIN { d = (b - a) / c; printf "%.4f", d; }')"
  exceeded="$(awk -v d="${drift}" -v t="${load_ratio_threshold}" 'BEGIN { print (d >= t || -d >= t) ? 1 : 0 }')"
  if [[ "${exceeded}" == "1" ]]; then
    add "host load changed by $(awk -v d="${drift}" 'BEGIN{printf "%.2f", d}') per core between boundaries (${load_a} -> ${load_b} over ${cpus_a} cores); work outside this run competed for the machine"
  fi
fi
if [[ -n "${containers_a}" && -n "${containers_b}" && "${containers_a}" != "${containers_b}" ]]; then
  add "running container count changed: ${containers_a} -> ${containers_b}; a container restarted, or another stack shared the host"
fi

verdict="stable"; [[ "${material}" == "1" ]] && verdict="material-change"
printf '{"kind":"environment-drift","captureState":"captured","boundaries":%s,"verdict":"%s","materialChange":%s,"thresholds":{"loadPerCore":%s},"observed":{"hostCpus":{"first":%s,"last":%s},"hostMemoryBytes":{"first":%s,"last":%s},"loadAverage1m":{"first":%s,"last":%s},"containersRunning":{"first":%s,"last":%s}},"findings":[%s]}\n' \
  "${#boundaries[@]}" "${verdict}" "$([[ "${material}" == "1" ]] && echo true || echo false)" \
  "${load_ratio_threshold}" \
  "${cpus_a:-null}" "${cpus_b:-null}" "${mem_a:-null}" "${mem_b:-null}" \
  "${load_a:-null}" "${load_b:-null}" "${containers_a:-null}" "${containers_b:-null}" \
  "${findings}" > "${out}"

if [[ "${material}" == "1" ]]; then
  echo "environment-drift: MATERIAL CHANGE between boundaries -- this run is not comparable to one taken on the unchanged host." >&2
  jqd -r '.findings[]' < "${out}" 2>/dev/null | sed 's/^/  - /' >&2 || true
fi
echo "wrote ${out}"
