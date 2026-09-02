#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ $# -eq 0 ]]; then
  echo "Usage: ./harness/core/run/run-multiple.sh <S01,S07,...> [duration-seconds] [options]" >&2
  exit 1
fi

if [[ "$1" == "-h" || "$1" == "--help" ]]; then
  exec "${script_dir}/run-scenarios.sh" --help
fi

selector="$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]' | tr -d '[:space:]')"
if [[ "${selector}" == "ALL" || "${selector}" != *,* ]]; then
  echo "run-multiple.sh requires at least two comma-separated scenario IDs; received '$1'." >&2
  exit 1
fi

exec "${script_dir}/run-scenarios.sh" "$1" "${@:2}"
