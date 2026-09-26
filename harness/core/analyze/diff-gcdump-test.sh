#!/usr/bin/env bash
# diff-gcdump.sh takes heap totals from the report's "GC Heap bytes" line: the
# per-object column is one object's size, so bytes*count underestimates a
# bucket of mixed sizes (2,012 planted 64 KiB arrays itemised at 16,408 B).
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
fail() { echo "diff-gcdump-test: $*" >&2; exit 1; }
work="$(mktemp -d "${TMPDIR:-/tmp}/diff-gcdump-test.XXXXXX")"
trap 'rm -rf "${work}"' EXIT
printf '     14,125,793  GC Heap bytes\n         32,792  GC Heap objects\n\n   Object Bytes     Count  Type\n         32,792         8  System.Byte[] (Bytes > 10K)  [Module(0x1)]\n' > "${work}/before.txt"
printf '    149,227,985  GC Heap bytes\n         67,915  GC Heap objects\n\n   Object Bytes     Count  Type\n         16,408     2,012  System.Byte[] (Bytes > 10K)  [Module(0x1)]\n' > "${work}/after.txt"
out="$(PERFLAB_LAB=scenariolab bash "${root}/harness/core/analyze/diff-gcdump.sh" "${work}/before.txt" "${work}/after.txt")"
grep -q '^#   candidate: 149227985 B$' <<< "${out}" || fail "candidate total is not the reported heap: ${out}"
grep -q 'total delta: +128.8 MiB  (+956.4%)' <<< "${out}" || fail "growth is not from the reported heap totals: ${out}"
grep -q 'System.Byte\[\]' <<< "${out}" || fail "grown type not ranked: ${out}"
# Without a heap total the itemised rows are the estimate.
printf '32792 8 System.Byte[]\n' > "${work}/rows-before.txt"
printf '32792 16 System.Byte[]\n' > "${work}/rows-after.txt"
out="$(PERFLAB_LAB=scenariolab bash "${root}/harness/core/analyze/diff-gcdump.sh" "${work}/rows-before.txt" "${work}/rows-after.txt")"
grep -q '^#   baseline : 262336 B$' <<< "${out}" || fail "row estimate fallback lost: ${out}"
echo "diff-gcdump tests passed"
