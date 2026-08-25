#!/usr/bin/env bash

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

require_command docker

# These docker invocations mix two kinds of absolute path: "${repo_root}/compose.yaml"
# is a HOST path that MSYS must rewrite to D:/... for native docker.exe, while
# "/artifacts/..." is a path INSIDE the diagnostics container that must be passed
# through untouched. Without this, dotnet-trace received
# "C:/Program Files/Git/artifacts/.../cpu.nettrace" and failed with "File does not
# exist". A blanket MSYS_NO_PATHCONV=1 cannot be used here because it would also
# stop the -f compose.yaml conversion; excluding by prefix keeps both correct.
export MSYS2_ARG_CONV_EXCL='/artifacts'

artifact_dir_arg="${1:?Usage: normalize-runtime.sh <artifact-directory>}"
if [[ ! -d "${artifact_dir_arg}" ]]; then
  echo "Artifact directory '${artifact_dir_arg}' does not exist." >&2
  exit 1
fi

# The container path below is produced by stripping the host artifacts root, so
# the argument has to be absolute before that strip can match. README documents
# the relative form (normalize-runtime.sh artifacts/runs/<run-id>), which left
# the prefix in place and asked the container for
# /artifacts/artifacts/runs/<run-id>/...; dotnet-trace then reported "File does
# not exist" for a file that was present. Resolving the argument here makes the
# relative and absolute forms behave identically, and the guard fails loudly
# rather than silently addressing a path the container cannot reach: only
# ./artifacts is mounted, at /artifacts.
artifacts_root="${repo_root}/artifacts"
artifact_dir="$(cd "${artifact_dir_arg}" && pwd)"
if [[ "${artifact_dir}" != "${artifacts_root}" && "${artifact_dir}" != "${artifacts_root}/"* ]]; then
  echo "Artifact directory must be inside ${artifacts_root} because the diagnostics container mounts only that tree at /artifacts; received '${artifact_dir}'." >&2
  exit 1
fi

runtime_dir="${artifact_dir}/runtime"
mkdir -p "${artifact_dir}/analysis/runtime"

while IFS= read -r trace_file; do
  artifact_relative="${trace_file#"${artifacts_root}/"}"
  output_name="$(basename "${trace_file}" .nettrace)"
  docker compose -f "${repo_root}/compose.yaml" --profile tools run --rm diagnostics \
    dotnet-trace convert "/artifacts/${artifact_relative}" \
    --format Speedscope \
    --output "/artifacts/${artifact_relative%/*}/${output_name}"
done < <(find "${runtime_dir}" -type f -name '*.nettrace' -print)

while IFS= read -r gcdump_file; do
  artifact_relative="${gcdump_file#"${artifacts_root}/"}"
  output_file="${artifact_dir}/analysis/runtime/$(basename "${gcdump_file}" .gcdump)-gcdump-report.txt"
  docker compose -f "${repo_root}/compose.yaml" --profile tools run --rm diagnostics \
    dotnet-gcdump report "/artifacts/${artifact_relative}" \
    > "${output_file}"
done < <(find "${runtime_dir}" -type f -name '*.gcdump' -print)

while IFS= read -r dump_file; do
  artifact_relative="${dump_file#"${artifacts_root}/"}"
  output_file="${artifact_dir}/analysis/runtime/$(basename "${dump_file}" .dmp)-dump-report.txt"
  docker compose -f "${repo_root}/compose.yaml" --profile tools run --rm diagnostics \
    dotnet-dump analyze "/artifacts/${artifact_relative}" \
    -c "clrthreads" \
    -c "clrstack -all" \
    -c "dumpheap -stat" \
    -c "exit" \
    > "${output_file}"
done < <(find "${runtime_dir}" -type f -name '*.dmp' -print)

echo "Normalized runtime evidence is under ${artifact_dir}/analysis/runtime."
