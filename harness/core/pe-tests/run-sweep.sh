#!/usr/bin/env bash
# Discrete capacity sweep: run ONE scenario at a ladder of target arrival rates
# (open model) and report the throughput<->latency curve plus the knee -- the
# max sustainable RPS, which a single-point load test cannot find. Each level is
# a full evidence package (it reuses run-scenario.sh at PERFLAB_PROFILE=arrival),
# so per-level traces/metrics are kept; the sweep adds a curve + knee on top.
#
#   run-sweep.sh <scenario-id> [seconds-per-level] [--rates R1,R2,...] [--no-runtime]
#
# Rates: --rates > PERFLAB_SWEEP_RATES > a default ladder. The knee is the first
# level that fails to sustain the target -- achieved < 95% of target, or the
# error rate crosses PERFLAB_MAX_HTTP_ERROR_RATE, or k6 dropped iterations.
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
pass_through=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --rates) rates_csv="${2:?--rates needs a value}"; shift 2 ;;
    --no-runtime|--measure-only|--with-runtime|--continue-on-error) pass_through+=("$1"); shift ;;
    *) echo "Unknown option '$1'." >&2; exit 1 ;;
  esac
done
IFS=',' read -r -a rates <<< "${rates_csv}"
for r in "${rates[@]}"; do [[ "${r}" =~ ^[1-9][0-9]*$ ]] || { echo "Invalid rate '${r}' in '${rates_csv}'." >&2; exit 1; }; done

err_threshold="${PERFLAB_MAX_HTTP_ERROR_RATE:-0.05}"
run_stamp="$(date -u +%Y%m%dT%H%M%SZ)"
sweep_id="sweep-${run_stamp}"
sweep_dir="${artifacts_root}/runs/${sweep_id}"
mkdir -p "${sweep_dir}/levels"
echo "Capacity sweep ${sweep_id}: scenario ${scenario_id}, rates [${rates_csv}] rps, ${seconds}s/level"

obs() { jqd -r --arg n "$2" '(.scenarios[0].observations // .observations)[]? | select(.name==$n) | .value' < "$1" 2>/dev/null | head -1; }

level_json=()
knee=""
for rate in "${rates[@]}"; do
  echo; echo "[sweep] target ${rate} rps ..."
  level_dir="${sweep_dir}/levels/rps-${rate}"
  mkdir -p "${level_dir}"
  # One flat evidence package per level, driven at a fixed arrival rate.
  PERFLAB_PROFILE=arrival PERFLAB_TARGET_RPS="${rate}" \
  PERFLAB_ARTIFACT_DIR="${level_dir}" PERFLAB_PACKAGE_RUN_ID="${sweep_id}-rps-${rate}" \
  PERFLAB_TELEMETRY_RUN_ID="${sweep_id}-rps-${rate}" \
    "${harness_core_dir}/run/run-scenario.sh" "${scenario_id}" "${seconds}" >/dev/null 2>&1 || \
    echo "[sweep] level ${rate} rps had a non-zero exit (continuing; check ${level_dir})." >&2

  f="${level_dir}/facts.json"; [[ -s "$f" ]] || f="${level_dir}/benchmark/observations.json"
  achieved="$(obs "$f" http.requests_per_second)"; achieved="${achieved:-0}"
  p50="$(obs "$f" http.latency.p50)"; p90="$(obs "$f" http.latency.p90)"; p99="$(obs "$f" http.latency.p99)"
  erate="$(obs "$f" http.error_rate)"; erate="${erate:-0}"
  dropped="$(obs "$f" http.dropped_iterations)"; dropped="${dropped:-0}"
  # Sustained if it kept ~the target rate with tolerable errors and no drops.
  sustained="$(awk -v a="${achieved}" -v t="${rate}" -v e="${erate}" -v et="${err_threshold}" -v d="${dropped}" \
    'BEGIN{ print (a >= 0.95*t && e <= et && d+0 == 0) ? "true" : "false" }')"
  [[ "${sustained}" == "false" && -z "${knee}" ]] && knee="${rate}"
  printf '[sweep] %5s rps -> achieved %-8s p50=%-8s p99=%-8s err=%-6s dropped=%-6s %s\n' \
    "${rate}" "${achieved%.*}" "${p50:-?}" "${p99:-?}" "${erate}" "${dropped}" \
    "$([[ "${sustained}" == "true" ]] && echo sustained || echo SATURATED)"
  level_json+=("$(printf '{"targetRps":%s,"achievedRps":%s,"p50":%s,"p90":%s,"p99":%s,"errorRate":%s,"droppedIterations":%s,"sustained":%s,"artifactPath":"levels/rps-%s"}' \
    "${rate}" "${achieved:-0}" "${p50:-null}" "${p90:-null}" "${p99:-null}" "${erate:-0}" "${dropped:-0}" "${sustained}" "${rate}")")
done

git_revision="unversioned"; git -C "${repo_root}" rev-parse --is-inside-work-tree >/dev/null 2>&1 && git_revision="$(git -C "${repo_root}" rev-parse HEAD)"
{
  printf '{"runId":"%s","kind":"capacity-sweep","scenarioId":"%s","secondsPerLevel":%s,"kneeRps":%s,"source":{"gitRevision":"%s"},"levels":[' \
    "$(json_escape "${sweep_id}")" "$(json_escape "${scenario_id}")" "${seconds}" "${knee:-null}" "$(json_escape "${git_revision}")"
  for i in "${!level_json[@]}"; do [[ $i -gt 0 ]] && printf ','; printf '%s' "${level_json[i]}"; done
  printf ']}\n'
} > "${sweep_dir}/sweep.json"

echo
if [[ -n "${knee}" ]]; then
  echo "Knee: first saturated at ${knee} rps -> max sustained is the level below it."
else
  echo "No saturation within [${rates_csv}] rps -- raise the ladder (--rates) to find the knee."
fi
echo "Sweep curve: ${sweep_dir}/sweep.json"
