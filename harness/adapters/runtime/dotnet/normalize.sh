#!/usr/bin/env bash
# dotnet runtime adapter -- normalize captured binaries into readable evidence.
# Invoked by harness/core/capture/normalize-runtime.sh. Uses the diagnostics tools
# container (built from ./diagnostics/Dockerfile via the compose "diagnostics"
# service) to convert:
#   *.nettrace -> Speedscope JSON  (CPU flamegraph, portable)
#   *.gcdump   -> text report
#   *.dmp      -> text report (threads, stacks, heap stats)
set -euo pipefail
HARNESS_ROOT="${PERFLAB_HARNESS_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)}"
# shellcheck disable=SC1091
source "${HARNESS_ROOT}/core/lib/common.sh"

# "/artifacts" is a container path (the diagnostics service mounts the artifacts
# tree there); compose_file is a host path. Exclude only /artifacts from MSYS
# argument conversion so dotnet-trace receives the container path unchanged and
# a blanket opt-out does not also break the -f compose.yaml host path.
export MSYS2_ARG_CONV_EXCL='/artifacts'

artifact_dir_arg="${1:?normalize.sh <artifact-dir>}"
artifact_dir="$(cd "${artifact_dir_arg}" && pwd)"
if [[ "${artifact_dir}" != "${artifacts_root}" && "${artifact_dir}" != "${artifacts_root}/"* ]]; then
  echo "Artifact directory must be inside ${artifacts_root} because the diagnostics container mounts only that tree at /artifacts; received '${artifact_dir}'." >&2
  exit 1
fi

runtime_dir="${artifact_dir}/runtime"
mkdir -p "${artifact_dir}/analysis/runtime"
normalization_failures=0

write_capture_normalization() { # source status output reason
  local source="$1" status="$2" output="$3" reason="$4" directory
  [[ "${source}" == "${runtime_dir}/captures/"* ]] || return 0
  directory="${source%/*}"
  printf '{"source":"%s","status":"%s","outputs":%s,"reason":"%s"}\n' \
    "$(json_escape "${source#"${artifact_dir}/"}")" "${status}" \
    "$([[ -n "${output}" ]] && printf '["%s"]' "$(json_escape "${output#"${artifact_dir}/"}")" || printf '[]')" \
    "$(json_escape "${reason}")" > "${directory}/normalization.json"
}

# NB: every `compose ... run` below redirects stdin from /dev/null. Without it a
# `docker compose run` inside a `while read` loop fed by `< <(find ...)` consumes the
# REST of find's output as its own stdin, so the loop runs only ONCE -- which silently
# normalized just one of the gcdump diagnostic's before/after pair (it always captures
# both). The tools read their input FILE from the argument, never stdin, so detaching
# stdin is safe and simply stops the loop's pipe from being eaten.
while IFS= read -r trace_file; do
  rel="${trace_file#"${artifacts_root}/"}"
  name="$(basename "${trace_file}" .nettrace)"
  normalized="${trace_file%/*}/${name}.speedscope.json"
  if compose --profile tools run --rm diagnostics \
    dotnet-trace convert "/artifacts/${rel}" --format Speedscope \
    --output "/artifacts/${rel%/*}/${name}" </dev/null; then
    write_capture_normalization "${trace_file}" captured "${normalized}" ""
  else
    echo "Failed to normalize ${trace_file}; continuing with other campaign captures." >&2
    write_capture_normalization "${trace_file}" partial "" "dotnet-trace conversion failed"
    normalization_failures=$((normalization_failures + 1))
  fi
done < <(find "${runtime_dir}" -type f -name '*.nettrace' -print)

while IFS= read -r gcdump_file; do
  rel="${gcdump_file#"${artifacts_root}/"}"
  analysis_out="${artifact_dir}/analysis/runtime/$(basename "${gcdump_file}" .gcdump)-gcdump-report.txt"
  out="${analysis_out}"
  [[ "${gcdump_file}" == "${runtime_dir}/captures/"* ]] && out="${gcdump_file%/*}/report.txt"
  if compose --profile tools run --rm diagnostics \
    dotnet-gcdump report "/artifacts/${rel}" </dev/null > "${out}"; then
    [[ "${out}" == "${analysis_out}" ]] || cp "${out}" "${analysis_out}"
    write_capture_normalization "${gcdump_file}" captured "${out}" ""
  else
    rm -f "${out}"
    echo "Failed to normalize ${gcdump_file}; continuing with other campaign captures." >&2
    write_capture_normalization "${gcdump_file}" partial "" "dotnet-gcdump report failed"
    normalization_failures=$((normalization_failures + 1))
  fi
done < <(find "${runtime_dir}" -type f -name '*.gcdump' -print)

while IFS= read -r dump_file; do
  rel="${dump_file#"${artifacts_root}/"}"
  analysis_out="${artifact_dir}/analysis/runtime/$(basename "${dump_file}" .dmp)-dump-report.txt"
  out="${analysis_out}"
  [[ "${dump_file}" == "${runtime_dir}/captures/"* ]] && out="${dump_file%/*}/report.txt"
  if compose --profile tools run --rm diagnostics \
    dotnet-dump analyze "/artifacts/${rel}" \
    -c "clrthreads" -c "clrstack -all" -c "dumpheap -stat" -c "exit" </dev/null > "${out}"; then
    [[ "${out}" == "${analysis_out}" ]] || cp "${out}" "${analysis_out}"
    write_capture_normalization "${dump_file}" captured "${out}" ""
  else
    rm -f "${out}"
    echo "Failed to normalize ${dump_file}; continuing with other campaign captures." >&2
    write_capture_normalization "${dump_file}" partial "" "dotnet-dump analysis failed"
    normalization_failures=$((normalization_failures + 1))
  fi
done < <(find "${runtime_dir}" -type f -name '*.dmp' -print)

echo "Normalized runtime evidence is under ${artifact_dir}/analysis/runtime."
if (( normalization_failures > 0 )); then
  echo "Runtime normalization completed partially (${normalization_failures} failed capture(s))." >&2
  exit 2
fi
