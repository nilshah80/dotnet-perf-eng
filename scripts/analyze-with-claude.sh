#!/usr/bin/env bash

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

require_command claude
require_command jq

artifact_dir="${1:?Usage: analyze-with-claude.sh <artifact-directory>}"
manifest="${artifact_dir}/manifest.json"
facts="${artifact_dir}/facts.json"
if [[ ! -f "${manifest}" || ! -f "${facts}" ]]; then
  echo "The evidence package must contain manifest.json and facts.json." >&2
  exit 1
fi

artifact_relative="$(relative_to_repo "${artifact_dir}")"
schema="$(jq -c . "${repo_root}/ai/diagnosis.schema.json")"
base_prompt="$(<"${repo_root}/ai/diagnosis-prompt.md")"
prompt="${base_prompt}

Evidence package: ${artifact_relative}
Scenario correlation key: $(jq -r '.scenarioId' "${manifest}")
Run ID: $(jq -r '.runId' "${manifest}")"

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

if [[ -n "${CLAUDE_MODEL:-}" ]]; then
  claude_args+=(--model "${CLAUDE_MODEL}")
fi

if [[ -f "${repo_root}/ai/generated-mcp.json" ]]; then
  claude_args+=(--mcp-config "${repo_root}/ai/generated-mcp.json")
fi

(
  cd "${repo_root}"
  # The "--" terminator is required: several Claude CLI flags are variadic
  # (--mcp-config <configs...>, --allowed-tools <tools...>), so without it the
  # positional prompt is swallowed as another value for the preceding flag.
  claude "${claude_args[@]}" -- "${prompt}" < /dev/null
) > "${raw_output}"

if jq -e '.structured_output != null' "${raw_output}" >/dev/null 2>&1; then
  jq '.structured_output' "${raw_output}" > "${diagnosis_output}"
elif jq -e '.result | type == "string"' "${raw_output}" >/dev/null 2>&1; then
  jq -r '.result' "${raw_output}" | jq . > "${diagnosis_output}"
else
  cp "${raw_output}" "${diagnosis_output}"
fi

echo "Claude diagnosis: ${diagnosis_output}"
echo "Review it before allowing edits. To open the edit phase:"
echo "${repo_root}/scripts/claude-fix.sh ${artifact_dir}"

