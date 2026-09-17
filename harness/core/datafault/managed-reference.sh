#!/usr/bin/env bash
# Managed-reference run-partition bootstrap for the native Slice 2 checkout
# journey. Seeds and resets only the unique runId partition. Cleanup is a
# separate invocation so an incomplete cleanup cannot pass a later gate.
set -euo pipefail
# shellcheck disable=SC1091
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../lib/common.sh"

run_id="${1:?managed-reference.sh <run-id> <base-url> [cleanup]}"
base_url="${2:?base-url required}"
action="${3:-seed}"
user="${PERF_LOGIN_USER:-user1}"
password="${PERF_LOGIN_PASSWORD:-Password123!}"

[[ "${PERF_WRITE_ACK:-}" == "managed-reference" ]] || {
  echo "managed-reference acknowledgement is required" >&2
  exit 1
}
[[ "${PERF_WRITE_BUDGET:-}" =~ ^[1-9][0-9]*$ ]] || {
  echo "a positive managed-reference write budget is required" >&2
  exit 1
}

login_json="$(curl -fsS -X POST "${base_url}/api/auth/login" \
  -H 'Content-Type: application/json' \
  -H "X-Perf-Run-Id: ${run_id}" \
  --data "{\"username\":\"${user}\",\"password\":\"${password}\"}")"
token="$(printf '%s' "${login_json}" | jqd -r '.token // empty')"
[[ -n "${token}" ]] || { echo "managed-reference login failed" >&2; exit 1; }

auth=(-H "Authorization: Bearer ${token}" -H "X-Perf-Run-Id: ${run_id}" -H 'Content-Type: application/json')
if [[ "${action}" == "cleanup" ]]; then
  cleanup_json="$(curl -fsS -X POST "${base_url}/api/perf/runs/${run_id}/cleanup" "${auth[@]}" --data '{}')"
  [[ "$(printf '%s' "${cleanup_json}" | jqd -r '.cleaned // false')" == "true" ]] || {
    echo "managed-reference cleanup did not complete" >&2
    exit 1
  }
  [[ "$(printf '%s' "${cleanup_json}" | jqd -r '.remaining // -1')" == "0" ]] || {
    echo "managed-reference cleanup left run-owned records" >&2
    exit 1
  }
  echo "managed-reference partition ${run_id} cleaned"
  exit 0
fi

if [[ "${action}" == "reset" ]]; then
  reset_json="$(curl -fsS -X POST "${base_url}/api/perf/runs/${run_id}/reset" "${auth[@]}" --data '{}')"
  [[ "$(printf '%s' "${reset_json}" | jqd -r '.ready // false')" == "true" ]] || {
    echo "managed-reference partition did not reset after warm-up" >&2
    exit 1
  }
  echo "managed-reference partition ${run_id} reset after warm-up"
  exit 0
fi

curl -fsS -X POST "${base_url}/api/perf/runs/${run_id}/seed?budget=${PERF_WRITE_BUDGET}" "${auth[@]}" --data '{}' >/dev/null
reset_json="$(curl -fsS -X POST "${base_url}/api/perf/runs/${run_id}/reset" "${auth[@]}" --data '{}')"
[[ "$(printf '%s' "${reset_json}" | jqd -r '.ready // false')" == "true" ]] || {
  echo "managed-reference partition did not become ready" >&2
  exit 1
}
echo "managed-reference partition ${run_id} seeded and reset"
