#!/usr/bin/env bash
# Normalize captured runtime binaries into readable evidence. Delegates to the
# runtime adapter's normalize.sh (e.g. dotnet: nettrace->Speedscope, gcdump/dump
# ->text). A runtime without a normalizer is a no-op, not an error.
set -euo pipefail
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/common.sh"

artifact_dir="${1:?Usage: normalize-runtime.sh <artifact-directory>}"
[[ -d "${artifact_dir}" ]] || { echo "Artifact directory '${artifact_dir}' does not exist." >&2; exit 1; }

normalizer="${runtime_adapter_dir}/normalize.sh"
if [[ ! -f "${normalizer}" ]]; then
  echo "Runtime adapter '${runtime}' has no normalize.sh; nothing to normalize." >&2
  exit 0
fi
"${normalizer}" "${artifact_dir}"
