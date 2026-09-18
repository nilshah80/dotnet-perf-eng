#!/usr/bin/env sh
set -eu
root="$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)"
cd "$root"

"$root/scripts/contract/independence.sh"
python3 "$root/scripts/contract/native-inventory.py" --check "$root"

python3 "$root/scripts/contract/plan-consistency.py"
python3 "$root/scripts/contract/markdowncheck.py" \
  docs/REAL-WORLD-PERFORMANCE-ENGINEERING-IMPLEMENTATION-PLAN.md \
  contracts/v1/semantics/contract.md

"$root/scripts/contract/verify-lock.sh" "$root"
python3 - <<'PY'
import hashlib, json
from pathlib import Path
root = Path('.')
parity = json.loads((root / 'parity-lock.json').read_text())
inv = (root / 'harness/inventories/compatibility-inventory.json').read_bytes()
digest = hashlib.sha256(inv).hexdigest()
if digest != parity['dotnetPerfEngInventorySha256']:
    raise SystemExit(f"inventory digest mismatch {digest} != {parity['dotnetPerfEngInventorySha256']}")
print('inventory ok', digest)
PY
"$root/scripts/contract/attest-test.sh"
"$root/scripts/contract/foundation-test.sh"
"$root/harness/adapters/loadgen/jmeter/runner-test.sh"
"$root/harness/adapters/loadgen/k6/journey-normalization-test.sh"
"$root/harness/adapters/loadgen/k6/journey-behaviour-test.sh"
"$root/harness/adapters/loadgen/k6/profile-shape-test.sh"

# Behaviour that the release claims and that a reader cannot verify by eye: each
# of these pins a rule that was once wrong in a way no one noticed, so the test
# is the only thing standing between a fix and its silent regression.
"$root/harness/adapters/runtime/dotnet/capture-target-identity-test.sh"
"$root/harness/core/lib/target-lifecycle-test.sh"
"$root/harness/core/lib/lab-context-pyroscope-test.sh"
"$root/harness/core/lib/catalog-equivalence-test.sh"
"$root/harness/core/lib/field-parsing-test.sh"
"$root/harness/core/run/run-scenario-lifecycle-test.sh"
"$root/harness/core/analyze/compare-runs-fingerprint-test.sh"
"$root/harness/core/analyze/compare-runs-keep-tiering-test.sh"
"$root/harness/core/analyze/bottleneck-rules-test.sh"
"$root/harness/core/analyze/environment-drift-test.sh"
"$root/harness/core/analyze/async-reconciliation-test.sh"
"$root/harness/core/capture/capture-evidence-empty-signal-test.sh"
"$root/harness/core/capture/evidence-safety-test.sh"
"$root/harness/core/capture/artifact-policy-test.sh"
echo "native contract local checks passed"
