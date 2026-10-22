#!/usr/bin/env bash
# Tab-delimited records with empty fields must not be read with `IFS=$'\t' read`.
#
# Bash treats tab as IFS WHITESPACE, so consecutive tabs collapse into a single
# delimiter and every field after an empty one shifts left. This is not a corner
# case: every GET workload has an empty body, so the diagnostic replay envelope
# was routinely rebuilt out of the wrong values -- `body=true`, `dataset=64`,
# `conns=''` -- and the diagnostic replayed a workload that was never measured.
#
# The bug is silent, so a guard is worth more than a fix: this both proves the
# helper is correct and refuses the pattern anywhere in production code.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
fail() { echo "field-parsing-test: $*" >&2; exit 1; }
export PERFLAB_LAB_OPTIONAL=1
export PERFLAB_CONFIG="${repo}/labs/scenariolab/lab.config.sh"
# shellcheck disable=SC1091
source "${repo}/harness/core/lib/common.sh"

# --- the collapse is real ---------------------------------------------------
# Demonstrate the defect the helper exists to avoid, so the reason is not just
# asserted in a comment.
printf 'S01\tGET\t\t64\n' | { IFS=$'\t' read -r id method body conns; \
  [[ "${body}" == "64" && -z "${conns}" ]] || fail "the collapse no longer reproduces; this guard may be unnecessary"; }

# --- the helper keeps positions ---------------------------------------------
read_fields 4 < <(printf 'S01\nGET\n\n64\n') || fail "read_fields rejected a valid 4-field record"
[[ "${TSV_FIELDS[0]}" == "S01" ]] || fail "field 0 = '${TSV_FIELDS[0]}', want S01"
[[ "${TSV_FIELDS[1]}" == "GET" ]] || fail "field 1 = '${TSV_FIELDS[1]}', want GET"
[[ -z "${TSV_FIELDS[2]}" ]]       || fail "field 2 = '${TSV_FIELDS[2]}', want the empty body"
[[ "${TSV_FIELDS[3]}" == "64" ]]  || fail "field 3 = '${TSV_FIELDS[3]}', want 64 -- the empty body shifted the record"

# Several empties in a row, and a trailing empty, are the shapes that collapse
# worst.
read_fields 5 < <(printf 'a\n\n\nb\n\n') || fail "read_fields rejected a record with consecutive empty fields"
[[ "${TSV_FIELDS[0]}" == "a" && -z "${TSV_FIELDS[1]}" && -z "${TSV_FIELDS[2]}" \
   && "${TSV_FIELDS[3]}" == "b" && -z "${TSV_FIELDS[4]}" ]] \
  || fail "consecutive empty fields were not preserved: [${TSV_FIELDS[*]}]"

# --- a short record is a refusal, not a partial parse -----------------------
# A short read is exactly what the collapse produced, so it must fail loudly
# rather than continue with whatever arrived.
if read_fields 4 < <(printf 'a\nb\n') 2>/dev/null; then
  fail "a 2-field record was accepted where 4 were required"
fi

# --- the pattern is banned in production code -------------------------------
# Reading into THREE OR MORE variables is the dangerous shape: an empty field
# anywhere but the last shifts every field after it. Two variables are safe --
# a trailing empty simply leaves the second empty, which is the correct result.
offenders=""
while IFS= read -r file; do
  case "${file}" in *-test.sh) continue ;; esac
  while IFS= read -r line; do
    # Count the variables named after `read`, stopping at a redirect or pipe.
    # Skip comments -- a line explaining the hazard is not the hazard.
    case "$(printf '%s' "${line}" | sed 's/^[[:space:]]*//')" in \#*) continue ;; esac
    # Count only the variable names: stop at a redirect, pipe, or statement end.
    variables="$(printf '%s' "${line}" | sed -n "s/.*read -r //p" | sed 's/[<|;].*//' | wc -w | tr -d ' ')"
    if [[ "${variables}" -ge 3 ]]; then
      offenders="${offenders}${offenders:+ }${file#"${repo}/"}"
      break
    fi
  done < <(grep -F "IFS=\$'\t' read" "${file}" 2>/dev/null || true)
done < <(find "${repo}/harness" "${repo}/scripts" -name '*.sh' -type f 2>/dev/null)
[[ -z "${offenders}" ]] \
  || fail "these read three or more tab-delimited fields with IFS=\$'\t', where an empty field shifts the rest -- use read_fields: ${offenders}"

echo "field parsing tests passed"
