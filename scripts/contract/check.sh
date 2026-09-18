#!/usr/bin/env sh
set -eu
root="$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)"
cd "$root"

"$root/scripts/contract/independence.sh"
python3 "$root/scripts/contract/native-inventory.py" --check "$root"

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
echo "native contract local checks passed"
