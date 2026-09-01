#!/usr/bin/env bash
# Report the cross-commit perf trend from perf-history/<lab>.jsonl: for a metric
# (and optionally one scenario/profile), print the value at each recorded commit
# over time with the change vs the previous point and a bar, so a slow regression
# across releases is visible at a glance.
#
#   trend-report.sh [--lab NAME] [--scenario ID] [--metric NAME] [--profile P] [--last N]
#
# Metric defaults to http.latency.p99. Useful metrics: http.latency.p99,
# http.requests_per_second, http.error_rate, efficiency.cpu_ms_per_request,
# efficiency.alloc_bytes_per_request.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PERFLAB_LAB_OPTIONAL=1
# shellcheck disable=SC1091
source "${here}/../lib/common.sh"

lab="${PERFLAB_PROJECT:-}"; scenario=""; metric="http.latency.p99"; profile=""; last="0"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --lab) lab="${2:?}"; shift 2 ;;
    --scenario) scenario="${2:?}"; shift 2 ;;
    --metric) metric="${2:?}"; shift 2 ;;
    --profile) profile="${2:?}"; shift 2 ;;
    --last) last="${2:?}"; shift 2 ;;
    *) echo "Unknown option '$1'." >&2; exit 2 ;;
  esac
done
[[ -n "${lab}" ]] || { echo "trend-report: set --lab NAME (or select a lab via PERFLAB_LAB)." >&2; exit 2; }
file="${repo_root}/perf-history/${lab}.jsonl"
[[ -s "${file}" ]] || { echo "trend-report: no history at ${file} -- run some scenarios first (record-trend.sh runs automatically after each measure)." >&2; exit 2; }

rows="$(jqd -r --arg s "${scenario}" --arg m "${metric}" --arg p "${profile}" '
  select( ($s=="" or .scenarioId==$s) and ($p=="" or .profile==$p) and (.metrics[$m] != null) )
  | [ (.ts|sub("T";" ")|sub("Z";"")), .gitRevision, (if .gitDirty then "*" else "" end), .scenarioId, .profile, (.metrics[$m]|tostring) ] | @tsv' < "${file}")"
[[ -n "${rows}" ]] || { echo "trend-report: no history rows for metric '${metric}'$([[ -n "${scenario}" ]] && echo ", scenario ${scenario}")$([[ -n "${profile}" ]] && echo ", profile ${profile}") in ${file}." >&2; exit 2; }

[[ "${last}" -gt 0 ]] 2>/dev/null && rows="$(printf '%s\n' "${rows}" | tail -n "${last}")"

echo "Perf trend -- lab=${lab} metric=${metric}$([[ -n "${scenario}" ]] && echo " scenario=${scenario}")$([[ -n "${profile}" ]] && echo " profile=${profile}")"
printf '%s\n' "${rows}" | awk -F'\t' '
  { v[NR]=$6+0; ts[NR]=$1; rev[NR]=$2; dirty[NR]=$3; scn[NR]=$4; prof[NR]=$5; if ($6+0>mx) mx=$6+0 }
  END{
    printf "  %-19s %-10s %-8s %-8s  %-12s %-9s %s\n","date","commit","scenario","profile","value","delta","";
    for(i=1;i<=NR;i++){
      d = (i>1) ? v[i]-v[i-1] : 0;
      dp = (i>1 && v[i-1]!=0) ? sprintf("%+.1f%%", 100*d/v[i-1]) : "-";
      barlen = (mx>0) ? int(30*v[i]/mx) : 0; bar=""; for(j=0;j<barlen;j++) bar=bar"#";
      printf "  %-19s %-8s%-2s %-8s %-8s  %-12.4g %-9s %s\n", ts[i], rev[i], dirty[i], scn[i], prof[i], v[i], dp, bar;
    }
    if (NR>1){ tot = v[NR]-v[1]; tp = (v[1]!=0)?sprintf("%+.1f%%",100*tot/v[1]):"-";
      printf "\n  net change over %d points: %+.4g (%s)  [* = uncommitted working tree]\n", NR, tot, tp; }
  }'
