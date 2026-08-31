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
# k6 only: this emits a numeric per-scale curve (rps/p50/p90/p99); wrk's
# unit-suffixed latency strings would produce invalid numeric JSON.
[[ "${load_generator}" == "k6" ]] || { echo "run-data-scale.sh needs PERFLAB_LOAD_GENERATOR=k6 (numeric latency percentiles; wrk emits unit-suffixed strings)." >&2; exit 1; }

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
# Reject an unknown scale up front: a typo (e.g. "demoo") would otherwise reseed
# an unexpected size -- or silently fall back -- and mislabel the curve. The valid
# set is overridable so a lab with different seed sizes stays supported.
valid_scales="${PERFLAB_SEED_SCALES_VALID:-smoke demo}"
for s in "${scales[@]}"; do
  case " ${valid_scales} " in
    *" ${s} "*) : ;;
    *) echo "Invalid scale '${s}' in '${scales_csv}'; supported: ${valid_scales} (override with PERFLAB_SEED_SCALES_VALID)." >&2; exit 1 ;;
  esac
done

run_stamp="$(date -u +%Y%m%dT%H%M%SZ)"
ds_id="datascale-${run_stamp}"
ds_dir="${artifacts_root}/runs/${ds_id}"
mkdir -p "${ds_dir}/scales"
echo "Data-scale sweep ${ds_id}: ${scenario_id}, scales [${scales_csv}], ${duration}s each, profile ${PERFLAB_PROFILE:-steady}"

obs() { jqd -r --arg n "$2" '(.scenarios[0].observations // .observations)[]? | select(.name==$n) | .value' < "$1" 2>/dev/null | head -1; }

level_json=()
for scale in "${scales[@]}"; do
  echo; echo "[data-scale] SEED_SCALE=${scale}: resetting DB volume and reseeding ..."
  # Hard-fail if the volume wipe fails: without a fresh volume the seeder's
  # idempotency guard skips reseeding, so this scale would be measured against the
  # PREVIOUS scale's data but labeled with the requested one -- silently
  # corrupting the degradation-vs-volume curve.
  if ! docker compose -f "${compose_file}" down -v >/dev/null 2>&1; then
    echo "[data-scale] ERROR: 'docker compose down -v' failed for scale ${scale}; the DB volume was not reset, so the seeder would skip reseeding and mislabel the data. Aborting." >&2
    exit 1
  fi
  level_dir="${ds_dir}/scales/${scale}"
  # A fresh volume + SEED_SCALE makes the app seed this size on startup.
  level_rc=0
  SEED_SCALE="${scale}" PERFLAB_ARTIFACT_DIR="${level_dir}" \
  PERFLAB_PACKAGE_RUN_ID="${ds_id}-${scale}" PERFLAB_TELEMETRY_RUN_ID="${ds_id}-${scale}" \
    "${harness_core_dir}/run/run-scenario.sh" "${scenario_id}" "${duration}" >/dev/null 2>&1 || level_rc=$?

  f="${level_dir}/facts.json"; [[ -s "$f" ]] || f="${level_dir}/benchmark/observations.json"
  if [[ "${level_rc}" -ne 0 || ! -s "$f" ]]; then
    echo "[data-scale] ${scale} ERRORED (exit ${level_rc}, no observations under ${level_dir}); recorded as errored." >&2
    level_json+=("$(printf '{"scale":"%s","errored":true,"artifactPath":"scales/%s"}' "$(json_escape "${scale}")" "${scale}")")
    continue
  fi
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
