#!/usr/bin/env bash
# Normalize captured runtime binaries into readable evidence. Delegates to the
# runtime adapter's normalize.sh (e.g. dotnet: nettrace->Speedscope, gcdump/dump
# ->text). A runtime without a normalizer is a no-op, not an error.
set -euo pipefail
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/common.sh"

artifact_dir="${1:?Usage: normalize-runtime.sh <artifact-directory>}"
[[ -d "${artifact_dir}" ]] || { echo "Artifact directory '${artifact_dir}' does not exist." >&2; exit 1; }

# Normalization runs inside the local Compose "diagnostics" tools container, which a
# remote target does not have (its compose file is /dev/null). The RAW capture (e.g.
# runtime/<target>/cpu.nettrace) is still valid evidence, so this is a no-op, not an
# error: convert it offline (a local lab with the diagnostics container, or
# `dotnet-trace convert` / PerfView / speedscope).
if [[ "${target_mode:-local}" == "remote" ]]; then
  echo "Remote target: skipping in-place normalization (needs the local diagnostics tools container). The raw capture under ${artifact_dir}/runtime/ is valid evidence; convert it offline." >&2
  exit 0
fi

normalizer="${runtime_adapter_dir}/normalize.sh"
if [[ ! -f "${normalizer}" ]]; then
  echo "Runtime adapter '${runtime}' has no normalize.sh; nothing to normalize." >&2
  exit 0
fi
"${normalizer}" "${artifact_dir}"
