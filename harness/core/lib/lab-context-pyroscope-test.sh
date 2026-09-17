#!/usr/bin/env bash
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
fail() { echo "lab-context-pyroscope-test: $*" >&2; exit 1; }

# Remote + profiling without telemetry opt-in or URL must fail closed.
if out="$(PERFLAB_LAB=remote-example PERFLAB_CONTINUOUS_PROFILING=1 \
    bash -c 'source "'"${repo}/harness/core/lib/common.sh"'"' 2>&1)"; then
  fail "remote profiling without telemetry opt-in was accepted:\n${out}"
fi
printf '%s\n' "${out}" | grep -q 'PERFLAB_REMOTE_TELEMETRY=1' || fail "missing remote telemetry error"

# Remote + telemetry still requires an explicit Pyroscope URL.
if out="$(PERFLAB_LAB=remote-example PERFLAB_CONTINUOUS_PROFILING=1 PERFLAB_REMOTE_TELEMETRY=1 \
    PERFLAB_PROMETHEUS_URL=https://prom.example PERFLAB_TEMPO_URL=https://tempo.example \
    PERFLAB_LOKI_URL=https://loki.example PERFLAB_PROM_JOB_REGEX=api PERFLAB_SERVICE_NAME_REGEX=api \
    bash -c 'source "'"${repo}/harness/core/lib/common.sh"'"' 2>&1)"; then
  fail "remote profiling inherited a missing Pyroscope URL:\n${out}"
fi
printf '%s\n' "${out}" | grep -q 'PERFLAB_PYROSCOPE_URL' || fail "missing explicit Pyroscope URL error"

# Remote + URL still requires the deployed service identities.
if out="$(PERFLAB_LAB=remote-example PERFLAB_CONTINUOUS_PROFILING=1 PERFLAB_REMOTE_TELEMETRY=1 \
    PERFLAB_PROMETHEUS_URL=https://prom.example PERFLAB_TEMPO_URL=https://tempo.example \
    PERFLAB_LOKI_URL=https://loki.example PERFLAB_PROM_JOB_REGEX=api PERFLAB_SERVICE_NAME_REGEX=api \
    PERFLAB_PYROSCOPE_URL=https://pyroscope.example \
    bash -c 'source "'"${repo}/harness/core/lib/common.sh"'"' 2>&1)"; then
  fail "remote profiling without PERFLAB_PYROSCOPE_SERVICES was accepted:\n${out}"
fi
printf '%s\n' "${out}" | grep -q 'PERFLAB_PYROSCOPE_SERVICES' || fail "missing remote service identity error"

# Explicit remote Pyroscope URL + services still require read-only verification.
if out="$(PERFLAB_LAB=remote-example PERFLAB_CONTINUOUS_PROFILING=1 PERFLAB_REMOTE_TELEMETRY=1 \
    PERFLAB_PROMETHEUS_URL=https://prom.example PERFLAB_TEMPO_URL=https://tempo.example \
    PERFLAB_LOKI_URL=https://loki.example PERFLAB_PROM_JOB_REGEX=api PERFLAB_SERVICE_NAME_REGEX=api \
    PERFLAB_PYROSCOPE_URL=https://pyroscope.example PERFLAB_PYROSCOPE_SERVICES=checkout-api \
    bash -c 'source "'"${repo}/harness/core/lib/common.sh"'"' 2>&1)"; then
  fail "remote profiling without verification URL was accepted:\n${out}"
fi
printf '%s\n' "${out}" | grep -q 'PERFLAB_PROFILING_VERIFICATION_URL' || fail "missing verification URL error"

# Explicit remote endpoints, services, and verification source are accepted by context loading.
out="$(PERFLAB_LAB=remote-example PERFLAB_CONTINUOUS_PROFILING=1 PERFLAB_REMOTE_TELEMETRY=1 \
    PERFLAB_PROMETHEUS_URL=https://prom.example PERFLAB_TEMPO_URL=https://tempo.example \
    PERFLAB_LOKI_URL=https://loki.example PERFLAB_PROM_JOB_REGEX=api PERFLAB_SERVICE_NAME_REGEX=api \
    PERFLAB_PYROSCOPE_URL=https://pyroscope.example PERFLAB_PYROSCOPE_SERVICES=checkout-api \
    PERFLAB_PROFILING_VERIFICATION_URL=https://agent.example/profiling \
    bash -c 'source "'"${repo}/harness/core/lib/common.sh"'"; printf "url=%s profiling=%s\n" "${pyroscope_url}" "${continuous_profiling}"' 2>&1)" \
  || fail "explicit remote Pyroscope URL was rejected:\n${out}"
printf '%s\n' "${out}" | grep -q 'url=https://pyroscope.example' || fail "pyroscope_url not recorded: ${out}"
printf '%s\n' "${out}" | grep -q 'profiling=1' || fail "continuous_profiling not set: ${out}"

# An invalid boolean is rejected before any lab work starts.
if out="$(PERFLAB_LAB=scenariolab PERFLAB_CONTINUOUS_PROFILING=maybe \
    bash -c 'source "'"${repo}/harness/core/lib/common.sh"'"' 2>&1)"; then
  fail "invalid PERFLAB_CONTINUOUS_PROFILING was accepted:\n${out}"
fi
printf '%s\n' "${out}" | grep -q 'must be 1/true or 0/false' || fail "invalid boolean error text: ${out}"

if out="$(PERFLAB_LAB=scenariolab PERFLAB_PROFILING_KEEP_TIERING=maybe \
    bash -c 'source "'"${repo}/harness/core/lib/common.sh"'"' 2>&1)"; then
  fail "invalid PERFLAB_PROFILING_KEEP_TIERING was accepted:\n${out}"
fi
printf '%s\n' "${out}" | grep -q 'PERFLAB_PROFILING_KEEP_TIERING must be 1/true or 0/false' || fail "invalid keep-tiering error text: ${out}"

# Local default remains loopback 4040.
out="$(PERFLAB_LAB=scenariolab PERFLAB_CONTINUOUS_PROFILING=0 \
    bash -c 'source "'"${repo}/harness/core/lib/common.sh"'"; printf "url=%s profiling=%s keep=%s\n" "${pyroscope_url}" "${continuous_profiling}" "${PERFLAB_PROFILING_KEEP_TIERING}"' 2>&1)" \
  || fail "local default failed:\n${out}"
printf '%s\n' "${out}" | grep -q 'url=http://127.0.0.1:4040' || fail "local default URL: ${out}"
printf '%s\n' "${out}" | grep -q 'profiling=0' || fail "local default profiling: ${out}"
printf '%s\n' "${out}" | grep -q 'keep=0' || fail "keep-tiering default: ${out}"

out="$(PERFLAB_LAB=scenariolab PERFLAB_PROFILING_KEEP_TIERING=true \
    bash -c 'source "'"${repo}/harness/core/lib/common.sh"'"; printf "keep=%s\n" "${PERFLAB_PROFILING_KEEP_TIERING}"' 2>&1)" \
  || fail "keep-tiering true was rejected:\n${out}"
printf '%s\n' "${out}" | grep -q 'keep=1' || fail "keep-tiering true was not exported as 1: ${out}"

scenariolab_keep="$(grep -c 'PERFLAB_PROFILING_KEEP_TIERING: ${PERFLAB_PROFILING_KEEP_TIERING:-0}' "${repo}/labs/scenariolab/compose.yaml" || true)"
[[ "${scenariolab_keep}" == "2" ]] || fail "scenariolab compose must forward keep-tiering on api and worker (got ${scenariolab_keep})"
ecommerce_keep="$(grep -c 'PERFLAB_PROFILING_KEEP_TIERING: ${PERFLAB_PROFILING_KEEP_TIERING:-0}' "${repo}/labs/ecommerce/compose.yaml" || true)"
[[ "${ecommerce_keep}" == "1" ]] || fail "ecommerce compose must forward keep-tiering on api (got ${ecommerce_keep})"

for managed_lab in scenariolab ecommerce; do
  out="$(PERFLAB_LAB="${managed_lab}" bash -c '
    source "'"${repo}"'/harness/core/lib/common.sh"
    source "'"${repo}"'/harness/core/lib/performance.sh"
    performance_profiling_preflight
  ' 2>&1)" || fail "${managed_lab} profiling preflight failed:\n${out}"
  printf '%s\n' "${out}" | grep -q '"captureState":"captured"' ||
    fail "${managed_lab} profiling preflight did not emit captured evidence: ${out}"
done

echo "lab-context pyroscope tests passed"
