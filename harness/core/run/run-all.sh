#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  cat <<'EOF'
Usage: ./harness/core/run-all.sh [duration-seconds] [--with-runtime] [--continue-on-error]

Runs every scenario in the descriptor's scenario catalog under one suite run ID.
EOF
  exit 0
fi

exec "${script_dir}/run-scenarios.sh" all "$@"
