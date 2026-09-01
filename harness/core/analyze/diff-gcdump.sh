#!/usr/bin/env bash
# Differential managed-heap analysis between two gcdumps -- the memory counterpart of
# diff-profile.sh. It answers "which TYPE grew", turning analyze-trends.sh's "the heap
# is growing" into an attributed leak.
#
# Unlike diff-profile (Speedscope self-time is genuinely complex, so its differ is
# Python), a `dotnet-gcdump report` is a plain `<bytes> <count>  <Type>` text table, so
# this diffs it with awk + sort -- host-native, no container, matching the rest of the
# analyze/ scripts (find-knee, steady-state, bottleneck).
#
# Three modes:
#   diff-gcdump.sh <run-dir>                      before.gcdump vs after.gcdump of the
#                                                 SAME process (the gcdump diagnostic
#                                                 brackets the load with two snapshots,
#                                                 so this is TRUE in-process growth --
#                                                 the leak-attribution default).
#   diff-gcdump.sh <baseline-run> <candidate-run> candidate's heap vs baseline's, matched
#                                                 by report name (cross-commit/config).
#   diff-gcdump.sh <base-report.txt> <cand.txt>   two explicit report files.
#
# Reports come from the dotnet adapter's normalize.sh (dotnet-gcdump report ->
# analysis/runtime/<name>-gcdump-report.txt), so the run(s) must have been captured
# `capture-runtime.sh <dir> gcdump` and normalized.
#
#   diff-gcdump.sh <a> [<b>] [--top N]
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${here}/../lib/common.sh"

a="${1:?diff-gcdump.sh <run-dir> | <baseline-run> <candidate-run> | <base.txt> <cand.txt> [--top N]}"; shift || true
b=""
[[ $# -gt 0 && "${1:-}" != --* ]] && { b="$1"; shift; }
top="15"
[[ "${1:-}" == "--top" ]] && { top="${2:?--top needs N}"; shift 2; }
[[ "${top}" =~ ^[1-9][0-9]*$ ]] || { echo "diff-gcdump: --top needs a positive integer." >&2; exit 2; }

# A data row of `dotnet-gcdump report` is `<bytes> <count>  <Type>` (N0 thousands
# separators, right-aligned). Fields split on whitespace: $1=bytes, $2=count, and the
# type is $3..$NF rejoined (generic/array names contain spaces). The header
# ("Object Bytes  Count  Type"), the "Report for ..." title and "====" rules all have a
# non-numeric $1 and are skipped. Portable awk only (runs on macOS/Linux/MSYS) -- no
# gawk match()-array or asort.
_human_awk='function human(n,   s,a,i,U){ s=(n<0?"-":"+"); a=(n<0?-n:n);
  split("B KiB MiB GiB TiB",U," ");
  for(i=1;i<=5;i++){ if(a<1024||i==5){ return (i==1?sprintf("%s%d %s",s,a,U[i]):sprintf("%s%.1f %s",s,a,U[i])) } a/=1024 } }'

diff_one() { # <baseline-report> <candidate-report> [header]
  local base="$1" cand="$2"
  [[ -s "${base}" ]] || { echo "diff-gcdump: missing/empty report ${base}" >&2; return 1; }
  [[ -s "${cand}" ]] || { echo "diff-gcdump: missing/empty report ${cand}" >&2; return 1; }
  [[ -n "${3:-}" ]] && echo "== $3 =="

  # One awk pass over both reports (FNR==1 flips the file counter): sum retained bytes
  # and count per type on each side, then emit per-type diff rows
  #   deltaBytes<TAB>deltaCount<TAB>baseBytes<TAB>candBytes<TAB>newFlag<TAB>type
  local rows
  rows="$(awk '
    FNR==1 { fn++ }
    { b=$1; c=$2; gsub(/,/,"",b); gsub(/,/,"",c);
      # A data row has TWO leading integers (bytes, count). This also excludes the
      # report header ("Object Bytes  Count  Type") and its "GC Heap bytes"/"objects"
      # summary lines (numeric $1 but a non-numeric $2).
      if (!(b ~ /^[0-9]+$/ && c ~ /^[0-9]+$/ && NF>=3)) next;
      t=$3; for(i=4;i<=NF;i++) t=t" "$i;
      # dotnet-gcdump report splits ONE type across size buckets and tags each with the
      # owning module: "System.Byte[] (Bytes > 1M)  [Module(0x..)]". Strip both so all
      # buckets/modules of a base type aggregate -- otherwise a type shifting buckets
      # between before/after shows spurious growth in one line and shrink in another.
      sub(/[ ]+\[Module\(0x[0-9a-fA-F]+\)\][ ]*$/, "", t);
      sub(/[ ]+\(Bytes [^)]*\)[ ]*$/, "", t);
      sub(/[ ]+$/, "", t);
      # "Object Bytes" is the PER-OBJECT size of that type+bucket (every object in a
      # "Bytes > 10K" row is itself >10K), so RETAINED bytes for the row = bytes * count.
      # Summing bytes alone undercounts by ~count -- verified: sum(bytes*count) matches
      # the report "GC Heap bytes" header (148,650,968 vs 148,888,072), sum(bytes) is
      # ~70x too small (2,109,916).
      if (fn==1) { bB[t]+=b*c; bC[t]+=c } else { cB[t]+=b*c; cC[t]+=c }
      all[t]=1 }
    END { for (t in all) {
      # newf FIRST: referencing bB[t] in an expression auto-vivifies the key, which
      # would make (t in bB) wrongly true for a candidate-only type.
      newf=((t in bB)?0:1);
      db=(cB[t]+0)-(bB[t]+0); dc=(cC[t]+0)-(bC[t]+0);
      printf "%d\t%d\t%d\t%d\t%d\t%s\n", db, dc, bB[t]+0, cB[t]+0, newf, t } }' \
    "${base}" "${cand}")"

  if [[ -z "${rows}" ]]; then
    echo "  Could not parse any type rows from the reports (expected '<bytes> <count>  <Type>')."
    echo "  Show a few lines so the parser can be adjusted:  sed -n '1,20p' ${cand}" >&2
    return 0
  fi

  # Totals + percent.
  local btot ctot
  btot="$(awk '{b=$1;c=$2; gsub(/,/,"",b); gsub(/,/,"",c); if (b ~ /^[0-9]+$/ && c ~ /^[0-9]+$/ && NF>=3) s+=b*c} END{print s+0}' "${base}")"
  ctot="$(awk '{b=$1;c=$2; gsub(/,/,"",b); gsub(/,/,"",c); if (b ~ /^[0-9]+$/ && c ~ /^[0-9]+$/ && NF>=3) s+=b*c} END{print s+0}' "${cand}")"
  awk -v bt="${btot}" -v ct="${ctot}" "${_human_awk}"'
    BEGIN{ d=ct-bt; pct=(bt>0? d/bt*100 : 0);
      printf "# Differential managed heap (retained bytes per type)\n";
      printf "#   baseline : %d B\n", bt;
      printf "#   candidate: %d B\n", ct;
      printf "#   total delta: %s  (%+.1f%%)\n\n", human(d), pct }'

  local fmt='function human(n,   s,a,i,U){ s=(n<0?"-":"+"); a=(n<0?-n:n); split("B KiB MiB GiB TiB",U," "); for(i=1;i<=5;i++){ if(a<1024||i==5){ return (i==1?sprintf("%s%d %s",s,a,U[i]):sprintf("%s%.1f %s",s,a,U[i])) } a/=1024 } }
    { t=$6; for(i=7;i<=NF;i++) t=t" "$i; if(length(t)>90) t=substr(t,1,90);
      printf "  %12s  count %+d   %d B -> %d B   %s\n", human($1), $2, $3, $4, t }'

  echo "Top ${top} GROWN types (leak suspects):"
  echo "${rows}" | awk -F'\t' '$1>0' | sort -t"$(printf '\t')" -k1,1 -rn | head -n "${top}" | awk -F'\t' "${fmt}"
  echo "${rows}" | awk -F'\t' '$1>0' | grep -q . || echo "  (none)"

  echo ""
  echo "Top ${top} type(s) NEW in candidate (retained from zero):"
  echo "${rows}" | awk -F'\t' '$5==1 && $1>0' | sort -t"$(printf '\t')" -k1,1 -rn | head -n "${top}" | awk -F'\t' "${fmt}"
  echo "${rows}" | awk -F'\t' '$5==1 && $1>0' | grep -q . || echo "  (none)"

  echo ""
  echo "Top ${top} SHRUNK types:"
  echo "${rows}" | awk -F'\t' '$1<0' | sort -t"$(printf '\t')" -k1,1 -n | head -n "${top}" | awk -F'\t' "${fmt}"
  echo "${rows}" | awk -F'\t' '$1<0' | grep -q . || echo "  (none)"
}

find_report() { find "$1" -type f -name "$2-gcdump-report.txt" 2>/dev/null | head -1; }

# --- mode 3: two explicit report files -------------------------------------
if [[ -f "${a}" && -n "${b}" && -f "${b}" && "${a}" == *.txt && "${b}" == *.txt ]]; then
  diff_one "${a}" "${b}"
  exit 0
fi

# --- mode 1: single run dir -> before vs after (in-process growth) ----------
if [[ -d "${a}" && -z "${b}" ]]; then
  before="$(find_report "${a}" before)"; after="$(find_report "${a}" after)"
  if [[ -z "${before}" || -z "${after}" ]]; then
    echo "diff-gcdump: need both before- and after-gcdump-report.txt under ${a}/analysis/runtime." >&2
    echo "  Capture + normalize a gcdump first:  ${harness_core_dir}/capture/capture-runtime.sh ${a} gcdump   then   ${harness_core_dir}/capture/normalize-runtime.sh ${a}" >&2
    exit 3
  fi
  echo "In-process heap growth during the load (before -> after, same process):"
  mkdir -p "${a}/analysis/runtime"
  out="${a}/analysis/runtime/diff-gcdump-before-after.txt"
  diff_one "${before}" "${after}" | tee "${out}"
  echo ""; echo "Wrote ${out}"
  exit 0
fi

# --- mode 2: two run dirs -> match reports by name --------------------------
if [[ -d "${a}" && -n "${b}" && -d "${b}" ]]; then
  mkdir -p "${b}/analysis/runtime"
  matched=0
  while IFS= read -r cand; do
    [[ -n "${cand}" ]] || continue
    name="$(basename "${cand}")"
    base="$(find "${a}" -type f -name "${name}" 2>/dev/null | head -1)"
    [[ -n "${base}" ]] || { echo "diff-gcdump: no baseline counterpart for ${name}; skipping." >&2; continue; }
    out="${b}/analysis/runtime/diff-${name%-gcdump-report.txt}-vs-baseline.txt"
    diff_one "${base}" "${cand}" "${name}: baseline ${base} -> candidate ${cand}" | tee "${out}"
    echo ""
    matched=$((matched+1))
  done < <(find "${b}" -type f -name '*-gcdump-report.txt' 2>/dev/null | sort)
  [[ "${matched}" -gt 0 ]] || { echo "diff-gcdump: no gcdump reports under ${b}/analysis/runtime. Capture + normalize a gcdump in both runs first." >&2; exit 3; }
  echo "Wrote ${matched} differential heap report(s) under ${b}/analysis/runtime/"
  exit 0
fi

echo "diff-gcdump: give one run dir (before vs after), two run dirs, or two *-gcdump-report.txt files." >&2
exit 2
