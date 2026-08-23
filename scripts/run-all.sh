#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  cat <<'EOF'
Usage: ./scripts/run-all.sh [duration-seconds] [--with-runtime] [--continue-on-error]

Runs every scenario in scenarios/scenarios.json under one suite run ID.
EOF
  exit 0
fi

exec "${script_dir}/run-scenarios.sh" all "$@"
