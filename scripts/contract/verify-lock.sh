#!/usr/bin/env bash
set -euo pipefail

root="${1:-$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)}"
export PERFLAB_LAB_OPTIONAL=1
# shellcheck disable=SC1091
source "${root}/harness/core/lib/common.sh"

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

verify_text() {
  local file="$1" first last two
  [[ -s "${file}" ]] || { echo "empty contract file: ${file}" >&2; return 1; }
  first="$(od -An -tx1 -N3 "${file}" | tr -d ' \n')"
  [[ "${first}" != "efbbbf" ]] || { echo "BOM in ${file}" >&2; return 1; }
  if LC_ALL=C grep -q $'\r' "${file}"; then
    echo "CR in ${file}" >&2
    return 1
  fi
  last="$(tail -c 1 "${file}" | od -An -tx1 | tr -d ' \n')"
  two="$(tail -c 2 "${file}" | od -An -tx1 | tr -d ' \n')"
  [[ "${last}" == "0a" && "${two}" != "0a0a" ]] || {
    echo "${file} must end in exactly one LF" >&2
    return 1
  }
}

path_map="${root}/contracts/contract-path-map.json"
manifest="${root}/contracts/contract-manifest.json"
lock="${root}/contracts/contract-lock.json"
index="${root}/contracts/contract-index.json"
parity="${root}/parity-lock.json"
for file in "${path_map}" "${manifest}" "${lock}" "${index}" "${parity}"; do
  verify_text "${file}"
done

revision="$(jqd -er '.contractRevision' < "${manifest}")"
[[ "${revision}" == "v1" ]] || {
  echo "unknown contract revision ${revision} rejected before traffic" >&2
  exit 1
}

work="$(mktemp -d "${TMPDIR:-/tmp}/native-contract.XXXXXX")"
trap 'rm -rf "${work}"' EXIT HUP INT TERM
jqd -r '.paths[] | [.logicalName,.path] | @tsv' < "${path_map}" > "${work}/paths"
printf 'meta/contract-manifest.json\tcontracts/contract-manifest.json\n' >> "${work}/paths"
LC_ALL=C sort -o "${work}/paths" "${work}/paths"
jqd -r '.entries[] | [.logicalName,.sha256] | @tsv' < "${lock}" > "${work}/lock"
LC_ALL=C sort -o "${work}/lock" "${work}/lock"

: > "${work}/actual"
: > "${work}/preimage"
while IFS=$'\t' read -r logical relative; do
  file="${root}/${relative}"
  [[ -f "${file}" ]] || { echo "missing contract entry ${relative}" >&2; exit 1; }
  verify_text "${file}"
  digest="$(sha256_file "${file}")"
  printf '%s\t%s\n' "${logical}" "${digest}" >> "${work}/actual"
  printf '%s\0%s\n' "${logical}" "${digest}" >> "${work}/preimage"
done < "${work}/paths"

cmp -s "${work}/actual" "${work}/lock" || {
  echo "contract entry digest mismatch" >&2
  diff -u "${work}/lock" "${work}/actual" >&2 || true
  exit 1
}
manifest_sha="$(sha256_file "${manifest}")"
aggregate_sha="$(sha256_file "${work}/preimage")"
lock_manifest="$(jqd -er '.manifestSha256' < "${lock}")"
lock_aggregate="$(jqd -er '.aggregateSha256' < "${lock}")"
[[ "${manifest_sha}" == "${lock_manifest}" && "${aggregate_sha}" == "${lock_aggregate}" ]] || {
  echo "contract manifest or aggregate digest mismatch" >&2
  exit 1
}
jqd -e --arg manifest "${manifest_sha}" --arg aggregate "${aggregate_sha}" '
  .activeRevision == "v1" and (.revisions | length == 1) and
  .revisions[0].revision == "v1" and
  .revisions[0].manifestSha256 == $manifest and
  .revisions[0].aggregateSha256 == $aggregate
' < "${index}" >/dev/null

plan_sha="$(sha256_file "${root}/docs/REAL-WORLD-PERFORMANCE-ENGINEERING-IMPLEMENTATION-PLAN.md")"
index_sha="$(sha256_file "${index}")"
inventory_sha="$(sha256_file "${root}/harness/inventories/compatibility-inventory.json")"
jqd -e --arg plan "${plan_sha}" --arg manifest "${manifest_sha}" \
  --arg aggregate "${aggregate_sha}" --arg index "${index_sha}" \
  --arg inventory "${inventory_sha}" '
    .contractRevision == "v1" and .planSha256 == $plan and
    .manifestSha256 == $manifest and .aggregateSha256 == $aggregate and
    .contractIndexSha256 == $index and .dotnetPerfEngInventorySha256 == $inventory
  ' < "${parity}" >/dev/null
printf 'native stable-v1 lock ok aggregate=%s\n' "${aggregate_sha}"
