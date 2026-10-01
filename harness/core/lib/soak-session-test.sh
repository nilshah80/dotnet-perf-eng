#!/usr/bin/env bash
# C-12. Soak certification is one uninterrupted generator session. Four hours
# is the advertised Gate B duration; this proof does not run a four-hour soak.
set -euo pipefail
root="$(CDPATH= cd -- "$(dirname "$0")/../../.." && pwd)"
fail() { echo "soak-session-test: $*" >&2; exit 1; }
export PERFLAB_LAB_OPTIONAL=1
# shellcheck disable=SC1091
source "${root}/harness/core/lib/common.sh"
# shellcheck disable=SC1091
source "${root}/harness/core/lib/performance.sh"

if PERFLAB_SOAK_CERT=1 performance_soak_cert_preflight 30; then
  fail "soak cert accepted a 30s duration"
fi
PERFLAB_SOAK_CERT=1 performance_soak_cert_preflight 14400 \
  || fail "soak cert rejected a four-hour duration"
unset PERFLAB_SOAK_CERT
performance_soak_cert_preflight 30 \
  || fail "uncertified soak must not require four hours"

work="$(mktemp -d "${TMPDIR:-/tmp}/soak-session.XXXXXX")"
trap 'rm -rf "${work}"' EXIT
performance_soak_bind_pid "${work}/start.json" 4242 k6 1700000000 || fail "bind pid"
performance_soak_assert_pid "${work}/start.json" 4242 || fail "matching pid was refused"
identity="$(performance_soak_identity "${work}/start.json")"
[[ "${identity}" =~ ^[a-f0-9]{32}$ ]] || fail "durable generator identity was not recorded"
if performance_soak_assert_pid "${work}/start.json" 9999; then
  fail "restarted generator pid was accepted as one soak"
fi

echo "soak session identity and four-hour certification gate passed"
