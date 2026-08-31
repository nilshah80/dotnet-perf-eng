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

# Series to trend: file | key | jq path to the values array (first matching series).
#   The DB row prefers the "used" connection gauge, else the first series.
roles=(
  "gc_heap|gc.heap_bytes|.data.result[0].values"
  "working_set|process.working_set_bytes|.data.result[0].values"
  "thread_pool_queue|threadpool.queue_length|.data.result[0].values"
  "gc_committed|gc.committed_bytes|.data.result[0].values"
  "database_pool_metrics|db.connections_used|((.data.result[]?|select(.metric.db_client_connection_state==\"used\"))//.data.result[0]).values"
)

# Per-series statistics: least-squares slope over the sample index, first->last
# growth relative to the starting value, and a leak flag.
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
      | (if ($vals[0]|fabs) > 1 then ($vals[0]|fabs) else 1 end) as $base
      | ($slope*1000|round/1000) as $slp
      | (( ($vals[-1]-$vals[0]) / $base )*1000|round/1000) as $g
      | {n:$n, first:$vals[0], last:$vals[-1], max:($vals|max),
         slopePerSample:$slp, growth:$g,
         growing:($slp > 0 and $g > $thr)}
    end;
([ (VALUES_PATH)? // [] | .[] | (.[1]|tonumber) ]) as $v
| {key:$key, metric:$metric} + stat($v)'

emit=()
for role in "${roles[@]}"; do
  IFS='|' read -r file key vpath <<< "${role}"
  src="${metrics_dir}/${file}.json"
  [[ -s "${src}" ]] || continue
  entry="$(jqd -c --arg key "${key}" --arg metric "${file}" --argjson thr "${growth_threshold}" \
    "${stat_filter/(VALUES_PATH)/${vpath}}" < "${src}" 2>/dev/null || true)"
  [[ -n "${entry}" ]] && emit+=("${entry}")
done

# Assemble the report (printf the wrapper; the series were built by jqd).
{
  printf '{"kind":"trend-report","growthThreshold":%s,"series":[' "${growth_threshold}"
  for i in "${!emit[@]}"; do [[ $i -gt 0 ]] && printf ','; printf '%s' "${emit[i]}"; done
  printf ']}\n'
} > "${report}"

leaks="$(jqd -r '[.series[]|select(.growing)]|length' < "${report}" 2>/dev/null || echo 0)"
echo "Trend report: ${report}"
jqd -r '.series[] | "  \(.key): first=\(.first) last=\(.last) growth=\(.growth) slope=\(.slopePerSample) \(if .growing then "GROWING (leak candidate)" elif .insufficientPoints then "(too few samples)" else "stable" end)"' \
  < "${report}" 2>/dev/null || true
if [[ "${leaks}" -gt 0 ]]; then
  echo "WARNING: ${leaks} series growing over the window -- likely a leak/drift (strongest evidence on a soak run)." >&2
fi
