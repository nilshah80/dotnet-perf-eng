#!/usr/bin/env bash
# Repeat a scenario N times and aggregate robust statistics per metric (median,
# mean, stddev, coefficient of variation). A single short run has high variance,
# so N reps + spread is what makes a number trustworthy and a regression
# detectable. Pair with compare-runs.sh for A/B significance.
#
#   run-repeat.sh <scenario-id> [duration-seconds] [--repeats N] [--profile P]
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/common.sh"
require_loadgen
# k6 only: this aggregates numeric latency percentiles into median/stddev/CV, but
# wrk emits them as unit-suffixed "wrk-duration" strings, which would drop to null.
[[ "${load_generator}" == "k6" ]] || { echo "run-repeat.sh needs PERFLAB_LOAD_GENERATOR=k6 (numeric latency percentiles; wrk emits unit-suffixed strings)." >&2; exit 1; }

scenario_id="${1:?run-repeat.sh <scenario-id> [duration] [--repeats N] [--reseed] [--profile P]}"; shift
require_scenario "${scenario_id}"
duration="30"
if [[ $# -gt 0 && "${1}" != --* ]]; then duration="$1"; shift; fi
[[ "${duration}" =~ ^[1-9][0-9]*$ ]] || { echo "duration must be a positive integer." >&2; exit 1; }
repeats="${PERFLAB_REPEATS:-5}"
reseed_between_reps="${PERFLAB_REPEAT_RESEED:-false}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repeats) repeats="${2:?--repeats needs a value}"; shift 2 ;;
    --reseed)  reseed_between_reps="true"; shift ;;
    --profile) export PERFLAB_PROFILE="${2:?--profile needs a value}"; shift 2 ;;
    *) echo "Unknown option '$1'." >&2; exit 1 ;;
  esac
done
[[ "${repeats}" =~ ^[1-9][0-9]*$ ]] || { echo "--repeats must be a positive integer." >&2; exit 1; }

run_stamp="$(date -u +%Y%m%dT%H%M%SZ)"
rep_id="repeat-${run_stamp}"
rep_dir="${artifacts_root}/runs/${rep_id}"
mkdir -p "${rep_dir}/reps"
echo "Repeat ${rep_id}: ${scenario_id} x${repeats}, ${duration}s each, profile ${PERFLAB_PROFILE:-steady}"

# By default reps share the DB volume (only pg_stat_statements/redis/queues are
# reset between them, not the data). For a WRITE scenario (e.g. E07/E12 inserting
# rows) the database grows across reps, so later reps measure a larger dataset and
# the CV/significance are NOT over independent samples -- pass --reseed to wipe and
# reseed the DB before each rep (independent samples, at the cost of a bring-up per
# rep). Read scenarios need no reseed.
facts_files=()
for ((k = 1; k <= repeats; k++)); do
  echo; echo "[repeat] rep ${k}/${repeats} ..."
  d="${rep_dir}/reps/rep-$(printf '%02d' "${k}")"
  if [[ "${reseed_between_reps}" == "true" ]]; then
    echo "[repeat] --reseed: wiping + reseeding the DB before rep ${k} ..."
    docker compose -f "${compose_file}" down -v >/dev/null 2>&1 || {
      echo "[repeat] ERROR: 'down -v' failed before rep ${k}; aborting to avoid biased samples." >&2; exit 1; }
  fi
  rep_rc=0
  PERFLAB_ARTIFACT_DIR="${d}" PERFLAB_PACKAGE_RUN_ID="${rep_id}-rep${k}" PERFLAB_TELEMETRY_RUN_ID="${rep_id}-rep${k}" \
    "${harness_core_dir}/run/run-scenario.sh" "${scenario_id}" "${duration}" >/dev/null 2>&1 || rep_rc=$?
  # Only a clean rep contributes to the statistics: a rep that errored (even if it
  # left a partial facts.json with rps~0) would otherwise skew median/stddev/CV.
  if [[ "${rep_rc}" -eq 0 && -s "${d}/facts.json" ]]; then
    facts_files+=("${d}/facts.json")
  else
    echo "[repeat] rep ${k} excluded from the statistics (exit ${rep_rc} or no facts)." >&2
  fi
done
[[ "${#facts_files[@]}" -gt 0 ]] || { echo "No successful reps produced facts." >&2; exit 1; }
# stddev/CV need >=2 samples to mean anything; with one rep they are 0 and would
# read as "perfectly consistent". Report the median/mean but flag the spread as
# undefined so a single-rep result is not mistaken for a trustworthy one.
if [[ "${#facts_files[@]}" -lt 2 ]]; then
  echo "WARNING: only ${#facts_files[@]} rep succeeded (of ${repeats} requested); stddev/CV are undefined with <2 samples -- median/mean are reported but treat the spread as unknown." >&2
fi

cat "${facts_files[@]}" | jqd -s --arg scen "${scenario_id}" --arg repId "${rep_id}" --arg prof "${PERFLAB_PROFILE:-steady}" '
  def med($a): ($a|sort) as $s | ($s|length) as $n
     | if $n==0 then null elif $n%2==1 then $s[($n/2|floor)] else (($s[$n/2-1]+$s[$n/2])/2) end;
  def stats($a): ($a|length) as $n
     | if $n==0 then null else (($a|add)/$n) as $mean
       # stddev/CV are undefined with <2 samples: emit null, not 0, so the
       # machine-readable output does not misrepresent one rep as zero spread.
       | (if $n>1 then ((reduce $a[] as $x (0; .+(($x-$mean)*($x-$mean)))/($n-1))|sqrt) else null end) as $sd
       | {n:$n, mean:($mean*1000|round/1000), median:(med($a)*1000|round/1000), min:($a|min), max:($a|max),
          stddev:(if $sd==null then null else ($sd*1000|round/1000) end),
          cv:(if $sd==null then null elif $mean==0 then 0 else ($sd/($mean|fabs)*1000|round/1000) end)} end;
  ["http.requests_per_second","http.latency.p50","http.latency.p90","http.latency.p99","http.error_rate"] as $names
  | (reduce .[] as $f ({}; reduce ($f.observations[]?) as $o (.; if ($o.value|type)=="number" then .[$o.name] += [$o.value] else . end))) as $byname
  | {runId:$repId,kind:"repeat-stats",scenarioId:$scen,profile:$prof,
     reps:(($byname["http.requests_per_second"]//[])|length),
     metrics:($names | map({(.): stats($byname[.] // [])}) | add)}' > "${rep_dir}/stats.json"

echo; echo "Repeat stats: ${rep_dir}/stats.json"
jqd -r '.metrics | to_entries[] | "  \(.key): median=\(.value.median) mean=\(.value.mean) cv=\(.value.cv) (n=\(.value.n))"' \
  < "${rep_dir}/stats.json" 2>/dev/null || true
