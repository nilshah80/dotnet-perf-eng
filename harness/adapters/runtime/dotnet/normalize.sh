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
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../core/lib" && pwd)/sensitive-evidence.sh"

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

# Non-fatal normalization outcomes that a single-kind capture has no per-stage
# normalization.json to carry. Written as runtime/normalization-limitations.json
# and merged into the package's normalization record by normalize-runtime.sh.
normalization_limitations=()
note_normalization_limitation() { # <source> <reason>
  normalization_limitations+=("$(json_escape "${1#"${artifact_dir}/"}"): $(json_escape "$2")")
}
write_normalization_limitations() {
  local file="${artifact_dir}/runtime/normalization-limitations.json" entry separator=""
  if (( ${#normalization_limitations[@]} == 0 )); then
    rm -f "${file}"
    return 0
  fi
  {
    printf '['
    for entry in "${normalization_limitations[@]}"; do
      printf '%s"%s"' "${separator}" "${entry}"
      separator=","
    done
    printf ']\n'
  } > "${file}"
}

write_capture_normalization() { # source status output reason
  local source="$1" status="$2" output="$3" reason="$4" directory
  [[ "${source}" == "${runtime_dir}/captures/"* ]] || return 0
  directory="${source%/*}"
  printf '{"source":"%s","status":"%s","outputs":%s,"reason":"%s"}\n' \
    "$(json_escape "${source#"${artifact_dir}/"}")" "${status}" \
    "$([[ -n "${output}" ]] && printf '["%s"]' "$(json_escape "${output#"${artifact_dir}/"}")" || printf '[]')" \
    "$(json_escape "${reason}")" > "${directory}/normalization.json"
}

# A profiler/GC-dump interaction can preserve the byte and count columns while
# replacing managed types with UNKNOWN 0x…. Treat materially degraded heap
# metadata as failed normalization: one resolved row cannot make a mostly
# unnamed type-attributed retention report successful evidence.
gcdump_report_has_usable_type_metadata() {
  awk '
    function numeric(value) {
      gsub(/,/, "", value)
      return value ~ /^[0-9]+$/
    }
    {
      if (NF < 3 || !numeric($1) || !numeric($2)) next
      object_bytes = $1
      object_count = $2
      gsub(/,/, "", object_bytes)
      gsub(/,/, "", object_count)
      retained = (object_bytes + 0) * (object_count + 0)
      rows++
      retained_bytes += retained
      type = $3
      for (field = 4; field <= NF; field++) type = type " " $field
      if (tolower(type) !~ /^unknown[[:space:]]+0x[[:xdigit:]]+([[:space:]]|$)/) {
        named_rows++
        named_retained_bytes += retained
      }
    }
    END {
      if (rows == 0 || named_rows * 100 < rows * 95) exit 1
      if (retained_bytes > 0 && named_retained_bytes * 100 < retained_bytes * 95) exit 1
      exit 0
    }
  ' "$1"
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
    # The readable answer beside the flame graph: the methods that held the CPU
    # (dotnet-trace's CPU_TIME attributed to its frame), self and inclusive.
    if trace_python="$(perflab_python)"; then
      "${trace_python}" "${harness_core_dir}/analyze/diff-speedscope.py" --report "${normalized}" --top 25 \
        > "${artifact_dir}/analysis/runtime/$(basename "$(dirname "${trace_file}")")-${name}-trace-top.txt" \
        || echo "WARNING: the on-CPU method report for ${trace_file} failed; the Speedscope file is still valid." >&2
    fi
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
    if gcdump_report_has_usable_type_metadata "${out}"; then
      [[ "${out}" == "${analysis_out}" ]] || cp "${out}" "${analysis_out}"
      write_capture_normalization "${gcdump_file}" captured "${out}" ""
    else
      rm -f "${out}" "${analysis_out}"
      echo "GC dump ${gcdump_file} has insufficient named type coverage; refusing a successful-looking heap report." >&2
      write_capture_normalization "${gcdump_file}" failed "" "GC dump type metadata is unavailable (fewer than 95% of parsed type rows or retained bytes have managed type names)"
      normalization_failures=$((normalization_failures + 1))
    fi
  else
    rm -f "${out}"
    echo "Failed to normalize ${gcdump_file}; continuing with other campaign captures." >&2
    write_capture_normalization "${gcdump_file}" partial "" "dotnet-gcdump report failed"
    normalization_failures=$((normalization_failures + 1))
  fi
done < <(find "${runtime_dir}" -type f -name '*.gcdump' -print)

# A dump is analysed where it is retained: the capture moved it to the sensitive
# store and left a pointer. A dump still inside the package (captured before
# dumps left packages) is analysed in place and then retained the same way.
# The list is taken before the loop because retaining a dump writes a pointer
# the same find would otherwise pick up.
dump_list="$(find "${runtime_dir}" -type f \( -name '*.dmp' -o -name '*.dmp.retained.json' \) -print)"
while IFS= read -r dump_file; do
  [[ -n "${dump_file}" ]] || continue
  retained_pointer=""
  if [[ "${dump_file}" == *.retained.json ]]; then
    retained_pointer="${dump_file}"
    dump_file="${dump_file%.retained.json}"
    rel="$(jqd -r '.retainedPath // empty' < "${retained_pointer}")"
    if [[ -z "${rel}" || "${rel}" != sensitive/* || ! -f "${artifacts_root}/${rel}" ]]; then
      echo "The retained dump for ${dump_file#"${artifact_dir}/"} is no longer in the sensitive store; nothing to analyse." >&2
      write_capture_normalization "${dump_file}" partial "" "the retained dump is no longer in the sensitive store"
      normalization_failures=$((normalization_failures + 1))
      continue
    fi
  else
    rel="${dump_file#"${artifacts_root}/"}"
  fi
  analysis_out="${artifact_dir}/analysis/runtime/$(basename "${dump_file}" .dmp)-dump-report.txt"
  out="${analysis_out}"
  [[ "${dump_file}" == "${runtime_dir}/captures/"* ]] && out="${dump_file%/*}/report.txt"
  # clrthreads/clrstack/dumpheap describe threads and the heap and are the
  # hang path; they run alone so their listing survives whatever the extended
  # commands do. dumpasync adds the async state machines a hang hides behind,
  # syncblk names the thread that holds each contended monitor and how many
  # wait on it, and analyzeoom explains a managed OutOfMemory (it says nothing
  # about a container OOM kill, which is a cgroup event the environment
  # capture records instead). The extended set runs as a second invocation:
  # if it fails, the thread and heap report is kept and the failure is
  # recorded on the normalization, not paid for with the whole file.
  if compose --profile tools run --rm diagnostics \
    dotnet-dump analyze "/artifacts/${rel}" \
    -c "clrthreads" -c "clrstack -all" -c "dumpheap -stat" -c "exit" </dev/null > "${out}"; then
    extended_reason=""
    if compose --profile tools run --rm diagnostics \
      dotnet-dump analyze "/artifacts/${rel}" \
      -c "dumpasync" -c "syncblk" -c "analyzeoom" -c "exit" </dev/null > "${out}.extended"; then
      { printf '\n=== extended SOS: dumpasync, syncblk, analyzeoom ===\n'; cat "${out}.extended"; } >> "${out}"
    else
      extended_reason="extended SOS commands (dumpasync, syncblk, analyzeoom) failed; the thread and heap listing is retained"
      echo "WARNING: ${extended_reason}: ${dump_file}" >&2
      # The retained report says so itself, and the package metadata carries it
      # for the single-kind path, whose capture has no per-stage record.
      printf '\n=== extended SOS: dumpasync, syncblk, analyzeoom ===\nFAILED: %s\n' "${extended_reason}" >> "${out}"
      note_normalization_limitation "${dump_file}" "${extended_reason}"
    fi
    rm -f "${out}.extended"
    [[ "${out}" == "${analysis_out}" ]] || cp "${out}" "${analysis_out}"
    write_capture_normalization "${dump_file}" captured "${out}" "${extended_reason}"
  else
    rm -f "${out}"
    echo "Failed to normalize ${dump_file}; continuing with other campaign captures." >&2
    write_capture_normalization "${dump_file}" partial "" "dotnet-dump analysis failed"
    normalization_failures=$((normalization_failures + 1))
  fi
  if [[ -z "${retained_pointer}" ]] && ! retain_sensitive_file "${dump_file}" process-memory; then
    normalization_failures=$((normalization_failures + 1))
  fi
done <<< "${dump_list}"

write_normalization_limitations
echo "Normalized runtime evidence is under ${artifact_dir}/analysis/runtime."
if (( normalization_failures > 0 )); then
  echo "Runtime normalization completed partially (${normalization_failures} failed capture(s))." >&2
  exit 2
fi
