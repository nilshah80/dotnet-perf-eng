#!/usr/bin/env bash
# Promote a measured run to the scenario's stored baseline
# (labs/<lab>/baselines/<scenario>.json), which gate.sh then checks future runs
# against for regression. A run-repeat stats.json (carrying per-metric spread) is
# preferred over a single-run facts.json when present, because it makes the
# downstream regression check significance-aware instead of a bare relative delta.
#
#   update-baseline.sh <run-dir|facts.json|stats.json> [--scenario ID]
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${here}/../lib/common.sh"

run_arg="${1:?update-baseline.sh <run-dir|facts.json|stats.json> [--scenario ID] [--allow-partial]}"; shift || true
scenario_override=""; allow_partial="false"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --scenario) scenario_override="${2:?--scenario needs an id}"; shift 2 ;;
    --allow-partial) allow_partial="true"; shift ;;
    *) echo "Unknown option '$1'." >&2; exit 2 ;;
  esac
done

if [[ -d "${run_arg}" ]]; then
  src=""
  [[ -s "${run_arg}/stats.json" ]] && src="${run_arg}/stats.json"
  [[ -z "${src}" && -s "${run_arg}/facts.json" ]] && src="${run_arg}/facts.json"
  [[ -n "${src}" ]] || { echo "update-baseline: no stats.json or facts.json under '${run_arg}'." >&2; exit 2; }
else
  src="${run_arg}"; [[ -s "${src}" ]] || { echo "update-baseline: not found '${src}'." >&2; exit 2; }
fi

# Never promote a partial/unknown capture to a baseline: gate.sh would then compare
# future runs against misleading evidence. Read src.status, fall back to a sibling
# manifest; require --allow-partial to override.
src_status="$(jqd -r '.status // "unknown"' < "${src}" 2>/dev/null || echo unknown)"
if [[ "${src_status}" == "unknown" && -d "${run_arg}" && -s "${run_arg}/manifest.json" ]]; then
  src_status="$(jqd -r '.status // "unknown"' < "${run_arg}/manifest.json" 2>/dev/null || echo unknown)"
fi
if [[ "${src_status}" != "captured" && "${allow_partial}" != "true" ]]; then
  echo "update-baseline: refusing to promote a '${src_status}' (not 'captured') package as a baseline. Promote a captured run, or pass --allow-partial to override." >&2
  exit 2
fi

scenario="${scenario_override}"
[[ -z "${scenario}" ]] && scenario="$(jqd -r '(.scenarioId // .scenarios[0].scenarioId // "")' < "${src}" 2>/dev/null || echo "")"
[[ -n "${scenario}" ]] || { echo "update-baseline: could not determine scenario; pass --scenario ID." >&2; exit 2; }

mkdir -p "${lab_dir}/baselines"
dest="${lab_dir}/baselines/${scenario}.json"
cp "${src}" "${dest}"
kind="$([[ "$(basename "${src}")" == stats.json ]] && echo "repeat-stats (significance-aware)" || echo "single-run facts")"
echo "Baseline for ${scenario} <- ${src}  [${kind}]"
echo "  wrote ${dest}"
echo "  commit this file so gate.sh checks future runs against it."
