#!/usr/bin/env sh
set -eu
root="$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)"
cd "$root"

"$root/scripts/contract/independence.sh"
python3 "$root/scripts/contract/native-inventory.py" --check "$root"

python3 "$root/scripts/contract/markdowncheck.py" \
  docs/REAL-WORLD-PERFORMANCE-ENGINEERING-IMPLEMENTATION-PLAN.md \
  contracts/v1/semantics/contract.md

go run ./harness/core/contract/cmd check "$root"
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
go run ./harness/core/catalog/cmd validate-catalog labs/ecommerce/catalog.json
go run ./harness/core/catalog/cmd validate-catalog labs/scenariolab/catalog.json
go run ./harness/core/catalog/cmd validate-catalog labs/remote-example/catalog.json
go test ./harness/core/catalog ./harness/core/capability ./harness/core/comparison \
  ./harness/core/workload ./harness/core/profile ./harness/core/session \
  ./harness/core/target ./harness/core/datafault ./harness/core/performance \
  ./harness/core/contract/cmd
go test ./harness/adapters/loadgen/jmeter/runner
go run ./harness/core/contract/cmd attest "$root"
echo "native contract local checks passed"
