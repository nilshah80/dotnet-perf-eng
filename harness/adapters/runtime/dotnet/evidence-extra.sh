#!/usr/bin/env bash
# dotnet runtime adapter -- optional runtime-specific evidence captured at
# measurement time (not during the perturbing diagnostic run). Invoked by
# capture-evidence.sh if present. Here: the dotnet-monitor process list.
set -euo pipefail
HARNESS_ROOT="${PERFLAB_HARNESS_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
# shellcheck disable=SC1091
source "${HARNESS_ROOT}/core/lib/common.sh"

artifact_dir="${1:?evidence-extra.sh <artifact-dir>}"
mkdir -p "${artifact_dir}/runtime"
curl -fsS --max-time 15 "${diagnostics_url}/processes" \
  > "${artifact_dir}/runtime/processes.json" || true
