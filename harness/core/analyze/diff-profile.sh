#!/usr/bin/env bash
# Differential CPU flame graph between two runs. For each Speedscope profile in the
# candidate run that has a same-named counterpart in the baseline run, it reports
# the methods whose share of CPU grew the most (the regression culprits) and shrank
# the most -- the step that is otherwise a manual eyeball of two flamegraphs.
#
# The differ runs INSIDE a python container (PERFLAB_PY_IMAGE, default
# python:3-alpine), fed through stdin -- exactly how jqd dockerizes jq -- so NO
# host Python is required and there are no volume-mount path issues. Both profiles
# are piped as one {"baseline":..,"candidate":..} envelope.
#
# Speedscope files come from the runtime-diagnostics phase: capture-runtime.sh
# collects *.nettrace and normalize-runtime.sh converts them to *.speedscope.json,
# so BOTH runs must have been captured --with-runtime.
#
#   diff-profile.sh <baseline-run-dir> <candidate-run-dir> [--top N]
#   diff-profile.sh <baseline.speedscope.json> <candidate.speedscope.json> [--top N]
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
differ="${here}/diff-speedscope.py"
py_image="${PERFLAB_PY_IMAGE:-python:3-alpine}"

a="${1:?diff-profile.sh <baseline> <candidate> [--top N]}"
b="${2:?diff-profile.sh <baseline> <candidate> [--top N]}"
shift 2
top="15"
[[ "${1:-}" == "--top" ]] && { top="${2:?--top needs N}"; shift 2; }

command -v docker >/dev/null 2>&1 || { echo "diff-profile: needs docker (runs the differ in ${py_image})." >&2; exit 2; }
# The differ has no $ or backticks, so it is safe to pass as a single -c argument.
script="$(cat "${differ}")"

diff_one() { # <baseline-file> <candidate-file>  -> prints the report
  { printf '{"baseline":'; cat "$1"; printf ',"candidate":'; cat "$2"; printf '}'; } \
    | MSYS_NO_PATHCONV=1 docker run --rm -i "${py_image}" python3 -c "${script}" --stdin --top "${top}"
}

# Two explicit Speedscope files: diff them directly.
if [[ -f "${a}" && -f "${b}" && "${a}" == *.json && "${b}" == *.json ]]; then
  diff_one "${a}" "${b}"
  exit 0
fi

[[ -d "${a}" && -d "${b}" ]] || { echo "diff-profile: give two run dirs, or two .speedscope.json files." >&2; exit 2; }
mkdir -p "${b}/analysis/runtime"
matched=0
while IFS= read -r cand; do
  [[ -n "${cand}" ]] || continue
  name="$(basename "${cand}")"
  bmatch="$(find "${a}" -type f -name "${name}" 2>/dev/null | head -1)"
  [[ -n "${bmatch}" ]] || { echo "diff-profile: no baseline counterpart for ${name}; skipping." >&2; continue; }
  out="${b}/analysis/runtime/diff-${name%.speedscope.json}.txt"
  echo "== ${name}: baseline ${bmatch} -> candidate ${cand} =="
  diff_one "${bmatch}" "${cand}" | tee "${out}"
  echo ""
  matched=$((matched+1))
done < <(find "${b}" -type f -name '*.speedscope.json' 2>/dev/null | sort)

[[ "${matched}" -gt 0 ]] || { echo "diff-profile: no matching Speedscope profiles between the runs. Capture both --with-runtime and normalize them first." >&2; exit 3; }
echo "Wrote ${matched} differential profile(s) under ${b}/analysis/runtime/"
