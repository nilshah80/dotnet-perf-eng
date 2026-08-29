#!/usr/bin/env bash
# redis dependency adapter -- live client sample taken mid-measurement.
set -euo pipefail
HARNESS_ROOT="${PERFLAB_HARNESS_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
# shellcheck disable=SC1091
source "${HARNESS_ROOT}/core/lib/common.sh"
artifact_dir="${1:?sample-midload.sh <artifact-dir>}"
mkdir -p "${artifact_dir}/dependencies"
compose exec -T redis redis-cli INFO clients \
  > "${artifact_dir}/dependencies/redis-clients-midload.txt" 2>/dev/null || true
