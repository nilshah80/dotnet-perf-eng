#!/usr/bin/env bash
# Open an interactive Claude Code edit session to implement the reviewed
# diagnosis. The only script that edits application source. The build command
# comes from the descriptor so this stays project-agnostic.
set -euo pipefail
HARNESS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091
source "${HARNESS_ROOT}/core/lib/common.sh"
require_command claude

artifact_dir="${1:?Usage: claude-fix.sh <artifact-directory>}"
diagnosis="${artifact_dir}/analysis/diagnosis.json"
[[ -f "${diagnosis}" ]] || { echo "Reviewable diagnosis not found: ${diagnosis}" >&2; exit 1; }

artifact_relative="$(relative_to_repo "${artifact_dir}")"
base_prompt="$(<"${harness_root}/ai/fix-prompt.md")"
prompt="${base_prompt}

Evidence package: ${artifact_relative}
Structured diagnosis: ${artifact_relative}/analysis/diagnosis.json
Build: from '${PERFLAB_BUILD_DIR:-.}' run: ${PERFLAB_BUILD_COMMAND:-dotnet build}"

echo "Starting an interactive Claude Code edit session. Review its changes before accepting them."
(
  cd "${repo_root}"
  claude --permission-mode acceptEdits "${prompt}"
)
