#!/usr/bin/env bash
# Gate B qualification is intentionally separate from the repository-local
# contract check: it creates temporary targets, local TLS material, and an
# isolated Compose project. Every command below is a real target proof, and
# each cleans up the processes/volumes it created.
set -euo pipefail
root="$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)"
cd "${root}"

"${root}/harness/adapters/runtime/dotnet/collection-rules-live-test.sh"
"${root}/labs/protocol-reliability/edge-security-test.sh"
"${root}/labs/protocol-reliability/security-journey-test.sh"
"${root}/labs/protocol-reliability/multi-origin-proof-test.sh"
"${root}/labs/protocol-reliability/backpressure-proof-test.sh"
"${root}/labs/protocol-reliability/measurement-window-proof-test.sh"
"${root}/labs/protocol-reliability/distributed-proof-test.sh"

echo "Gate B live Protocol Reliability qualification passed"
