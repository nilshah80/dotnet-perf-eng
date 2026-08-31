#!/usr/bin/env bash
# Data-scale sweep: run ONE scenario at each seed size to characterize how
# performance degrades with data volume (e.g. E05's ILIKE scan at 20k rows vs
# 100k). The seeded row counts are a first-class test axis here: each scale
# resets the DB volume and reseeds via SEED_SCALE, then runs a full evidence
# package. `smoke` and `demo` are the app's supported sizes.
#
#   run-data-scale.sh <scenario-id> [duration] [--scales smoke,demo] [--profile P]
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/common.sh"
require_loadgen

scenario_id="${1:?run-data-scale.sh <scenario-id> [duration] [--scales smoke,demo]}"; shift
require_scenario "${scenario_id}"
duration="30"
if [[ $# -gt 0 && "${1}" != --* ]]; then duration="$1"; shift; fi
[[ "${duration}" =~ ^[1-9][0-9]*$ ]] || { echo "duration must be a positive integer." >&2; exit 1; }
scales_csv="${PERFLAB_SEED_SCALES:-smoke,demo}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --scales) scales_csv="${2:?--scales needs a value}"; shift 2 ;;
    --profile) export PERFLAB_PROFILE="${2:?--profile needs a value}"; shift 2 ;;
    *) echo "Unknown option '$1'." >&2; exit 1 ;;
  esac
done
IFS=',' read -r -a scales <<< "${scales_csv}"

run_stamp="$(date -u +%Y%m%dT%H%M%SZ)"
ds_id="datascale-${run_stamp}"
ds_dir="${artifacts_root}/runs/${ds_id}"
mkdir -p "${ds_dir}/scales"
echo "Data-scale sweep ${ds_id}: ${scenario_id}, scales [${scales_csv}], ${duration}s each, profile ${PERFLAB_PROFILE:-steady}"

obs() { jqd -r --arg n "$2" '(.scenarios[0].observations // .observations)[]? | select(.name==$n) | .value' < "$1" 2>/dev/null | head -1; }

level_json=()
for scale in "${scales[@]}"; do
  echo; echo "[data-scale] SEED_SCALE=${scale}: resetting DB volume and reseeding ..."
  docker compose -f "${compose_file}" down -v >/dev/null 2>&1 || true
  level_dir="${ds_dir}/scales/${scale}"
  # A fresh volume + SEED_SCALE makes the app seed this size on startup.
  SEED_SCALE="${scale}" PERFLAB_ARTIFACT_DIR="${level_dir}" \
  PERFLAB_PACKAGE_RUN_ID="${ds_id}-${scale}" PERFLAB_TELEMETRY_RUN_ID="${ds_id}-${scale}" \
    "${harness_core_dir}/run/run-scenario.sh" "${scenario_id}" "${duration}" >/dev/null 2>&1 || \
    echo "[data-scale] ${scale} had a non-zero exit (continuing; check ${level_dir})." >&2

  f="${level_dir}/facts.json"; [[ -s "$f" ]] || f="${level_dir}/benchmark/observations.json"
  rps="$(obs "$f" http.requests_per_second)"; p50="$(obs "$f" http.latency.p50)"
  p90="$(obs "$f" http.latency.p90)"; p99="$(obs "$f" http.latency.p99)"; erate="$(obs "$f" http.error_rate)"
  printf '[data-scale] %-8s -> rps=%-8s p50=%-8s p99=%-8s err=%s\n' "${scale}" "${rps%.*}" "${p50:-?}" "${p99:-?}" "${erate:-?}"
  level_json+=("$(printf '{"scale":"%s","rps":%s,"p50":%s,"p90":%s,"p99":%s,"errorRate":%s,"artifactPath":"scales/%s"}' \
    "$(json_escape "${scale}")" "${rps:-null}" "${p50:-null}" "${p90:-null}" "${p99:-null}" "${erate:-0}" "${scale}")")
done

git_revision="unversioned"; git -C "${repo_root}" rev-parse --is-inside-work-tree >/dev/null 2>&1 && git_revision="$(git -C "${repo_root}" rev-parse HEAD)"
{
  printf '{"runId":"%s","kind":"data-scale-sweep","scenarioId":"%s","secondsPerScale":%s,"source":{"gitRevision":"%s"},"scales":[' \
    "$(json_escape "${ds_id}")" "$(json_escape "${scenario_id}")" "${duration}" "$(json_escape "${git_revision}")"
  for i in "${!level_json[@]}"; do [[ $i -gt 0 ]] && printf ','; printf '%s' "${level_json[i]}"; done
  printf ']}\n'
} > "${ds_dir}/data-scale.json"
echo; echo "Data-scale curve: ${ds_dir}/data-scale.json"
