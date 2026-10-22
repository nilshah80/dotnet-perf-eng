#!/usr/bin/env bash
# Native attestation exporter tests.
#
# The release coordinator compares this repository's attestation against
# PerfLab's. That comparison is only meaningful if the attestation reports the
# digests this repository ACTUALLY has -- an exporter that emitted stale or
# invented values would make the coordinator agree while the trees diverged,
# which is the failure the coordinator exists to prevent.
#
# So this pins two properties:
#   1. every compared field matches the verified parity lock, and
#   2. the exporter refuses to emit for a tree that fails verification.
set -euo pipefail

root="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
verify="${root}/scripts/contract/verify-lock.sh"
work="$(mktemp -d "${TMPDIR:-/tmp}/native-attest-test.XXXXXX")"
trap 'rm -rf "${work}"' EXIT HUP INT TERM
fail() { echo "attest-test: $*" >&2; exit 1; }

# shellcheck source=/dev/null
. "${root}/harness/core/lib/python.sh"
PYTHON="$(perflab_python)" || fail "a working Python 3 interpreter was not found (tried python3, python)"

out="${work}/parity-attestation.json"
bash "${verify}" "${root}" --attest "${out}" >/dev/null || fail "verification failed on a clean tree"
[[ -s "${out}" ]] || fail "exporter produced no attestation"

"${PYTHON}" - "$root" "$out" <<'PY'
import hashlib, json, sys
from pathlib import Path

root, attestation_path = Path(sys.argv[1]), Path(sys.argv[2])
attestation = json.loads(attestation_path.read_text())
lock = json.loads((root / "parity-lock.json").read_text())

# Exactly the fields scripts/contract/coordinate-release/compare.sh compares,
# plus the identity fields a reader needs to tell the two sides apart.
for field in (
    "contractRevision",
    "planSha256",
    "manifestSha256",
    "aggregateSha256",
    "contractIndexSha256",
    "perflabInventorySha256",
    "dotnetPerfEngInventorySha256",
):
    if field not in attestation:
        raise SystemExit(f"attestation is missing {field}")
    if attestation[field] != lock[field]:
        raise SystemExit(
            f"attestation {field}={attestation[field]} does not match the verified lock {lock[field]}"
        )

if attestation.get("repository") != "dotnet-perf-eng":
    raise SystemExit("attestation must identify its repository")
if attestation.get("inventoryField") != "dotnetPerfEngInventorySha256":
    raise SystemExit("attestation must name the inventory field it owns")

# The plan digest is the one a reader is most likely to assume rather than
# check, so confirm it against the file on disk instead of the lock alone.
plan = (root / "docs/REAL-WORLD-PERFORMANCE-ENGINEERING-IMPLEMENTATION-PLAN.md").read_bytes()
if attestation["planSha256"] != hashlib.sha256(plan).hexdigest():
    raise SystemExit("attestation planSha256 does not match the plan on disk")
print("attestation matches the verified lock")
PY

# A tree whose plan has drifted from its lock must not produce an attestation:
# emitting one would let the coordinator compare a document the verifier never
# accepted.
cp -R "${root}" "${work}/tree" 2>/dev/null || fail "could not copy the tree"
printf '\ndrift\n' >> "${work}/tree/docs/REAL-WORLD-PERFORMANCE-ENGINEERING-IMPLEMENTATION-PLAN.md"
if bash "${verify}" "${work}/tree" --attest "${work}/tree-attestation.json" >/dev/null 2>&1; then
  fail "a tree whose plan drifted from its lock still produced an attestation"
fi
[[ ! -s "${work}/tree-attestation.json" ]] || fail "a failed verification still wrote an attestation"

echo "native attestation exporter tests passed"
