#!/usr/bin/env bash
# Acceptance cases 1 and 2: the TSV and JSON descriptions of a lab agree.
#
# Every lab is described twice -- scenarios.tsv, which the native harness parses
# with awk, and catalog.json, which the contract and PerfLab consume. Two
# descriptions of one thing drift, and the drift is invisible: a scenario added
# to one and not the other silently means "this scenario does not exist" to half
# the system, and a scenario whose target or diagnostic differs between them
# produces two different runs under one id.
#
#   1  legacy TSV scenarios keep their behaviour, and the rate aliases resolve
#   2  the JSON workload matches the equivalent TSV row
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
fail() { echo "catalog-equivalence-test: $*" >&2; exit 1; }
command -v jq >/dev/null || fail "jq is required"

# This test compares jq output against awk output. jq.exe writes CRLF on Windows
# while MSYS awk writes LF, and command substitution strips only the TRAILING
# newline -- so multi-line jq output keeps an embedded CR on every line but the
# last, and the two id sets never compare equal. The failure is invisible in the
# message, which prints two sets that look identical. Strip CR at the source.
#
# MSYS_NO_PATHCONV is deliberately NOT set here, unlike common.sh's jqd: these
# calls pass the catalog PATH as a jq argument and rely on MSYS rewriting it
# into a Windows path that jq.exe can open.
jq() { command jq "$@" | tr -d '\r'; return "${PIPESTATUS[0]}"; }

checked_labs=0
for catalog in "${repo}"/labs/*/catalog.json; do
  [[ -f "${catalog}" ]] || continue
  lab_dir="$(dirname "${catalog}")"
  lab="$(basename "${lab_dir}")"
  tsv="${lab_dir}/scenarios.tsv"
  [[ -f "${tsv}" ]] || continue
  checked_labs=$((checked_labs + 1))

  # --- case 2: the same scenarios exist on both sides ----------------------
  # A TSV row is one method/path/body, so it can express `request` and
  # `protocol` workloads but not a `journey` or a `mix`, which are multi-step by
  # definition. Journeys living only in the catalog is therefore the design
  # rather than drift -- but a scenario claiming that exemption must actually be
  # multi-step, which is asserted below rather than assumed.
  tsv_ids="$(awk -F'\t' '!/^#/ && NF >= 2 && $1 != "" { print $1 }' "${tsv}" | LC_ALL=C sort -u)"
  json_ids="$(jq -r '.scenarios[] | select(.workload.type == "request" or .workload.type == "protocol") | .id' "${catalog}" | LC_ALL=C sort -u)"

  # Anything in the catalog but not the TSV has to justify itself by NOT being a
  # request workload. Without this, a request scenario dropped from the TSV would
  # hide behind the same exemption that legitimately covers journeys.
  non_request_only="$(jq -r '[.scenarios[] | select(.workload.type == "journey" or .workload.type == "mix") | .id] | join(" ")' "${catalog}")"
  for id in ${non_request_only}; do
    if printf '%s\n' "${tsv_ids}" | grep -qx "${id}"; then
      fail "${lab}/${id}: declared as a multi-step workload in the catalog but also present in the TSV, which can only describe a single request"
    fi
  done
  if [[ "${tsv_ids}" != "${json_ids}" ]]; then
    only_tsv="$(comm -23 <(printf '%s\n' "${tsv_ids}") <(printf '%s\n' "${json_ids}") | tr '\n' ' ')"
    only_json="$(comm -13 <(printf '%s\n' "${tsv_ids}") <(printf '%s\n' "${json_ids}") | tr '\n' ' ')"
    fail "${lab}: the two descriptions disagree about which scenarios exist -- only in TSV: [${only_tsv}], only in JSON: [${only_json}]"
  fi

  # --- case 2: and describe each one the same way --------------------------
  # Fields are extracted with awk, not `IFS=$'\t' read`. Bash treats tab as IFS
  # WHITESPACE, so consecutive tabs collapse into one delimiter: a scenario with
  # an empty body column shifts every later field left by one, and `target`
  # silently receives the diagnostic. Real rows have empty bodies.
  while IFS='|' read -r id target diagnostic connections; do
    [[ -n "${id}" ]] || continue
    kind="$(jq -r --arg id "${id}" '.scenarios[] | select(.id==$id) | .workload.type // ""' "${catalog}")"
    [[ "${kind}" == "request" || "${kind}" == "protocol" ]] || continue
    json_targets="$(jq -r --arg id "${id}" '.scenarios[] | select(.id==$id) | .targets | join(",")' "${catalog}")"
    [[ ",${json_targets}," == *",${target},"* ]] \
      || fail "${lab}/${id}: TSV targets '${target}', catalog targets '${json_targets}'; one run id would drive two different services"

    json_preset="$(jq -r --arg id "${id}" '.scenarios[] | select(.id==$id) | .diagnostics.preset // ""' "${catalog}")"
    if [[ -n "${json_preset}" && -n "${diagnostic}" ]]; then
      [[ "${json_preset}" == "${diagnostic}" ]] \
        || fail "${lab}/${id}: TSV diagnostic '${diagnostic}', catalog preset '${json_preset}'"
    fi

    # --- case 1: the rate alias resolves to the TSV connection count -------
    if [[ -n "${connections}" && "${connections}" =~ ^[0-9]+$ ]]; then
      json_rate="$(jq -r --arg id "${id}" '.scenarios[] | select(.id==$id) | .defaults.rate // ""' "${catalog}")"
      [[ "${json_rate}" == "${connections}" ]] \
        || fail "${lab}/${id}: TSV declares ${connections} connections, catalog declares rate ${json_rate}; the same scenario would run at two different loads"
    fi
  done < <(awk -F'\t' '!/^#/ && NF >= 2 && $1 != "" { printf "%s|%s|%s|%s\n", $1, $6, $7, $8 }' "${tsv}")

  # --- case 1: the rate UNIT must be declared, not assumed -----------------
  # A bare number is ambiguous: 64 concurrent iterations and 64 requests/second
  # are different experiments, and a closed-model scenario read as open-model
  # measures something nobody asked for.
  missing_unit="$(jq -r '[.scenarios[] | select((.defaults.rateUnit // "") == "") | .id] | join(",")' "${catalog}")"
  [[ -z "${missing_unit}" ]] \
    || fail "${lab}: scenarios [${missing_unit}] declare a rate with no unit; the number alone does not say which experiment it is"

  # Every declared unit must be one the harness understands, or it resolves to
  # a default at run time and the declaration was decorative.
  bad_unit="$(jq -r '[.scenarios[] | select((.defaults.rateUnit // "") | test("^(concurrent-iterations|concurrent-users|requests/s|journeys/s|iterations/s)$") | not) | "\(.id)=\(.defaults.rateUnit)"] | join(", ")' "${catalog}")"
  [[ -z "${bad_unit}" ]] || fail "${lab}: unrecognised rate unit(s): ${bad_unit}"
done

[[ "${checked_labs}" -gt 0 ]] || fail "no lab had both a TSV and a JSON catalog; this test checked nothing"
echo "catalog equivalence tests passed (${checked_labs} lab(s))"
