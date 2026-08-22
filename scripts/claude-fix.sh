#!/usr/bin/env bash

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

require_command claude

artifact_dir="${1:?Usage: claude-fix.sh <artifact-directory>}"
diagnosis="${artifact_dir}/analysis/diagnosis.json"
if [[ ! -f "${diagnosis}" ]]; then
  echo "Reviewable diagnosis not found: ${diagnosis}" >&2
  exit 1
fi

artifact_relative="$(relative_to_repo "${artifact_dir}")"
base_prompt="$(<"${repo_root}/ai/fix-prompt.md")"
prompt="${base_prompt}

Evidence package: ${artifact_relative}
Structured diagnosis: ${artifact_relative}/analysis/diagnosis.json"

echo "Starting an interactive Claude Code edit session. Review its changes before accepting them."
(
  cd "${repo_root}"
  claude --permission-mode acceptEdits "${prompt}"
)

