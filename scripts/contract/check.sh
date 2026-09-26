#!/usr/bin/env sh
set -eu
root="$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)"
cd "$root"

. "$root/harness/core/lib/python.sh"
PYTHON="$(perflab_python)" || { echo "a working Python 3 interpreter was not found (tried python3, python)" >&2; exit 1; }

"$root/scripts/contract/independence.sh"
"$PYTHON" "$root/scripts/contract/native-inventory.py" --check "$root"

"$PYTHON" "$root/scripts/contract/plan-consistency.py"
"$PYTHON" "$root/scripts/contract/markdowncheck.py" \
  docs/REAL-WORLD-PERFORMANCE-ENGINEERING-IMPLEMENTATION-PLAN.md \
  contracts/v1/semantics/contract.md

"$root/scripts/contract/verify-lock.sh" "$root"
"$PYTHON" - <<'PY'
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
"$root/harness/adapters/loadgen/k6/baggage-test.sh"
"$root/harness/adapters/loadgen/k6/run-test.sh"

# Behaviour that the release claims and that a reader cannot verify by eye: each
# of these pins a rule that was once wrong in a way no one noticed, so the test
# is the only thing standing between a fix and its silent regression.
"$root/harness/adapters/runtime/dotnet/capture-target-identity-test.sh"
"$root/harness/adapters/runtime/dotnet/capability-test.sh"
"$root/harness/adapters/runtime/dotnet/stacks-staging-test.sh"
"$root/harness/adapters/runtime/dotnet/collection-rules-test.sh"
"$root/harness/adapters/runtime/dotnet/capture-test.sh"
"$root/harness/adapters/runtime/dotnet/injection/injection-test.sh"
"$root/harness/adapters/runtime/dotnet/pyroscope/entrypoint-test.sh"
"$root/harness/adapters/observability/grafana/capture-profiles-test.sh"
"$root/harness/adapters/observability/grafana/capture-span-profiles-test.sh"
"$root/harness/core/lib/target-lifecycle-test.sh"
"$root/harness/core/lib/lab-context-pyroscope-test.sh"
"$root/harness/core/lib/catalog-equivalence-test.sh"
"$root/harness/core/lib/catalog-profiling-policy-test.sh"
"$root/harness/core/lib/capability-qualification-test.sh"
"$root/harness/core/lib/backend-auth-test.sh"
"$root/harness/core/lib/remote-correlation-test.sh"
"$root/harness/core/lib/baggage-contract-test.sh"
"$root/harness/core/lib/soak-session-test.sh"
"$root/harness/core/lib/fault-proof-test.sh"
"$root/harness/core/lib/distributed-merge-test.sh"
"$root/harness/core/lib/field-parsing-test.sh"
"$root/harness/core/lib/workload-login-test.sh"
"$root/harness/core/lib/generator-ports-test.sh"
"$root/harness/core/lib/measurement-window-replicas-test.sh"
bash "$root/harness/core/lib/common-jq-test.sh"
"$root/harness/core/lib/normalization-test.sh"
"$root/harness/core/run/run-scenario-lifecycle-test.sh"
"$root/harness/core/analyze/compare-runs-fingerprint-test.sh"
"$root/harness/core/analyze/compare-runs-keep-tiering-test.sh"
"$root/harness/core/analyze/bottleneck-rules-test.sh"
"$root/harness/core/analyze/environment-drift-test.sh"
"$root/harness/core/analyze/async-reconciliation-test.sh"
"$root/harness/core/analyze/analyze-stages-test.sh"
"$root/harness/core/analyze/gate-journey-test.sh"
"$root/harness/core/analyze/diff-speedscope-test.sh"
"$root/harness/core/analyze/update-baseline-test.sh"
"$root/harness/core/capture/capture-evidence-empty-signal-test.sh"
"$root/harness/core/capture/evidence-safety-test.sh"
"$root/harness/core/capture/artifact-policy-test.sh"
"$root/harness/core/capture/capture-evidence-profiling-guard-test.sh"
echo "native contract local checks passed"
