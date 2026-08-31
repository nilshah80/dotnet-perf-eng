#!/usr/bin/env bash
# Discrete capacity sweep: run ONE scenario at a ladder of target arrival rates
# (open model) and report the throughput<->latency curve plus the knee -- the
# max sustainable RPS, which a single-point load test cannot find. Each level is
# a full evidence package (it reuses run-scenario.sh at PERFLAB_PROFILE=arrival),
# so per-level traces/metrics are kept; the sweep adds a curve + knee on top.
#
#   run-sweep.sh <scenario-id> [seconds-per-level] [--rates R1,R2,...] [--no-runtime]
#
# Rates: --rates > PERFLAB_SWEEP_RATES > a default ladder. sweep.json records two
# machine-readable values: kneeRps = the first target rate that FAILED to sustain
# (achieved < 95% of target, or error rate > PERFLAB_MAX_HTTP_ERROR_RATE, or k6
# dropped iterations), and maxSustainedRps = the highest rate that WAS sustained
# (the max sustainable throughput). A knee reached via dropped iterations may be a
# k6 VU-starvation artifact rather than app saturation (raise PERFLAB_MAX_VUS).
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/common.sh"
require_loadgen
[[ "${load_generator}" == "k6" ]] || { echo "run-sweep.sh needs PERFLAB_LOAD_GENERATOR=k6 (open-model arrival rate is k6-only)." >&2; exit 1; }

scenario_id="${1:?run-sweep.sh <scenario-id> [seconds-per-level] [--rates R1,R2,...]}"; shift
require_scenario "${scenario_id}"
seconds="30"
if [[ $# -gt 0 && "${1}" != --* ]]; then seconds="$1"; shift; fi
[[ "${seconds}" =~ ^[1-9][0-9]*$ ]] || { echo "seconds-per-level must be a positive integer." >&2; exit 1; }

rates_csv="${PERFLAB_SWEEP_RATES:-50,100,200,400,800,1600}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --rates) rates_csv="${2:?--rates needs a value}"; shift 2 ;;
    # A sweep is inherently measurement-only and already continues past errored
    # levels, so these are accepted as explicit no-ops (kept for habit).
    --no-runtime|--measure-only|--continue-on-error) shift ;;
    *) echo "Unknown option '$1'." >&2; exit 1 ;;
  esac
done
IFS=',' read -r -a rates <<< "${rates_csv}"
for r in "${rates[@]}"; do [[ "${r}" =~ ^[1-9][0-9]*$ ]] || { echo "Invalid rate '${r}' in '${rates_csv}'." >&2; exit 1; }; done
# Sweep low -> high so kneeRps (first rate that failed) and maxSustainedRps
# (highest rate that held) are well-defined even if --rates was given out of order.
mapfile -t rates < <(printf '%s\n' "${rates[@]}" | sort -n)
rates_csv="$(IFS=,; echo "${rates[*]}")"

err_threshold="${PERFLAB_MAX_HTTP_ERROR_RATE:-0.05}"
run_stamp="$(date -u +%Y%m%dT%H%M%SZ)"
sweep_id="sweep-${run_stamp}"
sweep_dir="${artifacts_root}/runs/${sweep_id}"
mkdir -p "${sweep_dir}/levels"
echo "Capacity sweep ${sweep_id}: scenario ${scenario_id}, rates [${rates_csv}] rps, ${seconds}s/level"

obs() { jqd -r --arg n "$2" '(.scenarios[0].observations // .observations)[]? | select(.name==$n) | .value' < "$1" 2>/dev/null | head -1; }

level_json=()
knee=""           # first target rate that FAILED to sustain (the breaking point)
max_sustained=""  # highest target rate that WAS sustained (the max sustainable RPS)
for rate in "${rates[@]}"; do
  echo; echo "[sweep] target ${rate} rps ..."
  level_dir="${sweep_dir}/levels/rps-${rate}"
  mkdir -p "${level_dir}"
  # One flat evidence package per level, driven at a fixed arrival rate.
  level_rc=0
  PERFLAB_PROFILE=arrival PERFLAB_TARGET_RPS="${rate}" \
  PERFLAB_ARTIFACT_DIR="${level_dir}" PERFLAB_PACKAGE_RUN_ID="${sweep_id}-rps-${rate}" \
  PERFLAB_TELEMETRY_RUN_ID="${sweep_id}-rps-${rate}" \
    "${harness_core_dir}/run/run-scenario.sh" "${scenario_id}" "${seconds}" >/dev/null 2>&1 || level_rc=$?

  f="${level_dir}/facts.json"; [[ -s "$f" ]] || f="${level_dir}/benchmark/observations.json"
  # An errored level (non-zero exit or no observations) is a harness/bring-up
  # failure, NOT app saturation -- it must not become the knee. Record it as
  # errored and skip; only a level that ran but could not sustain the rate counts.
  if [[ "${level_rc}" -ne 0 || ! -s "$f" ]]; then
    echo "[sweep] ${rate} rps ERRORED (exit ${level_rc}, no observations under ${level_dir}); not counted as saturation." >&2
    level_json+=("$(printf '{"targetRps":%s,"errored":true,"sustained":false,"artifactPath":"levels/rps-%s"}' "${rate}" "${rate}")")
    continue
  fi
  achieved="$(obs "$f" http.requests_per_second)"; achieved="${achieved:-0}"
  p50="$(obs "$f" http.latency.p50)"; p90="$(obs "$f" http.latency.p90)"; p99="$(obs "$f" http.latency.p99)"
  erate="$(obs "$f" http.error_rate)"; erate="${erate:-0}"
  dropped="$(obs "$f" http.dropped_iterations)"; dropped="${dropped:-0}"
  # Sustained if it kept ~the target rate with tolerable errors and no drops.
  sustained="$(awk -v a="${achieved}" -v t="${rate}" -v e="${erate}" -v et="${err_threshold}" -v d="${dropped}" \
    'BEGIN{ print (a >= 0.95*t && e <= et && d+0 == 0) ? "true" : "false" }')"
  [[ "${sustained}" == "true" ]] && max_sustained="${rate}"
  [[ "${sustained}" == "false" && -z "${knee}" ]] && knee="${rate}"
  printf '[sweep] %5s rps -> achieved %-8s p50=%-8s p99=%-8s err=%-6s dropped=%-6s %s\n' \
    "${rate}" "${achieved%.*}" "${p50:-?}" "${p99:-?}" "${erate}" "${dropped}" \
    "$([[ "${sustained}" == "true" ]] && echo sustained || echo SATURATED)"
  level_json+=("$(printf '{"targetRps":%s,"achievedRps":%s,"p50":%s,"p90":%s,"p99":%s,"errorRate":%s,"droppedIterations":%s,"errored":false,"sustained":%s,"artifactPath":"levels/rps-%s"}' \
    "${rate}" "${achieved:-0}" "${p50:-null}" "${p90:-null}" "${p99:-null}" "${erate:-0}" "${dropped:-0}" "${sustained}" "${rate}")")
done

git_revision="unversioned"; git -C "${repo_root}" rev-parse --is-inside-work-tree >/dev/null 2>&1 && git_revision="$(git -C "${repo_root}" rev-parse HEAD)"
{
  printf '{"runId":"%s","kind":"capacity-sweep","scenarioId":"%s","secondsPerLevel":%s,"kneeRps":%s,"maxSustainedRps":%s,"source":{"gitRevision":"%s"},"levels":[' \
    "$(json_escape "${sweep_id}")" "$(json_escape "${scenario_id}")" "${seconds}" "${knee:-null}" "${max_sustained:-null}" "$(json_escape "${git_revision}")"
  for i in "${!level_json[@]}"; do [[ $i -gt 0 ]] && printf ','; printf '%s' "${level_json[i]}"; done
  printf ']}\n'
} > "${sweep_dir}/sweep.json"

echo
if [[ -n "${knee}" ]]; then
  echo "Knee: first saturated at ${knee} rps; max sustained = ${max_sustained:-none} rps (see maxSustainedRps in sweep.json)."
  echo "  NOTE: a knee reached via dropped iterations can be k6 VU starvation, not app saturation"
  echo "  (maxVUs scales with connections, not target rate); if that level shows drops, re-check with a higher PERFLAB_MAX_VUS."
else
  echo "No saturation within [${rates_csv}] rps -- raise the ladder (--rates) to find the knee."
fi
echo "Sweep curve: ${sweep_dir}/sweep.json"
