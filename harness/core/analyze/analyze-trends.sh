#!/usr/bin/env bash
# Trend / leak detector. Reads the range (over-the-window) gauge metrics an
# evidence package already captured and reports, per series, the least-squares
# slope and the first->last growth, flagging a "growing" series as a leak/drift
# candidate. This is what turns the `soak` profile from "it ran long" into an
# answer -- the resource-growth signal (heap, working set, thread-pool queue,
# DB connections) that a soak exists to surface. Runs on ANY package (short
# windows are just low-confidence, and marked so).
#
#   analyze-trends.sh <artifact-dir>
#
# Metric FILE names are the runtime-neutral role names from the adapter's
# metrics.sh (gc_heap/working_set/thread_pool_queue/database_pool_metrics), so
# this stays runtime-agnostic; only the optional DB "used"-state selector is a
# best-effort convenience.
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/common.sh"

artifact_dir="${1:?analyze-trends.sh <artifact-directory>}"
metrics_dir="${artifact_dir}/telemetry/metrics"
mkdir -p "${artifact_dir}/analysis"
report="${artifact_dir}/analysis/trend-report.json"

# Relative growth above which a positively-sloped series is flagged a leak.
growth_threshold="${PERFLAB_LEAK_GROWTH_THRESHOLD:-0.2}"
[[ "${growth_threshold}" =~ ^[0-9]*\.?[0-9]+$ ]] || growth_threshold="0.2"

# Series to trend: file | key | absolute-growth floor | per-series selector.
#   Each metric is trended PER PROCESS INSTANCE (a worker-target scenario has both
#   the api and worker processes, so gc_heap has 5 generations x 2 instances).
#   Within an instance the selected series are summed per timestamp -- so a
#   per-generation heap sums its OWN generations (gen0..poh) and never conflates
#   api with worker, and a single-series gauge sums to itself. The selector keeps
#   the role-relevant series: "." keeps all; the DB row keeps only the "used"
#   connection gauge (db_client_connection_state=="used"), since that metric file
#   also carries max/histogram/counter series that must not be summed in.
#   The floor is the absolute first->last change below which growth is ignored --
#   bytes for heap/working-set/committed, connection/queue counts otherwise -- so
#   a near-zero baseline can no longer fabricate a large relative growth.
roles=(
  "gc_heap|gc.heap_bytes|1048576|."
  "working_set|process.working_set_bytes|1048576|."
  "thread_pool_queue|threadpool.queue_length|5|."
  "gc_committed|gc.committed_bytes|1048576|."
  "database_pool_metrics|db.connections_used|2|select(.metric.db_client_connection_state == \"used\")"
)

# Per-instance statistics: least-squares slope over the sample index, first->last
# growth on a bounded denominator, and a leak flag; emits one object per instance.
stat_filter='
def stat($vals):
  ($vals|length) as $n
  | if $n < 3 then {n:$n, insufficientPoints:true, growing:false}
    else
      (reduce range(0;$n) as $i (0; .+$i)) as $sx
      | (reduce $vals[] as $v (0; .+$v)) as $sy
      | (reduce range(0;$n) as $i (0; .+ ($i*$vals[$i]))) as $sxy
      | (reduce range(0;$n) as $i (0; .+ ($i*$i))) as $sxx
      | (($n*$sxx - $sx*$sx)) as $den
      | (if $den == 0 then 0 else (($n*$sxy - $sx*$sy)/$den) end) as $slope
      # Bounded denominator max(|first|,|last|,1): a near-zero first sample can no
      # longer explode the relative growth. Combined with the absolute floor below.
      | ([($vals[0]|fabs),($vals[-1]|fabs),1]|max) as $base
      | ($slope*1000|round/1000) as $slp
      | ($vals[-1]-$vals[0]) as $abs
      | (( $abs / $base )*1000|round/1000) as $g
      | {n:$n, first:$vals[0], last:$vals[-1], max:($vals|max),
         slopePerSample:$slp, growth:$g, growthAbs:$abs,
         growing:($slp > 0 and $g > $thr and ($abs >= $floor))}
    end;
[ (.data.result // [])
  | group_by(.metric.service_instance_id // .metric.instance // "")[]
  | (.[0].metric.service_instance_id // .[0].metric.instance // "?") as $inst
  | ([ .[] | (SERIES_FILTER) ]) as $series
  | ([ $series[]? | .values[]? ] | group_by(.[0]) | map([(.[0][0]), ([.[][1]|tonumber]|add)])) as $summed
  | select(($summed | length) > 0)
  | ([ $summed[] | .[1] ]) as $vals
  | {key:$key, metric:$metric, instance:$inst} + stat($vals) ]'

emit=()
for role in "${roles[@]}"; do
  IFS='|' read -r file key floor filt <<< "${role}"
  src="${metrics_dir}/${file}.json"
  [[ -s "${src}" ]] || continue
  # entries is a JSON ARRAY of per-instance objects (one metric can span >1 process).
  entries="$(jqd -c --arg key "${key}" --arg metric "${file}" --argjson thr "${growth_threshold}" --argjson floor "${floor}" \
    "${stat_filter/SERIES_FILTER/${filt}}" < "${src}" 2>/dev/null || true)"
  [[ -n "${entries}" && "${entries}" != "[]" ]] && emit+=("${entries}")
done

# Concatenate the per-role arrays into one flat series list.
if [[ "${#emit[@]}" -eq 0 ]]; then
  series="[]"
else
  series="$(printf '%s\n' "${emit[@]}" | jqd -s 'add // []' 2>/dev/null || echo '[]')"
fi
printf '{"kind":"trend-report","growthThreshold":%s,"series":%s}\n' "${growth_threshold}" "${series}" > "${report}"

leaks="$(jqd -r '[.series[]|select(.growing)]|length' < "${report}" 2>/dev/null || echo 0)"
echo "Trend report: ${report}"
jqd -r '.series[] | "  \(.key)\(if (.instance // "") != "" and .instance != "?" then " [" + (.instance|tostring|.[0:12]) + "]" else "" end): first=\(.first) last=\(.last) growth=\(.growth) slope=\(.slopePerSample) \(if .growing then "GROWING (leak candidate)" elif .insufficientPoints then "(too few samples)" else "stable" end)"' \
  < "${report}" 2>/dev/null || true
if [[ "${leaks}" -gt 0 ]]; then
  echo "WARNING: ${leaks} instance-series growing over the window -- likely a leak/drift (strongest evidence on a soak run)." >&2
fi
