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

run_arg="${1:?gate.sh <run-dir|facts.json|stats.json> [--baseline P] [--slos P] [--threshold R] [--no-baseline] [--allow-missing] [--allow-partial] [--require-steady]}"; shift || true
baseline_override=""; slos_override=""; threshold="0.10"; use_baseline="true"; allow_missing="false"; allow_partial="false"; require_steady="false"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --baseline) baseline_override="${2:?--baseline needs a path}"; shift 2 ;;
    --slos) slos_override="${2:?--slos needs a path}"; shift 2 ;;
    --threshold) threshold="${2:?--threshold needs a value}"; shift 2 ;;
    --no-baseline) use_baseline="false"; shift ;;
    --allow-missing) allow_missing="true"; shift ;;
    --allow-partial) allow_partial="true"; shift ;;
    --require-steady) require_steady="true"; shift ;;
    *) echo "Unknown option '$1'." >&2; exit 2 ;;
  esac
done

# The candidate is a facts.json OR a run-repeat stats.json (kind=="repeat-stats"),
# resolved from a directory the same way compare-runs.sh does (stats.json wins).
if [[ -d "${run_arg}" ]]; then
  facts="${run_arg}/facts.json"
  [[ -s "${run_arg}/stats.json" ]] && facts="${run_arg}/stats.json"
  run_dir="${run_arg}"
else
  facts="${run_arg}"
  run_dir="$(dirname "${facts}")"
fi
[[ -s "${facts}" ]] || { echo "gate: no facts.json/stats.json at '${run_arg}'." >&2; exit 2; }
kind="$(jqd -r '.kind // ""' < "${facts}" 2>/dev/null || echo "")"

n_scen="$(jqd -r '(.scenarios | length) // 0' < "${facts}" 2>/dev/null || echo 0)"
[[ "${n_scen}" -gt 1 ]] && { echo "gate: '${facts}' is a ${n_scen}-scenario suite; point at .../scenarios/<id>." >&2; exit 2; }
scenario="$(jqd -r '(.scenarioId // .scenarios[0].scenarioId // "")' < "${facts}" 2>/dev/null || echo "")"
[[ -n "${scenario}" ]] || { echo "gate: could not read scenarioId from '${facts}'." >&2; exit 2; }

# Reject a partial capture unless explicitly allowed: its available metrics may meet
# the SLOs only because a required capture failed. Read facts.status (which
# capture-evidence stamps and run-repeat carries on stats.json); fall back to the
# sibling manifest; a legacy file without a status is unknown -> not captured.
status="$(jqd -r '.status // "unknown"' < "${facts}" 2>/dev/null || echo unknown)"
if [[ "${status}" == "unknown" && -d "${run_arg}" && -s "${run_arg}/manifest.json" ]]; then
  status="$(jqd -r '.status // "unknown"' < "${run_arg}/manifest.json" 2>/dev/null || echo unknown)"
fi
if [[ "${status}" != "captured" && "${allow_partial}" != "true" ]]; then
  echo "gate: capture status is '${status}' (not 'captured') -- refusing to gate a partial/unknown package whose SLOs may pass only because a capture failed. Pass --allow-partial to override." >&2
  exit 2
fi

slos_file="${slos_override:-${lab_dir}/slos.tsv}"
echo "Gate for scenario ${scenario}  (status: ${status}$([[ "${kind}" == "repeat-stats" ]] && echo ", repeat-stats median"))"
echo "  facts: ${facts}"
echo "  slos:  ${slos_file}"
echo ""

# Load every observation once (jqd is a container round-trip -- do not call per metric).
# A run-repeat stats.json stores values under .metrics.<name>.median (not .observations),
# so the absolute SLO check works on the median of a significance-aware baseline/candidate.
declare -A OBS
while IFS=$'\t' read -r n v; do [[ -n "${n}" ]] && OBS["${n}"]="${v}"; done < <(
  jqd -r 'if (.kind=="repeat-stats")
          then (.metrics // {} | to_entries[] | select(.value.median != null) | [.key,(.value.median|tostring)] | @tsv)
          else ((.observations // .scenarios[0].observations // [])[]? | select(.value != null) | [.name,(.value|tostring)] | @tsv) end' \
    < "${facts}" 2>/dev/null || true)

# --- 1. Absolute SLO checks -------------------------------------------------
fail=0; checked=0
if [[ -s "${slos_file}" ]]; then
  echo "Absolute SLOs:"
  while IFS=$'\t' read -r metric op thr; do
    [[ -n "${metric}" ]] || continue
    # An unknown operator is a config error, not a pass -- fail it.
    if [[ "${op}" != "max" && "${op}" != "min" ]]; then
      fail=$((fail+1)); checked=$((checked+1))
      printf '  %-34s %-3s %-10s  observed=%-13s FAIL (invalid op)\n' "${metric}" "${op}" "${thr}" "-"; continue
    fi
    val="${OBS[${metric}]:-}"
    if [[ -z "${val}" ]]; then
      # A configured SLO whose metric is absent must NOT silently pass (fail-open).
      # Fail it unless --allow-missing was given.
      if [[ "${allow_missing}" == "true" ]]; then
        printf '  %-34s %-3s %-10s  observed=(missing)  SKIP (--allow-missing)\n' "${metric}" "${op}" "${thr}"
      else
        fail=$((fail+1)); checked=$((checked+1))
        printf '  %-34s %-3s %-10s  observed=(missing)  FAIL (required; --allow-missing to skip)\n' "${metric}" "${op}" "${thr}"
      fi
      continue
    fi
    checked=$((checked+1))
    verdict="$(awk -v v="${val}" -v t="${thr}" -v op="${op}" 'BEGIN{
      if (op=="max") print (v+0 <= t+0) ? "PASS" : "FAIL";
      else print (v+0 >= t+0) ? "PASS" : "FAIL" }')"
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
  # Validate the BASELINE's capture status too: a partial baseline yields a
  # misleading regression verdict even when the candidate is clean.
  base_status="$(jqd -r '.status // "unknown"' < "${baseline}" 2>/dev/null || echo unknown)"
  if [[ "${base_status}" != "captured" && "${allow_partial}" != "true" ]]; then
    echo "  gate: baseline capture status is '${base_status}' (not 'captured') -- refusing to compare against a partial/unknown baseline. Re-promote a captured baseline (update-baseline.sh) or pass --allow-partial." >&2
    exit 2
  fi
  if ! "${here}/compare-runs.sh" "${baseline}" "${facts}" --threshold "${threshold}" 2>&1 | sed 's/^/  /'; then
    regressed=1
  fi
elif [[ "${use_baseline}" == "true" ]]; then
  echo ""
  echo "Regression vs baseline: none stored at ${baseline} (record one with update-baseline.sh)."
fi

# --- 3. Steady-state requirement (opt-in) -----------------------------------
# The absolute SLOs and the baseline compare a single p99/throughput number -- but
# that number is only trustworthy if the measure window was in STEADY STATE. When
# asked, refuse unless the candidate's verdict is exactly "steady".
unsteady=0
if [[ "${require_steady}" == "true" ]]; then
  echo ""
  echo "Steady-state requirement (--require-steady):"
  # Read the verdict from the CANDIDATE's OWN facts/stats -- but the stamp is only trusted
  # if its EMBEDDED runId+scenarioId match the candidate (a stamp copied from another run,
  # or a stale one, must not satisfy the gate). run-repeat carries an aggregate onto
  # stats.json. Fall back to the sibling analysis/steady-state.json only after the same
  # runId+scenario check, and only when the candidate's runId is actually known.
  cand_run="$(jqd -r '.telemetryRunId // .runId // ""' < "${facts}" 2>/dev/null || echo "")"
  # IFS=tab collapses consecutive tabs, so a missing (empty) runId would shift
  # every field after it -- per-field reads avoid that entirely.
  sv="$(jqd -r '.steadyState.verdict // ""' < "${facts}" 2>/dev/null || echo "")"
  stamp_run="$(jqd -r '.steadyState.runId // ""' < "${facts}" 2>/dev/null || echo "")"
  stamp_scen="$(jqd -r '.steadyState.scenarioId // ""' < "${facts}" 2>/dev/null || echo "")"
  ss_src="stamped facts"
  if [[ -n "${sv}" && ( -z "${cand_run}" || "${stamp_run}" != "${cand_run}" || "${stamp_scen}" != "${scenario}" ) ]]; then
    echo "  ignoring stamped steady-state: it is for run '${stamp_run}'/'${stamp_scen}', not this candidate ('${cand_run}'/'${scenario}')." >&2
    sv=""
  fi
  if [[ -z "${sv}" && -s "${run_dir}/analysis/steady-state.json" ]]; then
    ss="${run_dir}/analysis/steady-state.json"
    ss_v="$(jqd -r '.verdict // ""' < "${ss}" 2>/dev/null || echo "")"
    ss_run="$(jqd -r '.runId // ""' < "${ss}" 2>/dev/null || echo "")"
    ss_scen="$(jqd -r '.scenarioId // ""' < "${ss}" 2>/dev/null || echo "")"
    if [[ -n "${cand_run}" && "${ss_run}" == "${cand_run}" && "${ss_scen}" == "${scenario}" ]]; then
      sv="${ss_v}"; ss_src="${ss}"
    else
      echo "  ignoring ${ss}: run '${ss_run}'/'${ss_scen}' does not match candidate '${cand_run}'/'${scenario}' (or candidate runId is missing)." >&2
    fi
  fi
  case "${sv}" in
    steady) echo "  candidate verdict 'steady' (${ss_src}) -- SERVER-side steady state (windowed throughput + server p99). NOTE: client-side p99 TAIL steadiness is NOT independently verified (k6 client percentiles are not windowable); throughput tracks client MEAN latency only." ;;
    not-applicable) echo "  candidate verdict 'not-applicable' -- steady state cannot be confirmed for a non-steady (ramp/surge) profile; --require-steady needs a steady-load run. Refusing." >&2; unsteady=1 ;;
    *) echo "  candidate steady-state verdict is '${sv:-missing}' (need 'steady'; source: ${ss_src}) -- window not in steady state; run analyze/steady-state.sh or settle/lengthen the run. Refusing." >&2; unsteady=1 ;;
  esac
  # The BASELINE must be steady too, else the regression check compares against a
  # warm-up/drift-skewed reference. Its stamp is a DIFFERENT run (runId differs from the
  # candidate) but the SAME scenario, so validate the stamp is internally consistent (its
  # runId == the baseline's OWN runId) and for this scenario before trusting it.
  if [[ "${use_baseline}" == "true" && -s "${baseline}" ]]; then
    bsv="$(jqd -r '.steadyState.verdict // ""' < "${baseline}" 2>/dev/null || echo "")"
    b_stamp_run="$(jqd -r '.steadyState.runId // ""' < "${baseline}" 2>/dev/null || echo "")"
    b_stamp_scen="$(jqd -r '.steadyState.scenarioId // ""' < "${baseline}" 2>/dev/null || echo "")"
    b_ownrun="$(jqd -r '.telemetryRunId // .runId // ""' < "${baseline}" 2>/dev/null || echo "")"
    # Fail CLOSED when the baseline has no own runId: without it the stamp cannot be
    # verified, so an unverifiable "steady" stamp must NOT satisfy the requirement.
    if [[ -z "${bsv}" || "${b_stamp_scen}" != "${scenario}" || -z "${b_ownrun}" || "${b_stamp_run}" != "${b_ownrun}" ]]; then
      echo "  baseline steady-state is missing or unverifiable (verdict='${bsv:-missing}', scenario='${b_stamp_scen}', stampRun='${b_stamp_run}' vs baselineRun='${b_ownrun:-missing}') -- re-promote a steady baseline with update-baseline.sh. Refusing." >&2; unsteady=1
    elif [[ "${bsv}" == "steady" ]]; then
      echo "  baseline verdict 'steady' -- the comparison reference is steady-state."
    else
      echo "  baseline steady-state verdict is '${bsv}' (need 'steady') -- re-promote a steady baseline with update-baseline.sh. Refusing." >&2; unsteady=1
    fi
  fi
fi

# --- Verdict ----------------------------------------------------------------
echo ""
if [[ "${fail}" -gt 0 || "${regressed}" -gt 0 || "${unsteady}" -gt 0 ]]; then
  msg="GATE: FAIL -- ${fail} SLO breach(es)"
  [[ ${regressed} -gt 0 ]] && msg="${msg} + baseline regression"
  [[ ${unsteady} -gt 0 ]] && msg="${msg} + not steady-state"
  echo "${msg}." >&2
  exit 1
fi
echo "GATE: PASS -- ${checked} SLO(s) met$([[ -s "${baseline}" ]] && echo ", no regression vs baseline" || echo "")$([[ "${require_steady}" == "true" ]] && echo ", server-side steady-state confirmed" || echo "")."
