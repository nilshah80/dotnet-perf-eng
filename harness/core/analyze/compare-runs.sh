#!/usr/bin/env bash
# A/B regression check: compare a candidate run against a baseline and flag
# metrics that got worse. Each side is a package dir, a facts.json, or a
# run-repeat stats.json. When BOTH sides carry per-metric stddev+n (from
# run-repeat.sh), the flag is significance-aware -- a delta beyond ~2x the
# combined standard error -- so run-to-run noise is not called a regression;
# otherwise it falls back to a relative-delta threshold.
#
#   compare-runs.sh <baseline> <candidate> [--threshold 0.10]
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/common.sh"

baseline="${1:?compare-runs.sh <baseline> <candidate> [--threshold R]}"
candidate="${2:?compare-runs.sh <baseline> <candidate> [--threshold R]}"
shift 2
threshold="0.10"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --threshold) threshold="${2:?--threshold needs a value}"; shift 2 ;;
    *) echo "Unknown option '$1'." >&2; exit 1 ;;
  esac
done
[[ "${threshold}" =~ ^[0-9]*\.?[0-9]+$ ]] || threshold="0.10"

# Resolve a side to its comparable JSON: a repeat stats.json wins (it has spread),
# else the run's facts.json.
resolve() {
  local p="$1"
  if [[ -d "$p" ]]; then
    [[ -s "$p/stats.json" ]] && { printf '%s' "$p/stats.json"; return; }
    [[ -s "$p/facts.json" ]] && { printf '%s' "$p/facts.json"; return; }
    echo "No stats.json or facts.json under '$p'." >&2; exit 1
  fi
  [[ -s "$p" ]] || { echo "Not found: '$p'." >&2; exit 1; }
  printf '%s' "$p"
}
a_file="$(resolve "${baseline}")"
b_file="$(resolve "${candidate}")"
echo "Baseline:  ${a_file}"
echo "Candidate: ${b_file}"

result="$(cat "${a_file}" "${b_file}" | jqd -s --argjson thr "${threshold}" '
  def norm: if .kind=="repeat-stats"
            then (.metrics|to_entries|map({key:.key,value:{v:.value.mean,sd:.value.stddev,n:.value.n}})|from_entries)
            else (reduce (.observations[]?) as $o ({}; if ($o.value|type)=="number" then .[$o.name]={v:$o.value,sd:0,n:1} else . end)) end;
  def worseDir($k): if ($k|test("requests_per_second")) then -1 else 1 end;   # higher rps is better
  (.[0]|norm) as $a | (.[1]|norm) as $b
  | [ $a|keys[] as $k | select($b[$k]) | $a[$k] as $x | $b[$k] as $y
      | ($y.v-$x.v) as $delta
      | (if ($x.v|fabs)>1e-9 then ($delta/($x.v|fabs)) else 0 end) as $rel
      | ((($x.sd*$x.sd)/(if $x.n>0 then $x.n else 1 end))+(($y.sd*$y.sd)/(if $y.n>0 then $y.n else 1 end))|sqrt) as $se
      | ($x.n>1 and $y.n>1) as $hs | ($hs and (($delta|fabs)>(2*$se))) as $sig
      | (($delta*worseDir($k))>0) as $worse
      | {metric:$k, baseline:$x.v, candidate:$y.v, relPct:(($rel*100)*100|round/100),
         significanceAware:$hs, significant:$sig, regression:($worse and ($sig or ($rel|fabs)>$thr))} ]
  | {kind:"ab-comparison",threshold:$thr,regressions:([.[]|select(.regression)]|length),metrics:.}')"

printf '%s\n' "${result}" | jqd -r '.metrics[] | "  \(.metric): \(.baseline) -> \(.candidate) (\(.relPct)%)\(if .significant then " [significant]" else "" end)\(if .regression then "  <-- REGRESSION" else "" end)"' 2>/dev/null || true
regressions="$(printf '%s' "${result}" | jqd -r '.regressions' 2>/dev/null || echo 0)"
echo
if [[ "${regressions}" -gt 0 ]]; then
  echo "RESULT: ${regressions} regression(s) vs baseline." >&2
  exit 1
fi
echo "RESULT: no regression vs baseline (threshold ${threshold})."
