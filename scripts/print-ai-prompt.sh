#!/usr/bin/env bash

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

artifact_input="${1:?Usage: print-ai-prompt.sh <single-or-suite-evidence-directory>}"
if [[ "${artifact_input}" == /* ]]; then
  artifact_dir="${artifact_input}"
else
  artifact_dir="${repo_root}/${artifact_input#./}"
fi

if [[ ! -f "${artifact_dir}/manifest.json" || ! -f "${artifact_dir}/facts.json" ]]; then
  echo "Evidence directory must contain manifest.json and facts.json: ${artifact_dir}" >&2
  exit 1
fi

cat "${repo_root}/ai/interactive-diagnosis-prompt.md"
printf '\nEvidence directory: %s\n' "$(relative_to_repo "${artifact_dir}")"
