#!/usr/bin/env bash

set -euo pipefail

script_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_lib_dir}/../.." && pwd)"
scenario_catalog="${repo_root}/scenarios/scenarios.json"

# Windows-native jq.exe opens stdout in text mode and emits CRLF. Command
# substitution strips the trailing LF but leaves the CR, so every $(jq ...)
# capture carries a stray carriage return that corrupts URLs, paths, and
# comparisons: the trace-detail fetches in capture-evidence.sh failed with
# curl error 3 ("malformed input to a URL function") for exactly this reason.
# Normalize to LF on Windows only, and preserve jq's own exit status because
# callers such as `jq -e` rely on it for control flow.
case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN*)
    jq() {
      command jq "$@" | sed 's/\r$//'
      return "${PIPESTATUS[0]}"
    }

    # MSYS rewrites POSIX-looking environment variable values into Windows
    # paths when spawning a native binary, so PERF_PATH=/api/... reached k6.exe
    # as "C:/Program Files/Git/api/..." and the concatenated base URL became
    # host "127.0.0.1:8080C", failing DNS on every request. These variables are
    # URL parts and payloads, not filesystem paths, so exclude them.
    export MSYS2_ENV_CONV_EXCL='PERF_BASE_URL;PERF_METHOD;PERF_PATH;PERF_BODY;PERF_RUN_ID;PERF_SCENARIO;PERF_RUN_MODE'
    ;;
esac

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
