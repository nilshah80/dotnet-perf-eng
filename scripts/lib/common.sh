#!/usr/bin/env bash

set -euo pipefail

script_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_lib_dir}/../.." && pwd)"
scenario_catalog="${repo_root}/scenarios/scenarios.json"

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Required command '$1' was not found." >&2
    exit 1
  fi
}

require_scenario() {
  local scenario_id="$1"
  if ! jq -e --arg id "${scenario_id}" 'has($id)' "${scenario_catalog}" >/dev/null; then
    local available_scenarios
    available_scenarios="$(jq -r 'keys | join(", ")' "${scenario_catalog}")"
    echo "Unknown scenario '${scenario_id}'. Available scenarios: ${available_scenarios}." >&2
    exit 1
  fi
}

scenario_value() {
  local scenario_id="$1"
  local field="$2"
  jq -r --arg id "${scenario_id}" --arg field "${field}" '.[$id][$field]' "${scenario_catalog}"
}

wait_for_api() {
  local attempts=90
  local attempt
  for attempt in $(seq 1 "${attempts}"); do
    if curl -fsS http://127.0.0.1:8080/health/ready >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done

  echo "API did not become ready. Recent container logs:" >&2
  docker compose -f "${repo_root}/compose.yaml" logs --tail=100 api >&2
  return 1
}

relative_to_repo() {
  local absolute_path="$1"
  printf '%s\n' "${absolute_path#"${repo_root}/"}"
}
