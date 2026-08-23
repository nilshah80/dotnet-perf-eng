#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ $# -eq 0 ]]; then
  echo "Usage: ./scripts/run-single.sh <S00-S26> [duration-seconds] [--with-runtime]" >&2
  exit 1
fi

exec "${script_dir}/run-scenarios.sh" "$1" "${@:2}"
