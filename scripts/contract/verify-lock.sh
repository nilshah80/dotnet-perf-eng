#!/usr/bin/env bash
set -euo pipefail

# Usage: verify-lock.sh [root] [--attest <output.json>]
#
# --attest writes a parity attestation AFTER verification succeeds, from the
# very digests this script just checked. It is deliberately not a separate
# script: an exporter that recomputed the hashes could drift from the verifier
# and attest a tree that never passed. Emitting here makes "attested" mean
# "verified", which is what the release coordinator compares across repositories.
root=""
attest_out=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --attest) attest_out="${2:?--attest requires an output path}"; shift 2 ;;
    *) [[ -z "${root}" ]] || { echo "unexpected argument: $1" >&2; exit 2; }; root="$1"; shift ;;
  esac
done
root="${root:-$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)}"
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
if [[ -n "${attest_out}" ]]; then
  # perflabInventorySha256 is PerfLab's own inventory digest. This repository
  # does not own that file, so the value is carried from the parity lock that
  # was just verified rather than invented here; the coordinator compares it
  # against PerfLab's independently produced attestation.
  perflab_inventory_sha="$(jqd -er '.perflabInventorySha256' < "${parity}")"
  mkdir -p "$(dirname "${attest_out}")"
  printf '{\n' > "${attest_out}"
  printf '  "repository": "dotnet-perf-eng",\n' >> "${attest_out}"
  printf '  "contractRevision": "%s",\n' "${revision}" >> "${attest_out}"
  printf '  "planSha256": "%s",\n' "${plan_sha}" >> "${attest_out}"
  printf '  "manifestSha256": "%s",\n' "${manifest_sha}" >> "${attest_out}"
  printf '  "aggregateSha256": "%s",\n' "${aggregate_sha}" >> "${attest_out}"
  printf '  "contractIndexSha256": "%s",\n' "${index_sha}" >> "${attest_out}"
  printf '  "perflabInventorySha256": "%s",\n' "${perflab_inventory_sha}" >> "${attest_out}"
  printf '  "dotnetPerfEngInventorySha256": "%s",\n' "${inventory_sha}" >> "${attest_out}"
  printf '  "inventoryField": "dotnetPerfEngInventorySha256",\n' >> "${attest_out}"
  printf '  "inventorySha256": "%s"\n' "${inventory_sha}" >> "${attest_out}"
  printf '}\n' >> "${attest_out}"
  printf 'native attestation written to %s\n' "${attest_out}"
fi
printf 'native stable-v1 lock ok aggregate=%s\n' "${aggregate_sha}"
