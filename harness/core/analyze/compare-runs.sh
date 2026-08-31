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
allow_gen_mismatch="false"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --threshold) threshold="${2:?--threshold needs a value}"; shift 2 ;;
    --allow-generator-mismatch) allow_gen_mismatch="true"; shift ;;
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

# Warn when the two sides are from different experiment settings -- the numbers
# are only comparable when scenario, load generator, and profile match. (A
# multi-scenario suite has no top-level scenarioId, so that field is skipped.)
read_meta() { jqd -r '[(.scenarioId // .scenarios[0].scenarioId // ""),(.loadGenerator // .scenarios[0].loadGenerator // ""),(.profile // "")]|@tsv' < "$1" 2>/dev/null || printf '\t\t'; }
# `read` returns non-zero when the input has no trailing newline (the fallback
# above), which under `set -e` would abort the script -- the very aborted-read
# pattern this file otherwise guards against. This warning is cosmetic; never let
# it kill the comparison.
IFS=$'\t' read -r a_scen a_gen a_prof < <(read_meta "${a_file}") || true
IFS=$'\t' read -r b_scen b_gen b_prof < <(read_meta "${b_file}") || true
# A load-generator mismatch is not just noise: wrk and k6 latency numbers are not
# comparable at all, so refuse it outright (override with --allow-generator-mismatch).
# Scenario/profile differences are warned about but allowed -- a user may compare
# them intentionally (e.g. a fix that shifts the scenario slightly).
if [[ -n "${a_gen}" && -n "${b_gen}" && "${a_gen}" != "${b_gen}" && "${allow_gen_mismatch}" != "true" ]]; then
  echo "ERROR: baseline load generator '${a_gen}' != candidate '${b_gen}'; their numbers are not comparable. Re-run both with the same generator, or pass --allow-generator-mismatch to override." >&2
  exit 1
fi
mism=""
[[ -n "${a_scen}" && -n "${b_scen}" && "${a_scen}" != "${b_scen}" ]] && mism+=" scenario(${a_scen} vs ${b_scen})"
[[ -n "${a_prof}" && -n "${b_prof}" && "${a_prof}" != "${b_prof}" ]] && mism+=" profile(${a_prof} vs ${b_prof})"
[[ -n "${mism}" ]] && echo "WARNING: comparing across different experiment settings; the numbers may not be directly comparable ->${mism}" >&2

# A multi-scenario suite (run-multiple/all) has no single observation set; norm
# would compare only its scenarios[0] and silently miss regressions in the rest.
# Refuse it outright and make the caller target one scenario. A single-scenario
# suite (scenarios length 1, e.g. run-single) is fine and passes through.
reject_multi() {
  local n; n="$(jqd -r '(.scenarios | length) // 0' < "$1" 2>/dev/null || echo 0)"
  if [[ "${n}" -gt 1 ]]; then
    echo "ERROR: '$1' is a ${n}-scenario suite; comparing it would use only scenarios[0] and miss the others. Point at a specific child (.../scenarios/<id>) or a flat/single-scenario package." >&2
    exit 1
  fi
}
reject_multi "${a_file}"
reject_multi "${b_file}"

result="$(cat "${a_file}" "${b_file}" | jqd -s --argjson thr "${threshold}" '
  def norm: if .kind=="repeat-stats"
            # Drop metrics with a null mean (e.g. wrk latency strings -> n=0), so
            # the arithmetic below never evaluates null - null (which aborts jq);
            # coerce a missing stddev/n.
            then (.metrics|to_entries
                   |map(select(.value.mean != null)
                        |{key:.key,value:{v:.value.mean,sd:(.value.stddev//0),n:(.value.n//1)}})|from_entries)
            # A flat facts.json has top-level .observations; a single-scenario
            # suite (what run-single writes) nests them under .scenarios[0].
            else ((.scenarios[0].observations // .observations // []) as $obs
                  | reduce ($obs[]?) as $o ({}; if ($o.value|type)=="number" then .[$o.name]={v:$o.value,sd:0,n:1} else . end)) end;
  # Higher is better for throughput counts (requests_per_second, requests.total);
  # higher is worse for latency, error rate, and dropped iterations.
  def worseDir($k): if ($k|test("requests")) then -1 else 1 end;
  (.[0]|norm) as $a | (.[1]|norm) as $b
  | [ $a|keys[] as $k | select($b[$k]) | $a[$k] as $x | $b[$k] as $y
      | ($y.v-$x.v) as $delta
      # Relative change. When the baseline is ~0 but the candidate is not (an error
      # rate rising from zero), that is a large change, not zero.
      | (if ($x.v|fabs) > 1e-9 then ($delta/($x.v|fabs))
         elif ($y.v|fabs) > 1e-9 then 1e9
         else 0 end) as $rel
      | ((($x.sd*$x.sd)/(if $x.n>0 then $x.n else 1 end))+(($y.sd*$y.sd)/(if $y.n>0 then $y.n else 1 end))|sqrt) as $se
      | ($x.n>1 and $y.n>1) as $hs | ($hs and (($delta|fabs)>(2*$se))) as $sig
      | (($delta*worseDir($k))>0) as $worse
      # With spread on both sides, gate purely on statistical significance so a
      # within-noise change is not called a regression; without spread, fall back
      # to the relative-delta threshold.
      | ($worse and (if $hs then $sig else (($rel|fabs) > $thr) end)) as $regression
      | {metric:$k, baseline:$x.v, candidate:$y.v,
         relPct:(if $rel >= 1e8 then null else (($rel*100)*100|round/100) end),
         significanceAware:$hs, significant:$sig, regression:$regression} ]
  | {kind:"ab-comparison",threshold:$thr,regressions:([.[]|select(.regression)]|length),metrics:.}')"

printf '%s\n' "${result}" | jqd -r '.metrics[] | "  \(.metric): \(.baseline) -> \(.candidate) (\(.relPct // "n/a")%)\(if .significant then " [significant]" else "" end)\(if .regression then "  <-- REGRESSION" else "" end)"' 2>/dev/null || true
regressions="$(printf '%s' "${result}" | jqd -r '.regressions' 2>/dev/null || echo 0)"
echo
if [[ "${regressions}" -gt 0 ]]; then
  echo "RESULT: ${regressions} regression(s) vs baseline." >&2
  exit 1
fi
echo "RESULT: no regression vs baseline (threshold ${threshold})."
