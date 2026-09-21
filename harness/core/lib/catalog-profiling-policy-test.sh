#!/usr/bin/env bash
# D-P1-1. Profiling policy is a catalog field with CLI/env precedence. A missing
# field stays cpu. Changing types on an owned target requires recreate; an
# unowned target cannot take a process-lifetime profiler change.
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
fail() { echo "catalog-profiling-policy-test: $*" >&2; exit 1; }
export PERFLAB_LAB_OPTIONAL=1
export PERFLAB_CONFIG="${repo}/labs/scenariolab/lab.config.sh"

# Operator env must be truly unset, not defaulted, or the catalog cannot win.
unset PERFLAB_PROFILING_POLICY PERFLAB_PROFILING_TYPES PERFLAB_PROFILING_POLICY_SOURCE || true
# shellcheck disable=SC1091
source "${repo}/harness/core/lib/common.sh"

profiling_types_for_policy cpu >/dev/null \
  || fail "profiling_types_for_policy was not defined by lab-context"

# --- catalog field is selected when the operator did not set a policy ------
unset PERFLAB_PROFILING_POLICY PERFLAB_PROFILING_TYPES || true
PERFLAB_OPERATOR_PROFILING_POLICY=""
PERFLAB_OPERATOR_PROFILING_TYPES=""
resolve_profiling_policy S04 || fail "catalog memory policy for S04 was rejected"
[[ "${PERFLAB_PROFILING_POLICY}" == "memory" ]] \
  || fail "S04 catalog policy=${PERFLAB_PROFILING_POLICY}, want memory"
[[ "${PERFLAB_PROFILING_TYPES}" == "allocation,live-heap" ]] \
  || fail "S04 types=${PERFLAB_PROFILING_TYPES}, want allocation,live-heap"
[[ "${PERFLAB_PROFILING_POLICY_SOURCE}" == "catalog" ]] \
  || fail "S04 source=${PERFLAB_PROFILING_POLICY_SOURCE}, want catalog"

resolve_profiling_policy S00 || fail "default cpu policy for S00 was rejected"
[[ "${PERFLAB_PROFILING_POLICY}" == "cpu" && "${PERFLAB_PROFILING_TYPES}" == "cpu" ]] \
  || fail "S00 without a catalog field must default to cpu"
[[ "${PERFLAB_PROFILING_POLICY_SOURCE}" == "default" ]] \
  || fail "S00 source=${PERFLAB_PROFILING_POLICY_SOURCE}, want default"

resolve_profiling_policy S27 || fail "catalog contention policy for S27 was rejected"
[[ "${PERFLAB_PROFILING_POLICY}" == "contention" && "${PERFLAB_PROFILING_TYPES}" == "lock" ]] \
  || fail "S27 catalog policy=${PERFLAB_PROFILING_POLICY} types=${PERFLAB_PROFILING_TYPES}"

# --- CLI/env wins over the catalog ----------------------------------------
PERFLAB_OPERATOR_PROFILING_POLICY="cpu"
PERFLAB_OPERATOR_PROFILING_TYPES=""
resolve_profiling_policy S04 || fail "operator override of S04 was rejected"
[[ "${PERFLAB_PROFILING_POLICY}" == "cpu" && "${PERFLAB_PROFILING_POLICY_SOURCE}" == "operator" ]] \
  || fail "operator cpu must win over catalog memory: policy=${PERFLAB_PROFILING_POLICY} source=${PERFLAB_PROFILING_POLICY_SOURCE}"

# --- unknown catalog policy fails closed ----------------------------------
work="$(mktemp -d "${TMPDIR:-/tmp}/perflab-profiling-policy.XXXXXX")"
trap 'rm -rf "${work}"' EXIT HUP INT TERM
cat > "${work}/catalog.json" <<'JSON'
{
  "apiVersion": "perflab.io/v1",
  "kind": "ScenarioCatalog",
  "contractRevision": "v1",
  "scenarios": [
    {
      "id": "X01",
      "name": "bad-policy",
      "workload": {"type": "request", "selector": "X01"},
      "targets": ["api"],
      "defaults": {"loadModel": "closed", "rate": 1, "rateUnit": "concurrent-iterations"},
      "diagnostics": {"profilingPolicy": "not-a-policy"}
    }
  ]
}
JSON
json_catalog="${work}/catalog.json"
PERFLAB_OPERATOR_PROFILING_POLICY=""
PERFLAB_OPERATOR_PROFILING_TYPES=""
if resolve_profiling_policy X01 2>"${work}/err"; then
  fail "unknown catalog profilingPolicy was accepted"
fi
grep -q "unknown catalog diagnostics.profilingPolicy" "${work}/err" \
  || fail "unknown-policy error text: $(cat "${work}/err")"

# --- recreate is required only when the startup key actually changes ------
profiling_needs_recreate "" "1|cpu|cpu|0" && fail "first generation must not force-recreate"
profiling_needs_recreate "1|cpu|cpu|0" "1|cpu|cpu|0" && fail "identical startup key must not recreate"
profiling_needs_recreate "1|cpu|cpu|0" "1|memory|allocation,live-heap|0" \
  || fail "changed types must recreate the owned process"

echo "catalog profiling policy tests passed"
