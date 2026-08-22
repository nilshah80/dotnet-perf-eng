#!/usr/bin/env bash

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

require_command docker

artifact_dir="${1:?Usage: normalize-runtime.sh <artifact-directory>}"
runtime_dir="${artifact_dir}/runtime"
mkdir -p "${artifact_dir}/analysis/runtime"

while IFS= read -r trace_file; do
  artifact_relative="${trace_file#"${repo_root}/artifacts/"}"
  output_name="$(basename "${trace_file}" .nettrace)"
  docker compose -f "${repo_root}/compose.yaml" --profile tools run --rm diagnostics \
    dotnet-trace convert "/artifacts/${artifact_relative}" \
    --format Speedscope \
    --output "/artifacts/${artifact_relative%/*}/${output_name}"
done < <(find "${runtime_dir}" -type f -name '*.nettrace' -print)

while IFS= read -r gcdump_file; do
  artifact_relative="${gcdump_file#"${repo_root}/artifacts/"}"
  output_file="${artifact_dir}/analysis/runtime/$(basename "${gcdump_file}" .gcdump)-gcdump-report.txt"
  docker compose -f "${repo_root}/compose.yaml" --profile tools run --rm diagnostics \
    dotnet-gcdump report "/artifacts/${artifact_relative}" \
    > "${output_file}"
done < <(find "${runtime_dir}" -type f -name '*.gcdump' -print)

while IFS= read -r dump_file; do
  artifact_relative="${dump_file#"${repo_root}/artifacts/"}"
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
