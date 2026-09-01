#!/usr/bin/env bash
# Performance gate: judge a measured run against (1) absolute SLOs from the lab's
# slos.tsv and (2) a stored baseline (statistically-significant regression, via
# compare-runs.sh). Prints a verdict table and EXITS NON-ZERO if any SLO is
# breached or a regression is detected -- so it drops straight into CI.
#
#   gate.sh <run-dir|facts.json> [--baseline P] [--slos P] [--threshold R] [--no-baseline]
#
# The run must be a single scenario (a flat package or .../scenarios/<id>); a
# multi-scenario suite has no single observation set to gate. Select the lab the
# usual way (PERFLAB_LAB / PERFLAB_CONFIG) so slos.tsv and baselines/ resolve.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${here}/../lib/common.sh"
# shellcheck disable=SC1091
source "${here}/../lib/slo-lib.sh"

run_arg="${1:?gate.sh <run-dir|facts.json> [--baseline P] [--slos P] [--threshold R] [--no-baseline]}"; shift || true
baseline_override=""; slos_override=""; threshold="0.10"; use_baseline="true"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --baseline) baseline_override="${2:?--baseline needs a path}"; shift 2 ;;
    --slos) slos_override="${2:?--slos needs a path}"; shift 2 ;;
    --threshold) threshold="${2:?--threshold needs a value}"; shift 2 ;;
    --no-baseline) use_baseline="false"; shift ;;
    *) echo "Unknown option '$1'." >&2; exit 2 ;;
  esac
done

facts="${run_arg}"; [[ -d "${run_arg}" ]] && facts="${run_arg}/facts.json"
[[ -s "${facts}" ]] || { echo "gate: no facts.json at '${run_arg}'." >&2; exit 2; }

n_scen="$(jqd -r '(.scenarios | length) // 0' < "${facts}" 2>/dev/null || echo 0)"
[[ "${n_scen}" -gt 1 ]] && { echo "gate: '${facts}' is a ${n_scen}-scenario suite; point at .../scenarios/<id>." >&2; exit 2; }
scenario="$(jqd -r '(.scenarioId // .scenarios[0].scenarioId // "")' < "${facts}" 2>/dev/null || echo "")"
[[ -n "${scenario}" ]] || { echo "gate: could not read scenarioId from '${facts}'." >&2; exit 2; }

slos_file="${slos_override:-${lab_dir}/slos.tsv}"
echo "Gate for scenario ${scenario}"
echo "  facts: ${facts}"
echo "  slos:  ${slos_file}"
echo ""

# Load every observation once (jqd is a container round-trip -- do not call per metric).
declare -A OBS
while IFS=$'\t' read -r n v; do [[ -n "${n}" ]] && OBS["${n}"]="${v}"; done < <(
  jqd -r '(.observations // .scenarios[0].observations // [])[]? | select(.value != null) | [.name,(.value|tostring)] | @tsv' < "${facts}" 2>/dev/null || true)

# --- 1. Absolute SLO checks -------------------------------------------------
fail=0; checked=0
if [[ -s "${slos_file}" ]]; then
  echo "Absolute SLOs:"
  while IFS=$'\t' read -r metric op thr; do
    [[ -n "${metric}" ]] || continue
    val="${OBS[${metric}]:-}"
    if [[ -z "${val}" ]]; then
      printf '  %-34s %-3s %-10s  observed=(missing)  SKIP\n' "${metric}" "${op}" "${thr}"; continue
    fi
    checked=$((checked+1))
    verdict="$(awk -v v="${val}" -v t="${thr}" -v op="${op}" 'BEGIN{
      if (op=="max") print (v+0 <= t+0) ? "PASS" : "FAIL";
      else if (op=="min") print (v+0 >= t+0) ? "PASS" : "FAIL";
      else print "PASS" }')"
    [[ "${verdict}" == "FAIL" ]] && fail=$((fail+1))
    printf '  %-34s %-3s %-10s  observed=%-13s %s\n' "${metric}" "${op}" "${thr}" "${val}" "${verdict}"
  done < <(slo_effective "${slos_file}" "${scenario}")
else
  echo "  (no slos.tsv found; skipping absolute SLO checks)"
fi

# --- 2. Baseline regression check ------------------------------------------
regressed=0
baseline="${baseline_override:-${lab_dir}/baselines/${scenario}.json}"
if [[ "${use_baseline}" == "true" && -s "${baseline}" ]]; then
  echo ""
  echo "Regression vs baseline (${baseline}):"
  if ! "${here}/compare-runs.sh" "${baseline}" "${facts}" --threshold "${threshold}" 2>&1 | sed 's/^/  /'; then
    regressed=1
  fi
elif [[ "${use_baseline}" == "true" ]]; then
  echo ""
  echo "Regression vs baseline: none stored at ${baseline} (record one with update-baseline.sh)."
fi

# --- Verdict ----------------------------------------------------------------
echo ""
if [[ "${fail}" -gt 0 || "${regressed}" -gt 0 ]]; then
  echo "GATE: FAIL -- ${fail} SLO breach(es)$([[ ${regressed} -gt 0 ]] && echo " + baseline regression")." >&2
  exit 1
fi
echo "GATE: PASS -- ${checked} SLO(s) met$([[ -s "${baseline}" ]] && echo ", no regression vs baseline" || echo "")."
