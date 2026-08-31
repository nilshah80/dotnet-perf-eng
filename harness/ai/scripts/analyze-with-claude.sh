#!/usr/bin/env bash
# Read-only, schema-constrained AI diagnosis of an evidence package. Produces
# analysis/diagnosis.json. Claude's JSON output is parsed with dockerized jq.
set -euo pipefail
HARNESS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# The AI phase operates on an existing evidence package: it needs the harness
# helpers (relative_to_repo, jqd), not a specific lab. Load common.sh in
# helpers-only mode so it never demands a lab selection when the repo has >1.
export PERFLAB_LAB_OPTIONAL=1
# shellcheck disable=SC1091
source "${HARNESS_ROOT}/core/lib/common.sh"
require_command claude

artifact_dir="${1:?Usage: analyze-with-claude.sh <artifact-directory>}"
manifest="${artifact_dir}/manifest.json"
facts="${artifact_dir}/facts.json"
[[ -f "${manifest}" && -f "${facts}" ]] || {
  echo "The evidence package must contain manifest.json and facts.json." >&2; exit 1; }

artifact_relative="$(relative_to_repo "${artifact_dir}")"
schema="$(cat "${harness_root}/ai/diagnosis.schema.json")"
base_prompt="$(<"${harness_root}/ai/diagnosis-prompt.md")"
scenario_id="$(jqd -r '.scenarioId' < "${manifest}")"
run_identifier="$(jqd -r '.runId' < "${manifest}")"
prompt="${base_prompt}

Evidence package: ${artifact_relative}
Scenario correlation key: ${scenario_id}
Run ID: ${run_identifier}"

mkdir -p "${artifact_dir}/analysis"
raw_output="${artifact_dir}/analysis/claude-raw.json"
diagnosis_output="${artifact_dir}/analysis/diagnosis.json"
budget="${CLAUDE_MAX_BUDGET_USD:-5}"

claude_args=(
  -p
  --permission-mode dontAsk
  --allowedTools "Read,Grep,Glob"
  --no-session-persistence
  --output-format json
  --json-schema "${schema}"
  --max-budget-usd "${budget}"
)
[[ -n "${CLAUDE_MODEL:-}" ]] && claude_args+=(--model "${CLAUDE_MODEL}")

(
  cd "${repo_root}"
  # The "--" terminator is required: several Claude CLI flags are variadic, so
  # without it the positional prompt is swallowed as another flag value.
  claude "${claude_args[@]}" -- "${prompt}" < /dev/null
) > "${raw_output}"

# Extract the structured diagnosis (foreign JSON -> jqd), falling back to .result.
if jqd -e '.structured_output != null' < "${raw_output}" >/dev/null 2>&1; then
  jqd '.structured_output' < "${raw_output}" > "${diagnosis_output}"
elif jqd -e '.result | type == "string"' < "${raw_output}" >/dev/null 2>&1; then
  jqd -r '.result' < "${raw_output}" | jqd '.' > "${diagnosis_output}"
else
  cp "${raw_output}" "${diagnosis_output}"
fi

echo "Claude diagnosis: ${diagnosis_output}"
echo "Review it before allowing edits. To open the edit phase:"
echo "${harness_root}/ai/scripts/claude-fix.sh ${artifact_dir}"
