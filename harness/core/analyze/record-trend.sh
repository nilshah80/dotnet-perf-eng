#!/usr/bin/env bash
# Append a measured run's key facts to the committed cross-commit perf history
# (perf-history/<lab>.jsonl), so trend-report.sh can show latency / throughput /
# error / efficiency per scenario ACROSS commits over time -- catching the slow
# creep a single run cannot. One append-only JSON line per run.
#
#   record-trend.sh <run-dir|facts.json>
#
# Auto-invoked (best-effort) by run-scenario.sh after a measure run; skip with
# PERFLAB_RECORD_TREND=0. Each line carries the git revision, scenario, profile and
# generator so the report can filter to a canonical scenario/profile.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${here}/../lib/common.sh"

run_arg="${1:?record-trend.sh <run-dir|facts.json>}"
facts="${run_arg}"; manifest=""
if [[ -d "${run_arg}" ]]; then facts="${run_arg}/facts.json"; manifest="${run_arg}/manifest.json"; fi
[[ -s "${facts}" ]] || { echo "record-trend: no facts.json at '${run_arg}'." >&2; exit 2; }

# Skip a multi-scenario suite package (its children are recorded individually).
n_scen="$(jqd -r '(.scenarios | length) // 0' < "${facts}" 2>/dev/null || echo 0)"
[[ "${n_scen}" -gt 1 ]] && { echo "record-trend: '${facts}' is a suite; record its per-scenario children instead." >&2; exit 0; }

lab="${PERFLAB_PROJECT:-unknown}"
git_rev="$(git -C "${repo_root}" rev-parse --short HEAD 2>/dev/null || echo unknown)"
# --porcelain catches staged AND unstaged AND untracked changes; `git diff --quiet`
# would miss staged/untracked and mislabel a non-HEAD working tree as clean.
git_dirty="false"; [[ -n "$(git -C "${repo_root}" status --porcelain 2>/dev/null)" ]] && git_dirty="true"
ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
profile="steady"; generator=""; status="unknown"
[[ -s "${manifest}" ]] && {
  profile="$(jqd -r '.workload.profile // "steady"' < "${manifest}" 2>/dev/null || echo steady)"
  generator="$(jqd -r '.workload.loadGenerator // ""' < "${manifest}" 2>/dev/null || echo "")"
  # Capture status (captured|partial): a partial run must be visibly marked in
  # history, not silently trended as if it were clean.
  status="$(jqd -r '.status // "unknown"' < "${manifest}" 2>/dev/null || echo unknown)"
}

mkdir -p "${repo_root}/perf-history"
out="${repo_root}/perf-history/${lab}.jsonl"
line="$(jqd -c --arg ts "${ts}" --arg rev "${git_rev}" --arg lab "${lab}" \
             --arg prof "${profile}" --arg gen "${generator}" --arg status "${status}" --argjson dirty "${git_dirty}" '
  { ts:$ts, gitRevision:$rev, gitDirty:$dirty, captureStatus:$status, lab:$lab, profile:$prof,
    loadGenerator:( ($gen | select(. != "")) // (.loadGenerator // .scenarios[0].loadGenerator // "") ),
    runId:(.runId // .scenarios[0].runId // ""),
    scenarioId:(.scenarioId // .scenarios[0].scenarioId // ""),
    metrics:(reduce ((.observations // .scenarios[0].observations // [])[]?) as $o
             ({}; if ($o.value|type)=="number" then .[$o.name]=$o.value else . end)) }' < "${facts}")"
[[ -n "${line}" && "${line}" != "null" ]] || { echo "record-trend: could not build a trend line from ${facts}." >&2; exit 2; }
printf '%s\n' "${line}" >> "${out}"
echo "Recorded trend: $(printf '%s' "${line}" | jqd -r '"\(.scenarioId) @ \(.gitRevision) (\(.profile)/\(.loadGenerator))"' 2>/dev/null) -> ${out}" >&2
